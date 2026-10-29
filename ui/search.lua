local InputDialog = require("ui.common.action_style").InputDialog
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui.common.action_style").Menu
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local LoadingTask = require("ui.common.loading_task")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ButtonDialog = require("ui.common.action_style").ButtonDialog
local ConfirmBox = require("ui.common.action_style").ConfirmBox
local _ = require("gettext")
local T = require("ffi/util").template
local FavoriteActions = require("util.favorites")
local logger = require("util.logger")
local TextWidget = require("ui/widget/textwidget")
local CenterContainer = require("ui/widget/container/centercontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalGroup = require("ui/widget/verticalgroup")
local Geom = require("ui/geometry")
local Font = require("ui/font")
local VisualComicList = require("ui.common.visual_comic_list")
local ComicDetail = require("ui.common.comic_detail")
local TapGuard = require("ui.common.tap_guard")
local SearchHistory = require("util.search_history")
local MenuStyle = require("ui.common.menu_style")
local MenuSwipe = require("ui.common.menu_swipe")
local WidgetSweep = require("util.widget_sweep")

local Search = WidgetContainer:extend{
    name = "picayomi_search",
    title = _("搜索"),
    width = Screen:getWidth(),
    height = Screen:getHeight(),
}

function Search:init()
    -- 初始化API和模型
    self.comic_api = require("api.comic")
    self.comic_model = require("model.comic")

    -- 初始化其他UI模块
    self.reader = require("ui.reader")

    -- 初始化搜索结果数据
    self.search_results = nil
    self.current_page = 1
    self.total_pages = 1
    self.total_count = nil
    -- 默认排序取**当前源声明的第一个选项**, 不要写死某个源的取值
    -- (源 A 是 dd, 源 B 是 mr; 写死会导致换源后排序失效)
    local cur_source = require("source.registry"):getCurrent()
    local sort_opts = cur_source and cur_source.getSortOptions
        and cur_source:getSortOptions("search")
    self.current_sort = sort_opts and sort_opts[1] and sort_opts[1].value or nil
    self.current_keyword = ""
end

function Search:show(return_callback)
    -- 保存返回回调
    self.return_callback = return_callback or function()
        -- 默认返回：关闭当前界面（会回到KOReader）
        if logger.enabled then logger.info("Search", "使用默认返回回调") end
    end

    -- 确保在显示前先保存实例
    self.instance = self
    -- 显示搜索输入框
    self:showSearchDialog()
end

-- The dialog is owned by one explicit entry. Action callbacks cannot close a
-- newer input, and closing it never implicitly reopens another input.
function Search:closeSearchDialog(expected)
    if expected and self.search_dialog~=expected then return false end
    local dialog=self.search_dialog
    self.search_dialog=nil
    if dialog then
        dialog._search_action_close=true
        dialog.close_callback=nil
        pcall(function()dialog:onCloseKeyboard()end)
        if WidgetSweep.isInStack(dialog)then UIManager:close(dialog,"ui")end
    end
    return true
end

function Search:showSearchDialog()
    self.source=require("source.registry"):getCurrent()
    if not require("ui.common.source_access").check(self.source,"search")then return end
    self:closeSearchDialog()
    self._left=false
    self._dialog_generation=(self._dialog_generation or 0)+1
    local generation=self._dialog_generation
    local dialog
    dialog=InputDialog:new{
        is_picayomi_page=true,
        title=self.source and self.source.content_type=="novel" and _("搜索小说")or _("搜索漫画"),
        input="",
        buttons={{
            {text=_("搜索"),callback=function()
                if self.search_dialog~=dialog then return end
                local input=dialog:getInputText():gsub("^%s+",""):gsub("%s+$","")
                self:closeSearchDialog(dialog)
                if input==""then
                    UIManager:show(InfoMessage:new{text=_("请输入搜索关键词")},"ui")
                    return
                end
                self.current_keyword=input;self.current_page=1
                self:performSearch()
            end},
            {text=_("历史"),enabled=SearchHistory.count()>0,callback=function()
                if not self:closeSearchDialog(dialog)then return end
                self:showHistoryMenu()
            end},
            {text=_("取消"),callback=function()
                if not self:closeSearchDialog(dialog)then return end
                self:leave()
            end},
        }},
    }
    local close=dialog.onCloseWidget
    dialog.onCloseWidget=function(widget,...)
        local owned=self.search_dialog==widget
        if owned then self.search_dialog=nil end
        close(widget,...)
        if owned and not widget.sweeping and not widget._search_action_close then
            -- The host is still removing this window. Return after that removal
            -- so Home cannot try to close the same dialog a second time.
            UIManager:nextTick(function()
                if self._dialog_generation==generation and not self.search_dialog and not self._left then self:leave()end
            end)
        end
    end
    self.search_dialog=dialog
    UIManager:show(dialog,"ui")
end

--- Every submitted/closed search returns to its caller, without a new input.
function Search:leave()
    if self._left then return end
    self._left=true
    self._query_generation=(self._query_generation or 0)+1
    if self.search_task then self.search_task:cancel();self.search_task=nil end
    self:closeSearchDialog()
    for _,name in ipairs({"history_delete_dialog","history_menu","result_menu"})do
        local widget=self[name];self[name]=nil
        if widget and WidgetSweep.isInStack(widget)then UIManager:close(widget,"ui")end
    end
    if self.return_callback then self.return_callback()end
end

--- 用历史里的一个关键词直接重搜
function Search:searchFromHistory(keyword)
    self.current_keyword = keyword
    self.current_page = 1
    self:performSearch()
end

--- 搜索历史列表 (全屏 Menu)
--
-- 流程: 释放输入框 -> 显示整屏菜单 -> 关闭时返回调用方。
-- 选中条目时不能再触发"关菜单"的收尾 (否则栈里会多压一个一模一样的搜索框,
-- 用户按「返回」要按好几次才退得出去) —— 由 MenuStyle.disableSelectAutoClose 统一拦住。
function Search:showHistoryMenu(page)
    local old_menu = self.history_menu
    local items = SearchHistory.list()
    if #items == 0 then
        if old_menu then
            self.history_menu = nil
            if WidgetSweep.isInStack(old_menu) then UIManager:close(old_menu, "ui") end
        end
        -- 兜底: 「历史」按钮在无历史时是禁用态, 正常走不到这里
        UIManager:show(InfoMessage:new{
            text = _("还没有搜索历史"),
            timeout = 3,
        }, "ui")
        self:leave()
        return
    end

    -- **item_table 必须在 Menu:new 之前建好**。Menu:init 的结尾会立刻调一次
    -- `updateItems(1, true)` (menu.lua:979) 把当时的 item_table 渲染成控件;
    -- 构造完再往 `menu.item_table` 里 table.insert, 控件早已生成完毕 ——
    -- 新条目不会出现在屏幕上, 页脚停在 "无项目" (用户报的正是这个)。
    -- 其余菜单 (分类 / 排行榜 / 漫画源 / 章节列表) 都是"先建表再 new"。
    local item_table = {}
    local menu
    for _i, keyword in ipairs(items) do
        table.insert(item_table, {
            text = keyword,
            search_keyword = keyword,
            picayomi_underline = true,
            callback = function()
                if self.history_menu~=menu or not WidgetSweep.isInStack(menu)then return end
                UIManager:close(menu, "ui")
                self.history_menu = nil
                self:searchFromHistory(keyword)
            end,
        })
    end
    local clear_history = {
        text = _("清空历史"),
        callback = function()
            if self.history_menu ~= menu or not WidgetSweep.isInStack(menu) then return end
            UIManager:show(ConfirmBox:new{
                is_picayomi_page = true,
                text = _("确定清空全部搜索记录吗？清空后无法恢复。"),
                ok_text = _("清空"), cancel_text = _("取消"),
                ok_callback = function()
                    if self.history_menu ~= menu or not WidgetSweep.isInStack(menu) then return end
                    SearchHistory.clear()
                    UIManager:close(self.history_menu, "ui")
                    self.history_menu = nil
                    UIManager:show(InfoMessage:new{
                        text = _("已清空搜索历史"),
                        timeout = 3,
                    }, "ui")
                    self:leave()
                end,
            }, "ui")
        end,
    }
    -- 「返回」: 去掉右上角 ✕ 之后, 这里必须有一个看得见的退出口
    table.insert(item_table, {
        text = _("返回"),
        callback = function()
            if self.history_menu~=menu or not WidgetSweep.isInStack(menu)then return end
            UIManager:close(self.history_menu, "ui")
            self.history_menu = nil
            self:leave()
        end,
    })

    local title_bar = MenuStyle.titleBar{ title = _("搜索历史") }
    menu = Menu:new{
        footer_actions = {clear_history},
        is_picayomi_page = true, -- 退出 Picayomi 时由 util/widget_sweep 清扫
        title = title_bar.title,
        custom_title_bar = title_bar,
        item_table = item_table,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        full_width = true,
        -- 整屏菜单必须显式声明 (Menu 类默认 is_popout=true 会画圆角, 四角穿透)
        is_popout = false,
        covers_fullscreen = true,
        onMenuHold = function(_, item)
            if self.history_menu~=menu then return true end
            if item and item.search_keyword then
                self:confirmRemoveHistoryKeyword(item.search_keyword)
            end
            return true
        end,
        close_callback = function()
            -- 返回键与可见返回入口都离开搜索，不重建输入框。
            if self.history_menu==menu then self:leave()end
        end,
    }
    self.history_menu=menu
    MenuStyle.disableSelectAutoClose(menu)
    TapGuard.install(self.history_menu)
    -- 左右滑动: 与其它全屏菜单一致 (左滑下一页 / 右滑上一页 / 第一页右滑 = 返回)
    -- 返回动作与条目里的「返回」相同: 收掉菜单 -> 返回调用方。
    MenuSwipe.attach(self.history_menu, function()
        if self.history_menu ~= menu or not WidgetSweep.isInStack(menu) then return end
        UIManager:close(menu, "ui")
        self.history_menu = nil
        self:leave()
    end)

    if page and page > 1 then
        self.history_menu:onGotoPage(math.min(page, self.history_menu.page_num))
    end
    WidgetSweep.replace_page(old_menu, self.history_menu)
end

function Search:confirmRemoveHistoryKeyword(keyword)
    local menu = self.history_menu
    if not menu or not WidgetSweep.isInStack(menu) then return end
    if self.history_delete_dialog and WidgetSweep.isInStack(self.history_delete_dialog) then return end
    local dialog
    dialog = ConfirmBox:new{
        is_picayomi_page = true,
        text = T(_("确定删除搜索记录【%1】吗？"), keyword),
        ok_text = _("删除"),
        cancel_text = _("取消"),
        cancel_callback = function()
            if self.history_delete_dialog == dialog then self.history_delete_dialog = nil end
        end,
        ok_callback = function()
            if self.history_delete_dialog ~= dialog or not WidgetSweep.isInStack(dialog) then return end
            self.history_delete_dialog = nil
            -- A confirmation owned by an earlier page must not act after navigation.
            if self.history_menu ~= menu or not WidgetSweep.isInStack(menu) then return end
            local ok, err = SearchHistory.remove(keyword)
            if not ok then
                UIManager:show(InfoMessage:new{
                    text = T(_("删除失败：%1"), require("ui.common.error_message").describe(err)),
                }, "ui")
                return
            end
            self:showHistoryMenu(menu.page)
        end,
    }
    self.history_delete_dialog = dialog
    UIManager:show(dialog, "ui")
end

function Search:performSearch()
    self:closeSearchDialog()
    local keyword=type(self.current_keyword)=="string" and self.current_keyword:gsub("^%s+",""):gsub("%s+$","")or ""
    if keyword==""then
        UIManager:show(InfoMessage:new{text=_("请输入搜索关键词")},"ui")
        return
    end
    self.current_keyword=keyword
    -- Save the user's attempt before access checks or asynchronous HTTP. A
    -- failed, cancelled or empty response must never decide history retention.
    local saved,save_error=SearchHistory.add(keyword)
    if not saved then
        UIManager:show(InfoMessage:new{text=T(_("搜索历史保存失败：%1"),save_error),timeout=3},"ui")
    end
    local source=require("source.registry"):getCurrent()
    if not require("ui.common.source_access").check(source,"search")then return end
    self._left=false
    self._query_generation=(self._query_generation or 0)+1
    local generation=self._query_generation
    if self.search_task then self.search_task:cancel()end
    local function current()
        return not self._left and self._query_generation==generation
            and require("source.registry"):getCurrent()==source
    end
    local loading=InfoMessage:new{text=T(_("搜索【%1】…（点击取消）"),keyword)}
    UIManager:show(loading,"ui");UIManager:forceRePaint()
    local page,sort=self.current_page,self.current_sort
    self.search_task=LoadingTask.background(loading,function()
        if not current()then LoadingTask.close(loading);return end
        local success,data,err=LoadingTask.call(loading,function()
            return self.comic_api:searchComics(keyword,page,sort)
        end)
        if not current()then return end
        if success and data then
            self.search_results=data.comics;self.current_page=data.page
            self.total_pages=data.pages;self.server_page_size=data.page_size
            self.result_has_more=data.has_more;self.total_count=data.total
            self:showSearchResults()
        else
            UIManager:show(InfoMessage:new{text=T(_("搜索失败: %1"),require("ui.common.error_message").describe(err))},"ui")
        end
    end,{
        is_cancelled=function()return not current()end,
        on_cancel=function()
            if self._query_generation==generation then self._query_generation=generation+1 end
        end,
        on_error=function(err)
            if current()then UIManager:show(InfoMessage:new{
                text=T(_("搜索失败: %1"),require("ui.common.error_message").describe(err)),timeout=3},"ui")end
        end,
    })
end

--- 当前源声明的搜索排序选项 (空表 -> 界面不显示排序按钮)
function Search:_sortOptions()
    local source = require("source.registry"):getCurrent()
    if not (source and source.getSortOptions) then return {} end
    return source:getSortOptions("search") or {}
end

function Search:showSearchResults()
    self.source = require("source.registry"):getCurrent()
    -- 换排序 / 重搜时旧列表要收掉, 否则窗口栈里会堆出多层一模一样的列表
    -- (踩过: "点了没反应" 就是这种堆叠造成的)。
    -- 但**不能先关再建**: 建新列表要排版, 中间露出来的是搜索框 (上一页) ——
    -- 真机上就是"点了排序先退回搜索页再刷新"。收在 replace_page 里 (先 show 新的)。
    local old_list = self.result_menu
    self.result_menu = nil

    if not self.search_results or #self.search_results == 0 then
        -- 没有结果: 旧列表必须收掉 (否则关掉提示又回到一份过期的结果)
        if old_list then UIManager:close(old_list, "ui") end
        UIManager:show(InfoMessage:new{
            text = T(self.source and self.source.content_type=="novel" and _("没有找到与【%1】相关的小说") or _("没有找到与【%1】相关的漫画"), self.current_keyword),
        }, "ui")
        return
    end

    local comics = {}
    for _idx, comic in ipairs(self.search_results) do
        table.insert(comics, self.comic_model:processComicData(comic))
    end

    local function fetch(page)
        return self.comic_api:searchComics(self.current_keyword, page, self.current_sort)
    end

    self.result_menu = VisualComicList:new{
        title = T(_("搜索结果: %1"), self.current_keyword),
        comics = comics,
        -- 单层分页: 翻到缓冲区末尾时由列表自己按需补货
        server_page = self.current_page,
        total_pages = self.total_pages, server_page_size = self.server_page_size,
        has_more = self.result_has_more,
        -- 首次进入就要有总条数, 否则界面算不出总屏数
        total_count = self.total_count,
        fetch_page = fetch,
        processor = function(raw) return self.comic_model:processComicData(raw) end,
        -- 搜索结果同样支持排序: 换排序 = 按新排序重搜第一页
        sort_options = self:_sortOptions(),
        sort = self.current_sort,
        on_sort_change = function(value)
            self.current_sort = value
            self.current_page = 1
            self:performSearch()
        end,
        on_select = function(comic, navigation)
            self:showComicDetail(comic, navigation)
        end,
        on_back = function(list)
            if list then UIManager:close(list, "ui") end
            self.result_menu = nil
            -- 搜索已经提交, 输入框在点「搜索」时就被释放了 —— 这里**不能**再
            -- showSearchDialog: 那会把已经释放的输入框重新压在主页上
            -- (真机 2026-10-18: "从结果列表返回, 搜索框还显示在主页上")。
            self:leave()
        end,
    }

    WidgetSweep.replace_page(old_list, self.result_menu)
end

function Search:showComicDetail(comic, navigation)
    if logger.enabled then logger.info("Picayomi", "显示漫画详情: " .. comic.title) end
    self.navigating_to_detail = true
    local generation = self._query_generation

    -- **不销毁结果列表** —— 详情页盖在它上面, 返回时原样露出来, 页码与已加载的
    -- 缓冲都在。以前这里 close + 置 nil, 返回时只能重新 showSearchResults():
    -- 一次网络请求 + 一个全新的 VisualComicList (screen_index = 1) —— 用户报的
    -- "进详情再返回, 列表又从第一页开始"。与 ui/home.lua / ui/history.lua 一致。
    -- (结果列表压在搜索输入框之上, 输入框在搜索发起时已关闭, 见 showSearchDialog 的
    --  调用点 —— 所以这里露出来的就是结果列表本身。)
    local source = navigation and navigation.source or require("source.registry"):getCurrent()
    self.detail_menu = ComicDetail:new{
        navigation = navigation,
        comic = comic,
        source = source,
        source_id = source and source.identifier or "picacg",
        comic_model = self.comic_model,
        reader = self.reader,
        -- 登录走账号, 未登录走本地兜底 (规则统一在 util/favorites.buildAction)
        favorite_action = FavoriteActions.buildAction{
            source = source,
            source_id = source and source.identifier or "picacg",
            comic_api = self.comic_api,
            comic = comic,
        },
        on_back = function()
            if self._left or self._query_generation ~= generation then return end
            self.navigating_to_detail = false
            self.detail_menu = nil
            -- 列表还在窗口栈里就什么都不用做 (关掉详情页它自己就露出来了);
            -- 真的不在 (理论上不该发生) 才退回重建, 免得用户对着空屏。
            if not WidgetSweep.isInStack(self.result_menu) then
                self:showSearchResults()
            end
        end,
        on_return_from_reader = function()
            if self._left or self._query_generation ~= generation then return end
            -- 读完一话回来: 详情页**没有被关掉** (api/comic.lua 现在故意留着它,
            -- 它就是返回目标), 结果列表还在它下面 —— 什么都不用做, 栈顶就是详情页。
            -- 保留 self.detail_menu 引用 (页面还活着, 置 nil 是自欺)。
            self.navigating_to_detail = false
            if not WidgetSweep.isInStack(self.result_menu)
               and not WidgetSweep.isInStack(self.detail_menu) then
                self:leave()
            end
        end,
    }

    UIManager:show(self.detail_menu, "ui")
end


return Search
