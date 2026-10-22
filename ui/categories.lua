local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local LoadingTask = require("ui.common.loading_task")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ButtonDialog = require("ui/widget/buttondialog")
local _ = require("gettext")
local T = require("ffi/util").template
local FavoriteActions = require("util.favorites")
local logger = require("util.logger")
local VisualComicList = require("ui.common.visual_comic_list")
local ComicDetail = require("ui.common.comic_detail")
local CategoryCloud = require("ui.common.category_cloud")
local WidgetSweep = require("util.widget_sweep")

local Categories = WidgetContainer:extend{
    name = "picayomi_categories",
    title = _("分类"),
}

function Categories:init()
    -- 初始化API和模型
    self.comic_api = require("api.comic")
    self.comic_model = require("model.comic")

    -- 初始化其他UI模块
    self.reader = require("ui.reader")

    -- 初始化分类数据
    self.categories = nil
    self.current_category = nil
    self.current_page = 1
    self.total_pages = 1
    -- 排序取值由源声明 (source:getSortOptions("category")), 首次进入时取第一个;
    -- 不要写死 "ua" —— 那是源 A 的取值, 源 B 用 mr/mv/mp/tf, 写死会导致换排序无效
    self.current_sort = nil
end

function Categories:show(return_callback)
    -- 保存返回回调
    self.return_callback = return_callback or function()
        -- 默认返回：关闭当前界面（会回到KOReader）
        if self.category_menu then
            UIManager:close(self.category_menu, "ui")
            self.category_menu = nil
        end
    end

    -- 显示分类列表
    self:loadCategories()
end

function Categories:loadCategories()
    if not require("ui.common.source_access").check(require("source.registry"):getCurrent(),"categories") then return end
    -- 显示加载消息
    local loading = InfoMessage:new{
        text = _("加载分类列表..."),
    }
    UIManager:show(loading, "ui")
    -- 同步刷一次: show 只是把刷新入队, 而这里马上要阻塞做网络请求,
    -- 不等这一下的话事件循环没机会重绘, 提示等于没显示
    UIManager:forceRePaint()

    -- 获取分类列表
    -- 抛异常时也关掉提示, 否则"加载分类列表..."永久盖屏 (见 loading_task 注释)
    local success, categories, error_msg = LoadingTask.call(loading, function()
        return self.comic_api:getCategories()
    end)

    if success and categories then
        -- 保存分类数据
        self.categories = categories

        -- 显示分类列表
        self:showCategoryList()
    else
        -- 显示错误消息
        UIManager:show(InfoMessage:new{
            text = T(_("获取分类失败: %1"), error_msg or _("未知错误")),
        }, "ui")
    end
end

--- 控件当前是否还在窗口栈里
local function in_stack(widget)
    if not widget then return false end
    local stack = UIManager._window_stack
    for _i, e in ipairs(stack or {}) do
        if e.widget == widget then return true end
    end
    return false
end

