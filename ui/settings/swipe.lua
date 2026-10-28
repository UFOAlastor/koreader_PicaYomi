-- ui/settings/swipe.lua
-- 设置 -> 操作与手势
--
-- 三个开关, 全部由 ui/common/swipe_rules.lua **在判定时现读**, 改完立刻生效
-- (不需要重开页面, 也不需要重启 KOReader):
--   * 边缘滑动返回  —— 关掉后边缘滑动只消费事件, 不返回
--   * 允许的边缘    —— 两侧 / 仅左 / 仅右
--   * 边缘宽度      —— 窄 3% / 标准 5% / 宽 8% (治"起手点偏一点就滑不动")
--
-- 中间滑动 (翻屏) **不提供开关**: 那是页面内导航, 关掉只会让人以为页面坏了。

local BaseSettingsModule = require("ui.settings.base")
local SwipeRules = require("ui.common.swipe_rules")
local _ = require("gettext")
local T = require("ffi/util").template

local SwipeSettings = BaseSettingsModule:new{
    name = "swipe_settings",
}

--- 给选中的菜单项打勾
-- Menu 不渲染 checked 字段 (认它的是 TouchMenu), 所以用文字后缀 (与阅读设置一致)。
local function checkLabel(selected, text)
    return selected and (text .. "  ✓") or text
end

local SIDE_LABELS = {
    both = _("两侧"),
    left = _("仅左边缘"),
    right = _("仅右边缘"),
}

local WIDTH_LABELS = {
    narrow = T(_("窄（%1%）"), SwipeRules.WIDTHS.narrow * 100),
    normal = T(_("标准（%1%）"), SwipeRules.WIDTHS.normal * 100),
    wide = T(_("宽（%1%）"), SwipeRules.WIDTHS.wide * 100),
}

function SwipeSettings:show()
    local items = {
        {
            text = _("边缘滑动返回"),
            mandatory_func = function() return self:safeConfigGet(SwipeRules.CONFIG_ENABLED) and _("开启") or _("关闭") end,
            callback = function() self:chooseEnabled() end,
        },
        {
            text = _("允许的边缘"),
            mandatory_func = function() return SIDE_LABELS[self:safeConfigGet(SwipeRules.CONFIG_SIDE)] or SIDE_LABELS.both end,
            callback = function() self:chooseSide() end,
        },
        {
            text = _("边缘宽度"),
            mandatory_func = function() return WIDTH_LABELS[self:safeConfigGet(SwipeRules.CONFIG_WIDTH)] or WIDTH_LABELS.normal end,
            callback = function() self:chooseWidth() end,
        },
        self:createBackButton(),
    }
    self:showMenu(self:createMenu(_("操作与手势"), items))
end

--- 写入配置并把**当前页刷新出来**
--
-- 选项在子菜单里, 选完要回到本页并让上面那行文案跟着变:
--   goBack()  关掉子菜单, 回到本页 (菜单栈弹一层)
--   refresh() 用新配置重建本页 (关旧页 + 重建, 不会叠出两份)
-- 只 goBack 不 refresh 的话, 本页显示的还是打开时的旧值 (看起来像"没生效")。
function SwipeSettings:apply(key, value, toast)
    if not self:safeConfigSet(key, value, toast) then return end
    self:goBack()
    self:refresh()
end

--- 边缘滑动返回: 开 / 关
function SwipeSettings:chooseEnabled()
    local current = self:safeConfigGet(SwipeRules.CONFIG_ENABLED)
    local options = {
        { text = _("开启（默认）"), value = true, toast = _("已开启边缘滑动返回") },
        { text = _("关闭"), value = false,
          toast = _("已关闭边缘滑动返回（仍然可以用「返回」按钮）") },
    }
    local items = {}
    for _idx, opt in ipairs(options) do
        table.insert(items, {
            text = checkLabel(current == opt.value, opt.text),
            callback = function()
                self:apply(SwipeRules.CONFIG_ENABLED, opt.value, opt.toast)
            end,
        })
    end
    table.insert(items, self:createBackButton())
    self:showMenu(self:createMenu(_("边缘滑动返回"), items))
end

--- 允许哪一侧边缘
--
-- 关掉某一侧不会影响"中间滑动翻屏" —— 那一侧仍然可以正常翻页。
function SwipeSettings:chooseSide()
    local current = self:safeConfigGet(SwipeRules.CONFIG_SIDE)
    local options = {
        { text = _("两侧（默认）"), value = "both" },
        { text = _("仅左边缘"), value = "left" },
        { text = _("仅右边缘"), value = "right" },
    }
    local items = {}
    for _idx, opt in ipairs(options) do
        table.insert(items, {
            text = checkLabel(current == opt.value, opt.text),
            callback = function()
                self:apply(SwipeRules.CONFIG_SIDE, opt.value,
                    T(_("边缘返回已改为 %1"), opt.text))
            end,
        })
    end
    table.insert(items, self:createBackButton())
    self:showMenu(self:createMenu(_("允许的边缘"), items))
end

--- 边缘宽度
--
-- 宽一点更容易起手 (手抖 / 壳子挡住边缘时), 代价是中间可用于翻屏的区域变窄;
-- 窄一点则更不容易误触。
function SwipeSettings:chooseWidth()
    local current = self:safeConfigGet(SwipeRules.CONFIG_WIDTH)
    local options = {
        { text = WIDTH_LABELS.narrow, value = "narrow" },
        { text = WIDTH_LABELS.normal .. _("（默认）"), value = "normal" },
        { text = WIDTH_LABELS.wide, value = "wide" },
    }
    local items = {}
    for _idx, opt in ipairs(options) do
        table.insert(items, {
            text = checkLabel(current == opt.value, opt.text),
            callback = function()
                self:apply(SwipeRules.CONFIG_WIDTH, opt.value,
                    T(_("边缘宽度已设置为 %1"), opt.text))
            end,
        })
    end
    table.insert(items, self:createBackButton())
    self:showMenu(self:createMenu(_("边缘宽度"), items))
end

return SwipeSettings
