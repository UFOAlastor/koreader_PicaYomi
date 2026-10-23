-- util/diag.lua
-- 轻量运行时诊断 —— 目的是"真机被系统强杀 (SIGKILL / OOM) 时也能留下证据"。
--
-- 为什么不只用 logger:
--   1) KOReader 的日志有缓冲, 进程被内核 OOM-killer 强杀时最后几行可能丢失;
--   2) 日志里每张图的下载/签名信息量极大, 关键信号会被淹没。
--   因此这里把内存与阅读进度**每条都即时 flush** 写到独立文件:
--     <koreader>/picayomi/diag.log
--   用户只需通过 USB 取这个文件即可, 不必 SSH / dmesg。
--
-- 采样内容: 系统可用内存、主进程与子进程；Linux 定期附加 PSS/私有页。

-- Return before loading samplers, UI or opening files in release builds.
-- A fresh network worker has no screen or UI scheduler. Keep ordinary warning
-- logs, but never initialize UI-dependent sampling inside that process.
local worker = package.loaded["network.background_worker"]
local enabled = require("util.logger").enabled and not (worker and worker.background)
if not enabled then
    local function noop() end
    return { enabled = false, mark = noop, snapshot = noop, header = noop,
        start = noop, stop = noop, set_context = noop }
end

local UIManager = require("ui/uimanager")
local DataStorage = require("datastorage")
local logger = require("util.logger")
local MemoryGuard = require("util.memory_guard")
local ProcessMemory = require("util.process_memory")

local Diag = { enabled = true }

Diag.INTERVAL = 5             -- 采样间隔(秒)
Diag.LOW_AVAIL_MB = 100       -- 可用内存低于此值 -> 告警
Diag.MAX_BYTES = 512 * 1024   -- 文件超过此大小则轮转

-- 退出阅读页之后继续采样的间隔与拍数 (秒 / 拍)
--
-- 真机教训 (2026-10-18): 那次崩溃落在"退出阅读器 108 秒后开下一话"的一瞬间,
-- 而 stop() 一停就再也没有内存读数了 —— 排查只能从 crash.log 里推。
-- 多采两分钟的成本是十几行文本, 换来的是"下次一定看得见"。
Diag.TAIL_INTERVAL = 15
Diag.TAIL_SAMPLES = 8

local fh, timer, context, last_avail = nil, nil, nil, nil
local tail_left = 0
local last_detail = 0

local function dir_path()
    return DataStorage:getDataDir() .. "/picayomi"
end

local function mb(kb)
    if not kb then return "?" end
    return string.format("%.1f", kb / 1024)
end

--- 读 Linux /proc 的内存信息; 模拟器 (macOS) 上返回 nil, 不报错
--
-- /proc/meminfo 的解析收在 util/memory_guard.lua 里 (它才是消费方 —— 阅读页的
-- 内存策略要按可用内存做决定), 这里直接用, 免得两处各解析一遍、判据还不一致。
local function read_mem()
    local info = MemoryGuard.read_meminfo()
    if not info then return nil end

    local sf = io.open("/proc/self/status", "r")
    if sf then
        for line in sf:lines() do
            local v = line:match("^VmRSS:%s+(%d+)")
            if v then info.rss = tonumber(v) break end
        end
        sf:close()
    end
    return info
end

--- DocCache 占用 (MB 文本); 取不到时返回 "?"
--
-- 为什么要记它: 真机上"读几话之后整个界面卡死几分钟"的根因就是这个渲染缓存的
-- 预算 (见 util/memory_guard.lua 的文件头)。没有这一行, 下次只能再猜一遍。
local function doc_cache_stat()
    local ok, DocCache = pcall(require, "document/doccache")
    if not ok or type(DocCache) ~= "table" then return "?" end
    local ok2, used = pcall(function() return DocCache.cache:used_size() end)
    local ok3, total = pcall(function() return DocCache.cache:total_size() end)
    if not ok2 or not ok3 then return "?" end
    return string.format("%s/%sMB", mb(used / 1024), mb(total / 1024))
end

local function stamp()
    return os.date("%m/%d/%y-%H:%M:%S")
end

local function open_file()
    if fh then return true end
    local dir = dir_path()
    local path = dir .. "/diag.log"
    -- 过大则轮转, 保留上一份为 .1
    local rf = io.open(path, "r")
    if rf then
        local sz = rf:seek("end")
        rf:close()
        if sz and sz > Diag.MAX_BYTES then
            os.remove(path .. ".1")
            os.rename(path, path .. ".1")
        end
    end
    fh = io.open(path, "a")
    if not fh then
        os.execute("mkdir -p \"" .. dir .. "\"")
        fh = io.open(path, "a")
    end
    return fh ~= nil
end

local function put(line)
    if not open_file() then return end
    fh:write(line .. "\n")
    fh:flush()          -- 关键: 即时落盘, 被 SIGKILL 也不丢
end

--- 记录一行 (自动加时间戳)
function Diag.mark(msg)
    put(string.format("%s | %s", stamp(), tostring(msg)))
end

