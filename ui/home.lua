-- ui/home.lua
-- PicaYomi 主界面
-- 使用新架构 (source.registry + network.download_manager)

local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local Menu = require("ui/widget/menu")
local Notification = require("ui/widget/notification")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("util.logger")
local _ = require("gettext")
local T = require("ffi/util").template
local FavoriteActions = require("util.favorites")
local TextWidget = require("ui/widget/textwidget")
local Geom = require("ui/geometry")
local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local ButtonDialog = require("ui/widget/buttondialog")
local InputDialog = require("ui/widget/inputdialog")
local SpinWidget = require("ui/widget/spinwidget")
local Input = require("device").input
local VisualComicList = require("ui.common.visual_comic_list")
local ComicDetail = require("ui.common.comic_detail")
local TapGuard = require("ui.common.tap_guard")
local MenuStyle = require("ui.common.menu_style")
local MenuSwipe = require("ui.common.menu_swipe")
local WidgetSweep = require("util.widget_sweep")
local LoadingTask = require("ui.common.loading_task")
local SourceAccess = require("ui.common.source_access")

-- 新架构模块
local SourceRegistry = require("source.registry")
local DownloadManager = require("network.download_manager")
local config = require("util.config")

-- 旧架构模块 (逐步迁移中)
local ComicModel = require("model.comic")

local Home = WidgetContainer:extend{
    name = "picayomi_home",
    title = _("Picayomi"),
    width = Screen:getWidth(),
    height = Screen:getHeight(),
}

function Home:init()
    -- 获取当前源
    self.source = SourceRegistry:getCurrent()
    if self.source then
        self.source:init()
    end

    -- 保留旧模块引用 (兼容期)
    self.comic_model = ComicModel

    -- 子界面改为按需惰性创建 (见 _getUI / _getReader)：
    -- 一次性实例化全部子界面需要集中加载大量模块，会让点击后的界面出现明显延迟。
    self._uis = {}

    self:createMainMenu()
    -- 供"别处切换了源"的路径 (如「已下载」跨源打开) 找回主页实例并重建菜单。
    -- 不这样做的话, 返回主页时菜单仍显示旧源的能力与名称。
    Home.instance = self
end

--- 把主页的源对齐到注册表 (注册表是唯一真相)
--
-- 别处会切换当前源: 「已下载」里打开**别的源**的条目时会 switch 过去 (阅读链路
-- 走的是"当前源")。主页若不跟着变, 就会出现"菜单写着源 A, 点进分类/收藏却是
-- 源 C 的数据" —— 真机反馈的正是这个。
--
-- @return 是否真的换了源
function Home:ensureCurrentSource()
    local current = SourceRegistry:getCurrent()
    if current == self.source then return false end

    self.source = current
    -- 排序取值是按源的, 换源必须清掉 (否则新源收到旧源的 s= 会回 validation error)
    self.current_sort = nil
    -- source:init() 可能是同步网络 (源 B 要探域名), 期间菜单必须还挂在屏幕上 ——
    -- 先关再建的话那几秒露出来的是文件浏览器, 用户看到的就是"切源退回了上一页"。
    if self.source then self.source:init() end

    local old_menu = self.main_menu
    self.main_menu = nil
    self:createMainMenu()
    if old_menu and self:isMenuShown(old_menu) then
        -- 旧菜单正在屏幕上: 先 show 新的, 再关旧的 (中间不留空档)
        WidgetSweep.replace_page(old_menu, self.main_menu)
    end
    return true
end

--- 若当前源已被别处切换, 重建主页菜单 (调用方应在返回主页之前调用)
function Home.syncCurrentSource()
    local h = Home.instance
    if not h then return false end
    local changed = h:ensureCurrentSource()
    if changed and h.main_menu and not h:isMenuShown(h.main_menu) then
        UIManager:show(h.main_menu, "ui")
    end
    return changed
end

--- 惰性获取子界面实例 (首次访问时才创建)
function Home:_getUI(name)
    self._uis = self._uis or {}
    local ui = self._uis[name]
    if not ui then
        ui = require("ui." .. name):new{}
        self._uis[name] = ui
    end
    return ui
end

--- 惰性获取阅读器模块
function Home:_getReader()
    if not self._reader then
        self._reader = require("ui.reader")
    end
    return self._reader
end

