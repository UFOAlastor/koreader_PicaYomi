-- The only business boundary between executable source packages and consumers.
-- Raw implementations live in closures, never in the registry. The legacy
-- facade projects verified DTOs while existing views migrate to invoke().
local Contract=require("source.contract")
local Runtime={}
local list_methods={getComics=true,getRecommendations=true,getLatest=true,search=true,
    getCategoryComics=true,getRankings=true,getRandom=true,getFavorites=true}
local capability={getRecommendations="recommendations",getLatest="latest",search="search",
    getRandom="random",
    getCategories="categories",getCategoryComics="categories",getRankings="rankings",
    getRankingTypes="rankings",getFavorites="favorites",addFavorite="favorites",removeFavorite="favorites",
    getComments="comments",getCommentReplies="comments",getCommentDetails="comment_details",login="login",logout="login",getUserProfile="login"}
local mutations={login=true,logout=true,addFavorite=true,removeFavorite=true,punchIn=true,setCredential=true}
local arity={getManga=1,getChapters=2,getPages=2,getChapterContent=2,getImageRequest=2,getLatest=1,getRecommendations=1,
    search=2,getCategories=0,getCategoryComics=2,getRankingTypes=0,getRankings=2,getSortOptions=1,
    getSession=0,getCredential=0,setCredential=1,login=2,logout=0,getUserProfile=0,getFavorites=1,
    addFavorite=1,removeFavorite=1,getComments=2,getCommentReplies=3,getCommentDetails=2,punchIn=0,getRandom=1}
local function message(err) return err and err.message or "源请求失败" end
local function project(item,kind)
    local out=Contract.copy(item)
    if kind=="page" then out.url=out.resource.url
    else
        out._id=out.id
        if kind=="manga" then
            out.thumb=out.cover or out.thumb
            if out.favorite~=nil then out.isFavourite=out.favorite end
            out.update_time=out.updated_at or out.update_time
            for name,field in pairs({chapters="epsCount",pages="pagesCount",likes="likesCount",comments="commentsCount",views="viewsCount"}) do
                if out.stats and out.stats[name]~=nil then out[field]=out.stats[name] end
            end
        end
        if kind=="chapter" then out.sort_index=out.position;out.pagesCount=out.page_count or out.pagesCount end
    end
    return out
