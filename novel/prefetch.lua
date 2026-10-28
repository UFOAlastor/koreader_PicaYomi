-- Shared setting boundary; reading sessions subscribe without polling config.
local M={listeners=setmetatable({},{__mode="k"})}
function M.count()
    local n=tonumber(require("util.config"):get("novel_prefetch_chapters",1))
    if not n or n~=n then n=1 end
    return math.max(0,math.min(5,math.floor(n)))
end
function M.watch(callback)
    local key={};M.listeners[key]=callback
    return function()M.listeners[key]=nil end
end
function M.changed()
    for _,callback in pairs(M.listeners)do
        local ok=pcall(callback)
        if not ok then require("util.logger").warn("Picayomi: 小说预加载设置通知失败")end
    end
end
return M
