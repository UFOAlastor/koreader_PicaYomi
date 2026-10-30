local Device=require("device")
local Screen=Device.screen
local BB=require("ffi/blitbuffer")
local Font=require("ui/font")
local Geom=require("ui/geometry")
local GestureRange=require("ui/gesturerange")
local InputContainer=require("ui/widget/container/inputcontainer")
local Text=require("ui/widget/textwidget")
local Image=require("ui/widget/imagewidget")
local Style=require("ui.common.action_style")
local UI=require("ui/uimanager")
local Layout=require("ui.common.home_layout")
local Data=require("ui.common.home_data")
local Cover=require("util.cover_cache")
local CoverPlaceholder=require("ui.common.cover_placeholder")
local _=require("gettext")

local Link=InputContainer:extend{}
function Link:init()
    self.dimen=Geom:new{w=self.width,h=self.height}
    self.label=Text:new{text=self.text,face=self.face,bold=true,fgcolor=self.enabled==false and BB.COLOR_DARK_GRAY or BB.COLOR_BLACK,max_width=self.width-self.arrow_width,
        truncate_with_ellipsis=true}
    self.arrow=Text:new{text="›",face=self.face}
    self[1]=self.label;self[2]=self.arrow
    if self.note then
        self.note_widget=Text:new{text=self.note,face=self.note_face,fgcolor=BB.COLOR_DARK_GRAY,
            max_width=math.max(1,self.width-self.arrow_width-self.label:getSize().w-self.note_gap),truncate_with_ellipsis=true}
        self[3]=self.note_widget
    end
    self.ges_events={Tap={GestureRange:new{ges="tap",range=self.dimen}}}
end
function Link:paintTo(bb,x,y)
    self.dimen.x=x;self.dimen.y=y
    local label=self.label:getSize();local arrow=self.arrow:getSize()
    self.label:paintTo(bb,x,y+math.floor((self.height-label.h)/2))
    self.arrow:paintTo(bb,x+self.width-arrow.w,y+math.floor((self.height-arrow.h)/2))
    if self.note_widget then
        local size=self.note_widget:getSize()
        self.note_widget:paintTo(bb,x+label.w+self.note_gap,y+math.floor((self.height-size.h)/2))
    end
end
function Link:onTap()
    if self.enabled~=false and self.callback then self.callback()end
    return true
end

local Tile=InputContainer:extend{}
function Tile:init()
    self.dimen=Geom:new{w=self.width,h=self.height}
    self.ges_events={Tap={GestureRange:new{ges="tap",range=self.dimen}}}
end
function Tile:setPath(path)
    if self._closed or path==self.path then return false end
    if self.image then self.image:free();self.image=nil end
    self.path=path
    if path then
        if self.placeholder then self.placeholder:free();self.placeholder=nil end
        self.image=Image:new{file=path,width=self.cover_width,height=self.cover_height,
            scale_factor=nil,file_do_cache=false}
    end
    return true
end
function Tile:paintTo(bb,x,y)
    self.dimen.x=x;self.dimen.y=y
    bb:paintRect(x,y,self.width,self.height,BB.COLOR_LIGHT_GRAY)
    if self.image then
        -- The image is intentionally larger than this preview's clipping window.
        -- It is owned separately so hidden pixels never become touch targets.
        local view=bb:viewport(x,y,self.width,self.height)
        local ok=pcall(self.image.paintTo,self.image,view,0,0)
        view:free()
        if not ok then self.image:free();self.image=nil end
    end
    if not self.image then
        self.placeholder=self.placeholder or CoverPlaceholder:new{width=self.cover_width,height=self.height,
            clip_width=self.width,title=self.comic and self.comic.title,background=BB.COLOR_LIGHT_GRAY,border=false}
        -- Keep fills on the parent buffer: native full-width fills on a
        -- strided viewport can otherwise overwrite neighbouring thumbnails.
        self.placeholder:paintTo(bb,x,y)
    end
end
function Tile:onTap()
    if not self._closed and self.callback then self.callback()end
    return true
