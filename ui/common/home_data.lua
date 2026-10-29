-- Home previews read the same identities/order as their destination lists.
-- Remote favorites stay in this page's memory, never in the local shelf.
local M={}
function M.take(items,limit)
    local result={}
    for i=1,math.min(#(items or {}),limit)do result[i]=items[i]end
    return result,#(items or {})>limit
end
function M.snapshot(source,model,limit,online)
    local sid=source and source.identifier or "unknown"
    local backend=require("util.favorites").backend(source)
    local favorites=backend=="online" and online or backend=="local" and require("util.local_favorites").list(sid) or {}
    local history={}
    for _,item in ipairs(model:getHistory(sid) or {})do
        history[#history+1]={_id=item.id,title=item.title,thumb=item.thumb,source_id=sid,
            content_type=item.content_type or source and source.content_type,_history=item}
        if #history>=limit+1 then break end
    end
    local kind=source and source.content_type=="novel" and "novel" or "comic"
    local downloads=require("util.offline_library").preview(kind,limit+1)
    local result={backend=backend,pending=backend=="online" and online==nil}
    for id,items in pairs({favorites=favorites or {},history=history,downloads=downloads})do
        local taken,more=M.take(items,limit)
        result[id]={items=taken,more=more}
    end
    return result
end
return M
