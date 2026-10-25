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

function Search:showSearchDialog()
    if not require("ui.common.source_access").check(require("source.registry"):getCurrent(),"search") then return end
    -- 幂等: 上一个输入框还在栈里就先收掉。
    --
    -- 不这么做的话, 任何"重复进入搜索"的路径都会在栈里叠出第二个输入框:
    -- 关掉看得见的那个, 下面那个还在 —— 用户看到的就是"搜索框怎么都关不掉"
    -- 或者"从别的页面回到主页, 搜索框还留在屏幕上" (真机 2026-10-18)。
    -- 主页的 Home:show 只在菜单已在栈里时 setDirty, 不会清理压在它上面的东西,
    -- 所以这里必须自己保证"最多一个"。
    if self.search_dialog then
        local old = self.search_dialog
        self.search_dialog = nil
        pcall(function() old:onCloseKeyboard() end)
        if WidgetSweep.isInStack(old) then
            UIManager:close(old, "ui")
        end
    end

    self.search_dialog = InputDialog:new{
        -- 标记为"插件顶层页面": 退出 Picayomi 时由 util/widget_sweep 统一清扫。
        -- 输入框是插件自己 show 出来的模态层, 不标记的话任何一条忘记关它的路径
        -- 都会把它留到 KOReader 的界面上 (这正是用户报的"搜索框遗留")。
        is_picayomi_page = true,
        title = _("搜索漫画"),
        input = "", -- A fresh input must not reuse the active result query.
        -- 按返回键关掉输入框时: 清引用 + 回到调用方 (主页)。
        -- 不接的话 self.search_dialog 会一直指着一个已经关掉的控件,
        -- 下次 showSearchDialog 的判断就靠它, 很容易叠出第二个框。
        close_callback = function()
            self.search_dialog = nil
            if self.return_callback then self.return_callback() end
        end,
        buttons = {
            {
                {
                    text = _("搜索"),
                    -- 注意: KOReader 的 ButtonTable 调用 callback 时**不传参数**
                    -- (buttontable.lua: btn_entry.callback()), 所以以前写的
                    -- `function(input)` 里 input 恒为 nil ——
                    -- 表现就是"明明输入了关键词, 点搜索却提示请输入关键词"。
                    -- 必须自己去读输入框。
                    callback = function()
                        local raw = self.search_dialog
                            and self.search_dialog:getInputText() or nil
                        local input = raw and raw:gsub("^%s+", ""):gsub("%s+$", "") or ""
                        if input ~= "" then
                            self.current_keyword = input
                            self.current_page = 1
                            -- **必须先把输入框关掉再去搜**。原来这里是直接 performSearch,
                            -- 于是搜索框留在栈里、结果列表压在上面; 之后从结果列表
                            -- 「返回」又会 showSearchDialog 建**第二个**输入框 ——
                            -- 两个一模一样的搜索框叠在一起, 关掉看得见的那个会露出
                            -- 下面那个, 用户以为"搜索框关不掉", 最后一直留到 KOReader
                            -- 的界面上 (用户报的就是这个)。
                            -- 与「历史」「取消」同一个做法: 先收键盘再关框。
                            if self.search_dialog then
                                pcall(function() self.search_dialog:onCloseKeyboard() end)
                                UIManager:close(self.search_dialog, "ui")
                                self.search_dialog = nil
                            end
                            self:performSearch()
                        else
                            UIManager:show(InfoMessage:new{
                                text = _("请输入搜索关键词"),
                            }, "ui")
                        end
                    end,
                },
                {
                    text = _("历史"),
                    -- 没有历史时置灰: 点开一个空列表等于"点了没反应" (见 F-UI-005)
                    enabled = SearchHistory.count() > 0,
                    callback = function()
                        -- 先收键盘再关输入框: 与「取消」同一个道理 —— 输入框关掉了但
                        -- 键盘还留在屏上时, 用户看到的是"键盘底下什么也没发生"
                        if self.search_dialog then
                            pcall(function() self.search_dialog:onCloseKeyboard() end)
                            UIManager:close(self.search_dialog, "ui")
                            self.search_dialog = nil
                        end
                        self:showHistoryMenu()
                    end,
                },
                {
                    text = _("取消"),
                    callback = function()
                        if logger.enabled then logger.info("Picayomi Search: 点击取消按钮，关闭搜索界面") end
                        -- 关闭所有可能存在的搜索相关对话框
                        if self.search_dialog then
                            -- 先收键盘: 输入框关掉了但键盘还留着的话, 屏幕看起来毫无变化,
                            -- 用户会以为"点了取消没反应"
                            pcall(function() self.search_dialog:onCloseKeyboard() end)
                            UIManager:close(self.search_dialog, "ui")
                            self.search_dialog = nil
                        end
                        if self.result_menu then
                            UIManager:close(self.result_menu, "ui")
                            self.result_menu = nil
                        end
                        if self.history_menu then
                            UIManager:close(self.history_menu, "ui")
                            self.history_menu = nil
                        end
                        -- 执行返回回调
                        if self.return_callback then
                            self.return_callback()
                        end
                    end,
                },
            },
        },
    }

    UIManager:show(self.search_dialog, "ui")
