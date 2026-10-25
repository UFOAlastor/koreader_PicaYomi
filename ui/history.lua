local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local LoadingTask = require("ui.common.loading_task")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local ButtonDialog = require("ui/widget/buttondialog")
local _ = require("gettext")
local T = require("ffi/util").template
local FavoriteActions = require("util.favorites")
local TextWidget = require("ui/widget/textwidget")
local CenterContainer = require("ui/widget/container/centercontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalGroup = require("ui/widget/verticalgroup")
local Geom = require("ui/geometry")
local Font = require("ui/font")
local logger = require("util.logger")
local ComicDetail = require("ui.common.comic_detail")
local VisualComicList = require("ui.common.visual_comic_list")
local WidgetSweep = require("util.widget_sweep")
local Diag = require("util.diag")

local History = WidgetContainer:extend{
    name = "picayomi_history",
    title = _("浏览历史"),
    width = Screen:getWidth(),
    height = Screen:getHeight(),
}

function History:init()
    -- 初始化API和模型
    self.comic_api = require("api.comic")
    self.comic_model = require("model.comic")

    -- 初始化其他UI模块
    self.reader = require("ui.reader")

    -- 初始化历史数据
    self.history_list = nil
end

--- 当前源 (历史按源隔离: 只显示/操作这个源的记录)
--
-- 每次进历史页都重新取一次: 用户可能在设置里切过源, 而 History 实例是复用的。
function History:currentSource()
    local ok, SourceRegistry = pcall(require, "source.registry")
    if not ok or not SourceRegistry then return nil, nil end
    local source = SourceRegistry:getCurrent()
    return source, (source and source.identifier) or SourceRegistry:getCurrentId()
end

function History:show(return_callback)
    -- 保存返回回调
    self.return_callback = return_callback or function()
        -- 默认返回：关闭当前界面（会回到KOReader）
        if logger.enabled then logger.info("History", "使用默认返回回调") end
    end

    -- 加载历史记录
    self:loadHistory()
end

function History:loadHistory()
    local source, source_id = self:currentSource()
    self.source = source
    self.source_id = source_id

    -- 获取历史记录列表 (只取当前源的: 各源 id 命名空间不通用, 混在一起会串)
    self.history_list = self.comic_model:getHistory(source_id)

    -- 显示历史记录列表
    self:showHistoryList()
end

--- 历史条目的进度文案: 「读到 第3话 · 第5/20页」
--
-- 页码是后来才记进历史的 (model/comic.lua 的 saveHistory 带 progress):
--   * 老记录只有话号 -> 只显示话号, 不显示"第 nil 页";
--   * 源没给页数 (pages 缺失) -> 只显示"第5页";
--   * 换过话的记录页码会被清掉 (见 saveHistory), 同样只显示话号。
function History.progressText(item)
    if not (item and item.episode) then return _("未记录进度") end
    local text = type(item.episode_title) == "string" and item.episode_title ~= ""
        and (_("读到 ") .. item.episode_title)
        or T(_("读到 第%1话"), tostring(item.episode))
    local page = tonumber(item.page)
    local pages = tonumber(item.pages)
    if page and page > 0 then
        if pages and pages > 0 then
            text = text .. " · " .. T(_("第%1/%2页"), page, pages)
        else
            text = text .. " · " .. T(_("第%1页"), page)
        end
    end
    return text
end

--- 历史条目的时间显示
-- 写入时用的字段是 `time` (见 model/comic.lua), 读取也必须用 `time`。
-- 历史 bug: 这里曾读 `history.timestamp`(恒为 nil), 于是每条都显示成"当前时间"。
-- 保留 timestamp 兜底只为兼容可能存在的旧数据。
function History.formatTime(item)
    return os.date("%Y-%m-%d %H:%M", item.time or item.timestamp or os.time())
end

function History:showHistoryList()
    local source, source_id = self.source, self.source_id
    -- 刷新 (清空 / 删除后重新加载) 时旧列表要收掉: 否则会在栈里叠出两份长得
    -- 一模一样的列表, 之后按「返回」只弹掉上面一份, 屏幕看着毫无变化 ——
    -- 用户看到的就是"点了没反应" (与主页/详情页踩过的是同一个坑)。
    -- 收在最后一步 (replace_page): 先 show 新的, 再关旧的。
    local old_list = self.history_menu
    self.history_menu = nil

    if not self.history_list or #self.history_list == 0 then
        if old_list then UIManager:close(old_list, "ui") end
        UIManager:show(InfoMessage:new{
            text = T(_("【%1】没有阅读历史记录"),
                (self.source and self.source.name) or _("当前源")),
        }, "ui")
        return
    end

    -- 封面地址属于持久元数据，图片仍走可清理的封面缓存。
    local comics = {}
    for _idx, item in ipairs(self.history_list) do
        local time_str = self.formatTime(item)
        table.insert(comics, {
            _id = item.id,
            title = item.title,
            thumb = item.thumb,
            author_text = time_str,
            categories_text = History.progressText(item),
            _history = item,
        })
    end

    -- 标题带上源名: 历史是按源隔离的, 不写清楚会让人以为"记录丢了"
    -- (切源后另一个源的历史本来就该是另一份)
    local title = _("阅读历史")
    if self.source and self.source.name then
        title = T(_("阅读历史 · %1"), self.source.name)
    end

    self.history_menu = VisualComicList:new{
        title = title,
        comics = comics,
        source = self.source,
        source_id = self.source_id,
        -- 旧记录没有地址时，只为当前可见行异步补详情；不开整段历史扫描。
        resolve_cover = function(comic)
            if not source or type(source.getComicDetail) ~= "function"
                    or not require("ui.common.source_access").check(source, nil, true) then return nil, "failed" end
            local started = Diag.enabled and require("socket").gettime()
            local ok, detail = source:getComicDetail(comic._id)
            if Diag.enabled then
                Diag.mark(string.format("history cover metadata source=%s ok=%s elapsed=%.2fs",
                    tostring(source_id),tostring(ok),require("socket").gettime()-started))
            end
            if not ok or type(detail) ~= "table" then return nil, "failed" end
            local thumb = ok and type(detail) == "table" and detail.thumb
            if type(thumb) ~= "string" or thumb == "" then return nil, "missing" end
            self.comic_model:updateHistoryCover(comic._id, source_id, thumb)
            return thumb
        end,
        -- 历史记录全部在本地, 没有可补的下一页
        has_more = false,
        on_select = function(comic, navigation)
            self:showHistoryDetail(comic._history or { id = comic._id, title = comic.title }, navigation)
        end,
        -- 删除是**列表**的操作 (只对"这条记录"有意义), 所以放在长按里,
        -- 不塞进详情页 —— 详情页该显示的是漫画本身的信息。
        on_hold = function(comic)
            self:removeFromHistory(comic._id)
        end,
        extra_buttons = {
            { text = _("清空"), callback = function()
                self:confirmClearHistory()
            end },
        },
        on_back = function(list)
            -- 必须先关掉本页: VisualComicList:goBack 在设置了 on_back 时**不会**
            -- 自己关闭, 只调 on_back。漏掉这一步, 主页只是被重绘了一下, 而历史页
            -- 仍盖在最上面 —— 屏幕上看起来就是"点返回没反应"。(实测踩到)
            if list then UIManager:close(list, "ui") end
            self.history_menu = nil
            if self.return_callback then
                self.return_callback()
            end
        end,
    }

    WidgetSweep.replace_page(old_list, self.history_menu)
end

function History:showHistoryDetail(history, navigation)
    local loading = InfoMessage:new{
        text = _("加载漫画信息..."),
    }
    UIManager:show(loading, "ui")
    -- 同步刷一次: show 只是把刷新入队, 而这里马上要阻塞做网络请求,
    -- 不等这一下的话事件循环没机会重绘, 提示等于没显示
    UIManager:forceRePaint()

    local success, comic_detail, error_msg = LoadingTask.call(loading, function()
        return self.comic_api:getComicDetail(history.id)
    end)

    if not success or not comic_detail then
        UIManager:show(InfoMessage:new{
            text = T(_("获取漫画信息失败: %1"), require("ui.common.error_message").describe(error_msg)),
        }, "ui")
        return
    end

    -- 用列表构建时记下的源: 详情页必须与列表同源, 否则会拿这个源的 id 去问另一个源
    local source = self.source or require("source.registry"):getCurrent()
    local source_id = self.source_id or (source and source.identifier) or "picacg"
    local detail
    detail = ComicDetail:new{
        navigation = navigation,
        comic = comic_detail,
        source = source,
        source_id = source_id,
        comic_model = self.comic_model,
        reader = self.reader,
        start_label = _("继续"),
        resume_episode_order = history.episode or history.last_page,
        -- 登录走账号, 未登录走本地兜底 (规则统一在 util/favorites.buildAction)。
        -- 原实现只会"加"且写死文案, 已收藏的漫画点一下又加一次、状态也显示不出来。
        favorite_action = FavoriteActions.buildAction{
            source = source,
            source_id = source_id,
            comic_api = self.comic_api,
        },
        -- 这里**不放**"从头阅读 / 从历史记录删除": 详情页是看漫画信息的地方,
        -- 两个入口都只跟"这条历史"有关。删除属于列表本身的操作 —— 长按历史条目
        -- 弹删除 (见 showHistoryList 的 on_hold); 从头看用详情页自己的「开始」。
        on_back = function()
            self.detail_menu = nil
        end,
        on_return_from_reader = function()
            -- 读完一话回来: 详情页**没有被关掉** (api/comic.lua 现在故意留着它,
            -- 它就是返回目标), 浏览历史列表还在它下面 —— 什么都不用做,
            -- 页码与已加载的缓冲都保留。保留 self.detail_menu 引用 (页面还活着)。
            if not WidgetSweep.isInStack(self.history_menu)
               and not WidgetSweep.isInStack(self.detail_menu) then
                self:show(self.return_callback)
            end
        end,
    }
    self.detail_menu = detail
    UIManager:show(detail, "ui")
end

function History:removeFromHistory(comic_id)
    -- 显示确认对话框
    UIManager:show(ConfirmBox:new{
        text = _("确定要从历史记录中删除这部漫画吗？"),
        ok_text = _("确定"),
        cancel_text = _("取消"),
        ok_callback = function()
            -- 只删当前源的那一条: 别的源可能有同名 id 的记录, 不能一起删掉
            local success = self.comic_model:clearHistory(comic_id, self.source_id)

            if success then
                -- 显示成功消息
                UIManager:show(InfoMessage:new{
                    text = _("已从历史记录中删除"),
                }, "ui")

                -- 重新加载历史记录
                self:loadHistory()
            end
        end,
    }, "ui")
end

function History:confirmClearHistory()
    local source_name = (self.source and self.source.name) or _("当前源")
    -- 显示确认对话框
    UIManager:show(ConfirmBox:new{
        text = T(_("确定要清空【%1】的全部历史记录吗？\n(其它源的历史不受影响)"),
            source_name),
        ok_text = _("确定"),
        cancel_text = _("取消"),
        ok_callback = function()
            -- 只清空当前源: 这一页显示的就是这个源的历史, 顺手把别的源也清掉会莫名其妙
            local success = self.comic_model:clearHistory(nil, self.source_id)

            if success then
                -- 显示成功消息
                UIManager:show(InfoMessage:new{
                    text = _("已清空历史记录"),
                }, "ui")

                -- 重新加载历史记录
                self:loadHistory()
            end
        end,
    }, "ui")
end

return History
