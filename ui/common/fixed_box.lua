-- ui/common/fixed_box.lua
-- 固定尺寸盒子: getSize() 恒为声明尺寸, 内容再高也不改变盒子大小。
--
-- 为什么需要:
--   行内 TextBoxWidget 的实际 _bb 高度会比声明 height 多几像素 (行高不足时被抬高,
--   再为下伸部留白), 于是 FrameContainer:getSize() 算出来的行高与调用方期望的行高
--   对不上, 点击区就与绘制区错开 —— 表现是"看得见却点不着"或被后一行盖住。
--   把内容关进固定盒子, 行高就恒等于声明高度, 三者严格一致:
--       绘制区 == 落位基准 == 命中区
--
-- 使用者: comic_detail.lua 的 DetailRow、comment_list.lua 的 CommentRow。

local Geom = require("ui/geometry")
local Widget = require("ui/widget/widget")

local FixedBox = Widget:extend{
    width = nil,
    height = nil,
}

function FixedBox:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function FixedBox:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    if self[1] then self[1]:paintTo(bb, x, y) end
end

return FixedBox
