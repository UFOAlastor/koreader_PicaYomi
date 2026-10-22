-- Opaque image/file handles. Only the host allocates, commits and frees buffers.
local S={}
local bitmaps=setmetatable({},{__mode="k"})
local files=setmetatable({},{__mode="k"})
local arena
local arena_handles
function S.wrapBitmap(bb)
    local h={};bitmaps[h]=bb
    if arena_handles then arena_handles[#arena_handles+1]=h end
    return h
end
function S.unwrapBitmap(h) return bitmaps[h] end
function S.wrapFile(path) local h={}; files[h]=path; return h end
function S.dimensions(handle)
    local bb=assert(bitmaps[handle],"invalid image handle")
    return bb:getWidth(),bb:getHeight()
end
function S.reorderBands(handle,num)
    local bb=assert(bitmaps[handle],"invalid image handle")
    assert(type(num)=="number" and num%1==0 and num>=2 and num<=512,"invalid band count")
    local w,h=bb:getWidth(),bb:getHeight()
    assert(h>=num,"image is shorter than its bands")
    assert(not arena or #arena==0,"one bitmap output per processor call")
    if type(bb)=="table" and bb._region then
        assert(not bb.bands,"multiple region transforms are unsupported")
        return S.wrapBitmap({_region=true,bands=num,width=w,height=h,
            getWidth=function() return w end,getHeight=function() return h end})
    end
    local out=require("ffi/blitbuffer").new(w,h,bb:getType())
    if arena then arena[#arena+1]=out end
    local over,band=h%num,math.floor(h/num)
    local ok,err=pcall(function()
        for i=0,num-1 do
            local move=band
            local ys,yd=h-band*(i+1)-over,band*i
            if i==0 then move=move+over else yd=yd+over end
            out:blitFrom(bb,0,yd,0,ys,w,move)
        end
    end)
    if not ok then
        if arena then arena[#arena]=nil end
        out:free(); error(err,0)
    end
    return S.wrapBitmap(out)
end
function S.process(fn,bb,context)
    local previous,previous_handles=arena,arena_handles
    local allocated,handles={},{};arena=allocated;arena_handles=handles
    local ok,result=pcall(fn,S.wrapBitmap(bb),context)
    local out=ok and S.unwrapBitmap(result) or nil
    for _,handle in ipairs(handles) do bitmaps[handle]=nil end
    arena,arena_handles=previous,previous_handles
    for _,buffer in ipairs(allocated) do if buffer~=out then buffer:free() end end
    assert(out,"处理器未返回图片句柄")
    return out
end
-- Run the registered processor against a dimensions-only handle. Only host
-- operations with a proven region mapping participate; older arbitrary bitmap
-- processors retain their budgeted full-image route.
function S.regionPlan(fn,w,h,context)
    local virtual={_region=true,width=w,height=h,
        getWidth=function() return w end,getHeight=function() return h end}
    local out=S.process(fn,virtual,context)
    assert(out._region,"processor has no region equivalent")
    return out
end
function S.regionPieces(plan,y,height)
    local result={}
    if not plan.bands then return {{source_y=y,target_y=0,height=height}} end
    local h,num=plan.height,plan.bands
    local band,over=math.floor(h/num),h%num
    for i=0,num-1 do
        local count=band+(i==0 and over or 0)
        local ys=h-band*(i+1)-over
        local yd=band*i+(i==0 and 0 or over)
        local first,last=math.max(y,yd),math.min(y+height,yd+count)
        if last>first then result[#result+1]={source_y=ys+first-yd,target_y=first-y,height=last-first} end
    end
    return result
end
function S.processFile(fn,path,context)
    local handle=S.wrapFile(path)
    local ok,result,err=pcall(fn,handle,context)
    files[handle]=nil
    assert(ok,"文件处理器执行失败")
    return result,err
end
function S.readFile(handle,limit)
    local path=assert(files[handle],"invalid file handle")
    limit=math.min(tonumber(limit) or 2097152,2097152)
    local f=assert(io.open(path,"rb")); local data=f:read(limit+1); f:close()
    assert(#data<=limit,"processor input exceeds limit")
    return data
end
function S.writeFile(handle,bytes)
    local path=assert(files[handle],"invalid file handle")
    assert(type(bytes)=="string" and #bytes>0 and #bytes<=2097152,"processor output exceeds limit")
    local temp=path..".processing"
    local f=assert(io.open(temp,"wb")); local ok,err=f:write(bytes); f:close()
    if not ok then os.remove(temp); error(err,0) end
    assert(os.rename(temp,path))
    return true
end
function S.api()
    return {dimensions=S.dimensions,reorderBands=S.reorderBands,readFile=S.readFile,writeFile=S.writeFile}
end
return S
