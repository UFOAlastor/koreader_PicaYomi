-- Reading images live in a content generation; document/progress paths remain
-- stable. A late worker can only publish into its original generation.
local M={}
local transient={token=true,access_token=true,auth=true,authorization=true,signature=true,
    sign=true,key=true,api_key=true,expires=true,expiry=true,verify=true,timestamp=true}
local function resource_key(url)
    local base,query=url:match("^([^?#]+)%?([^#]*)")
    if not base then return url:gsub("#.*$","") end
    local stable={}
    for part in query:gmatch("[^&]+") do
        local key=part:match("^([^=]+)") or part
        if not transient[key:lower()] then stable[#stable+1]=part end
    end
    table.sort(stable)
    if #stable==0 then return base end
    return base.."?"..table.concat(stable,"&")
end
function M.fileKey(page)
    return require("ffi/sha2").sha256(require("source.contract").serialize({
        url=resource_key(page.resource and page.resource.url or page.url or ""),
        context=page.context,file=page.processing and page.processing.file,
    }))
end
function M.bind(dir,images,digest)
    if not dir or not images[1] or images[1].local_path or not images[1].resource then return dir end
    local list={digest=digest,items={}}
    for i,page in ipairs(images) do
        list.items[i]={url=resource_key(page.resource.url),context=page.context,processing=page.processing}
    end
    local hash=require("ffi/sha2").sha256(require("source.contract").serialize(list))
    local tag="g_"..hash:sub(1,40)
    local path=dir:sub(-#tag)==tag and dir or dir.."/"..tag
    require("source.extensions.storage").mkdir(path)
    -- Only the digest is persisted; URLs and credentials are never written.
    local marker=path.."/manifest.json"
    local storage=require("source.extensions.storage")
    if not storage.read(marker) then storage.json(marker,{format=1,digest=hash}) end
    return path
end
return M
