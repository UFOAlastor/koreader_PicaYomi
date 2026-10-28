-- Illustration bodies stay on disk in the worker, not in acknowledged IPC frames.
local M={}
function M.download(request,timeout,destination,pool,deadline)
    assert(type(destination)=="string" and not destination:find("[%c]")
        and destination:match("/images/%d%d%d%d%.img%.download$"),"invalid image destination")
    for part in destination:gmatch("[^/]+") do assert(part~="..","invalid image destination") end
    -- KOReader on Kindle uses ./picayomi, while emulator KO_HOME is absolute.
    -- Resolve before passing the same destination to a background worker.
    if destination:sub(1,1)~="/" then
        destination=require("libs/libkoreader-lfs").currentdir().."/"..destination
    end
    local valid=require("source.image_request").validate(request)
    local clock=require("socket").gettime
    -- At most one extra slow-timeout attempt, bounded by the chapter deadline.
    -- HTTP status, certificate and protocol errors are never retried here.
    local function attempt()
        local budget=math.min(timeout or 20,20,deadline and deadline-clock() or 20)
        if budget<=0 then return nil,"chapter deadline exceeded" end
        if pool then valid.headers.Connection="keep-alive";pool.timeout=budget end
        return require("network.http_client"):download(valid.url,destination,valid.headers,budget,1,pool)
    end
    local ok,size=attempt()
    if not ok and deadline and deadline-clock()>1 and type(size)=="string"
        and size:match("timeout$") then
        require("util.logger").warn("Picayomi novel illustration timeout; retrying once within chapter deadline")
        ok,size=attempt()
    end
    if not ok then return nil,size end
    if size>4*1024*1024 then os.remove(destination);return nil,"illustration too large"end
    return {path=destination,bytes=size}
end
function M.image(request,timeout,destination,deadline)
    local Async=require("network.async_task")
    local result,err
    if Async.active()then
        result,err=Async.await(function()return M.download(request,timeout,destination,nil,deadline)end,
            {kind="novel_image",request=request,timeout=timeout,destination=destination,deadline=deadline})
    else result,err=M.download(request,timeout,destination,nil,deadline)end
    if not result then return nil,err end
    local absolute=destination:sub(1,1)=="/" and destination
        or require("libs/libkoreader-lfs").currentdir().."/"..destination
    assert(result.path==absolute,"unexpected image path")
    local bytes=require("source.extensions.storage").read(destination,4*1024*1024)
    os.remove(destination)
    assert(bytes and #bytes==result.bytes,"incomplete illustration")
    return {status_code=200,body=bytes}
end
return M
