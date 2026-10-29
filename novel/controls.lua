-- PicaYomi reading actions on top of KOReader's native text reader.
local UI=require("ui/uimanager")
local Rules=require("ui.common.swipe_rules")
local Controls=require("ui/widget/container/inputcontainer"):extend{}
local M={}
function Controls:current()
    return not self.closed and require("apps/reader/readerui").instance==self.ui
end
function Controls:actions() return self.options.navigation(self.ui) end
function Controls:returnToDetails()
    if not self:current() or self.returning then return end
    self.returning=true
    self.ui._picayomi_return_notice=require("ui.common.loading_task").showReturning()
    self.return_task=function()
        self.return_task=nil
        if self:current()then
            local ok,err=pcall(self:actions()[1].callback)
            if not ok then self.returning=false;require("ui.common.loading_task").showFailure(err)end
        end
    end
    UI:scheduleIn(.01,self.return_task)
end
function Controls:addToMainMenu(items)
    if not self:current() then return end
    local actions=self:actions()
    items.picayomi,items.picayomi_novel,items.picayomi_save_image=nil,nil,nil
    items.picayomi_chapter_directory=nil
    local ids={"picayomi_return","picayomi_prev_episode","picayomi_next_episode"}
    for i,id in ipairs(ids) do
        local action=actions[i];items[id]=nil
        if action and action.enabled~=false then
            items[id]={text=i==1 and "返回 Picayomi" or action.text,sorting_hint="tools",callback=action.callback}
        end
    end
end
function Controls:onEndOfBook()
    if not self:current() then return false end
    if self.returning or self.end_dialog then return true end
    local next_chapter=self:actions()[3]
    if next_chapter and next_chapter.pending then
        UI:show(require("ui/widget/infomessage"):new{text=next_chapter.pending=="loading"and "章节目录仍在后台加载，请稍候。"or "章节目录加载失败，请返回详情重试。",timeout=3},"ui")
        return true
    end
    if next_chapter and next_chapter.enabled~=false then
        self.end_dialog=require("ui.common.action_style").ConfirmBox:new{
            is_picayomi_page=true,
            text="当前章节已结束，是否继续阅读下一章节？\n\n"..next_chapter.text,
            ok_text="继续阅读",cancel_text="返回",
            ok_callback=function()
                self.end_dialog=nil
                UI:nextTick(function()if self:current() then next_chapter.callback() end end)
            end,
            cancel_callback=function()self.end_dialog=nil;self:returnToDetails()end,
        }
        UI:show(self.end_dialog,"ui")
    else
        self:returnToDetails()
        UI:nextTick(function()UI:show(require("ui/widget/infomessage"):new{text="已到最后一章",timeout=2},"ui")end)
    end
    return true
end
function Controls:onCloseDocument()
    self.closed=true
    if self.return_task then UI:unschedule(self.return_task);self.return_task=nil end
    if self.end_dialog then UI:close(self.end_dialog,"ui");self.end_dialog=nil end
    self.ui._picayomi_novel_controls=nil
    if self.ui.handleEvent==self.event_handler then self.ui.handleEvent=self.original_event_handler end
    local undo=self.sync_undo
    UI:nextTick(function()for _,restore in ipairs(undo or {}) do restore() end end)
end
function M.install(ui,options)
    if not options.navigation then return end
    local self=Controls:new{ui=ui,options=options,sync_undo={}}
    ui:registerModule("picayomi_novel_controls",self)
    -- ReaderUI paints its first child (ReaderView). Preserve that order and
    -- route only EndOfBook before the host's generic file-browser dialog.
    self.original_event_handler=ui.handleEvent
    self.event_handler=function(instance,event,...)
        if event.handler=="onEndOfBook" and self:current() then return self:onEndOfBook() end
        return self.original_event_handler(instance,event,...)
    end
    ui.handleEvent=self.event_handler
    ui._picayomi_novel_controls=self
    ui.menu:registerToMainMenu(self)
    if require("device"):isTouchDevice() then
        local zone={ratio_x=0,ratio_y=0,ratio_w=1,ratio_h=1}
        ui:registerTouchZones{
            {id="picayomi_novel_edge_swipe",ges="swipe",screen_zone=zone,
                overrides={"rolling_swipe","paging_swipe","swipe_link"},handler=function(ges)
                    if Rules.isBackSwipe(ges) then self:returnToDetails();return true end
                    return false
                end},
            {id="picayomi_novel_edge_pan",ges="pan",screen_zone=zone,
                overrides={"rolling_pan"},handler=function(ges)
                    self.back_pan=Rules.isBackPan(ges);return self.back_pan or false
                end},
            {id="picayomi_novel_edge_pan_release",ges="pan_release",screen_zone=zone,
                overrides={"rolling_pan_release"},handler=function(ges)
                    local back=self.back_pan or Rules.isBackPan(ges);self.back_pan=nil
                    if back then self:returnToDetails();return true end
                    return false
                end},
        }
    end
    -- Keep automatic Readest sync from moving temporary chapter documents or
    -- blocking their close on a network request. Manual sync remains available.
    for _,child in ipairs(ui) do
        if child.name=="readerreadest" or child.name=="readest" then
            for _,name in ipairs({"pullBookConfig","pushBookConfig","pushBookNotes","pushBookStats","pushOpenBook"}) do
                local original=child[name]
                if type(original)=="function" then
                    child[name]=function(instance,interactive,...)
                        if interactive then return original(instance,interactive,...) end
                    end
                    self.sync_undo[#self.sync_undo+1]=function()child[name]=original end
                end
            end
        end
    end
    return self
end
return M
