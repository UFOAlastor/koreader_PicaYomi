local UIManager = require("ui/uimanager")
local Menu = require("ui.common.action_style").Menu
local Screen = require("device").screen
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local TapGuard = require("ui.common.tap_guard")
local MenuStyle = require("ui.common.menu_style")
local MenuSwipe = require("ui.common.menu_swipe")
local logger = require("util.logger")
local _ = require("gettext")

local SettingsManager = WidgetContainer:extend{
    name = "settings_manager",
    title = _("Picayomi设置"),
}

function SettingsManager:init()
    self.menu_stack = {}
    self.current_menu = nil

    -- 初始化各个设置模块
    self.modules = {
        reading = require("ui.settings.reading"),
        swipe = require("ui.settings.swipe"),
        cache = require("ui.settings.cache"),
        sources = require("ui.settings.sources"),
        about = require("ui.settings.about"),
    }

    -- 为每个模块设置管理器引用
    for _, module in pairs(self.modules) do
        module.manager = self
    end
end

function SettingsManager:show()
    self:showMainMenu()
end

function SettingsManager:showMainMenu()
    self:closeCurrentMenu()

    local main_menu
    -- 标题栏走 MenuStyle: 去掉右上角那个与「返回」做同一件事的 ✕
    -- (理由见 ui/common/menu_style.lua)
    local title_bar = MenuStyle.titleBar{ title = self.title }
    main_menu = Menu:new{
        is_picayomi_page = true, -- 退出 Picayomi 时由 util/widget_sweep 清扫
        title = title_bar.title,
        custom_title_bar = title_bar,
        -- 整屏页面: 不绘制下层 ReaderUI (顶部状态栏的时间会透出来)
        covers_fullscreen = true,
        item_table = {
            {
                text = _("阅读设置"),
                callback = function()
                    self:navigateTo("reading")
                end,
            },
            {
                text = _("操作与手势"),
                callback = function()
                    self:navigateTo("swipe")
                end,
            },
            {
                text = _("存储管理"),
                callback = function()
                    self:navigateTo("cache")
                end,
            },
            {
                text = _("源管理") .. (function()
                    local n=require("source.extensions.manager").instance():updateCount()
                    return n>0 and (" · "..n.." 个更新") or ""
                end)(),
                callback = function() self:navigateTo("sources") end,
            },
            {
                text = _("关于"),
                callback = function()
                    self:navigateTo("about")
                end,
            },
            {
                text = _("返回"),
                callback = function()
                    self:close()
                end,
            },
        },
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        -- 整屏菜单: 同 base:createMenu, 不要用 popout
        is_popout = false,
        full_width = true,
        -- 选中条目不会再走到这里 (见下面 disableSelectAutoClose): 上游 onMenuChoice
        -- 执行完 item callback 后也会调本回调, 点"阅读设置"时子菜单刚推上去就会被
        -- 整页拆掉 —— 屏幕上看起来就是"点了没反应"。
        -- current_menu 判据: 只有主菜单仍是最上层菜单时才算真的要关闭设置。
        close_callback = function()
            if main_menu._picayomi_in_select then return end
            if self.current_menu ~= main_menu then return end
            self:close()
        end,
    }
    MenuStyle.disableSelectAutoClose(main_menu)

    self:pushMenu(main_menu)
    -- 全屏菜单项之间的缝隙也要吃掉落空的 tap, 否则会穿透到下层窗口 (见 tap_guard 注释)
    TapGuard.install(main_menu)
    -- 左右滑动: 规则与其它页面一致 (见 ui/common/menu_swipe.lua)
    MenuSwipe.attach(main_menu, function() self:goBack() end)
    UIManager:show(main_menu, "ui")
end

function SettingsManager:navigateTo(module_name)
    local module = self.modules[module_name]
    if module and module.show then
        local success, err = pcall(function()
            module:show()
        end)

        if not success then
            logger.err("Failed to show module:", module_name, err)
            UIManager:show(InfoMessage:new{
                text = _("加载设置页面失败"),
            }, "ui")
        end
    end
end

function SettingsManager:pushMenu(menu)
    if self.current_menu then
        table.insert(self.menu_stack, self.current_menu)
    end
    self.current_menu = menu
end

-- Returning to a route after removing a source/subscription replaces the
-- existing ancestor instead of adding another copy of it to the back stack.
function SettingsManager:trimToRoute(route)
    local index
    for i, menu in ipairs(self.menu_stack) do
        if menu._settings_route == route then index = i; break end
    end
    if index then
        self:closeCurrentMenu()
        for i = #self.menu_stack, index, -1 do
            UIManager:close(table.remove(self.menu_stack), "ui")
        end
    elseif self.current_menu and self.current_menu._settings_route == route then
        self:closeCurrentMenu()
    end
end

function SettingsManager:popMenu()
    if #self.menu_stack > 0 then
        local previous_menu = table.remove(self.menu_stack)
        self:closeCurrentMenu()
        self.current_menu = previous_menu
        -- 父菜单本来就在窗口栈里(只是被子菜单盖住), 关掉子菜单后它自然重新可见,
        -- 这里只需要请求一次重绘。
        -- 注意: 不能再 UIManager:show(previous_menu) —— 那会往窗口栈里塞一个
        -- 重复条目, 之后每返回一层就多一层, 越点越乱。
        if previous_menu._extensions_redraw then
            -- All back paths (button, gesture and close) refresh live source state.
            local redraw = previous_menu._extensions_redraw
            self:closeCurrentMenu()
            redraw()
        else
            previous_menu:updateItems()
            UIManager:setDirty(previous_menu, "ui")
        end
        return true
    end
    return false
end

function SettingsManager:closeCurrentMenu()
    if self.current_menu then
        -- 显式刷新模式: mode 为 nil 时 UIManager 会丢弃刷新 (屏幕不更新)
        UIManager:close(self.current_menu, "ui")
        self.current_menu = nil
    end
end

function SettingsManager:goBack()
    if not self:popMenu() then
        self:close()
    end
end

function SettingsManager:close()
    self:closeCurrentMenu()
    -- 清空菜单栈
    for _, menu in ipairs(self.menu_stack) do
        UIManager:close(menu, "ui")
    end
    self.menu_stack = {}
    UIManager:close(self, "ui")
    -- Storage/account settings can change the data shown by the already-open
    -- dashboard. Revealing that window alone would retain its old previews.
    require("ui.home").refreshShownAccountState()
    require("source.extensions.updater").schedule()
end

return SettingsManager
