-- Cooperative UI tasks. Only HTTP crosses the process boundary; parsing,
-- source cookies and configuration changes stay in the parent process.
local Async = {}
local tasks = setmetatable({}, { __mode = "k" })
local in_worker = false
Async.TICK = 0.05
Async.TIMEOUT = 90
Async.MAX_RESULT = 8 * 1024 * 1024

function Async.active()
    local co = coroutine.running()
    return not in_worker and co and tasks[co] ~= nil
end

-- Yield a continuation without sleeping the UI thread or starting a worker.
function Async.wait(seconds)
    assert(Async.active(),"等待需要后台任务")
    assert(type(seconds)=="number" and seconds>=0 and seconds<=300,"无效的等待时间")
    if seconds==0 then return end
    local ok,err=coroutine.yield({wait=seconds})
    if not ok then error(err,0)end
end

function Async.await(fn, request)
    if not Async.active() then return fn() end
    local ok, value, err = coroutine.yield(request and { fetch = fn, request = request } or fn)
    if not ok then error(value, 0) end
    return value, err
end

function Async.cancelAll(nonblocking)
    local pending = {}
    for _, task in pairs(tasks) do pending[#pending + 1] = task end
    for _, task in ipairs(pending) do
        task.nonblocking = nonblocking
        task:cancel()
    end
end

function Async.run(fn, opts)
    opts = opts or {}
    local UIManager = require("ui/uimanager")
    local socket = require("socket")
    local buffer = require("string.buffer")
    local Fork = opts.subprocess or require("network.subprocess_fork")
    local task = { done = false }
    -- The worker watchdog below is per request. This optional budget spans all
    -- requests/retries in the continuation, including source fallbacks.
    local deadline=opts.timeout and socket.gettime()+opts.timeout
    local co
    local function safe_callback(cb, ...)
        if not cb then return end
        local ok, err = pcall(cb, ...)
        if not ok then require("util.logger").warn("Picayomi async callback: " .. tostring(err)) end
    end
    local function release(keep_session)
        if task.poll then UIManager:unschedule(task.poll) end
        if task.wait_timer then UIManager:unschedule(task.wait_timer);task.wait_timer=nil end
        if task.session and not keep_session then
            pcall(function()
                if task.nonblocking and task.session.terminate then task.session:terminate()
                else task.session:close() end
            end)
            task.session = nil
        end
        task.chunks = nil
    end
    local function finish()
        if task.done then return end
        task.done = true
        tasks[co] = nil
        release()
        -- A cancelled coroutine is still suspended, retaining its source and
        -- page stack. Drop it even if the owning page keeps the task handle.
        co = nil
    end
    function task:cancel()
        if self.done then return end
        finish()
        safe_callback(opts.on_cancel)
    end
    local resume
    local function fail(err)
        finish()
        safe_callback(opts.on_error, tostring(err))
    end
    local function start(fetch)
        local request
        if type(fetch) == "table" then request, fetch = fetch.request, fetch.fetch end
        -- A failed fork must not silently turn a background operation into
        -- blocking network I/O on a low-memory device.
        if not opts.subprocess then
            local MG = require("util.memory_guard")
            local allowed = MG.instance():fork_allowed()
            if not allowed then
                resume(false, "可用内存不足，请稍后重试")
                return
            end
        end
        task.chunks, task.bytes = {}, 0
        task.started = socket.gettime()
        local session, err
        if request and opts.reuse_worker and not opts.subprocess then
            if task.session then
                local ok,why=task.session:send({request=request})
                if ok then session=task.session else err=why end
            else session,err=Fork.spawnWorker("novel",request) end
            task.persistent_session=true
        elseif request and not opts.subprocess and require("ffi").os == "OSX" then
            session, err = Fork.spawnWorker("request", request)
        else
            session, err = Fork.spawn(function(child)
                require("network.background_worker").reply(child, function()
                    local previous_worker = in_worker
                    in_worker = true
                    local ok, value, reason = pcall(fetch)
                    in_worker = previous_worker
                    if not ok then error(value, 0) end
                    return value, reason
                end, Async.MAX_RESULT)
            end)
        end
        if not session then
            resume(false, err or "无法启动后台请求")
            return
        end
        task.session = session
        UIManager:scheduleIn(Async.TICK, task.poll)
    end
    task.poll = function()
        if task.done then return end
        local ok, err = pcall(function()
            if opts.is_cancelled and opts.is_cancelled() then task:cancel(); return end
            if deadline and socket.gettime()>=deadline then fail("加载超时，请重试"); return end
            local frame = task.session:try_recv()
            if frame then
                if frame.error then fail(frame.error); return end
                assert(type(frame.chunk) == "string", "后台响应格式错误")
                task.bytes = task.bytes + #frame.chunk
                assert(task.bytes <= Async.MAX_RESULT, "后台响应过大")
                task.chunks[#task.chunks + 1] = frame.chunk
                if frame.last then
                    local result = buffer.decode(table.concat(task.chunks))
                    release(task.persistent_session)
                    resume(result.ok, result.value, result.err)
                    return
                end
                assert(task.session:send({ ack = true }))
            elseif not task.session:alive() then
                fail("后台请求意外退出，请重试")
                return
            end
            if socket.gettime() - task.started >= Async.TIMEOUT then
                fail("请求超时，请重试")
                return
            end
            UIManager:scheduleIn(Async.TICK, task.poll)
        end)
        if not ok then fail(err) end
    end
    co = coroutine.create(fn)
    tasks[co] = task
    resume = function(...)
        if task.done then return end
        if deadline and socket.gettime()>=deadline then fail("加载超时，请重试"); return end
        local ok, yielded = coroutine.resume(co, ...)
        if task.done then return end
        if not ok then fail(yielded); return end
        if coroutine.status(co) == "dead" then finish(); return end
        if type(yielded)=="table" and type(yielded.wait)=="number" then
            task.wait_timer=function()
                task.wait_timer=nil
                if task.done then return end
                if opts.is_cancelled and opts.is_cancelled()then task:cancel();return end
                resume(true)
            end
            UIManager:scheduleIn(math.max(0,math.min(yielded.wait,deadline and deadline-socket.gettime()or yielded.wait)),task.wait_timer)
            return
        end
        if type(yielded) ~= "function" and not (type(yielded) == "table"
            and type(yielded.fetch) == "function" and type(yielded.request) == "table") then
            fail("无效的后台任务"); return
        end
        local started, err = pcall(start, yielded)
        if not started then fail(err) end
    end
    if opts.is_cancelled and opts.is_cancelled() then task:cancel()
    else resume() end
    return task
end

return Async
