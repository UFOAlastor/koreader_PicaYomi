-- ui/common/loading_task.lua
-- 统一"显示加载提示 → 取数 → 关提示"的时序, 并保证**取数抛异常时提示也会被关掉**。
--
-- 为什么必须有这个模块:
--   这些加载提示都是 `InfoMessage`, 而且大多**没有 timeout** —— 不会自己消失。
--   取数用的是同步网络调用, 一旦它**抛异常**(而不是返回 false), 后面那句
--   `UIManager:close(loading)` 就永远走不到, 提示会永久盖在屏幕上。
--   用户看到的现象就是"点了没反应 / 界面卡住", 只能退出插件。
--
--   这个坑在项目里踩过多次, 于是各处在本地补 pcall (见 visual_comic_list.lua、
--   ui/home.lua 的注释), 但仍漏了十处以上 —— 说明"每处都记得写 pcall"这种约定
--   靠不住。这里收成一个函数, 让"忘写 pcall"在结构上不可能发生。
--
-- 另有一个副作用值得注意: 有些调用方除了关提示, 还要复位一个"正在加载"的守卫
--   (如 ComicDetail.loading_chapters / VisualComicList.loading_more)。那种复位
--   **必须**放在本函数之后无条件执行 —— 否则异常时守卫会一直是 true,
--   之后每次重试都在入口被 return 掉, 表现同样是"点了没反应"。
--   `LoadingTask.run` 把这个复位收成了 `set_busy`, 让"漏写复位"也不可能发生。
--
-- 两个入口:
--   * `call(loading, fn)`  —— 只负责"取数并把提示关掉", 提示由调用方自己管理;
--   * `run{...}`           —— 连"显示提示 → 延迟一拍 → 取数 → 关提示 → 复位守卫 → 回调"
--                             整套时序一起管。新代码优先用 `run`。

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local logger = require("util.logger")

