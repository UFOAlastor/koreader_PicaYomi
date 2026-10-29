-- util/cover_cache.lua
-- 封面缩略图缓存: 统一路径规则 + 异步下载去重 + **不阻塞主线程**
--
-- 列表页与详情页都需要"先显示文本, 再异步补封面", 此前各自复制了一份
-- 路径拼接与下载逻辑。这里集中一处, 供所有页面复用。
--
-- 为什么封面也必须走 fork worker (2026-10 性能审计):
--   改造前这里是把 `source:downloadImage(...)` 包在 `UIManager:scheduleIn(0.1, ...)`
--   里 —— 只是把下载**推迟**了一下, 下载本身仍是**主线程同步 HTTP**(含 DNS/TLS)。
--   列表页一屏 6 条 + 预取一屏, 逐张串行, 慢网下每张几百 ms 到数秒, 这段时间里
--   点击/翻页完全收不到。阅读页已经用 fork worker 解决了同一类问题, 封面这条链漏了。
--
--   现在它复用同一套通道 (network/transport_worker.lua):
--     * 真正的 HTTP + DNS + 源侧后处理都在**子进程**里;
--     * 主线程每 TICK 只做一次 ioctl + read (收帧) 和一次 write (派活), 不阻塞。
--
-- 通道是共享的：整进程一个图片 worker，最多两路下载，减少单张慢图的阻塞。
-- 阅读时暂停，退出阅读后恢复；平时空闲五秒后关闭，避免每张封面重新 fork。

local logger = require("util.logger")
local UIManager = require("ui/uimanager")

local Cache = require("util.cache")
local DownloadManager = require("network.download_manager")
local TransportWorker = require("network.transport_worker")
local Diag = require("util.diag")

local CoverCache = {}

-- 驱动 tick 的最小延迟 (秒)。**必须 > 0** —— 见 ui/reader_bridge.lua 文件头:
-- scheduleIn(0)/nextTick 自排会让 UIManager:handleInput 的
-- `repeat ... until not _task_queue_dirty` 永不退出, 从而彻底饿死输入。
local TICK = 0.05

-- 单张封面的下载超时 (秒)。
--
-- 比阅读页 (20s) 短：封面是缩略图，两路下载也不让失效图片长时间占住通道。
-- 现在超时期间界面照常响应, 所以这里取的是"别让一张破图占着通道太久"。
local COVER_TIMEOUT = 8

-- 单步允许占用的 CPU 毫秒上限 (预留给 transport 的 poll)
local BUDGET_MS = 25

-- 正在下载的封面: base_path -> { callbacks = { fn, ... } }
-- 与通道无关地保留在这里: 通道空闲会被关掉重建, 去重状态不能跟着一起丢。
local inflight = {}

-- 共享下载通道: { source =, transport =, jobs = { id -> { dest, finish } }, next_id =, driving = }
local channel = nil
local pauses = {}
local release_channel

-- Unsubscribe a page without cancelling other pages waiting for the same file.
local function unsubscribe(base,callback,expected)
    return function()
        local entry=inflight[base]
        if not entry or entry~=expected or not callback then return end
        for i=#entry.callbacks,1,-1 do
            if entry.callbacks[i]==callback then table.remove(entry.callbacks,i) end
        end
        if #entry.callbacks==0 and entry.channel then
            local ch=entry.channel
            ch.jobs[entry.id]=nil
            inflight[base]=nil
            if ch.transport then pcall(ch.transport.cancel,ch.transport,entry.id) end
            if next(ch.jobs)==nil then release_channel(ch) end
        end
    end
end

local function new_transport(source)
    return TransportWorker.new{source=source,fix_extension=function(path)
        return DownloadManager.fixImageExtension(path)
    end,timeout=COVER_TIMEOUT,tag="cover",max_inflight=2,async=true}
end

local function safeName(value)
    value = tostring(value or "unknown")
    return (value:gsub("[^%w%._%-]", "_"))
end

--- 封面缓存的基路径 (不含扩展名)
function CoverCache.basePath(source_id, comic_id)
    return Cache.COVER_CACHE_DIR .. "/" .. safeName(source_id) .. "_" .. safeName(comic_id)
end

--- 查找已缓存的封面文件
function CoverCache.find(source_id, comic_id)
    if not comic_id then return nil end
    return DownloadManager.findExistingImage(CoverCache.basePath(source_id, comic_id))
end

----------------------------------------------------------------------------
-- 共享通道
----------------------------------------------------------------------------

--- 墙钟 (秒)
local function now()
    local ok, socket = pcall(require, "socket")
    if ok and type(socket) == "table" and socket.gettime then
        return socket.gettime()
    end
    return os.time()
end

--- 空闲多久之后才真的关掉通道 (秒)
--
-- 不能"一空闲就关": 列表是一张一张补封面的 —— 上一张完成、下一张还没入队的
-- 那个空档里 transport:busy() 就是 false。立刻关的话**每张封面都会重新 fork**,
-- 真机一屏十几张 = 十几次 fork (2026-10-18 实测: 12 张封面 spawn 10 次)。
-- 等一小段确实没有新任务再关; 期间有新任务就把定时器撤掉。
local IDLE_CLOSE_DELAY = 5

