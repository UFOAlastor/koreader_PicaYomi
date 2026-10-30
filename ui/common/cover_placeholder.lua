local BB=require('ffi/blitbuffer')
local Screen=require('device').screen
local Geom=require('ui/geometry')
local Size=require('ui/size')
local TextBox=require('ui/widget/textboxwidget')
local Text=require('ui/widget/textwidget')
local Container=require('ui/widget/container/widgetcontainer')
local Theme=require('ui.common.theme')
local _=require('gettext')

local Cover=Container:extend{}
function Cover:init()
    local title=self.title
    if type(title)=='number'then title=tostring(title)end
    if type(title)~='string'then title=''end
    title=title:gsub('%s+',' '):match('^%s*(.-)%s*$')
    if title==''then title=_('未知标题')end
    self.title=title
    self.background=self.background or BB.COLOR_WHITE
    self.dimen=Geom:new{w=self.width,h=self.height}
    local padding=Screen:scaleBySize(6)
    local inner=math.max(1,self.width-2*padding)
    local status_height,gap=0,0
    if self.text and self.text~=_('无封面')then
        self[2]=Text:new{text=self.text,face=Theme.face('cover_status'),fgcolor=BB.COLOR_DARK_GRAY,
            max_width=inner,truncate_with_ellipsis=true}
        status_height=self[2]:getSize().h
        gap=Screen:scaleBySize(4)
    end
    self[1]=TextBox:new{text=title,face=Theme.face('cover_title'),bold=true,
        width=inner,height=math.max(1,self.height-2*padding-status_height-gap),
        height_adjust=true,height_overflow_show_ellipsis=true,alignment='center',
        fgcolor=BB.COLOR_BLACK,bgcolor=self.background}
    local h=self[1]:getSize().h
    self.title_y=math.max(padding,math.floor((self.height-status_height-gap-h)/2))
    self.padding=padding
    self.status_y=self.height-padding-status_height
end

function Cover:paintTo(bb,x,y)
    self.dimen.x=x;self.dimen.y=y
    local visible_width=math.min(self.width,self.clip_width or self.width)
    bb:paintRect(x,y,visible_width,self.height,self.background)
    if self.border~=false then
        bb:paintBorder(x,y,self.width,self.height,Size.border.thin,BB.COLOR_DARK_GRAY)
    end
    -- The last home thumbnail may only be partly visible. Clip both text and
    -- glyph descenders, while keeping normal widget coordinates for callers.
    local left,top=math.max(0,x),math.max(0,y)
    local width=math.min(bb:getWidth(),x+visible_width)-left
    local height=math.min(bb:getHeight(),y+self.height)-top
    if width<=0 or height<=0 then return end
    local view=bb:viewport(left,top,width,height)
    for i,child in ipairs(self)do
        local size=child:getSize()
        local cx=x+math.floor((self.width-size.w)/2)
        local cy=y+(i==1 and self.title_y or self.status_y)
        child:paintTo(view,cx-left,cy-top)
        child.dimen=Geom:new{x=cx,y=cy,w=size.w,h=size.h}
    end
    view:free()
end
return Cover