end

--- 离开搜索, 回到调用方 (主页)
--
-- 只有**还没提交**的流程 (历史菜单 / 取消) 才回输入框; 一旦按了「搜索」,
-- 输入框就已经被释放, 结果列表返回时只负责回主页。
function Search:leave()
    if self.search_task then self.search_task:cancel(); self.search_task = nil end
    if self.history_delete_dialog then
        if WidgetSweep.isInStack(self.history_delete_dialog) then
            UIManager:close(self.history_delete_dialog, "ui")
        end
        self.history_delete_dialog = nil
    end
    if self.search_dialog then
        local dlg = self.search_dialog
        self.search_dialog = nil
        pcall(function() dlg:onCloseKeyboard() end)
        if WidgetSweep.isInStack(dlg) then
            UIManager:close(dlg, "ui")
        end
    end
    if self.return_callback then self.return_callback() end
end

--- 用历史里的一个关键词直接重搜
function Search:searchFromHistory(keyword)
    self.current_keyword = keyword
    self.current_page = 1
    self:performSearch()
end

--- 搜索历史列表 (全屏 Menu)
--
-- 流程: 先关掉输入框 -> 显示整屏菜单 -> 关菜单时把用户送回输入框。
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
        self:showSearchDialog()
        return
    end

    -- **item_table 必须在 Menu:new 之前建好**。Menu:init 的结尾会立刻调一次
    -- `updateItems(1, true)` (menu.lua:979) 把当时的 item_table 渲染成控件;
    -- 构造完再往 `menu.item_table` 里 table.insert, 控件早已生成完毕 ——
    -- 新条目不会出现在屏幕上, 页脚停在 "无项目" (用户报的正是这个)。
    -- 其余菜单 (分类 / 排行榜 / 漫画源 / 章节列表) 都是"先建表再 new"。
    local item_table = {}
    for _i, keyword in ipairs(items) do
        table.insert(item_table, {
            text = keyword,
            search_keyword = keyword,
            picayomi_underline = true,
            callback = function()
                UIManager:close(self.history_menu, "ui")
                self.history_menu = nil
                self:searchFromHistory(keyword)
            end,
        })
    end
    table.insert(item_table, {
        text = _("清空历史"),
        callback = function()
            SearchHistory.clear()
            UIManager:close(self.history_menu, "ui")
            self.history_menu = nil
            UIManager:show(InfoMessage:new{
                text = _("已清空搜索历史"),
                timeout = 3,
            }, "ui")
            self:showSearchDialog()
        end,
    })
    -- 「返回」: 去掉右上角 ✕ 之后, 这里必须有一个看得见的退出口
    table.insert(item_table, {
        text = _("返回"),
        callback = function()
            UIManager:close(self.history_menu, "ui")
            self.history_menu = nil
            self:showSearchDialog()
        end,
    })

    local title_bar = MenuStyle.titleBar{ title = _("搜索历史") }
    self.history_menu = Menu:new{
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
            if item and item.search_keyword then
                self:confirmRemoveHistoryKeyword(item.search_keyword)
            end
            return true
        end,
        close_callback = function()
            -- 只剩返回键/✕ 会走到这里: 把用户送回搜索框
            self:showSearchDialog()
        end,
    }
    MenuStyle.disableSelectAutoClose(self.history_menu)
    TapGuard.install(self.history_menu)
    -- 左右滑动: 与其它全屏菜单一致 (左滑下一页 / 右滑上一页 / 第一页右滑 = 返回)
    -- 返回动作与条目里的「返回」完全相同: 收掉菜单 -> 回到搜索框
    MenuSwipe.attach(self.history_menu, function()
        UIManager:close(self.history_menu, "ui")
        self.history_menu = nil
        self:showSearchDialog()
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
    if not require("ui.common.source_access").check(require("source.registry"):getCurrent(),"search") then return end
    if self.search_task then self.search_task:cancel() end
    -- 显示加载消息
    local loading = InfoMessage:new{
        text = T(_("搜索【%1】…（点击取消）"), self.current_keyword),
    }
    UIManager:show(loading, "ui")
    -- 在准备请求和创建子进程之前先显示加载提示。
    UIManager:forceRePaint()

    local keyword, page, sort = self.current_keyword, self.current_page, self.current_sort
    self.search_task = LoadingTask.background(loading, function()
        -- 执行搜索
        -- 抛异常时也关掉提示, 否则"搜索【…】..."永久盖屏 (见 loading_task 注释)
        local success, search_data, error_msg = LoadingTask.call(loading, function()
            return self.comic_api:searchComics(keyword, page, sort)
        end)

        if success and search_data then
            -- 保存搜索结果
            self.search_results = search_data.comics
            self.current_page = search_data.page
            self.total_pages = search_data.pages
            self.result_has_more=search_data.has_more
            self.total_count = search_data.total

            -- 记进搜索历史 (只记**真的搜到东西**的那次: 打错字的词不该占着历史列表)
            --
            -- **点调用, 不是冒号**: util/search_history 的函数签名是 `function M.add(keyword)`,
            -- 没有 self。写成 `SearchHistory:add(kw)` 会把模块表自己当成 keyword 传进去,
            -- normalize 判空后直接 return false —— 结果是"搜过但一条历史都不记", 而且
            -- 不报任何错。测试里用的是点调用, 所以测试全绿而真机不记录。
            -- (同一个约定见 util/local_favorites.lua: 调用方一律用点。)
            SearchHistory.add(keyword)

            -- 显示搜索结果
            self:showSearchResults()
        else
            -- 显示错误消息
            UIManager:show(InfoMessage:new{
                text = T(_("搜索失败: %1"), require("ui.common.error_message").describe(error_msg)),
            }, "ui")
        end
    end, {
        on_error = function(err)
            UIManager:show(InfoMessage:new{
                text = T(_("搜索失败: %1"), require("ui.common.error_message").describe(err)), timeout = 3,
            }, "ui")
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
            text = T(_("没有找到与【%1】相关的漫画"), self.current_keyword),
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
        total_pages = self.total_pages,
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
            self.navigating_to_detail = false
            self.detail_menu = nil
            -- 列表还在窗口栈里就什么都不用做 (关掉详情页它自己就露出来了);
            -- 真的不在 (理论上不该发生) 才退回重建, 免得用户对着空屏。
            if not WidgetSweep.isInStack(self.result_menu) then
                self:showSearchResults()
            end
        end,
        on_return_from_reader = function()
            -- 读完一话回来: 详情页**没有被关掉** (api/comic.lua 现在故意留着它,
            -- 它就是返回目标), 结果列表还在它下面 —— 什么都不用做, 栈顶就是详情页。
            -- 保留 self.detail_menu 引用 (页面还活着, 置 nil 是自欺)。
            self.navigating_to_detail = false
            if not WidgetSweep.isInStack(self.result_menu)
               and not WidgetSweep.isInStack(self.detail_menu) then
                self:show(self.return_callback)
            end
        end,
    }

    UIManager:show(self.detail_menu, "ui")
end


return Search