-- 前向声明: schedule_idle_close 里要调用它, 而它定义在后面。
-- 不声明的话那里解析成**全局** release_channel (nil), 定时器真到点时才炸 ——
-- 而且是在事件循环里炸, 通道从此再也不关。
local pump
local kick

local function schedule_pump(ch)
    local transport=ch.transport
    if ch.pump_task then UIManager:unschedule(ch.pump_task)end
    local task
    task=function()
        if ch.pump_task==task then ch.pump_task=nil end
        if ch.transport==transport and channel==ch then pump(ch) end
    end
    ch.pump_task=task
    UIManager:scheduleIn(TICK,task)
end

--- 排一次"稍后再关"。到点时若又有了活动, 就再等一轮 (不能直接放弃,
--- 否则通道再也不会被关掉)。
local function schedule_idle_close(ch)
    if ch.idle_task then return end
    ch.idle_task = function()
        ch.idle_task = nil
        if channel ~= ch then return end
        if ch.transport and ch.transport:busy() then
            -- 有活却没人推: 列表在"任务已入队、还没发出去"的瞬间被关掉时会出现
            -- (队列停了, 但没有在跑的 pump)。不补这一拍的话通道会永远"忙" ——
            -- 既不会继续下, 也永远不会被关掉, 子进程就这么常驻下去。
            if not ch.driving then kick(ch) end
            return
        end
        if next(ch.jobs) ~= nil then return end
        if now() - (ch.last_activity or 0) < IDLE_CLOSE_DELAY then
            schedule_idle_close(ch)
            return
        end
        release_channel(ch)
    end
    UIManager:scheduleIn(IDLE_CLOSE_DELAY, ch.idle_task)
end

--- 关掉通道 (释放 fork 子进程)。
--
-- **释放通道必须把在途任务全部回调掉**: ch.jobs 里的每一条都对应 inflight[base]
-- 的一个条目, 而 finish 是唯一清它的地方。若只 close transport 不管 jobs,
-- 那些条目会**永久**留在 inflight 里 —— 之后对同一张封面再 ensure 只会命中这个
-- 死条目、追加回调后返回, 那张封面从此再也加载不出来 (且没有任何报错)。
--
-- 三条释放路径 (空闲 / 通道异常 / 换源) 都收敛到这里, 所以保证只在这里 drain 一次。
--
-- 注意这里**不因"ch 已不是当前通道"就提前 return**: 极端情况下 (回调里又调了 ensure,
-- 把 channel 换成了新的) 被释放的那个 ch 依然是活的 transport + 挂着 job, 提前 return
-- 会让它的子进程和 inflight 条目都漏掉。只有"把 channel 置空"这一步才需要判等。
function release_channel(ch)
    if channel == ch then channel = nil end
    if ch.pump_task then UIManager:unschedule(ch.pump_task);ch.pump_task=nil end
    if ch.idle_task then
        pcall(function() UIManager:unschedule(ch.idle_task) end)
        ch.idle_task = nil
    end
    local jobs = ch.jobs
    ch.jobs = {}
    if ch.transport then pcall(function() ch.transport:close() end) end
    for _id, job in pairs(jobs) do
        pcall(job.finish, nil)
    end
end

--- 取/建通道。**换源时重建** —— 通道里的 transport 绑定着 source
--- (imageHeaders / imagePost 都取自它), 复用会让新源的图带着旧源的请求头。
local function get_channel(source)
    if channel and channel.source == source then return channel end
    if channel then release_channel(channel) end

    channel = {
        source = source,
        next_id = 0,
        jobs = {},
        driving = false,
        transport = next(pauses)==nil and new_transport(source) or nil,
    }
    return channel
end

--- 收一步: 收割完成的任务 -> 回调; 还有活就排下一拍
function pump(ch)
    if next(pauses) or not ch.transport then ch.driving=false; return end
    ch.driving = false

    -- 必须 pcall 兜住整段: 这里抛异常的话, ch.jobs 里挂着的条目永远不会被释放,
    -- 于是那张封面 (连同它挂着的回调闭包) **永久**留在 inflight 里 ——
    -- 之后每次对它调 ensure 都只会往那个死条目上追加回调, 这张封面再也加载不出来。
    -- (回归: test/regression_robustness.lua 第 5.2 节; drain 收在 release_channel 里)
    local ok, res = pcall(ch.transport.poll, ch.transport, BUDGET_MS)
    if not ok then
        logger.warn("Picayomi CoverCache: 封面下载通道异常, 已重建: " .. tostring(res))
        release_channel(ch)
        return
    end

    if #(res.done or {}) > 0 then ch.last_activity = now() end

    for _i, item in ipairs(res.done or {}) do
        local job = ch.jobs[item.page]
        ch.jobs[item.page] = nil
        if job then
            if Diag.enabled then
                Diag.mark(string.format("cover source=%s ok=%s elapsed=%.2fs bytes=%d",
                    tostring(ch.source and ch.source.identifier or "unknown"),tostring(item.ok),
                    tonumber(item.elapsed) or 0,tonumber(item.size) or 0))
            end
            if item.ok then
                pcall(job.finish, item.path)
            else
                logger.warn("Picayomi CoverCache: 封面下载失败 " ..
                    tostring(job.title) .. ": " .. tostring(item.err))
                pcall(job.finish, nil)
            end
        end
    end

    if next(pauses) or not ch.transport then return end
    if res.idle then
        -- 空闲就准备关掉通道: fork 出来的子进程不该常驻。
        -- 用户补完一屏封面后可能马上进阅读页, 那时列表页的下载子进程若还在,
        -- 就是"阅读时多一个进程抢内存" —— 真机 OOM 排查里踩过这一类。
        -- 但**不能立刻关** (会变成每张封面一次 fork), 见 schedule_idle_close。
        schedule_idle_close(ch)
    else
        ch.driving = true
        schedule_pump(ch)
    end
