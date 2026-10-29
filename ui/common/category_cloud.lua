-- Category labels flow across rows in source order. Only the visible page
-- owns buttons; the remaining pages keep lightweight layout descriptions.
local Blitbuffer = require("ffi/blitbuffer")
local ActionStyle = require("ui.common.action_style")
local Button = ActionStyle.CloudButton
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local MenuSwipe = require("ui.common.menu_swipe")
local PageJump = require("ui.common.page_jump")
local Size = require("ui/size")
local TapGuard = require("ui.common.tap_guard")
local TextWidget = require("ui/widget/textwidget")
local Theme = require("ui.common.theme")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local VisualComicList = require("ui.common.visual_comic_list")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local Cloud = InputContainer:extend{
    name = "picayomi_category_cloud",
    title = _("分类浏览"),
    is_picayomi_page = true,
    covers_fullscreen = true,
    is_popout = false,
}

function Cloud:init()
    self.width = self.width or Screen:getWidth()
    self.height = self.height or Screen:getHeight()
    self.dimen = Geom:new{x=0, y=0, w=self.width, h=self.height}
    self.page = 1
    self.categories = self.categories or {}
    self.padding = Screen:scaleBySize(12)
    self.gap = Screen:scaleBySize(10)
    self.label_padding = Screen:scaleBySize(14)
    self.content_width = self.width - 2 * self.padding
    self.page_text = TextWidget:new{
        text = "", face = Theme.face("info"),
        max_width = self.width - Screen:scaleBySize(16),
    }
    -- Share only the host list's title/footer presentation. No comic rows,
    -- cover downloads or network pagination are initialized for this page.
    self.header = VisualComicList.createHeader(self)
    self.footer = VisualComicList.createFooter(self)
    self.body_height = self.height - self.header:getSize().h - self.footer:getSize().h
    -- A fixed-size input container reserves the blank space above the footer
    -- while still forwarding gestures to its child buttons.
    self.body = InputContainer:new{
        dimen = Geom:new{x=0, y=0, w=self.width, h=self.body_height},
    }
    self:buildRows()
    self.rows_per_page = math.max(1, math.floor(
        (self.body_height - 2 * self.padding + self.gap) / (self.row_height + self.gap)))
    self.page_num = math.max(1, math.ceil(#self.rows / self.rows_per_page))
    self[1] = FrameContainer:new{
        padding = 0, margin = 0, bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{align="left", self.header, self.body, self.footer},
    }
    self:renderPage()
    if Device:isTouchDevice() then
        self.ges_events.Swipe = {GestureRange:new{ges="swipe", range=self.dimen}}
    end
    if Device.input and Device.input.group then
        self.key_events.Close = {{"Back"}}
        self.key_events.PageForward = {{Device.input.group.PgFwd}}
        self.key_events.PageBackward = {{Device.input.group.PgBack}}
    end
    MenuSwipe.attach(self, function() self:goBack() end)
    TapGuard.install(self, self.dimen)
end

function Cloud:buildRows()
    self.rows = {}
    local row, used, label_height = {}, 0, 0
    for _idx, category in ipairs(self.categories) do
        local title = type(category.title) == "string" and category.title:gsub("%s+", " ") or ""
        if not title:match("%S") then title = _("未知分类") end
        local label = TextWidget:new{
            text = title, face = Theme.face("row"),
            max_width = self.content_width - 2 * (self.label_padding + Size.border.thin),
        }
        local size = label:getSize()
        local width = math.min(self.content_width, size.w + 2 * (self.label_padding + Size.border.thin))
        label_height = math.max(label_height, size.h)
        label:free()
        if #row > 0 and used + self.gap + width > self.content_width then
            self.rows[#self.rows + 1] = row
            row, used = {}, 0
        end
        row[#row + 1] = {category=category, text=title, width=width}
        used = used + (#row > 1 and self.gap or 0) + width
    end
    if #row > 0 then self.rows[#self.rows + 1] = row end
    self.row_height = math.max(Screen:scaleBySize(42),
        label_height + 2 * Screen:scaleBySize(6) + 2 * Size.border.thin)
end

function Cloud:renderPage()
    if self.body[1] then self.body[1]:free() end
    self.chips = {}
    local rows = VerticalGroup:new{align="left"}
    local first = (self.page - 1) * self.rows_per_page + 1
    local last = math.min(#self.rows, first + self.rows_per_page - 1)
    local padding_v = Screen:scaleBySize(6)
    for n = first, last do
        if n > first then rows[#rows + 1] = VerticalSpan:new{width=self.gap} end
        local group = HorizontalGroup:new{}
        for i, item in ipairs(self.rows[n]) do
            if i > 1 then group[#group + 1] = HorizontalSpan:new{width=self.gap} end
            local chip = Button:new{
                text = item.text, width = item.width,
                -- Button.height is the label height, excluding padding/border.
                height = self.row_height - 2 * (padding_v + Size.border.thin),
                padding_h = self.label_padding, padding_v = padding_v,
                bordersize = Size.border.thin, radius = ActionStyle.RADIUS,
                text_font_size = Theme.face("row").orig_size, text_font_bold = false,
                avoid_text_truncation = false, show_parent = self,
                callback = function() if self.on_select then self.on_select(item.category) end end,
                hold_callback = function() if self.on_hold then self.on_hold(item.category) end end,
            }
            chip.category = item.category
            group[#group + 1] = chip
            self.chips[#self.chips + 1] = chip
        end
        rows[#rows + 1] = group
    end
    self.body[1] = FrameContainer:new{padding=self.padding, margin=0, bordersize=0, rows}
    self.page_text:setText(T(_("%1 个分类 · 第 %2/%3 页"), #self.categories, self.page, self.page_num))
    self.prev_button:enableDisable(self.page > 1)
    self.next_button:enableDisable(self.page < self.page_num)
    self.jump_button:enableDisable(self.page_num>1)
end

function Cloud:goToPage(page)
    if self._closed then return false end
    if type(page) ~= "number" or page ~= math.floor(page) or page < 1 or page > self.page_num then
        return false, _("页码超出范围")
    end
    if page ~= self.page then
        self.page = page
        self:renderPage()
        UIManager:setDirty(self, "ui")
    end
    return true
end

function Cloud:prevScreen()
    self:goToPage(math.max(1, self.page - 1))
    return true
end

function Cloud:nextScreen()
    self:goToPage(math.min(self.page_num, self.page + 1))
    return true
end
Cloud.onPrevPage = Cloud.prevScreen
Cloud.onNextPage = Cloud.nextScreen
Cloud.onPageBackward = Cloud.prevScreen
Cloud.onPageForward = Cloud.nextScreen

function Cloud:showJumpDialog()
    if self.jump_dialog then return end
    local dialog = PageJump.show{
        current = self.page,
        description = T(_("共 %1 页"), self.page_num),
        on_jump = function(page) return self:goToPage(page) end,
    }
    local on_close = dialog.onCloseWidget
    dialog.onCloseWidget = function(widget, ...)
        if self.jump_dialog == widget then self.jump_dialog = nil end
        return on_close(widget, ...)
    end
    self.jump_dialog = dialog
end

function Cloud:goBack()
    if self._closed then return true end
    UIManager:close(self, "ui")
    if self.on_back then self.on_back() end
    return true
end
Cloud.onClose = Cloud.goBack

function Cloud:onCloseWidget()
    if self._closed then return end
    self._closed = true
    if self.jump_dialog then
        UIManager:close(self.jump_dialog, "ui")
        self.jump_dialog = nil
    end
    if self.close_callback then self.close_callback() end
end

return Cloud
