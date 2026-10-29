-- Optional native ReaderUI gesture; PicaYomi sessions retain their own origin.
local UI=require('ui/uimanager')
local Device=require('device')
local Rules=require('ui.common.swipe_rules')
local Config=require('util.config')
local Event=require('ui/event')
local Listener=require('ui/widget/container/inputcontainer'):extend{}
local M={}
function Listener:eligible()
    local reader=self.ui
    if self.closed or not reader or require('apps/reader/readerui').instance~=reader
        or not Config:get('native_reader_edge_back',false)then return false end
    if reader._picayomi_novel_controls or reader.document and reader.document.provider=='picayomi_stream'then return false end
    if reader.highlight and(reader.highlight.hold_pos or reader.highlight.select_mode)then return false end
    local stack=UI._window_stack;local top=stack and stack[#stack]and stack[#stack].widget
    return top~=nil and(top==reader or top==reader.dialog or self.notice and top==self.notice)
end
function Listener:back()
    if self.returning or not self:eligible()then return end
    self.returning=true
    self.notice=require('ui.common.loading_task').showReturning()
    self.return_task=function()
        self.return_task=nil
        local reader=self.ui
        if self:eligible()then
            local ok,err=pcall(reader.handleEvent,reader,Event:new('Home'))
            if not ok then require('ui.common.loading_task').showFailure(err)end
        end
        if self.notice then UI:close(self.notice,'ui');self.notice=nil end
        self.returning=false
    end
    UI:scheduleIn(.01,self.return_task)
end
function Listener:onCloseDocument()
    if self.closed then return end
    self.closed=true
    if self.return_task then UI:unschedule(self.return_task);self.return_task=nil end
    if self.notice then UI:close(self.notice,'ui');self.notice=nil end
    local reader=self.ui
    if reader then
        reader:unRegisterTouchZones(self.zones)
        if reader._picayomi_native_edge==self then reader._picayomi_native_edge=nil end
    end
    self.ui=nil;self.zones=nil
end
Listener.onCloseWidget=Listener.onCloseDocument
function M.install(reader)
    if not Device:isTouchDevice()or reader._picayomi_native_edge then return end
    local self=Listener:new{ui=reader}
    local zone={ratio_x=0,ratio_y=0,ratio_w=1,ratio_h=1}
    local swipe={'rolling_swipe','paging_swipe','swipe_link','short_diagonal_swipe'}
    local pan={'rolling_pan','paging_pan'};local release={'rolling_pan_release','paging_pan_release'}
    for _,name in ipairs{'one_finger_swipe_top_edge_right','one_finger_swipe_top_edge_left','one_finger_swipe_bottom_edge_right','one_finger_swipe_bottom_edge_left'}do
        swipe[#swipe+1]=name;pan[#pan+1]=name..'_pan';release[#release+1]=name..'_pan_release'
    end
    self.zones={
        {id='picayomi_native_edge_swipe',ges='swipe',screen_zone=zone,overrides=swipe,handler=function(ges)
            if self:eligible()and Rules.isBackSwipe(ges,true)then self:back();return true end
            return false
        end},
        {id='picayomi_native_edge_pan',ges='pan',screen_zone=zone,overrides=pan,handler=function(ges)
            return self:eligible()and Rules.isBackPan(ges,true)or false
        end},
        {id='picayomi_native_edge_release',ges='pan_release',screen_zone=zone,overrides=release,handler=function(ges)
            if self:eligible()and Rules.isBackPan(ges,true)then
                if math.abs(ges.pos.x-ges.start_pos.x)>=Device.screen:scaleBySize(24)then self:back()end
                return true
            end
            return false
        end},
    }
    reader:registerModule('picayomi_native_edge',self)
    reader:registerTouchZones(self.zones)
    reader._picayomi_native_edge=self
    return self
end
return M