end

function kick(ch)
    if next(pauses) or not ch.transport then return end
    if ch.driving then return end
    ch.driving = true
    schedule_pump(ch)
end

-- Keep callbacks and queued requests, but release the background process
-- before foreground reading forks/decodes. Tokens cover overlapping chapters.
function CoverCache.pause()
    local token={}
    local first=next(pauses)==nil
    pauses[token]=true
    if first and channel then
        local ch=channel
        if ch.pump_task then UIManager:unschedule(ch.pump_task);ch.pump_task=nil end
        if ch.idle_task then UIManager:unschedule(ch.idle_task);ch.idle_task=nil end
        if ch.transport then ch.transport:close();ch.transport=nil end
        ch.driving=false
    end
    local released=false
    return function()
        if released then return end
        released=true
        if not pauses[token]then return end
        pauses[token]=nil
        local ch=channel
        if next(pauses) or not ch then return end
        if not next(ch.jobs) then release_channel(ch);return end
        ch.transport=new_transport(ch.source)
        local ids={}
        for id in pairs(ch.jobs) do ids[#ids+1]=id end
        table.sort(ids)
        for _,id in ipairs(ids) do ch.transport:start(ch.jobs[id].request) end
        kick(ch)
    end
end

-- Plugin exit abandons subscribers, not cached files. Do not wake closed pages.
function CoverCache.shutdown()
    local ch=channel
    channel=nil;inflight={};pauses={}
    if not ch then return end
    for _,key in ipairs{"pump_task","idle_task"}do
        if ch[key] then UIManager:unschedule(ch[key]);ch[key]=nil end
    end
    ch.jobs={};ch.driving=false
    local transport=ch.transport;ch.transport=nil
    if transport then
        if transport.terminate then transport:terminate()
        elseif transport.cancel_all then transport:cancel_all(true)
        else transport:close()end
    end
end

----------------------------------------------------------------------------
-- 对外接口
----------------------------------------------------------------------------

--- 异步确保封面存在
-- 已缓存时同步回调; 否则交给共享通道下载, 完成后回调 (在后续 tick 里)。
-- 同一封面并发请求只下载一次。
--
-- **立刻返回**: 下载发生在 fork 出来的子进程里, 主线程不会在 HTTP/DNS 上卡住。
--
-- @param source      漫画源 (需有 imageHeaders; 没有则自动退回同步实现)
-- @param source_id   源标识
-- @param comic       漫画对象 (需有 _id 与 thumb)
-- @param on_done     function(path_or_nil)
function CoverCache.ensure(source, source_id, comic, on_done)
    if not comic or not comic._id then
        if on_done then on_done(nil) end
        return
    end

    local existing = CoverCache.find(source_id, comic._id)
    if existing then
        if on_done then on_done(existing) end
        return
    end

    if not source or not comic.thumb or comic.thumb == "" then
        if on_done then on_done(nil) end
        return
    end

    local base = CoverCache.basePath(source_id, comic._id)

    -- 去重: 同一封面已在下载中, 只登记回调
    local pending = inflight[base]
    if pending then
        if on_done then table.insert(pending.callbacks, on_done) end
        return unsubscribe(base,on_done,pending)
    end

    local entry={ callbacks = on_done and { on_done } or {} }
    inflight[base] = entry

    local ch = get_channel(source)
    ch.next_id = ch.next_id + 1
    local id = ch.next_id
    inflight[base].channel=ch
    inflight[base].id=id

    ch.jobs[id] = {
        title = comic.title,
        request = {page=id,url=comic.thumb,dest=base..".jpg"},
        -- finish 是唯一会清 inflight[base] 的地方, 所以它必须在**每一条**路径上
        -- 被调用一次 (成功 / 失败 / 通道异常)。
        finish = function(path)
            if inflight[base]~=entry then return end
            inflight[base] = nil
            for _idx, cb in ipairs(entry and entry.callbacks or {}) do
                pcall(cb, path)
            end
        end,
    }

    ch.last_activity = now()
    if ch.idle_task then
        pcall(function() UIManager:unschedule(ch.idle_task) end)
        ch.idle_task = nil
    end
    if ch.transport then ch.transport:start(ch.jobs[id].request) end
    kick(ch)
    return unsubscribe(base,on_done,entry)
end

return CoverCache
