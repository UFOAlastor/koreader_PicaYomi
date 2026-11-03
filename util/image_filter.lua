-- Small, local source-resolution filters using the host's Leptonica library.
-- Work is transactional: allocation/budget failure leaves the input untouched.
local ffi=require('ffi')
local BB=require('ffi/blitbuffer')
local M={HALO=3}
local lib
local weights=ffi.new('double[511]')
for d=-255,255 do weights[d+255]=math.exp(-1/(2*0.7*0.7)-d*d/(2*24*24))end
-- Two local 1-D bilateral passes: approximate the 3x3 filter while
-- retaining intensity-dependent edge weights. Scratch is owned by the caller.
local function smooth(raw,w,h,stride,components,temp,ts)
    for c=0,(components==4 and 2 or 0)do
        for y=0,h-1 do
            local a,b=raw+y*stride,temp+y*ts
            for x=0,w-1 do
                local i=x*components+c
                local v=tonumber(a[i]);local l=tonumber(a[math.max(0,x-1)*components+c]);local r=tonumber(a[math.min(w-1,x+1)*components+c])
                local wl,wr=weights[l-v+255],weights[r-v+255]
                b[i]=math.floor((v+l*wl+r*wr)/(1+wl+wr)+0.5)
            end
        end
        for y=0,h-1 do
            local b=raw+y*stride;local a=temp+y*ts
            local up,down=temp+math.max(0,y-1)*ts,temp+math.min(h-1,y+1)*ts
            for x=0,w-1 do
                local i=x*components+c
                local v,u,d=tonumber(a[i]),tonumber(up[i]),tonumber(down[i]);local wu,wd=weights[u-v+255],weights[d-v+255]
                b[i]=math.floor((v+u*wu+d*wd)/(1+wu+wd)+0.5)
            end
        end
    end
end

-- The separable filter is translation-invariant in intensity. A signed byte
-- stores its rounded correction for each pair of differences (range -7..7).
-- Build at most once, only when the original grant also covers this storage;
-- tight grants and allocation failure keep the original arithmetic path.
local DIFFERENCE_BYTES=511*511
local difference_table
local function lookup_for(pixels,budget,required)
    if pixels<32768 or required+DIFFERENCE_BYTES>budget or difference_table==false then return nil end
    if difference_table then return difference_table end
    local ok,value=pcall(function()
        local values=ffi.new('int8_t[?]',DIFFERENCE_BYTES)
        for a=-255,255 do for b=-255,255 do
            local wa,wb=weights[a+255],weights[b+255]
            values[(a+255)*511+b+255]=math.floor((a*wa+b*wb)/(1+wa+wb)+.5)
        end end
        return values
    end)
    difference_table=ok and value or false
    return difference_table or nil
end

local function smooth_lookup(raw,w,h,stride,components,temp,ts,differences)
    for c=0,(components==4 and 2 or 0)do
        for y=0,h-1 do
            local a,b=raw+y*stride,temp+y*ts
            for x=0,w-1 do
                local i=x*components+c
                local v=tonumber(a[i]);local l=tonumber(a[math.max(0,x-1)*components+c]);local r=tonumber(a[math.min(w-1,x+1)*components+c])
                b[i]=v+differences[(l-v+255)*511+r-v+255]
            end
        end
        for y=0,h-1 do
            local b=raw+y*stride;local a=temp+y*ts
            local up,down=temp+math.max(0,y-1)*ts,temp+math.min(h-1,y+1)*ts
            for x=0,w-1 do
                local i=x*components+c
                local v,u,d=tonumber(a[i]),tonumber(up[i]),tonumber(down[i])
                b[i]=v+differences[(u-v+255)*511+d-v+255]
            end
        end
    end
end


local function backend()
    if lib then return lib end
    require('ffi/leptonica_h')
    ffi.cdef[[
        PIX *pixCreate(int,int,int);
        unsigned int *pixGetData(PIX *);
        int pixGetWpl(const PIX *);
        int pixEndianByteSwap(PIX *);
        PIX *pixBlockBilateralExact(PIX *,float,float);
        PIX *pixUnsharpMaskingFast(PIX *,int,float,int);
        PIX *pixScaleLI(PIX *,float,float);
        int pixGetWidth(PIX *); int pixGetHeight(PIX *); int pixSetSpp(PIX *,int);
        PIX *pixErodeGray3(PIX *,int,int); PIX *pixDilateGray3(PIX *,int,int);
        PIX *pixColorMorph(PIX *,int,int,int);
        PIX *pixMinOrMax(PIX *,PIX *,PIX *,int);
    ]]
    local loaded=ffi.loadlib('leptonica',6)
    assert(loaded.pixBlockBilateralExact and loaded.pixUnsharpMaskingFast)
    lib=loaded
    return lib
