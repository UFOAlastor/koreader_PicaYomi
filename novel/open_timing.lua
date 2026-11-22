-- Sample only the first few chapter opens. Never change the host input handler.
local M={}
local samples=0
function M.start()
    if samples>=8 then return end
    samples=samples+1
    local time=require("ui/time")
    local function now() return time.to_s(time.monotonic()) end
    local trace={id=samples,started=now()}
    function trace:mark(stage)
        require("util.logger").notice(string.format("Picayomi: novel open sample=%d stage=%s elapsed_ms=%.1f",
            self.id,stage,(now()-self.started)*1000))
    end
    function trace:ready(reader)
        self:mark("native_ready")
        local device=require("device")
        local view=reader.view
        local previous=rawget(view,"paintTo")
        local paint=view.paintTo
        local trace=self
        function view:paintTo(bb,...)
            if bb~=device.screen.bb then return paint(self,bb,...) end
            self.paintTo=previous
            local result=paint(self,bb,...)
            trace:mark("first_screen_buffer_painted")
            return result
        end
        -- The host restores handleTouchEv when it releases its input guard.
        -- Observe it on the UI loop; this timestamp is an upper bound.
        if not device.input._abs_ev_handler then return end
        local ui=require("ui/uimanager")
        local reader_ui=require("apps/reader/readerui")
        local deadline=now()+10
        local function observe()
            if reader_ui.instance~=reader then return end
            if not device.input._abs_ev_handler then
                trace:mark("touch_enabled_observed")
            elseif now()<deadline then
                ui:scheduleIn(.05,observe)
            end
        end
        ui:scheduleIn(.2,observe)
    end
    return trace
end
return M