end
function Tile:onCloseWidget()self._closed=true;self:free()end
function Tile:free()
    if self.image then self.image:free();self.image=nil end
    if self.placeholder then self.placeholder:free();self.placeholder=nil end
end

local Strip=InputContainer:extend{}
function Strip:init()
    self.dimen=Geom:new{w=self.width,h=self.height}
    local x=0
    for _,comic in ipairs(self.items)do
        if x>=self.width then break end
        local tile=Tile:new{width=math.min(self.cover_width,self.width-x),height=self.height,
            cover_width=self.cover_width,cover_height=self.cover_height,comic=comic,
            callback=function()self.on_select(comic)end}
        tile.offset=x
        local sid=comic.source_id or self.source_id
        tile:setPath(Cover.find(sid,comic._id))
        self[#self+1]=tile;x=x+self.cover_width+self.gap
    end
    self.more=self.has_more or #self.items*(self.cover_width+self.gap)-self.gap>self.width
end
function Strip:paintTo(bb,x,y)
    self.dimen.x=x;self.dimen.y=y
    for _,tile in ipairs(self)do tile:paintTo(bb,x+tile.offset,y)end
    -- A bounded number of alpha bands works on gray and color framebuffers.
    local fade=math.min(self.height,math.floor(self.height*.35))
    for i=1,16 do
        local y0=math.floor((i-1)*fade/16);local y1=math.floor(i*fade/16)
        if y1>y0 then bb:lightenRect(x,y+self.height-fade+y0,self.width,y1-y0,i/16)end
    end
    if self.more then
        local width=math.min(self.width,self.fade_width)
        for i=1,16 do
            local x0=math.floor((i-1)*width/16);local x1=math.floor(i*width/16)
            if x1>x0 then bb:lightenRect(x+self.width-width+x0,y,x1-x0,self.height,i/16)end
        end
    end
end

local Dashboard=InputContainer:extend{
    name="picayomi_home_dashboard",is_picayomi_page=true,is_picayomi_home_menu=true,
    is_picayomi_dashboard=true,covers_fullscreen=true,is_popout=false,page=1,page_num=1,
}
function Dashboard:isTop()
    local stack=UI._window_stack
    return not self._closed and stack and stack[#stack] and stack[#stack].widget==self
end
function Dashboard:face(size)
    return Font:getFace("cfont",size*self.scale/self.native_scale*(self.font_scale or 1))
end
function Dashboard:button(spec,width,height)
    local button=Style.Button:new{
        text=spec.label or spec.text,width=width,height=height,padding=0,margin=0,
        align=spec.align or "center",
        padding_h=spec.align=="left" and math.floor(12*self.scale+.5) or 0,
        bordersize=0,text_font_size=19*self.scale/self.native_scale*(self.font_scale or 1),
        text_font_bold=true,enabled=spec.enabled~=false,avoid_text_truncation=false,
        callback=function()self:onMenuSelect(spec)end,show_parent=self,
    }
    return button
end
function Dashboard:init()
    local Favorites=require("util.favorites")
    local cached=Favorites.cachedOnline(self.source,true)
    if cached then self.online_data=cached;self.online=cached.comics end
    self._online_scope=Favorites.onlineScope(self.source)
    self._refresh_online=Favorites.backend(self.source)=="online"
    self.width=self.width or Screen:getWidth();self.height=self.height or Screen:getHeight()
    self.dimen=Geom:new{x=0,y=0,w=self.width,h=self.height}
    self._epoch=0
    self.shelves={};self.positions={}
    self:updateItems()
    require("ui.common.tap_guard").install(self,self.dimen)
    require("ui.common.menu_swipe").attach(self)
    if Device.input and Device.input.group then self.key_events.Close={{"Back"}}end
end
function Dashboard:onMenuSelect(item)
    if not item or item.enabled==false or item.select_enabled==false then return true end
    self:suspend()
    if item.callback then item.callback()end
    return true
end
function Dashboard:onClose()
    if self.close_callback then self.close_callback()end
    return true
end
function Dashboard:onNextPage()return true end
function Dashboard:onPrevPage()return true end
function Dashboard:getSize()return Geom:new{w=self.width,h=self.height}end
function Dashboard:refreshData(reset_online)
    self:suspend()
    local Favorites=require("util.favorites")
    local scope=Favorites.onlineScope(self.source)
    local old=self._online_scope
    local identity_changed=old and(not scope or scope.generation~=old.generation or scope.key~=old.key)
    local revision=Favorites.revision(self.source and self.source.identifier)
    if self._favorites_revision~=nil and self._favorites_revision~=revision then reset_online=true end
    self._favorites_revision=revision
    if identity_changed or reset_online and not scope then
        self.online=nil;self.online_data=nil;self.online_error=nil
    end
    self._online_scope=scope
    if reset_online or identity_changed then self._refresh_online=true;self.online_error=nil end
    if not self.online and scope then
        local cached=Favorites.cachedOnline(self.source,true)
        if cached then self.online_data=cached;self.online=cached.comics end
    end
    local count=math.ceil(self.width/math.max(1,Screen:scaleBySize(106)))+1
    self.snapshot=Data.snapshot(self.source,self.owner.comic_model,math.min(count,16),self.online)
    if self.snapshot.backend~="online"then self._refresh_online=false end
    self:updateItems()
    if self:isTop()then self:startPreviews();UI:setDirty(self,"ui")end
end
function Dashboard:updateItems()
    if self._building then return end
    self._building=true
    self:suspend()
    for _,child in ipairs(self)do child:free()end
    for i=#self,1,-1 do self[i]=nil end
    self.positions={};self.shelves={};self.tiles={}
    self.native_scale=Screen:scaleBySize(600)/600
    self.scale=math.max(1,self.native_scale)
    local function px(n)return math.floor(n*self.scale+.5)end
    self.snapshot=self.snapshot or Data.snapshot(self.source,self.owner.comic_model,16,self.online)
    local header_face=self:face(23)
    local probe=Text:new{text="已下载",face=header_face,bold=true}
    local text_h=probe:getSize().h;local min_header=probe:getSize().w+px(32);probe:free()
    local header_height=math.max(px(44),text_h+px(8))
    local top_h=math.max(px(50),text_h+px(12))
    local footer_specs={}
    for _,spec in ipairs(self.footer_specs)do
        footer_specs[#footer_specs+1]={text=spec.text,enabled=spec.enabled,callback=function()self:onMenuSelect(spec)end}
    end
    local footer_label=Text:new{text=_("设置"),face=self:face(20)}
    local footer_label_h=footer_label:getSize().h;footer_label:free()
    local footer_options
    if self.native_scale<1 or self.font_scale and self.font_scale~=1 then
        footer_options={padding=px(4),height=math.max(px(40),footer_label_h+px(8)),
            font_size=20*self.scale/self.native_scale*(self.font_scale or 1)}
    end
    self.footer_widget,self.footer_buttons=Style.footer(self.width,footer_specs,footer_options)
    local footer_h=self.footer_widget:getSize().h
    local sections={}
    for _,entry in ipairs(self.section_specs)do
        local data=self.snapshot[entry.id]
        sections[#sections+1]={id=entry.id,has_preview=data and #data.items>0 or entry.id=="favorites" and self.snapshot.pending}
    end
    local bubbles={}
    self.bubble_buttons={}
    for _,spec in ipairs(self.bubble_specs)do
        local label=Text:new{text=spec.label or spec.text,face=self:face(19)}
        local width=label:getSize().w+px(42);label:free()
        local button=Style.CloudButton:new{text=spec.label or spec.text,width=width,height=header_height,
            padding=0,margin=0,bordersize=1,radius=Style.RADIUS,text_font_bold=false,
            text_font_size=19*self.scale/self.native_scale*(self.font_scale or 1),
            callback=function()self:onMenuSelect(spec)end}
        self.bubble_buttons[#self.bubble_buttons+1]=button
        local size=button:getSize();bubbles[#bubbles+1]={w=size.w,h=size.h}
    end
    self.layout=Layout.arrange{width=self.width,height=self.height,scale=self.scale,
        top_height=top_h,footer_height=footer_h,preview_height=px(104),sections=sections,bubbles=bubbles,
        min_header_width=min_header,header_height=function()return header_height end}
    local function add(widget,x,y)
        self[#self+1]=widget;self.positions[#self]={x=x,y=y};return widget
    end
    local padding=self.layout.padding
    local account=Text:new{text=self.account_spec.label or self.account_spec.text,face=self:face(19)}
    local account_w=account:getSize().w+px(38);account:free()
    self.source_button=add(self:button(self.source_spec,self.width-2*padding-account_w-px(14),top_h),padding,padding)
    self.account_button=add(self:button(self.account_spec,account_w,top_h),self.width-padding-account_w,padding)
    for i,r in ipairs(self.layout.sections)do
        local spec=self.section_specs[i];local data=self.snapshot[r.id]
        local text,note=spec.label
        if r.id=="favorites" then
            note=self.snapshot.backend=="online" and _("线上") or self.snapshot.backend=="local" and _("本地") or _("不可用")
            if self.online_error then note=note.._(" · 重试")
            elseif (self._refresh_online or self.snapshot.pending)and r.preview then note=note.._(" · 刷新中")end
        end
        local link=Link:new{text=text,note=note,note_face=self:face(14),note_gap=px(8),
            width=r.w,height=r.header_height,face=header_face,arrow_width=px(28),enabled=spec.enabled,
            callback=function()self:onMenuSelect(spec)end}
        add(link,r.x,r.y)
        self.shelves[r.id]={link=link,rect=r}
        if r.preview then
            local strip=Strip:new{width=r.w,height=px(104),items=data.items,has_more=data.more,
                source_id=self.source and self.source.identifier,cover_width=px(106),cover_height=px(149),gap=px(16),fade_width=px(48),
                on_select=function(comic)
                    self:suspend();self.owner:openHomePreview(r.id,comic,self.online_data)
                end}
            add(strip,r.x,r.y+r.header_height+px(8));self.shelves[r.id].strip=strip
            for _,tile in ipairs(strip)do self.tiles[#self.tiles+1]=tile end
        end
    end
    for i,r in ipairs(self.layout.bubbles)do add(self.bubble_buttons[i],r.x,r.y)end
    add(self.footer_widget,0,self.height-footer_h)
    self._building=nil
end
function Dashboard:paintTo(bb,x,y)
    self.dimen.x=x;self.dimen.y=y
    bb:paintRect(x,y,self.width,self.height,BB.COLOR_WHITE)
    for i,widget in ipairs(self)do
        local p=self.positions[i];widget:paintTo(bb,x+p.x,y+p.y)
    end
    -- A transient host dialog can cover the first scheduled load. Resume only
    -- when this page is painted at the top again; no background polling loop.
    if self:isTop()and self._preview_epoch_started~=self._epoch and not self._start then
        self._start=function()self._start=nil;self:startPreviews()end
        UI:scheduleIn(.05,self._start)
    end
end
function Dashboard:suspend()
    self._epoch=(self._epoch or 0)+1
    if self._start then UI:unschedule(self._start);self._start=nil end
    if self._remote then self._remote:cancel();self._remote=nil end
    if self._metadata then self._metadata:cancel();self._metadata=nil end
    if self._cover_cancel then self._cover_cancel();self._cover_cancel=nil end
end
function Dashboard:startPreviews()
    if not self:isTop()then return end
    local epoch=self._epoch
    self._preview_epoch_started=epoch
    local source=self.source
    local function alive()
        if self._epoch~=epoch or self._closed then return false end
        if self:isTop()then return true end
        self._preview_epoch_started=nil
        return false
    end
    local function covers()
        local index=0
        local function next_cover()
            if not alive()then return end
            index=index+1;local tile=self.tiles[index]
            if not tile then return end
            local comic=tile.comic;local sid=comic.source_id or source and source.identifier
            local item_source=source and source.identifier==sid and source or require("source.registry"):get(sid)
            local function ensure()
                if not alive()then return end
                local completed=false
                local cancel=Cover.ensure(item_source,sid,comic,function(path)
                    completed=true
                    if not alive()or tile._closed then return end
                    if tile:setPath(path)then
                        -- KOReader only paints dirty top-level windows. Repaint
                        -- through the dashboard so strip fades remain intact,
                        -- but refresh only the cover's physical screen region.
                        UI:setDirty(self,"ui",tile.dimen)
                    end
                    next_cover()
                end)
                if not completed then self._cover_cancel=cancel end
            end
            if Cover.find(sid,comic._id)or comic.thumb then ensure();return end
            if not item_source or not item_source.getComicDetail
                or not require("ui.common.source_access").check(item_source,nil,true)then next_cover();return end
            self._metadata=require("ui.common.loading_task").background(nil,function()
                local ok,detail=item_source:getComicDetail(comic._id)
                if not alive()then return end
                comic.thumb=ok and type(detail)=="table" and detail.thumb or nil
                ensure()
            end,{delay=.05,timeout=12,is_cancelled=function()return not alive()end,
                on_error=function()if alive()then next_cover()end end})
        end
        next_cover()
    end
    if (self._refresh_online or self.snapshot.pending)and self.shelves.favorites and not self.layout.hidden.favorites
        and require("ui.common.source_access").check(source,"favorites",true)then
        local scope=require("util.favorites").onlineScope(source)
        self._remote=require("ui.common.loading_task").background(nil,function()
            if not alive()then return end
            local ok,data,err=source:getFavorites(1)
            if not alive()then return end
            local current=require("util.favorites").onlineScope(source)
            if scope and(not current or current.generation~=scope.generation or current.key~=scope.key or current.revision~=scope.revision)then return end
            self._refresh_online=false
            if ok and type(data)=="table" and type(data.comics)=="table"then
                require("util.favorites").markAll(data)
                require("util.favorites").rememberOnline(source,data,scope)
                self.online=data.comics;self.online_data=data;self.online_error=nil
            else self.online=self.online or {};self.online_error=err or true end
            self.snapshot=nil;self:refreshData(false);UI:setDirty(self,"ui")
        end,{delay=.1,timeout=15,is_cancelled=function()return not alive()end,
            on_error=function(err)
                if not alive()then return end
                self._refresh_online=false;self.online=self.online or {};self.online_error=err;self.snapshot=nil;self:refreshData(false);UI:setDirty(self,"ui")
            end})
    end
    covers()
end
function Dashboard:onShow()
    self._closed=nil
    if self._unwatch then self._unwatch();self._unwatch=nil end
    if self.source and self.source.watchSession then
        self._unwatch=self.source:watchSession(function()
            if self._closed then return end
            local changed=self.owner and self.owner.refreshFavoritesLabel and self.owner:refreshFavoritesLabel()
            if not changed then self:refreshData(true)end
            if self:isTop()then UI:setDirty(self,"ui")end
        end)
    end
    self._start=function()self._start=nil;self:startPreviews()end
    UI:scheduleIn(.05,self._start)
end
function Dashboard:onSetDimensions()
    self.width=Screen:getWidth();self.height=Screen:getHeight()
    self.dimen=Geom:new{x=0,y=0,w=self.width,h=self.height}
    self:updateItems()
    require("ui.common.tap_guard").install(self,self.dimen)
    for _,ranges in pairs(self.ges_events or {})do
        for _,range in ipairs(ranges)do range.range=self.dimen end
    end
    self:updateTouchZonesOnScreenResize(self.dimen)
    if self:isTop()then self:onShow();UI:setDirty(self,"ui")end
end
function Dashboard:onCloseWidget()
    self._closed=true;self:suspend()
    if self._unwatch then self._unwatch();self._unwatch=nil end
end
return Dashboard