--- 采样一次内存并记录
function Diag.snapshot(tag)
    local m = read_mem()
    -- smaps walks page tables: keep it off ordinary 5-second samples. Collect
    -- detailed accounting every 30s, and every 5s while pressure is high.
    local now = os.time()
    local elapsed=now-last_detail
    local detailed = elapsed>=30 or (elapsed>=5 and m and m.avail and m.avail/1024 < Diag.LOW_AVAIL_MB)
    local family = ProcessMemory.snapshot{detailed=detailed}
    if detailed then last_detail=now end
    if family then
        local entries = {}
        for _, p in ipairs(family.processes) do
            entries[#entries+1] = string.format("%d:%s rss=%s pss=%s private=%s footprint=%s",
                p.pid, p.pid==family.processes[1].pid and "main" or "child", mb(p.rss),
                mb(p.pss), mb(p.private), mb(p.footprint))
        end
        put(string.format("%s | Family %s n=%d partial=%s PSS=%sMB Private=%sMB | %s | %s",
            stamp(),family.platform,#family.processes,tostring(family.partial or false),
            mb(family.pss),mb(family.private),table.concat(entries,"; "),tostring(tag or "")))
        if family.others and #family.others>0 then
            local others={}
            for _,p in ipairs(family.others) do
                others[#others+1]=string.format("%d:%s=%sMB",p.pid,
                    (p.name or "?"):gsub("[%c|;]","?"),mb(p.rss))
            end
            put(string.format("%s | Other RSS (shared, not additive) | %s",stamp(),table.concat(others,"; ")))
        end
    end
    if not m then
        put(string.format("%s | system mem n/a | DocCache %s | %s", stamp(), doc_cache_stat(), tostring(tag or "")))
        return
    end
    local guard=MemoryGuard.instance()
    local policy=guard:snapshot()
    put(string.format("%s | Avail %sMB | Free %sMB | Swap %sMB | RSS %sMB | DocCache %s | Decode %sMB | Reserve %sMB | Worker %sMB | Reclaimed %sMB | %s",
        stamp(), mb(m.avail), mb(m.free), mb(m.swap), mb(m.rss), doc_cache_stat(),
        mb(guard:decode_budget()/1024),mb(policy.reserve/1024),mb(policy.worker/1024),
        mb((guard.last_reclaimed or 0)/1024),tostring(tag or "")))

    if m.avail then
        local avail_mb = m.avail / 1024
        -- 首次跌破阈值时额外用 logger 告警 (会在 koreader.log 里显眼)
        if avail_mb < Diag.LOW_AVAIL_MB
           and (last_avail == nil or last_avail >= Diag.LOW_AVAIL_MB) then
            logger.warn(string.format(
                "Picayomi DIAG: 可用内存仅 %.0fMB, 有被系统杀(OOM)风险", avail_mb))
        end
        last_avail = avail_mb
    end
end

--- 记录环境信息 (设备 / KOReader 版本), 便于事后定位
function Diag.header()
    local model, rev = "?", "?"
    pcall(function() model = require("device").model or "?" end)
    pcall(function() rev = require("version"):getCurrentRevision() or "?" end)
    put(string.format("%s | ===== Picayomi diag: %s / KOReader %s =====",
        stamp(), tostring(model), tostring(rev)))
end

local generation = 0

local function cancel_timer()
    generation = generation + 1
    if timer then UIManager:unschedule(timer) end
    timer = nil
end

-- scheduleIn 没有返回值; unschedule 接收的是原回调。
-- generation 同时挡住已经取出队列的旧回调, 包括同一章节的再次打开。
local function schedule(delay, fn)
    local current_generation = generation
    local callback
    callback = function()
        if generation ~= current_generation or timer ~= callback then return end
        timer = nil
        fn()
    end
    timer = callback
    UIManager:scheduleIn(delay, callback)
end

local function tick()
    timer = nil
    if not context then return end
    if Diag.enabled then Diag.snapshot(context) end
    if context then
        schedule(Diag.INTERVAL, tick)
    end
end

--- 退出后尾巴采样的一拍 (见 TAIL_INTERVAL 的说明)
local function tail_tick(ctx)
    timer = nil
    -- 期间开了新的一话: 交回给 start 的周期采样, 别两套计时器并行
    if context ~= ctx then return end
    tail_left = tail_left - 1
    if Diag.enabled then Diag.snapshot(ctx .. " (退出后)") end
    if tail_left > 0 and context == ctx then
        schedule(Diag.TAIL_INTERVAL, function() tail_tick(ctx) end)
    else
        context = nil
    end
end

--- 开始周期采样; ctx 是写进每行的说明 (如 "读 X 第3话 共92页")
function Diag.start(ctx)
    cancel_timer()
    context = ctx
    tail_left = 0
    if Diag.enabled then Diag.header() end
    if Diag.enabled then Diag.mark("start | " .. tostring(ctx)) end
    if Diag.enabled then Diag.snapshot(tostring(ctx)) end
    schedule(Diag.INTERVAL, tick)
end

--- 停止周期采样 (但继续低频采一会儿, 见 TAIL_INTERVAL)
function Diag.stop()
    cancel_timer()
    if Diag.enabled then Diag.snapshot("stop") end
    if Diag.enabled then Diag.mark("stop") end
    if not context then return end

    local ctx = context
    tail_left = Diag.TAIL_SAMPLES
    schedule(Diag.TAIL_INTERVAL, function() tail_tick(ctx) end)
end

--- 更新上下文 (页码/阶段变化时)
function Diag.set_context(ctx)
    context = ctx
end

return Diag
