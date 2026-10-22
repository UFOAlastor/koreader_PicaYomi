-- ui/reader_bridge.lua
-- 阅读器 ↔ 下载调度器 之间的**驱动层**: 决定"什么时候推进一步调度"。
--
-- 为什么不把 tick 直接放在 StreamSession 里:
--   会话该关心的是"下哪一页 / 失败了怎么办"; "什么时候跑"属于阅读器的生命周期。
--   而且这条 tick 链有一个很容易踩错的硬约束 (见下), 集中在一处才好守。
--
-- 硬约束: **重排自己的延迟必须 > 0**。
--   UIManager:handleInput 是 `repeat ... until not self._task_queue_dirty`
--   (frontend/ui/uimanager.lua:1537-1564), 而 Input:waitEvent 在循环**外** (:1608)。
--   若每轮都用 0 延迟重排自己 (scheduleIn(0) / nextTick), _task_queue_dirty 恒真 =>
--   循环永不退出 => 点击/翻页完全收不到 (观感与"冻屏"一样, 只是换了机制)。
--   所以用两段式: 第一段 nextTick 尽快开始, 之后一律 scheduleIn(TICK), TICK > 0。
--   KOReader 自己也这么干 (readerthumbnail.lua:42-58)。
--
-- 单步预算 (STEP_BUDGET_MS):
--   一次 step 最多发起 1 个请求 + 收割 1 个完成 (由调度器的 policy 保证), 加上
--   传给 transport 的 CPU 毫秒上限。目的都是"主线程占用有界" —— 宁可多走几步,
--   也不要一步走太久把输入事件挤掉。

local UIManager = require("ui/uimanager")
local logger = require("util.logger")
local Diag = require("util.diag")

local ReaderBridge = {}
ReaderBridge.__index = ReaderBridge

-- 驱动 tick 的最小延迟 (秒), **必须 > 0** —— 见文件头
ReaderBridge.TICK = 0.05
-- 单步允许占用的 CPU 毫秒上限 (预留给 transport 的 poll)
ReaderBridge.STEP_BUDGET_MS = 25

-- 诊断门槛 (秒): tick 迟到 / 单步耗时 超过这两个值就记一行 diag。
-- 迟到 = 事件循环被别的东西占住 (排版、解码、e-ink 刷新、别的插件的同步任务);
-- 单步 = 我们自己这一步 (收帧 / 发起) 占主线程太久。两者都会让用户感到"卡一下",
-- 但修法完全不同 —— 没有这两行就只能靠猜。
ReaderBridge.LAG_WARN = 0.3
ReaderBridge.STEP_WARN = 0.25

-- 墙钟 (秒)。不能用 os.clock(): 这里量的是等待与阻塞, 不是 CPU。
local function now_seconds()
    local ok, socket = pcall(require, "socket")
    if ok and type(socket) == "table" and socket.gettime then return socket.gettime() end
    return os.clock()
end

-- 注意: 用点号定义/调用 (X.new(session)), 与本项目的其它调度层模块一致
-- (PageStore.new / Scheduler.new / Transport.new)。写成 `function ReaderBridge:new`
-- 而调用处写 `ReaderBridge.new(session)` 的话, session 会落进 self 里, 实例的
-- session 字段恒为 nil —— 桥就再也驱动不了 (也取消不了) 那个会话。
function ReaderBridge.new(session)
    return setmetatable({ session = session, _driving = false, _standby = false }, ReaderBridge)
end

--- 给会话建一个驱动桥并接上 (同一会话重复调用返回同一个)
--
-- 会话自己也会在第一次需要推进时懒建一个 (见 StreamSession:_kick) —— 这样
-- "忘了接桥"不会变成"静默永远不下页"; 这里只是把它显式化并交给调用方持有。
function ReaderBridge.attach(session)
    if not session then return nil end
    local existing = session.driver
    if existing and existing.session == session then return existing end

    local bridge = ReaderBridge.new(session)
    session:set_driver(bridge)
    return bridge
end

--- 把会话接到一个已就绪的 ReaderUI 上
--
-- 阶段 3 起由 main.lua 的 registerPostInitCallback 调用 —— 那时 document/paging/
-- footer 全部就绪, 且用的是闭包里的 ui, 不必去猜 ReaderUI.instance。
function ReaderBridge.install(ui, session)
    local bridge = ReaderBridge.attach(session)
    if ui then ui._picayomi_bridge = bridge end
    return bridge
end

