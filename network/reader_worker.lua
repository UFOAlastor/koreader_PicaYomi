local Diag = require("util.diag")
-- network/reader_worker.lua
-- 下载 worker 的**子进程侧**: 真正做 HTTP (含 DNS/TLS) 与图片后处理的地方。
--
-- 为什么必须在子进程里做:
--   1. `socket.http` / `ssl.https` 的 connect() 会**同步解析域名**, 不受 socket
--      timeout 约束。主线程一旦发起连接, 界面就冻在那儿 —— 真机 "点了没反应" 的根因。
--   2. 源侧图片后处理 (imagePost) 是纯 CPU 的活, 在主线程上做会占住事件循环。
--      注意: 源 B 的解扰**不走这里** (0.9.7 起改到渲染期内存里做, 见
--      source/base.lua 的 imageRenderPost) —— 它落盘要重新编码一张照片, 真机 3.5s/页。
--
-- 约束 (与 KOReader 自己的 updater 一致): 子进程里**不能碰 UIManager / 控件树**,
-- 也不能弹任何提示。它只能读文件、写文件、发帧。
--
-- 协议 (见 network/subprocess_fork.lua):
--   父 -> 子: { "job", page, url, dest, headers, post, timeout, token }
--             { "cancel", page, token } (async only)
--             { "quit" }
--   子 -> 父: { "done", page, ok, path, size, err, elapsed, post_elapsed, token }
--
-- 请求头由**父进程**在发起那一刻现算并随任务下发 (见 source/base.lua 的 imageHeaders):
-- 子进程是 fork 出来的快照, 里面的登录 token 可能已经过期; 让父进程现算就绕开了
-- 这个陷阱。后处理同理只下发一个"模块 + 函数"描述符 (imagePost)。
--
-- 两种跑法 (由 opts.async 选, 默认串行):
--   * 串行: 一次一个任务, 直接调 Worker.execute (老行为; 也是所有离线用例的路径);
--   * 并发: 用 network/download_async 同时推进 2 个请求 (opts.async = true)。
--     只有 ui/stream_reader 的真实阅读页会开 —— 封面通道一次只要一张, 开了也没用。
--   两条路共用同一份后处理 (Worker.post_process) 与同一套协议。

local logger = require("util.logger")

local Worker = {}

--- 墙钟 (秒)。**不能用 os.clock()**: 它量的是本进程的 CPU 时间, 而下载几乎全是
--- 等网络 (DNS / TLS / 首字节 / 传输) —— 实测一张图真机上要好几秒, 子进程报上来的
--- 却是 "0.1s"。这个数字有两个消费者, 都会因此判错:
---   * Diag 的 "page N ok X.Xs" (排查"翻页慢"时唯一的耗时证据);
---   * 调度器的慢链路熔断 (policy.slow_seconds), 它按这个值决定要不要停预取。
local function wall_time()
    local ok, socket = pcall(require, "socket")
    if ok and type(socket) == "table" and socket.gettime then return socket.gettime() end
    return os.clock()   -- 没有 luasocket 时退回 (测试环境): 语义退化但不炸
end

--- 可注入的墙钟 (测试用它制造"这一页下了很久"; 见 regression_robustness 1.3)
Worker.wall_time = wall_time

-- 单张图的下载超时 (秒)。比旧实现略长, 因为现在超时不再冻结界面 ——
-- 超时期间主线程照常响应翻页/返回。
Worker.DEFAULT_TIMEOUT = 20

