-- Check catalogs on idle home. Package downloads require an explicit choice.
local U={generation=0,asked={},notified={}}
local UI=require("ui/uimanager")
local logger=require("util.logger")
local function shownHome()
    local Home=package.loaded["ui.home"]
    return Home and Home.findShownMenu()
end
local function idle()
    local top=UI._window_stack and UI._window_stack[#UI._window_stack]
    if not top or top.widget~=shownHome() then return false end
    local Queue=package.loaded["util.download_queue"]
    return not Queue or not Queue.instance():is_active()
end
local function manager() return require("source.extensions.manager").instance() end
local function due(m)
    for url in pairs(m.state.repositories) do if m:due(url) then return true end end
    return false
end
local function pending(m)
    local out={}
    for id,r in pairs(m.state.sources) do
        if r.pending and r.pending~=r.active then out[#out+1]={id=id,hash=r.pending} end
    end
    return out
end
function U.acknowledgePending()
    for _,r in ipairs(pending(manager())) do U.notified[r.id]=r.hash end
end
local function unnotified(m)
    local n=0
    for _,r in ipairs(pending(m)) do if U.notified[r.id]~=r.hash then n=n+1 end end
    return n
end
local function candidates(m)
    local out,seen={},{}
    local urls={};for url in pairs(m.state.repositories) do urls[#urls+1]=url end;table.sort(urls)
    for _,url in ipairs(urls) do
        for _,entry in ipairs(m.state.repositories[url].sources or {}) do
            if not seen[entry.id] and m.state.sources[entry.id] then
                local c=m:candidate(url,entry.id)
                if c.code=="update" and c.entry and U.asked[entry.id]~=c.entry.sha256 then
                    seen[entry.id]=true
                    out[#out+1]={url=url,id=entry.id,name=c.entry.name or entry.id,
                        version=c.entry.version,hash=c.entry.sha256}
                end
            end
        end
    end
    table.sort(out,function(a,b) return a.id<b.id end)
    return out
end
local function refresh() UI:setDirty(nil,"full") end
local function notify(m)
    if not idle() or U.prompt or U.downloading then return end
    local available=m.state.auto_check and candidates(m) or {}
    if #available>0 then
        local lines={"发现 "..#available.." 个漫画源有更新，是否下载？"}
        for _,r in ipairs(available) do
            lines[#lines+1]=r.name.." "..r.version
            U.asked[r.id]=r.hash
        end
        local waiting=#pending(m)
        if waiting>0 then
            lines[#lines+1]="另有 "..waiting.." 个源已下载，等待重启。"
            U.acknowledgePending()
        end
        local prompt=require("ui.common.action_style").ConfirmBox:new{
            is_picayomi_page=true,text=table.concat(lines,"\n"),
            ok_text="下载更新",cancel_text="稍后",
            ok_callback=function()
                if U.downloading then return end
                U.downloading=true
                local generation=U.generation
                UI:nextTick(function()
                    if generation~=U.generation then U.downloading=false;return end
                    local ok,err=pcall(U.downloadUpdates,m,available)
                    if not ok then U.downloading=false;require("ui.common.loading_task").showFailure(err) end
                end)
            end,
        }
        local close=prompt.onCloseWidget
        prompt.onCloseWidget=function(self)
            if U.prompt==self then U.prompt=nil end
            close(self);refresh()
        end
        U.prompt=prompt
        if logger.enabled then logger.info("Picayomi source check: consent requested",#available) end
        UI:show(prompt,"full");refresh()
        return
    end
    local count=unnotified(m)
    if count>0 then
        local text="已下载 "..#pending(m).." 个漫画源更新，重启 KOReader 后生效"
        if U.error then text=text.."\n另有更新未完成："..require("ui.common.error_message").describe(U.error) end
        U.error=nil
        require("ui.settings.sources"):offerRestart(text)
        refresh()
    elseif U.error then
        local err=U.error;U.error=nil
        require("ui.settings.sources"):showInfo("检查或下载更新未完成："
            ..require("ui.common.error_message").describe(err).."\n可在源管理中手动重试。")
    end
end
function U.downloadUpdates(m,available)
    if logger.enabled then logger.info("Picayomi source check: download confirmed",#available) end
    U.download=require("ui.common.loading_task").run{
        message="正在下载漫画源更新…\n点击取消",async=true,delay=.1,timeout=180,
        set_busy=function(value) U.downloading=value;if not value then U.download=nil end end,
        fetch=function()
            local stats={updated=0,failed=0,skipped=0}
            for _,r in ipairs(available) do
                local status=m:candidate(r.url,r.id)
                if status.code=="latest" then stats.skipped=stats.skipped+1
                elseif status.code~="update" or not status.entry or status.entry.sha256~=r.hash then
                    stats.failed=stats.failed+1;stats.error="可用版本已变化，请重新检查"
                else
                    local ok,err=pcall(m.installFromRepository,m,r.url,r.id,false)
                    if ok then stats.updated=stats.updated+1
                    else stats.failed=stats.failed+1;stats.error=err end
                end
            end
            return true,stats
        end,
        on_cancel=function()
            if logger.enabled then logger.info("Picayomi source check: download cancelled",#pending(m)) end
            refresh();U.schedule()
        end,
        on_done=function(ok,stats,err)
            if logger.enabled then logger.info("Picayomi source check: download result",ok,stats and stats.updated or 0,stats and stats.failed or 0) end
            U.error=ok and stats and stats.error or err
            if ok and stats and stats.updated>0 then
                for _,r in ipairs(pending(m)) do U.notified[r.id]=nil end
            elseif ok and stats and stats.failed==0 and #pending(m)==0 then
                require("ui.settings.sources"):showInfo("漫画源已是最新，无需下载")
                refresh();return
            end
            notify(m);U.schedule()
        end,
    }
end
function U.cancel()
    U.stopping=true
    U.generation=U.generation+1
    if U.start then UI:unschedule(U.start);U.start=nil end
    if U.task then U.task:cancel();U.task=nil end
    if U.download then local task=U.download;U.download=nil;task:cancel() end
    U.downloading=false
    if U.prompt then UI:close(U.prompt,"ui") end
    U.stopping=false
end
function U.schedule()
    if U.stopping then return end
    local m=manager()
    if U.start or U.prompt or U.downloading or U.task and not U.task.done then return end
    local notices=unnotified(m)>0 or U.error~=nil
        or m.state.auto_check and #candidates(m)>0
    if not notices and not due(m) then return end
    local generation=U.generation
    local function start()
        U.start=nil
        if generation~=U.generation or not shownHome() then return end
        if not idle() then U.start=start;UI:scheduleIn(1,start);return end
        local current=manager()
        if not current.state.auto_check or not due(current) then notify(current);return end
        local ok,network=pcall(require,"ui/network/manager")
        if not ok or not network:isConnected() then
            notify(current)
            if not U.prompt then U.start=start;UI:scheduleIn(5,start) end
            return
        end
        if current.state_error then return end
        if logger.enabled then logger.info("Picayomi source check: catalog start") end
        U.task=require("network.async_task").run(function()
            local errors={}
            local urls={};for url in pairs(current.state.repositories) do urls[#urls+1]=url end;table.sort(urls)
            for _,url in ipairs(urls) do
                if current:due(url) then
                    local refreshed,reason=pcall(current.refreshRepository,current,url)
                    if not refreshed then errors[#errors+1]=reason end
                end
            end
            U.error=errors[1]
            if logger.enabled then logger.info("Picayomi source check: catalog done",#candidates(current),#errors) end
            notify(current)
            if not idle() and not U.prompt then U.task=nil;U.schedule() end
        end,{
            is_cancelled=function() return generation~=U.generation or not idle() end,
            on_cancel=function()
                if logger.enabled then logger.info("Picayomi source check: catalog deferred") end
                if generation==U.generation then U.task=nil;U.schedule() end
            end,
            on_error=function(err)
                logger.warn("Picayomi source check: "..tostring(err))
                U.error=err;U.task=nil;notify(current)
                if not idle() then U.schedule() end
            end,
        })
    end
    U.start=start;UI:scheduleIn(.5,start)
end
return U
