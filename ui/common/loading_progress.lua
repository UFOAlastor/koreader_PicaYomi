-- Reusable loading dialog: measured work, indeterminate wait, elapsed time and cancel.
local Info=require("ui/widget/infomessage")
local UI=require("ui/uimanager")
local socket=require("socket")
local Progress=Info:extend{show_icon=false,alignment="left",dismissable=true,unmovable=true}
-- update{message="正在下载",completed=2,total=5}; omit total for unknown duration.
function Progress:description()
    local p=self.progress or {}
    local message=p.message or "正在加载…"
    if type(p.total)=="number" and p.total>0 and type(p.completed)=="number" then
        local done=math.max(0,math.min(p.completed,p.total))
        return message..string.format(" · %d / %d",done,p.total),done/p.total
    end
    return message,nil
end
function Progress:init()
    self.started=self.started or socket.gettime()
    self.progress=self.progress or {stage="body"}
    local status,ratio=self:description()
    self.determinate=ratio~=nil
    self.text=(self.title or self.chapter_title or "正在加载").."\n"..status.."\n已等待 "..math.floor(socket.gettime()-self.started).." 秒\n轻触取消"
    Info.init(self)
    local frame=self.movable[1]
    self.bar=require("ui/widget/progresswidget"):new{
        width=math.floor(require("device").screen:getWidth()*.6),
        height=require("device").screen:scaleBySize(10),
        percentage=ratio or 0,
    }
    frame[1]=require("ui/widget/verticalgroup"):new{
        align="center",frame[1],require("ui/widget/verticalspan"):new{width=require("device").screen:scaleBySize(12)},self.bar,
    }
    if not self.determinate then
        local paint=self.bar.paintTo
        local elapsed=math.floor(socket.gettime()-self.started)
        self.bar.paintTo=function(bar,bb,x,y)
            paint(bar,bb,x,y)
            local inset=bar.margin_h+bar.bordersize
            local width=bar.width-2*inset
            local segment=math.floor(width*.22)
            local offset=math.floor((width-segment)*(elapsed%5)/4)
            bb:paintRect(x+inset+offset,y+bar.margin_v+bar.bordersize,segment,
                bar.height-2*(bar.margin_v+bar.bordersize),require("ffi/blitbuffer").COLOR_DARK_GRAY)
        end
    end
    if self.covers_fullscreen then self.movable.unmovable=true end
end
function Progress:update(progress)
    if self.closed then return end
    local old=self.movable.dimen and self.movable.dimen:copy()
    if progress then self.progress=progress end
    self:free();self:init()
    local screen=require("device").screen
    local size=self.movable:getSize()
    local area=require("ui/geometry"):new{
        x=math.floor((screen:getWidth()-size.w)/2),y=math.floor((screen:getHeight()-size.h)/2),w=size.w,h=size.h}
    if old then area=area:combine(old)end
    -- Repaint the old outline as well when a new phase changes dialog height.
    UI:setDirty("all","ui",area)
end
function Progress:onShow()
    Info.onShow(self)
    self.refresh_tick=function()
        if self.closed then return end
        self:update()
        UI:scheduleIn(1,self.refresh_tick)
    end
    UI:scheduleIn(1,self.refresh_tick)
end
function Progress:onCloseWidget()
    self.closed=true
    if self.refresh_tick then UI:unschedule(self.refresh_tick)end
    return Info.onCloseWidget(self)
end
function Progress:paintTo(bb,x,y)
    if self.covers_fullscreen then
        local screen=require("device").screen
        bb:paintRect(0,0,screen:getWidth(),screen:getHeight(),require("ffi/blitbuffer").COLOR_WHITE)
    end
    Info.paintTo(self,bb,x,y)
end
function Progress:getVisibleArea()
    if self.covers_fullscreen then return require("device").screen:getSize()end
    return self.movable.dimen
end
return Progress
