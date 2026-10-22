-- ui/common/menu_style.lua
-- 插件全屏菜单的统一外观
--
-- 解决的问题: KOReader 的 Menu 会**自动**在标题栏右上角画一个 ✕, 而且没有开关能
-- 关掉它。插件的每个页面都自带「返回」项, ✕ 做的是同一件事 (回到 KOReader) ——
-- 两个入口并存只会让用户以为它们是两个不同的动作。
--
-- 为什么要自己造标题栏: Menu:init 把关闭回调写死在给 TitleBar 的参数里
-- (`close_callback = function() self:onClose() end`), 而 TitleBar:init 一看到
-- close_callback 就 `self.right_icon = "close"` 并把回调挂到图标上
-- (frontend/ui/widget/titlebar.lua:87-90)。Menu 只在给了 custom_title_bar 时才走别的
-- 分支 (`self.custom_title_bar or TitleBar:new{...}`), 所以这是唯一干净的入口。
--
-- 顺带修一处上游越界: Menu 把**外框宽**给了标题栏 (`width = self.dimen.w`), 而内容
-- 画在 bordersize 之内, 于是标题栏及其右侧图标比屏幕宽出 Size.border.window
-- (见 docs 里"控件布局陷阱")。这里按内容宽给。

local Screen = require("device").screen
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local Menu = require("ui/widget/menu")

local M = {}

--- 造一个"只有标题、没有右上角 ✕"的标题栏 (给 Menu 的 custom_title_bar 用)
--
-- 用法:
--     local tb = MenuStyle.titleBar{ title = _("Picayomi") }
--     Menu:new{ custom_title_bar = tb, title = tb.title, ... }
-- 把 `title = tb.title` 一起传上, 是为了别把同一个文案写两遍 —— Menu 自己也用
-- self.title (switchItemTable 会把它写进 item_table.title)。
--
-- @param opts.title       标题文案
-- @param opts.width       标题栏宽度; 不传 = 整屏宽 - 两侧外框
-- @param opts.show_parent 用于刷新的宿主控件 (一般是那个 Menu; 建表时还没有则留空)
-- @return TitleBar
function M.titleBar(opts)
    opts = opts or {}
    return TitleBar:new{
        width = opts.width or (Screen:getWidth() - 2 * Size.border.window),
        fullscreen = true,
        align = "center",
        title = opts.title or "",
        with_bottom_line = opts.with_bottom_line,
        show_parent = opts.show_parent,
    }
end

--- 让 close_callback 只在"这一页真的被关掉"时触发 (返回键 / ✕ / 右滑), 而不是每次选中条目后
--
-- 上游 Menu:onMenuSelect (frontend/ui/widget/menu.lua:1383-1404) 在条目 callback
-- 之后**无条件**再调一次 close_callback。插件把 close_callback 当"返回上一页"用,
-- 于是每点一项都会顺手把当前页退掉, 真机表现就是"点完按钮回到了上一页":
--   * 主页点「排行榜」-> 类型菜单刚弹出来就被收掉, 屏幕先闪回主页;
--   * 设置页点「最大缓存容量」-> 数值控件和"返回上一页"同时发生;
--   * 下载选择页点一个章节 -> 整页消失 (看起来像"点了没反应")。
--
-- 这里把"选中条目"这一段包起来: 期间的 close_callback 一律忽略。返回键仍走
-- Menu:onClose -> Menu:onCloseAllMenus -> close_callback (menu.lua:1492-1508),
-- 语义不变。所有带 close_callback 的 Menu 都必须在构造之后调一次本函数
-- (静态检查 check_menu_close_guard 会盯着)。
--
-- @param menu Menu 实例 (构造完成、close_callback 已就位)
function M.disableSelectAutoClose(menu)
    if not menu then return end
    local real_close = menu.close_callback
    menu.close_callback = function()
        -- 选中条目期间不关页; 其余路径 (返回键/✕/onClose) 照旧
        if menu._picayomi_in_select then return end
        if real_close then real_close() end
    end
    menu.onMenuSelect = function(self, item)
        self._picayomi_in_select = true
        -- pcall 只为保证标志位一定被清掉: 留着的话返回键会再也关不掉这一页
        local ok, err = pcall(Menu.onMenuSelect, self, item)
        self._picayomi_in_select = nil
        if not ok then error(err, 0) end
        return true
    end
end

return M