function Categories:showCategoryList()
    -- 分类菜单还在栈里就只重绘: 重建会把它再压一层, 之后每次「返回」只弹掉
    -- 一层长得一模一样的菜单 (与主页/来源切换菜单踩过的是同一个坑)。
    if self.category_menu and in_stack(self.category_menu) then
        UIManager:setDirty(self.category_menu, "ui")
        return
    end

    if not self.categories or #self.categories == 0 then
        -- 显示无分类消息
        UIManager:show(InfoMessage:new{
            text = _("没有可用的分类"),
        }, "ui")
        return
    end

    if logger.enabled then logger.info("ComicAPI", "创建分类界面，分类数量: " .. #self.categories) end

    -- 筛选漫画分类（过滤掉网页分类）
    local comic_categories = {}
    for _idx, category in ipairs(self.categories) do
        -- 只保留漫画分类，过滤掉网页分类
        if not category.isWeb then
            table.insert(comic_categories, category)
        elseif category._id then
            -- 有_id的都是传统漫画分类，也要包含
            table.insert(comic_categories, category)
        end
    end

    if logger.enabled then logger.info("ComicAPI", "筛选后的漫画分类数量: " .. #comic_categories) end

    if #comic_categories == 0 then
        UIManager:show(InfoMessage:new{text=_("没有可用的分类")}, "ui")
        return
    end
    local page
    page = CategoryCloud:new{
        categories = comic_categories,
        on_select = function(category) self:onCategorySelected(category) end,
        on_hold = function(category) self:onCategoryHold(category) end,
        on_back = function() if self.return_callback then self.return_callback() end end,
        close_callback = function()
            if self.category_menu == page then self.category_menu = nil end
        end,
    }
    self.category_menu = page
    UIManager:show(page, "ui")
end

-- 处理分类选择
function Categories:onCategorySelected(category)
    if logger.enabled then logger.info("ComicAPI", "选择分类: " .. category.title) end

    -- 如果是网页分类，显示链接信息（虽然已经过滤了，但保险起见）
    if category.isWeb then
        UIManager:show(InfoMessage:new{
            text = T(_("【%1】是外部链接，Kindle设备无法打开"), category.title),
            timeout = 3,
        }, "ui")
        return
    end

    -- **不要关分类菜单**: 它是这一层的"来路", 关掉再取数的那几秒里, 屏幕上
    -- 露出来的是它下面的主页 —— 用户看到的就是"点了分类先退回主页, 再弹列表"。
    -- 列表直接盖在分类菜单上; 返回时关掉列表, 分类菜单原样露出来 (页码/滚动都在)。
    self:loadCategoryComics(category, 1)
end

-- 处理分类长按
function Categories:onCategoryHold(category)
    local ButtonDialog = require("ui/widget/buttondialog")

    local buttons = {
        {
            {
                text = _("进入分类"),
                callback = function()
                    self:onCategorySelected(category)
                end,
            },
        },
    }

    if category.isWeb and category.link then
        table.insert(buttons[1], {
            text = _("复制链接"),
            callback = function()
                -- 这里可以添加复制链接到剪贴板的功能
                UIManager:show(InfoMessage:new{
                    text = _("链接: ") .. category.link,
                    timeout = 3,
                }, "ui")
            end,
        })
    end

    table.insert(buttons, {
        {
            text = _("取消"),
            callback = function()
                -- 什么都不做，只是关闭对话框
            end,
        },
    })

    self.button_dialog = ButtonDialog:new{
        title = category.title,
        buttons = buttons,
    }
    UIManager:show(self.button_dialog, "ui")
end

function Categories:loadCategoryComics(category, page, sort)
    if not require("ui.common.source_access").check(require("source.registry"):getCurrent(),"categories") then return end
    -- 设置当前分类和页面
    self.current_category = category
    page = page or 1
    if sort then self.current_sort = sort end
    -- 排序取值跟着**当前源**走: 换源后旧取值 (如源 A 的 ua) 对新源无意义,
    -- 传下去会让接口拿到不认识的排序 (甚至报错)。不在当前源的选项里就重取第一个。
    local sort_opts = self:_sortOptions()
    local sort_valid = false
    for _i, o in ipairs(sort_opts) do
        if o.value == self.current_sort then sort_valid = true break end
    end
    if not sort_valid then
        self.current_sort = sort_opts[1] and sort_opts[1].value or nil
    end

    if logger.enabled then logger.info("ComicAPI", "加载分类漫画: " .. category.title .. "，页面: " .. page) end

    -- **不要在这里关旧列表。**
    --
    -- 这里是"换排序 / 换分类后重新取数"的入口, 而取数是同步的 1~2 秒。
    -- 先关列表的话, 那两秒屏幕上露出的是**分类菜单** (上一页), 取完才刷出新列表 ——
    -- 用户报的"点排序先退回上一页"就是这个。旧列表留到新列表压上来之后再收
    -- (见 showComicList 里的 replace_page)。
    --
    -- 显示加载提示 + 取数。
    --
    -- **必须走 LoadingTask.run**: 它负责"show → forceRePaint → 取数 → 关提示"这一串。
    -- 旧代码是裸 InfoMessage + timeout=1, **漏了 forceRePaint** —— show 只把刷新入队,
    -- 紧接着就阻塞做网络请求, 事件循环没机会重绘, 提示等于没显示
    -- (探针实测事件序列 show → 取数 → show; 对照 loadCategories 是
    --  show → forceRePaint → 取数 → show)。那句 timeout=1 只是让看不见的提示自己
    -- 消失而已, 并不解决"看不见"。
    LoadingTask.run{
        message = T(_("正在加载【%1】分类第%2页..."), category.title, page),
        fetch = function()
            if category._id then
                -- 普通分类: 用分类 id
                return self.comic_api:getComicsByCategory(
                    category._id, page, self.current_sort)
            end
            -- 没有 _id 的条目是"特殊分类" (源 A 的「大家都在看」等), 退化成按标题搜索
            return self.comic_api:getComicsBySpecialCategory(
                category.title, page, self.current_sort)
        end,
        on_done = function(success, comics_data, error_msg)
            if success and comics_data then
                if logger.enabled then logger.info("ComicAPI", "成功获取分类漫画，数量: "
                    .. #(comics_data.comics or {})) end
                self:showComicList(comics_data)
            else
                logger.err("ComicAPI", "获取分类漫画失败: " .. (error_msg or "未知错误"))
                UIManager:show(InfoMessage:new{
                    text = T(_("获取【%1】分类漫画失败: %2"), category.title,
                        error_msg or _("网络错误")),
                    timeout = 3,
                }, "ui")
            end
        end,
    }
end

--- 当前源在"分类列表"下可用的排序方式 (空表 = 不支持排序)
function Categories:_sortOptions()
    if self.comic_api and self.comic_api.getSortOptions then
        return self.comic_api:getSortOptions("category") or {}
    end
    return {}
end

function Categories:showComicList(comics_data)
    if not comics_data.comics or #comics_data.comics == 0 then
        UIManager:show(InfoMessage:new{
            text = T(_("【%1】分类下没有漫画"), self.current_category.title),
        }, "ui")
        return
    end

    local current_page = comics_data.page or 1
    local total_pages = comics_data.pages or 1
    local comics = {}
    for idx, comic in ipairs(comics_data.comics) do
        local processed_comic = self.comic_model:processComicData(comic)
        if logger.enabled then logger.info("ComicAPI", "处理分类漫画 #" .. idx .. ": " .. processed_comic.title) end
        table.insert(comics, processed_comic)
    end

    local function fetch(page)
        local cat = self.current_category
        local sort = self.current_sort
        if cat._id then
            return self.comic_api:getComicsByCategory(cat._id, page, sort)
        end
        return self.comic_api:getComicsBySpecialCategory(cat.title, page, sort)
    end

    local old_list = self.comic_list_menu

    self.comic_list_menu = VisualComicList:new{
        title = T(_("【%1】分类漫画"), self.current_category.title),
        comics = comics,
        -- 单层分页: 翻到缓冲区末尾时由列表自己按需补货
        server_page = current_page,
        total_pages = comics_data.pages,
        has_more = comics_data.has_more,
        -- 首次进入就要有总条数, 否则界面算不出总屏数 (见 ui/home.lua 同处的说明)
        total_count = comics_data.total,
        fetch_page = fetch,
        -- 排序按钮: 只有源声明了可用排序时才出现
        sort_options = self:_sortOptions(),
        sort = self.current_sort,
        on_sort_change = function(value)
            -- 换排序要按新排序重新拉第一页 (loadCategoryComics 会先关掉旧列表)
            self:loadCategoryComics(self.current_category, 1, value)
        end,
        processor = function(raw) return self.comic_model:processComicData(raw) end,
        on_select = function(comic)
            if logger.enabled then logger.info("ComicAPI", "选择了漫画: " .. comic.title) end
            self:showComicDetail(comic)
        end,
        on_back = function(list)
            if logger.enabled then logger.info("ComicAPI", "返回分类列表") end
            if list then UIManager:close(list, "ui") end
            self.comic_list_menu = nil
            -- 分类菜单还在栈里就直接露出来 (不重建, 不重复压栈)
            if self.category_menu and in_stack(self.category_menu) then
                UIManager:setDirty(self.category_menu, "ui")
            else
                self:showCategoryList()
            end
        end,
    }

    if logger.enabled then logger.info("ComicAPI", "显示分类漫画列表，项目数量: " .. #comics .. "，当前页: " .. current_page .. "/" .. total_pages) end
    -- 先 show 新的, 再关旧的: 中间不留"旧列表已关、新列表还没出来"的空档
    WidgetSweep.replace_page(old_list, self.comic_list_menu)
end

function Categories:showComicDetail(comic)
    if logger.enabled then logger.info("Picayomi", "显示漫画详情: " .. comic.title) end
    self.navigating_to_detail = true

    -- **不销毁列表** —— 详情页是**盖**在列表上的, 返回时列表原样露出来, 页码与
    -- 已加载的那几页缓冲都还在。
    --
    -- 以前这里 `UIManager:close(list) + list = nil`, 而返回时只能重新
    -- `loadCategoryComics(...)`: 一次新的网络请求 + 一个全新的 VisualComicList
    -- (`screen_index = 1`), 于是用户报的"进详情再返回, 列表又从第一页开始"。
    -- 详情页 `covers_fullscreen = true`, 所以盖着的时候下层列表不会被画出来。
    -- 与 ui/home.lua / ui/history.lua 的做法一致 (那两页本来就是对的)。
    local source = require("source.registry"):getCurrent()
    self.detail_menu = ComicDetail:new{
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
            -- 列表还在窗口栈里就什么都不用做 —— 关掉详情页它自己就露出来了。
            -- 只有列表真的不在了 (理论上不该发生) 才退回重建, 免得用户对着空屏。
            if not WidgetSweep.isInStack(self.comic_list_menu) then
                if self.current_category then
                    self:loadCategoryComics(self.current_category, self.current_page or 1)
                else
                    self:showCategoryList()
                end
            end
        end,
        on_return_from_reader = function()
            -- 读完一话回来: 详情页**没有被关掉** (api/comic.lua 现在故意留着它,
            -- 它就是返回目标), 列表还在它下面 —— 什么都不用做。
            -- 保留 self.detail_menu 引用 (页面还活着, 置 nil 是自欺)。
            self.navigating_to_detail = false
            if not WidgetSweep.isInStack(self.comic_list_menu)
               and not WidgetSweep.isInStack(self.detail_menu) then
                if self.current_category then
                    self:loadCategoryComics(self.current_category, self.current_page or 1)
                else
                    self:show(self.return_callback)
                end
            end
        end,
    }

    UIManager:show(self.detail_menu, "ui")
end


return Categories
