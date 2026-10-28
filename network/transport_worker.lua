local Diag = require("util.diag")
-- network/transport_worker.lua
-- 生产用的下载传输层: 常驻 fork worker, **父进程侧**。
--
-- 职责边界 (与 network/transport_blocking.lua 完全对齐, 只是换了个跑法):
--   * 发起 / 收割 / 取消, 不含任何策略 (优先级、退避、熔断都在 util/download_scheduler.lua);
--   * 请求头与后处理描述符在**发起那一刻**由父进程现算 (见 source/base.lua 的
--     imageHeaders / imagePost) —— 子进程是 fork 快照, 登录 token 可能已过期。
--
-- 为什么它让界面不卡:
--   poll() 只做两件极短的事: ① 把管道里**已经就绪**的字节收进来 (ioctl FIONREAD +
--   read, 不阻塞); ② 往管道里写一条任务 (管道缓冲 64KB, 小帧不会阻塞)。
--   真正的 HTTP + DNS + 解扰全在子进程里。所以哪怕弱网下某一页要 10 秒,
--   主线程也只是每 50ms 醒来一次问一句"好了吗"。
--
-- 三条回退路径 (任何一条都必须静默降级到同步下载, 不能把功能弄丢):
--   1. 本源没实现 imageHeaders  -> 该任务交给 fallback (行为与改造前完全一致);
--   2. fork/管道创建失败        -> 之后所有任务都走 fallback (只警告一次);
--   3. 子进程意外死亡           -> 在途任务判失败 (交给调度器退避), 下次懒重建。
--
-- 同步语义 (StreamSession:fetch_page) 靠 poll(budget, block=true) 实现:
-- 那种调用方就是要"拿到结果再返回", 所以允许阻塞等子进程回帧。

local logger = require("util.logger")
local socket = require("socket")

local Transport = {}
Transport.__index = Transport
local instances = setmetatable({}, {__mode="k"})

-- 单张图的下载超时 (秒); 真正生效的是子进程里的 socket timeout
Transport.DEFAULT_TIMEOUT = 20

--- @param opts.source        漫画源 (需要 imageHeaders(url) -> headers|nil, err)
--- @param opts.fix_extension function(path) -> path  按文件头修正扩展名 (可注入)
--- @param opts.fallback      同步 transport (默认自建 TransportBlocking); 传 false 表示不要
--- @param opts.subprocess    子进程工厂 (默认 network/subprocess_fork; 测试注入假实现)
function Transport.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Transport)
    self.source = opts.source
    self.fix_extension = opts.fix_extension
    -- 诊断标签: "read" = 阅读页, "cover" = 封面。
    --
    -- 为什么必须有: 两条通道的日志长得一模一样 —— 封面任务也带 page 字段
    -- (CoverCache 用自增 id 当 page), 于是 diag 里 "start p1" 既可能是"第 1 页"
    -- 也可能是"第 1 张封面"。真机排查"同一页为什么下两遍"时被这个歧义带偏过
    -- (2026-10-18: 那两个 start p1 其实是封面通道的)。
    self.tag = opts.tag or "read"
    self.subprocess = opts.subprocess or require("network.subprocess_fork")
    self.timeout = opts.timeout or Transport.DEFAULT_TIMEOUT

    if opts.fallback == false then
        self.fallback = nil
    elseif opts.fallback then
        self.fallback = opts.fallback
    else
        self.fallback = require("network.transport_blocking").new{
            source = opts.source,
            fix_extension = opts.fix_extension,
        }
    end

    self.pending = {}          -- 还没交给 worker 的任务
    -- page -> { dest, started }。**可以有多条** —— 子进程侧用非阻塞 socket
    -- 同时推进 (network/download_async), 父进程这边只是记账。
    -- 默认 1；封面通道显式开两路，避免单张慢图阻塞后续可见行。
    self.inflight = {}
    self.max_inflight = opts.max_inflight or 1
    -- true = 子进程里用非阻塞 socket 同时推进多个请求 (见 reader_worker 的 async_loop)。
    -- 必须与 max_inflight 一致, 否则父进程发出去的比子进程能跑的还多, 只会排队。
    self.async = opts.async or false
    self.session = nil         -- 常驻子进程会话
    self.worker_error = nil    -- 一旦非空就再不起子进程 (避免每次任务都白试一遍)
    self.ready = {}            -- 已判定失败但还没被 poll 收走的条目
    self.fallback_jobs = {}
    self.next_token = 0
    self.cancelled = false
    if self.source and self.source.watchSession then
        self.unwatch=self.source:watchSession(function() self:invalidate() end)
    end

    instances[self] = true
    return self
