-- One speculative page per document. Completed pixels belong only to DocCache.
local M={}
local documents=setmetatable({},{__mode='k'})
function M.cancel(doc)
    local job=doc._enhancement_job
    doc._enhancement_job=nil
    if not job then return end
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
    local spec,key=doc:prefetch_spec(n,zoom,rotation,gamma,saturation)
    if not spec then M.cancel(doc);return end
    if doc._prediction_rejected==key then M.cancel(doc);return end
    local cache=require('document/doccache')
    if cache:check(spec.cache_key)then M.cancel(doc);return end
    local current=doc._enhancement_job
    if current and current.key==key then return end
    for other in pairs(documents)do M.cancel(other)end
    M.cancel(doc)
    if not room(doc,spec.width*spec.height*(spec.color and 4 or 1))then return end
    local job={key=key};doc._enhancement_job=job;documents[doc]=true
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
            if spec.budget<4*1024*1024 or not room(doc,bytes)then clean();return end
            spec.output=os.tmpname();job.output=spec.output
            local result=Async.await(function()return require('util.enhancement_worker').render(spec)end,spec)
            if not valid() or not room(doc,bytes) or guard:prediction_budget(bytes)<spec.budget then clean();return end
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
            clean()
        end,{admit=function()return valid() and room(doc,bytes) and guard:prediction_budget(bytes)>=spec.budget end,
            timeout=5,on_error=function()doc._prediction_rejected=key;clean()end,on_cancel=clean})
    job.task.nonblocking=true
end
return M
