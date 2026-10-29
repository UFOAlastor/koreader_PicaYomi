-- Add an action only to image viewers opened by this novel Reader instance.
local UI=require("ui/uimanager")
local M={}
local function close(widget)
    if widget and UI:isWidgetShown(widget)then UI:close(widget,"ui")end
end
local function encoded(document,pos)
    local ffi=require("ffi")
    local data,size=document._document:getImageDataFromPosition(pos.x,pos.y,false)
    if not data or data==ffi.NULL then return nil,"无法读取当前插图"end
    local ok,bytes=pcall(function()
        assert(type(size)=="number"and size>0 and size<=4*1024*1024,"插图数据超过保存限制")
        return ffi.string(data,size)
    end)
    ffi.C.free(data)
    if not ok then return nil,"无法读取插图，或图片超过保存限制"end
    return bytes
end
function M.install(ui,title)
    local highlight=ui.highlight
    if not highlight or not highlight.onHold then return end
    local original=highlight.onHold
    local state={viewers={},document=ui.document}
    local function current(viewer)
        return not state.closed and require("apps/reader/readerui").instance==ui
            and ui.document==state.document and UI:isWidgetShown(viewer)
    end
    local function cleanup(record)
        if record.task then record.task:cancel();record.task=nil end
        if record.chooser then close(record.chooser.button_dialog)end
        close(record.chooser);close(record.message)
        record.chooser=nil;record.message=nil
    end
    local function choose(viewer,record,pos)
        if not current(viewer)or record.task or record.chooser then return end
        local Config=require("util.config")
        local path=Config:get("comic_image_save_dir")
        if type(path)~="string"or require("libs/libkoreader-lfs").attributes(path,"mode")~="directory"then
            path=require("apps/filemanager/filemanagerutil").getHomeFolder()
        end
        local chooser=require("ui/widget/pathchooser"):new{
            title="保存插图：长按选择文件夹",path=path,select_directory=true,select_file=false,show_files=false,
            onConfirm=function(directory)
                record.chooser=nil
                if not current(viewer)then return end
                local Loading=require("ui.common.loading_task")
                local notice=require("ui/widget/infomessage"):new{text="正在保存插图…"}
                UI:show(notice,"ui");UI:forceRePaint()
                record.task=Loading.background(notice,function()
                    if not current(viewer)then return end
                    local bytes,err=encoded(state.document,pos)
                    local target
                    if bytes then target,err=require("util.comic_image").saveIllustration(bytes,title,directory)end
                    Loading.close(notice);record.task=nil
                    if not current(viewer)then return end
                    local text=target and "插图已保存到：\n"..target or "保存插图失败：\n"..tostring(err)
                    if target and not Config:set("comic_image_save_dir",directory)then text=text.."\n保存目录未能记住，下次请重新选择。"end
                    record.message=require("ui/widget/infomessage"):new{text=text}
                    UI:show(record.message,"ui")
                end,{delay=.05,is_cancelled=function()return not current(viewer)end,
                    on_cancel=function()record.task=nil end,
                    on_error=function(err)
                        record.task=nil
                        if current(viewer)then
                            record.message=require("ui/widget/infomessage"):new{text="保存插图失败，请检查目录或存储空间。"}
                            UI:show(record.message,"ui")
                        end
                    end})
            end,
        }
        record.chooser=chooser
        local old_close=chooser.onCloseWidget
        chooser.onCloseWidget=function(self,...)
            if record.chooser==self then record.chooser=nil end
            if old_close then return old_close(self,...)end
        end
        UI:show(chooser,"ui")
    end
    local function decorate(viewer,pos)
        if state.viewers[viewer]then return end
        local record={};state.viewers[viewer]=record
        local old_close=viewer.onCloseWidget
        viewer.onCloseWidget=function(self,...)
            cleanup(record);state.viewers[self]=nil
            return old_close(self,...)
        end
        local old=viewer.button_table
        local buttons=old.buttons
        table.insert(buttons[1],#buttons[1],{id="picayomi_save",text="保存插图",callback=function()choose(viewer,record,pos)end})
        viewer.button_table=require("ui/widget/buttontable"):new{width=old.width,buttons=buttons,zero_sep=true,show_parent=viewer}
        viewer.button_container[1]=viewer.button_table
        viewer.button_container.dimen.h=viewer.button_table:getSize().h
        old:free()
        viewer.buttons_visible=true;viewer:update()
    end
    state.hold=function(self,arg,ges)
        local pos=ges and ges.pos and ui.view:screenToPageTransform(ges.pos)
        local before=UI._window_stack[#UI._window_stack]
        local result=original(self,arg,ges)
        local top=UI._window_stack[#UI._window_stack]
        if pos and top and top~=before and not state.closed
            and getmetatable(top.widget)==require("ui/widget/imageviewer")then decorate(top.widget,pos)end
        return result
    end
    highlight.onHold=state.hold
    function state:close()
        self.closed=true
        if highlight.onHold==self.hold then highlight.onHold=original end
        local viewers={};for viewer in pairs(self.viewers)do viewers[#viewers+1]=viewer end
        for _,viewer in ipairs(viewers)do cleanup(self.viewers[viewer]);close(viewer)end
        self.viewers={};self.document=nil
    end
    return state
end
return M