end
function M.available()return pcall(backend)end
function M.workspace(w,h,color)
    -- Input/output, mirrored border, intermediate gray/RGB planes and native
    -- sharpener scratch. Deliberately conservative, within the existing budget.
    return (w+8)*(h+8)*(color and 40 or 12)+65536
end
local function apply_piece(bb,mode,budget,fast,resize)
    if mode~='denoise_sharpen' and mode~='sharpen' and mode~='denoise' and mode~='bounded_sharpen' and mode~='denoise_bounded_sharpen' and not resize then return true end
    local kind=bb:getType()
    local count=({[BB.TYPE_BB8]=1,[BB.TYPE_BB8A]=2,[BB.TYPE_BBRGB24]=3,[BB.TYPE_BBRGB32]=4})[kind]
    if not count then return false,'unsupported_bitmap' end
    local w,h=tonumber(bb.w),tonumber(bb.h)
    if (w<8 or h<8) and not resize then return true end
    local ow,oh=resize and resize.w or w,resize and resize.h or h
    local required=M.workspace(ow,oh,count>=3)
    if resize and not resize.sharpen then required=(w*h+ow*oh)*(count>=3 and 12 or 3)+65536 end
    if required>(budget or 0)then return false,'memory_budget',required end
    local owned={}
    local scratch,destination
    local function keep(p)assert(p~=nil,'native allocation failed');owned[#owned+1]=p;return p end
    local function release(p)
        for i=1,#owned do if owned[i]==p then owned[i]=false;break end end
        local ref=ffi.new('PIX*[1]',p);lib.pixDestroy(ref)
    end
    local ok,err=pcall(function()
        local l=backend()
        local src=keep(l.pixCreate(w,h,count>=3 and 32 or 8))
        local raw=ffi.cast('uint8_t*',l.pixGetData(src));local stride=tonumber(l.pixGetWpl(src))*4
        local input=ffi.cast('uint8_t*',bb.data);local bs=tonumber(bb.stride)
        local inverse=bb:getInverse()==1
        local native_rgb=count==3 and not inverse and bb:getRotation()==0 and BB.getUseCBB()
        if native_rgb then
            local view=BB.new(w,h,BB.TYPE_BBRGB32,raw,stride)
            view:blitFrom(bb,0,0,0,0,w,h);view:free()
        else for y=0,h-1 do
            local a,b=input+y*bs,raw+y*stride
            if count==1 or count==4 then ffi.copy(b,a,w*count)
            else for x=0,w-1 do
                if count==2 then b[x]=a[x*2]
                else local i,j=x*3,x*4;b[j]=a[i];b[j+1]=a[i+1];b[j+2]=a[i+2];b[j+3]=255 end
            end end
            if inverse then for x=0,w-1 do for c=0,(count>=3 and 2 or 0)do local i=x*(count>=3 and 4 or 1)+c;b[i]=255-b[i]end end end
        end end
        if fast and mode=='denoise_sharpen' then
            scratch=BB.new(w,h,count>=3 and BB.TYPE_BBRGB32 or BB.TYPE_BB8)
            local lookup=lookup_for(w*h,budget,required)
            if lookup then smooth_lookup(raw,w,h,stride,count>=3 and 4 or 1,ffi.cast('uint8_t*',scratch.data),tonumber(scratch.stride),lookup)
            else smooth(raw,w,h,stride,count>=3 and 4 or 1,ffi.cast('uint8_t*',scratch.data),tonumber(scratch.stride))end
            scratch:free();scratch=nil
        end
        if ffi.abi('le')then assert(l.pixEndianByteSwap(src)==0)end
        local scaled
        if resize then
            if count==4 then assert(l.pixSetSpp(src,4)==0)end
            scaled=keep(l.pixScaleLI(src,ow/w,oh/h))
            assert(l.pixGetWidth(scaled)==ow and l.pixGetHeight(scaled)==oh,'invalid resize dimensions')
            src=scaled
        end
        local denoised=(mode=='denoise_sharpen' or mode=='denoise' or mode=='denoise_bounded_sharpen') and not fast and keep(l.pixBlockBilateralExact(src,0.7,24))or src
        local result
        if mode=='denoise' or resize and (not resize.sharpen or ow<8 or oh<8)then result=denoised
        else result=keep(l.pixUnsharpMaskingFast(denoised,1,0.35,3))end
        if (mode=='bounded_sharpen' or mode=='denoise_bounded_sharpen') and result~=denoised then
            -- Bound the sharpener to its 3x3 input neighborhood in C. Release
            -- each bound before allocating the next to retain the same budget.
            for _,minimum in ipairs{true,false}do
                local bound
                if count>=3 then bound=keep(l.pixColorMorph(denoised,minimum and 2 or 1,3,3))
                elseif minimum then bound=keep(l.pixErodeGray3(denoised,3,3))
                else bound=keep(l.pixDilateGray3(denoised,3,3))end
                assert(l.pixMinOrMax(result,result,bound,minimum and 2 or 1)==result)
                release(bound)
            end
        end
        if ffi.abi('le')then assert(l.pixEndianByteSwap(result)==0)end
        local output=ffi.cast('uint8_t*',l.pixGetData(result));local os=tonumber(l.pixGetWpl(result))*4
        local alpha,alpha_stride
        if resize then
            destination=BB.new(ow,oh,kind);destination:setInverse(bb:getInverse())
            input=ffi.cast('uint8_t*',destination.data);bs=tonumber(destination.stride)
            if count==4 then
                if scaled~=result and ffi.abi('le')then assert(l.pixEndianByteSwap(scaled)==0)end
                alpha=ffi.cast('uint8_t*',l.pixGetData(scaled));alpha_stride=tonumber(l.pixGetWpl(scaled))*4
            end
        end
        -- All fallible native operations have finished. Preserve alpha/padding.
        if native_rgb then
            local view=BB.new(ow,oh,BB.TYPE_BBRGB32,output,os)
            local target=destination or bb
            target:blitFrom(view,0,0,0,0,ow,oh);view:free()
        else for y=0,oh-1 do
            local a,b=input+y*bs,output+y*os
            if count==1 and not inverse then ffi.copy(a,b,ow)
            else for x=0,ow-1 do
                local i,j=x*count,x*(count>=3 and 4 or 1)
                for c=0,(count>=3 and 2 or 0)do
                    local v=tonumber(b[j+c])
                    a[i+c]=inverse and 255-v or v
                end
                if alpha then a[i+3]=alpha[y*alpha_stride+j+3]end
            end end
        end end
    end)
    if scratch then scratch:free()end
    if lib then for i=#owned,1,-1 do if owned[i]then local ptr=ffi.new('PIX*[1]',owned[i]);lib.pixDestroy(ptr)end end end
    if not ok and destination then destination:free();destination=nil end
    return ok and (destination or true) or false,ok and nil or tostring(err),required
end
function M.apply(bb,mode,budget,fast)
    -- The Lua kernel is a JIT path; retain the native filter if JIT is off.
    fast=fast and require("jit").status()
    local count=({[BB.TYPE_BB8]=1,[BB.TYPE_BB8A]=2,[BB.TYPE_BBRGB24]=3,[BB.TYPE_BBRGB32]=4})[bb:getType()]
    if not count or (mode~='sharpen' and mode~='denoise_sharpen' and mode~='denoise' and mode~='bounded_sharpen' and mode~='denoise_bounded_sharpen')then return apply_piece(bb,mode,budget,fast)end
    local w,h=tonumber(bb.w),tonumber(bb.h)
    local full=M.workspace(w,h,count>=3)
    if full<=(budget or 0)or h<8 then return apply_piece(bb,mode,budget,fast)end
    local rows=64
    local output_bytes=w*h*count
    local function need(n)return output_bytes+w*(n+6)*count+M.workspace(w,n+6,count>=3)end
    while rows>8 and need(rows)>(budget or 0)do rows=math.floor(rows/2)end
    local required=need(rows)
    if required>(budget or 0)then return false,'memory_budget',required end
    local output,piece
    local ok,err=pcall(function()
        output=BB.new(w,h,bb:getType())
        local input=ffi.cast('uint8_t*',bb.data)
        local dst=ffi.cast('uint8_t*',output.data)
        for y=0,h-1,rows do
            local first,last=math.max(0,y-3),math.min(h,y+rows+3)
            first=math.min(first,math.max(0,last-8))
            piece=BB.new(w,last-first,bb:getType());piece:setInverse(bb:getInverse())
            local data=ffi.cast('uint8_t*',piece.data)
            for k=first,last-1 do ffi.copy(data+(k-first)*piece.stride,input+k*bb.stride,w*count)end
            local good,reason=apply_piece(piece,mode,budget-output_bytes-w*(last-first)*count,fast)
            assert(good,reason)
            for k=y,math.min(h,y+rows)-1 do ffi.copy(dst+k*output.stride,data+(k-first)*piece.stride,w*count)end
            piece:free();piece=nil
        end
        for y=0,h-1 do ffi.copy(input+y*bb.stride,dst+y*output.stride,w*count)end
    end)
    if piece then piece:free()end
    if output then output:free()end
    return ok,ok and nil or tostring(err),required
end
function M.upscale(bb,w,h,sharpen,budget)
    if bb:getType()~=BB.TYPE_BB8 and bb:getType()~=BB.TYPE_BBRGB24 and bb:getType()~=BB.TYPE_BBRGB32 then return nil,'unsupported_bitmap' end
    if bb:getRotation()~=0 then return nil,'unsupported_rotation' end
    local result,why,need=apply_piece(bb,'bounded_sharpen',budget,false,{w=w,h=h,sharpen=sharpen})
    return result or nil,why,need
end
return M
