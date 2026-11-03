-- One speculative page per document. Completed pixels belong only to DocCache.
local M={}
local MIN_BUDGET=4*1024*1024
local clock=require('socket').gettime
local function observe(doc,n,state,job)
    local info=job and job.observation or {page=n}
    info.state=state
    if job then info.ms=math.floor((clock()-job.started)*1000)end
    doc._enhancement_observation=info
end
local function count(doc,event)
    local stats=doc._enhancement_stats or {launched=0,ready=0,used=0,failed=0,cancelled=0}
    doc._enhancement_stats=stats;stats[event]=stats[event]+1
end
function M.describe(doc,n)
    local info=doc and doc._enhancement_observation
    if not info or info.page~=n then return 'none',0,0 end
    return info.state,info.ms or 0,math.floor((info.budget or 0)/1024)
end
function M.used(doc,n,tile)
    local info=doc._enhancement_observation
    if info and info.page==n and info.state=='ready' and tile and info.bitmap and info.bitmap[1]==tile.bb then
        info.state='used';info.bitmap=nil;count(doc,'used')
    end
end
function M.report(doc)
    local s=doc._enhancement_stats
    if s then require('util.logger').notice('Picayomi: enhancement summary',
        'launched',s.launched,'ready',s.ready,'used',s.used,'failed',s.failed,'cancelled',s.cancelled)end
    doc._enhancement_stats=nil;doc._enhancement_observation=nil
end
function M.setSuspended(value)
    M.suspended=value
    if value then M.cancelAll()end
end
local documents=setmetatable({},{__mode='k'})
function M.cancel(doc)
    local job=doc._enhancement_job
    doc._enhancement_job=nil
    if not job then return end
    observe(doc,job.page,'cancelled',job);count(doc,'cancelled')
    if job.task then job.task.nonblocking=true;job.task:cancel()end
    if job.output then os.remove(job.output)end
end
function M.cancelAll()
    for doc in pairs(documents)do M.cancel(doc)end
end
local function room(doc,bytes)
    local cache=require('document/doccache')
    local ref=doc._prediction_current
    -- Touch the visible tile last, then normal LRU can only replace older tiles
    -- when the result arrives. Never resize/clear cache to admit speculative work.
    local current=ref and cache.cache:get(ref.key)
    return current and current==ref.tile[1] and current.pageno==doc._last_render_page
        and (cache.slots or 0)>=2 and cache:willAccept(bytes+512)
        and current.size+bytes+512<=cache.size
end

function M.hint(doc,n,zoom,rotation,gamma,saturation)
    if M.suspended then return end
    local spec,key=doc:prefetch_spec(n,zoom,rotation,gamma,saturation)
    if not spec then M.cancel(doc);observe(doc,n,key or 'ineligible');return end
    if doc._prediction_rejected==key then M.cancel(doc);return end
    local cache=require('document/doccache')
    if cache:check(spec.cache_key)then M.cancel(doc);return end
    local current=doc._enhancement_job
    if current and current.key==key then return end
    for other in pairs(documents)do M.cancel(other)end
    M.cancel(doc)
    if not room(doc,spec.width*spec.height*(spec.color and 4 or 1))then observe(doc,n,'cache_room');return end
    local job={key=key,page=n,started=clock(),observation={page=n}}
    doc._enhancement_job=job;documents[doc]=true;observe(doc,n,'waiting',job)
    local function valid()
        if doc._enhancement_job~=job then return false end
        local fresh,newkey=doc:prefetch_spec(n,zoom,rotation,gamma,saturation)
        return fresh and newkey==key
    end
    local bytes=spec.width*spec.height*(spec.color and 4 or 1)
    local guard=require('util.memory_guard').instance()
    local Async=require('network.async_task')
    local function clean()
        if spec.output then os.remove(spec.output)end
        if doc._enhancement_job==job then doc._enhancement_job=nil end
    end
    job.task=Async.run(function()
            Async.wait(.12)
            if not valid()then clean();return end
            spec.budget=guard:prediction_budget(bytes)
            if spec.budget<MIN_BUDGET or not room(doc,bytes)then observe(doc,n,'memory',job);clean();return end
            spec.output=os.tmpname();job.output=spec.output
            local result=Async.await(function()return require('util.enhancement_worker').render(spec)end,spec)
            if not valid()then clean();return end
            -- The codec workspace has been released. The existing admission
            -- policy reserves three raster buffers plus foreground headroom;
            -- receiving a finished raster does not require its old codec grant.
            if not room(doc,bytes) or guard:prediction_budget(bytes)<MIN_BUDGET then
                observe(doc,n,'receive_memory',job);clean();return
            end
            assert(type(result)=='table' and result.bytes==bytes and result.stride==spec.width*(spec.color and 4 or 1),'invalid raster size')
            local lfs=require('libs/libkoreader-lfs')
            assert(lfs.attributes(spec.output,'size')==bytes,'truncated raster')
            local BB=require('ffi/blitbuffer');local ffi=require('ffi')
            local bb=BB.new(spec.width,spec.height,spec.color and BB.TYPE_BBRGB32 or BB.TYPE_BB8)
            local f=io.open(spec.output,'rb')
            local ok,err=pcall(function()
                assert(f,'missing raster')
                for offset=0,bytes-1,65536 do
                    local count=math.min(65536,bytes-offset);local data=f:read(count)
                    assert(data and #data==count,'truncated raster')
                    ffi.copy(ffi.cast('uint8_t*',bb.data)+offset,data,count)
                end
                assert(not f:read(1),'oversized raster')
            end)
            if f then f:close()end
            if not ok then bb:free();error(err,0)end
            -- No event yield between revalidation and ownership transfer.
            doc:accept_prefetch(n,spec,bb,result.bypass)
            job.observation.bitmap=setmetatable({bb},{__mode='v'})
            observe(doc,n,'ready',job);count(doc,'ready')
            clean()
        end,{admit=function()
                if not valid() or not room(doc,bytes)then return false end
                -- Loading the fork backend itself changes MemAvailable. Never
                -- increase a grant, but do not reject a still-usable smaller one.
                spec.budget=math.min(spec.budget,guard:prediction_budget(bytes))
                job.observation.budget=spec.budget
                if spec.budget<MIN_BUDGET then return false end
                observe(doc,n,'running',job);count(doc,'launched');return true
            end,
            timeout=5,on_error=function(err)
                local message=tostring(err)
                local reason=message:find('memory',1,true) or message:find('budget',1,true) or message:find('内存',1,true)
                observe(doc,n,reason and 'memory' or message:find('超时',1,true) and 'timeout' or 'worker_error',job)
                count(doc,'failed');doc._prediction_rejected=key;clean()
            end,on_cancel=function()
                if doc._enhancement_job==job then observe(doc,n,'cancelled',job);count(doc,'cancelled')end
                clean()
            end})
    job.task.nonblocking=true
end
return M
