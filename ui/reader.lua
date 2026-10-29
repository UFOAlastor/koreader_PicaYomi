-- ui/reader.lua
-- 阅读器侧的门面: 打开一话 / 装阅读器钩子 / 换章 / 章节导航 / 关闭清理。
--
-- 边界 (避免又长出"挂在没人调用的路径上"的死代码):
--   * 取页、预取、下载调度 -> ui/stream_reader.lua + util/download_scheduler.lua
--   * "打开一话"的时序 (可取消协程) -> api/comic.lua:getAndOpenComic
--   * 本文件只负责和 KOReader 阅读器打交道的那部分

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local LoadingTask = require("ui.common.loading_task")
local Screen = require("device").screen
local Menu = require("ui.common.action_style").Menu
local ConfirmBox = require("ui.common.action_style").ConfirmBox
local logger = require("util.logger")
local Diag = require("util.diag")
local _ = require("gettext")
local T = require("ffi/util").template
local ReaderUI = require("apps/reader/readerui")
local ReaderBridge = require("ui.reader_bridge")
local MenuStyle = require("ui.common.menu_style")
local MenuSwipe = require("ui.common.menu_swipe")
local SwipeRules = require("ui.common.swipe_rules")
local config = require("util.config")
local ViewMode = require("ui.common.view_mode")

-- 源 A 阅读器
local PicaReader = {
    on_return_callback = nil,
    on_end_of_book_callback = nil,
    is_showing = false,
    current_comic = nil,
    current_episode = nil,
    episodes_list = nil, -- 新增：存储章节列表
    current_episode_index = nil, -- 新增：当前章节在列表中的索引
    -- 阅读进度落盘的节流间隔 (秒): 翻页太频繁时没必要每页写一次 settings JSON
    PROGRESS_SAVE_INTERVAL = 5,
}

-- ==================== 翻页时的失败重试放行 ====================

--- 从 ReaderUI 取当前的流式会话 (不是流式阅读则返回 nil)
local function currentStreamSession()
    local instance = ReaderUI.instance
    local doc = instance and instance.document
    return doc and doc.session
end

--- 用户主动翻页时, 清掉目标页的失败冷却 (允许重试一次)
--
-- 这里**不再下载**。以前会在翻页前同步下载目标页并弹"加载中…"提示, 那等于
-- 把冻结搬到了翻页动作上; 现在取页全权交给 stream_reader:
-- 绘制链里缺页只返回"加载中…"占位页, 下载排到事件循环, 完成后自动替换。
-- 唯一还需要在这里做的是"允许重试": 失败页有 15 秒冷却 (挡住绘制链里的
-- 重试风暴), 但用户明确翻到这一页就是重试意图, 应该放行。
function PicaReader:ensurePagesCached(pages)
    local session = currentStreamSession()
    if not session or session.cancelled then return end
    local total = tonumber(session.total) or 0
    if total <= 0 then return end

    for _i, n in ipairs(pages or {}) do
        n = tonumber(n)
        if n and n >= 1 and n <= total then
            session:clear_failure(n)
        end
    end
end

--- 翻页后补一次整屏刷新 ("刷新不全的印子")
--
-- 墨水屏的局部刷新会把上一页的残影留在整页图上; 漫画是**整页换图**, 残影比文字页
-- 明显得多。KOReader 自己只在每 FULL_REFRESH_COUNT 次局部刷新后补一次全刷
-- (uimanager.lua:1242), 中间那几页就带着印子。
--
-- 做法: 每次 PageUpdate 之后追加一次 setDirty(dialog, "full")。UIManager 会把同区域
-- 的刷新合并、模式取更强的那个 (uimanager.lua:1159 update_mode), 所以不会和
-- KOReader 自己排的 "ui"/"partial" 打架, 也不会多刷一次屏。
--
-- 关掉它的开关在 设置 → 阅读设置 → 翻页刷新 (默认开)。
-- 滚动停下后多久补一次整屏刷新 (秒)
--
-- 太短: 用户还在慢慢滚的时候就会闪一下; 太长: 残影停留太久。
-- 0.8s 是"手指离开后几乎立刻清干净"的量级, 又不会打断连续滚动。
local SCROLL_SETTLE_REFRESH_DELAY = 0.8

--- 滚动模式: 停手之后再补一次整屏刷新 (消残影)
--
-- 为什么不能每步全刷: 滚动时每一步移动都会发一次刷新, 每步整屏刷 = 频闪灯。
--
-- 为什么也不能"完全交给 KOReader": UIManager:_refresh 在
-- `currently_scrolling` 时会把**所有**刷新降级成 "fast"
-- (uimanager.lua:1208), 而"每 N 次局部刷新补一次全刷"的计数只对
-- "partial" 生效 (uimanager.lua:1241) —— fast 永远等不到那次全刷。
-- 于是连续滚十几屏下来, 残影越叠越重 (真机反馈: "留下残影了")。
--
-- 做法: 每次滚动排一个防抖任务, 只有**最后一次**真的执行 (序号令牌),
-- 执行时若还在滚 (按住/惯性) 就再排一轮。
function PicaReader:scheduleScrollRefresh(ui)
    if not config:get("refresh_on_page_turn", true) then return end
    local dialog = ui and ui.dialog
    if not dialog then return end

    self._scroll_refresh_seq = (self._scroll_refresh_seq or 0) + 1
    local seq = self._scroll_refresh_seq
    UIManager:scheduleIn(SCROLL_SETTLE_REFRESH_DELAY, function()
        -- 又滚了一下 / 换了一本书 / 页面已关: 这一枪作废
        if self._scroll_refresh_seq ~= seq then return end
        if self._closing then return end
        local ok, shown = pcall(function() return UIManager:isWidgetShown(dialog) end)
        if ok and not shown then return end
        if UIManager.currently_scrolling then
            -- 手指还按着 (或惯性还在跑): 等它停下来
            self:scheduleScrollRefresh(ui)
            return
        end
        self._scroll_refresh_seq = nil
        UIManager:setDirty(dialog, "full")
    end)
end

function PicaReader:forceFullRefresh(ui)
    if not config:get("refresh_on_page_turn", true) then return end
    local dialog = ui and ui.dialog
    if not dialog then return end
    -- 连续滚动模式: 不每步全刷 (频闪), 改成"停手后补一次" (见 scheduleScrollRefresh)
    if ui.view and ui.view.page_scroll then
        self:scheduleScrollRefresh(ui)
        return
    end
    UIManager:setDirty(dialog, "full")
end

