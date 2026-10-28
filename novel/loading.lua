-- Chapter-specific labels over the shared progress component.
local Progress=require("ui.common.loading_progress"):extend{}
function Progress:description()
    local p=self.progress or {}
    if p.stage=="images" then
        if p.total==0 then return "正文已就绪 · 无插图",1 end
        return string.format("正文已就绪 · 插图 %d / %d",p.current,p.total),p.current/p.total
    elseif p.stage=="commit" then return "图文已就绪 · 正在校验保存…",1
    elseif p.stage=="ready" then return "章节已就绪 · 正在打开…",1 end
    return "正在获取正文…",nil
end
return Progress
