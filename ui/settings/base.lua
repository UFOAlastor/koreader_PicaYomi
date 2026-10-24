local UIManager = require("ui/uimanager")
local Menu = require("ui.common.action_style").Menu
local Screen = require("device").screen
local InfoMessage = require("ui/widget/infomessage")
local SpinWidget = require("ui.common.action_style").SpinWidget
local ToggleSwitch = require("ui/widget/toggleswitch")
local MultiInputDialog = require("ui.common.action_style").MultiInputDialog
local ConfirmBox = require("ui.common.action_style").ConfirmBox
local ButtonDialog = require("ui.common.action_style").ButtonDialog
local TapGuard = require("ui.common.tap_guard")
local MenuStyle = require("ui.common.menu_style")
local MenuSwipe = require("ui.common.menu_swipe")
local logger = require("util.logger")
local _ = require("gettext")
local T = require("ffi/util").template

local BaseSettingsModule = {}

function BaseSettingsModule:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self

    -- 初始化配置模块
    o.config = require("util.config")

    -- 初始化配置默认值模块
    o.config_defaults = require("util.config_defaults")

    -- 确保默认值被应用
    o.config_defaults:applyDefaults(o.config)

    return o
end

function BaseSettingsModule:createMenu(title, items)
    local menu
    -- 标题栏走 MenuStyle: 去掉右上角那个与「返回」做同一件事的 ✕
    -- (理由见 ui/common/menu_style.lua)
    local title_bar = MenuStyle.titleBar{ title = title }
    menu = Menu:new{
        is_picayomi_page = true, -- 退出 Picayomi 时由 util/widget_sweep 清扫
        title = title_bar.title,
        custom_title_bar = title_bar,
        -- 标记归属模块: refresh() 据此判断"当前这层是不是本模块自己的页面"
        _settings_module = self,
        item_table = items,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        -- 这是整屏菜单, 不是浮动小菜单
        is_popout = false,
        full_width = true,
        -- 整屏页面: 不绘制下层 ReaderUI (阅读器顶部状态栏的时间会透出来)
        covers_fullscreen = true,
        -- 选中条目不会再走到这里 (见下面 disableSelectAutoClose): 上游
        -- Menu:onMenuChoice 执行完 item callback 之后还会调一次本回调
        -- (menu.lua:1393-1396), 不拦的话
        --   * 回调推了新菜单 -> 刚打开的页面立刻被关掉 ("点了没反应");
        --   * 回调弹了数值控件/确认框 -> 顺手把设置页弹回上一级
        --     (真机 2026-10-18: 点「最大缓存容量」, 控件和"返回上一页"同时发生)。
        -- 走到这里就只剩返回键/✕; current_menu 判据防重入 (回调链里可能已退过一层)。
        close_callback = function()
            if not self.manager then return end
            if self.manager.current_menu ~= menu then return end
            self.manager:goBack()
        end,
    }
    MenuStyle.disableSelectAutoClose(menu)
    -- 全屏菜单项之间的缝隙也要吃掉落空的 tap, 否则会穿透到下层窗口 (见 tap_guard 注释)
    TapGuard.install(menu)
    -- 左右滑动: 左滑下一页 / 右滑上一页, 已在第一页时右滑 = 返回
    -- (规则与列表页、详情页、主页一致; 见 ui/common/menu_swipe.lua)
    MenuSwipe.attach(menu, function()
        self:goBack()
    end)
    return menu
end

function BaseSettingsModule:showMenu(menu)
    if self.manager then
        self.manager:pushMenu(menu)
    end
    UIManager:show(menu, "ui")
end

--- 原地刷新本模块当前页 (操作后更新显示, 如清完缓存更新大小)
--
-- 不能直接用 show(): 那会 createMenu 出一个新菜单并 show, 而旧的那层既没关掉
-- 也没从菜单栈里去掉 —— 于是窗口栈里叠了两层一模一样的页面, 用户按「返回」
-- 要多按一次才退得出去 (看起来像"点了没反应")。
function BaseSettingsModule:refresh()
    if self.manager and self.manager.current_menu
            and self.manager.current_menu._settings_module == self then
        self.manager:closeCurrentMenu()
    end
    self:show()
end