--- 挂钩翻页入口
-- 相对翻页 (上一页/下一页) 与绝对跳页都在**重绘之前**调用, 正好用来
--   1. 放行失败页的重试 (清掉冷却);
--   2. 上报"目标页 + 方向"给会话做位置驱动的预取。
--
-- **方向只能从这里拿到**: PageUpdate 不带方向, 而且程序性跳转也会发它
-- (readerpaging.lua 的 onGotoPage/onGotoPageRel 是用户意图的唯一入口)。
function PicaReader:hookPageTurns(ui)
    local paging = ui and ui.paging
    if not paging then return end

    -- 取当前流式会话: 优先用传进来的 ui (真实 ReaderUI 有 .document),
    -- 退回 ReaderUI.instance —— 测试里常常只有一个带 paging 的桩。
    local function stream_session()
        local doc = ui and ui.document
        return (doc and doc.session) or currentStreamSession()
    end

    -- 上报"翻到哪一页、往哪个方向翻"; 会话据此决定预取窗口
    local function report_turn(target, dir)
        local session = stream_session()
        if session and not session.cancelled and session.on_page_turn then
            session:on_page_turn(target, dir)
        end
    end

    -- 页脚建得比 paging 还晚, 重试可能先放弃; 翻页时再兜一次 (只为打一次诊断日志)。
    -- 用 _footer_checked 而不是页脚对象本身做标记: 找到过就不再重跑, 免得每翻页都刷日志。
    local function retry_footer_if_needed()
        if not PicaReader._footer_checked then
            PicaReader:adaptFooterWithRetry(ui)
        end
    end

    if paging.onGotoPageRel and not paging._picayomi_wrapped_rel then
        local orig = paging.onGotoPageRel
        paging.onGotoPageRel = function(self, diff, no_page_turn)
            -- 用户**自己**翻页了: 「开始」的页码兜底必须立刻停手, 否则会把用户拨回去。
            -- 只在这里置位 —— onGotoPage 是程序性跳转 (跳页弹窗、别的插件), 不算用户意图。
            --
            -- 标记记在**会话**上而不是模块上: PicaReader 是单例, 记在它上面时
            -- 上一本书里翻过页会让下一本书的兜底整个失效 (测试当场就抓到了)。
            local s = stream_session()
            if s then s.user_turned_page = true end
            local cur = tonumber(self.current_page) or 1
            local step = tonumber(diff) or 0
            local pages = {}
            -- 沿翻页方向看两页: 用户翻过去时这两页里的失败页都该被放行重试
            for k = 1, 2 do
                pages[#pages + 1] = cur + (step >= 0 and k or -k)
            end
            PicaReader:ensurePagesCached(pages)
            report_turn(cur + step, step >= 0 and 1 or -1)
            retry_footer_if_needed()
            return orig(self, diff, no_page_turn)
        end
        paging._picayomi_wrapped_rel = true
    end

    if paging.onGotoPage and not paging._picayomi_wrapped_abs then
        local orig = paging.onGotoPage
        paging.onGotoPage = function(self, number, pos)
            local target = tonumber(number)
            -- 「开始」的第三道保证 (见 enforceStartFromBeginning 的说明):
            -- 用户还没碰过设备, 这次程序性跳页就一定是**别人**干的 (后台同步)。
            -- 直接忽略这次跳转, 保持在第一页 —— 不执行 orig 就不会触发重绘。
            local s = stream_session()
            if s and s.start_guard and not s.user_turned_page and target and target > 1 then
                logger.warn(string.format(
                    "Picayomi Reader: 「开始」期间忽略程序性跳页 (第 %d 页), 保持在第 1 页",
                    target))
                return
            end
            PicaReader:ensurePagesCached({ number })
            local cur = tonumber(self.current_page) or 1
            target = target or cur
            report_turn(target, target >= cur and 1 or -1)
            retry_footer_if_needed()
            return orig(self, number, pos)
        end
        paging._picayomi_wrapped_abs = true
    end

    -- 程序性跳页 (恢复阅读位置 / 别的插件 / 换章) 不经过 onGotoPage*,
    -- 只发 PageUpdate。不接这一条的话, 调度器的 current_page 会一直停在旧值 ——
    -- 而队列里每一条的 dist 都是按"旧位置"算的, 预取顺序随之整体错位
    -- (典型: 打开一话直接恢复到第 50 页, 调度器却还以为在第 1 页)。
    --
    -- 这里**只同步页码**: PageUpdate 不带方向, 方向由 on_page_turn 负责;
    -- 也不在这里触发预取 (那会在程序性重绘时反复排任务)。
    if paging.onPageUpdate and not paging._picayomi_wrapped_update then
        local orig_update = paging.onPageUpdate
        paging.onPageUpdate = function(self, number, orig_mode)
            local s = stream_session()
            if s and not s.cancelled and s.scheduler then
                pcall(function() s.scheduler:set_current_page(number) end)
            end
            -- 阅读进度: 历史页要显示「第N话 · 第3/20页」(写盘由 recordProgress 节流)
            pcall(function()
                PicaReader:recordProgress(number, self.number_of_pages)
            end)
            local ret = orig_update(self, number, orig_mode)
            -- 先让 KOReader 排好它自己的 "ui"/"partial", 再追加整屏刷新 (会被合并)
            PicaReader:forceFullRefresh(ui)
            return ret
        end
        paging._picayomi_wrapped_update = true
    end

    -- 滚动模式的残影: 每一步都整屏刷会频闪, 而 KOReader 在滚动期间会把所有刷新
    -- 降级成 fast (fast 又不参与"每 N 次补一次全刷"), 残影会越叠越重。
    -- 在这两个滚动入口上挂"停手后补一次全刷"的防抖 —— 覆盖**页内**平移
    -- (PageUpdate 只在页码变化时才发, 页内滚 100px 不会触发它)。
    if paging.onScrollPanRel and not paging._picayomi_wrapped_scroll then
        local orig_pan = paging.onScrollPanRel
        paging.onScrollPanRel = function(self, diff)
            local ret = orig_pan(self, diff)
            PicaReader:scheduleScrollRefresh(ui)
            return ret
        end
        local orig_scroll_page = paging.onScrollPageRel
        if orig_scroll_page then
            paging.onScrollPageRel = function(self, diff, no_page_turn)
                local ret = orig_scroll_page(self, diff, no_page_turn)
                PicaReader:scheduleScrollRefresh(ui)
                return ret
            end
        end
        paging._picayomi_wrapped_scroll = true
    end
end

--- 打印页脚诊断信息 (只读, 不改任何东西)
--
-- 为什么这里只做诊断、不再"修"页脚:
--   book_time_to_read / chapter_time_to_read 的实现是
--     footer.ui.statistics and footer.ui.statistics:getTimeForPages(left) or _("N/A")
--   (readerfooter.lua:340/347)。它们显示 N/A **只有一个原因** —— KOReader 的
--   statistics 插件没给这个文档算过阅读速度 (avg_time)。
--
--   而这个原因在我们这边是 `StreamDocument.is_pic` (见 ui/stream_reader.lua 里
--   is_pic 的注释)。把 is_pic 改成 false 之后统计会正常初始化, 这两项直接显示
--   真实时长, **用户在 KOReader 里选的显示项一个字都不用动**。
--
--   曾经的做法是"发现当前项需要统计就换一个能用的项 / 把统计项从生成器列表里
--   摘掉"。那是治标 —— 页脚内容会和用户在 KOReader 里的设置对不上, 看起来就是
--   "插件把我的页脚改掉了"。根因修掉之后, 那一整段逻辑删掉了。
--
--   注意: 如果用户自己在 KOReader 里**关掉了"阅读统计"**, 这两项对所有书
--   (包括普通 epub) 都会显示 N/A —— 那是 KOReader 自己的行为, 插件不该覆盖。
function PicaReader:logFooterState(footer)
    if not (footer and footer.settings and footer.mode_index) then return end

    local cur_name = footer.mode_index[footer.mode]
    local stats = footer.ui and footer.ui.statistics
    if logger.enabled then logger.info(string.format(
        "Picayomi Reader: 页脚状态 mode=%s(%s) all_at_once=%s visible=%s bar=%sx%s 统计=%s(avg_time=%s)",
        tostring(footer.mode), tostring(cur_name),
        tostring(footer.settings.all_at_once and true or false),
        tostring(footer.view and footer.view.footer_visible),
        tostring(footer.progress_bar and footer.progress_bar.width),
        tostring(footer.progress_bar and footer.progress_bar.height),
        stats and tostring(stats.is_doc) or "无",
        stats and tostring(stats.avg_time) or "-")) end
end

--- 页脚诊断: 读一次 `ui.view.footer` 就够 (名字保留, 语义已退化)
--
-- **为什么不再递归找、也不用重试**: 页脚是 ReaderView 在 `ui.view` 上**同步**
-- 建好的 (`apps/reader/modules/readerview.lua:131` 的
-- `self.footer = ReaderFooter:new{...}`), 而 `ui.view` 是 ReaderUI:new 注册的
-- 第 1 个子模块 (`readerui.lua:153`) —— 插件 init 跑在 `readerui.lua:463` 的
-- 插件循环里, 那时 `ui.view.footer` 必然已经存在。
--
-- 旧代码之所以要"递归 + 每 0.5s 重试 20 次", 根因是**调用点太早**
-- (getAndOpenComic 刚返回, ReaderUI 实例还没建), 而不是页脚难找。换成
-- `registerPostInitCallback` 之后这个时序问题不存在了, 重试逻辑一并删掉。
function PicaReader:adaptFooterWithRetry(ui)
    local footer = ui and ui.view and ui.view.footer
    if not footer then return end
    self._footer_checked = true   -- 找到了就记下 (诊断日志只打一次)
    self:logFooterState(footer)
end

-- ==================== 边缘滑动退出 ====================
--
-- 规则 (与列表页/详情页/菜单统一, 见 ui/common/swipe_rules.lua):
--   **从最左/最右 8% 往中间划 = 退出阅读**;
--   中间区域左右滑仍然交给 KOReader 翻页 (west = 下一页, east = 上一页), 点两侧照旧。
--
-- 为什么必须注册成 touch zone + overrides:
--   翻页手势是 ReaderPaging 注册的**整屏**触摸区 `paging_swipe`
--   (readerpaging.lua:104)。触摸区按 DepGraph 顺序逐个 match, 第一个 handler
--   返回 true 的吃掉手势; 不写 overrides 我们的区永远排在它后面, 收不到事件。
--
-- 为什么每个边缘只认"往中间"那个方向:
--   左边缘再往左、右边缘再往右都没有物理空间, 用户实际做不出这种手势; 而竖向
--   滑动是能发生的 (在边缘上竖着划一下), 那不该被当成退出。
--
-- 宽度 / 允许哪一侧 / 是否启用都是设置项 (设置 -> 操作与手势), 规则本身在
-- ui/common/swipe_rules.lua —— 阅读页与列表页/详情页/菜单共用同一套判定。
function PicaReader:installEdgeSwipeToExit(reader_ui)
    if not (reader_ui and type(reader_ui.registerTouchZones) == "function") then
        return false
    end
    local self_ = self

    reader_ui:registerTouchZones({
        {
            id = "picayomi_reader_edge_back",
            ges = "swipe",
            -- **整屏**注册, 判定交给 SwipeRules:
            --   边缘宽度 / 允许哪一侧 / 是否启用都是设置项 (设置 -> 操作与手势),
            --   在注册时把几何写死的话, 用户改完设置要重开阅读器才生效。
            --   不是边缘返回时返回 false, dispatch 会继续试后面的翻页区
            --   (inputcontainer.lua:267)。
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            -- 必须排在整屏翻页区之前 (见上面的说明)
            overrides = { "paging_swipe", "rolling_swipe", "swipe_link" },
            handler = function(ges)
                -- **先收掉在途的 pan, 再做任何事。**
                --
                -- 我们覆盖了 paging_swipe (见上面的 overrides), 于是
                -- ReaderPaging:onSwipe 里"pan 还在进行 -> onPanRelease()"那段
                -- 不会跑了。而 _pan_page_states_to_restore 是 pan 开始时记下的
                -- **page_states 表引用**: 如果 pan 还没滚 (按下不到 500ms 激活
                -- 延迟) 就先跑了下面那句 onGotoViewRel, onScrollPageRel 会
                -- table.remove 这张表 —— 一屏只有 1 页时它就被清空了, 而
                -- _pan_started 还留着。
                --
                -- 之后任何一次 HandledAsSwipe (用户的 short_diagonal_swipe =
                -- 全屏刷新就会发) 会拿这张空表回滚:
                --   readerpaging.lua:529  page_states[#page_states].page
                -- -> 索引 nil -> 整个 KOReader 退出。真机 2026-10-18 20:38 即此。
                local paging = reader_ui.paging
                if paging and paging._pan_started then
                    pcall(function() paging:onPanRelease() end)
                end
                if SwipeRules.isBackSwipe(ges) then
                    if logger.enabled then logger.info("Picayomi Reader: 边缘滑动, 退出阅读") end
                    self_:onReturn()
                    return true
                end
                -- 连续滚动模式: 只保留"上下滚动", 左右划不再翻页。
                --
                -- 竖划 = 滚一屏 (与点屏幕两侧等价); 横划 = 吃掉。
                --   以前这里只吞横划, 竖划"交给 ReaderPaging 的 pan" —— 但 pan
                --   要求**按住拖动**, 用户习惯的快速一划 (swipe) 在竖向上什么都不做,
                --   真机上的感受就是"没有上下滑动能力"。现在快划滚一屏, 慢拖仍然
                --   由 ReaderPaging 的 pan 连续滚动。
                --
                -- 横划必须吃掉: ReaderPaging:onSwipe 在滚动模式下会把横划当成
                -- "翻一页" (onGotoViewRel -> onScrollPageRel), 用户滚到一半手一偏
                -- 就整屏跳走。
                --
                -- 左右边缘的竖划**不抢**: 那里是 KOReader 的亮度/色温手势区
                -- (见 SwipeRules.inGestureEdge)。返回 false 让事件继续往下传。
                local view = reader_ui.view
                if view and view.page_scroll then
                    if SwipeRules.axisOf(ges) == "vertical" then
                        if SwipeRules.inGestureEdge(ges) then return false end
                        -- 手指往上划 = 往下看 (与"点右侧前进"一致)
                        local forward = true
                        local pos, end_pos = ges and ges.pos, ges and ges.end_pos
                        if pos and end_pos and pos.y and end_pos.y then
                            forward = end_pos.y < pos.y
                        elseif ges and ges.direction == "south" then
                            forward = false
                        end
                        pcall(function()
                            reader_ui.paging:onGotoViewRel(forward and 1 or -1)
                        end)
                        return true
                    end
                    -- 横向 (含斜向): 吃掉, 不翻页
                    return true
                end
                return false
            end,
        },
    })
    return true
end

--- 安装阅读器侧的钩子 (翻页预取提示 + 页脚修正 + 左边缘退出)
--
-- 单独抽成函数是为了能被测试直接调用; 曾经因为把钩子挂在
-- PicaReader:hookWithPriorityOntoReaderUiEvents 里 (那个函数只被
-- initializeFromReaderUI 调用, 而它全项目没有调用点) 导致这两个功能
-- 一直是死代码 —— 表现为"阅读页没有加载提示"+"页脚一直 N/A"。
function PicaReader:installReaderHooks(reader_ui)
    if not (reader_ui and reader_ui.paging) then
        if logger.enabled then logger.info("Picayomi Reader: 没有 paging 模块, 跳过翻页钩子") end
    else
        self:hookPageTurns(reader_ui)
    end
    -- 把会话接到调度驱动上 (tick 链的唯一起点; 见 ui/reader_bridge.lua)。
    -- 没有文档/会话时 (测试里的桩 ui) 直接跳过。
    local doc = reader_ui and reader_ui.document
    if doc and doc.session then
        ReaderBridge.install(reader_ui, doc.session)
    end
    -- 页脚诊断: 只读 `ui.view.footer`, 不改任何设置 (见 adaptFooterWithRetry)
    self:adaptFooterWithRetry(reader_ui)
    -- 左边缘右滑 = 退出阅读 (见 installEdgeSwipeToExit)
    self:installEdgeSwipeToExit(reader_ui)
end

--- 这个文档是不是本插件的流式文档
local function is_stream_doc(ui)
    local doc = ui and ui.document
    return (doc and doc.provider == "picayomi_stream") and ui or nil
end

--- 阅读器 init 完成后的**确定性**接线点 (取代旧的"轮询 ReaderUI.instance")
--
-- 由 `main.lua` 的 `ui:registerPostInitCallback` 调用。时序 (都指
-- `koreader/frontend/apps/reader/readerui.lua`):
--
--   :153  registerModule("view")   -> `ui.view.footer` 已经建好
--   :297  registerModule("paging") -> `ui.paging` 已经建好
--   :463  插件循环                 -> 插件 init 在这里注册 postInitCallback
--   :486  postInitCallback 触发    <-- 我们在这里装钩子
--   :517  ReaderReady 事件
--   :520  postReaderReadyCallback 触发
--   :546  ReaderUI.instance = self
--
-- 注意 :486 时 **ReaderUI.instance 还没赋值** —— 所以这里不能用
-- `ReaderUI.instance` 反查, 必须用插件手里的 `self.ui` (它就是那个 ReaderUI)。
-- 旧代码就是栽在这里: 它只能在 `getAndOpenComic` 返回后去猜
-- `ReaderUI.instance`, 而那时实例还没建, 于是排定时器轮询最多 15 秒。
function PicaReader:onReaderInit(reader_ui)
    if not is_stream_doc(reader_ui) then return end
    -- 换章兜底: switchDocument 的 after_open 没能跑到时 (失败/被中断),
    -- 这个标记不能永久留着 —— 否则退出阅读时再也不还原屏幕方向。
    self._switching = nil
    self:suppressForeignSync(reader_ui)
    self:attachReaderHooks(reader_ui)
end

--- ReaderReady 之后的兜底接线点
--
-- `ReaderReady` 事件之后 KOReader 才认为"文档已加载并渲染", 页码这时才有意义,
-- 所以「开始」的第二道保证 (页码拨回 1) 放在这里, 而不是 postInitCallback。
function PicaReader:onReaderReady(reader_ui)
    if not is_stream_doc(reader_ui) then return end
    self:enforceStartFromBeginning(reader_ui)
    self:announceScrollMode(reader_ui)
end

--- 进入条漫章节时提示一次"现在是滚动模式"
--
-- 为什么要提示: 滚动模式和用户习惯的"翻页"完全不同 (没有整页跳转, 上下滑动,
-- 屏幕位置在页面中间), 不说明的话第一反应是"怎么翻不动了/画面卡住了"。
--
-- 只提示**一次** (记在会话上, 换一话重新算): 每一话都弹会烦。而且只在真的
-- 进了滚动模式时弹 —— 用户自己改过视图模式 (文档设置里的 kopt_page_scroll)
-- 的话 view.page_scroll 是 false, 这时不该说"已进入滚动阅读模式"。
function PicaReader:announceScrollMode(reader_ui)
    local doc = reader_ui and reader_ui.document
    local session = doc and doc.session
    if not (session and session.view_mode == ViewMode.SCROLL) then return end
    if session.scroll_notice_shown then return end
    session.scroll_notice_shown = true

    local view = reader_ui.view
    if not (view and view.page_scroll) then return end

    -- 只弹前两次 (跨章节/跨启动累计)。之后再进来靠打开时的加载文案提示
    -- (api/comic.lua 的"正在打开阅读器…（条漫：…）"), 不再每次挡一下。
    if not ViewMode.take_notice() then
        if logger.enabled then logger.info("Picayomi Reader: 条漫章节, 已进入滚动阅读模式 (提示次数已用完)") end
        return
    end

    UIManager:show(InfoMessage:new{
        text = _("已进入滚动阅读模式\n上下滑动阅读 · 可在 设置 → 阅读设置 中修改"),
        timeout = 5,
    }, "ui")
    if logger.enabled then logger.info("Picayomi Reader: 条漫章节, 已进入滚动阅读模式") end
end

--- 临时挡掉别的插件的"跨设备进度同步"
--
-- 为什么: 设备上装着 Progress sync (kosync) 和 Readest, 两者的 auto_sync 都是 true。
-- 它们都在 ReaderReady 之后**异步**拉一次服务器进度, 拿到就 GotoPage —— 于是
-- 「开始」(固定从第 1 页读) 会被拉到别的设备看到的那一页。这类全局插件对
-- "插件自己管理的文档"没有任何意义: 它们记的是**它们自己的页码**, 和我们的
-- 流式文档不是一回事。
--
-- 两个插件的关法不一样, 差别在**要不要动持久设置**:
--
--   * kosync: 它的 onReaderReady 读 self.settings.auto_sync, 改内存里的
--     settings 表就能让它既不拉也不推; 关文档时放回去。它的 settings 来自
--     自己的 settings/kosync.lua, 我们改的这一份会在退出时被它自己写回原值。
--   * readest: self.settings 是 **G_reader_settings 里那张表的引用**, 而
--     G_reader_settings 会被 KOReader 随时落盘 —— 改它等于**永久**关掉用户的
--     同步, 一旦中途落盘就再也回不来。所以这里改成**包一层方法**: 只丢掉
--     "非交互"(自动)的那次 pullBookConfig, 菜单里手点"立即拉取"照常工作,
--     设置一个字都不碰。
--
-- 只认 name, 不 require 那个插件的模块: 没装/改名/版本不同时静默跳过,
-- 绝不会因为"别人的插件长什么样"把我们的阅读器打崩。
--
-- **name 在 ReaderUI 里是带前缀的**: readerui.lua:97 的 registerModule 会写
-- `ui_module.name = "reader" .. name` —— 所以 readest 在这里叫 "readerreadest",
-- kosync 叫 "readerkosync"。0.9.9 那版直接比 "readest"/"kosync", 于是**从来没
-- 匹配上过** (真机 2026-10-18: 打开漫画仍然弹「进度已同步」, 日志里也没有
-- "已屏蔽 Readest"); 当时的用例用 name="readest" 的假表测, 所以是绿的。
-- 这里两种写法都认: 前缀是 KOReader 的实现细节, 不该成为我们失效的理由。
local function plugin_base_name(child)
    local n = child and child.name
    if type(n) ~= "string" then return nil end
    return (n:match("^reader(.+)$")) or n
end

function PicaReader:suppressForeignSync(reader_ui)
    if type(reader_ui) ~= "table" then return end
    -- 累加到已有的撤销表上, **不能**把它清掉: 同一个会话里可能被调用两次
    -- (换章重入), 第二次两个插件都已在屏蔽中、什么也没做, 清掉就等于把第一次
    -- 记下的"原值"弄丢了 —— 关文档时再也放不回去 (测试当场抓到)。
    local undo = self._foreign_sync or {}

    for _i, child in ipairs(reader_ui) do
        if type(child) == "table" and plugin_base_name(child) == "kosync"
           and type(child.settings) == "table"
           and not child._picayomi_sync_blocked then
            local prev = child.settings.auto_sync
            child.settings.auto_sync = false
            child._picayomi_sync_blocked = true
            undo[#undo + 1] = function()
                if type(child.settings) == "table" then
                    child.settings.auto_sync = prev
                end
                child._picayomi_sync_blocked = nil
            end
            if logger.enabled then logger.info("Picayomi Reader: 已临时关闭 Progress sync 的自动同步"
                .. " (它会把页码拉到别的设备的进度上) [" .. tostring(child.name) .. "]") end
            break
        end
    end

    for _i, child in ipairs(reader_ui) do
        if type(child) == "table" and plugin_base_name(child) == "readest"
           and type(child.pullBookConfig) == "function"
           and not child._picayomi_pull_blocked then
            local orig = child.pullBookConfig
            child.pullBookConfig = function(inst, interactive, ...)
                if not interactive then
                    -- 非交互 = 打开/唤醒/联网时自己拉的那次。它拉到远端页码就
                    -- GotoPage, 而且**不管我们有没有拦下跳转都会弹
                    -- 「阅读进度已同步」** —— 那个提示是假的, 页码根本没动。
                    if logger.enabled then logger.info("Picayomi Reader: 忽略 Readest 的自动进度拉取"
                        .. " (它会拨走页码并弹「进度已同步」)") end
                    return
                end
                return orig(inst, interactive, ...)
            end
            child._picayomi_pull_blocked = true
            undo[#undo + 1] = function()
                child.pullBookConfig = orig
                child._picayomi_pull_blocked = nil
            end
            if logger.enabled then logger.info("Picayomi Reader: 已屏蔽 Readest 的自动进度拉取 [" .. tostring(child.name) .. "]") end
            break
        end
    end

    -- 自动上传会 fork 同步 worker, 在低内存阅读时与下载/解码争用内存。
    -- 关闭文档还会上传笔记/统计/书目, 也要挡住这些非交互入口。
    -- 与 pull 一样只挡非交互调用, 不改共享的持久设置。
    for _i, child in ipairs(reader_ui) do
        if type(child) == "table" and plugin_base_name(child) == "readest"
           and not child._picayomi_push_blocked then
            for _j, method in ipairs({ "pushBookConfig", "pushBookNotes", "pushBookStats", "pushOpenBook" }) do
                local orig = child[method]
                if type(orig) == "function" then
                    child[method] = function(inst, interactive, ...)
                        if not interactive then return end
                        return orig(inst, interactive, ...)
                    end
                    undo[#undo + 1] = function() child[method] = orig end
                end
            end
            child._picayomi_push_blocked = true
            undo[#undo + 1] = function()
                child._picayomi_push_blocked = nil
            end
            if logger.enabled then logger.info("Picayomi Reader: 已屏蔽 Readest 的自动进度上传") end
        end
    end

    if #undo > 0 then self._foreign_sync = undo end
end

--- 把 suppressForeignSync 挡掉的东西原样放回去
function PicaReader:restoreForeignSync()
    local undo = self._foreign_sync
    self._foreign_sync = nil
    if type(undo) ~= "table" then return end
    for _i, fn in ipairs(undo) do pcall(fn) end
end

--- 兜底接线: 实例若已就绪就直接装, 否则什么都不做 (**不再轮询**)
--
-- 保留它是因为换章路径 (`switchToChapter` 的 `after_open`) 需要在这里兜一下:
-- `after_open_callback` 触发时 (readerui.lua:525) 仍早于
-- `ReaderUI.instance = self` (:546), 所以这一次调用**通常读不到新实例** ——
-- 真正装钩子的是新实例自己的 postInitCallback (见 `onReaderInit`)。
-- 旧实现靠 0.25s×60 的轮询在这里等实例出现; 现在时序由 KOReader 保证, 删掉。
function PicaReader:attachHooksWhenReady()
    local ui = is_stream_doc(ReaderUI.instance)
    if ui then
        self:attachReaderHooks(ui)
    end
end

--- 在就绪的 ReaderUI 实例上装钩子 (同一实例只装一次)
--
-- 这里**不写** `reader_ui.pica_end_callback` / `pica_return_callback` 这类字段:
-- 它们以前只有那个从未被安装的 eventListener 会读, 属于"写了没人看"的死接线。
-- 现在两条路都走 KOReader 自己的机制:
--   * 读到末尾 -> `EndOfBook` 事件冒泡到插件实例 -> `Picayomi:onEndOfBook`
--   * 关闭阅读器 -> `CloseWidget` 事件冒泡 -> `Picayomi:onCloseWidget`
--- 注册一个 Dispatcher 动作, 让用户把手势绑到「退出阅读」上
--
-- KOReader 的手势管理器支持**分区**: 同一个滑动可以按屏幕区域绑不同动作 ——
-- 中间滑 = 翻页, 边缘滑 = 退出。但手势只能绑 Dispatcher 里的动作, 插件不注册的话
-- 用户只能选 KOReader 的「文件浏览器」(那会把整个插件上下文丢掉, 不是"退回详情页")。
--
-- 注册是幂等的: 动作只在启动时进一次 settingsList。
function PicaReader:registerExitAction()
    if PicaReader._exit_action_registered then return true end
    local ok, Dispatcher = pcall(require, "dispatcher")
    if not ok or type(Dispatcher) ~= "table"
        or type(Dispatcher.registerAction) ~= "function" then
        return false
    end
    local rok = pcall(function()
        Dispatcher:registerAction("picayomi_exit_reader", {
            category = "none",
            event = "PicayomiExitReader",
            title = _("Picayomi: 退出阅读"),
            reader = true,
        })
    end)
    if rok then PicaReader._exit_action_registered = true end
    return rok
end

function PicaReader:attachReaderHooks(reader_ui)
    if self._hooks_reader_ui == reader_ui then return end
    self._hooks_reader_ui = reader_ui

    -- 手势 -> Dispatcher 事件 -> 这里。动作与页脚「返回」完全相同 (回详情页),
    -- 不是 KOReader 的「文件浏览器」(那会丢掉插件的来路)。
    self:registerExitAction()
    reader_ui.onPicayomiExitReader = function()
        self:onReturn()
    end

    -- 重新注册菜单项（确保包含最新的章节导航）
    if reader_ui.menu then
        reader_ui.menu:registerToMainMenu(self)
    end

    -- 翻页预取提示 + 页脚修正
    self:installReaderHooks(reader_ui)
end

--- 「开始」的第二道保证: 阅读器就绪后确认停在第一页
--
-- 主保证在打开文档之前 (api/comic.lua:prepareComic 清掉 KOReader 记住的页码),
-- 正常情况下这里看到的就已经是第 1 页, 不会做任何事。
--
-- 但**别的插件会在就绪之后再改页码**: 最典型的是 Progress sync 的 auto_sync ——
-- 它在 ReaderReady 之后异步拉一次服务器进度, 拿到就 GotoPage。suppressForeignSync
-- 已经把它关掉, 这里是"不依赖任何插件行为"的那道兜底: 在一个很短的窗口里复核几次。
--
-- 两条边界:
--   * 用户一旦**自己**翻页 (onGotoPageRel) 就立刻停 —— 绝不能把用户拨回去;
--     程序性跳转 (GotoPage, 含别的插件) 不算, 否则兜底自己就把自己关掉了;
--   * 换章 / 关文档时 token 变掉, 定时器自然失效 (不会去动新文档的页码)。
PicaReader.START_ASSERT_DELAYS = { 0.4, 1.2, 2.5 }

function PicaReader:enforceStartFromBeginning(reader_ui)
    local doc = reader_ui and reader_ui.document
    local session = doc and doc.session
    if not (session and session.context and session.context.from_beginning) then return end

    local paging = reader_ui.paging
    if not paging then return end

    -- 第三道保证: 打开后到"用户第一次碰设备"之间, 禁止任何**程序性**跳页把页码
    -- 拨离第 1 页 (见 hookPageTurns 里 onGotoPage 包装的判据)。
    --
    -- 为什么定时复核不够 (真机 2026-10-18): readest 的 auto_sync 在打开文档
    -- **5 秒后**才拿到远端进度并 GotoPage —— 复核窗口 (0.4/1.2/2.5s) 早过去了,
    -- 用户看到的就是"点开始却从历史处继续"。
    --
    -- 判据用"用户碰没碰过设备", 不用时间窗: 时间窗短了盖不住慢同步, 长了会把
    -- 用户的跳页弹窗也拨回去。任何输入事件 (翻页/点菜单/跳页) 都算用户意图。
    if session.release_start_guard then session.release_start_guard() end
    session.start_guard = true
    local tasks = {}
    local on_user_input
    session.release_start_guard = function()
        if on_user_input then UIManager.event_hook:unregister("InputEvent", on_user_input) end
        for _, callback in ipairs(tasks) do UIManager:unschedule(callback) end
        session.start_guard = false
        session.release_start_guard = nil
    end
    if UIManager.event_hook and UIManager.event_hook.register then
        on_user_input = function()
            session.start_guard = false
            -- 同一个含义也交给定时复核用 (它们看的是 user_turned_page):
            -- 用户一旦碰过设备, 就不该再被自动拨回 —— 哪怕他只是点开菜单没翻页。
            -- 宁可让后台同步赢一次, 也绝不能和用户抢页码。
            session.user_turned_page = true
            session.release_start_guard()
        end
        UIManager.event_hook:register("InputEvent", on_user_input)
    end

    self._start_assert_seq = (self._start_assert_seq or 0) + 1
    local seq = self._start_assert_seq

    local function check(tag)
        if self._start_assert_seq ~= seq then return end
        -- 文档已经被换掉 (换章/关了重开): 别去动新文档的页码。
        -- 用"还是不是同一个 document 对象"判断, 而不是 is_stream_doc ——
        -- 后者要求 provider 字段, 桩出来的 ReaderUI 没有它, 会把兜底整个关死。
        if reader_ui.document ~= doc then return end
        -- 用户已经自己翻过页 -> 兜底必须停手 (见 hookPageTurns 里的置位)
        if session.user_turned_page then return end

        local page = tonumber(paging.current_page) or 1
        -- <= 1 都算"已经在第一页": 刚初始化时 current_page 可能是 0
        if page <= 1 then return end

        logger.warn(string.format(
            "Picayomi Reader: 「开始」本应停在第 1 页, 实际在第 %d 页 (%s) —— 已强制拨回",
            page, tag))
        paging:onGotoPage(1)
    end

    check("就绪时")
    for _i, delay in ipairs(PicaReader.START_ASSERT_DELAYS) do
        local callback = function()
            check(string.format("+%.1fs", delay))
        end
        tasks[#tasks+1] = callback
        UIManager:scheduleIn(delay, callback)
    end
end

-- 添加到主菜单
function PicaReader:addToMainMenu(menu_items)
    -- Exit reading through Tools -> 返回 Picayomi; no duplicate source-named
    -- return entry in the Main tab, including when a menu table is reused.
    menu_items.go_back_to_picayomi = nil

    -- 新增：添加章节导航菜单
    if self.current_comic and self.episodes_list then
        menu_items.pica_chapter_nav = {
            text = _("章节导航"),
            sorting_hint = "navigation",
            sub_item_table = self:buildChapterNavMenu(),
        }
    end
end

-- 构建章节导航菜单
function PicaReader:buildChapterNavMenu()
    local sub_menu = {}

    if not self.episodes_list or not self.current_episode_index then
        return sub_menu
    end

    -- 上一章节
    if self.current_episode_index > 1 then
        local prev_episode = self.episodes_list[self.current_episode_index - 1]
        table.insert(sub_menu, {
            text = _("上一章节: ") .. (prev_episode.title or "第" .. prev_episode.order .. "话"),
            callback = function()
                self:switchToChapter(self.current_episode_index - 1)
            end
        })
    end

    -- 下一章节
    if self.current_episode_index < #self.episodes_list then
        local next_episode = self.episodes_list[self.current_episode_index + 1]
        table.insert(sub_menu, {
            text = _("下一章节: ") .. (next_episode.title or "第" .. next_episode.order .. "话"),
            callback = function()
                self:switchToChapter(self.current_episode_index + 1)
            end
        })
    end

    -- 章节列表
    table.insert(sub_menu, {
        text = _("章节列表"),
        callback = function()
            self:showChapterList()
        end
    })

    return sub_menu
end

-- 切换到指定章节
--
-- 实现: 用 `ReaderUI.instance:switchDocument(path, nil, after_open, provider)`
-- **在当前阅读器里换文档**, 而不是"关掉阅读器 -> 重开文件浏览器 -> 再开阅读器"。
-- 后者会闪一下文件管理器 (真机上肉眼可见), 前者不会。
--
-- 为什么必须在 after_open 里重新装钩子: switchDocument 内部其实是
-- `onClose(false)` + `showReader(...)`, 也就是**会重建一个 ReaderUI 实例** ——
-- 菜单注册 / 返回回调 / 翻页钩子都挂在实例上, 所以换了实例就得重装。
-- 主接线点其实是新实例自己的 postInitCallback (main.lua 注册 -> onReaderInit),
-- 它比这里更早、且拿得到正确的实例; 这里的调用是兜底 (after_open_callback 触发时
-- readerui.lua:525 仍早于 :546 的 `ReaderUI.instance = self`, 所以常常读不到新实例)。
function PicaReader:switchToChapter(episode_index)
    if self._chapter_loading then return false end
    if not self.episodes_list or episode_index < 1 or episode_index > #self.episodes_list then
        logger.err("PicaReader", "无效的章节索引: " .. tostring(episode_index) ..
                  " (总章节数: " .. tostring(self.episodes_list and #self.episodes_list or 0) .. ")")
        UIManager:show(InfoMessage:new{
            text = _("章节不存在或索引无效"),
        }, "ui")
        return false
    end

    local episode = self.episodes_list[episode_index]
    if not episode then
        logger.err("PicaReader", "章节 #" .. episode_index .. " 不存在")
        UIManager:show(InfoMessage:new{
            text = _("章节不存在"),
        }, "ui")
        return false
    end

    if not self.current_comic then
        logger.err("PicaReader", "当前漫画信息缺失，无法切换章节")
        UIManager:show(InfoMessage:new{
            text = _("漫画信息缺失，无法切换章节"),
        }, "ui")
        return false
    end

    local episode_title = episode.title or ("第" .. (episode.order or "?") .. "话")
    if logger.enabled then logger.info("PicaReader", "切换到章节: " .. episode_title .. " (" .. episode_index .. "/" .. #self.episodes_list .. ")") end

    -- 老版 KOReader 没有 switchDocument: 回退到"关掉再开"
    local ui = ReaderUI.instance
    if not (ui and type(ui.switchDocument) == "function") then
        if logger.enabled then logger.info("PicaReader", "当前 ReaderUI 不支持 switchDocument, 回退到关掉重开") end
        return self:switchToChapterLegacy(episode_index)
    end

    -- prepareComic 里有网络请求 (取章节图片列表), 必须先把提示画出来,
    -- 否则请求期间界面看起来像卡死。
    -- switchDocument closes the old reader before asynchronously opening the
    -- new one. Keep a fullscreen loading layer over the detail page throughout
    -- that gap, including KOReader's forced repaint while opening a document.
    local loading = InfoMessage:new{
        text = T(_("正在加载 %1…"), episode_title),
        dismissable = false,
        covers_fullscreen = true,
    }
    function loading:paintTo(bb, x, y)
        bb:paintRect(0, 0, Screen:getWidth(), Screen:getHeight(),
            require("ffi/blitbuffer").COLOR_WHITE)
        InfoMessage.paintTo(self, bb, x, y)
    end
    function loading:getVisibleArea() return Screen:getSize() end
    self._chapter_loading = loading
    local function close_loading()
        if self._chapter_loading ~= loading then return end
        self._chapter_loading = nil
        self._switching = nil
        LoadingTask.close(loading)
        UIManager:setDirty(nil, "ui", Screen:getSize())
    end
    UIManager:show(loading, "ui")
    UIManager:setDirty(loading, "ui", Screen:getSize())
    UIManager:forceRePaint()

    local comic_api = require("api.comic")
    local old_doc = ui.document
    local old_session = old_doc and old_doc.session
    local view_mode_hint
    if old_session and not old_session.cancelled and old_session.source
            and tostring(old_session.comic_id) == tostring(self.current_comic._id) then
        -- 只传版式与身份, 不把整个旧会话留在新上下文里 (会拖住旧文档与缓存)。
        view_mode_hint = {
            comic_id = old_session.comic_id,
            source_id = old_session.source.identifier,
            mode = old_session.view_mode,
        }
    end
    -- Unlike ordinary fetch prompts, this one stays until the new ReaderUI
    -- reaches the window stack. Still close it on preparation/open exceptions.
    local prepared, ok, path, doc_class, new_session, err = pcall(
        comic_api.prepareComic, comic_api,
        self.current_comic._id, tostring(episode.order), {
            comic = self.current_comic,
            source_id = self.source_id or (old_session and old_session.source and old_session.source.identifier),
            offline = self.offline,
            episodes = self.episodes_list,
            episode = episode,
            view_mode_hint = view_mode_hint,
        })
    if not prepared then err, ok = ok, false end

    if not ok then
        close_loading()
        logger.err("PicaReader", "准备章节失败: " .. tostring(err))
        UIManager:show(InfoMessage:new{
            text = require("ui.common.error_message").describe(err, _("加载章节失败，请重试。")),
            timeout = 3,
        }, "ui")
        return false
    end

    if new_session then
        new_session.release_downloads = require("util.reading_resources").pause()
    end

    -- 新会话的 prev_rotation 是刚才在横屏状态下量到的 —— 直接用它, 退出时会把
    -- 屏幕还原成横屏。要把**最初打开阅读器之前**的方向带过去 (见 restoreScreenRotation)。
    if new_session and old_session and old_session.prev_rotation ~= nil then
        new_session.prev_rotation = old_session.prev_rotation
    end

    -- 先更新模块状态, 再换文档: 换完文档后菜单/回调会重新读取这些字段
    local previous_episode, previous_index = self.current_episode, self.current_episode_index
    self.current_episode = episode
    self.current_episode_index = episode_index

    -- 换章期间**不要**还原屏幕方向 (见 onReaderClosed): 新章节若是横屏, 屏幕本来就
    -- 该一直是横的, 中间转回来一次会闪一帧竖屏; 而且新会话记下的"打开前方向"会
    -- 变成横屏, 退出时就会还原成横屏。
    self._switching = true
    if Diag.enabled then Diag.mark(string.format("open %s 第%s话: 切换阅读器…",
        tostring(self.current_comic._id), tostring(episode.order))) end
    local switched, switch_err = pcall(ui.switchDocument, ui, path, true, function()
        if Diag.enabled then Diag.mark(string.format("open %s 第%s话: 换章阅读器已打开",
            tostring(self.current_comic._id), tostring(episode.order))) end
        self._switching = nil
        self:attachHooksWhenReady()
    end, doc_class)
    if not switched then
        close_loading()
        if new_session then new_session:cancel() end
        self.current_episode, self.current_episode_index = previous_episode, previous_index
        logger.err("PicaReader", "切换章节失败: " .. tostring(switch_err))
        UIManager:show(InfoMessage:new{ text = _("加载章节失败"), timeout = 3 }, "ui")
        return false
    end
    -- KOReader queues doShowReader before returning from switchDocument. This
    -- continuation runs after that opening attempt, also removing the cover if
    -- KOReader reports an asynchronous document failure instead of calling us.
    UIManager:nextTick(function()
        close_loading()
        local active = ReaderUI.instance
        if new_session and new_session.cancel
                and not (active and active.document and active.document.session == new_session) then
            new_session:cancel()
        end
    end)

    return true
end

-- 换章的旧实现 (回退用): 关掉阅读器再重新打开
--
-- 只在 ReaderUI 没有 switchDocument 时走这里。它会经过
-- closeReaderUi (关阅读器 + 重开文件浏览器), 因此真机上会闪一下。
function PicaReader:switchToChapterLegacy(episode_index)
    local episode = self.episodes_list[episode_index]
    local episode_title = episode.title or ("第" .. (episode.order or "?") .. "话")

    -- 关闭当前阅读器
    self:closeReaderUi(function()
        -- 打开新章节
        local success = self:open(self.current_comic, episode, self.episodes_list, self.on_return_callback)
        if not success then
            logger.err("PicaReader", "打开章节失败: " .. episode_title)
            -- 如果打开失败，返回到主页
            if self.on_return_callback then
                self.on_return_callback()
            end
        end
    end)

    return true
end

-- 显示章节列表
function PicaReader:showChapterList()
    if not self.current_comic or not self.episodes_list then
        return
    end

    local menu_items = {}

    for i, episode in ipairs(self.episodes_list) do
        local title = episode.title or ("第" .. episode.order .. "话")
        if i == self.current_episode_index then
            title = "● " .. title .. " (当前)"
        end

        table.insert(menu_items, {
            text = title,
            callback = function()
                -- 注意: 原来这里写的是 UIManager:close() (没传控件),
                -- 等于什么都没关 —— 选完章节后列表会一直盖在屏幕上。
                -- 另外关闭时必须带刷新模式, 否则屏幕不会更新 (见 ui/home.lua 的说明)。
                if self.chapter_menu then
                    UIManager:close(self.chapter_menu, "ui")
                    self.chapter_menu = nil
                end
                if i ~= self.current_episode_index then
                    self:switchToChapter(i)
                end
            end
        })
    end

    -- 「返回」: 去掉右上角 ✕ 之后, 这里必须有一个看得见的退出口
    -- (列表里全是章节, 用户只是想"不改了, 退出去")
    table.insert(menu_items, {
        text = _("返回"),
        callback = function()
            if self.chapter_menu then
                UIManager:close(self.chapter_menu, "ui")
                self.chapter_menu = nil
            end
        end,
    })

    -- 创建菜单
    -- (本菜单 is_borderless = true -> 没有外框, 标题栏宽度就取整个菜单宽, 不减 bordersize)
    local chapter_title_bar = MenuStyle.titleBar{
        title = self.current_comic.title .. " - 章节列表",
        width = Screen:getWidth() * 0.9,
        show_parent = self,
    }
    local menu = Menu:new{
        is_picayomi_page = true, -- 退出 Picayomi 时由 util/widget_sweep 清扫
        title = chapter_title_bar.title,
        custom_title_bar = chapter_title_bar,
        item_table = menu_items,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth() * 0.9,
        height = Screen:getHeight() * 0.8,
        show_parent = self,
        close_callback = function()
            if logger.enabled then logger.info("PicaReader", "章节列表关闭") end
        end,
    }
    -- 选中章节时上游还会再调一次 close_callback; 这里只是日志, 但仍统一关掉
    -- "选中即自动关页"的行为, 免得以后往回调里加收尾逻辑时又踩一遍。
    MenuStyle.disableSelectAutoClose(menu)
    -- 左右滑动: 左滑 = 下一页, 右滑 = 上一页, **第一页右滑 = 关掉章节列表**。
    -- Menu 自带的翻页是**循环**的 (menu.lua:1429), 第一页往"上一页"滑会跳到最后一页
    -- —— 几十话的作品里就是"一滑跳到末尾, 退不出去"。
    MenuSwipe.attach(menu, function()
        if self.chapter_menu then
            UIManager:close(self.chapter_menu, "ui")
            self.chapter_menu = nil
        end
    end)

    -- 记住引用: 行回调需要它才能把列表关掉
    self.chapter_menu = menu

    -- 必须带刷新模式, 否则 UIManager 会丢弃刷新, 菜单画不出来
    UIManager:show(menu, "ui")
end

-- 返回源 A
--- 返回 Picayomi
-- @param reason_text 可选: 提示文案。读完最后一章时直接用它把"已结束"和
--        "正在返回"合成一句话 —— 否则用户要先看 4 秒完结提示, 再等一次
--        "返回中…" (真机反馈"多此一举, 要多等蛮久")。
function PicaReader:onReturn(reason_text)
    -- 关阅读器这一段是**同步**的: 真机 diag 实测 1.3~4.8 秒 (绝大部分是 KOReader
    -- 自己在 onClose 里存设置/写 sqlite/序列化缓存, 我们只占其中 ~0.7s)。期间
    -- 屏幕完全不更新, 用户会以为"点了没反应"而反复点。
    --
    -- 所以先画一个提示再干活。注意 show 只是把刷新**入队**, 这里紧接着就要阻塞,
    -- 必须 forceRePaint 才能真的画出来 (与 ui/home.lua 的"加载中"同一个道理)。
    --
    -- 已在关闭流程中就直接退出: 否则第二次点击会再压一个永远没人关的提示。
    if self._closing then
        if logger.enabled then logger.info("Picayomi Reader: 已在关闭流程中, 忽略重复的返回请求") end
        return
    end

    local info = require("ui.common.loading_task").showReturning(reason_text)
    self._return_info = info

    -- 返回前把**精确**页码落一次历史: 翻页时的写入是节流的, 最后几页可能
    -- 还停在内存里 (历史页显示"第 12 页", 实际已经看到第 15 页)。
    local ui = ReaderUI.instance
    if ui and ui.paging then
        pcall(function()
            self:recordProgress(ui.paging.current_page, ui.paging.number_of_pages, true)
        end)
    end

    self:closeReaderUi(function()
        local ok,err=pcall(function()
            if self.on_return_callback then self.on_return_callback()end
        end)
        if self._return_info then
            pcall(function() UIManager:close(self._return_info, "ui") end)
            self._return_info = nil
        end
        if not ok then error(err,0)end
    end)
end

--- 还原打开阅读器之前的屏幕方向 (横屏漫画专用)
--
-- 旋转是**屏幕级**的 (Screen:setRotationMode), 不属于文档设置 —— KOReader 关文档时
-- 不会自己转回来 (它只在文件管理器的 showFiles 里按 fm_rotation_mode 重设, 而我们的
-- 插件界面不是文件管理器)。不还原的话, 退出阅读后整个 Picayomi 都是横的, 用户只能
-- 去系统菜单手动转回来。
--
-- 幂等: 还原后立刻清掉 session.prev_rotation, 重复调用不会反复触发整屏刷新。
function PicaReader:restoreScreenRotation(reader_ui)
    local doc = reader_ui and reader_ui.document
    local session = doc and doc.session
    local prev = session and session.prev_rotation
    if prev == nil then return false end
    session.prev_rotation = nil
    local Screen = require("device").screen
    local cur = Screen:getRotationMode()
    if cur == prev then return false end
    local ok = pcall(function() Screen:setRotationMode(prev) end)
    if logger.enabled then logger.info(string.format("Picayomi Reader: 还原屏幕方向 %s -> %s (%s)",
        tostring(cur), tostring(prev), tostring(ok))) end
    return ok
end

-- 关闭阅读器界面
function PicaReader:closeReaderUi(done_callback)
    -- 关阅读器可能被多条路径同时触发 (菜单项 + 返回键 + 页面按钮)。重复执行会把
    -- 回调跑两遍、把已经关掉的 ReaderUI 再关一次, 于是返回路径上会多冒出一层界面。
    if self._closing then
        if logger.enabled then logger.info("Picayomi Reader: 已在关闭流程中, 忽略重复请求") end
        return
    end
    self._closing = true

    if logger.enabled then logger.info("Picayomi Reader: 准备关闭阅读器并返回Picayomi") end

    -- 保存回调函数，在ReaderUI完全关闭后执行
    self.pending_callback = done_callback

    -- 延迟执行，确保所有事件处理程序在关闭ReaderUI之前运行
    UIManager:nextTick(function()
        if logger.enabled then logger.info("Picayomi Reader: 关闭ReaderUI实例") end

        -- 这是延迟任务, 而且是**返回路径上最关键的一拍**: KOReader 的任务队列不兜异常
        -- (逃出 = 整个进程退出), 并且下面三步有先后依赖 —— 任何一步抛了都不能让后面
        -- 的步骤被跳过:
        --   * onClose 是 KOReader 自己的 (存设置 / 写 sqlite / 序列化缓存, 真机实测
        --     1.3~4.8s), 磁盘满 / sqlite 出错时会抛;
        --   * 它抛了还跳过 ensureBase (补回文件浏览器) 的话, 窗口栈就是空的,
        --     UIManager 下一轮判 "No dialogs left to show" 把 KOReader 一起退掉 ——
        --     用户点的是"返回", 得到的是"退出 KOReader";
        --   * 再跳过返回回调的话, 用户还会卡在黑屏/残留的提示上。
        -- 所以每步各自 pcall, 失败只记日志, 后面照常执行。
        local function step(label, fn)
            local ok, err = pcall(fn)
            if not ok then
                logger.warn("Picayomi Reader: 关闭阅读器 - " .. label .. " 失败: " .. tostring(err))
            end
            return ok
        end

        -- 横屏漫画: 先把屏幕转回打开前的方向, 再关文档。
        -- 顺序不能反: 关文档之后 document.session 可能已经不可达。
        step("还原屏幕方向", function() self:restoreScreenRotation(ReaderUI.instance) end)

        -- 关闭ReaderUI
        step("onClose", function()
            if ReaderUI.instance then
                ReaderUI.instance:onClose()
            end
        end)

        -- 必须重新打开FileManager以避免UI状态问题。
        --
        -- 用 ensureBase 而不是 `if FileManager.instance then reinit() end`:
        -- reinit **只重排已有实例, 不把它放回窗口栈**。实例还在栈里时那是对的 (便宜),
        -- 但只要实例存在却不在栈里 (半关闭状态), 这个分支就等于什么都没做 ——
        -- 关掉阅读器后窗口栈为空, UIManager 下一轮就判 "No dialogs left to show"
        -- 把 KOReader 一起退掉。ensureBase 三种情况都兜住, 并且放到栈底。
        step("补回底层", function() require("util.widget_sweep").ensureBase() end)

        -- **立刻**恢复 Picayomi 的界面, 不要再等一个 tick:
        -- 上一行刚把 FileManager 放回栈底, 每多等一帧, 用户就多看到一帧
        -- 文件管理器(还会恢复到他上次停留的目录) —— 表现就是"返回后回到的
        -- 不是上一级, 而是文件管理器/历史位置"。
        if logger.enabled then logger.info("Picayomi Reader: 执行返回回调") end
        if self.pending_callback then
            local callback = self.pending_callback
            self.pending_callback = nil
            step("返回回调", callback)
        end
    end)
end

-- 处理书籍结束事件
--
-- 接缝: KOReader 翻过最后一页时发 `EndOfBook` (readerpaging.lua:1043 /
-- readerrolling.lua:916), 事件沿子控件冒泡到插件实例, 由 `main.lua` 的
-- `Picayomi:onEndOfBook` 转发到这里。
--
-- 曾经这里是**死代码**: 它只被 `reader_ui.pica_end_callback` 调用, 而那个字段的
-- 唯一消费者 `hookWithPriorityOntoReaderUiEvents` 从未被安装 (它的调用者
-- `initializeFromReaderUI` 全项目没有调用点) —— 表现就是"读到最后一页什么都不发生"。
--- 关掉 KOReader 自带的"文档结束"弹窗
--
-- 它由 `ReaderStatus:onEndOfBook` 弹出 (frontend/apps/reader/modules/readerstatus.lua:38,
-- 名称 `end_document`), 与**我们自己的**「下一话 / 已读完」提示是两回事 —— 两个都会弹。
--
-- 真机反馈: 读完一话返回后这个弹窗**还留在屏幕上**。原因就是它在窗口栈里,
-- 而关阅读器只是把 ReaderUI 从栈里摘掉, 它自然浮到最上面。
--
-- 为什么由我们关: 这个弹窗对"插件自己管理的流式文档"毫无意义 —— 里面是
-- "Mark as finished / Open next file / Delete file / File browser", 而我们的
-- "下一个文件"是**下一话**, 走的是插件自己的换章逻辑。留着它只会误导。
--
-- 只认窗口栈里的 name, 不 require 那个模块: 版本不同/改名时静默跳过。
function PicaReader:dismissKoreaderEndDialog()
    local stack = UIManager._window_stack
    if type(stack) ~= "table" then return false end
    local doomed
    for _i, entry in ipairs(stack) do
        local w = entry and entry.widget
        if type(w) == "table" and w.name == "end_document" then
            doomed = w
        end
    end
    if not doomed then return false end
    -- 同一轮事件里 show 完立刻 close: 刷新是**事件处理完之后**才跑的,
    -- 所以用户一帧都看不到它, 不会闪。
    pcall(function() UIManager:close(doomed, "ui") end)
    if logger.enabled then logger.info("Picayomi Reader: 已关掉 KOReader 自带的文档结束弹窗") end
    return true
end

function PicaReader:onEndOfBook()
    if self.is_showing then
        if logger.enabled then logger.info("PicaReader", "到达漫画末尾") end
        -- 先清掉 KOReader 那个弹窗, 再弹我们自己的 —— 顺序反了的话, 它压在
        -- 我们的提示上面, 用户点的是它的按钮。
        self:dismissKoreaderEndDialog()

        -- 检查是否有下一章节
        if self.episodes_list and self.current_episode_index and self.current_episode_index < #self.episodes_list then
            -- 有下一章节，询问是否继续阅读
            local next_episode = self.episodes_list[self.current_episode_index + 1]

            UIManager:show(ConfirmBox:new{
                -- 阅读期间窗口栈里只有 ReaderUI, 所以这个确认框就是**唯一的**插件层 ——
                -- 不带标记的话, 它一旦残留就没有锚点可扫 (util/widget_sweep.closeAll)
                is_picayomi_page = true,
                text = _("当前章节已结束，是否继续阅读下一章节？\n\n") ..
                       (next_episode.title or "第" .. next_episode.order .. "话"),
                ok_text = _("继续阅读"),
                cancel_text = _("返回"),
                ok_callback = function()
                    self:switchToChapter(self.current_episode_index + 1)
                end,
                cancel_callback = function()
                    if self.on_end_of_book_callback then
                        self.on_end_of_book_callback(self.current_comic, self.current_episode)
                    else
                        self:onReturn()
                    end
                end,
            }, "ui")
        else
            -- 没有下一章节: 完结提示与返回**同时**开始
            --
            -- 以前是"提示 timeout=4 -> scheduleIn(4, onReturn) -> 再画返回中… -> 关" ——
            -- 用户读完最后一页要干等 4 秒, 然后还要再看一次返回提示 (关闭本身
            -- 还要 1~5 秒)。两段完全重叠得起来: 直接把这句提示当成返回提示,
            -- 关阅读器立刻开始。
            if self.on_end_of_book_callback then
                UIManager:show(InfoMessage:new{
                    text = _("已阅读全部章节\n\n总共阅读了 "
                        .. #self.episodes_list .. " 话"),
                    timeout = 2,
                }, "ui")
                self.on_end_of_book_callback(self.current_comic, self.current_episode)
            else
                self:onReturn(T(_("已阅读全部章节（共 %1 话），正在返回…"),
                    #self.episodes_list))
            end
        end

        return true
    end
end

--- 阅读器关闭时的清理 (由 main.lua 的 `Picayomi:onCloseWidget` 调用)
--
-- 触发链: `ReaderUI:onClose()` -> `UIManager:close(self)` (self.dialog == self)
--   -> `handleEvent(Event:new("CloseWidget"))` -> `WidgetContainer:propagateEvent`
--   遍历 ReaderUI 的所有子控件 (插件实例也在其中) -> `Picayomi:onCloseWidget`。
--
-- **只做两件事: 停掉本实例的下载 + 松开引用。故意不清 current_comic /
-- episodes_list / current_episode_index** ——
-- 换章走的 `switchDocument` 内部是 `self:onClose(false)` + `showReader(...)`, 也会
-- 触发本回调; 而 `switchToChapter` 在 switchDocument **之前**就把
-- current_episode / current_episode_index 设好了。在这里清掉的话, 新实例的
-- "章节导航"菜单 (addToMainMenu 读这两个字段) 会立刻变空 —— 换章后菜单里就
-- 只剩"返回 Picayomi"了。
function PicaReader:onReaderClosed(reader_ui)
    if logger.enabled then logger.info("Picayomi Reader: ReaderUI 关闭, 清理插件侧状态") end

    -- 把临时关掉的跨设备进度同步原样打开 —— 那是**用户的全局设置**, 我们只在
    -- 自己的文档里借走一会儿, 不能永久改掉 (否则用户在 KOReader 里打开普通
    -- epub 时进度同步就悄悄失效了)。
    --
    -- 换章也走这里 (switchDocument = onClose + showReader): 先恢复、新实例的
    -- postInitCallback 再关掉, 两步在同一个同步调用链里, 中间没有窗口期。
    self:restoreForeignSync()

    -- 横屏漫画: 退出阅读器时把屏幕转回来。换章 (switchDocument) 也会走到这里,
    -- 那时屏幕要保持在横屏 —— 由 _switching 区分。
    if not self._switching then
        self:restoreScreenRotation(reader_ui)
    end

    -- 停掉这个实例上的下载: 换文档/关阅读器之后都不该再有任何下载落地
    local bridge = reader_ui and reader_ui._picayomi_bridge
    if bridge then
        bridge:close()          -- 内部就是 session:cancel()
    else
        local doc = reader_ui and reader_ui.document
        if doc and doc.session then doc.session:cancel() end
    end

    -- 松开对 ReaderUI 的引用。PicaReader 是模块级单例 (整个 KOReader 生命周期只有
    -- 一个实例), 而 attachReaderHooks 会把 ReaderUI 存进 self._hooks_reader_ui。
    -- 不清的话, 关掉阅读器之后那个 ReaderUI (连同它的 document / StreamSession /
    -- 图片列表 / page_sizes / 整棵控件树) 一直可达 —— 恰好在用户回到列表页、
    -- 最需要内存的时候白占几 MB。这台设备已经因为 OOM 被 SIGKILL 过。
    if self._hooks_reader_ui == reader_ui then
        self._hooks_reader_ui = nil
    end
end

-- 设置当前漫画信息
--- 把"读到第几页"写进阅读历史 (历史页据此显示「第N话 · 第3/20页」)
--
-- 写盘要**节流**: 历史存在 settings JSON 里, 每翻一页都整份落盘在 Kindle 上是
-- 纯浪费 (一次 eMMC 写)。翻页时最多每 PROGRESS_SAVE_INTERVAL 秒写一次,
-- 返回/关闭时再 force 补一次精确值 —— 最后那几页不会因为节流而丢掉。
--
-- @param page   当前页码 (1-based)
-- @param pages  本话总页数 (可为 nil: 源没给页数时历史只显示页码)
-- @param force  true = 忽略节流, 立即落盘
function PicaReader:recordProgress(page, pages, force)
    local comic, episode = self.current_comic, self.current_episode
    if not (comic and comic._id and episode) then return end
    page = tonumber(page)
    if not page or page < 1 then return end

    local now = os.time()
    if not force and self._progress_saved_at
        and now - self._progress_saved_at < self.PROGRESS_SAVE_INTERVAL then
        return
    end
    self._progress_saved_at = now

    local ok, model = pcall(require, "model.comic")
    if not ok or type(model) ~= "table" or type(model.saveHistory) ~= "function" then
        return
    end
    pcall(function()
        model:saveHistory(comic._id, comic.title or "", episode.order,
            self.source_id, { page = page, pages = tonumber(pages), episode_title = episode.title, thumb = comic.thumb })
    end)
end

function PicaReader:setCurrentComic(comic, episode, episodes_list)
    if not comic or not episode then
        logger.err("PicaReader", "设置当前漫画失败：comic或episode参数为空")
        return false
    end

    self.current_comic = comic
    self.current_episode = episode
    self.episodes_list = episodes_list
    self.preloaded_episode_id = nil -- 重置预下载状态
    self.current_episode_index = nil -- 重置索引

    -- 查找当前章节在列表中的索引
    if episodes_list and #episodes_list > 0 then
        for i, ep in ipairs(episodes_list) do
            if ep and ((ep._id and ep._id == episode._id) or (ep.order and ep.order == episode.order)) then
                self.current_episode_index = i
                break
            end
        end
    end

    local comic_title = comic.title or "未知漫画"
    local episode_title = episode.title or ("第" .. (episode.order or "?") .. "话")
    local episode_index_str = self.current_episode_index and tostring(self.current_episode_index) or "未知"
    local total_episodes = episodes_list and #episodes_list or 0

    if logger.enabled then logger.info("PicaReader", "设置当前漫画: " .. comic_title ..
                ", 章节: " .. episode_title ..
                ", 索引: " .. episode_index_str ..
                ", 总章节数: " .. total_episodes) end

    return true
end

-- 获取当前漫画信息
function PicaReader:getCurrentComic()
    return self.current_comic, self.current_episode
end

-- 打开漫画，供其他UI模块调用
--
-- @param opts 可选 { from_beginning = true }: 「开始」按钮的语义 —— 固定从第一页读,
--             打开前会清掉 KOReader 记住的页码 (见 api/comic.lua:prepareComic)。
--             缺省/为假时按 KOReader 记住的进度恢复 (「继续」/换章/点章节行)。
function PicaReader:open(comic, episode, episodes_list, return_callback, detail_menu_to_close, opts)
    require("source.extensions.updater").cancel()
    -- 新的一次阅读: 清掉上一次的关闭标记, 否则这次会关不掉
    self._closing = nil
    -- 进度节流的时间戳也要重置: 上一本书刚写过时, 这本书的第一页会被跳过
    self._progress_saved_at = nil
    -- 也要重新找一次页脚 (换文档后是新的页脚对象), 否则诊断日志不会再打
    self._footer_checked = nil
    -- 添加参数验证
    if not comic then
        logger.err("PicaReader", "打开漫画失败：comic参数为空")
        UIManager:show(InfoMessage:new{
            text = _("漫画信息缺失，无法打开"),
        }, "ui")
        return false
    end

    if not episode then
        logger.err("PicaReader", "打开漫画失败：episode参数为空")
        UIManager:show(InfoMessage:new{
            text = _("章节信息缺失，无法打开"),
        }, "ui")
        return false
    end

    local comic_title = comic.title or "未知漫画"
    local episode_title = episode.title or ("第" .. (episode.order or "?") .. "话")

    if logger.enabled then logger.info("PicaReader", "打开漫画: " .. comic_title .. ", 章节: " .. episode_title) end

    -- 本次阅读属于哪个源: 历史按源分桶, 记错源会让进度落到别的源下面
    -- (调用方 ui/common/comic_detail 会带上自己的 source_id; 兜底取当前源)
    -- 换章 (onEndOfBook -> self:open) 不带 opts: 沿用上一次的值, 不要退回"当前源"
    self.source_id = (opts and opts.source_id) or self.source_id
        or require("source.registry"):getCurrentId()

    -- 设置返回回调
    self.on_return_callback = return_callback or function()
        -- 默认回调：返回到Picayomi主页
        if logger.enabled then logger.info("PicaReader", "使用默认返回回调，回到Picayomi主页") end
        local Home = require("ui.home")
        local home = Home:new{}
        home:show()
    end

    -- 记录当前漫画信息
    self:setCurrentComic(comic, episode, episodes_list)

    -- 取章节列表 + 取图片列表 + 打开阅读器, 整条链在 api/comic.lua 的一个
    -- **可取消协程**里跑 (见 getAndOpenComic 的注释): 每步之间会把控制权交回
    -- UIManager, 所以等待期间界面可响应, 用户点屏幕能中止。
    --
    -- 代价是本函数变成"启动即返回 + 结果走回调": 调用方拿不到同步的成功/失败。
    -- 这是必须的 —— 要在等待中途让出控制权, 就不可能同时同步返回结果。
    local comic_api = require("api.comic")
    if opts then self.offline = opts.offline == true end
    local context = {
        comic = comic,
        source_id = self.source_id,
        offline = (opts and opts.offline) or (not opts and self.offline) or false,
        episodes = self.episodes_list or episodes_list,
        episode = episode,
        -- from_beginning 也走这条上下文: prepareComic 据此清掉本话的阅读进度,
        -- 阅读器就绪后 attachReaderHooks 再兜一次底 (见 enforceStartFromBeginning)。
        from_beginning = (opts and opts.from_beginning) or false,
    }
    comic_api:getAndOpenComic(comic._id, tostring(episode.order), episode._id,
        detail_menu_to_close, context, function(ok, err, episodes)
            if not ok then
                if detail_menu_to_close then
                    detail_menu_to_close.opening_reader=false
                    if detail_menu_to_close.revealQuickEntry then detail_menu_to_close:revealQuickEntry()end
                end
                -- err == nil 表示用户自己按了「中止」: 界面已经清干净, 不该再弹错误。
                -- 真正的失败 (取列表失败 / 打开异常) 由 getAndOpenComic 弹提示。
                if err then
                    logger.err("PicaReader", "获取漫画失败: " .. tostring(err))
                else
                    if logger.enabled then logger.info("PicaReader", "用户中止了本次打开") end
                end
                return
            end

            -- 章节列表是这次现取的 (调用方没给), 补上 —— 阅读器内的
            -- "返回本话详情 / 下一话"依赖它
            if episodes then
                self:setCurrentComic(comic, episode, episodes)
            end

            self.is_showing = true

            -- 装钩子 (结束/返回回调 + 菜单 + 翻页预取 + 页脚修正)
            --
            -- **不能**直接依赖 getAndOpenComic 返回的实例: ReaderUI:showReader 是
            -- 异步的, 实例常常还没建好。主接线点是新实例自己的 postInitCallback
            -- (main.lua 注册 -> onReaderInit); 这里再兜一次, 覆盖"其实已就绪"的情况。
            self:attachHooksWhenReady()
        end)

    return true
end

return PicaReader
