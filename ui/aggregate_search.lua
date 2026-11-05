-- Aggregated results retain the shared list's paging, gestures and navigation.
local List=require("ui.common.visual_comic_list")
local UI=require("ui/uimanager")
local Result=List:extend{}
function Result:init()
    self.has_more=false;self.total_pages=1;self.total_count=#self.comics
    self.fetch_page=nil;self.sort_options={}
    local summary=self.batch:summary()
    self.extra_buttons={
        {text="重试未完成",enabled=summary.failed>0,callback=function()
            self:showRetry()
        end},
    }
    List.init(self)
    if #self.comics==0 then
        local message=summary.total==0 and "没有可搜索的同类来源"
            or summary.failed>0 and "暂未取得结果，可重试未完成来源"or "没有找到匹配的作品"
        local group=self[1][1]
        local height=self.height-group[1]:getSize().h-group[3]:getSize().h
        self.list_view:free();self.list_view=nil
        group[2]=require("ui/widget/container/centercontainer"):new{
            dimen=require("ui/geometry"):new{w=self.width,h=math.max(1,height)},
            require("ui/widget/textboxwidget"):new{text=message,width=math.floor(self.width*.8),
                face=require("ui/font"):getFace("cfont",20),alignment="center"},
        }
        group:resetLayout()
    end
end
function Result:showRetry()
    if self._closed or self.retry_dialog or self.batch:summary().failed==0 then return end
    local lines={"已保留取得的结果，将重试以下未完成来源："}
    for _,source in ipairs(self.batch.sources)do
        local state=self.batch.states[source.identifier]
        if state.status~="complete"then
            lines[#lines+1]=(source.name or source.identifier).."："..(state.error or "未完成")
        end
    end
    local dialog,finished
    dialog=require("ui.common.action_style").ConfirmBox:new{
        is_picayomi_page=true,text=table.concat(lines,"\n"),ok_text="重试",cancel_text="取消",
        ok_callback=function()
            if finished or self._closed then return end
            finished=true
            if self.retry_search then self.retry_search()end
        end,
    }
    local close=dialog.onCloseWidget
    dialog.onCloseWidget=function(widget)
        finished=true
        if self.retry_dialog==widget then self.retry_dialog=nil end
        if close then return close(widget)end
    end
    self.retry_dialog=dialog
    UI:show(dialog,"ui")
end
function Result:onCloseWidget()
    List.onCloseWidget(self)
    if self.retry_dialog then UI:close(self.retry_dialog,"ui");self.retry_dialog=nil end
end
return Result
