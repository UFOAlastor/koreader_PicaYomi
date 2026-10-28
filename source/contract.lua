-- Canonical source data. This module has no UI, platform or network dependency.
local C = { MAX_ITEMS=20000, MAX_NODES=200000, MAX_DEPTH=12, MAX_STRING=262144, MAX_ID=512, MAX_BYTES=8*1024*1024 }
local codes={unsupported=true,auth_required=true,auth_expired=true,network=true,timeout=true,
    rate_limited=true,not_found=true,protocol_changed=true,invalid_response=true,cancelled=true,resource_limit=true}
function C.error(code,message,operation,field,retryable)
    assert(codes[code],"unknown source error")
    local text=require("util.log_redact").text(message or "源返回值无效")
    text=text:gsub("https?://[^%s\"'<>]+",function(url) return require("util.log_redact").url(url) end)
    return {code=code,message=text:sub(1,1024),operation=operation,field=field,retryable=retryable==true}
end
local function invalid(field,message,code) error(C.error(code or "invalid_response",message,nil,field),0) end
C.invalid=invalid
function C.copy(value,strict)
    local nodes,bytes,stack=0,0,{}
    local function copy(v,depth)
        nodes=nodes+1
        if nodes>C.MAX_NODES or depth>C.MAX_DEPTH then invalid("result","源数据超过限额","resource_limit") end
        local t=type(v)
        if v==nil or t=="boolean" then return v end
        if t=="string" then
            bytes=bytes+#v
            if bytes>C.MAX_BYTES then invalid("result","源数据超过字节限额","resource_limit") end
            if #v>C.MAX_STRING then invalid("result","源文本超过限额","resource_limit") end
            return v
        end
        if t=="number" and v==v and math.abs(v)<math.huge then return v end
        if t=="userdata" and not strict and v==require("rapidjson").null then return nil end
        if t~="table" or stack[v] then invalid("result","源数据必须为无循环的 JSON 值") end
        local meta=getmetatable(v)
        local tag=type(meta)=="table" and rawget(meta,"__jsontype")
        if meta then
            if tag~="array" and tag~="object" then invalid("result","源数据元表无效") end
            for k in pairs(meta) do if k~="__jsontype" then invalid("result","源数据元表无效") end end
        end
        stack[v]=true
        local out={}
        local numeric,strings=false,false
        for k,item in pairs(v) do
            if type(k)~="string" and (type(k)~="number" or k<1 or k%1~=0) then invalid("result","源数据键无效") end
            if type(k)=="number" and type(item)=="userdata" then invalid("result","数组条目不能为 JSON null") end
            if type(k)=="string" then
                bytes=bytes+#k
                if #k>4096 or bytes>C.MAX_BYTES then invalid("result","源数据键超过限额","resource_limit") end
            end
            out[k]=copy(item,depth+1)
            if type(k)=="number" then numeric=true else strings=true end
        end
        if numeric and strings then invalid("result","JSON 对象不能混用数组与字符串键") end
        if numeric then C.array(out,"result") end
        stack[v]=nil
        if tag then setmetatable(out,{__jsontype=tag}) end
        return out
    end
    return copy(value,0)
