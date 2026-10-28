-- Experimental prepared-HTML reader. Network preparation is a separate step.
-- This does not install comic paging/zoom/export hooks on a rolling document.
-- Leave typography to ReaderFont: KOReader defaults, installed fonts and native
-- per-document settings. Do not override the font or maintain a second font list.
local Document=require("novel.document")
local M={}
function M.open(prepared,options)
    options=options or {}
    assert(Document.load(prepared.root,prepared.key,prepared.generation),"incomplete novel document")
    prepared=require("novel.filters").document(prepared,options.source)
    local Reader=require("apps/reader/readerui")
    local function ready(ui)
        assert(ui.rolling and ui.document,"HTML did not open in text reader")
        ui._picayomi_content_type="novel"
        local Diag=require("util.diag")
        if Diag.enabled then
            local clock=require("socket").gettime
            local samples,slowest,total=0,0,0
            local turn=ui.rolling.onGotoViewRel
            ui.rolling.onGotoViewRel=function(rolling,...)
                local started=clock()
                local result=turn(rolling,...)
                local elapsed=clock()-started
                samples=samples+1;total=total+elapsed;slowest=math.max(slowest,elapsed)
                if elapsed>=.15 then Diag.mark(string.format("novel turn slow %.3fs",elapsed))end
                return result
            end
        end
        local close=ui.onClose
        ui.onClose=function(reader,...)
            if reader._picayomi_novel_closing then return true end
            reader._picayomi_novel_closing=true
            local UI=require("ui/uimanager")
            local notice
            if not (options.is_switching and options.is_switching()) then
                notice=require("ui.common.loading_task").showReturning()
            end
            local started=require("socket").gettime()
            local ok,result=pcall(close,reader,...)
            if notice then UI:close(notice,"ui")end
            reader._picayomi_novel_closing=nil
            if Diag.enabled then Diag.mark(string.format("novel close %.3fs",require("socket").gettime()-started))end
            if not ok then error(result,0)end
            return result
        end
        require("novel.controls").install(ui,options)
        local saved=not options.from_beginning and Document.position(prepared)
        if saved then ui.rolling:onGotoXPointer(saved)
        else ui.rolling:onGotoPage(1) end
        local Listener=require("ui/widget/container/inputcontainer"):extend{}
        local function save()
            local pointer=ui.document and ui.document:getXPointer()
            if pointer then
                local saved_ok=pcall(Document.savePosition,prepared,pointer)
                if not saved_ok then
                    ui._picayomi_novel_position_error=true
                    require("util.logger").warn("Picayomi: 小说阅读位置保存失败，保留上次位置")
                end
            end
            if options.on_position then
                local ok=pcall(options.on_position,ui)
                if not ok then require("util.logger").warn("Picayomi: 小说历史记录保存失败，保留文本定位") end
            end
        end
        function Listener:onSuspend() save() end
        function Listener:onCloseDocument()
            save()
            if options.on_close and not (options.is_switching and options.is_switching()) then
                require("ui/uimanager"):nextTick(function() options.on_close(ui) end)
            end
        end
        local listener=Listener:new{}
        ui:registerModule("picayomi_novel_position",listener)
        if options.ready then options.ready(ui) end
    end
    local current=Reader.instance
    if current then current:switchDocument(prepared.path,true,ready)
    else Reader:showReader(prepared.path,nil,nil,nil,ready) end
end
return M
