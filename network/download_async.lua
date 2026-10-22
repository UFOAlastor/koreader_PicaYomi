-- network/download_async.lua
-- 下载子进程里的**并发**下载调度: 同时推进多个 HTTP 请求 (默认 2 个)。
--
-- 为什么需要它:
--   v0.9.14 把"每张图一次 TLS 握手"摊掉之后, 剩下的瓶颈是**串行** ——
--   一页下完才发下一张。真机一页 1~1.5s, 预取 3 页就要 3~4.5s 才铺满,
--   而漫画翻页间隔常常只有 2~3s, 于是"偶尔还是要等一张"。
--
-- 怎么并发 (不靠线程):
--   socket 设成非阻塞 (settimeout(0)), 每次只读"当前可读"的那点字节,
--   喂给增量解析器 (network/http_parse), 然后**让出**去推进下一个任务。
--   Lua 是单线程, 但下载等的是网络 —— 一个线程轮转多个 socket 就够了,
--   这也是 nginx 那种模型。
--
-- 公平性: 每个任务每轮最多读 READS_PER_TURN 次, 然后让出。全部任务都
-- 返回 wantread 时用 socket.select 等 20ms —— 不空转 CPU。
--
-- 与阻塞路径的关系:
--   落盘/状态判定/原子改名复用 http_client 的同一套规则 (publish_download),
--   解析复用 http_parse。这里只负责"把字节从 socket 搬到文件"。

local socket = require("socket")
local logger = require("util.logger")
local Parser = require("network/http_parse")
local HttpClient = require("network.http_client")
local Redact = require("util.log_redact")

local Async = {}
Async.__index = Async

Async.MAX_ACTIVE = 2          -- 同时推进的任务数 (Kindle 上带宽/内存都紧, 别贪)
Async.READ_CHUNK = 16384
Async.READS_PER_TURN = 8      -- 每个任务每轮最多读几次, 然后让出
Async.IDLE_WAIT = 0.02        -- 全部等数据时的 select 超时 (秒)
Async.MAX_REDIRECTS = 5       -- 与阻塞路径一致

--- @param opts.pool       连接池 (network/http_conn, 必需)
--- @param opts.max_active 并发上限
--- @param opts.wall_time  墙钟 (测试注入)
function Async.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Async)
    self.pool = opts.pool
    self.max_active = opts.max_active or Async.MAX_ACTIVE
    self.wall_time = opts.wall_time or function()
        return socket.gettime and socket.gettime() or os.clock()
    end
    self.jobs = {}
    return self
end

function Async:active_count() return #self.jobs end
function Async:busy() return #self.jobs > 0 end
function Async:full() return #self.jobs >= self.max_active end

----------------------------------------------------------------------------
-- 请求构造
----------------------------------------------------------------------------

