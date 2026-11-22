local Blitbuffer = require("ffi/blitbuffer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen

local CoverZoom = {}

function CoverZoom.show(self, path)
    -- 已经开着: 这一下就是"退出" (避免叠第二层)
    if self.cover_zoom then
        CoverZoom.close(self)
        return true
    end

    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local margin = Screen:scaleBySize(6)
    local max_w = sw - margin * 2
    local max_h = sh - margin * 2

    local overlay = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh },
        -- 下层 (详情页) 不必再画; 也保证整屏都是黑的
        covers_fullscreen = true,
        modal = true,
        -- 退出 Picayomi 时由 util/widget_sweep 一并扫掉
        is_picayomi_page = true,
    }
    overlay.ges_events = {
        TapClose = {
            GestureRange:new{
                ges = "tap",
                range = overlay.dimen,
            },
        },
    }
    overlay.onTapClose = function()
        CoverZoom.close(self)
        return true
    end
    overlay[1] = FrameContainer:new{
        width = sw,
        height = sh,
        dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh },
        margin = 0,
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_BLACK,
        CenterContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh },
            ImageWidget:new{
                file = path,
                width = max_w,
                height = max_h,
                -- 0 = 等比缩放到刚好放进 width/height (不拉伸)
                scale_factor = 0,
            },
        },
    }

    self.cover_zoom = overlay
    UIManager:show(overlay, "ui")
    return true
end

--- 关掉封面放大层 (幂等)
function CoverZoom.close(self)
    local overlay = self.cover_zoom
    if not overlay then return end
    self.cover_zoom = nil
    pcall(function() UIManager:close(overlay, "ui") end)
end

return CoverZoom
