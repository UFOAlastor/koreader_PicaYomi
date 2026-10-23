-- network/subprocess_fork.lua
-- fork 出来的子进程 + 双向管道: 让"下载"整体离开主线程。
--
-- 为什么必须有它 (而不是用 httpasync / 非阻塞 socket):
--   socket.http / ssl.https 的 `connect(host, port)` 会**同步解析域名**, 这一步
--   不受 socket timeout 约束 (KOReader 的 socketutil 里明说 "name resolution
--   发生在更底层")。主线程一旦发起连接, 界面就冻在那儿 —— 这正是真机上
--   "点了没反应"的根因。只有把整段 HTTP (DNS + TLS + 传输) 放进子进程,
--   主线程才可能"只等结果"。
--
-- 协议照抄 KOReader 自己的 updater (base/ffi/updater.lua): 2 字节长度 + payload,
-- payload 用 string.buffer 编解码 Lua 表。长度用**本机字节序** (收发两端都在同一台
-- 机器上), 所以父进程的非阻塞读用 ffi 的 uint16_t 直接解释那 2 个字节。
--
-- **`string.buffer` 必须 require 进来, 不能当内建用**: KOReader 的 LuaJIT 构建
-- 没有把 string.buffer / string.unpack 编进 string 库 (`string.buffer` 是 nil)。
-- 上游 updater 也是 `local buffer = require("string.buffer")` (updater.lua:2)。
-- 踩过的坑: 这里原本写 `string.buffer(4096)`, 而 L2 的 worker 测试用的是假子进程
-- (test/lua/fake_subprocess.lua) 根本没执行到本文件, 于是这个"在本机 LuaJIT 上
-- 看着没问题"的写法一路溜到 L3 真实网络测试才炸:
--   network/subprocess_fork.lua:205: attempt to call field 'buffer' (a nil value)
--
-- 本模块只负责"发 / 收 / 杀", 不含任何下载或调度逻辑 (那些在
-- network/reader_worker.lua 与 network/transport_worker.lua)。把 ffi/posix 的细节
-- 收在这一处, 上层就能在测试里换成纯 Lua 的假实现 (test/lua/fake_subprocess.lua),
-- 从而在不 fork 的前提下确定性地测到协议与状态机。

local ffi = require("ffi")
local posix = require("ffi/posix")
local util = require("ffi/util")
local logger = require("util.logger")
local buffer = require("string.buffer")

local C = ffi.C

local Fork = {}
Fork.__index = Fork

-- 单帧上限: 任务帧里带的是 URL + 请求头 (几百字节), 结果帧更小。
-- 2 字节长度字段本身的上限就是 65535, 这里显式挡一下, 免得畸形数据把内存吃光。
Fork.MAX_FRAME = 65535

-- 解码用的复用缓冲 (单线程, 一次只解一帧, 不存在重入)
local scratch = nil

--- 把一帧 payload 解成 Lua 表
local function decode_frame(payload)
    scratch = scratch or buffer:new()
    return scratch:reset():put(payload):decode()
end

--- 新会话的公共字段
local function new_session(fields)
    fields.rx = ""
    fields.want = nil
    fields.tx = buffer:new()          -- 发送缓冲 (encode 用)
    fields.hdr = ffi.new("uint16_t[1]")  -- 长度头 (发/收共用, 顺序调用不冲突)
    return setmetatable(fields, Fork)
end

function Fork.from_fds(read_fd, write_fd, pid)
    return new_session({ read_fd = read_fd, write_fd = write_fd, pid = pid, child = pid == nil })
end

-- Named workers have a fresh interpreter on Darwin and retain the established
-- fork backend on Linux. Injected test factories need only implement spawn().
function Fork.spawnWorker(kind, options)
    if ffi.os == "OSX" then return require("network.subprocess_spawn").spawn(kind, options) end
    return Fork.spawn(function(child)
        require("network.background_worker").run(child, kind, options)
    end)
end

--- 发送一帧 (父/子通用: 都往自己那侧的 write_fd 写)
--
-- posix.write 在失败时会**抛错** (EPIPE/EBADF), 所以这里必须 pcall ——
-- 子进程猝死时父进程正好会写到一个没有读者的管道, 那是正常情况, 不是异常。
function Fork:send(tbl)
    if self.closed then return false, "管道已关闭" end
    self.tx:reset():encode(tbl)
    local n = #self.tx
    if n > Fork.MAX_FRAME then return false, "帧过大: " .. n end

    local ok, err = pcall(function()
        self.hdr[0] = n
        posix.write(self.write_fd, self.hdr, 2, true)
        if n > 0 then posix.write(self.write_fd, self.tx:ref(), n, true) end
    end)
    if not ok then return false, tostring(err) end
    return true
end

--- 非阻塞地把管道里"已经就绪"的字节收进接收缓冲
function Fork:_pump_rx()
    while true do
        local avail = util.getNonBlockingReadSize(self.read_fd)
        if not avail or avail <= 0 then return end
        local chunk = ffi.new("char[?]", avail)
        local n = tonumber(C.read(self.read_fd, chunk, avail))
        if not n or n <= 0 then return end
        self.rx = self.rx .. ffi.string(chunk, n)
        if #self.rx > Fork.MAX_FRAME then
            logger.warn("Picayomi Worker: 接收缓冲异常增长, 丢弃")
            self.rx = ""
            self.want = nil
            return
        end
    end
end

--- 从接收缓冲里取出一帧 (不足一帧则返回 nil, 不消费半帧)
function Fork:_pop_frame()
    if not self.want then
        if #self.rx < 2 then return nil end
        ffi.copy(self.hdr, self.rx:sub(1, 2), 2)
        self.want = self.hdr[0]
        self.rx = self.rx:sub(3)
    end
    if #self.rx < self.want then return nil end
    local payload = self.rx:sub(1, self.want)
    self.rx = self.rx:sub(self.want + 1)
    self.want = nil
    return decode_frame(payload)
end

--- 非阻塞收一帧
-- @return 帧 或 nil ("暂时没有"; 不代表子进程死了 —— 用 alive() 判)
function Fork:try_recv()
    if self.closed then return nil end
    self:_pump_rx()
    return self:_pop_frame()
end

--- 收一帧, 不够就阻塞等到齐
--
-- 两条路径都用它:
--   * 子进程: 没有接收缓冲, 直接阻塞 (它就是靠这个等任务);
--   * 父进程: 只在**同步语义**的路径上用 (StreamSession:fetch_page 的兼容语义)。
-- 子进程自己的网络超时会兜底, 所以不会无限期挂住。
-- 读出错 (对端已关/管道坏了) 一律返回 nil, 由调用方当"子进程没了"处理。
function Fork:recv()
    if self.closed then return nil end
    local frame = self:_pop_frame()          -- 先把已缓冲的帧取出来
    if frame then return frame end

    local ok, result = pcall(function()
        if tonumber(posix.read(self.read_fd, self.hdr, 2, false)) < 2 then
            return nil                       -- 对端关掉了管道
        end
        local want = self.hdr[0]
        if want == 0 then return {} end
        if want > Fork.MAX_FRAME then return nil end

        local payload = ffi.new("char[?]", want)
        if tonumber(posix.read(self.read_fd, payload, want, false)) < want then
            return nil
        end
        return decode_frame(ffi.string(payload, want))
    end)
    if not ok then return nil end
    return result
end

--- 子进程还活着吗
--
-- 注意: util.isSubProcessDone 内部会 waitpid **收尸**。所以一旦返回 true,
-- 之后就必须走 close()/重建, 不能再指望管道里还有新数据 ——
-- 调用方要先把 try_recv 收干净再问 alive()。
function Fork:alive()
    if self.closed or not self.pid then return false end
    return not util.isSubProcessDone(self.pid)
end

function Fork:_close_fds()
    if self.read_fd then
        C.close(self.read_fd)
        self.read_fd = nil
    end
    if self.write_fd then
        C.close(self.write_fd)
        self.write_fd = nil
    end
end

--- 杀掉子进程并收尸 (不等它自己退出)
--
-- 用 SIGKILL (terminateSubProcess 内部就是 kill(-pid, 9) —— 子进程在
-- runInSubProcess 里 setpgid 过, 所以是整组一起杀)。SIGKILL 之后 waitpid
-- 基本立刻返回, 这里用阻塞 wait 保证不留僵尸 (取消只发生在关文档/换章, 不在绘制链)。
function Fork:kill()
    if self.pid then
        util.terminateSubProcess(self.pid)
        util.isSubProcessDone(self.pid, true)
        self.pid = nil
    end
    self.closed = true
    self:_close_fds()
end

--- 杀掉子进程但**不等它被回收** (给"进程正在退出"的路径用)
--
-- 与 kill() 的唯一区别: 不做那次阻塞 waitpid。kill() 的阻塞语义是给"正常关闭 /
-- 换章"用的 —— 那时子进程通常响应着, 且必须不留僵尸; 而在退出/重启/关机路径上,
-- 子进程可能正卡在一个 15 秒的 DNS 解析里, 阻塞等它就是把"退出卡顿"原样留着。
-- 进程退出后它变成孤儿 (被 init 收养后自行消失), 无害。
--
-- 注意: 调用方之后**不能**再用 alive() —— pid 已经丢掉, alive() 会恒返回 false。
function Fork:terminate()
    if self.pid then
        util.terminateSubProcess(self.pid)
        self.pid = nil
    end
    self.closed = true
    self:_close_fds()
end

function Fork:close()
    self:kill()
    self.rx = ""
    self.want = nil
    self.tx = nil
end

----------------------------------------------------------------------------
-- 入口
----------------------------------------------------------------------------

--- 起一个常驻子进程
--
-- @param child_main function(session)  子进程主循环 (见 network/reader_worker.lua)
-- @return session 或 nil, err
--
-- 失败必须由调用方处理 (退回同步下载), 不能静默 —— 管道创建在低内存设备上
-- 真的会失败 (base/ffi/util.lua 的 runInSubProcess 会返回 false, err)。
function Fork.spawn(child_main)
    local pid, read_fd, write_fd = util.runInSubProcess(function(_pid, child_write, child_read)
        local session = new_session({
            child = true,
            read_fd = child_read,
            write_fd = child_write,
        })
        local ok, err = pcall(child_main, session)
        if not ok then
            logger.err("Picayomi Worker: 子进程主循环异常退出: " .. tostring(err))
        end
        session:close()
    end, "bidi")

    if not pid then
        return nil, tostring(read_fd or "无法创建下载子进程")
    end

    return new_session({
        pid = pid,
        read_fd = read_fd,
        write_fd = write_fd,
    })
end

return Fork
