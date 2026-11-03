-- Cooperative UI tasks. Only HTTP crosses the process boundary; parsing,
-- source cookies and configuration changes stay in the parent process.
local Async = {}
local tasks = setmetatable({}, { __mode = "k" })
local in_worker = false
Async.TICK = 0.05
Async.MAX_IDLE_TICK = 0.25
Async.TIMEOUT = 90
Async.MAX_RESULT = 8 * 1024 * 1024

function Async.active()
    local co = coroutine.running()
    return not in_worker and co and tasks[co] ~= nil
end

-- A persistent HTTP worker can retain TLS/connection memory while its owner
-- decodes an illustration. Never touch another task or an in-flight response.
function Async.releaseIdleWorker()
    local task=tasks[coroutine.running()]
    return task and not task.done and task._release_idle and task._release_idle()or false
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
    local task = { done = false, session=opts.session, subprocess=opts.subprocess }
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
        local released=true
        if task.poll then UIManager:unschedule(task.poll) end
        if task.wait_timer then UIManager:unschedule(task.wait_timer);task.wait_timer=nil end
        if task.join_cleanup then task.join_cleanup()end
        if task.session and not keep_session then
            released=pcall(function()
                if task.nonblocking and task.session.terminate then
                    local pid=task.session.pid
                    task.session:terminate()
                    if pid then
                        local util=require('ffi/util')
                        local function reap()
                            if not util.isSubProcessDone(pid)then UIManager:scheduleIn(.05,reap)end
                        end
                        -- Keep only the PID, never the cancelled coroutine or
                        -- its source/document. WNOHANG never stalls the UI.
                        reap()
                    end
                else task.session:close() end
            end)
            task.session = nil
        end
        task.chunks = nil
        return released
    end
    task._release_idle=function()
        if task.done or not task.persistent_session or not task.session or task.chunks~=nil
            or type(task.session.terminate)~='function'then return false end
        local previous=task.nonblocking;task.nonblocking=true
        local released=release()
        task.nonblocking=previous;task.persistent_session=nil
        return released
    end
    local function finish(callback,...)
        if task.done then return end
        task.done = true
        tasks[co] = nil
        for child in pairs(task.children or {})do
            child.nonblocking=true;child:cancel()
        end
        task.children=nil
        release()
        -- A cancelled coroutine is still suspended, retaining its source and
        -- page stack. Drop it even if the owning page keeps the task handle.
        co = nil
        task._release_idle=nil
        safe_callback(callback,...)
        local notify=task._on_done;task._on_done=nil
        safe_callback(notify)
    end
    function task:cancel()
        if self.done then return end
        finish(opts.on_cancel)
    end
    local resume
    local function fail(err)
        finish(opts.on_error,tostring(err))
    end
    local function schedule_poll()
        local now=socket.gettime()
        local remaining=math.max(0,task.started+Async.TIMEOUT-now)
        if deadline then remaining=math.min(remaining,math.max(0,deadline-now))end
        UIManager:scheduleIn(math.min(task.poll_delay,remaining),task.poll)
    end
    local function start(fetch)
        local request
        if type(fetch) == "table" then request, fetch = fetch.request, fetch.fetch end
        -- A failed fork must not silently turn a background operation into
        -- blocking network I/O on a low-memory device.
        if not opts.subprocess and not (request and opts.reuse_worker and task.session) then
            local MG = require("util.memory_guard")
            local allowed
            if opts.admit then allowed=opts.admit() else allowed=MG.instance():fork_allowed() end
            if not allowed then
                resume(false, "可用内存不足，请稍后重试")
                return
            end
        end
        task.chunks, task.bytes = {}, 0
        task.started = socket.gettime()
        task.poll_delay = Async.TICK
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
        schedule_poll()
    end
    task.poll = function()
        if task.done then return end
        local ok, err = pcall(function()
            if opts.is_cancelled and opts.is_cancelled() then task:cancel(); return end
            if deadline and socket.gettime()>=deadline then fail("加载超时，请重试"); return end
            local frame = task.session:try_recv()
            if frame then
                task.poll_delay=Async.TICK
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
            else
                task.poll_delay=math.min(Async.MAX_IDLE_TICK,task.poll_delay*2)
            end
            if socket.gettime() - task.started >= Async.TIMEOUT then
                fail("请求超时，请重试")
                return
            end
            schedule_poll()
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
        if type(yielded)=='table' and yielded.join then
            local wake
            local function cleanup()
                for _,child in ipairs(yielded.join)do
                    if child._on_done==wake then child._on_done=nil end
                end
                task.join_cleanup=nil
            end
            local function cancelled()
                if not opts.is_cancelled then return false end
                local success,value=pcall(opts.is_cancelled)
                if not success then fail(value);return true end
                if value then task:cancel();return true end
                return false
            end
            wake=function()
                if task.done or task.join_cleanup~=cleanup or not yielded.ready()then return end
                cleanup()
                if task.wait_timer then UIManager:unschedule(task.wait_timer)end
                local continuation
                continuation=function()
                    if task.done or task.wait_timer~=continuation then return end
                    task.wait_timer=nil
                    if not cancelled()then resume(true)end
                end
                task.wait_timer=continuation
                -- One continuation after completion, never a periodic poll.
                UIManager:scheduleIn(0,task.wait_timer)
            end
            task.join_cleanup=cleanup
            for _,child in ipairs(yielded.join)do child._on_done=wake end
            if deadline or opts.is_cancelled then
                local function watch()
                    if task.done or task.join_cleanup~=cleanup then return end
                    task.wait_timer=nil
                    if cancelled()then return end
                    local delay=deadline and math.max(0,deadline-socket.gettime())or Async.MAX_IDLE_TICK
                    if deadline and delay==0 then fail("加载超时，请重试");return end
                    if opts.is_cancelled then delay=math.min(delay,Async.MAX_IDLE_TICK)end
                    task.wait_timer=watch;UIManager:scheduleIn(delay,watch)
                end
                watch()
            end
            wake()
            return
        end
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

-- Source continuations stay on the UI thread; only their existing await()
-- calls cross a process boundary. Results keep input order, completion may not.
function Async.map(functions,concurrency)
    assert(type(functions)=='table' and #functions<=200,'后台任务数量无效')
    concurrency=math.max(1,math.min(3,math.floor(tonumber(concurrency)or 3),#functions))
    local owner=tasks[coroutine.running()]
    local results={}
    if not owner or concurrency==1 then
        for i,fn in ipairs(functions)do results[i]=fn()end
        return results
    end
    assert(not owner.children,'不能嵌套并行任务')
    local guard=require('util.memory_guard').instance()
    local snapshot=guard:snapshot()
    local borrowed=owner.persistent_session and owner.session
    if snapshot.available then
        local free=math.max(0,snapshot.available-snapshot.reserve)
        concurrency=math.min(concurrency,(borrowed and 1 or 0)+math.floor(free/require('util.memory_guard').WORKER_BYTES))
    end
    if concurrency<=1 then
        for i,fn in ipairs(functions)do results[i]=fn()end
        return results
    end
    owner.children={}
    if borrowed then owner.session=nil end
    local next_index,failure=1,nil
    local children={}
    local function stop(reason)if failure==nil then failure=reason~=nil and reason or '后台任务失败' end end
    for lane=1,concurrency do
        if failure~=nil then break end
        local child=Async.run(function()
            while failure==nil and next_index<=#functions do
                local i=next_index;next_index=i+1
                local ok,value=pcall(functions[i])
                if not ok then stop(value);return end
                results[i]=value
            end
        end,{reuse_worker=true,session=lane==1 and borrowed or nil,subprocess=owner.subprocess,
            on_error=stop})
        children[#children+1]=child;owner.children[child]=true
    end
    local function ready()
        if failure~=nil then return true end
        for _,child in ipairs(children)do if not child.done then return false end end
        return true
    end
    if not ready()then coroutine.yield({join=children,ready=ready})end
    for _,child in ipairs(children)do
        child.nonblocking=true;child:cancel()
    end
    owner.children=nil
    if failure~=nil then error(failure,0)end
    return results
end

return Async
