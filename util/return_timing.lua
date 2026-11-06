-- Bounded, anonymous close samples in release mode. No timers or per-page work.
-- Native substeps overlap their parent stages and must not be added together.
local M={LIMIT=8}
local counts={}
local noop={stage=function()end,finish=function()end,native=function(_,_,fn)return fn()end}
local function pack(...)return {n=select('#',...),...}end
function M.new(kind,deps)
    if kind~='comic' and kind~='novel' then return noop end
    if (counts[kind]or 0)>=M.LIMIT then return noop end
    counts[kind]=(counts[kind]or 0)+1
    deps=deps or {}
    local time=require('ui/time')
    local clock=deps.clock or function()return time.to_s(time.monotonic())end
    local log=deps.log or require('util.logger').notice
    local started=clock()
    local trace={last=started,stages={},steps={}}
    function trace:stage(name)
        if self.finished then return end
        local now=clock()
        self.stages[#self.stages+1]=string.format('%s=%.1f',name,(now-self.last)*1000)
        self.last=now
    end
    function trace:native(reader,fn)
        local result=pack(pcall(require('novel.close_diagnostics').run,reader,fn,function(name,elapsed,ok)
            if elapsed>=.005 or not ok then
                self.steps[#self.steps+1]={name=name,ms=elapsed*1000,ok=ok}
            end
        end,clock,require('document/doccache'),G_reader_settings))
        self:stage('native')
        if not result[1]then error(result[2],0)end
        return unpack(result,2,result.n)
    end
    function trace:finish()
        if self.finished then return end
        self.finished=true
        table.sort(self.steps,function(a,b)return a.ms>b.ms end)
        local details={}
        for i=1,math.min(6,#self.steps)do
            local entry=self.steps[i]
            details[#details+1]=string.format('%s:%.1f:%s',entry.name,entry.ms,tostring(entry.ok))
        end
        -- Logging failures must never change the close outcome.
        pcall(log,string.format('Picayomi: return timing kind=%s total_ms=%.1f stages_ms=[%s] native_overlap_ms=[%s]',
            kind,(clock()-started)*1000,table.concat(self.stages,','),table.concat(details,',')))
    end
    return trace
end
return M
