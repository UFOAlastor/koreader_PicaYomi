local InfoMessage = require("ui/widget/infomessage")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local LoadingTask = require("ui.common.loading_task")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ConfirmBox = require("ui.common.action_style").ConfirmBox
local _ = require("gettext")
local T = require("ffi/util").template
local logger = require("util.logger")
local TextWidget = require("ui/widget/textwidget")
local CenterContainer = require("ui/widget/container/centercontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalGroup = require("ui/widget/verticalgroup")
local Geom = require("ui/geometry")
local Font = require("ui/font")
local VisualComicList = require("ui.common.visual_comic_list")
local ComicDetail = require("ui.common.comic_detail")
local FavoriteActions = require("util.favorites")
local LocalFavorites = require("util.local_favorites")
local WidgetSweep = require("util.widget_sweep")
local Diag = require("util.diag")

--- 墙钟 (秒)。不能用 os.clock(): 这里量的是等网络。
local function now_seconds()
    local ok, socket = pcall(require, "socket")
    if ok and type(socket) == "table" and socket.gettime then return socket.gettime() end
    return os.clock()
end

local Favorites = WidgetContainer:extend{
    name = "picayomi_favorites",
    title = _("我的收藏"),
}

function Favorites:init()
    -- 初始化API和模型
    self.comic_api = require("api.comic")
    self.comic_model = require("model.comic")

    -- 初始化其他UI模块
    self.reader = require("ui.reader")

    -- 初始化收藏数据
    self.current_page = 1
    self.total_pages = 1
end

function Favorites:show(return_callback)
    -- 保存返回回调
    self.return_callback = return_callback or function()
        -- 默认返回：关闭当前界面（会回到KOReader）
        if self.favorites_menu then
            UIManager:close(self.favorites_menu, "ui")
            self.favorites_menu = nil
        end
    end

    -- 显示收藏列表
    self:loadFavorites()
end

--- 当前源名称 (提示文案用)
function Favorites:getSourceName()
    local ok, SourceRegistry = pcall(require, "source.registry")
    if ok and SourceRegistry then
        local s = SourceRegistry:getCurrent()
        if s and s.name then return s.name end
    end
    return _("当前源")
end

--- 当前源 (每次进来都重新取: 用户可能中途换过源)
function Favorites:currentSource()
    local ok, SourceRegistry = pcall(require, "source.registry")
    if not ok or not SourceRegistry then return nil end
    local sok, s = pcall(function() return SourceRegistry:getCurrent() end)
    return sok and s or nil
end

--- 当前源标识 (本地收藏按源分桶, 必须一致)
function Favorites:currentSourceId()
    local s = self:currentSource()
    return (s and s.identifier) or "unknown"
end

--- 是否已登录 (未登录时收藏接口会返回 401)
function Favorites:isLoggedIn()
    return FavoriteActions.isLoggedIn()
end

function Favorites:promptLogin()
    local source_name = self:getSourceName()
    UIManager:show(ConfirmBox:new{
        text = T(_("请先登录%1，才能查看收藏"), source_name),
        ok_text = _("去登录"),
        cancel_text = _("取消"),
        ok_callback = function()
            local home = require("ui.home")
            -- 借道首页的登录入口，保证与主菜单走同一条逻辑
            local ok, h = pcall(function() return home:new{} end)
            if ok and h then
                h:_getUI("login"):show()
            end
        end,
    }, "ui")
end

-- Shelves often return only the stable book ID and title. Resolve visible
-- rows lazily through the same cancellable queue used by reading history.
function Favorites:resolveCover(comic,source)
    source=source or self:currentSource()
    if not source or not source.getComicDetail or not require("ui.common.source_access").check(source,nil,true) then return nil,"failed" end
    local ok,detail=source:getComicDetail(comic._id)
    if not ok or type(detail)~="table" then return nil,"failed" end
    local thumb=detail.thumb or detail.cover
    if type(thumb)~="string" or thumb=="" then return nil,"missing" end
    return thumb
end

--- 收藏入口: 登录了看账号收藏, 没登录看本地收藏
--
-- 用户确认过的规则: "未登录用本地, 登录用账号"。
-- 以前未登录直接弹"请先登录", 于是没账号的人根本用不了收藏。
function Favorites:loadFavorites()
    local source = self:currentSource()
    if FavoriteActions.backend(source) == "local" then
        self:loadLocalFavorites(source)
    else
        self:loadRemoteFavorites()
    end
end

--- 本地收藏 (未登录 / 源没有网络收藏能力时的兜底)
function Favorites:loadLocalFavorites(source)
    local source_id = self:currentSourceId()
    local raw = LocalFavorites.list(source_id)
    if logger.enabled then logger.info(string.format("Picayomi 本地收藏 %s: %d 条", source_id, #raw)) end

    if #raw == 0 then
        self:showEmptyLocalFavorites(source)
        return
    end

    local comics = {}
    for _i, item in ipairs(raw) do
        comics[#comics + 1] = self.comic_model:processComicData(item)
    end

    -- 本地收藏没有服务端分页: 单页给全, 由列表自己决定怎么分屏
    local function local_page(page)
        local want = tonumber(page) or 1
        local items = (want == 1) and raw or {}
        return true, { comics = items, page = want, pages = 1, total = #raw }
    end

    local old_list = self.favorites_menu

    self.favorites_menu = VisualComicList:new{
        title = _("我的收藏 (本地)"),
        comics = comics,
        resolve_cover = function(comic) return self:resolveCover(comic,source) end,
        source = source,
        source_id = source_id,
        server_page = 1,
        total_pages = 1,
        total_count = #raw,
        fetch_page = local_page,
        processor = function(item) return self.comic_model:processComicData(item) end,
        on_select = function(comic, navigation)
            if logger.enabled then logger.info("Picayomi", "选择了本地收藏: " .. tostring(comic.title)) end
            self:showComicDetail(comic, navigation)
        end,
        on_back = function(list)
            if list then UIManager:close(list, "ui") end
            self.favorites_menu = nil
            if not self.navigating_to_detail and self.return_callback then
                self.return_callback()
            end
        end,
    }

    WidgetSweep.replace_page(old_list, self.favorites_menu)
end

--- 本地收藏为空时的提示
-- 源支持网络收藏时顺手给一个"去登录"的入口 —— 否则用户不知道登录后能同步账号收藏
function Favorites:showEmptyLocalFavorites(source)
    local can_login = source and source.hasCapability and source:hasCapability("favorites")
    if not can_login then
        UIManager:show(InfoMessage:new{
            text = source and source.content_type=="novel" and _("你还没有收藏小说") or _("你还没有收藏漫画"),
        }, "ui")
        return
    end
    UIManager:show(ConfirmBox:new{
        text = _("还没有本地收藏。\n\n登录账号后，收藏会保存到账号里（本地收藏不会自动同步）。"),
        ok_text = _("去登录"),
        cancel_text = _("知道了"),
        ok_callback = function() self:promptLogin() end,
    }, "ui")
end

--- 账号收藏 (已登录)
function Favorites:loadRemoteFavorites()
    local source = self:currentSource()
    if not require("ui.common.source_access").check(require("source.registry"):getCurrent(),"favorites") then return end
    -- 显示加载消息
    if logger.enabled then logger.info("Picayomi", "开始加载收藏漫画...") end
    local loading = InfoMessage:new{
        text = source and source.content_type=="novel" and _("加载收藏小说...") or _("加载收藏漫画..."),
    }
    UIManager:show(loading, "ui")
    -- 同步刷一次: show 只是把刷新入队, 而这里马上要阻塞做网络请求,
    -- 不等这一下的话事件循环没机会重绘, 提示等于没显示
    UIManager:forceRePaint()

    -- 获取收藏列表
    -- 抛异常时也关掉提示, 否则"加载收藏漫画..."永久盖屏 (见 loading_task 注释)
    local t0 = Diag.enabled and now_seconds() or 0
    local success, favorites_data, error_msg = LoadingTask.call(loading, function()
        return self.comic_api:getFavorites(self.current_page)
    end)
    -- 这一段是**主线程同步**等网络 (整页在此期间不响应输入), 所以它多长,
    -- 用户感受到的"加载收藏慢"就有多长。记下来才能分清是源慢还是我们慢。
    if Diag.enabled then Diag.mark(string.format("favorites 取列表 %.1fs (第 %d 页)",
        now_seconds() - t0, self.current_page or 1)) end

    if success and favorites_data then
        if logger.enabled then logger.info("Picayomi", "成功获取收藏漫画数据，数量: " .. #(favorites_data.comics or {})) end

        -- 更新分页信息
        self.current_page = favorites_data.page or self.current_page
        self.total_pages = favorites_data.pages

        -- 显示收藏列表
        self:showFavoritesList(favorites_data)
    else
        logger.warn("Picayomi", "获取收藏漫画失败: " .. (error_msg or "未知错误"))
        -- 会话过期也会以 401 出现, 同样引导去登录
        if tostring(error_msg or ""):find("401", 1, true) then
            self:promptLogin()
        else
            UIManager:show(InfoMessage:new{
                text = T(source and source.content_type=="novel" and _("获取收藏小说失败: %1") or _("获取收藏漫画失败: %1"), require("ui.common.error_message").describe(error_msg)),
            }, "ui")
        end
    end
end

function Favorites:showFavoritesList(favorites_data)
    local source = self:currentSource()
    if not favorites_data.comics or #favorites_data.comics == 0 then
        UIManager:show(InfoMessage:new{
            text = source and source.content_type=="novel" and _("你还没有收藏小说") or _("你还没有收藏漫画"),
        }, "ui")
        return
    end

    local comics = {}
    for idx, comic in ipairs(favorites_data.comics) do
        local processed_comic = self.comic_model:processComicData(comic)
        if logger.enabled then logger.info("Picayomi", "处理收藏漫画 #" .. idx .. ": " .. processed_comic.title) end
        table.insert(comics, processed_comic)
    end

    local old_list = self.favorites_menu

    self.favorites_menu = VisualComicList:new{
        title = _("我的收藏"),
        comics = comics,
        resolve_cover = function(comic) return self:resolveCover(comic,source) end,
        source = source,
        source_id = source and source.identifier,
        -- 单层分页: 翻到缓冲区末尾时由列表自己按需补货
        server_page = self.current_page,
        total_pages = self.total_pages, server_page_size = favorites_data.page_size,
        has_more = favorites_data.has_more,
        -- 首次进入就要有总条数, 否则界面算不出总屏数 (见 ui/home.lua 同处的说明)
        total_count = favorites_data.total,
        fetch_page = function(page) return self.comic_api:getFavorites(page) end,
        processor = function(raw) return self.comic_model:processComicData(raw) end,
        on_select = function(comic, navigation)
            if logger.enabled then logger.info("Picayomi", "选择了收藏漫画: " .. comic.title) end
            self:showComicDetail(comic, navigation)
        end,
        on_back = function(list)
            if list then UIManager:close(list, "ui") end
            self.favorites_menu = nil
            if not self.navigating_to_detail and self.return_callback then
                self.return_callback()
            end
        end,
    }

    if logger.enabled then logger.info("Picayomi", "显示收藏漫画列表，项目数量: " .. #comics) end
    WidgetSweep.replace_page(old_list, self.favorites_menu)
end

function Favorites:showComicDetail(comic, navigation)
    -- 收藏页里的条目按定义就是"已收藏"。
    -- 明确写进对象: 阅读时它会作为 session.context.comic 传下去, 返回详情页
    -- (main.lua 的 returnToPicayomi) 会用同一个对象按 isFavourite 推导按钮文案;
    -- 不写的话读一圈回来按钮就变回"收藏"了。
    if type(comic) == "table" then comic.isFavourite = true end
    if logger.enabled then logger.info("Picayomi", "显示漫画详情: " .. comic.title) end
    self.navigating_to_detail = true

    -- **不销毁列表** —— 详情页盖在列表上, 返回时原样露出来, 页码与已加载的缓冲都在。
    -- 以前这里 close + 置 nil, 返回时只能重新 loadFavorites(): 一次网络请求 + 一个
    -- 全新的 VisualComicList (screen_index = 1) —— 用户报的"进详情再返回, 列表又从
    -- 第一页开始"。与 ui/home.lua / ui/history.lua 的做法一致。
    local source = navigation and navigation.source or self:currentSource()
    self.detail_menu = ComicDetail:new{
        navigation = navigation,
        comic = comic,
        source = source,
        source_id = source and source.identifier or "picacg",
        comic_model = self.comic_model,
        reader = self.reader,
        -- 收藏页里只有"取消收藏"这一种动作, 文案固定 (否则会跟着状态翻成"收藏")。
        -- 后端仍是统一规则: 登录走账号, 未登录走本地。
        favorite_action = FavoriteActions.buildAction{
            source = source,
            source_id = source and source.identifier or "picacg",
            comic_api = self.comic_api,
            comic = comic,
            pinned_label = _("取消收藏"),
            confirm_text = T(_("确定要取消收藏《%1》吗？"), comic.title),
            after_success = function(view)
                -- 取消收藏**改动了列表内容** —— 这本已经不该在收藏页里了, 所以这一条
                -- 路径必须重拉列表; 普通返回则只把列表露出来 (保住翻页进度)。
                -- 用 favorites_dirty 区分这两种返回, 见 on_back。
                self.favorites_dirty = true
                -- 必须用 goBack() 而不是 UIManager:close(view):
                --   close() 会先向子控件派发 CloseWidget(把它们 free 掉, TextBoxWidget._bb
                --   变 nil), 紧接着本页 onCloseWidget -> on_back -> loadFavorites ->
                --   forceRePaint, 于是重绘一个已被 free 的页面直接崩溃。
                --   goBack() 先关页、关完再回调, 重绘时本页已不在栈里, 安全。
                view:goBack()
            end,
        },
        on_back = function()
            self.navigating_to_detail = false
            self.detail_menu = nil
            if self.favorites_dirty then
                self.favorites_dirty = false
                self:loadFavorites()
            elseif not WidgetSweep.isInStack(self.favorites_menu) then
                -- 列表真的不在 (理论上不该发生) 才重建, 免得用户对着空屏
                self:loadFavorites()
            end
            -- 其余情况什么都不做: 关掉详情页, 下面的收藏列表自己就露出来了
        end,
        on_return_from_reader = function()
            -- 读完一话回来: 详情页**没有被关掉** (api/comic.lua 现在故意留着它,
            -- 它就是返回目标), 收藏列表还在它下面 —— 什么都不用做。
            -- 保留 self.detail_menu 引用 (页面还活着, 置 nil 是自欺)。
            self.navigating_to_detail = false
            if not WidgetSweep.isInStack(self.favorites_menu)
               and not WidgetSweep.isInStack(self.detail_menu) then
                self:show(self.return_callback)
            end
        end,
    }

    UIManager:show(self.detail_menu, "ui")
end


return Favorites
