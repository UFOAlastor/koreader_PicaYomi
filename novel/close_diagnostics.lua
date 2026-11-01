-- Synchronous, reversible timings around native close. Values may overlap.
local M={}
local function pack(...)return {n=select('#',...),...}end
function M.run(reader,callback,mark,clock,doccache,settings)
    local undo={}
    local wrapped={}
    local function wrap(obj,key,label)
        if not obj or type(obj[key])~='function' then return end
        wrapped[obj]=wrapped[obj]or {}
        if wrapped[obj][key]then return end
        wrapped[obj][key]=true
        local own,original=rawget(obj,key),obj[key]
        obj[key]=function(...)
            local started=clock()
            local result=pack(pcall(original,...))
            -- Report only method names/times; no paths, settings or arguments.
            pcall(mark,label,clock()-started,result[1])
            if not result[1] then error(result[2],0)end
            return unpack(result,2,result.n)
        end
        undo[#undo+1]=function()obj[key]=own end
    end
    wrap(reader,'saveSettings','save_settings')
    wrap(reader,'closeDocument','document_release')
    wrap(reader.doc_settings,'flush','document_settings_flush')
    wrap(settings,'flush','global_settings_flush')
    wrap(doccache,'serialize','doccache_serialize')
    -- Native events also invoke third-party modules; measure them separately
    -- before attributing event latency to KOReader itself.
    for name,child in pairs(reader)do
        if type(name)=="string" and name:match("^[%w_]+$") and type(child)=="table" and child.ui==reader then
            for _,method in ipairs({"onCloseDocument","onSaveSettings","onCloseWidget"})do
                wrap(child,method,"module."..name.."."..method)
            end
        end
    end
    local function registered(children,prefix)
        for index,child in ipairs(children)do
            if type(child)=='table' and child~=reader then
                local name=child.name
                if type(name)~='string' or not name:match('^[%w_]+$')then name=prefix..index end
                for _,method in ipairs({'onCloseDocument','onSaveSettings','onCloseWidget'})do
                    wrap(child,method,'module.'..name..'.'..method)
                end
            end
        end
    end
    -- PluginLoader registers unnamed instances in the event array. They can
    -- perform synchronous network work even without a named reader.ui field.
    registered(reader,'child_')
    registered(reader.active_widgets or {},'active_')
    local original,own=reader.handleEvent,rawget(reader,'handleEvent')
    if type(original)=='function' then
        reader.handleEvent=function(self,event,...)
            local name=event and event.handler
            local started=clock();local result=pack(pcall(original,self,event,...))
            if name=='onCloseDocument' or name=='onSaveSettings' or name=='onFlushSettings' then
                pcall(mark,name,clock()-started,result[1])
            end
            if not result[1] then error(result[2],0)end
            return unpack(result,2,result.n)
        end
        undo[#undo+1]=function()reader.handleEvent=own end
    end
    local result=pack(pcall(callback))
    for i=#undo,1,-1 do undo[i]()end
    if not result[1]then error(result[2],0)end
    return unpack(result,2,result.n)
end
return M
