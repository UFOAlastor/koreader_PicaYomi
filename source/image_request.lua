-- Shared by blocking and worker transports. Resolve in the parent at dispatch,
-- so credentials are never inherited from an earlier fork snapshot.
local C=require("source.contract")
local I={}
function I.validate(request)
    if type(request)~="table" then C.invalid("image.request","图片请求无效") end
    local out=C.copy(request,true)
    C.url(out.url,"image.url")
    if out.method~=nil and out.method~="GET" then C.invalid("image.method","图片请求仅支持 GET") end
    out.method="GET"; out.headers=out.headers or {}
    if type(out.headers)~="table" then C.invalid("image.headers","图片请求头无效") end
    local count,bytes=0,0
    for k,v in pairs(out.headers) do
        count=count+1
        if type(k)~="string" or not k:match("^[%w!#$%%&'*+.^_`|~%-]+$") or type(v)~="string" or v:find("[%c]") then
            C.invalid("image.headers","图片请求头无效")
        end
        bytes=bytes+#k+#v
    end
    if count>64 or bytes>32768 then C.invalid("image.headers","图片请求头超过限额","resource_limit") end
    if out.timeout~=nil and (type(out.timeout)~="number" or out.timeout~=out.timeout or out.timeout<=0) then C.invalid("image.timeout","图片超时无效") end
    out.timeout=math.min(out.timeout or 20,60)
    return out
end
function I.prepare(source,job)
    if source and source.getImageRequest then
        local page=job.image or {resource={url=job.url}}
        local ok,request,err=source:getImageRequest(page.resource or {url=job.url},page.context,job.call)
        if not ok then return nil,err or C.error("invalid_response","图片请求构造失败","getImageRequest") end
        local valid,data,e=C.protect("getImageRequest",I.validate,request)
        if not valid then return nil,e end
        data.post=page.processing and page.processing.file
        return data
    end
    -- Host cover providers and legacy test transports retain their old protocol.
    if not source or not source.imageHeaders then return nil,"源未实现 imageHeaders" end
    local ok,headers,err=pcall(source.imageHeaders,source,job.url)
    if not ok or type(headers)~="table" then return nil,err or "请求头构造失败" end
    return {url=job.url,headers=headers,timeout=20,legacy=true}
end
return I