--- 源侧图片后处理 (例如源 B 的分带解扰)
--
-- 单独计时: 解扰不是"顺手做的", 它是**解码整图 + 逐带重排 + 重新编码** ——
-- 真机上很可能比 HTTP 还贵。只报总耗时的话, 看到 4s 也分不清该优化网络还是
-- 该优化后处理, 而这两件事的修法毫无交集。
--
-- @return 后处理耗时 (秒); 没有后处理时接近 0
function Worker.post_process(job, item)
    local t_post = Worker.wall_time()
    local success=true
    if job.post and job.post.digest then
        success=require("source.processors").file(job.post,job.dest,job.url)
    elseif job.post and job.post.module and job.post.fn then
        local pok, mod = pcall(require, job.post.module)
        if pok and type(mod) == "table" and type(mod[job.post.fn]) == "function" then
            local qok, qres, qinfo = pcall(mod[job.post.fn], job.dest, job.url)
            if not qok then
                success=false
            elseif qres == false then
                success=false
            end
        else
            success=false
        end
    end
    if not success then
        item.ok=false; item.err="图片文件处理失败";item.code="invalid_response";item.retryable=false
        os.remove(job.dest)
    end
    return Worker.wall_time() - t_post
end

--- 执行一个下载任务 (串行路径; 子进程内调用)
--
-- @param job  { page, url, dest, headers, post, timeout }
-- @param deps { download = function(url, dest, headers, timeout) -> ok, res }
--             可注入, 让协议/状态机能在不联网的情况下被测试。
-- @return { page, ok, path, size, err, elapsed, post }
function Worker.execute(job, deps)
    deps = deps or {}
    local download = deps.download
    if not download then
        local HttpClient = require("network.http_client")
        download = function(url, dest, headers, timeout)
            return HttpClient:download(url, dest, headers, timeout, nil, deps.pool)
        end
    end

    local item = { page = job.page, ok = false }
    if not job.url or not job.dest then
        item.err = "缺少图片地址"
        return item
    end

    -- 单页耗时**在子进程里量**, 而不是在父进程里量 —— 那样会把"界面忙一下, 晚来
    -- poll 了一次"算进下载耗时, 误判成慢链路。但尺子必须是**墙钟**: 下载等的是
    -- 网络, CPU 几乎不动 (见 wall_time 的注释)。
    local t0 = Worker.wall_time()
    local ok, res = download(job.url, job.dest, job.headers,
        job.timeout or Worker.DEFAULT_TIMEOUT)

    if not ok then
        item.elapsed = Worker.wall_time() - t0
        os.remove(job.dest)          -- 与同步实现一致: 失败不留残file
        local err=require("source.contract").error("network",tostring(res),"image.download",nil,true)
        item.err,item.code,item.retryable=err.message,err.code,err.retryable
        return item
    end

    item.post = Worker.post_process(job, item)
    if item.err then item.elapsed=Worker.wall_time()-t0; return item end

    -- 总耗时**包含源侧后处理** (源 B 的逐带解扰在这里, 真机实测 ~1s):
    -- 用户等的是"这一页什么时候能看", 不是"HTTP 什么时候结束"。
    -- 只算 HTTP 会让慢页熔断和 diag 都低估一半。
    item.elapsed = Worker.wall_time() - t0

    local lfs = require("libs/libkoreader-lfs")
    item.ok = true
    item.path = job.dest
    item.size = lfs.attributes(job.dest, "size")
    return item
end

----------------------------------------------------------------------------
-- 子进程主循环
----------------------------------------------------------------------------

local function decode_job(msg)
    return {
        page    = msg[2],
        token   = msg[8],
        url     = msg[3],
        dest    = msg[4],
        headers = msg[5],
        post    = msg[6],
        timeout = msg[7],
    }
end

local function emit(session, item)
    session:send{
        "done", item.page, item.ok and true or false,
        item.path, item.size, item.err, item.elapsed, item.post, item.token,item.code,item.retryable,
    }
end

--- 串行: 收一个跑一个 (老行为)
local function serial_loop(session, exec_opts)
    while true do
        local msg = session:recv()
        if not msg then break end
        local kind = msg[1]
        if kind == "quit" then break end

        if kind == "job" then
            local job = decode_job(msg)
            local ok, item = pcall(Worker.execute, job, exec_opts)
            if not ok then
                item = { page = job.page, ok = false, err = tostring(item) }
            end
            item.token = job.token
            emit(session, item)
        end
    end
    session:close()
