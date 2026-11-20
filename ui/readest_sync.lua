-- Suppress automatic Readest traffic for a PicaYomi reader instance.
local M={}
local function pack(...) return {n=select("#",...),...} end

local function manual_only(original)
    return function(self,interactive,...)
        if interactive then return original(self,interactive,...) end
    end
end

local function close_without_auto_sync(original)
    return function(self,...)
        local settings=self.settings
        if type(settings)~="table" or not settings.auto_sync then return original(self,...) end
        -- Readest checks auto_sync before asking KOReader to bring up Wi-Fi.
        -- Keep the shared settings untouched, including if close raises.
        local own=rawget(self,"settings")
        local view=setmetatable({auto_sync=false},{__index=settings,__newindex=settings})
        self.settings=view
        local result=pack(pcall(original,self,...))
        if self.settings==view then self.settings=own end
        if not result[1] then error(result[2],0) end
        return unpack(result,2,result.n)
    end
end

function M.install(reader,undo)
    for _,child in ipairs(reader) do
        if type(child)=="table" and (child.name=="readerreadest" or child.name=="readest")
                and not child._picayomi_sync_scope then
            local function replace(name,wrapper)
                local original=child[name]
                if type(original)~="function" then return end
                local own=rawget(child,name)
                child[name]=wrapper(original)
                undo[#undo+1]=function() child[name]=own end
            end
            for _,name in ipairs({"pullBookConfig","pullBookNotes","pullBookStats",
                    "pushBookConfig","pushBookNotes","pushBookStats","pushOpenBook"}) do
                replace(name,manual_only)
            end
            local function skip_schedule() return function() end end
            replace("scheduleBackgroundPull",skip_schedule)
            replace("scheduleWakePull",skip_schedule)
            replace("onCloseDocument",close_without_auto_sync)
            child._picayomi_sync_scope=true
            undo[#undo+1]=function() child._picayomi_sync_scope=nil end
        end
    end
end

return M
