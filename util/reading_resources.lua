-- Foreground reading temporarily owns the network/memory budget. Returning a
-- single release callback preserves the session's existing cleanup contract.
local Resources = {}
function Resources.pause()
    local release_downloads=require("util.download_queue").instance():pause("reading")
    local ok,release_covers=pcall(function() return require("util.cover_cache").pause() end)
    if not ok then release_downloads();error(release_covers) end
    local released=false
    return function()
        if released then return end
        released=true
        release_covers()
        release_downloads()
    end
end
return Resources