end
function C.serialize(value)
    -- A stable representation for cache generations and continuation equality.
    -- rapidjson object key order is intentionally unspecified between processes.
    local json=require("rapidjson")
    local function encode(v)
        if type(v)~="table" then return json.encode(v) end
        local array=v[1]~=nil or type(getmetatable(v))=="table" and getmetatable(v).__jsontype=="array"
        local parts={}
        if array then
            for i=1,#v do parts[i]=encode(v[i]) end
            return "["..table.concat(parts,",").."]"
        end
        local keys={};for k in pairs(v) do keys[#keys+1]=k end;table.sort(keys)
        for i,k in ipairs(keys) do parts[i]=json.encode(k)..":"..encode(v[k]) end
        return "{"..table.concat(parts,",").."}"
    end
    return encode(C.copy(value,true))
end
function C.string(v,field,max)
    if type(v)~="string" or v=="" or #v>(max or C.MAX_ID) or v:find("%z") then invalid(field,"源字段无效: "..field) end
    -- IDs are opaque UTF-8, not byte strings or path segments.
    local i=1
    while i<=#v do
        local a=v:byte(i)
        local n=a<128 and 1 or a>=194 and a<=223 and 2 or a>=224 and a<=239 and 3 or a>=240 and a<=244 and 4 or 0
        if n==0 or i+n-1>#v then invalid(field,"源字段不是有效 UTF-8: "..field) end
        for j=1,n-1 do local b=v:byte(i+j);if b<128 or b>191 then invalid(field,"源字段不是有效 UTF-8: "..field) end end
        local b=v:byte(i+1)
        if n==3 and (a==224 and b<160 or a==237 and b>=160) or n==4 and (a==240 and b<144 or a==244 and b>=144) then
            invalid(field,"源字段不是有效 UTF-8: "..field)
        end
        i=i+n
    end
    return v
end
function C.array(v,field)
    if type(v)~="table" then invalid(field,"源列表无效: "..field) end
    local meta=getmetatable(v)
    if type(meta)=="table" and rawget(meta,"__jsontype")=="object" then invalid(field,"源列表必须为数组: "..field) end
    local n=#v
    if n>C.MAX_ITEMS then invalid(field,"源列表超过限额","resource_limit") end
    for k in pairs(v) do
        if type(k)~="number" or k%1~=0 or k<1 or k>n then invalid(field,"源列表必须为连续数组: "..field) end
    end
    for i=1,n do if v[i]==nil then invalid(field,"源列表必须为连续数组: "..field) end end
    return v
end
function C.url(v,field)
    C.string(v,field,16384)
    local authority=v:match("^https?://([^/%?#]+)")
    if not authority or authority:find("@",1,true) or v:find("[%c%s]") then invalid(field,"图片地址无效") end
    return v
end
-- Sources choose fields, ordering and labels; the host keeps the card geometry.
function C.listDisplay(value)
    if value==nil then return nil end
    local out=C.copy(value,true)
    if type(out)~="table" then invalid("list_display","列表展示配置必须为对象") end
    local fields={author=true,categories=true,tags=true,finished=true,updated_at=true,subtitle=true,
        ["stats.chapters"]=true,["stats.pages"]=true,["stats.likes"]=true,["stats.views"]=true,["stats.comments"]=true}
    for row,items in pairs(out) do
        if row~="subtitle" and row~="details" then invalid("list_display","列表展示行无效") end
        C.array(items,"list_display."..row)
        if #items>6 then invalid("list_display","每行最多展示六个字段","resource_limit") end
        for i,item in ipairs(items) do
            if type(item)=="string" then item={field=item};items[i]=item end
            if type(item)~="table" then invalid("list_display","列表展示字段无效") end
            for key in pairs(item) do
                if key~="field" and key~="label" then invalid("list_display","列表展示选项无效") end
            end
            if not fields[item.field] and not (type(item.field)=="string" and #item.field<=73
                and item.field:match("^metadata%.[a-z][a-z0-9_]*$")) then
                invalid("list_display","列表展示字段不受支持")
            end
            if item.label~=nil then
                C.string(item.label,"list_display.label",64)
                if item.label:find("%c") then invalid("list_display.label","列表标签不能含控制字符") end
            end
        end
    end
    return out
end
function C.metadata(value)
    if value==nil then return nil end
    if type(value)~="table" then invalid("manga.metadata","列表扩展信息必须为对象") end
    local out,count={},0
    for key,text in pairs(value) do
        count=count+1
        if count>16 then invalid("manga.metadata","列表扩展信息超过限额","resource_limit") end
        if type(key)~="string" or #key>64 or not key:match("^[a-z][a-z0-9_]*$") then
            invalid("manga.metadata","列表扩展字段名无效")
        end
        C.string(text,"manga.metadata."..key,512)
        if text:find("%c") then invalid("manga.metadata","列表扩展信息不能含控制字符") end
        out[key]=text
    end
    return out
end
function C.manga(v,legacy)
    if type(v)~="table" then invalid("manga","作品返回值无效") end
    local out=C.copy(v,not legacy)
    out._list_display=nil -- Only the sealed source configuration may set this.
    out.metadata=C.metadata(out.metadata)
    out.id=C.string(legacy and tostring(out._id or "") or out.id,"manga.id")
    out.title=C.string(out.title,"manga.title",4096)
    out.cover=out.cover or out.thumb
    if not legacy then
        for _,key in ipairs({"finished","favorite"}) do
            if out[key]~=nil and type(out[key])~="boolean" then invalid("manga."..key,"作品状态类型无效") end
        end
        for _,key in ipairs({"cover","author","description","updated_at"}) do
            if out[key]~=nil and type(out[key])~="string" then invalid("manga."..key,"作品可选字段类型无效") end
        end
        for _,key in ipairs({"tags","categories"}) do
            if out[key]~=nil then
                C.array(out[key],"manga."..key)
                for _,tag in ipairs(out[key]) do C.string(tag,"manga."..key,4096) end
            end
        end
        if out.stats~=nil then
            if type(out.stats)~="table" then invalid("manga.stats","作品统计无效") end
            for _,n in pairs(out.stats) do if type(n)~="number" or n<0 or n%1~=0 then invalid("manga.stats","作品统计无效") end end
        end
    end
    return out
end
function C.comment(v,legacy)
    local out=C.copy(v,not legacy)
    if type(out)~="table" then invalid("comment","评论返回值无效") end
    out.id=C.string(legacy and tostring(out._id or "") or out.id,"comment.id")
    if type(out.content)~="string" or type(out.author)~="table" then invalid("comment","评论正文或作者无效") end
    if out.content_complete~=nil and type(out.content_complete)~="boolean" then invalid("comment","评论完整性标记无效") end
    if out.replies then
        C.array(out.replies,"comment.replies")
        for i,r in ipairs(out.replies) do out.replies[i]=C.comment(r,legacy) end
    end
    return out
end
function C.chapter(v,manga_id,position,legacy,policy)
    if type(v)~="table" then invalid("chapter","章节返回值无效") end
    local out=C.copy(v,not legacy)
    if legacy then
        if policy=="legacy" then
            if out.order==nil then invalid("chapter.order","历史章节标识无效") end
            out.id=tostring(out._id or out.order)
        else
            if type(out._id)~="string" or #out._id>160 or not out._id:match("^[%w_%-]+$") then
                invalid("chapter.id","章节必须提供唯一、稳定的 _id")
            end
            out.id=out._id; out.order="c_"..out.id
        end
    end
    C.string(out.id,"chapter.id")
    if not legacy and out.manga_id~=nil and out.manga_id~=manga_id then invalid("chapter.manga_id","章节作品身份不符") end
    out.manga_id=C.string(legacy and tostring(manga_id or "") or manga_id,"chapter.manga_id")
    out.title=C.string(out.title,"chapter.title",4096)
    out.position=position
    return out
end
function C.context(value)
    if value==nil then return nil end
    local out=C.copy(value,true)
    if type(out)~="table" then invalid("context","页面上下文必须为 JSON 对象") end
    local function scan(v)
        for k,item in pairs(v) do
            local name=tostring(k):lower()
            if name:find("token",1,true) or name:find("password",1,true) or name:find("cookie",1,true)
                or name:find("secret",1,true) or name=="auth" or name=="credentials"
                or name=="headers" or name=="authorization" or name=="module" or name=="path" or name=="local_path" then
                invalid("context","页面上下文不能保存凭据、路径或模块")
            end
            if type(item)=="string" and (item:match("^https?://") or item:sub(1,1)=="/") then invalid("context","页面上下文不能保存 URL 或本地路径") end
            if type(item)=="table" then scan(item) end
        end
    end
    scan(out)
    if #require("rapidjson").encode(out)>16384 then invalid("context","页面上下文超过限额","resource_limit") end
    return out
end
function C.pages(value,legacy)
    if type(value)~="table" then invalid("pages","图片列表返回值无效") end
    if legacy then
        C.array(value.images,"pages.items")
        for i,item in ipairs(value.images) do
            local url=type(item)=="string" and item or type(item)=="table" and item.url
            if type(url)~="string" or url=="" then invalid("pages."..i,"第 "..i.." 页图片地址无效") end
        end
    end
    value=C.copy(value,not legacy)
    local input=legacy and value.images or value.items
    if not legacy and value.complete~=true then invalid("pages.complete","图片列表必须完整") end
    C.array(input,"pages.items")
    local out=legacy and C.copy(value,false) or {}
    out.images=nil; out.items={}; out.complete=true
    for i,v in ipairs(input) do
        local page
        if legacy then
            if type(v)=="string" then page={resource={url=v}}
            elseif type(v)=="table" then
                page=C.copy(v,false); page.resource={url=page.url}
            end
        else page=C.copy(v,true) end
        if type(page)~="table" or type(page.resource)~="table" then invalid("pages."..i,"第 "..i.." 页图片地址无效") end
        local ok=pcall(C.url,page.resource.url,"pages."..i..".url")
        if not ok then invalid("pages."..i,"第 "..i.." 页图片地址无效") end
        if not legacy and page.index~=i then invalid("pages."..i..".index","页码必须从 1 连续递增") end
        page.index=i; page.context=C.context(page.context)
        -- Original image URL is transient. It is never copied into an offline manifest.
        out.items[i]=page
    end
    return out
end
function C.list(value,kind,legacy,opts)
    opts=opts or {}
    if type(value)~="table" then invalid(kind,"列表返回值无效") end
    value=C.copy(value,not legacy)
    local key=({manga="comics",chapter="episodes",comment="comments",reply="replies"})[kind]
    local input=legacy and value[key] or value.items
    C.array(input,"list.items")
    local out,seen={items={},has_more=false},{}
    for i,v in ipairs(input) do
        local item
        if kind=="manga" then item=C.manga(v,legacy)
        elseif kind=="chapter" then item=C.chapter(v,opts.manga_id,i,legacy,opts.identity_policy)
        else item=C.comment(v,legacy) end
        local identity=kind=="chapter" and legacy and opts.identity_policy=="legacy" and tostring(item.order) or item.id
        if seen[identity] then invalid("list.items."..i,"列表身份重复") end
        seen[identity]=true; out.items[i]=item
    end
    if legacy then
        local page=tonumber(value.page) or opts.page or 1
        local pages=tonumber(value.pages)
        out.has_more=pages~=nil and page<pages or value.has_more==true
        out.next=out.has_more and {page=page+1} or nil
        out.total=tonumber(value.total)
        out.page=page; out.pages=pages
    else
        if type(value.has_more)~="boolean" then invalid("list.has_more","列表必须声明 has_more") end
        out.has_more=value.has_more; out.next=C.context(value.next); out.total=value.total
        if out.has_more and (not out.next or not next(out.next)) then invalid("list.next","续页数据缺失") end
        if not out.has_more and out.next~=nil then invalid("list.next","结束列表不能携带续页数据") end
        if value.pagination~=nil then
            local p=value.pagination
            if (kind~="manga" and kind~="comment" and kind~="reply") or type(p)~="table" or p.mode~="page" then invalid("list.pagination","页码分页声明无效") end
            for _,key in ipairs({"page","pages","page_size"}) do
                local n=p[key]
                local limit=key=="page_size" and C.MAX_ITEMS or 1000000
                if type(n)~="number" or n<1 or n%1~=0 or n>limit then invalid("list.pagination."..key,"分页范围无效") end
            end
            if p.page>p.pages or #out.items>p.page_size or out.has_more~=(p.page<p.pages)
                or out.has_more and out.next.page~=p.page+1 then invalid("list.pagination","分页声明与结果不一致") end
            for key in pairs(out.next or {}) do
                if key~="page" then invalid("list.pagination","页码分页不能依赖额外游标") end
            end
            out.pagination={mode="page",page=p.page,pages=p.pages,page_size=p.page_size}
        end
    end
    if out.total~=nil and (type(out.total)~="number" or out.total<0 or out.total%1~=0) then invalid("list.total","列表总数无效") end
    return out
end
function C.protect(operation,fn,...)
    local ok,result=pcall(fn,...)
    if ok then return true,result,nil end
    if type(result)=="table" and codes[result.code] then result.operation=operation; return false,nil,result end
    return false,nil,C.error("invalid_response","源返回值无效",operation)
end
function C.sourceError(value,operation)
    if type(value)=="table" and codes[value.code] and type(value.message)=="string" and type(value.retryable)=="boolean" then
        return C.error(value.code,value.message,operation,value.field,value.retryable)
    end
    return C.error("network",type(value)=="string" and value or "源请求失败",operation,nil,false)
end
function C.isError(value)
    return type(value)=="table" and codes[value.code]==true and type(value.message)=="string"
        and value.message~="" and type(value.retryable)=="boolean"
end
return C