--- driver 接口: 请推进调度器 (非阻塞; 还有活会自己排下一拍)
function ReaderBridge:tick()
    self:_schedule(true)
end

--- 会话关闭 / 取消时调用 (由 main.lua 的 Picayomi:onCloseWidget 触发)
function ReaderBridge:close()
    self._closed = true
    if self._task then UIManager:unschedule(self._task);self._task=nil end
    self._driving = false
    self:_allow_standby()
    local session=self.session
    self.session=nil
    if session then
        if session.driver==self then session.driver=nil end
        session:cancel()
    end
end

--- 有下载在跑时不让设备睡过去 (否则后台预取会被 suspend 掐断)
--
-- 范本: frontend/apps/reader/modules/readerthumbnail.lua:289/333。
-- 必须成对: 用 _standby 标记保证 prevent/allow 一一对应, 否则设备会一直被
-- "钉住"不睡 (耗电), 或者反过来下载中途被 suspend 打断。
function ReaderBridge:_prevent_standby()
    if self._standby then return end
    self._standby = true
    if UIManager.preventStandby then UIManager:preventStandby() end
end

function ReaderBridge:_allow_standby()
    if not self._standby then return end
    self._standby = false
    if UIManager.allowStandby then UIManager:allowStandby() end
end

function ReaderBridge:_schedule(immediate)
    if self._driving or self._closed then return end
    self._driving = true

    -- 本该在什么时候跑 (诊断用: 实际执行时间 - 这个值 = 事件循环被占住的时长)
    local due = Diag.enabled and (now_seconds() + (immediate and 0 or ReaderBridge.TICK)) or 0

    local function run()
        if self._closed then return end
        self._task = nil
        self._driving = false
        local lag = Diag.enabled and (now_seconds() - due) or 0
        if lag >= ReaderBridge.LAG_WARN then
            if Diag.enabled then Diag.mark(string.format("bridge 迟到 %.0fms", lag * 1000)) end
        end
        local session = self.session
        if not session or session.cancelled then
            self:_allow_standby()
            return
        end
        -- 兜住整步: 本回调在事件循环的任务队列里跑, 这里抛出去就是整个阅读器崩溃
        -- (transport 收帧解码、上层的 on_ready 回调都在这一步的调用链上)。
        -- 出错就停掉本次驱动 (不重排), 但**不置 cancelled** —— 用户再翻一页会重新
        -- 触发 tick, 于是有机会自愈; 也保证 standby 一定被放开 (否则设备不睡)。
        local t0 = Diag.enabled and now_seconds() or 0
        local ok, pending = pcall(session.step, session, ReaderBridge.STEP_BUDGET_MS)
        local step_ms = Diag.enabled and ((now_seconds() - t0) * 1000) or 0
        if step_ms >= ReaderBridge.STEP_WARN * 1000 then
            if Diag.enabled then Diag.mark(string.format("bridge step %.0fms", step_ms)) end
        end
        if not ok then
            logger.warn("Picayomi ReaderBridge: 调度步进异常, 已停止本次驱动: "
                .. tostring(pending))
            self:_allow_standby()
            return
        end
        if pending then
            self:_prevent_standby()
            self:_schedule(false)   -- 第二段起延迟 > 0, 让出输入轮询
        else
            self:_allow_standby()
            -- 不变量: 调度器还有活, 就必须有人继续推。
            --
            -- step 返回的 pending 与 pending_count() 是同一次计算, 正常不会不一致;
            -- 真不一致 (例如 on_ready 里的重绘又排了新的下载) 时补一拍 —— 否则
            -- 队列里的页会一直躺着, 直到用户翻页才被"顺手"踢醒。真机表现正是
            -- "预取永远差一页, 每翻一页都要现下", 而日志里全是 "prefetch 被拒"。
            -- transport 不存在时 step 永远返回"没活"却又有队列 —— 那种情况下重排只是
            -- 每 50ms 空转一次并刷屏日志 (队列永远推不动)。这种状态没有自救的可能,
            -- 交给用户翻页重新建会话。
            local sched = session.scheduler
            if sched and sched.transport and sched.pending_count
               and sched:pending_count() > 0 then
                if Diag.enabled then Diag.mark(string.format("bridge 停在非空队列 (待下 %d)",
                    sched:pending_count())) end
                self:_schedule(false)
            end
        end
    end

    self._task = run
    if immediate then
        UIManager:nextTick(run)
    else
        UIManager:scheduleIn(ReaderBridge.TICK, run)
    end
end

return ReaderBridge