function Home:createMainMenu()
    local source = self.source
    local has = function(cap)
        return require("source.capabilities").query(source,cap).supported
    end

    -- 按源的能力动态生成菜单项 (不同源支持的浏览/搜索/收藏能力差异很大)
    local item_table = {}

    -- 当前源条目本身就是切换入口: 原来"当前源(灰、不可点)"+"切换漫画源"两项只做一件事,
    -- 合并为可点击的一项 (Kindle 小屏上省一行, 也更直观)。
    table.insert(item_table, {
        text = T(_("漫画源: %1 (点击切换)"), source and source.name or _("无")),
        callback = function()
            self:showSourceSwitcher()
        end,
    })

    if has("recommendations") then
        table.insert(item_table, { text = _("推荐漫画"), callback = function() self:showRecommended(nil, "recommendations") end })
    end
    if has("latest") or source and not source._extension_digest and not source._offline then
        table.insert(item_table, { text = _("最新漫画"), callback = function() self:showRecommended(nil, "latest") end })
    end

    if has("categories") then
        table.insert(item_table, {
            text = _("分类浏览"),
            callback = function()
                self:showCategories()
            end,
        })
    end

    if has("rankings") then
        table.insert(item_table, {
            text = _("排行榜"),
            callback = function()
                self:showRanking()
            end,
        })
    end

    -- 收藏: 网络收藏 (登录) 或本地收藏 (未登录兜底) 只要有一个能用就显示入口
    self.favorites_item = nil
    if has("favorites") or has("local_favorites") then
        self.favorites_item = {
            text = FavoriteActions.backend(source) == "online"
                and _("我的收藏 (线上)") or _("我的收藏 (本地)"),
            callback = function()
                self:showFavorites()
            end,
        }
        table.insert(item_table, self.favorites_item)
    end

    table.insert(item_table, {
        text = _("浏览历史"),
        callback = function()
            self:showHistory()
        end,
    })

    -- 已下载: 与源能力无关 (本地文件); 未登录/断网时也应该能用。
    -- 因此它排在登录门槛之前 —— 登录提示框里也给了同一个入口。
    table.insert(item_table, {
        text = _("已下载"),
        callback = function()
            self:showDownloads()
        end,
    })

    if has("search") then
        table.insert(item_table, {
            text = _("搜索漫画"),
            callback = function()
                self:showSearch()
            end,
        })
    end

    if has("login") then
        table.insert(item_table, {
            text = source and source:isLoggedIn() and _("账号管理") or _("登录账号"),
            callback = function()
                self:showAccount()
            end,
        })
    end

    table.insert(item_table, {
        text = _("设置"),
        callback = function()
            self:showSettings()
        end,
    })

    -- 关掉插件页面之后, 保证窗口栈里还剩**非插件**的底层界面
    --
    -- 为什么必须有: KOReader 的 handleInput 每轮都检查栈底, 栈空就判定"没有界面了"
    -- 并退出整个程序 (uimanager.lua:1556)。而阅读期间 KOReader 会关掉文件浏览器
    -- (FileManager:onShowingReader), 从阅读页回来之后栈里可能真的只剩插件页面 ——
    -- 真机 01:07:47 的 "No dialogs left to show" -> "exit code: 0" 就是这么来的。
    -- 底层界面要么是文件浏览器, 要么是阅读器。
    local function keep_base()
        local remaining = 0
        for _i, entry in ipairs(UIManager._window_stack or {}) do
            local w = entry.widget
            if not (type(w) == "table" and w.is_picayomi_page) then
                remaining = remaining + 1
            end
        end
        if remaining == 0 then WidgetSweep.ensureBase() end
    end

    -- 「退出」项与右滑共用的退出动作
    --
    -- **退出 = 关掉所有插件页面**, 不是"退回上一页"。
    -- 主页下面常常还压着来路: 详情页 / 列表页 / 设置页 (例如"阅读完返回
    -- Picayomi"之后, 栈里保留着详情页)。只关主菜单的话, 用户点「退出」看到的
    -- 却是"又回到了上一页" (真机 2026-10-18)。这里统一清扫, 只留非插件的底层
    -- (文件浏览器), 语义与 KOReader 里退出一个插件一致。
    local function leave_home()
        if self._leaving then return end
        self._leaving = true
        local ok, sweep = pcall(require, "util.widget_sweep")
        if ok and sweep then
            pcall(function() sweep.closeAll() end)
        else
            UIManager:close(self.main_menu, "ui")
            UIManager:close(self, "ui")
        end
        keep_base()
        if self.return_callback then
            self.return_callback()
        end
    end

    table.insert(item_table, {
        -- 名字就写「退出」: 它做的事就是退出插件, 不叫"返回"才不会让人以为
        -- 还能退回上一页。
        text = _("退出"),
        callback = leave_home,
    })

    -- 标题栏走 MenuStyle: 去掉右上角那个与「返回」做同一件事的 ✕
    -- (理由见 ui/common/menu_style.lua)
    local title_bar = MenuStyle.titleBar{ title = _("Picayomi") }
    self.main_menu = Menu:new{
        is_picayomi_page = true, -- 退出 Picayomi 时由 util/widget_sweep 清扫
        -- 标记: 供 Home.findShownMenu 判断"主页菜单是否已在窗口栈里"
        is_picayomi_home_menu = true,
        title = title_bar.title,
        custom_title_bar = title_bar,
        item_table = item_table,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        full_width = true,
        -- 必须显式声明"这是整屏菜单, 不是浮动小菜单":
        --   Menu 的类默认值是 is_popout = true, 那会给整屏菜单画一个 radius = w/20
        --   的大圆角 —— 四个角于是露出**下层的文件浏览器**, 点到那里就穿透过去,
        --   正好压在某个文件上就把它打开了 (用户看到的是"点了却进了阅读")。
        --   同时 tap_guard 只给非弹出式菜单加兜底消费, 声明对了它才生效。
        is_popout = false,
        -- 整屏页面: 不再绘制下层 ReaderUI (否则阅读器顶部状态栏的时间会透出来)
        covers_fullscreen = true,
        close_callback = function()
            -- 选中条目走不到这里 (见下面 disableSelectAutoClose), 剩下的就是返回键:
            -- onCloseAllMenus 先 UIManager:close(self) 再调本回调 (menu.lua:1503-1506)
            -- —— 菜单已经不在栈里 = 用户真的要退出。
            -- 退出动作本身会清空整个栈, 用 _leaving 防止重入 (Home 可被再次 show)。
            if self._leaving then return end
            leave_home()
        end,
    }
    -- 点条目 (排行榜/搜索/设置...) 不能顺手把主页退掉
    MenuStyle.disableSelectAutoClose(self.main_menu)

    -- 全屏菜单的缝隙也要吃掉落空的 tap: 菜单项之间有缝隙, 缝隙里的 tap 没人消费
    -- 就会继续往下层窗口传 (见 tap_guard 的注释)。
    TapGuard.install(self.main_menu)
    -- 主页**不绑定滑动退出** —— 只保留"左滑翻页"。
    --
    -- 真机反馈 (2026-10-18): 主页右滑/边缘滑直接退出 Picayomi 回到 KOReader,
    -- 稍微滑一下就掉出插件, 代价太大且不好回来。退出是**破坏性**动作, 只能走
    -- 明确入口: 菜单里的「退出」项, 或返回键。
    -- 不传 on_back: 第一页右滑 (含边缘往中间滑) 什么都不做, 事件照样被吃掉,
    -- 不会穿透到下层。
    MenuSwipe.attach(self.main_menu)
end

--- 在窗口栈里找已经打开的主页菜单 (没有则 nil)
--
-- 为什么需要它: UIManager:show() **不会去重**, 同一个控件重复 show 就会在窗口栈里
-- 堆叠多层。子页面返回时若直接再 show 一次主页菜单, 栈里就会出现
-- [底层, 主页A, 主页B, ...]; 之后每点一次「返回」只弹掉一层**长得一模一样**的菜单,
-- 屏幕上看起来毫无变化 —— 实测点 4 次才退得出去, 用户只会觉得"卡死"。
function Home.findShownMenu()
    local ok, ui_window = pcall(require, "ui/uimanager")
    if not ok or not ui_window or not ui_window._window_stack then return nil end
    for _i, entry in ipairs(ui_window._window_stack) do
        local w = entry.widget
        if type(w) == "table" and w.is_picayomi_home_menu then
            return w
        end
    end
    return nil
end

--- 登录状态变化后更新收藏入口, 与实际收藏后端保持一致。
function Home:refreshFavoritesLabel()
    if not self.favorites_item or not self.main_menu then return end
    local label = FavoriteActions.backend(self.source) == "online"
        and _("我的收藏 (线上)") or _("我的收藏 (本地)")
    if self.favorites_item.text ~= label then
        self.favorites_item.text = label
        self.main_menu:updateItems()
    end
end

--- 回到主页 (供子页面 / 登录页调用)
-- 已经在栈里就只重绘, 否则才新建 —— 绝不无条件 new+show
function Home.returnToHome()
    local UIManager = require("ui/uimanager")
    local shown = Home.findShownMenu()
    if shown then
        require("source.extensions.updater").schedule()
        if Home.instance then Home.instance:refreshFavoritesLabel() end
        UIManager:setDirty(shown, "ui")
        return true
    end
    local home = Home:new{}
    home:show()
    return true
end

function Home:show(return_callback)
    require("source.extensions.updater").schedule()
    self.return_callback = return_callback
    -- 退出标记只对一次退出有效: Home 实例可能被再次 show (例如重新进入插件)
    self._leaving = nil

    -- 别处可能切换过源 (已下载里打开跨源条目就会), 每次显示主页先对齐 ——
    -- 菜单上的源名与实际取数的源必须是同一个。
    self:ensureCurrentSource()
    self:refreshFavoritesLabel()

    -- 只有"不登录就用不了"的源才拦截并提示登录 —— 判据是 requires_login,
    -- 不是 login。源 C 支持登录 (capabilities.login = true) 但免登录也能浏览/
    -- 阅读, 用 login 当判据会把它整个挡在登录框后面。
    local need_login = self.source and self.source:hasCapability("requires_login")
    if self.source and need_login and not self.source:isLoggedIn() then
        self:showLoginPrompt()
        return
    end

    -- 已经在栈里就只重绘: 重复 show 会堆叠出多个相同菜单, 导致「返回」看起来没反应
    if self:isMenuShown(self.main_menu) then
        -- 但"只重绘"有个前提: 主页必须真的在最上层。
        -- 任何**忘了关**的插件层 (最典型的是搜索输入框) 都会继续盖着它 ——
        -- 用户从别的页面回到主页, 看到的还是那个搜索框 (真机 2026-10-18)。
        -- 语义上"回到主页"就是"主页在最上面", 所以这里顺手收掉上面的插件层。
        self:closeAboveMainMenu()
        UIManager:setDirty(self.main_menu, "ui")
        return
    end

    UIManager:show(self.main_menu, "ui")
end

--- 关掉压在主菜单之上的插件层 (弹窗 / 子页面)
--
-- 只关**插件**控件 (带 is_picayomi_page 标记的)。KOReader 自己的窗口
-- (键盘 / 文件浏览器) 不在这里的职责范围内 —— 键盘由各自弹窗自己收。
function Home:closeAboveMainMenu()
    local stack = UIManager._window_stack
    if type(stack) ~= "table" then return end
    local idx
    for i, entry in ipairs(stack) do
        if entry and entry.widget == self.main_menu then idx = i break end
    end
    if not idx then return end

    -- 先收集再关: UIManager:close 会改 _window_stack, 边遍历边删容易跳项
    local doomed = {}
    for i = #stack, idx + 1, -1 do
        local w = stack[i] and stack[i].widget
        if type(w) == "table" and w.is_picayomi_page then
            doomed[#doomed + 1] = w
        end
    end
    for _i, w in ipairs(doomed) do
        if logger.enabled then logger.info("Picayomi Home: 回到主页时收掉上层残留页面") end
        UIManager:close(w, "ui")
    end
end

--- 某个控件当前是否在窗口栈里
function Home:isMenuShown(widget)
    if not widget then return false end
    local ok, ui_window = pcall(require, "ui/uimanager")
    if not ok or not ui_window or not ui_window._window_stack then return false end
    for _i, entry in ipairs(ui_window._window_stack) do
        if entry.widget == widget then return true end
    end
    return false
end

function Home:showLoginPrompt()
    local source_name = (self.source and self.source.name) or "Picayomi"
    self.login_prompt = ButtonDialog:new{
        -- 这是**唯一**可能单独存在的插件层 (主页菜单还没压进栈就先弹了它),
        -- 所以它自己必须带清扫标记, 否则 util/widget_sweep 找不到锚点
        is_picayomi_page = true,
        title = _("需要登录"),
        text = T(_("请先登录%1账号"), source_name),
        buttons = {
            {
                {
                    text = _("登录"),
                    callback = function()
                        UIManager:close(self.login_prompt, "ui")
                        self:_getUI("login"):show()
                    end,
                },
                {
                    text = _("已下载"),
                    callback = function()
                        UIManager:close(self.login_prompt, "ui")
                        self:showDownloads()
                    end,
                },
                {
                    text = _("设置"),
                    callback = function()
                        UIManager:close(self.login_prompt, "ui")
                        self:showSettings()
                    end,
                },
                {
                    text = _("取消"),
                    callback = function()
                        UIManager:close(self.login_prompt, "ui")
                        UIManager:close(self, "ui")
                    end,
                },
            },
        },
    }
    UIManager:show(self.login_prompt, "ui")
end

-- ============================================================================
-- 漫画列表
-- ============================================================================

function Home:showRecommended(sort, kind)
    if not SourceAccess.check(self.source, kind or "latest") then return end
    kind = kind or "latest"
    local source = self.source
    local method = kind == "recommendations" and "getRecommendations" or "getLatest"
    local title = kind == "recommendations" and _("推荐漫画") or _("最新漫画")
    local status = require("source.capabilities").query(source, kind)
    if source and source._extension_digest and not status.available then
        UIManager:show(InfoMessage:new{ text=status.reason,timeout=3 },"ui"); return
    end
    local fetch = function(page, order)
        if source[method] then return source[method](source, page, order) end
        return source:getComics(page, order)
    end
    -- 可选排序由源声明: 源 A 4 种, 源 B 的"推荐/最新"不支持排序(返回空表),
    -- 界面据此不显示"排序"按钮 —— 显示一个点了没反应的按钮更糟。
    -- 默认取第一个 (源 A ua / 源 B mr), 与接口自身的默认值一致。
    local sort_options = (self.source and self.source.getSortOptions)
        and self.source:getSortOptions(kind == "recommendations" and "recommend" or "latest") or {}
    self.current_sort = sort or self.current_sort
    -- 当前排序必须是**这个源**的合法取值。Home 实例在切源后继续复用, 而
    -- current_sort 是上一次源留下的 (源 B 的 mr / 源 A 的 dd): 直接发给新源,
    -- 服务端一律回 "validation error" (真机 2026-10-18: 从源 B 切到源 A 后
    -- 推荐/最新打不开, 日志里是 "加载推荐漫画 (排序 mr)")。
    local valid = false
    for _idx, opt in ipairs(sort_options) do
        if opt.value == self.current_sort then valid = true break end
    end
    if not valid then
        self.current_sort = sort_options[1] and sort_options[1].value or nil
    end

    if logger.enabled then logger.info("Picayomi Home: 加载推荐漫画 (排序 " .. tostring(self.current_sort) .. ")") end
    local loading = InfoMessage:new{ text = title .. _("加载中…（点击取消）") }
    UIManager:show(loading, "ui")
    -- 同步刷一次: show 只是把刷新入队, 而这里马上要阻塞做网络请求,
    -- 不等这一下的话事件循环没机会重绘, 提示等于没显示
    UIManager:forceRePaint()

    -- 使用新架构异步加载
    self:_loadComicList(function()
        return fetch(1, self.current_sort)
    end, title, loading, nil, {
        options = sort_options,
        sort = self.current_sort,
        on_change = function(value) self:showRecommended(value, kind) end,
    }, function(page) return fetch(page, self.current_sort) end)
end

function Home:showRanking()
    if not SourceAccess.check(self.source, "rankings") then return end
    -- Platform values belong to adapters. Never substitute another site's types.
    local ok, types = pcall(self.source.getRankingTypes, self.source)
    local ranking_types = {}
    for _, t in ipairs(ok and type(types)=="table" and types or {}) do
        if type(t)=="table" and t.id~=nil and type(t.title)=="string" and t.title~="" then
            ranking_types[#ranking_types+1] = {text=t.title,value=t.id}
        end
    end
    if #ranking_types==0 then
        UIManager:show(InfoMessage:new{text=_("当前源没有可用的排行榜类型"),timeout=3},"ui")
        return
    end

    local item_table = {}
    for _, type in ipairs(ranking_types) do
        table.insert(item_table, {
            text = type.text,
            callback = function()
                -- **不关类型菜单**: 它是列表的"来路"。关掉再取数的那几秒里屏幕
                -- 会退回主菜单 —— 用户看到的就是"选了排行榜类型先回主页再出列表"。
                self:loadRanking(type.value, type.text)
            end,
        })
    end

    -- 关掉类型菜单, 露出下面的主菜单。
    -- 主菜单本来就在窗口栈里 (类型菜单是压在其上的), 关掉它就自然重新可见 ——
    -- **不能**再无条件 UIManager:show(main_menu): show 不去重, 会叠出第二份主菜单,
    -- 之后「返回」只弹掉一层长得一样的菜单 (用户看到"点了没反应")。
    local function close_type_menu()
        if self.ranking_type_menu then
            UIManager:close(self.ranking_type_menu, "ui")
            self.ranking_type_menu = nil
        end
        if not self:isMenuShown(self.main_menu) then
            UIManager:show(self.main_menu, "ui")
        end
    end

    table.insert(item_table, {
        text = _("返回"),
        callback = function()
            close_type_menu()
        end,
    })

    local type_title_bar = MenuStyle.titleBar{ title = _("选择排行榜类型") }
    self.ranking_type_menu = Menu:new{
        is_picayomi_page = true, -- 退出 Picayomi 时由 util/widget_sweep 清扫
        title = type_title_bar.title,
        custom_title_bar = type_title_bar,
        item_table = item_table,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        full_width = true,
        is_popout = false,
        -- 整屏页面: 不再绘制下层 ReaderUI (否则阅读器顶部状态栏的时间会透出来)
        covers_fullscreen = true,
        is_borderless = false,
        tap_close_callback = function()
            close_type_menu()
        end,
        close_callback = function()
            -- 按返回键关闭菜单时也会走这里: 把用户送回主菜单 (同样不重复压栈)
            close_type_menu()
        end,
    }
    -- 选中类型时**不能**走 close_callback: 那一瞬间就会把类型菜单收掉, 而取数
    -- 还在排队 —— 屏幕先闪回主菜单几秒才出列表 (真机"点了排行榜像返回了主页")。
    -- 类型菜单要一直压到列表出来, 作为列表的"来路" (returnToListBase 靠它)。
    MenuStyle.disableSelectAutoClose(self.ranking_type_menu)
    -- 全屏菜单的缝隙也要吃掉落空的 tap (否则穿透到下层, 见 tap_guard 注释)
    TapGuard.install(self.ranking_type_menu)
    -- 右滑 = 返回 (收掉类型菜单, 露出主菜单); 与「返回」项同一个动作
    MenuSwipe.attach(self.ranking_type_menu, close_type_menu)

    UIManager:show(self.ranking_type_menu, "ui")
end

function Home:loadRanking(type_value, type_text, page)
    if not SourceAccess.check(self.source, "rankings") then return end
    page = page or 1
    local loading = InfoMessage:new{ text = T(_("加载%1排行榜…（点击取消）"), type_text) }
    UIManager:show(loading, "ui")
    -- 同步刷一次: show 只是把刷新入队, 而这里马上要阻塞做网络请求,
    -- 不等这一下的话事件循环没机会重绘, 提示等于没显示
    UIManager:forceRePaint()

    self:_loadComicList(function()
        return self.source:getRankings(type_value, page)
    end, T(_("%1排行榜"), type_text), loading, page, nil,
    -- 翻页要留在**同一个榜单**里: 不传这个的话列表自己补货时会退回 getComics,
    -- 用户翻到第二屏突然变成"最新"列表 (且标题还写着排行榜)。
    function(p) return self.source:getRankings(type_value, p) end)
end

--- 通用的漫画列表加载器
-- @param fetch_fn: 获取数据的函数, 返回 ok, data
-- @param title: 列表标题
-- @param loading: 加载提示 widget
-- @param page: 当前页码
-- @param sort_spec: 可选 { options=, sort=, on_change= }, 透传给列表的"排序"按钮
--- @param fetch_page 可选 function(page) -> ok, data
---        列表自己翻页时用。缺省取"推荐列表" (getComics), 排行榜/分类必须显式给,
---        否则翻到第二屏会**悄悄换成推荐列表** (旧实现就是这个 bug)。
function Home:_loadComicList(fetch_fn, title, loading, page, sort_spec, fetch_page)
    if not SourceAccess.check(self.source) then
        if loading then UIManager:close(loading,"ui") end
        return
    end
    if self.list_task then self.list_task:cancel() end
    local source = self.source
    -- 先把"加载中"提示画出来, 否则同步请求期间界面看起来是卡死的
    if loading then UIManager:forceRePaint() end
    self.list_task = LoadingTask.background(loading, function()
        -- 必须 pcall: 取数抛异常时若走不到 close(loading),
        -- "加载中"会永久盖在屏幕上 (表现为列表怎么点都出不来)
        local pok, ok, data, err = pcall(fetch_fn)

        -- 「加载中」提示**留到新列表出来之后再关**。
        --
        -- 先关提示再建列表的话, 那中间露出来的是**旧列表**; 而旧列表紧接着又被
        -- 新列表替换 —— 真机上就是"先闪回一下旧内容再刷新"。提示本身是盖在
        -- 旧页面上的, 让它一直撑到新页面压上来, 整段过渡就没有空档。
        local function close_loading()
            if loading then LoadingTask.close(loading) end
        end

        if not pok then
            close_loading()
            logger.warn("Picayomi Home: 列表取数异常: " .. tostring(ok))
            UIManager:show(InfoMessage:new{
                text = T(_("获取失败: %1"), tostring(ok)),
                timeout = 3,
            }, "ui")
            self:returnToListBase()
            return
        end

        if not ok or not data or not data.comics then
            close_loading()
            local msg = err or data or "获取数据失败"
            if type(msg) ~= "string" then msg = "获取数据失败" end
            UIManager:show(InfoMessage:new{
                text = T(_("获取失败: %1"), msg),
                timeout = 3,
            }, "ui")
            self:returnToListBase()
            return
        end

        if #data.comics == 0 then
            close_loading()
            UIManager:show(InfoMessage:new{
                text = _("没有找到漫画"),
                timeout = 2,
            }, "ui")
            self:returnToListBase()
            return
        end

        -- 新列表先起来 (盖住提示与旧列表), 再收提示与旧列表
        local ok_show, show_err = pcall(function()
            self:_showComicList(title, data, page, sort_spec, fetch_page)
        end)
        close_loading()
        if not ok_show then
            logger.warn("Picayomi Home: 建列表异常: " .. tostring(show_err))
            self:returnToListBase()
        end
    end, {
        delay = 0.1,
        is_cancelled = function() return self.source ~= source end,
        on_error = function(err)
            UIManager:show(InfoMessage:new{
                text = T(_("获取失败: %1"), tostring(err)), timeout = 3,
            }, "ui")
        end,
    })
end

--- 列表页的"来路"层: 排行榜类型菜单 > 主菜单
--
-- 取数失败 / 空列表 / 用户返回时都回到这一层。**不能**无条件 show 主菜单:
-- 类型菜单还压在栈里时, show 会把主菜单叠到它上面 (看起来像"返回跳了一层")。
function Home:returnToListBase()
    if self.ranking_type_menu and self:isMenuShown(self.ranking_type_menu) then
        UIManager:setDirty(self.ranking_type_menu, "ui")
        return
    end
    if self:isMenuShown(self.main_menu) then
        UIManager:setDirty(self.main_menu, "ui")
    else
        UIManager:show(self.main_menu, "ui")
    end
end

--- 显示漫画列表
function Home:_showComicList(title, data, page, sort_spec, fetch_page)
    page = page or (data.page or 1)

    local comics = {}
    for _idx, comic in ipairs(data.comics or {}) do
        table.insert(comics, self.comic_model:processComicData(comic))
    end

    -- 换排序 / 重新加载会再走一次这里: 旧的列表要收掉, 否则窗口栈里会叠出多层
    -- 一模一样的列表, 用户按「返回」要多按几次才退得出去 (看起来像"点了没反应"),
    -- 而且下层那份还留着旧的点击区, 更容易点错。
    --
    -- **但不能先关再建**: 建新列表要走一遍排版, 中间那一瞬露出来的是主页 ——
    -- 真机上就是"点了排序先退回上一页再刷新"。收在 replace_page 里: 先 show 新的。
    local old_list = self.comic_list_menu

    self.comic_list_menu = VisualComicList:new{
        title = title,
        comics = comics,
        source = self.source,
        source_id = self.source and self.source.identifier or "picacg",
        -- 单层分页: 翻到缓冲区末尾时由列表自己按需补货
        server_page = data.page or page or 1,
        total_pages = data.pages,
        has_more = data.has_more,
        -- 总条数必须在**首次进入**时就带上: 只给 pages 的话界面上算不出总屏数,
        -- 得等翻到第二批补货才拿到 total, 表现为"刚进列表不显示总量"
        total_count = data.total,
        -- 翻页必须沿用"这一份列表"的取数方式 (排行榜/分类/搜索各自不同)。
        -- 缺省才是推荐列表。
        fetch_page = fetch_page or function(p)
            return self.source:getComics(p, self.current_sort)
        end,
        -- 排序按钮: 只有源声明了可用排序时才出现
        sort_options = sort_spec and sort_spec.options or nil,
        sort = sort_spec and sort_spec.sort or nil,
        on_sort_change = sort_spec and sort_spec.on_change or nil,
        processor = function(raw) return self.comic_model:processComicData(raw) end,
        on_select = function(comic)
            self:showComicDetail(comic)
        end,
        on_back = function(list)
            if list then UIManager:close(list, "ui") end
            self.comic_list_menu = nil
            -- 主菜单本来就压在列表下面, 关掉列表它自己就露出来了 ——
            -- **不能**无条件再 show 一次: UIManager:show 不去重, 会把同一个菜单
            -- 重复压栈, 之后每次「返回」只弹掉一层长得一模一样的菜单
            -- (用户看到的就是"点了没反应", 这个坑踩过)。
            -- 排行榜类型菜单还压在下面时, 关掉列表就回到它 (不是主菜单)
            self:returnToListBase()
        end,
    }

    WidgetSweep.replace_page(old_list, self.comic_list_menu)
end

-- ============================================================================
-- 漫画详情
-- ============================================================================

--- 显示漫画详情
--
-- @param episodes_data 可选。已知的章节数据 { episodes = {...}, page =, pages =, total = }。
--        给了就不再发章节请求 (ComicDetail:init 的短路, 见其 :258 的注释) ——
--        "关阅读器回详情页"那条路会把它从阅读上下文里带过来。
function Home:showComicDetail(comic, episodes_data)
    if not SourceAccess.check(self.source) then return end
    if logger.enabled then logger.info("Picayomi Home: 显示漫画详情: " .. comic.title) end

    self.detail_menu = ComicDetail:new{
        comic = comic,
        source = self.source,
        source_id = self.source and self.source.identifier or "picacg",
        comic_model = self.comic_model,
        reader = self:_getReader(),
        episodes_data = episodes_data,
        -- 登录走账号, 未登录走本地兜底 (规则统一在 util/favorites.buildAction)
        favorite_action = FavoriteActions.buildAction{
            source = self.source,
            source_id = self.source and self.source.identifier or "picacg",
            comic = comic,
        },
        on_back = function()
            self.detail_menu = nil
        end,
        on_return_from_reader = function()
            -- 读完一话回来: 详情页这次**没有被关掉** (见 api/comic.lua 的说明),
            -- 它就在窗口栈里等着 —— 直接重绘它就回到详情页, 下面的列表页原样
            -- 保留 (翻页记录、已加载的缓冲都还在)。
            --
            -- **不能**在这里 `self:show()`: 那是主页主菜单。主菜单恰好也在栈里时
            -- 只是白重绘一次; 一旦它不在 (例如详情页是从别的入口压上来的), 就会
            -- 把主菜单盖到详情页上面 —— 用户看到的就是"读完回到首页/列表"。
            if self.detail_menu and self:isMenuShown(self.detail_menu) then
                UIManager:setDirty(self.detail_menu, "ui")
            elseif self.return_callback then
                self.return_callback()
            else
                self:show()
            end
        end,
    }

    UIManager:show(self.detail_menu, "ui")
end

-- ============================================================================
-- 切换漫画源
-- ============================================================================

function Home:showSourceSwitcher()
    local SourceRegistry = require("source.registry")
    local current_id = SourceRegistry:getCurrentId()

    local item_table = {}
    -- 注意: 循环变量不要用 `_`, 否则会遮蔽 gettext 的 `_`
    for _idx, info in ipairs(SourceRegistry:list(true)) do
        local id = info.identifier
        local label = info.name
        if id == current_id then
            label = label .. "  " .. _("(当前)")
        end
        table.insert(item_table, {
            text = label,
            callback = function()
                -- **不在这里关切换源菜单**: 切源要先跑一次 source:init() (同步网络),
                -- 关掉菜单的话那几秒露出来的是下面的主菜单/文件浏览器。
                -- 由 switchSource 在新主菜单压上来之后再收 (见那里的注释)。
                self:switchSource(id)
            end,
        })
    end

    -- 「返回」项与右滑共用
    local function close_source_menu()
        UIManager:close(self.source_menu, "ui")
        self.source_menu = nil
        -- 主菜单本来就在窗口栈里 (切换菜单是压在其上的), 关掉切换菜单它自然重新可见。
        -- 这里**不能**无条件再 show 一次: UIManager:show 不去重, 会把主菜单重复压栈,
        -- 之后每次「返回」只弹掉一层长得一模一样的菜单, 用户看到的就是"点了没反应"
        -- (与 login/详情页踩过的是同一个坑)。
        if not self:isMenuShown(self.main_menu) then
            UIManager:show(self.main_menu, "ui")
        end
    end

    table.insert(item_table, {
        text = _("返回"),
        callback = close_source_menu,
    })

    local source_title_bar = MenuStyle.titleBar{ title = _("选择漫画源") }
    self.source_menu = Menu:new{
        is_picayomi_page = true, -- 退出 Picayomi 时由 util/widget_sweep 清扫
        title = source_title_bar.title,
        custom_title_bar = source_title_bar,
        item_table = item_table,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        full_width = true,
        is_popout = false,
        -- 整屏页面: 不再绘制下层 ReaderUI (否则阅读器顶部状态栏的时间会透出来)
        covers_fullscreen = true,
        is_borderless = false,
        close_callback = function()
            -- 返回键关掉这一页: 清掉引用即可 (主菜单就在下面)。
            -- 选中源时不走这里 (见 disableSelectAutoClose) —— 那时 switchSource
            -- 会自己收菜单, 提前清引用会让它变成"没人引用的孤儿窗口"。
            self.source_menu = nil
        end,
    }
    MenuStyle.disableSelectAutoClose(self.source_menu)
    -- 全屏菜单的缝隙也要吃掉落空的 tap (否则穿透到下层, 见 tap_guard 注释)
    TapGuard.install(self.source_menu)
    -- 右滑 = 返回 (与「返回」项同一个动作)
    MenuSwipe.attach(self.source_menu, close_source_menu)

    UIManager:show(self.source_menu, "ui")
end

--- 切换当前源并重建主菜单
function Home:switchSource(identifier)
    local SourceRegistry = require("source.registry")
    if not SourceRegistry:switch(identifier) then
        UIManager:show(InfoMessage:new{ text = _("切换源失败"), timeout = 3 }, "ui")
        return
    end

    self.source = SourceRegistry:getCurrent()
    if self.source then
        self.source:init()
    end
    -- 排序取值是**按源**的 (源 A dd/da/ua/ld/vd, 源 B mr/mp/tf...): 不清掉的话
    -- 新源的推荐列表会带着旧源的取值去请求, 服务端回 "validation error"。
    self.current_sort = nil

    -- 重建主菜单以反映新源的能力差异
    --
    -- 顺序: 先建新的 -> show -> 再关旧的与切换源菜单。反过来写的话, 关掉菜单那一刻
    -- 屏幕上露出的是文件浏览器 (主菜单也被关掉时) —— 就是"切源先退回上一页"。
    local old_menu = self.main_menu
    self.main_menu = nil
    self:createMainMenu()
    WidgetSweep.replace_page(old_menu, self.main_menu)
    if self.source_menu then
        UIManager:close(self.source_menu, "ui")
        self.source_menu = nil
    end

    UIManager:show(InfoMessage:new{
        text = T(_("已切换到 %1"), self.source and self.source.name or identifier),
        timeout = 2,
    }, "ui")
end

-- ============================================================================
-- 导航到其他 UI
-- ============================================================================

function Home:showCategories()
    if not SourceAccess.check(self.source, "categories") then return end
    local return_callback = function() self:show() end
    self:_getUI("categories"):show(return_callback)
end

function Home:showFavorites()
    local return_callback = function() self:show() end
    self:_getUI("favorites"):show(return_callback)
end

function Home:showHistory()
    local return_callback = function() self:show() end
    self:_getUI("history"):show(return_callback)
end

function Home:showSearch()
    if not SourceAccess.check(self.source, "search") then return end
    local return_callback = function() self:show() end
    self:_getUI("search"):show(return_callback)
end

function Home:showDownloads()
    local return_callback = function() self:show() end
    self:_getUI("downloads"):show(return_callback)
end

function Home:showAccount()
    self:_getUI("login"):show()
end

function Home:showSettings()
    self:_getUI("settings"):show()
end

function Home:showRankingPageJump(type_value, type_text, total_pages)
    UIManager:show(SpinWidget:new{
        title_text = _("跳转到页面"),
        value = 1,
        value_min = 1,
        value_max = total_pages,
        value_step = 1,
        callback = function(page)
            self:loadRanking(type_value, type_text, page)
        end,
    }, "ui")
end

return Home