local function build_request(url, headers)
    local scheme, host, port, path = require("network.http_conn").parseUrl(url)
    if not scheme then return nil, "无法解析地址: " .. tostring(url) end
    local lines = { "GET " .. path .. " HTTP/1.1" }
    local host_header = (port == 80 or port == 443) and host or (host .. ":" .. port)
    lines[#lines + 1] = "Host: " .. host_header
    for k, v in pairs(headers or {}) do
        local lk = tostring(k):lower()
        if lk ~= "connection" and lk ~= "host" then
            lines[#lines + 1] = tostring(k) .. ": " .. tostring(v)
        end
    end
    lines[#lines + 1] = "Connection: keep-alive"
    return table.concat(lines, "\r\n") .. "\r\n\r\n"
end

----------------------------------------------------------------------------
-- 任务的三个状态: connect -> send -> read
----------------------------------------------------------------------------

local function abort(self, job, err)
    if job.fh then pcall(function() job.fh:close() end); job.fh = nil end
    if job.tmp then os.remove(job.tmp) end
    if job.sock then
        self.pool:release(job.key, job.sock, false)
        job.sock = nil
    end
    job.state = "failed"
    job.err = err or "下载失败"
end

local function begin(job)
    local tmp = job.dest .. HttpClient.DOWNLOAD_TMP_SUFFIX
    local fh = io.open(tmp, "wb")
    if not fh then return nil, "无法创建文件: " .. tmp end
    job.tmp = tmp
    job.fh = fh
    job.written = 0
    return true
end

--- 3xx: 换地址重下 (截断文件, 丢掉这一跳的响应体)
--
-- **并发路径必须自己跟跳转**。阻塞路径 (http_client 的 follow) 早就跟了, 并发这条
-- 是 v0.9.15 新写的, 漏了这一步 —— 而 2026-10-18 源 A 把图床从 storage1 迁到
-- img.源站, 旧地址一律回 301 + 194 字节 HTML:
--   旧图床地址 -> 301 新图床地址
-- 于是封面/详情正常 (走阻塞路径), **阅读页每页都 HTTP 301**, 整话空白。
-- 这类"两条路径必须同形"的判定, 一律共用 http_client 的那一份。
--
-- @return true = 已改成"从新地址重下" (任务还在途); false = 不是可跟随的跳转
local function follow_redirect(self, job)
    local p = job.parser
    local status = tonumber(p and p.status_code) or 0
    if status < 300 or status >= 400 then return false end
    local location = p and p.headers and p.headers.location
    local next_url = HttpClient.resolveLocation(job.url, location)
    -- 没有 Location 的 3xx 不是跳转, 交给 check_download 报真实状态码
    if not next_url then return false end
    if (job.hops or 0) >= Async.MAX_REDIRECTS then return false end

    -- 连接按响应头决定留不留 (与正常完成时同一套判定)
    if job.sock then
        self.pool:release(job.key, job.sock, p:keep_alive())
        job.sock = nil
    end
    if job.fh then pcall(function() job.fh:close() end) end
    job.fh = io.open(job.tmp, "wb")     -- 截断: 跳转页那 194 字节不能留在图片前面
    if not job.fh then
        abort(self, job, "无法创建文件: " .. tostring(job.tmp))
        return true
    end
    job.written = 0
    job.hops = (job.hops or 0) + 1
    job.url = next_url
    job.parser = nil
    job.state = "connect"               -- 下一轮 advance 重新建连 + 发请求
    if logger.enabled then logger.dbg("Picayomi Async: 跟随跳转 (" .. job.hops .. ") -> " .. Redact.url(next_url)) end
    return true
end

local function complete(self, job)
    -- 先处理跳转: 194 字节的跳转页一旦发布出去, 解码必然失败 (用户看到"永远加载中")
    if follow_redirect(self, job) then return end
    if job.fh then pcall(function() job.fh:close() end); job.fh = nil end
    local status = job.parser and job.parser.status_code
    -- 连接能不能留着, 看响应头; 与阻塞路径同一套判定
    local keep = job.parser and job.parser:keep_alive()
    if job.sock then
        self.pool:release(job.key, job.sock, keep)
        job.sock = nil
    end

    -- publish_download 的返回是 (ok, size, err, transient): 失败时第二、三个
    -- 位置分别是 err 与 transient, 别按名字想当然 (踩过: err 拿到 false)。
    local ok, a, b, c = HttpClient:publish_download(job.tmp, job.dest, status, job.written)
    job.tmp = nil
    if not ok then
        job.state = "failed"
        job.err = a
        job.transient = b
        return
    end
    job.state = "done"
    job.size = a
end

--- 推进一个任务 (非阻塞; 每次最多做一点)
--
-- connect -> send 在同一次调用里连做: 建连本来就已经阻塞过了, 再把"发请求"
-- 推到下一轮只是白等一个调度周期。
local function advance(self, job)
    if job.state == "connect" then
        local sock, key, _reused, err = self.pool:acquire(job.url)
        if not sock then return abort(self, job, err) end
        job.sock, job.key = sock, key
        -- 连接阶段是阻塞的 (DNS/TCP/TLS): 复用命中时这一段几乎为零,
        -- 只有每话第一次 (或换 host) 会付一次握手 —— 那点时间无法避开。
        sock:settimeout(0)
        local req, rerr = build_request(job.url, job.headers)
        if not req then return abort(self, job, rerr) end
        job.req, job.off = req, 1
        job.parser = Parser.new(function(chunk)
            job.written = job.written + #chunk
            local ok, werr = job.fh:write(chunk)
            if not ok then return nil end
            return 1
        end)
        job.state = "send"
        -- 落到下面的 send 分支 (同一次调用里发出去)
    end

    if job.state == "send" then
        local n, err = job.sock:send(job.req, job.off)
        if n then
            job.off = n + 1
            if job.off > #job.req then job.state = "read" end
        elseif err == "wantwrite" or err == "timeout" then
            return                      -- 下一轮再试
        else
            return abort(self, job, "发送请求失败: " .. tostring(err))
        end
    end

    if job.state == "read" then
        for _ = 1, Async.READS_PER_TURN do
            local chunk, err, partial = job.sock:receive(Async.READ_CHUNK)
            local piece = chunk or partial
            if piece and #piece > 0 then
                local done, perr = job.parser:feed(piece)
                if perr then return abort(self, job, perr) end
                if done then return complete(self, job) end
            end
            if not chunk then
                if err == "wantread" or err == "timeout" then
                    return                  -- 让出, 去推进别的任务
                elseif err == "closed" then
                    local dok, derr = job.parser:eof()
                    if dok then return complete(self, job) end
                    return abort(self, job, derr)
                else
                    return abort(self, job, "读取响应失败: " .. tostring(err))
                end
            end
        end
    end
end

--- 加一个任务
-- @return true = 已开始; false = 并发已满 (调用方自己排队)
function Async:add(job)
    if self:full() then return false end
    local ok, err = begin(job)
    if not ok then
        job.state = "failed"
        job.err = err
        self.jobs[#self.jobs + 1] = job
        return true
    end
    job.t0 = self.wall_time()
    job.state = "connect"
    self.jobs[#self.jobs + 1] = job
    return true
end

--- 推进一步: 所有任务各走一小步, 收掉完成的
-- @return { done = { item, ... }, active = n }
function Async:step()
    local done = {}
    local keep = {}
    for _i, job in ipairs(self.jobs) do
        if job.state ~= "done" and job.state ~= "failed" then
            local timeout = job.timeout or 20
            if self.wall_time() - (job.t0 or 0) > timeout then
                abort(self, job, "下载超时")
            else
                advance(self, job)
            end
        end
        if job.state == "done" or job.state == "failed" then
            done[#done + 1] = {
                page = job.page,
                token = job.token,
                ok = job.state == "done",
                path = (job.state == "done") and job.dest or nil,
                size = job.size,
                err = job.err,
                transient = job.transient,
                elapsed = self.wall_time() - (job.t0 or 0),
                -- 后处理在 worker 侧做 (见 reader_worker.async_loop): 描述符与
                -- 图片地址一起带出去, 免得 worker 再去翻原任务表。
                url = job.url,
                post_spec = job.post,
            }
        else
            keep[#keep + 1] = job
        end
    end
    self.jobs = keep
    return { done = done, active = #keep }
end

--- 等一等 (全部任务都在等数据时调用, 避免空转 CPU)
function Async:wait()
    local rsocks, wsocks = {}, {}
    for _i, job in ipairs(self.jobs) do
        if job.sock then
            if job.state == "send" then
                wsocks[#wsocks + 1] = job.sock
            else
                rsocks[#rsocks + 1] = job.sock
            end
        end
    end
    if #rsocks == 0 and #wsocks == 0 then
        socket.sleep(Async.IDLE_WAIT)
        return
    end
    -- **必须分开读写集**: 一条已建连的 socket 几乎总是"可写", 把它同时塞进
    -- 读集和写集, select 会立刻返回 —— 主循环就变成 40k 次/秒的空转 (实测
    -- 20000 轮 0.48s), 既烧 CPU 又让人误以为"下载卡住了"。
    -- select 的可读只是"有事可做"的提示: TLS 内部可能还有半个记录,
    -- 读不到数据就下一轮再来 —— 不依赖它的精确语义。
    pcall(socket.select, (#rsocks > 0) and rsocks or nil,
        (#wsocks > 0) and wsocks or nil, Async.IDLE_WAIT)
end

--- Cancel a single request without closing the shared worker or other sockets.
function Async:cancel(page, token)
    for i, job in ipairs(self.jobs) do
        if job.page == page and job.token == token then
            abort(self, job, "已取消")
            table.remove(self.jobs, i)
            return true
        end
    end
    return false
end

--- 放弃所有在途任务 (worker 退出)
function Async:close()
    for _i, job in ipairs(self.jobs) do
        abort(self, job, "已取消")
    end
    self.jobs = {}
end

return Async;
