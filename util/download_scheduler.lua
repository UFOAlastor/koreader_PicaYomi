-- util/download_scheduler.lua
-- 阅读页下载的**唯一决策点**: 优先级 / 去重 / 退避 / 熔断 / 取消 / 每步预算。
--
-- 为什么要有它 (根因):
--   旧实现把"发起下载"挂在 Document:openPage 上 —— 而 openPage 位于 KOReader 的
--   绘制链内部 (UIManager:_repaint -> paintTo -> renderPage -> openPage)。于是
--   "失败重试"也落在绘制路径里, 只能靠一堆补丁去堵:
--     失败冷却 15s / 连续失败熔断 / 慢页熔断 / 每页只提示一次 / 翻页放行重试 /
--     DocCache 键带 epoch —— 六个机制, 同一个根因。
--   本模块把决策集中到一处, 让绘制链只需要"读本地文件, 没有就画占位页"。
--
-- 分工 (不变量, test/scheduler_offline.lua 会断言):
--   * 只有本模块决定"下哪一页、什么时候下、失败后怎么办";
--   * 真正的 I/O 交给注入的 transport (见 network/transport_*.lua), 本模块不碰网络;
--   * 每页状态记在 PageStore 上, 本模块不碰文件;
--   * 本文件不 require 任何 ui/* —— 它不弹提示、不刷屏。
--
-- 每步预算 (budget):
--   step() 单次最多**发起 1 个**请求、**收割 1 个**完成。这是刻意的:
--   KOReader 的 Lua 是单线程的, 主线程占用必须有界, 否则一次 step 太长会把
--   输入事件挤掉 (表现就是"点了没反应")。宁可多走几步, 也不要一步走太久。
--
-- 注意 step() 本身**不安排自己的下一次执行** —— 那是驱动层的事
--   (ui/reader_bridge.lua)。驱动层必须用 scheduleIn(延迟 > 0) 重排自己:
--   scheduleIn(0)/nextTick 会让 UIManager:handleInput 的
--   `repeat ... until not _task_queue_dirty` 永不退出, 从而彻底饿死输入。
--   本模块不 require UIManager, 从结构上不可能犯这个错。

local logger = require("util.logger")

local Scheduler = {}
Scheduler.__index = Scheduler

-- 优先级: 数字越小越先下
--
-- 只有两级是**实际在用**的: 用户在看的这一页, 与后台预取补的页。曾经还定义过
-- P_NEIGHBOR (1) / P_REMOTE (3) 两级, 但生产路径从来没有传过它们
-- (ui/stream_reader.lua 无论向前还是回看都传 P_HINT), 于是那两级只是让读代码的人
-- 以为存在"回看排在向前之后"这套机制 —— 实际不生效。已删掉。
Scheduler.P_CURRENT = 0    -- 用户正看着的这一页 (熔断也不丢)
Scheduler.P_HINT    = 2    -- 后台预取补的页 (熔断时整批丢掉)

local DEFAULT_POLICY = {
    concurrency        = 1,          -- 同时在跑的下载数 (Kindle 上带宽/内存都紧)
    -- 单页超过这么久 => 认为链路"病态", 停预取。
    --
    -- 3s -> 10s (2026-10-18): 这个阈值原本是配"同步下载"时代的 —— 那时一页下 3 秒
    -- 就是界面冻 3 秒, 停预取是对的。现在下载跑在 fork 子进程里, 主线程一秒都不占,
    -- 慢链路**不再**等于界面卡; 而预取恰恰是慢链路下唯一能让翻页不等图的手段
    -- (用户读完一页的几秒里, 后台已经把下一张下好了)。3 秒会把"正常但慢"的 CDN
    -- 判成病态, 一停预取就退化成"每翻一页现下一张", 体验更差。
    -- 真正卡死的连接由 socket 超时 (20s) 走失败路径, 不靠这里。
    slow_seconds       = 10,
    failure_threshold  = 2,          -- 连续失败这么多次 => 停预取
    cooldown           = 15,         -- 失败页冷却 (秒), 冷却期内不重复发起
    max_start_per_step = 1,          -- 单步最多发起几个
    max_harvest_per_step = 1,        -- 单步最多收割几个
}

-- 导出默认策略: PageStore 的 retry_limit (占位页"加载中"还是"加载失败"的分界)
-- 与这里的 failure_threshold 是**同一个语义** —— 两个数字各写一份迟早会漂移。
Scheduler.DEFAULT_POLICY = DEFAULT_POLICY

--- 默认墙上时钟 (秒), 只用于冷却判定
local function default_wall_clock()
    return os.time()
end

function Scheduler.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Scheduler)

    self.store = opts.store
    self.transport = opts.transport
    self.policy = {}
    for k, v in pairs(DEFAULT_POLICY) do self.policy[k] = v end
    for k, v in pairs(opts.policy or {}) do self.policy[k] = v end

    -- 两个时钟刻意分开, 与旧实现一致 (旧实现: 冷却用 os.time, 单页耗时用 os.clock):
    --   * wall_clock 判冷却 (秒级, 可被注入以便离线测退避)
    --   * 单页耗时由 transport 报告 (它才是真正测量下载的那一层)
    self.wall_clock = opts.wall_clock or default_wall_clock
    self.interval_clock = opts.interval_clock or require("socket").gettime
    self.current_since = self.interval_clock()

    self.on_ready = opts.on_ready
    self.on_failed = opts.on_failed

    self.queue = {}          -- 已排序: { {n=, priority=, dist=, seq=}, ... }
    self.inflight = {}       -- n -> { started =, elapsed = }
    self.attempts = {}       -- n -> 尝试次数
    self.current_page = opts.current_page or 1
    -- 行进方向: +1 向后翻 / -1 回看。只影响**同优先级**页的先后,
    -- 不会让预取越过 P_CURRENT (见 compare_entries)。
    self.direction = opts.direction or 1
    self._seq = 0            -- 入队序号 (dist 相同时的稳定 tie-break)

    self.cancelled = false
    self.stats = { started = 0, done = 0, failed = 0 }

    return self
end

--- 注入/替换 transport (生产用 worker, 测试用脚本化的假实现)
function Scheduler:set_transport(transport)
    if self.transport and self.transport ~= transport then
        pcall(function() self.transport:cancel_all() end)
    end
    self.transport = transport
    self.inflight = {}
end

--- 更新"用户在哪一页、往哪个方向走"
--
-- @param n   当前页
-- @param dir 可选, +1 向后翻 / -1 回看。**只有翻页入口知道方向**
--            (PageUpdate 不带方向), 所以程序性跳转可以不传 —— 保持上一次的方向。
--
-- 方向为什么要进排序: dist = |n - current| 是**对称**的, 回看时 n+1 (刚翻过的)
-- 与 n-1 (马上要看的) 距离都是 1, 只能靠入队序号决胜负 —— 而 n+1 是上一拍
-- 作为"当前页"入队的, 序号永远更小。表现就是"往回翻得越快, 越是在下已经看过
-- 的那几页, 下一张反而慢"。
function Scheduler:set_current_page(n, dir)
    n = tonumber(n)
    if not n then return end
    local d = tonumber(dir)
    if d then
        self.direction = (d >= 0) and 1 or -1
    elseif n ~= self.current_page then
        -- 没给方向 (程序性跳页 / 恢复阅读位置): 用**页码变化的方向**兜底。
        -- 往回跳之后, 原来向前预取的 31,32,33 就该算"身后" —— 否则它们会排在
        -- 用户要看的 9,8,7 前面。
        self.direction = (n > self.current_page) and 1 or -1
    end
    -- 页码没变但方向可能变了 (先回看再前进), 也要重排
    if n ~= self.current_page then self.current_since = self.interval_clock() end
    self.current_page = n
    self:_resort()
    local radius = self.policy.keep_radius
    if radius then
        for i = #self.queue, 1, -1 do
            local e = self.queue[i]
            if e.priority ~= Scheduler.P_CURRENT and e.dist > radius then
                self.store:clear_loading(e.n)
                table.remove(self.queue, i)
            end
        end
    end
end

--- 队列排序键: 方向优先, 然后才是距离
--
-- @return front (0 = 在行进方向上 / 1 = 在身后), dist
local function order_key(entry, current_page, direction)
    local offset = entry.n - current_page
    local dist = math.abs(offset)
    -- 当前页自己 (offset == 0) 算"前方", 与旧的 dist 排序一致
    local behind = (offset * direction < 0) and 1 or 0
    return behind, dist
end

--- 队列比较器 (入队与重排共用一份, 避免两处逻辑漂移)
local function compare_entries(a, b)
    if a.priority ~= b.priority then return a.priority < b.priority end
    if a.behind ~= b.behind then return a.behind < b.behind end
    if a.dist ~= b.dist then return a.dist < b.dist end
    -- table.sort 不稳定: 同 (priority, 方向, dist) 时用入队序号定序, 保证可复现
    return a.seq < b.seq
end

--- 按新的当前页重算 dist 并重排队列
--
-- 为什么必须有这一步: dist = |n - current_page| 是**入队那一刻**算的, 而 _enqueue
-- 的插入是"线性扫描, 找到第一个该排在我后面的" —— 那个写法**只在队列已经有序时**
-- 才正确。当前页一跳 (跳页弹窗 / 恢复阅读位置 / 历史「继续」), 旧条目的 dist 全过期,
-- 队列就不再有序了。
--
-- 实测 (prefetch_pages = 3, 跳页前队列 = 2,3,4):
--   跳到第 20 页 -> 队列 2,21,3,22,4,23 -> **实际先下载的是第 2 页**
--   (离当前位置 18 页远, 而且用户已经翻过去了), 第 21 页排在它后面。
--   把当前页提权到 P_CURRENT 也救不回来: 20,2,21,3,22,4,23。
--   往回跳 (30 -> 10): 31,9,32,8,33,7 (向前/向后交错)。
-- 逐页翻之所以看起来没事, 是因为旧条目恰好按页码递增、新页追加在末尾 —— 巧合,
-- 不是设计。
function Scheduler:_resort()
    for _i, e in ipairs(self.queue) do
        e.behind, e.dist = order_key(e, self.current_page, self.direction)
        -- **P_CURRENT 是"用户此刻在看这一页"的临时身份, 不是永久标签。**
        --
        -- 连续翻页时每一页在成为当前页的那一刻都被提过权; 用户翻过去之后它还带着
        -- P_CURRENT, 就会永远排在**新的**当前页的邻页前面 —— 表现就是"翻得越快,
        -- 越是在下已经看过的那几页", 而下一页的预取迟迟不来。
        -- 当前页一变就把旧的降级成预取: 它们仍然值得下 (回看时省一次请求),
        -- 只是不再优先于当前页附近那几页。
        --
        -- 注意只降级 `e.n ~= current_page`: 当前页自己必须保住 P_CURRENT,
        -- 那是"熔断也不丢当前页"的依据 (见 _drop_prefetch_entries)。
        if e.priority == Scheduler.P_CURRENT and e.n ~= self.current_page then
            e.priority = Scheduler.P_HINT
        end
    end
    table.sort(self.queue, compare_entries)
end

--- 队列长度 (供兼容镜像/诊断)
function Scheduler:queue_size() return #self.queue end

--- 队列里的页码, 按即将发起的顺序 (供测试与诊断)
function Scheduler:queued_pages()
    local pages = {}
    for i, e in ipairs(self.queue) do pages[i] = e.n end
    return pages
end

--- 在途数量
function Scheduler:inflight_count()
    local c = 0
    for _ in pairs(self.inflight) do c = c + 1 end
    return c
end

--- 还有活没干完吗 (排队 + 在途)
function Scheduler:pending_count()
    return #self.queue + self:inflight_count()
end

function Scheduler:is_idle()
    return self:pending_count() == 0
end

local function find_in_queue(queue, n)
    for i, e in ipairs(queue) do
        if e.n == n then return i end
    end
    return nil
end

--- 按 (priority, dist) 插入。队列很短 (预取窗口 ≤ 9 + 近邻), 线性插入足够;
--- 这里刻意不做二分 —— 元素个数决定线性扫描就是最快的写法。
--
-- **前提: 队列当前是有序的** (由 _enqueue 自己 + set_current_page 的 _resort 维持)。
function Scheduler:_enqueue(n, priority)
    self._seq = (self._seq or 0) + 1
    local entry = { n = n, priority = priority, seq = self._seq }
    entry.behind, entry.dist = order_key(entry, self.current_page, self.direction)

    local pos = #self.queue + 1
    for i, e in ipairs(self.queue) do
        if compare_entries(entry, e) then
            pos = i
            break
        end
    end
    table.insert(self.queue, pos, entry)
    return entry
end

--- 请求下载第 n 页
--
-- 幂等: 已在本地 / 已在队 / 在跑 / 冷却中 一律返回 false 且不重复入队。
-- 已在队但优先级更高时**提权** (用户翻到这一页了, 它该插到前面去)。
--
-- @param priority 见 Scheduler.P_*
-- @return boolean 本次是否新增了任务
function Scheduler:request(n, priority)
    if self.cancelled then return false end
    n = tonumber(n)
    if not n or n < 1 or n > (self.store:page_count() or 0) then return false end
    if self.store.non_retryable and self.store.non_retryable[n] then return false end

    -- 缺省值只为"某个调用点忘了传"兜底 (生产路径一律显式传): 按**用户当前需要的页**
    -- 处理 —— 这个方向判错只是抢一点带宽, 反过来判错(把当前页当预取)会被熔断整批丢掉,
    -- 表现就是"点了没反应"。
    priority = priority or Scheduler.P_CURRENT
    if priority ~= Scheduler.P_CURRENT and self.policy.keep_radius
       and math.abs(n - self.current_page) > self.policy.keep_radius then
        return false
    end

    -- 已有有效文件 => 不需要下 (回看已读页因此天然零新请求)
    if self.store:has_local(n) then return false end
    if self.inflight[n] then return false end
    if self.store:in_cooldown(n, self.wall_clock(), self.policy.cooldown) then return false end

    local idx = find_in_queue(self.queue, n)
    if idx then
        -- 提权: 删掉旧位置重新插, 让顺序正确
        if self.queue[idx].priority > priority then
            table.remove(self.queue, idx)
            self:_enqueue(n, priority)
        end
        return false
    end

    self:_enqueue(n, priority)
    -- 一入队就算"已排队": 占位页要**立刻**显示"加载中…", 而不是等真正发起下载
    -- 才变 —— 绘制链里 openPage 返回占位页时, 状态必须已经是 loading。
    self.store:mark_loading(n)
    return true
end

--- 清掉某页的失败冷却 (用户主动翻到这一页 => 放行一次重试)
--
-- 由驱动层 (ui/reader.lua 的 ensurePagesCached) 在用户翻页时调用。决策点在这里,
-- 但"什么时候算用户重试意图"由驱动层判断 —— 调度器不猜用户意图。
function Scheduler:clear_failure(n)
    self.store:clear_failure(n)
end

--- 只丢掉"预取"性质的任务, 保留用户当前需要的页
--
-- 熔断的语义是"别再后台补页了", 不是"用户翻到哪都别下" —— 所以 P_CURRENT 必须留下。
function Scheduler:_drop_prefetch_entries()
    local kept = {}
    local dropped = 0
    for _i, e in ipairs(self.queue) do
        if e.priority == Scheduler.P_CURRENT then
            kept[#kept + 1] = e
        else
            -- 丢掉的页必须把"已排队"标记一并清掉, 否则占位页会永远停在"加载中…"
            -- (没有东西在加载, 却又显示正在加载)。
            if self.store.clear_loading then self.store:clear_loading(e.n) end
            dropped = dropped + 1
        end
    end
    self.queue = kept
    return dropped
end

--- 停掉预取 (熔断)
function Scheduler:disable_prefetch(reason)
    if self.store.prefetch_disabled then return false end
    self.store.prefetch_disabled = true
    local dropped = self:_drop_prefetch_entries()
    logger.warn(string.format(
        "Picayomi Scheduler: 暂停后台预取 (%s), 丢掉 %d 个待下载任务; 按需翻页仍可用",
        tostring(reason or "?"), dropped))
    return true
end

--- 取消一切 (文档关闭 / 换章时调用)
--
-- 必须同时: 清队列、丢在途、停 transport、清 PageStore 的"已排队"标记
-- (否则 state() 会永远停在 loading, 占位页永远显示"加载中…")。
--
-- @param nonblocking true 时要求 transport **不等待**子进程被回收
--        (见 StreamSession:shutdown / network/subprocess_fork.lua 的 Fork:terminate)。
--        只给"进程正在退出"的路径用: 那条路上子进程可能正卡在一个 15 秒的 DNS 解析里,
--        阻塞等它就是把"退出卡顿"原样留着。transport 没实现 terminate 时静默退回普通取消
--        (功能不会丢, 顶多多等一次回收)。
function Scheduler:cancel_all(nonblocking)
    self.cancelled = true
    self.queue = {}
    self.inflight = {}
    if self.transport then
        if nonblocking and self.transport.terminate then
            pcall(function() self.transport:terminate() end)
        else
            pcall(function() self.transport:cancel_all() end)
        end
    end
    if self.store and self.store.reset_pending then
        self.store:reset_pending()
    end
end

--- 收割一个完成的下载
function Scheduler:_complete(item)
    local n = item.page
    self.inflight[n] = nil

    if item.ok then
        self.stats.done = self.stats.done + 1
        -- 注意: 不把 transport 报的**文件字节数**当页面尺寸传给 mark_ready ——
        -- 尺寸 (w/h) 由上层在 on_ready 里用真实解码量出来 (见 ui/stream_reader.lua)。
        self.store:mark_ready(n, item.path)
        if self.on_ready then
            -- 回调来自上层, 会碰 UI (发 PageUpdate 触发重绘), 而本函数是在事件循环的
            -- tick 里跑的 —— 抛异常会一路逃出 UIManager 的任务队列, 直接把阅读器打崩。
            -- 兜住它: 顶多这一页这次不刷新 (文件已落地, 下次翻页/重绘仍会显示)。
            --
            -- 第 4 个参数是 transport 上报的**文件字节数** (可能为 nil)。上层拿它做
            -- 缓存总量记账 —— 有了它就不必为了知道"缓存涨了多少"去递归扫盘。
            -- 第 5 个参数是后处理耗时 (源侧解扰), 只是诊断口径 —— 调用方可以忽略。
            local ok, err = pcall(self.on_ready, n, item.path, item.elapsed, item.size,
                item.post)
            if not ok then
                logger.warn("Picayomi Scheduler: on_ready 回调异常: " .. tostring(err))
            end
        end
    else
        self.stats.failed = self.stats.failed + 1
        self.store:mark_failed(n, item.err, self.wall_clock())
        if item.retryable==false then
            self.store.non_retryable=self.store.non_retryable or {}
            self.store.non_retryable[n]=true
        end
        if self.on_failed then
            local ok, err = pcall(self.on_failed, n, item.err)
            if not ok then
                logger.warn("Picayomi Scheduler: on_failed 回调异常: " .. tostring(err))
            end
        end
    end

    -- 慢链路熔断: transport 报告的单页耗时超阈值 => 别再后台补页, 否则界面
    -- 会被反复的长下载冻住。
    if item.elapsed and item.elapsed >= self.policy.slow_seconds then
        self:disable_prefetch(string.format("单页耗时 %.1fs", item.elapsed))
    end

    -- 连续失败熔断
    if not item.ok
       and self.store.consecutive_failures >= self.policy.failure_threshold then
        self:disable_prefetch(string.format(
            "连续失败 %d 次", self.store.consecutive_failures))
    end
end

-- Only reclaim a slot when the settled current page actually needs it.
-- No worker restart, and at most one obsolete request is cancelled per step.
function Scheduler:_make_room_for_current()
    local grace = self.policy.preempt_after
    if not grace or not self.transport.cancel
       or self:inflight_count() < self.policy.concurrency
       or self.interval_clock() - self.current_since < grace then return end
    local current = find_in_queue(self.queue, self.current_page)
    if not current or self.queue[current].priority ~= Scheduler.P_CURRENT then return end
    local victim, victim_behind, victim_dist
    for n in pairs(self.inflight) do
        if n ~= self.current_page then
            local behind, dist = order_key({ n = n }, self.current_page, self.direction)
            if not victim or behind > victim_behind
               or (behind == victim_behind and dist > victim_dist)
               or (behind == victim_behind and dist == victim_dist and n < victim) then
                victim, victim_behind, victim_dist = n, behind, dist
            end
        end
    end
    if victim and self.transport:cancel(victim) then
        self.inflight[victim] = nil
        self.store:clear_loading(victim)
    end
end

--- 发起一个任务
function Scheduler:_start(entry)
    local n = entry.n
    self.attempts[n] = (self.attempts[n] or 0) + 1
    -- 递增代数: 让 DocCache 的键变化, 保证"重试"真的会走到 openPage
    -- (见 util/page_store.lua 的 render_key)
    self.store:bump_gen(n)
    self.store:mark_loading(n)

    local imgs = self.store:page_images()
    local img = imgs and imgs[n]
    self.inflight[n] = { started = self.wall_clock(), attempt = self.attempts[n] }
    self.stats.started = self.stats.started + 1

    self.transport:start{
        page = n,
        image = img,
        url = img and img.url,
        dest = self.store:base(n) .. ".jpg",
        attempt = self.attempts[n],
    }
end

--- 推进一步: 收割 + 发起。**不安排自己的下一次执行** (见文件头)。
--
-- @param budget_ms 本步允许占用的 CPU 毫秒上限 (预留给 transport 的 poll)
-- @param block     true = "同步语义": transport 可以阻塞等到结果。
--                  只有 run_until_idle (fetch_page 的兼容语义) 会传它。
--                  事件循环里的 tick 一律不传 —— 那种场合主线程一秒都不能多占。
-- @return did_work, pending
function Scheduler:step(budget_ms, block)
    if self.cancelled then return false, false end
    if not self.transport then return false, false end

    local did_work = false

    -- 1) 收割 (有界)
    local res = self.transport:poll(budget_ms, block) or {}
    local done = res.done or {}
    local harvested = 0
    for _i, item in ipairs(done) do
        if harvested >= self.policy.max_harvest_per_step then break end
        harvested = harvested + 1
        self:_complete(item)
        did_work = true
    end

    self:_make_room_for_current()

    -- 2) 发起 (有界)
    if not self.cancelled then
        for _i = 1, self.policy.max_start_per_step do
            if self:inflight_count() >= self.policy.concurrency then break end
            local entry = table.remove(self.queue, 1)
            if not entry then break end
            self:_start(entry)
            did_work = true
        end
    end

    local pending = (not self.cancelled) and (self:pending_count() > 0)
    return did_work, pending
end

--- 把队列与在途全部跑完 (阻塞)。
--
-- 只给"必须同步拿到结果"的路径用 (StreamSession:fetch_page 的兼容语义、
-- 打开前预热)。**绝不能在绘制链里调用** —— 它会一直 step 到没有活为止。
--
-- block=true 会透传给 transport: worker 实现据此知道"可以阻塞等子进程回帧",
-- 否则它只能非阻塞地问一句"好了吗", 这个循环就会空转到上限。
--
-- @param max_steps 安全上限, 防 transport 永远不返回完成导致死循环
function Scheduler:run_until_idle(max_steps)
    max_steps = max_steps or 64
    local steps = 0
    while not self.cancelled and self:pending_count() > 0 and steps < max_steps do
        steps = steps + 1
        local _did_work, pending = self:step(0, true)
        if not pending then break end
    end
    return steps
end

return Scheduler
