-- Plugin-scoped action styles. Native controls keep their geometry, gestures
-- and callbacks; KOReader's own menus/widgets are never changed globally.
local Screen=require("device").screen
local BB=require("ffi/blitbuffer")
local Size=require("ui/size")
local NativeButton=require("ui/widget/button")
local NativeMenu=require("ui/widget/menu")
local NativeDialog=require("ui/widget/buttondialog")
local NativeConfirm=require("ui/widget/confirmbox")
local NativeSpin=require("ui/widget/spinwidget")
local NativeInput=require("ui/widget/inputdialog")
local NativeMultiInput=require("ui/widget/multiinputdialog")
local Center=require("ui/widget/container/centercontainer")
local Left=require("ui/widget/container/leftcontainer")
local Frame=require("ui/widget/container/framecontainer")
local Geom=require("ui/geometry")
local Text=require("ui/widget/textwidget")
local FixedBox=require("ui.common.fixed_box")
local Theme=require("ui.common.theme")
local Style={}
Style.RADIUS=Screen:scaleBySize(2)
Style.GAP=Screen:scaleBySize(4)
Style.BORDER=Size.border.thin

function Style.row(opts)
    local gap,border=Style.GAP,Style.BORDER
    local w,h=opts.width-gap*2-border*2,opts.height-gap*2-border*2
    local padding=Screen:scaleBySize(8)
    local text=Text:new{text=opts.text,face=Theme.face("row"),bold=true,
        fgcolor=opts.enabled~=false and BB.COLOR_BLACK or BB.COLOR_DARK_GRAY,
        max_width=w-padding*2,truncate_with_ellipsis=true,
        picayomi_expandable_text=opts.expandable_text}
    local label
    if opts.align=="left" then
        label=Frame:new{padding=0,padding_left=padding,padding_right=padding,margin=0,bordersize=0,
            Left:new{dimen=Geom:new{w=w-padding*2,h=h},text}}
    else label=Center:new{dimen=Geom:new{w=w,h=h},text} end
    return FixedBox:new{width=opts.width,height=opts.height,
        Center:new{dimen=Geom:new{w=opts.width,h=opts.height},
            Frame:new{padding=0,margin=0,bordersize=border,radius=Style.RADIUS,
                background=BB.COLOR_WHITE,
                FixedBox:new{width=w,height=h,label}}}}
end

-- Inset outlines add no extra size to native menu/dialog rows.
local function outline(frame,enabled,primary)
    if not frame or frame._picayomi_action_outline then return end
    frame._picayomi_action_outline=true
    local paint=frame.paintTo
    frame.paintTo=function(self,bb,x,y)
        paint(self,bb,x,y)
        local size=self:getSize()
        local gap=Style.GAP
        bb:paintBorder(x+gap,y+gap,size.w-gap*2,size.h-gap*2,
            primary and Style.BORDER*2 or Style.BORDER,
            enabled() and BB.COLOR_BLACK or BB.COLOR_DARK_GRAY,Style.RADIUS)
    end
end

local function action_label(button)
    local label=button.label_widget
    local color=button.enabled~=false and BB.COLOR_BLACK or BB.COLOR_DARK_GRAY
    if button.text and label and label.fgcolor~=color then
        label.fgcolor=color
        if label.update then label:update() end
    elseif label and not button.text then label.dim=button.enabled==false end
end
local function disable(button)
    NativeButton.disable(button)
    action_label(button)
end
Style.Button=NativeButton:extend{radius=Style.RADIUS,bordersize=0,
    margin=Screen:scaleBySize(2)}
function Style.Button:init()
    NativeButton.init(self)
    action_label(self)
    outline(self.frame,function() return self.enabled~=false end)
end
Style.Button.disable=disable

local function label_width(text,height)
    local probe=Style.Button:new{text=text,height=height}
    local width=probe:getSize().w
    probe:free()
    return width
end
function Style.compactWidth(text,height)
    return label_width(text,height)+Screen:scaleBySize(24)
end