end

--- 并发: 同时推进最多 2 个请求 (network/download_async)
--
-- 主循环必须**不空转**: 有在途任务时用 socket.select 等 20ms; 完全空闲时
-- 阻塞在管道上 —— 与串行版的 CPU 占用一致 (空闲 0%)。
local function async_loop(session, exec_opts, pool)
    local Async = require("network.download_async")
    local async = Async.new{ pool = pool }
    local pending = {}        -- 并发满了就排这儿 (父进程本来也会排队, 这是二道闸)

    while true do
        local progressed = false

        -- 1) 收任务 (非阻塞, 一次一帧)
        local msg = session:try_recv()
        if msg then
            if msg[1] == "quit" then break end
            if msg[1] == "cancel" then
                async:cancel(msg[2], msg[3])
                for i = #pending, 1, -1 do
                    if pending[i].page == msg[2] and pending[i].token == msg[3] then
                        table.remove(pending, i)
                    end
                end
                progressed = true
            elseif msg[1] == "job" then
                local job = decode_job(msg)
                if not async:add(job) then
                    pending[#pending + 1] = job
                end
                progressed = true
            end
        end

        -- 2) 推进在途任务
        local res = async:step()
        for _i, item in ipairs(res.done) do
            if item.ok then
                local post = Worker.post_process({ dest = item.path, url = item.url,
                    post = item.post_spec }, item)
                item.post = post
                -- 总耗时含后处理, 与串行路径口径一致
                item.elapsed = (item.elapsed or 0) + post
            end
            emit(session, item)
            progressed = true
        end

        -- 3) 补位
        while #pending > 0 and not async:full() do
            async:add(table.remove(pending, 1))
            progressed = true
        end

        -- 4) 等: 有活就等 socket, 没活就阻塞等管道
        if async:busy() or #pending > 0 then
            if not progressed then async:wait() end
        else
            local m = session:recv()      -- 阻塞 (真实现是 posix.read)
            if not m or m[1] == "quit" then break end
            if m[1] == "job" then
                local job = decode_job(m)
                if not async:add(job) then pending[#pending + 1] = job end
            end
        end
    end

    async:close()
    session:close()
end

--- 子进程主循环: 收任务 -> 执行 -> 回结果
--
-- 循环体里任何异常都不许把子进程带走 (那样父进程只能看到"子进程意外退出") ——
-- 单条任务失败就回一条 ok=false。
--
-- @param opts.async true = 并发推进 (默认串行)
-- @param opts.download 可注入的下载函数 (测试)
function Worker.loop(session, opts)
    -- 连接池**只活在子进程里**: 子进程是常驻的, 一话的二十来页都从它发出去,
    -- 每页复用同一条 TLS 连接 (省掉一次握手, 真机 0.4s+/页)。
    -- 放在父进程不行 —— 父进程一旦 fork, 子进程拿到的是 fd 的副本,
    -- 两条进程交替读同一条连接必然把响应切碎。
    local pool = nil
    do
        local ok, Pool = pcall(require, "network.http_conn")
        if ok and type(Pool) == "table" then
            pool = Pool.new{
                timeout = Worker.DEFAULT_TIMEOUT,
                -- 诊断: 新建连接才打一行。一话 20 页如果只出现 1 行, 说明复用生效;
                -- 每页一行就是没复用 (或每页都换了 host) —— 排查"翻页慢"时
                -- 这是最直接的证据, 且不像逐页日志那么噪。
                on_connect = function(host)
                    pcall(function()
                        if Diag.enabled then Diag.mark("conn 新建 " .. tostring(host)) end
                    end)
                end,
            }
        end
    end

    local exec_opts = { pool = pool, download = opts and opts.download }

    if opts and opts.async and pool then
        async_loop(session, exec_opts, pool)
    else
        serial_loop(session, exec_opts)
    end
    if pool then pcall(function() pool:close() end) end
end

return Worker
