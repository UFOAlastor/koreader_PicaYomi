-- ui/common/swipe_rules.lua
-- 全插件统一的"滑动分区"规则
--
--   边缘 (屏幕最左/最右 N%) 往中间划 = 返回上一页
--   中间 (其余区域) 左右划          = 页面内翻屏 (west = 下一屏, east = 上一屏)
--
-- 为什么按**起手位置**分区, 而不是按方向:
--   从左边往右划和从中间往右划是同一个方向 (east), 只有按下那一刻的坐标能区分。
--   Gesture.pos 正是起手点 (frontend/device/gesturedetector.lua:949 的 start_pos),
--   不是松手位置 —— 手指划过半个屏幕也不会改变归属。
--
-- 为什么边缘要"往中间"才算返回:
--   左边缘再往左、右边缘再往右都没有物理空间, 用户实际做不出这种手势; 但竖向
--   滑动是能发生的 (比如在边缘上竖着划一下), 那不该被当成返回。
--
-- 三个设置项 (设置 -> 操作与手势), **每次判定现读配置**, 改完立刻生效:
--   swipe_edge_back  = false      关掉边缘返回 (仍然消费事件, 只是不返回)
--   swipe_edge_side  = left/right 只允许某一侧 (default both)
--   swipe_edge_width = narrow/normal/wide (3% / 5% / 8%, default normal)
--
-- 默认 5%（PW5 上约 62px）；三个档位统一供所有页面的快滑与慢拖读取。

local Screen = require("device").screen
local config = require("util.config")

local M = {}

-- 配置键 (设置页与这里共用; 字符串字面量也满足 static_check 的"设置项接线"检查)
M.CONFIG_ENABLED = "swipe_edge_back"
M.CONFIG_SIDE = "swipe_edge_side"
M.CONFIG_WIDTH = "swipe_edge_width"

M.WIDTHS = { narrow = 0.03, normal = 0.05, wide = 0.08 }

--- 边缘返回是否启用
function M.isEnabled()
    return config:get(M.CONFIG_ENABLED, true) and true or false
end

--- 当前边缘宽度 (占屏宽的比例)
function M.edgeRatio()
    local key = config:get(M.CONFIG_WIDTH, "normal")
    return M.WIDTHS[key] or M.WIDTHS.normal
end

--- 这一侧边缘是否允许返回
function M.edgeAllowed(edge)
    local side = config:get(M.CONFIG_SIDE, "both")
    if side == "left" then return edge == "left" end
    if side == "right" then return edge == "right" end
    return true
end

--- 起手点在哪个边缘
-- @return "left" | "right" | nil
function M.edgeOf(ges)
    local pos = ges and ges.pos
    if not pos or not pos.x then return nil end
    local w = Screen:getWidth()
    local edge = w * M.edgeRatio()
    if pos.x <= edge then return "left" end
    if pos.x >= w - edge then return "right" end
    return nil
end

--- 这次滑动是不是"从边缘往中间划" (= 返回上一页)
--
-- 方向判定不能只看 east/west: KOReader 把 30° 以上的斜划标成
-- northeast/southeast (gesturedetector.lua 的 getPath), 而拇指在边缘划一下
-- 很容易带点上下分量 —— 真机反馈"边缘右滑偶尔有用、偶尔没用", 这是其中一类。
-- 只要**水平分量占优** (|dx| >= |dy|) 斜划也算返回; 竖向为主的仍然不算。
function M.isBackSwipe(ges,enabled)
    if enabled==nil then enabled=M.isEnabled()end
    if not enabled then return false end
    local edge = M.edgeOf(ges)
    if not edge or not M.edgeAllowed(edge) then return false end
    local direction = ges and ges.direction
    if ges and ges.end_pos and ges.pos then
        local dx = ges.end_pos.x - ges.pos.x
        local dy = ges.end_pos.y - ges.pos.y
        if math.abs(dx) < math.abs(dy) then return false end
    end
    if edge == "left" then
        return direction == "east" or direction == "northeast"
            or direction == "southeast"
    end
    return direction == "west" or direction == "northwest"
        or direction == "southwest"
end

-- Returns nil for gestures outside page navigation, so native menu handling
-- (e.g. diagonal refresh) can remain with its owner.
function M.dispatchPageSwipe(ges,actions)
    if M.isBackSwipe(ges) then
        if actions.back then actions.back() end
        return true
    end
    local direction=ges and ges.direction
    if direction=="west" then
        if actions.next then actions.next() end
        return true
    elseif direction=="east" then
        if actions.prev then actions.prev() end
        return true
    end
end

