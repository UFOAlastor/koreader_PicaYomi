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
    local manager=require("source.extensions.manager").instance()
    if not manager.state.auto_check or U.checked then return end
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
            local updated,errors=0,{}
            local urls={}; for url in pairs(m.state.repositories) do urls[#urls+1]=url end; table.sort(urls)
            for _,url in ipairs(urls) do
                if generation~=U.generation or not idle() then return end
                local refreshed,reason=true,nil
                if m:due(url) then refreshed,reason=pcall(m.refreshRepository,m,url) end
                if not refreshed then errors[#errors+1]=reason end
                local repo=m.state.repositories[url]
                if refreshed and repo and repo.public_key and m.state.auto_check and idle() then
                    local results=m:updateAll(url,true)
                    for _,result in ipairs(results) do
                        if result.ok then updated=updated+1
                        else
                            require("util.logger").warn("Picayomi automatic source update failed",result.id,result.error)
                            errors[#errors+1]=result.error or "源更新失败"
                        end
                    end
                end
            end
            U.checked=true
            if updated>0 and idle() then
                local message="已自动更新 "..updated.." 个漫画源，重启 KOReader 后生效"
                if #errors>0 then
                    message=message.."\n另有更新未完成："..require("ui.common.error_message").describe(errors[1])
                end
                require("ui.settings.sources"):offerRestart(message)
            elseif #errors>0 and idle() then
                require("ui.settings.sources"):showInfo("自动检查或更新未完成："
                    ..require("ui.common.error_message").describe(errors[1]).."\n可在订阅管理中手动重试。")
            end
        end,{is_cancelled=function() return generation~=U.generation or not idle() end,
            on_error=function(err)
                require("util.logger").warn("Picayomi source update: "..tostring(err))
                if generation==U.generation and idle() then
                    require("ui.settings.sources"):showInfo("自动检查或更新未完成："
                        ..require("ui.common.error_message").describe(err).."\n可在订阅管理中手动重试。")
                end
            end})
    end
    require("ui/uimanager"):scheduleIn(0.5,U.start)
end
return U
