local Loader = {}
function Loader.open(pkg, digest, settings, trusted_legacy)
    local m = pkg.manifest
    local prefix = "picayomi_ext."..m.id.."."..digest.."."
    local cache, loading = {}, {}
    local ctx,processors = require("source.extensions.sdk").create(m.id, settings, trusted_legacy, m.cache_schema_version,m.api_version)
    local function ext_require(name)
        assert(type(name)=="string" and name:match("^[%w_%-%.]+$"), "模块名无效")
        if cache[name]~=nil then return cache[name] end
        assert(not loading[name], "源模块循环依赖: "..name)
        local path=name:gsub("%.","/")..".lua"
        local code=assert(pkg.files[path], "源包缺少模块: "..name)
        loading[name]=true
        local env=setmetatable({require=ext_require,ctx=ctx},{__index=_G}); env._G=env
        local chunk="@"..prefix..path
        local coverage_root=os.getenv("PICAYOMI_COV_ROOT")
        if coverage_root and os.getenv("PICAYOMI_COV_OUT") then
            local original=coverage_root.."/extensions/"..m.id.."/"..path
            local f=io.open(original,"rb")
            if f then local bytes=f:read("*a"); f:close(); if bytes==code then chunk="@"..original end end
        end
        local fn=assert(loadstring(code,chunk)); setfenv(fn,env)
        local ok,result=pcall(fn); loading[name]=nil; assert(ok,result)
        cache[name]=result==nil and true or result
        return cache[name]
    end
    ctx.require=ext_require
    if m.api_version<3 then ctx.module=function(name) return prefix..name end end
    for path in pairs(pkg.files) do
        local name=path:sub(1,-5):gsub("/",".")
        package.preload[prefix..name]=function() return ext_require(name) end
    end
    local context={ctx=ctx,processors=processors or {},require=ext_require,pkg=pkg,digest=digest,trusted_legacy=trusted_legacy}
    require("source.processors").attach(context)
    return context
end
function Loader.activate(context)
    local pkg,digest=context.pkg,context.digest
    local m=pkg.manifest
    context.ctx.initializing=true
    local factory=context.require(m.entry:sub(1,-5):gsub("/","."))
    assert(type(factory)=="function", "入口必须返回源工厂函数")
    local source=factory(context.ctx)
    assert(type(source)=="table", "源工厂必须返回对象")
    source.identifier,source.name,source.version=m.id,m.name,m.version
    source.content_type=m.content_type or "comic"
    source._extension_digest=digest
    if m.api_version==3 and source.getImageRequest==nil then
        function source:getImageRequest(resource) return context.ctx.imageRequest(resource) end
    end
    if m.api_version==3 and source.getSortOptions==nil then
        function source:getSortOptions() return true,{},nil end
    end
    local required=m.api_version==3 and {"init","getManga","getChapters","getPages","getImageRequest"}
        or {"init","getComics","getComicDetail","getChapters","getAllChapterImages","imageHeaders","hasCapability"}
    if source.content_type=="novel" then
        required={"init","getManga","getChapters","getChapterContent","getImageRequest"}
    end
    for _,method in ipairs(required) do
        assert(type(source[method])=="function", "缺少源接口: "..method)
    end
    require("source.capabilities").validate(source,m.api_version)
    if m.identity_policy=="legacy" then assert(context.trusted_legacy,"历史数据身份未获授权") end
    context.ctx.initializing=true
    local initialized,init_error,init_data,init_failure=pcall(source.init,source,context.ctx)
    context.ctx.initializing=false
    assert(initialized,init_error)
    if m.api_version==3 then
        assert(init_error==true and type(init_data)=="table" and init_failure==nil,"初始化返回约定无效")
    end
    require("source.extensions.sdk").seal(context.ctx)
    context.processors=require("source.contract").copy(context.processors,true)
    if m.api_version<3 and not source._extension_guards then
        for _,method in ipairs({"getComics","getComicDetail","getChapters","getChapterImages","getAllChapterImages","getRandom"}) do
            local original = source[method]
            if type(original) == "function" then
                source[method] = function(self,...)
                    if require("source.capabilities").needsLogin(self) then return false,nil,"请先登录" end
                    return original(self,...)
                end
            end
        end
        for capability,list in pairs({recommendations={"getRecommendations"},latest={"getLatest"},
            search={"search"},categories={"getCategories","getCategoryComics"},rankings={"getRankings"},
            comments={"getComments","getCommentReplies"},favorites={"getFavorites","addFavorite","removeFavorite"}}) do
            if source.capabilities[capability] then
                for _,method in ipairs(list) do
                    local original=source[method]
                    if original then
                        source[method]=function(self,...)
                            local status=require("source.capabilities").query(self,capability)
                            if not status.available then
                                if method=="addFavorite" or method=="removeFavorite" then return false,status.reason end
                                return false,nil,status.reason
                            end
                            return original(self,...)
                        end
                    end
                end
            end
        end
        source._extension_guards=true
    end
    return require("source.runtime").new(source,m,digest,context)
end
function Loader.load(pkg,digest,settings,trusted_legacy)
    return Loader.activate(Loader.open(pkg,digest,settings,trusted_legacy))
end
return Loader