end
function Runtime.new(source,manifest,digest,extension_context)
    local legacy=manifest.api_version<3
    local list_display=Contract.listDisplay(source.list_display)
    local caps=Contract.copy(source.capabilities,true)
    local access=Contract.copy(source.access or {},true)
    local handle={identifier=manifest.id,name=manifest.name,version=manifest.version,
        content_type=manifest.content_type or "comic",
        text_filters=Contract.copy(manifest.text_filters or {},true),
        _extension_digest=digest,_api_version=manifest.api_version,_source_runtime=true,
        capabilities=Contract.copy(caps),access=Contract.copy(access)}
    function handle:init() return true end -- already initialized by the loader
    local orders,legacy_orders,order_keys={},{},{}
    local generation,listeners=0,{}
    local cache_session = tostring({}) -- Fallback for sources without a stable credential.
    function handle:sessionGeneration() return generation end
    function handle:watchSession(callback)
        local key={};listeners[key]=callback
        return function() listeners[key]=nil end
    end
    local function invalidate_sessions()
        generation=generation+1
        orders,legacy_orders,order_keys={},{},{}
        local pending={};for _,fn in pairs(listeners) do pending[#pending+1]=fn end
        for _,fn in ipairs(pending) do pcall(fn,generation) end
    end
    local function logged()
        if not legacy then
            if not caps.login then return false end
            local sdk=require("source.extensions.sdk")
            local ctx=extension_context and extension_context.ctx
            local previous=ctx and sdk.processing(ctx,true)
            local called,ok,state=pcall(source.getSession,source,{})
            if ctx then sdk.processing(ctx,previous) end
            return called and ok==true and type(state)=="table" and state.logged_in==true
        end
        local ok,value=pcall(function() return source:isLoggedIn() end)
        return ok and value==true
    end
    local function call(method,args,context)
        context=context or {}
        if context.cancelled or context.isCancelled and context.isCancelled() then
            return false,nil,Contract.error("cancelled","操作已取消",method)
        end
        if context.deadline and require("socket").gettime()>=context.deadline then
            return false,nil,Contract.error("timeout","操作超时",method,nil,true)
        end
        local cap=capability[method]
        if cap and caps[cap]~=true then return false,nil,Contract.error("unsupported","当前源不支持此功能",method) end
        if method=="getCommentReplies" and require("source.capabilities").replies(source)~="paged" then
            return false,nil,Contract.error("unsupported","当前源不支持分页回复",method)
        end
        if (caps.requires_login and method~="login" and method~="logout" and method~="getUserProfile" and method~="getSession" and method~="setCredential"
            or access[cap]=="login") and not logged() then
            return false,nil,Contract.error("auth_required","请先登录",method)
        end
        local fn=source[method]
        if type(fn)~="function" then return false,nil,Contract.error("unsupported","当前源不支持此功能",method) end
        local sdk=require("source.extensions.sdk")
        local ctx=extension_context and extension_context.ctx
        local previous=ctx and sdk.enter(ctx,context)
        local parameters={unpack(args,1,args.n or #args)}
        local count=not legacy and arity[method] or args.n or #args
        if not legacy then count=count+1; parameters[count]=context end
        local called,ok,data,err=pcall(fn,source,unpack(parameters,1,count))
        if ctx then sdk.enter(ctx,previous) end
        if context.cancelled or context.isCancelled and context.isCancelled() then
            return false,nil,Contract.error("cancelled","操作已取消",method)
        end
        if context.deadline and require("socket").gettime()>=context.deadline then
            return false,nil,Contract.error("timeout","操作超时",method,nil,true)
        end
        if not called then return false,nil,Contract.error("invalid_response","源执行失败",method) end
        if not legacy then
            if type(ok)~="boolean" or ok and (data==nil or err~=nil)
                or not ok and (data~=nil or not Contract.isError(err)) then
                return false,nil,Contract.error("invalid_response","源返回约定无效",method)
            end
        end
        if mutations[method] and legacy then
            if not ok and method~="logout" then return false,nil,Contract.sourceError(data,method) end
            return true,{success=true},nil
        end
        if legacy and (method=="getRankingTypes" or method=="getSortOptions" or method=="getUserProfile") then
            if ok==nil then return false,nil,Contract.sourceError(data,method) end
            data,ok=ok,true
        end
        if ok~=true then return false,nil,Contract.sourceError(err,method) end
        return true,data,nil
    end
    function handle:invoke(method,args,context)
        args=args or {}
        if not legacy and arity[method]==nil then return false,nil,Contract.error("unsupported","当前源不支持此接口",method) end
        if legacy and method=="getImageRequest" then return self:getImageRequest(args[1],args[2],context) end
        if legacy and method=="getPages" then
            local key=tostring(args[1])
            if not legacy_orders[key] then
                local ready,_,err=self:directory(args[1],context)
                if not ready then return false,nil,err end
            end
            local order=legacy_orders[key] and legacy_orders[key][args[2]]
            if order==nil then return false,nil,Contract.error("not_found","章节不存在",method) end
            args={args[1],order}
        elseif legacy then
            local at=list_methods[method] and ((method=="search" or method=="getCategoryComics" or method=="getRankings") and 2 or 1)
                or method=="getChapters" and 2 or method=="getComments" and 2 or method=="getCommentReplies" and 3
            if at and type(args[at])=="table" then
                local request=args[at]
                local translated={unpack(args)}
                translated[at]=request.page or 1
                if list_methods[method] then translated[at+1],translated[at+2]=request.sort,request.categories;translated.n=at+2 end
                args=translated
            end
        end
        local native=method
        if legacy then native=({getManga="getComicDetail",getPages="getAllChapterImages"})[method] or method end
        local account_change=native=="login" or native=="logout" or native=="setCredential"
        local was_logged=account_change and logged()
        local ok,data,err=call(native,args,context)
        if account_change and (ok or was_logged~=logged()) then invalidate_sessions() end
        if not ok then return false,nil,err end
        return Contract.protect(method,function()
            if method=="getChapterContent" then
                if handle.content_type~="novel" then Contract.invalid(method,"当前源不是小说源") end
                local out=Contract.copy(data,true)
                if type(out)~="table" or out.complete~=true or out.format~="html" then
                    Contract.invalid(method,"小说章节不完整或格式无效")
                end
                Contract.string(out.html,"chapter.html",Contract.MAX_STRING)
                require("source.image_request").validate({url=out.base_url,method="GET",headers={}})
                return out
            end
            if method=="getImageRequest" then return require("source.image_request").validate(data) end
            if not legacy and mutations[method] then
                if type(data)~="table" or data.success~=true then Contract.invalid(method,"写操作缺少成功结果") end
                return {success=true}
            end
            if not legacy and method=="getSession" then
                if type(data)~="table" or type(data.logged_in)~="boolean" then Contract.invalid(method,"会话状态无效") end
            end
            if not legacy and (method=="getUserProfile" or method=="getCredential") and type(data)~="table" then
                Contract.invalid(method,"账号返回值无效")
            end
            if method=="getManga" or method=="getComicDetail" then
                local manga=Contract.manga(data,legacy)
                manga.content_type=handle.content_type
                manga._list_display=Contract.copy(list_display,true)
                return manga
            end
            if method=="getPages" or method=="getAllChapterImages" or method=="getChapterImages" then
                local result=Contract.pages(data,legacy)
                local P=require("source.processors")
                for _,page in ipairs(result.items) do
                    local processing={}
                    for _,stage in ipairs({"file","render"}) do
                        processing[stage]=legacy and P.legacy(source,stage,page.resource.url)
                            or P.bind(manifest.id,digest,extension_context.processors or {},stage,
                                page.processors and page.processors[stage],page.context)
                    end
                    page.processing=processing
                end
                return result
            end
            if list_methods[method] then
                local result=Contract.list(data,"manga",legacy)
                for _,manga in ipairs(result.items) do manga._list_display=Contract.copy(list_display,true);manga.content_type=handle.content_type end
                return result
            end
            if method=="getChapters" then
                local result=Contract.list(data,"chapter",legacy,{manga_id=args[1],identity_policy=manifest.identity_policy})
                for _,ch in ipairs(result.items) do
                    if not legacy then ch.order=require("source.identity").chapterOrder(manifest,ch) end
                    ch.order=ch.order or "c_"..require("ffi/sha2").sha256(ch.id):sub(1,32)
                end
                return result
            end
            if method=="getCommentDetails" then return Contract.comment(data,legacy) end
            if method=="getComments" or method=="getCommentReplies" then
                return Contract.list(data,method=="getComments" and "comment" or "reply",legacy)
            end
            if method=="getCategories" or method=="getRankingTypes" or method=="getSortOptions" then
                local items=Contract.copy(data,not legacy); Contract.array(items,method)
                for i,item in ipairs(items) do
                    if type(item)~="table" then Contract.invalid(method.."."..i,"元数据条目无效") end
                    Contract.string(item.title or legacy and item.text,method.."."..i..".title",4096)
                    if not legacy then Contract.string(item.id,method.."."..i..".id") end
                end
                return items
            end
            return Contract.copy(data,not legacy)
        end)
    end
    local function remember_directory(manga_id,items)
        local key=tostring(manga_id)
        if not orders[key] then order_keys[#order_keys+1]=key end
        local mapping,old_mapping={},{}
        for _,ch in ipairs(items) do mapping[tostring(ch.order)]=ch.id;old_mapping[ch.id]=ch.order end
        orders[key]=mapping; legacy_orders[key]=old_mapping
        if #order_keys>32 then local oldest=table.remove(order_keys,1);orders[oldest]=nil;legacy_orders[oldest]=nil end
    end
    local function chapter_cache_key(manga_id)
        if caps.requires_login and not logged() then return end
        local scope="public"
        if logged() then
            local credential
            if not legacy then
                local ok,data=handle:invoke("getCredential",{})
                if ok and next(data) then credential=Contract.serialize(data) end
            elseif source.getToken then
                local ok,token=pcall(source.getToken,source)
                if ok and type(token)=="string" and token~="" then credential=token end
            end
            scope=credential and require("ffi/sha2").sha256(credential) or cache_session..":"..generation
        end
        local settings={}
        for _,setting in ipairs(manifest.settings or {}) do
            local getter=extension_context and extension_context.ctx and extension_context.ctx.getSetting
            local value=setting.default
            if getter then value=getter(setting.key,setting.default) end
            settings[setting.key]=value
        end
        return Contract.serialize({source=manifest.id,digest=digest,version=manifest.version,
            manga=tostring(manga_id),scope=scope,settings=require("ffi/sha2").sha256(Contract.serialize(settings))})
    end
    local function chapter_view(data)
        local result={episodes={},page=1,pages=1,total=#data.items}
        for i,item in ipairs(data.items) do result.episodes[i]=project(item,"chapter") end
        return result
    end
    function handle:peekChapters(manga_id)
        local readable,key=pcall(chapter_cache_key,manga_id)
        if not readable or not key then return end
        local entry=require("util.chapter_cache").read(key,manga_id)
        if not entry then return end
        remember_directory(manga_id,entry.data.items)
        return chapter_view(entry.data),entry.fresh
    end
    function handle:refreshChapters(manga_id,context)
        local key=chapter_cache_key(manga_id)
        local started=generation
        local ok,data,err=self:directory(manga_id,context)
        if not ok then return false,nil,message(err) end
        if method=="getCommentDetails" then return true,project(data,"comment") end
        if started~=generation or key~=chapter_cache_key(manga_id) then return false,nil,"登录或源设置已改变，请重新打开详情" end
        -- Cache writes are optional: disk-full/oversized snapshots must not hide
        -- a valid network directory. A failed refresh never replaces last good data.
        if key then pcall(require("util.chapter_cache").write,key,manga_id,data) end
        return true,chapter_view(data)
    end
    -- Aggregation is bounded and atomic: no partial directory escapes on error.
    function handle:directory(manga_id,context)
        local request,seen,ids,items={}, {},{},{}
        for _=1,200 do
            local args={manga_id,legacy and (request.page or 1) or request}
            local ok,result,err=self:invoke("getChapters",args,context)
            if not ok then return false,nil,err end
            for _,ch in ipairs(result.items) do
                if ids[ch.id] then return false,nil,Contract.error("invalid_response","章节身份重复","getChapters") end
                ids[ch.id]=true; ch.position=#items+1; items[#items+1]=ch
                if #items>Contract.MAX_ITEMS then return false,nil,Contract.error("resource_limit","章节超过限额","getChapters") end
            end
            if not result.has_more then
                remember_directory(manga_id,items)
                return true,{items=items,has_more=false,total=#items}
            end
            local key=Contract.serialize(result.next)
            if seen[key] then return false,nil,Contract.error("invalid_response","章节续页重复","getChapters") end
            seen[key]=true; request=result.next
        end
        return false,nil,Contract.error("resource_limit","章节请求超过限额","getChapters")
    end
    function handle:hasCapability(name) return caps[name]==true end
    function handle:capability(name) return require("source.capabilities").query(self,name) end
    if not legacy then
        function handle:isLoggedIn() return logged() end
        function handle:getToken()
            local ok,data=self:invoke("getCredential",{})
            return ok and data.token or nil
        end
        function handle:setToken(token)
            local ok,_,err=self:invoke("setCredential",{token})
            return ok,not ok and message(err) or nil
        end
    end
    function handle:getImageRequest(resource,page_context,context)
        if type(resource)~="table" then return false,nil,Contract.error("invalid_response","图片资源无效","getImageRequest") end
        if context and (context.cancelled or context.isCancelled and context.isCancelled()) then return false,nil,Contract.error("cancelled","操作已取消","getImageRequest") end
        if context and context.deadline and require("socket").gettime()>=context.deadline then return false,nil,Contract.error("timeout","操作超时","getImageRequest",nil,true) end
        if context and context.generation~=nil and context.generation~=generation then
            return false,nil,Contract.error("cancelled","登录状态已改变，请重新打开章节","getImageRequest")
        end
        if legacy then
            if caps.requires_login and (not source.isLoggedIn or not source:isLoggedIn()) then
                return false,nil,Contract.error("auth_required","请先登录","getImageRequest")
            end
            local ok,headers,err=pcall(source.imageHeaders,source,resource.url)
            if not ok or type(headers)~="table" then return false,nil,Contract.sourceError(err,"getImageRequest") end
            local copy={}
            for k,v in pairs(headers) do copy[k]=type(v)=="number" and tostring(v) or v end
            return Contract.protect("getImageRequest",require("source.image_request").validate,
                {url=resource.url,method="GET",headers=copy})
        end
        local ok,request,err=call("getImageRequest",{resource,page_context,n=2},context)
        if not ok then return false,nil,err end
        return Contract.protect("getImageRequest",require("source.image_request").validate,request)
    end
    if not legacy then
        function handle:imageHeaders(url)
            local ok,data,err=self:getImageRequest({url=url})
            return ok and data.headers or nil,not ok and message(err) or nil
        end
    end
    local continuations,continuation_keys,continuation_seen,indexed_pages={},{},{},{}
    local function continuation_state(key)
        if not continuations[key] then
            continuations[key]={};continuation_seen[key]={}
            continuation_keys[#continuation_keys+1]=key
            if #continuation_keys>16 then
                local oldest=table.remove(continuation_keys,1)
                continuations[oldest]=nil;continuation_seen[oldest]=nil;indexed_pages[oldest]=nil
            end
        end
        return continuations[key]
    end
    local function facade(method,...)
        local args={...}
        local context
        if method=="getAllChapterImages" or method=="getChapterImages" then
            context=args[3];args[3]=nil
        end
        local canonical=method
        if not legacy then canonical=({getComicDetail="getManga",getAllChapterImages="getPages",getChapterImages="getPages",getComics="getLatest"})[method] or method end
        local page_number=1
        local paging_key
        if not legacy and list_methods[method] then
            local at=(method=="search" or method=="getCategoryComics" or method=="getRankings") and 2 or 1
            local explicit=type(args[at])=="table" and args[at]
            page_number=explicit and tonumber(explicit.page) or tonumber(args[at]) or 1
            local scope={method=canonical,filter=args[1],sort=args[at+1],categories=args[at+2]}
            if at==1 then scope.filter=nil end
            paging_key=Contract.serialize(scope)
            continuation_state(paging_key)
            local indexed=indexed_pages[paging_key]
            if page_number<1 or page_number%1~=0 then return false,nil,"页码无效" end
            local request=explicit or page_number==1 and {} or continuations[paging_key][page_number]
            if not explicit and page_number>1 and indexed then
                if page_number>indexed.pages then return false,nil,"页码超出范围，请重新加载" end
                request={page=page_number}
            end
            if not request then return false,nil,"续页已失效，请从首页重新加载" end
            request=Contract.copy(request)
            if args[at+1]~=nil then request.sort=args[at+1] end
            if args[at+2]~=nil then request.categories=args[at+2] end
            if explicit then paging_key=nil end
            if at==1 then args={request} else args={args[1],request} end
        elseif not legacy and (method=="getComments" or method=="getCommentReplies") then
            local at=method=="getComments" and 2 or 3
            page_number=tonumber(args[at]) or 1
            paging_key=method..":"..tostring(args[1])..":"..(at==3 and tostring(args[2]) or "")
            continuation_state(paging_key)
            local indexed=indexed_pages[paging_key]
            if indexed and page_number>indexed.pages then return false,nil,"页码超出范围，请重新加载" end
            args[at]=page_number==1 and {} or indexed and {page=page_number} or continuations[paging_key][page_number]
            if not args[at] then return false,nil,"续页已失效，请重新加载" end
        elseif not legacy and canonical=="getPages" then
            local id=orders[tostring(args[1])] and orders[tostring(args[1])][tostring(args[2])]
            if not id then
                local ok,_,err=handle:directory(args[1],context)
                if not ok then return false,nil,message(err) end
                id=orders[tostring(args[1])] and orders[tostring(args[1])][tostring(args[2])]
            end
            if not id then return false,nil,"章节标识不存在，请重新加载目录" end
            args={args[1],id}
        end
        local ok,data,err
        if paging_key and page_number>200 and not indexed_pages[paging_key] then return false,nil,"列表请求超过限额，请重新搜索或筛选" end
        if not legacy and method=="getChapters" then ok,data,err=handle:directory(args[1])
        else ok,data,err=handle:invoke(canonical,args,context) end
        if ok and paging_key then
            if data.pagination and data.pagination.page~=page_number then return false,nil,"源返回页码不一致" end
            if page_number==1 then continuations[paging_key]={};continuation_seen[paging_key]={};indexed_pages[paging_key]=nil end
            indexed_pages[paging_key]=data.pagination
            local state=continuations[paging_key]
            local encoded=data.next and Contract.serialize(data.next)
            if encoded and not data.pagination then
                local hash=require("ffi/sha2").sha256(encoded)
                local previous=continuation_seen[paging_key][hash]
                if previous and previous<page_number then return false,nil,"源续页重复，请重新加载" end
                continuation_seen[paging_key][hash]=page_number
            end
            state[page_number+1]=data.next
            for n in pairs(state) do if n<page_number-31 then state[n]=nil end end
        end
        if mutations[method] then return ok,not ok and message(err) or nil end
        if method=="getRankingTypes" or method=="getSortOptions" or method=="getUserProfile" then
            if ok and not legacy and method~="getUserProfile" then
                for _,item in ipairs(data) do
                    if method=="getSortOptions" then item.value,item.text=item.id,item.title end
                end
            end
            return ok and data or nil,not ok and message(err) or nil
        end
        if not ok then return false,nil,message(err) end
        if method=="getComicDetail" then return true,project(data,"manga") end
        if not legacy and method=="getCategories" then
            for _,item in ipairs(data) do item._id=item.id end
            return true,data
        end
        local kind,key
        if list_methods[method] then kind,key="manga","comics"
        elseif method=="getChapters" then kind,key="chapter","episodes"
        elseif method=="getComments" then kind,key="comment","comments"
        elseif method=="getCommentReplies" then kind,key="comment","replies"
        elseif method=="getAllChapterImages" or method=="getChapterImages" then kind,key="page","images" end
        if kind then
            local result=Contract.copy(data)
            result[key]={}
            for i,item in ipairs(data.items) do result[key][i]=project(item,kind) end
            -- Sources may explicitly declare validated indexed pagination.
            if legacy and kind~="page" then
                result.page=data.page
                result.pages=data.pages
            end
            if not legacy and kind~="page" then
                result.page=page_number
                if data.pagination then
                    result.pages=data.pagination.pages
                    result.page_size=data.pagination.page_size
                end
                if method=="getChapters" then result.pages=1 end
            end
            return true,result
        end
        return true,data
    end
    for method in pairs(list_methods) do handle[method]=function(_,...) return facade(method,...) end end
    for _,method in ipairs({"getComicDetail","getChapters","getAllChapterImages","getChapterImages",
        "getComments","getCommentReplies","getCommentDetails","getCategories","getRankingTypes","getSortOptions",
        "login","logout","getUserProfile","addFavorite","removeFavorite","punchIn"}) do
        handle[method]=function(_,...) return facade(method,...) end
    end
    -- Frozen legacy compatibility: helpers bind self to the implementation, but
    -- table values are copied. They cannot expose a mutable source cache.
    return setmetatable(handle,{__index=function(_,name)
        if not legacy then return nil end
        if name=="_http_client" then return nil end
        local value=source[name]
        if type(value)=="function" then return function(_,...) return value(source,...) end end
        if type(value)=="table" then return Contract.copy(value) end
        return value
    end,__newindex=function(t,name,value)
        -- Legacy integrations historically replace service hooks in tests.
        if legacy then source[name]=value else rawset(t,name,value) end
    end})
end
return Runtime
