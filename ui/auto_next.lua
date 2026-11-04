-- One automatic transition per reader instance. Failed/cancelled transitions
-- retain manual navigation; repeated end events never create a retry loop.
local M={}
function M.start(reader,valid,open)
    if not reader or require('util.config'):get('auto_next_chapter')~=true then return false end
    if reader._picayomi_auto_next then return true end
    reader._picayomi_auto_next=true
    local dispatched=false
    require('ui/uimanager'):nextTick(function()
        if dispatched then return end
        dispatched=true
        if valid() and require('util.config'):get('auto_next_chapter')==true then
            local ok,err=pcall(open)
            if not ok then require('ui.common.loading_task').showFailure(err)end
        end
    end)
    return true
end
return M
