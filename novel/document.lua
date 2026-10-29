-- Local HTML + closed illustration directory. No EPUB, remote references,
-- credentials or signed image URLs are persisted in the manifest.
local Store=require("source.extensions.storage")
local json=require("rapidjson")
local sha=require("ffi/sha2").sha256
local lfs=require("libs/libkoreader-lfs")
local M={}
local function escape(s)
    return (s:gsub("&","&amp;"):gsub("<","&lt;"):gsub(">","&gt;"):gsub('"',"&quot;"))
end
local function guard(call)
    if call and (call.cancelled or call.isCancelled and call.isCancelled()) then error("novel preparation cancelled") end
    if call and call.deadline and require("socket").gettime()>=call.deadline then error("novel preparation timed out") end
end
function M.key(source,book,chapter)
    for _,s in ipairs({source,book,chapter}) do assert(type(s)=="string" and #s>0 and #s<8192 and not s:find("%z"),"invalid novel identity") end
    return sha(source.."\0"..book.."\0"..chapter)
end
local function digest(s) return type(s)=="string" and #s==64 and s:match("^%x+$") end
function M.cached(root,source,book,chapter)
    local key=M.key(source,book,chapter)
    local raw=Store.read(root.."/index/"..key..".json",1024)
    if not raw then return nil end
    local ok,p=pcall(json.decode,raw)
    if not ok or type(p)~="table" or not digest(p.generation) then return nil end
    local valid,doc=pcall(M.load,root,key,p.generation)
    return valid and doc or nil
end
function M.load(root,key,generation)
    assert(digest(key) and digest(generation),"invalid document identity")
    local dir=root.."/chapters/"..key.."/"..generation
    local raw=Store.read(dir.."/manifest.json",65536)
    if not raw then return nil,"chapter incomplete" end
    local m=json.decode(raw)
    assert(type(m)=="table" and m.version==1 and m.key==key and m.generation==generation,"invalid document manifest")
    assert(type(m.files)=="table" and #m.files>=1 and #m.files<=65,"invalid document files")
    local seen={}
    for _,file in ipairs(m.files) do
        assert(type(file.path)=="string" and (file.path=="chapter.html" or file.path:match("^images/%d%d%d%d%.png$") or file.path:match("^images/%d%d%d%d%.jpeg$")) and not seen[file.path],"invalid asset path")
        seen[file.path]=true
        assert(digest(file.digest),"invalid asset digest")
        local bytes=Store.read(dir.."/"..file.path,4*1024*1024)
        if not bytes or #bytes~=file.bytes or sha(bytes)~=file.digest then return nil,"chapter assets incomplete or damaged" end
    end
    assert(seen["chapter.html"],"missing chapter HTML")
    return {path=dir.."/chapter.html",key=key,generation=generation,root=root,manifest=m}
end
function M.prepare(session,options)
    local key=M.key(session.metadata.id,options.book,options.chapter)
    local root=assert(options.root)
    local stage
    local phase,image_number,image_count="body",0,0
    local clock=require("socket").gettime
    local began=clock()
    local diag=require("util.diag")
    local function cleanup()
        if not stage then return end
        local images=stage.."/images"
        if lfs.attributes(images,"mode")=="directory" then
            for file in lfs.dir(images) do if file~="." and file~=".." then os.remove(images.."/"..file) end end
            lfs.rmdir(images)
        end
        for _,file in ipairs({"chapter.html","chapter.html.tmp","manifest.json","manifest.json.tmp"}) do os.remove(stage.."/"..file) end
        lfs.rmdir(stage)
    end
    if options.on_cleanup then options.on_cleanup(cleanup) end
    local success,result=pcall(function()
        guard(options.call)
        local function progress(stage,current,total)
            phase,image_number,image_count=stage,current or 0,total or 0
            if options.on_progress then options.on_progress({stage=stage,current=current,total=total})end
        end
        progress("body")
        local ok,html,err=session:invoke("parseChapter",{options.chapter},options.call)
        if not ok then error(err or "chapter unavailable",0) end
        local cleaned=session:normalize(html)
        progress("images",0,#cleaned.assets)
        guard(options.call)
        local unique=os.tmpname();os.remove(unique)
        stage=root.."/staging/"..key.."-"..assert(unique:match("([^/]+)$"))
        Store.mkdir(stage.."/images")
        local files,total={},0
        local signatures={}
        local function save(path,bytes)
            total=total+#bytes;assert(total<=12*1024*1024,"chapter resource limit")
            Store.write(stage.."/"..path,bytes)
            files[#files+1]={path=path,bytes=#bytes,digest=sha(bytes)}
            signatures[#signatures+1]=path.."\0"..sha(bytes)
        end
        local page_url=require("socket.url").absolute(session.metadata.site,options.chapter)
        for number,asset in ipairs(cleaned.assets) do
            image_number=number
            guard(options.call)
            assert(asset.path:match("^images/%d%d%d%d%.img$"),"invalid illustration path")
            local url=require("socket.url").absolute(page_url,asset.url)
            local parsed=require("socket.url").parse(url)
            assert(parsed and parsed.scheme=="https" and parsed.host and not parsed.userinfo,"invalid illustration URL")
            local headers={}
            for name,value in pairs((session.metadata.imageRequestInit or {}).headers or {}) do
                local lower=name:lower()
                assert(lower~="cookie" and lower~="authorization" and not (name..value):find("[%c]"),"credentialed illustrations unsupported")
                headers[name]=value
            end
            local timeout=20
            if options.call and options.call.deadline then timeout=math.min(timeout,options.call.deadline-require("socket").gettime()) end
            local request={method="GET",url=url,headers=headers}
            if session.imageRequest then request=session:imageRequest(url,options.call) end
            local response,download_error=options.http(request,math.min(timeout,request.timeout or timeout),options.call,stage.."/"..asset.path..".download")
            guard(options.call)
            if require("source.contract").isError(download_error)then
                download_error.message=string.format("第 %d/%d 张插图加载失败，请重试。",image_number,image_count)
                error(download_error,0)
            end
            assert(response and response.status==200 and type(response.body)=="string" and #response.body<=4*1024*1024,"illustration download failed: "..tostring(download_error or "invalid response"))
            local w,h,format=require("util.image_size").from_data(response.body)
            assert(w and (format=="png" or format=="jpeg" or format=="webp"),"unsupported illustration")
            if w*h>4*1024*1024 then
                -- Two-page light-novel illustrations commonly exceed 4 MP.
                -- Reuse the comic decoder's bounded native scaling rather than
                -- allocating the full image or dropping the complete chapter.
                assert(format=="jpeg" or format=="webp","oversized illustration has no bounded decoder")
                assert(w<=8192 and h<=8192 and w*h<=24*1024*1024,"illustration dimensions exceed limit")
                local input=stage.."/"..asset.path
                Store.write(input,response.body)
                local tw,th=require("util.image_guard").fit_dimensions(w,h,12*1024*1024)
                local zoom=math.min(tw/w,th/h)
                if format=="jpeg" then
                    for _,denom in ipairs({2,4,8}) do
                        if math.ceil(w/denom)*math.ceil(h/denom)<=3*1024*1024 then zoom=1/denom;break end
                    end
                end
                -- The region API also limits progressive-JPEG coefficients
                -- and WebP workspace, even when requesting the whole image.
                local memory=require("util.memory_guard").instance()
                local snapshot=memory:snapshot()
                local budget=math.min(40*1024*1024,snapshot.available and memory:prepare_decode() or 40*1024*1024)
                local bitmap,decode_error=require("util.scaled_decode").decode_region(input,format,0,h,true,
                    budget,zoom,response.body)
                assert(bitmap,"bounded illustration decode failed: "..tostring(decode_error))
                local target=input:gsub("%.img$",".png")
                local wrote=pcall(bitmap.writePNG,bitmap,target)
                bitmap:free();os.remove(input)
                assert(wrote,"illustration conversion failed")
                response.body=assert(Store.read(target,4*1024*1024),"converted illustration too large")
                w,h,format=require("util.image_size").from_data(response.body)
                assert(w and w*h<=4*1024*1024 and format=="png","converted illustration exceeds limit")
            end
            -- Some CDNs return WebP even at a .jpg URL. Normalize it for crengine.
            if format=="webp" then
                local bitmap=assert(require("ui/renderimage"):renderImageData(response.body,#response.body,false),"WebP decode failed")
                local target=stage.."/images/"..asset.path:match("(%d%d%d%d)%.img$")..".png"
                local wrote=pcall(bitmap.writePNG,bitmap,target)
                bitmap:free()
                assert(wrote,"WebP conversion failed")
                response.body=assert(Store.read(target,4*1024*1024),"converted illustration too large")
                format="png"
            end
            local image_path=asset.path:gsub("%.img$","."..format)
            cleaned.html=cleaned.html:gsub(asset.path:gsub("(%W)","%%%1"),function() return image_path end)
            save(image_path,response.body)
            local image=require("ffi/pic").openDocument(stage.."/"..image_path)
            assert(image,"illustration decode failed");image:close()
            progress("images",number,#cleaned.assets)
        end
        progress("commit",#cleaned.assets,#cleaned.assets)
        local title=options.title or ""
        assert(type(title)=="string" and #title<=4096,"invalid chapter title")
        local document='<!DOCTYPE html><html><head><meta charset="utf-8"><title>'..escape(title)
            ..'</title></head><body>'..cleaned.html..'</body></html>'
        save("chapter.html",document)
        local generation=sha(table.concat(signatures,"\0"))
        Store.json(stage.."/manifest.json",{version=1,key=key,generation=generation,files=files})
        guard(options.call)
        local parent=root.."/chapters/"..key
        Store.mkdir(parent)
        local destination=parent.."/"..generation
        if lfs.attributes(destination,"mode") then
            local valid,existing=pcall(M.load,root,key,generation)
            if valid and existing then cleanup()
            else
                -- Keep damaged files for recovery while atomically replacing them.
                local quarantine=root.."/quarantine/"..key.."-"..generation.."-"..unique:match("([^/]+)$")
                Store.mkdir(root.."/quarantine")
                assert(os.rename(destination,quarantine),"cannot preserve damaged chapter")
                if not os.rename(stage,destination) then
                    os.rename(quarantine,destination);error("cannot repair chapter")
                end
            end
        else assert(os.rename(stage,destination),"cannot commit complete chapter") end
        stage=nil
        local prepared=assert(M.load(root,key,generation))
        Store.json(root.."/index/"..key..".json",{generation=generation})
        progress("ready",#cleaned.assets,#cleaned.assets)
        return prepared
    end)
    if not success then
        cleanup()
        if require("source.contract").isError(result) then return false,nil,result end
        local redact=require("util.log_redact")
        local reason=redact.text(tostring(result)):gsub("https?://[^%s\"'<>]+",redact.url):sub(1,512)
        require("util.logger").warn("Picayomi novel preparation failed: "..reason)
        local message=phase=="images" and string.format("第 %d/%d 张插图加载失败，请重试。",image_number,image_count)
            or phase=="body" and "章节正文处理失败，请重试。" or "章节保存失败，请检查剩余存储空间后重试。"
        return false,nil,{code="chapter_unavailable",message=message}
    end
    if diag.enabled then diag.mark(string.format("novel prepare %.3fs images=%d",clock()-began,image_count))end
    return true,result,nil
end
function M.savePosition(document,xpointer)
    assert(type(xpointer)=="string" and #xpointer>0 and #xpointer<=8192,"invalid text position")
    Store.json((document.progress_root or document.root.."/progress").."/"..document.key..".json",{
        version=1,key=document.key,generation=document.generation,xpointer=xpointer})
end
function M.position(document)
    local raw=Store.read((document.progress_root or document.root.."/progress").."/"..document.key..".json",16384)
    if not raw then return nil end
    local ok,p=pcall(json.decode,raw)
    if ok and type(p)=="table" and p.version==1 and p.key==document.key and p.generation==document.generation
        and type(p.xpointer)=="string" and #p.xpointer<=8192 then return p.xpointer end
    return nil
end
function M.remove(root,key,on_step)
    assert(digest(key),"invalid document identity")
    local parent=root.."/chapters/"..key
    local nodes=0
    local function remove_tree(path,depth)
        if on_step then on_step()end
        nodes=nodes+1;assert(nodes<=1024 and depth<=8,"unexpected document directory")
        local attributes=lfs.symlinkattributes(path)
        if not attributes then return end
        if attributes.mode=="directory" then
            for name in lfs.dir(path) do if name~="." and name~=".." then remove_tree(path.."/"..name,depth+1) end end
            assert(lfs.rmdir(path))
        else assert(os.remove(path)) end
    end
    if lfs.attributes(parent,"mode")=="directory" then
        for generation in lfs.dir(parent) do
            if digest(generation) then
                remove_tree(parent.."/"..generation,0)
            end
        end
        assert(lfs.rmdir(parent))
    end
    os.remove(root.."/index/"..key..".json")
    return true
end
return M