local LoadingTask = {}
local handles=setmetatable({},{__mode="k"})
function LoadingTask.cancelAll()
    local pending={}
    for handle in pairs(handles)do pending[#pending+1]=handle end
    for _,handle in ipairs(pending)do
        if handle.task then handle.task.nonblocking=true end
        handle:cancel()
    end
end

-- Shared by comic and novel return paths; paint before blocking reader cleanup.
function LoadingTask.showReturning(reason)
    local notice=InfoMessage:new{text=reason or require("gettext")("返回中…"),dismissable=false}
    UIManager:show(notice,"ui")
    UIManager:forceRePaint()
    return notice
end

function LoadingTask.showFailure(err)
    UIManager:show(InfoMessage:new{
        text = require("ui.common.error_message").describe(err,
            require("gettext")("加载失败，请检查网络后重试；若仍失败，请重新打开此页面。")),
    }, "ui")
end

function LoadingTask.close(loading)
    -- InfoMessage invokes dismiss_callback on programmatic close too.
    if loading then loading.dismiss_callback = nil end
    UIManager:close(loading, "ui")
end

-- Run a UI continuation whose HTTP calls yield to background workers.
-- Cancellation drops the continuation, so late responses cannot reopen pages.
function LoadingTask.background(loading, fn, opts)
    opts = opts or {}
    local handle = {}
    handles[handle]=true
    local function cleanup()
        handles[handle]=nil
        if loading then LoadingTask.close(loading) end
    end
    local function cancelled()
        if handle.cancelled then return end
        handle.cancelled = true
        cleanup()
        if opts.on_cancel then opts.on_cancel() end
    end
    function handle:cancel()
        if self.cancelled or (self.task and self.task.done) then return end
        if self.start then UIManager:unschedule(self.start) end
        if self.task then self.task:cancel() end
        cancelled()
    end
    if loading then
        loading.dismiss_callback = function() handle:cancel() end
    end
    handle.start = function()
        if handle.cancelled then return end
        handle.task = require("network.async_task").run(function()
            fn();handles[handle]=nil
        end, {
            timeout = opts.timeout,
            reuse_worker = opts.reuse_worker,
            is_cancelled = opts.is_cancelled,
            on_cancel = cancelled,
            on_error = function(err)
                cleanup()
                if opts.on_error then
                    local ok, callback_err = pcall(opts.on_error, err)
                    if not ok then
                        logger.warn("Picayomi: failure callback failed: " .. tostring(callback_err))
                        LoadingTask.showFailure()
                    end
                else
                    logger.warn("Picayomi: 后台取数失败: " .. tostring(err))
                    if loading then LoadingTask.showFailure(err) end
                end
            end,
        })
    end
    if opts.delay and opts.delay > 0 then UIManager:scheduleIn(opts.delay, handle.start)
    else handle.start() end
    return handle
end

--- 记录返回值**个数**的 pack (不能只靠 `#t`: 带洞的表的 `#` 是不确定的)
local function pack(...)
    return { n = select("#", ...), ... }
end

--- 跑一次取数, 无论成功/失败/抛异常都先关掉加载提示。
--
-- 返回值归一成本项目里最常见的 `(ok, data, err)` 契约:
--   * 正常返回: 原样透传 fn 的返回值 (fn 通常返回 `ok, data, err`)
--   * 抛异常:   返回 `false, nil, 异常信息`
-- 于是调用方只需把 `local ok, data, err = api:call()` 换成
-- `local ok, data, err = LoadingTask.call(loading, function() return api:call() end)`,
-- 原来的失败分支不用动就能同时兜住"返回失败"和"抛异常"两种情况。
--
-- @param loading 已经 show 出来的 InfoMessage (可为 nil; nil 时只做 pcall)
-- @param fn      取数函数 (无参闭包最方便)
--
-- 例外: 需要**区分"抛异常"与"返回失败"**两件事的调用方 (如 VisualComicList:fetchMore
-- 在异常时要保留 has_more 以便重试、并停掉自动预取), 归一之后这个区别就没了,
-- 那种地方继续直接用 pcall —— 但同样要保证 close(loading) 一定被执行。
function LoadingTask.call(loading, fn)
    -- 必须把返回值个数记下来再 `unpack(…, 2, n)`:
    -- 取数失败的常见形态是 `(false, nil, err)` —— 中间有个 nil。直接写
    -- `unpack({ pcall(fn) }, 2)` 时 j 会退化成 `#t`, 而带洞的表的 `#` 是不确定的
    -- (LuaJIT 实测返回 2), 于是 err 被**静默丢掉**, 上层只能显示 "失败: false"。
    local results = pack(pcall(fn))

    -- 先关提示, 再处理结果: 后面的分支里会 show 新的 InfoMessage,
    -- 顺序反了会让新提示被这条 close 的刷新逻辑盖掉一层。
    LoadingTask.close(loading)

    if not results[1] then
        local err = tostring(results[2])
        logger.warn("Picayomi: 取数抛异常 (已关掉加载提示): " .. err)
        return false, nil, err
    end
    return unpack(results, 2, results.n)
end

--- "显示加载提示 → 延迟一拍 → 取数 → 关提示 → 复位守卫 → 回调" 的整套时序。
--
-- 为什么还要这一层: `call` 只解决"提示一定被关掉", 而每个调用点仍要自己写
--   show → forceRePaint → scheduleIn → call → 复位守卫 → 分支
-- 这一串。写漏任何一步都是真事故:
--   * 漏 forceRePaint —— show 只把刷新入队, 紧接着就阻塞做网络请求,
--     事件循环没机会重绘, 提示等于没显示 (用户以为卡住了);
--   * 漏 scheduleIn   —— 提示和请求挤在同一拍里, 提示同样看不到;
--   * 漏复位守卫     —— 守卫卡在 true, 之后每次重试都在入口被 return 掉,
--     表现还是"点了没反应" (见文件头注释)。
-- 收进这里之后, 这三件事在结构上不可能漏。
--
-- @param opts.message     提示文案 (内部创建 InfoMessage)
-- @param opts.fetch       function() -> ok, data, err
-- @param opts.async       true: HTTP yields to a cancellable background task
-- @param opts.delay       延迟秒数; 省略或 <= 0 表示"不延迟, 立刻取"
--                         (取数前已经 forceRePaint 过, 提示照样看得见)
-- @param opts.is_cancelled function() -> bool  可选; 为 true 时**不取数**,
--                         直接关提示并回调 (页面已关闭, 不该再联网)
-- @param opts.set_busy    function(bool)  可选; 取数结束后**无条件**调用
--                         set_busy(false) (无论成功/失败/抛异常/被取消)
-- @param opts.on_done     function(ok, data, err)  可选
-- @return loading 控件
function LoadingTask.run(opts)
    local loading
    if opts.progress then
        loading=require("ui.common.loading_progress"):new{title=opts.message,progress={message=opts.stage}}
    else loading=InfoMessage:new{text=opts.message}end
    UIManager:show(loading, "ui")
    -- 同步刷一次: show 只是把刷新入队, 而后面马上就要阻塞做网络请求,
    -- 不等这一下的话事件循环没机会重绘, 提示等于没显示。
    UIManager:forceRePaint()

    local function notify_done(ok, data, err)
        if opts.on_done then
            local ok_cb, err_cb = pcall(opts.on_done, ok, data, err)
            if not ok_cb then
                logger.warn("Picayomi: LoadingTask on_done 抛异常 (已吞掉, 守卫已复位): " .. tostring(err_cb))
                LoadingTask.showFailure()
            end
        elseif not ok then
            LoadingTask.showFailure(err)
        end
    end

    local function step()
        -- 页面已关闭: 连请求都不该发 (延迟任务是关页面之后照样会被调度的)
        if opts.is_cancelled and opts.is_cancelled() then
            LoadingTask.close(loading)
            if opts.set_busy then opts.set_busy(false) end
            if opts.on_done then pcall(opts.on_done, false, nil, nil) end
            return
        end

        local fetch=opts.fetch
        if opts.progress then fetch=function()return opts.fetch(function(p)loading:update(p)end)end end
        local ok, data, err = LoadingTask.call(loading, fetch)

        -- 复位必须无条件: 放进任何分支里, 异常那条路就会把守卫永久留在 true
        if opts.set_busy then opts.set_busy(false) end

        -- on_done 里跑的是**调用方的数据加工与整页重建** (processor 吃源返回的原始数据,
        -- 形状没料到就抛)。它常常在 scheduleIn 的任务里 (delay > 0): KOReader 的任务队列
        -- 不兜异常, 逃出去 = 整个进程退出。fetch 本身有 LoadingTask.call 兜底, 而它没有 ——
        -- 漏在这里等于"取数很稳, 处理结果时随机闪退"。
        -- 提示已关、守卫已复位, 此刻吞掉异常只会让这次加载"没有结果", 用户可以重试。
        notify_done(ok, data, err)
    end

    if opts.async then
        return LoadingTask.background(loading, step, {
            timeout = opts.timeout,
            delay = opts.delay,
            is_cancelled = opts.is_cancelled,
            on_cancel = function()
                if opts.set_busy then opts.set_busy(false) end
                if opts.on_cancel then opts.on_cancel() end
            end,
            on_error = function(err)
                if opts.set_busy then opts.set_busy(false) end
                notify_done(false, nil, err)
            end,
        })
    elseif opts.delay and opts.delay > 0 then
        local handle={}
        handles[handle]=true
        local start=function()
            if handle.cancelled then return end
            handles[handle]=nil
            step()
        end
        function handle:cancel()
            if self.cancelled then return end
            self.cancelled=true;handles[self]=nil
            UIManager:unschedule(start);LoadingTask.close(loading)
            if opts.set_busy then opts.set_busy(false)end
            if opts.on_cancel then opts.on_cancel()end
        end
        loading.dismiss_callback=function()handle:cancel()end
        UIManager:scheduleIn(opts.delay,start)
    else
        step()
    end

    return loading
end

return LoadingTask