function BaseSettingsModule:goBack()
    if self.manager then
        self.manager:goBack()
    end
end

function BaseSettingsModule:showInfo(text)
    UIManager:show(InfoMessage:new{
        text = text,
    }, "ui")
end

function BaseSettingsModule:showError(text)
    logger.err("Settings error:", text)
    UIManager:show(InfoMessage:new{
        text = _("错误：") .. require("ui.common.error_message").describe(text),
    }, "ui")
end

function BaseSettingsModule:createSpinWidget(config)
    return SpinWidget:new{
        title_text = config.title,
        value = config.value,
        value_min = config.min,
        value_max = config.max,
        value_step = config.step or 1,
        unit = config.unit,
        -- SpinWidget 把**控件自身**传给 callback (spinwidget.lua:229 `self.callback(self)`),
        -- 于是回调里拿到的是控件而不是数值 —— 直接拿去写配置会被 validate 判为
        -- "配置值无效" (max_cache_size 就这么一直是坏的)。这里统一成"回调拿到数值",
        -- 免得每个调用方各自记得去取 .value。
        callback = config.callback and function(widget)
            config.callback(widget.value)
            local menu=self.manager and self.manager.current_menu
            if menu and menu._settings_module==self then menu:updateItems() end
        end,
    }
end

function BaseSettingsModule:createMultiInputDialog(config)
    return MultiInputDialog:new{
        title = config.title,
        fields = config.fields,
        buttons = config.buttons,
    }
end

function BaseSettingsModule:createConfirmBox(config)
    return ConfirmBox:new{
        text = config.text,
        ok_text = config.ok_text or _("确定"),
        cancel_text = config.cancel_text or _("取消"),
        ok_callback = config.ok_callback,
        cancel_callback = config.cancel_callback,
    }
end

function BaseSettingsModule:createButtonDialog(config)
    return ButtonDialog:new{
        title = config.title,
        text = config.text,
        buttons = config.buttons,
    }
end

function BaseSettingsModule:safeConfigSet(key, value, success_message)
    -- 验证配置值
    if not self.config_defaults:validate(key, value) then
        self:showError(_("配置值无效：") .. tostring(value))
        return false
    end

    local success, err = pcall(function()
        return self.config:set(key, value)
    end)

    if success and err ~= false then
        if success_message then
            self:showInfo(success_message)
        end
        if logger.enabled then logger.info("Config updated:", key) end
        return true
    else
        self:showError(success and _("保存设置失败，请检查存储空间和目录写入权限。")
            or (_("保存设置失败：") .. tostring(err)))
        return false
    end
end

function BaseSettingsModule:safeConfigGet(key, fallback_default)
    local success, result = pcall(function()
        return self.config:get(key)
    end)

    if success and result ~= nil then
        -- 验证现有值
        if self.config_defaults:validate(key, result) then
            return result
        else
            logger.warn("Invalid config value, using default:", key, result)
        end
    end

    -- 使用配置默认值或提供的fallback值
    local default_value = self.config_defaults:getDefault(key)
    if default_value ~= nil then
        return default_value
    else
        return fallback_default
    end
end

function BaseSettingsModule:createBackButton()
    return {
        text = _("返回"),
        callback = function()
            self:goBack()
        end,
    }
end

function BaseSettingsModule:createToggleItem(text, config_key, on_message, off_message)
    return {
        text = text,
        callback = function()
            local current_value = self:safeConfigGet(config_key)
            local new_value = not current_value

            if self:safeConfigSet(config_key, new_value) then
                self:showInfo(new_value and on_message or off_message)
            end
        end,
    }
end

function BaseSettingsModule:createResetButton(config_keys, reset_message)
    return {
        text = _("重置为默认值"),
        callback = function()
            local confirm_box = self:createConfirmBox{
                text = _("确定要重置设置为默认值吗？"),
                ok_callback = function()
                    self.config_defaults:resetToDefaults(self.config, config_keys)
                    self:showInfo(reset_message or _("设置已重置为默认值"))
                    -- 刷新当前菜单以显示更新后的值
                    if self.show then
                        self:show()
                    end
                end,
            }
            UIManager:show(confirm_box, "ui")
        end,
    }
end

return BaseSettingsModule
