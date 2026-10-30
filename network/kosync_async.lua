-- KOReader falls back to synchronous Spore requests without Turbo. Keep its
-- protocol and callbacks, but execute that fallback in the existing worker.
local M={}
local function same(a,b)
    if type(a)~=type(b)then return false end
    if type(a)~='table'then return a==b end
    for k,v in pairs(a)do if not same(v,b[k])then return false end end
    for k in pairs(b)do if a[k]==nil then return false end end
    return true
end

function M.attach(Client,Plugin,Queue,deps)
    if Client._picayomi_async then return end
    local UI=deps.ui
    local Async=deps.async
    local busy=false
    for _,operation in ipairs({'get_progress','update_progress'})do
        local original=Client[operation]
        Client[operation]=function(client,...)
            if UI.looper then return original(client,...)end
            local count=select('#',...)
            local args={...}
            local callback=args[count]
            args[count]=nil
            local reader=deps.reader()
            local request={kind='kosync',operation=operation,service_spec=client.service_spec,
                custom_url=client.custom_url,args=args,device_model=deps.device_model}
            local completed=false
            local function finish(ok,status,body)
                if completed then return end
                completed=true
                -- A pull for a closed document must never move a new reader.
                if operation=='get_progress' and deps.reader()~=reader then return end
                if operation=='get_progress'then callback(ok,body)
                else callback(ok,status,body)end
            end
            return Async.run(function()
                local response=Async.await(function()
                    return require('network.background_worker').request(request)
                end,request)
                finish(response.ok,response.status,response.body)
            end,{timeout=15,on_error=function()finish(false)end,on_cancel=function()finish(false)end})
        end
    end
    if Queue and type(Plugin.drainQueue)=='function'then
        local function load()
            -- Native load() returns {} on a read error. During an ACK that
            -- would turn a damaged/unreadable queue into an empty overwrite.
            if type(Queue._storage)=='function'then
                local storage=Queue:_storage()
                if storage:exists()then
                    local data=storage:load()
                    assert(type(data)=='table','同步队列读取失败')
                    return data
                end
            end
            return Queue:load()
        end
        Plugin.drainQueue=function(owner)
            if busy then return end
            local settings=owner.settings
            if not(settings and settings.username and settings.userkey)then return end
            local username,userkey,server=settings.username,settings.userkey,settings.custom_server
            local function current()
                return owner.settings==settings and settings.username==username
                    and settings.userkey==userkey and settings.custom_server==server
            end
            local loaded,pending=pcall(load)
            if not loaded or #pending==0 then return end
            local created,client=pcall(Client.new,Client,{service_spec=owner.path..'/api.json',custom_url=server})
            if not created then return end
            busy=true
            local index=1
            local step
            step=function()
                if not current() or index>#pending then busy=false;return end
                local item=pending[index]
                local ok=pcall(client.update_progress,client,username,userkey,item.document,
                    item.metadata,item.progress,item.percentage,item.device,item.device_id,
                    function(success)
                        if not success or not current()then busy=false;return end
                        -- Reload after the ACK: pushes may have replaced this record
                        -- or appended others while the network request was pending.
                        local saved=pcall(function()
                            local latest=load()
                            for i,entry in ipairs(latest)do
                                if same(entry,item)then table.remove(latest,i);break end
                            end
                            Queue:save(latest)
                            assert(same(load(),latest),'同步队列保存失败')
                        end)
                        if not saved then busy=false;return end
                        index=index+1
                        UI:scheduleIn(.05,step)
                    end)
                if not ok then busy=false end
            end
            UI:scheduleIn(.05,step)
        end
    end
    Client._picayomi_async=true
end

function M.install(reader)
    local UI=require('ui/uimanager')
    if UI.looper then return end
    local Loader=require('pluginloader')
    for _,plugin in ipairs(Loader.enabled_plugins or {})do
        if plugin.name=='kosync' and type(plugin.path)=='string'then
            local ok,Client=pcall(require,'KOSyncClient')
            if not ok or type(Client.get_progress)~='function' or type(Client.update_progress)~='function'then return end
            local queue_ok,Queue=pcall(require,'KOSyncQueue')
            M.attach(Client,plugin,queue_ok and Queue or nil,{ui=UI,async=require('network.async_task'),device_model=require('device').model,
                reader=function()return require('apps/reader/readerui').instance end})
            return
        end
    end
end
return M