-- Reserve real label width plus breathing room, then share the remaining
-- space between short actions. Long labels use the same padding in every footer.
function Style.footerWidths(width,specs,height)
    local minimum,fixed={},{}
    local equal=math.floor(width/#specs)
    local remaining,flex=width,#specs
    for i,spec in ipairs(specs) do
        local natural=label_width(spec.min_text or spec.text,height)
        minimum[i]=natural+Screen:scaleBySize(16)
        if minimum[i]>equal then
            minimum[i]=natural+Screen:scaleBySize(24)
            fixed[i]=true;remaining=remaining-minimum[i];flex=flex-1
        end
    end
    local widths={}
    local short_min=0
    for i=1,#specs do if not fixed[i] then short_min=short_min+minimum[i] end end
    if remaining<short_min then
        -- Unusually long translations: stay within the viewport and let the
        -- native button handle fitting the labels, just as before.
        for i=1,#specs do widths[i]=equal end
    else
        for i=1,#specs do
            widths[i]=fixed[i] and minimum[i] or minimum[i]+math.floor((remaining-short_min)/math.max(1,flex))
        end
    end
    local used=0
    for _,w in ipairs(widths) do used=used+w end
    widths[#widths]=widths[#widths]+width-used
    return widths
end

local function decorate_menu(menu)
    for _,row in ipairs(menu.item_group or {}) do
        local entry=row.entry
        if entry and entry.picayomi_underline then
            local frame=row[1]
            if not frame._picayomi_underline then
                frame._picayomi_underline=true
                local paint=frame.paintTo
                frame.paintTo=function(self,bb,x,y)
                    paint(self,bb,x,y)
                    local size=self:getSize()
                    bb:paintRect(x+Style.GAP,y+size.h-Style.GAP-Style.BORDER,
                        size.w-2*Style.GAP,Style.BORDER,BB.COLOR_BLACK)
                end
            end
            row._picayomi_underlined_row=true
        elseif entry and (entry.callback or entry.sub_item_table or entry.tap_input)
            and not entry.picayomi_list_item then
            outline(row[1],function() return entry.enabled~=false end,entry.picayomi_primary)
            row._picayomi_action_row=true
        end
    end
end
Style.Menu=NativeMenu:extend{linesize=0,
    is_enable_shortcut=NativeMenu.is_enable_shortcut and not require("device"):isTouchDevice()}
function Style.Menu:registerKeyEvents()
    NativeMenu.registerKeyEvents(self)
    -- Hide keyboard badges in touch layouts while keeping actual keyboard keys.
    if require("device"):hasKeyboard() and not self.is_enable_shortcut then
        self.key_events.SelectByShortCut={{self.item_shortcuts}}
    end
end
function Style.Menu:updateItems(...)
    for _,entry in ipairs(self.item_table or {}) do
        if type(entry)=="table" then
            entry.dim=entry.enabled==false and not not (entry.callback or entry.sub_item_table or entry.tap_input)
            entry.mandatory_dim=entry.dim
            if entry.mandatory_dim_func then entry.mandatory_dim_func=function() return entry.dim end end
        end
    end
    NativeMenu.updateItems(self,...)
    decorate_menu(self)
end
local function restore_footer(menu)
    if menu._picayomi_footer_children then
        for i,child in ipairs(menu._picayomi_footer_children) do menu.page_info[i]=child end
        menu._picayomi_footer_children=nil
        menu.page_info:resetLayout()
    end
end
function Style.Menu:updatePageInfo(...)
    restore_footer(self)
    NativeMenu.updatePageInfo(self,...)
    self._picayomi_hidden_footer=self.page_num<=1
    if self._picayomi_hidden_footer then
        self.page_info_text:disableWithoutDimming()
        for _,button in ipairs{self.page_info_first_chev,self.page_info_left_chev,
            self.page_info_right_chev,self.page_info_last_chev} do
            button:hide()
            button:disableWithoutDimming()
        end
        self._picayomi_footer_children={}
        for i,child in ipairs(self.page_info) do self._picayomi_footer_children[i]=child end
        for i=#self.page_info,1,-1 do self.page_info[i]=nil end
        self.page_info:resetLayout()
    end
end
function Style.Menu:free(...)
    -- Detached controls still own label buffers; restore them for native cleanup.
    restore_footer(self)
    return NativeMenu.free(self,...)
end

local function decorate_dialog(dialog)
    local seen={}
    local function visit(widget)
        if type(widget)~="table" or seen[widget] then return end
        seen[widget]=true
        if widget.buttons_layout then
            for _,row in ipairs(widget.buttons_layout) do
                for _,button in ipairs(row) do
                    local target=button
                    if not target._picayomi_action_button then
                        local init=target.init
                        target.init=function(self,...)
                            init(self,...)
                            action_label(self)
                            outline(self.frame,function() return self.enabled~=false end)
                        end
                        target.disable=disable
                    end
                    action_label(target)
                    outline(target.frame,function() return target.enabled~=false end)
                    target._picayomi_action_button=true
                end
            end
            return
        end
        for _,child in ipairs(widget) do visit(child) end
    end
    visit(dialog.buttontable or dialog)
end
Style.ButtonDialog=NativeDialog:extend{}
function Style.ButtonDialog:init()
    NativeDialog.init(self)
    decorate_dialog(self)
end
Style.ConfirmBox=NativeConfirm:extend{}
function Style.ConfirmBox:init()
    NativeConfirm.init(self)
    decorate_dialog(self)
end
Style.SpinWidget=NativeSpin:extend{}
function Style.SpinWidget:init()
    NativeSpin.init(self)
    decorate_dialog(self)
end
function Style.SpinWidget:update(...)
    NativeSpin.update(self,...)
    decorate_dialog(self)
end
Style.InputDialog=NativeInput:extend{}
function Style.InputDialog:init(...)
    NativeInput.init(self,...)
    decorate_dialog(self)
end
Style.MultiInputDialog=NativeMultiInput:extend{}
function Style.MultiInputDialog:init(...)
    NativeMultiInput.init(self,...)
    decorate_dialog(self)
end
return Style
