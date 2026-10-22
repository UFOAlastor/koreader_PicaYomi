-- Explicit, versioned host services. This is dependency isolation, not a sandbox.
local SDK = {}
local calls=setmetatable({},{__mode="k"})
local sealed=setmetatable({},{__mode="k"})
local processing=setmetatable({},{__mode="k"})
function SDK.seal(ctx) sealed[ctx]=true end
function SDK.processing(ctx,value) local old=processing[ctx]; processing[ctx]=value; return old end
local function thread() return coroutine.running() or SDK end
function SDK.enter(ctx,call)
    calls[ctx]=calls[ctx] or setmetatable({},{__mode="k"})
    local key=thread(); local old=calls[ctx][key]; calls[ctx][key]=call
    return old
end
local allowed = { ["source.base"]=true, logger=true, gettext=true, ["ffi/util"]=true,
    ["network.http_client"]=true, rapidjson=true, ["util.log_redact"]=true,
    ["util.json_null"]=true, ["util.cookie"]=true, ["util.aes"]=true, ["util.b64"]=true,
    ["util.hmac"]=true, ["util.favorites"]=true, ["libs/libkoreader-lfs"]=true,
    ["ffi/blitbuffer"]=true, ["ffi/sha2"]=true, util=true, htmlparser=true, ["util.cache"]=true, socket=true, ["util.diag"]=true, ["util.crypto"]=true }
local legacy = {
    picacg={ ["source.picacg.token"]=true,token=true,["source.picacg.username"]=true,profile=true },
    jm={jm_account=true,jm_password=true,jm_cookies=true,jm_session=true,jm_domains=true,
        jm_img_host=true,jm_categories_cache=true,jm_scramble_cache_v=true},
    htcomic={ ["source.htcomic.cookies"]=true,["source.htcomic.account"]=true },
}
function SDK.create(id, settings, trusted_legacy, cache_version, api_version)
    local config = require("util.config")
    local function key(k)
        assert(type(k)=="string" and #k<=160 and k:match("^[%w_%.%-]+$"), "源存储键无效")
        if trusted_legacy and legacy[id] and legacy[id][k] then return k end
        return "source_data."..id.."."..k
    end
    local secrets = {}
    for _, method in ipairs({"get","set","clear","get_json","set_json"}) do
        secrets[method] = function(k, ...) return require("util.secret_store")[method](key(k), ...) end
    end
    local cache=require("util.cache")
    local cache_prefix=trusted_legacy and (cache_version or 1)==1 and "" or "source_cache:"..id..":"..(cache_version or 1)..":"
    local scoped_cache={}
    for _,method in ipairs({"getData","cacheData","clear","clearPattern"}) do
        scoped_cache[method]=function(_,k,...) return cache[method](cache,cache_prefix..k,...) end
    end
    local scoped = {}
    function scoped:get(k, default)
        if k=="image_quality" then return config:get(k) end
        local v=config:get(key(k)); return v==nil and default or v
    end
    function scoped:set(k,v) return config:set(key(k),v) end
    local ctx={ base=require("source.base"), http=require("network.http_client"),
        json=require("rapidjson"), aes=require("util.aes"), html=require("htmlparser"),
        config=scoped, secrets=secrets, logger=require("util.logger"), getSetting=settings }
    local http=ctx.http
    ctx.http=setmetatable({}, {__index=function(_,name)
        if api_version==3 and not ({get=true,post=true,request=true,requestWithRetry=true,
            parseJsonResponse=true,fixImageUrl=true,resolveRedirect=true})[name] then return nil end
        local value=http[name]
        if type(value)~="function" then return value end
        return function(_, ...)
            assert(not ctx.initializing, "源初始化禁止联网")
            assert(not processing[ctx],"图片处理器禁止联网")
            local call=calls[ctx] and calls[ctx][thread()]
            assert(not call or not (call.cancelled or call.isCancelled and call.isCancelled()),"操作已取消")
            assert(not call or not call.deadline or require("socket").gettime()<call.deadline,"操作超时")
            if api_version==3 then
                local args={...}
                local at=({get=3,post=4,request=5,requestWithRetry=5,httpsRequest=5,download=4})[name]
                if at then
                    local limit=call and call.deadline and call.deadline-require("socket").gettime() or 60
                    local requested=args[at] or 20
                    assert(type(requested)=="number" and requested==requested and requested>0,"HTTP 超时无效")
                    args[at]=math.min(requested,60,limit)
                    return value(http,unpack(args,1,math.max(select("#",...),at)))
                end
            end
            return value(http,...)
        end
    end})
    function ctx.host(name)
        if name=="logger" then return require("util.logger") end
        if name=="network.http_client" then return ctx.http end
        if name=="util.cache" then return scoped_cache end
        if name=="util.config" then return scoped end
        if name=="util.secret_store" then return secrets end
        assert(allowed[name], "宿主未提供此依赖: "..tostring(name))
        return require(name)
    end
    if api_version~=3 then return ctx end
    -- Named services only. Old host/base/module imports are frozen in v1/v2.
    ctx.host=nil; ctx.base=nil
    ctx.cache=scoped_cache
    ctx.b64=require("util.b64"); ctx.hmac=require("util.hmac")
    ctx.hashes={md5=require("ffi/sha2").md5,["sha256"]=require("ffi/sha2").sha256}
    ctx.cookie=require("util.cookie"); ctx.values=require("util.json_null")
    local util=require("util")
    ctx.text={htmlToPlainText=util.htmlToPlainText,htmlEntitiesToUtf8=util.htmlEntitiesToUtf8,
        template=require("ffi/util").template}
    ctx.translate=require("gettext")
    ctx.clock={now=require("socket").gettime,timestamp=os.time}
    ctx.redact=require("util.log_redact")
    local logger=require("util.logger")
    local function safe_log(value)
        return ctx.redact.text(value):gsub("https?://[^%s\"'<>]+",ctx.redact.url)
    end
    ctx.logger={enabled=logger.enabled}
    for _,name in ipairs({"dbg","info","warn","err"}) do
        ctx.logger[name]=function(...)
            if (name=="dbg" or name=="info") and not logger.enabled then return end
            local parts={...}
            for i,v in ipairs(parts) do parts[i]=safe_log(type(v)=="table" and "<source data>" or v) end
            return logger[name](unpack(parts))
        end
    end
    ctx.trace={enabled=logger.enabled,mark=function(value)
        if logger.enabled then require("util.diag").mark(safe_log(value)) end
    end}
    ctx.error=require("source.contract").error
    ctx.imageRequest=function(resource,headers,timeout)
        return true,{url=resource.url,method="GET",headers=headers or {},timeout=timeout or 20},nil
    end
    local registered={}
    ctx.images=require("source.image_service").api()
    function ctx.images.register(name,entry)
        assert(not sealed[ctx],"运行期间不能新增图片处理器")
        assert(type(name)=="string" and name:match("^[a-z][a-z0-9_%-]*$") and #name<=64 and not registered[name],"图片处理器名称无效或重复")
        assert(type(entry)=="table" and (entry.stage=="file" or entry.stage=="render")
            and type(entry.version)=="number" and entry.version>=1 and entry.version%1==0
            and type(entry.module)=="string" and entry.module:match("^[%w_%-%.]+$")
            and type(entry.fn)=="string" and entry.fn:match("^[%w_]+$"),"图片处理器注册无效")
        registered[name]=require("source.contract").copy(entry,true)
    end
    return ctx,registered
end
return SDK
