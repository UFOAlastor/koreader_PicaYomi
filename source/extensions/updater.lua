-- One cancellable update lane. Never wakes Wi-Fi or runs from the page-turn path.
local U={generation=0}
local function idle()
    local Home=package.loaded["ui.home"]
    local menu=Home and Home.findShownMenu()
    local UI=require("ui/uimanager")
    local top=UI._window_stack and UI._window_stack[#UI._window_stack]
    if not menu or not top or top.widget~=menu then return false end
    local Queue=package.loaded["util.download_queue"]
    if Queue and Queue.instance():is_active() then return false end
    return true
end
function U.cancel()
    U.generation=U.generation+1
    if U.start then require("ui/uimanager"):unschedule(U.start); U.start=nil end
    if U.task then U.task:cancel(); U.task=nil end
end
function U.schedule()
    U.cancel()
    local generation=U.generation
    U.start=function()
        U.start=nil
        if generation~=U.generation or not idle() then return end
        local ok,network=pcall(require,"ui/network/manager")
        if not ok or not network:isConnected() then return end
        local m=require("source.extensions.manager").instance()
        if m.state_error then return end
        U.task=require("network.async_task").run(function()
            local urls={}; for url in pairs(m.state.repositories) do urls[#urls+1]=url end; table.sort(urls)
            for _,url in ipairs(urls) do
                if generation~=U.generation or not idle() then return end
                if m:due(url) then
                    local refreshed=pcall(m.refreshRepository,m,url)
                    local repo=m.state.repositories[url]
                    if refreshed and repo and repo.auto_install and idle() then m:updateAll(url,true) end
                end
            end
        end,{is_cancelled=function() return generation~=U.generation or not idle() end,
            on_error=function(err) require("util.logger").warn("Picayomi source update: "..tostring(err)) end})
    end
    require("ui/uimanager"):scheduleIn(0.5,U.start)
end
return U
