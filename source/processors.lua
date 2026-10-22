local C=require("source.contract")
local P={}
local contexts={}
function P.attach(context)
    contexts[context.pkg.manifest.id..":"..context.digest]=context
end
function P.legacy(source,stage,url)
    local method=stage=="render" and "imageRenderPost" or "imagePost"
    if type(source[method])~="function" then return nil end
    local desc=source[method](source,url)
    if desc==nil then return nil end
    assert(type(desc)=="table" and type(desc.module)=="string" and type(desc.fn)=="string","图片处理器无效")
    local id,digest,name=desc.module:match("^picayomi_ext%.([%w_%-]+)%.([%w_%-]+)%.([%w_%.%-]+)$")
    assert(id==source.identifier and digest==source._extension_digest,"图片处理器必须来自当前源包")
    return {source_id=id,digest=digest,module=name,fn=desc.fn,stage=stage,version=1,legacy=true,
        context=C.context(desc.context),online_argument=desc.context==nil and url or nil}
end
function P.bind(id,digest,registered,stage,desc,context)
    if desc==nil then return nil end
    assert(type(desc)=="table" and type(desc.name)=="string","图片处理器声明无效")
    local entry=assert(registered[desc.name],"图片处理器未注册")
    assert(entry.stage==stage and desc.version==entry.version,"图片处理器阶段或版本不符")
    return {source_id=id,digest=digest,name=desc.name,stage=stage,version=entry.version,context=C.context(context)}
end
function P.persist(desc)
    if desc==nil then return nil end
    assert(desc.online_argument==nil,"旧源处理器缺少离线上下文，请升级源后重新下载")
    return C.copy(desc,true)
end
function P.resolve(desc)
    assert(type(desc)=="table" and (desc.stage=="file" or desc.stage=="render"),"图片处理器描述无效")
    local context=contexts[tostring(desc.source_id)..":"..tostring(desc.digest)]
    if not context then context=require("source.extensions.manager").instance():processorContext(desc) end
    local m=context.pkg.manifest
    assert(m.id==desc.source_id and context.digest==desc.digest,"图片处理包不匹配")
    local entry
    if desc.legacy then
        assert(m.api_version<3,"新源不能使用旧处理器")
        entry={module=desc.module,fn=desc.fn}
    else
        entry=assert((context.processors or {})[desc.name],"图片处理器未注册")
        assert(entry.stage==desc.stage and entry.version==desc.version,"图片处理器版本不符")
    end
    assert(type(entry.module)=="string" and entry.module:match("^[%w_%-%.]+$")
        and type(entry.fn)=="string" and entry.fn:match("^[%w_]+$"),"图片处理器入口无效")
    return function(...)
        local sdk=require("source.extensions.sdk")
        local previous=sdk.processing(context.ctx,true)
        local args={...}
        local ok,result,err=pcall(function()
            local mod=context.require(entry.module)
            local fn=assert(type(mod)=="table" and type(mod[entry.fn])=="function" and mod[entry.fn],"图片处理器缺失")
            return fn(unpack(args))
        end)
        sdk.processing(context.ctx,previous)
        assert(ok,"图片处理器执行失败")
        return result,err
    end
end
function P.file(desc,path,url)
    if not desc then return true end
    local ok,result=pcall(function()
        local fn=P.resolve(desc)
        local context=desc.context or desc.online_argument or url
        local result,err
        if desc.legacy then result,err=fn(path,context)
        else result,err=require("source.image_service").processFile(fn,path,context) end
        assert(desc.legacy and result~=false or result==true,err or "文件处理器未成功")
        assert(require("util.image_size").from_file(path),"文件处理器输出不是可读图片")
        return true
    end)
    if not ok then os.remove(path..".processing"); return false,"图片文件处理失败" end
    return result
end
function P.regionPlan(desc,w,h)
    if not desc or desc.legacy then return nil end
    local ok,plan=pcall(function()
        return require("source.image_service").regionPlan(P.resolve(desc),w,h,desc.context or {})
    end)
    return ok and plan or nil
end
function P.render(desc,bb,url)
    if not desc then return bb end
    local ok,out=pcall(function()
        local fn=P.resolve(desc)
        if desc.legacy then return assert(fn(bb,desc.context or desc.online_argument or url)) end
        local service=require("source.image_service")
        return service.process(fn,bb,desc.context or {})
    end)
    if not ok or not out then return nil,"图片渲染处理失败" end
    if out~=bb then bb:free() end
    return out
end
return P
