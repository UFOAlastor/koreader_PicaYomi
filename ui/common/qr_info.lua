-- ui/common/qr_info.lua
-- 带说明文字的二维码弹层: 标题 + 二维码 + URL + 操作提示。
--
-- 为什么不直接用 KOReader 的 QRMessage:
--   它只有一张二维码, 没有任何文字。用户不知道码指向什么, 在电子墨水屏上
--   也没法把 URL 复制出来 —— 扫码前至少应该看到"这是哪个项目的仓库"。
--
-- 交互: 点屏幕任意位置 (或按任意键) 关闭; 不做超时, 方便慢慢扫。
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local QRWidget = require("ui/widget/qrwidget")
local Screen = Device.screen
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")

local Theme = require("ui.common.theme")

local QrInfo = InputContainer:extend{
    is_picayomi_page = true,
    covers_fullscreen = true,
    title_text = nil,
    url = nil,
    hint = nil,
    width = nil,
    height = nil,
}

function QrInfo:init()
    self.width = self.width or Screen:getWidth()
    self.height = self.height or Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }

    local padding = Screen:scaleBySize(24)
    local side = math.min(self.width, self.height) - Screen:scaleBySize(320)
    side = math.max(side, Screen:scaleBySize(240))

    local qr = QRWidget:new{
        text = self.url or "",
        width = side,
        height = side,
    }

    local box = FrameContainer:new{
        padding = padding,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "center",
            TextWidget:new{
                text = self.title_text or _("二维码"),
                face = Theme.face("list_title"),
                bold = true,
            },
            VerticalSpan:new{ width = Screen:scaleBySize(12) },
            qr,
            VerticalSpan:new{ width = Screen:scaleBySize(10) },
            TextWidget:new{
                text = self.url or "",
                face = Theme.face("info"),
            },
            VerticalSpan:new{ width = Screen:scaleBySize(6) },
            TextWidget:new{
                text = self.hint or _("扫码可打开上面的链接 · 点屏幕关闭"),
                face = Theme.face("info"),
            },
        },
    }

    self[1] = FrameContainer:new{
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        width = self.width,
        height = self.height,
        CenterContainer:new{
            dimen = self.dimen,
            box,
        },
    }

    if Device:isTouchDevice() then
        self.ges_events.TapClose = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        }
    end
    if Device:hasKeys() then
        local Input = Device.input
        self.key_events = {
            AnyKeyPressed = { { Input.group.Any } },
        }
    end
end

function QrInfo:onTapClose()
    UIManager:close(self, "ui")
    return true
end

QrInfo.onAnyKeyPressed = QrInfo.onTapClose
QrInfo.onClose = QrInfo.onTapClose

--- 显示二维码 (返回控件, 供测试断言)
function QrInfo.show(opts)
    local widget = QrInfo:new(opts)
    UIManager:show(widget, "ui")
    return widget
end

return QrInfo