end

-- Only idle workers are reclaimed. Pending jobs and completed replies remain
-- owned by the transport and are delivered normally on the next poll.
function Transport.reclaim_idle(tag)
    local count = 0
    for transport in pairs(instances) do
        if (not tag or transport.tag==tag) and transport.session and next(transport.inflight) == nil then
            transport:_drop_session()
            count = count + 1
        end
    end
    return count
end

function Transport:start(job)
    if self.cancelled then return end
    if self.invalidated then
        self.ready[#self.ready+1]={page=job.page,ok=false,err="登录状态已改变",code="cancelled",retryable=false}
        return
    end
    self.pending[#self.pending + 1] = job
end

--- 还有活吗 (在跑 / 在等)
function Transport:_inflight_count()
    local c = 0
    for _ in pairs(self.inflight) do c = c + 1 end
    return c
end

function Transport:busy()
    if next(self.inflight) ~= nil or #self.pending > 0 or #self.ready > 0 then return true end
    if self.fallback and self.fallback.busy then return self.fallback:busy() end
    return false
end

----------------------------------------------------------------------------
-- 子进程生命周期
----------------------------------------------------------------------------

--- 丢弃子进程
--
-- @param nonblocking true = 用 Fork:terminate (不发阻塞 waitpid), 见其注释
function Transport:_drop_session(nonblocking)
    local session = self.session
    self.session = nil
    -- 每丢一次就要重新 fork (真机 0.5~2.5s)。这条 mark 是"为什么又 fork 了"
    -- 的唯一证据 —— 没有它, diag 里只能看到一串"子进程已启动"。
    if session then
        pcall(function()
            if Diag.enabled then Diag.mark(string.format("drop %s (pid=%s)",
                tostring(self.tag), tostring(session.pid))) end
        end)
    end
    if session then
        if nonblocking and session.terminate then
            pcall(function() session:terminate() end)
        else
            pcall(function() session:close() end)
        end
    end
end

--- 懒加载内存守卫 (拿不到就当没有: 纯逻辑测试里不该因为它炸)
function Transport:_memory_guard()
    if self._mg_loaded == nil then
        local ok, mod = pcall(require, "util.memory_guard")
        self._mg = ok and type(mod) == "table" and mod or false
        self._mg_loaded = true
    end
    return self._mg or nil
end

--- fork 之前的内存闸门
--
-- 返回 false 表示"这次别 fork" (调用方退回进程内下载), 第二个返回值是原因。
-- 子进程是 fork 出来的整份进程副本, 自己还要解 TLS/写盘/跑源的图片后处理,
-- 真机实测增量 10~25MB。可用内存已经见底时再 fork, 内核会先杀子进程
-- (crash.log 里的"下载子进程意外退出"), 再往下就是整机重启。
function Transport:_fork_allowed()
    local MG = self:_memory_guard()
    if not MG then return true end

    local ok, allowed, avail = pcall(function() return MG.instance():fork_allowed() end)
    if not ok or avail == nil then return true end      -- 读不到内存 (非 Linux): 不拦

    -- 诊断: fork 是整条链上唯一会"复制一份进程"的动作, 这一行让事后能对着
    -- 崩溃时间点看内存 (Diag.mark 自带 flush, 被 SIGKILL 也不丢)。
    pcall(function()
        if Diag.enabled then Diag.snapshot(string.format("fork 前 (可用 %.0fMB)", avail)) end
    end)

    if not allowed then
        return false, string.format("可用内存仅 %.0fMB", avail)
    end
    return true
end

--- 懒建子进程 (只在真的要发第一个任务时 fork)
function Transport:_ensure_session()
    if self.session then return self.session end
    if self.worker_error then return nil, self.worker_error end

    -- 内存见底时不 fork: 返回 nil 让调用方走 fallback, 但**不设 worker_error**
    -- (那是一次性的环境问题, 下一张图内存回来了就该重新允许 fork)。
    local allowed, why = self:_fork_allowed()
    if not allowed then
        logger.warn("Picayomi Transport: " .. tostring(why) .. ", 这次不 fork, 改用进程内下载")
        return nil, why
    end

    local Worker = require("network.reader_worker")
    local session, err
    if self.subprocess.spawnWorker then
        session, err = self.subprocess.spawnWorker("reader", { async = self.async })
    else
        session, err = self.subprocess.spawn(function(s)
            Worker.loop(s, { async = self.async })
        end)
    end
    if not session then
        self.worker_error = tostring(err or "无法创建下载子进程")
        logger.warn("Picayomi Transport: 起下载子进程失败, 回退到同步下载: "
            .. self.worker_error)
        return nil, self.worker_error
    end

    self.session = session
    if logger.enabled then logger.info("Picayomi Transport[" .. tostring(self.tag) .. "]: 下载子进程已启动 (pid="
        .. tostring(session.pid) .. ")") end
    return session
end

----------------------------------------------------------------------------
-- 发起
----------------------------------------------------------------------------

--- 取这一页的请求头 (父进程现算)
function Transport:_headers_for(job)
    if not job.url then return nil, "缺少图片地址" end
    local source = self.source
    if not (source and source.imageHeaders) then
        return nil, "源未实现 imageHeaders"
    end
    local ok, headers, err = pcall(source.imageHeaders, source, job.url)
    if not ok then return nil, tostring(headers) end
    if type(headers) ~= "table" then return nil, err or "请求头构造失败" end
    return headers
end

--- 取这一页的后处理描述符 (可选; 例如源 B 的分带解扰)
function Transport:_post_for(job)
    local source = self.source
    if not (source and source.imagePost and job.url) then return nil end
    local ok, post = pcall(source.imagePost, source, job.url)
    if ok and type(post) == "table" then return post end
    return nil
end

--- 交给同步实现 (本源不支持 worker / 子进程起不来)
function Transport:_to_fallback(job, why)
    if not self.fallback then
        self.ready[#self.ready + 1] = {
            page = job.page, ok = false, err = tostring(why),
        }
        return false
    end
    self.fallback:start(job)
    self.fallback_jobs[job.page]=true
    return true
end

--- 发起一个任务
function Transport:_dispatch(job)
    local request,herr
    if self.source and self.source._source_runtime then
        request,herr=require("source.image_request").prepare(self.source,job)
    else
        local headers; headers,herr=self:_headers_for(job)
        if headers then request={url=job.url,headers=headers,post=self:_post_for(job),timeout=self.timeout} end
    end
    local headers=request and request.headers
    if not headers then
        if type(herr)=="table" then
            self.ready[#self.ready+1]={page=job.page,ok=false,err=herr.message,code=herr.code,retryable=herr.retryable}
            return false
        end
        return self:_to_fallback(job, herr)
    end

    local session, serr = self:_ensure_session()
    if not session then
        return self:_to_fallback(job, serr)
    end

    -- 诊断: 这一行才是"什么时候真的开始下这一页"的唯一证据。
    -- 只有完成时间 ("page N ok") 的话, 分不清"下载慢"和"调度器迟迟没发起" ——
    -- 真机上这两者的修法完全不同。
    pcall(function()
        if Diag.enabled then Diag.mark(string.format("start p%s%d%s",
            self.tag == "cover" and "c" or self.tag == "offline" and "d" or "", job.page,
            self.tag == "cover" and " (封面)" or self.tag == "offline" and " (离线下载)" or "")) end
    end)

    self.next_token = self.next_token + 1
    local token = self.next_token
    local ok, werr = session:send{
        "job", job.page, request.url, job.dest,
        headers, request.post, math.min(request.timeout or self.timeout,self.timeout), token,
    }
    if not ok then
        -- 管道坏了: 丢掉这个子进程, 本次退回同步实现
        self:_drop_session()
        return self:_to_fallback(job, werr)
    end

    self.inflight[job.page] = { dest = job.dest, started = socket.gettime(), token = token }
    return true
end

----------------------------------------------------------------------------
-- 收割
----------------------------------------------------------------------------

--- 把一条子进程回复转成调度器要的 done 条目
function Transport:_settle(msg)
    local page, ok, path, size, err, elapsed, post =
        msg[2], msg[3], msg[4], msg[5], msg[6], msg[7], msg[8]
    local f = self.inflight[page]
    -- 过期的回复 (任务已被取消/已被判失败) 直接丢弃
    if not f or f.token ~= msg[9] then return nil end
    self.inflight[page] = nil

    local item = { page = page, ok = ok and true or false,code=msg[10],retryable=msg[11] }
    -- 耗时优先用子进程自报的: 父进程"多久才来 poll 一次"不该算进下载耗时,
    -- 否则界面忙一下就会被误判成"慢链路"从而误停预取。
    item.elapsed = tonumber(elapsed) or (socket.gettime() - f.started)
    -- 后处理耗时 (源侧解扰/转码); 旧版子进程没有这个字段, 缺失时就是 0
    item.post = tonumber(post)

    if item.ok then
        item.path = path or f.dest
        if self.fix_extension then
            item.path = self.fix_extension(item.path) or item.path
        end
        item.size = size
    else
        item.err = err or "下载失败"
        os.remove(f.dest)          -- 与同步实现一致: 失败不留残file
    end
    return item
end

--- 收子进程的帧; 顺便发现"子进程意外死亡"
--
-- 单次最多收**一条** —— 与调度器的 max_harvest_per_step 对称, 保证主线程占用有界。
function Transport:_drain(done, block)
    local session = self.session
    if not session then return end

    if #done == 0 then
        local msg = block and session:recv() or session:try_recv()
        if msg then
            local item = self:_settle(msg)
            if item then done[#done + 1] = item end
        end
    end

    -- 先把管道收干净再问存活 —— 子进程可能"写完结果才退出"。
    if next(self.inflight) ~= nil and not session:alive() then
        -- 子进程猝死: **所有**在途任务一起判失败 (以前只有一个, 现在可能两个)
        self:_drop_session()       -- 下次懒重建 (worker_error 不设, 允许重试)
        for page in pairs(self.inflight) do
            done[#done + 1] = {
                page = page, ok = false, err = "下载子进程意外退出",
            }
        end
        self.inflight = {}
    end
end

--- 收一个任务
--
-- @param budget_ms 预留的 CPU 毫秒上限 (本实现用不到: 收帧是 ioctl + read)
-- @param block     true 表示"同步语义": 发起后等到这一条真的有结果才返回
-- @return { done = { item, ... }, idle = bool }
function Transport:poll(budget_ms, block)
    local done = {}
    if self.cancelled then return { done = done, idle = true } end

    -- 1) 之前判定失败的 (没有 fallback 时)
    if #self.ready > 0 then
        done[1] = table.remove(self.ready, 1)
        return { done = done, idle = not self:busy() }
    end

    -- 2) 子进程的回复 (非阻塞; 最多一条)
    self:_drain(done)

    -- 3) 发起下一个 (有空位就发, 最多 max_inflight 条)
    while #self.pending > 0 and self:_inflight_count() < self.max_inflight do
        local before = self:_inflight_count()
        self:_dispatch(table.remove(self.pending, 1))
        if self:_inflight_count() == before then break end   -- 退回到同步实现
    end
    if next(self.inflight) ~= nil and #done == 0 then
        -- 刚发出去: 同步语义要等到结果才返回;
        -- 非同步语义也顺手收一次 —— 子进程往往还没回, 收不到就是收不到,
        -- 代价只有一次 ioctl (但"瞬间就绪"的情况能省掉一整拍)。
        self:_drain(done, block)
    end

    -- 4) 同步实现的回复 (它自己会阻塞, 一次只处理一个)
    if #done == 0 and self.fallback then
        local res = self.fallback:poll(budget_ms)
        for _i, item in ipairs(res.done or {}) do
            self.fallback_jobs[item.page]=nil
            done[#done + 1] = item
            break
        end
    end

    return { done = done, idle = not self:busy() }
end

--- Cancel one asynchronous request. FIFO pipe ordering puts cancellation before
-- a replacement job; generation tokens reject replies already in the pipe.
function Transport:cancel(page)
    for i, job in ipairs(self.pending) do
        if job.page == page then
            table.remove(self.pending, i)
            return true
        end
    end
    local f = self.inflight[page]
    if not self.async or not f or not self.session then return false end
    local ok = self.session:send{ "cancel", page, f.token }
    if not ok then return false end
    self.inflight[page] = nil
    pcall(function()
        if Diag.enabled then Diag.mark(string.format("cancel %s p%d token%d",
            tostring(self.tag), page, f.token)) end
    end)
    return true
end

--- 取消一切 (关文档 / 换章)
--
-- 子进程直接杀掉, 下次要下载时懒重建 —— 不用"发 quit 再等它自己退",
-- 因为此刻可能正卡在一个 15 秒的 DNS 解析里。
--
-- @param nonblocking true = 杀掉但**不等待**它被回收。只给"进程正在退出"的路径用
--        (见 Fork:terminate 与 StreamSession:shutdown): 那条路上阻塞等一个卡在
--        DNS 里的子进程, 本身就是"退出卡顿"。
function Transport:cancel_all(nonblocking)
    self.cancelled = true
    self.pending = {}
    self.inflight = {}
    self.ready = {}
    self.fallback_jobs = {}
    if self.unwatch then self.unwatch();self.unwatch=nil end
    if self.fallback then
        pcall(function() self.fallback:cancel_all() end)
    end
    self:_drop_session(nonblocking)
end

function Transport:invalidate()
    if self.cancelled or self.invalidated then return end
    local ready={}
    for _,job in ipairs(self.pending) do ready[#ready+1]={page=job.page,ok=false,err="登录状态已改变",code="cancelled",retryable=false} end
    for page in pairs(self.inflight) do ready[#ready+1]={page=page,ok=false,err="登录状态已改变",code="cancelled",retryable=false} end
    for page in pairs(self.fallback_jobs) do ready[#ready+1]={page=page,ok=false,err="登录状态已改变",code="cancelled",retryable=false} end
    self:cancel_all()
    self.cancelled=false;self.invalidated=true;self.ready=ready
end

--- 同 cancel_all, 但明确要求"不等待" —— 给 main.lua 的退出钩子用
--
-- 单列一个名字而不是让调用方传 true: 退出路径上"不阻塞"是**语义要求**, 不是优化;
-- 名字写出来才不会有人在别处顺手复用。
function Transport:terminate()
    self:cancel_all(true)
end

function Transport:close()
    self:cancel_all()
    self.source = nil
end

--- 供上层判断"是否已经取消"
function Transport:is_cancelled()
    return self.cancelled
end

return Transport