--- 这次滑动的**主轴** (按位移, 不按 direction 的名字)
--
-- KOReader 把偏 30° 以上的划动标成 northeast/southeast (gesturedetector 的
-- getPath), 所以"竖着划"手指稍微歪一点就不是 north/south 了。按方向名判断
-- 会让竖向滚动时灵时不灵 —— 只认位移的主轴。
-- @return "vertical" | "horizontal" | nil
function M.axisOf(ges)
    local pos, end_pos = ges and ges.pos, ges and ges.end_pos
    if pos and end_pos and pos.x and pos.y and end_pos.x and end_pos.y then
        local dx = math.abs(end_pos.x - pos.x)
        local dy = math.abs(end_pos.y - pos.y)
        if dx == 0 and dy == 0 then return nil end
        return dy > dx and "vertical" or "horizontal"
    end
    local d = ges and ges.direction
    if d == "north" or d == "south" then return "vertical" end
    if d == "east" or d == "west" or d == "northeast" or d == "northwest"
        or d == "southeast" or d == "southwest" then
        return "horizontal"
    end
    return nil
end

--- KOReader 自己的边缘手势区宽度 (左右各 1/8, 可在 KOReader 设置里改)
--
-- 用户常把"边缘上/下滑"配成亮度/色温。竖向滚动和那条手势是**同一个动作**,
-- 所以滚动必须让开这块区域 —— 只在中部生效。
local GESTURE_EDGE_FALLBACK = 1 / 8

local function gesture_edge_ratio(side)
    local key = (side == "left") and "DSWIPE_ZONE_LEFT_EDGE" or "DSWIPE_ZONE_RIGHT_EDGE"
    local defaults = rawget(_G, "G_defaults")
    if defaults and type(defaults.readSetting) == "function" then
        local ok, zone = pcall(defaults.readSetting, defaults, key)
        if ok and type(zone) == "table" and tonumber(zone.w) then
            return tonumber(zone.w)
        end
    end
    return GESTURE_EDGE_FALLBACK
end

--- 起手点是否落在 KOReader 的边缘手势区 (亮度/色温等)
function M.inGestureEdge(ges)
    local pos = ges and ges.pos
    if not (pos and pos.x) then return false end
    local w = Screen:getWidth()
    if w <= 0 then return false end
    return pos.x <= w * gesture_edge_ratio("left")
        or pos.x >= w - w * gesture_edge_ratio("right")
end

--- 慢速拖动 (pan) 是不是"从边缘往中间划"
--
-- KOReader 的 swipe 有 **900ms 上限** (gesturedetector.lua 的 SWIPE_INTERVAL_MS):
-- 手指在屏幕上停留超过 0.9 秒再抬起, 这个手势就不再是 swipe, 而是 pan_release
-- —— 页面的 onSwipe 根本不会被调用。真机上"慢一点就一定没用"就是这条。
--
-- pan 事件带 start_pos (按下点) 与 pos (当前点), 用同一套边缘规则判定。
function M.isBackPan(ges,enabled)
    if enabled==nil then enabled=M.isEnabled()end
    if not enabled then return false end
    local start = ges and ges.start_pos
    local cur = ges and ges.pos
    if not (start and cur and start.x and cur.x) then return false end
    local dx = cur.x - start.x
    local dy = cur.y - start.y
    if math.abs(dx) < math.abs(dy) then return false end
    local edge = M.edgeOf({ pos = start })
    if not edge or not M.edgeAllowed(edge) then return false end
    if edge == "left" then return dx > 0 end
    if edge == "right" then return dx < 0 end
    return false
end

--- 给页面补一条"慢速边缘拖动 = 返回"的兜底 (见 isBackPan)
--
-- 注册 pan / pan_release 两种手势: 拖动期间记下"这次是从边缘往中间拖的",
-- 抬手时才真的返回 —— 划到一半不触发, 免得刚动一下就退出。
-- 只认边缘起手; 中间的拖动原本就没有任何行为, 不受影响。
--
-- 兜底**始终装上**, 是否生效由 isBackPan 现读配置决定 —— 这样用户在设置里
-- 打开/关闭边缘返回时不需要重开页面 (注册时写死会变成"改完要重启")。
--
-- @param widget   InputContainer 及其子类 (页面/菜单)
-- @param on_back  返回动作 (无参)
-- @return 是否装上
function M.installSlowDragBack(widget, on_back)
    if not widget or type(on_back) ~= "function" then return false end
    if not require("device"):isTouchDevice() then return false end
    local GestureRange = require("ui/gesturerange")
    local Geom = require("ui/geometry")
    local range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }

    widget.ges_events = widget.ges_events or {}
    widget.ges_events.PicayomiDragTrack = {
        GestureRange:new{ ges = "pan", range = range },
    }
    widget.ges_events.PicayomiDragRelease = {
        GestureRange:new{ ges = "pan_release", range = range },
    }
    -- 实例方法 (会覆盖类方法, 与 TapGuard 同一个做法)
    widget.onPicayomiDragTrack = function(self, _arg, ges)
        -- 每次都用最新状态覆盖: 拖出去又拖回来, 抬手时就不该再算返回
        self._picayomi_drag_back = M.isBackPan(ges)
        return false    -- 兜底手势, 不吃掉事件
    end
    widget.onPicayomiDragRelease = function(self, _arg, _ges)
        local hit = self._picayomi_drag_back
        self._picayomi_drag_back = nil
        if not hit then return false end
        on_back()
        return true
    end
    return true
end

return M
