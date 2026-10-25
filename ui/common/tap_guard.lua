-- ui/common/tap_guard.lua
-- 给"全屏页面/菜单"加一个兜底 tap 消费者, 让落空的输入在本页就地结束。
--
-- 为什么需要:
--   KOReader 的事件分发是 UIManager:sendEvent 从窗口栈顶往下走 —— 顶层控件
--   handleEvent 返回 false (没消费) 就继续往下层窗口送。而全屏页面内部的控件之间
--   总有内边距/行间空隙, 那些点没人认领, 于是一路传下去:
--     * 下层凡注册为 active_widgets / is_always_active 的模块都会收到
--       (阅读器的手势模块就是这类), 可能触发与本页毫不相干的动作;
--     * 界面越大、空隙越多, "点了没反应/点了却跳到别处"的概率越高。
--   KOReader 自己的全屏控件也是这么做的 (InputDialog 就用一个整屏 ges 吃掉落空的 tap)。
--
-- 为什么"兜底"就够了:
--   子控件 (按钮 / 列表项) 先被派发, 它们会 return true; 只有**全都没接**时
--   才轮到这一条。所以正常点击完全不受影响, 只是把"没人要的 tap"就地吃掉。
--
-- 注意: 弹出式菜单 (is_popout) 靠 KOReader 自己的 TapCloseAllMenus 关闭,
--   再叠一个 TapConsume 会让"点外面关掉菜单"失效 (ges_events 是 pairs 遍历,
--   顺序不保证), 所以这里对弹出式菜单直接跳过。

local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")

local TapGuard = {}

local Screen = Device.screen

--- 让 widget 吃掉落空的全屏 tap
-- @param widget 目标控件 (须是 InputContainer 及其子类)
-- @param range  可选, 自定义消费范围; 默认整屏
-- @return widget (便于链式书写)
function TapGuard.install(widget, range)
    if not widget or not Device:isTouchDevice() then return widget end
    -- 弹出式菜单: 保留它自己的"点外面关闭"行为
    if widget.is_popout then return widget end
    require("ui.common.host_menu").attach(widget)

    widget.ges_events = widget.ges_events or {}
    widget.ges_events.TapConsume = {
        GestureRange:new{
            ges = "tap",
            range = range or Geom:new{
                x = 0, y = 0,
                w = Screen:getWidth(), h = Screen:getHeight(),
            },
        },
    }
    -- 实例字段会覆盖类方法, 效果等同各页面自己写一个 onTapConsume
    widget.onTapConsume = function() return true end
    return widget
end

return TapGuard
