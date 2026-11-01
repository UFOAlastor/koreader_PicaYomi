-- Small, local source-resolution filters using the host's Leptonica library.
-- Work is transactional: allocation/budget failure leaves the input untouched.
local ffi=require('ffi')
local BB=require('ffi/blitbuffer')
local M={HALO=3}
local lib
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
local function apply_piece(bb,mode,budget)
    if mode~='denoise_sharpen' and mode~='sharpen'then return true end
    local kind=bb:getType()
    local count=({[BB.TYPE_BB8]=1,[BB.TYPE_BB8A]=2,[BB.TYPE_BBRGB24]=3,[BB.TYPE_BBRGB32]=4})[kind]
    if not count then return false,'unsupported_bitmap' end
    local w,h=tonumber(bb.w),tonumber(bb.h)
    if w<8 or h<8 then return true end
    local required=M.workspace(w,h,count>=3)
    if required>(budget or 0)then return false,'memory_budget',required end
    local owned={}
    local function keep(p)assert(p~=nil,'native allocation failed');owned[#owned+1]=p;return p end
    local ok,err=pcall(function()
        local l=backend()
        local src=keep(l.pixCreate(w,h,count>=3 and 32 or 8))
        local raw=ffi.cast('uint8_t*',l.pixGetData(src));local stride=tonumber(l.pixGetWpl(src))*4
        local input=ffi.cast('uint8_t*',bb.data);local bs=tonumber(bb.stride)
        local inverse=bb:getInverse()==1
        for y=0,h-1 do
            local a,b=input+y*bs,raw+y*stride
            if count==1 or count==4 then ffi.copy(b,a,w*count)
            else for x=0,w-1 do
                if count==2 then b[x]=a[x*2]
                else local i,j=x*3,x*4;b[j]=a[i];b[j+1]=a[i+1];b[j+2]=a[i+2];b[j+3]=255 end
            end end
            if inverse then for x=0,w-1 do for c=0,(count>=3 and 2 or 0)do local i=x*(count>=3 and 4 or 1)+c;b[i]=255-b[i]end end end
        end
        if ffi.abi('le')then assert(l.pixEndianByteSwap(src)==0)end
        local denoised=mode=='denoise_sharpen' and keep(l.pixBlockBilateralExact(src,0.7,24))or src
        local result=keep(l.pixUnsharpMaskingFast(denoised,1,0.35,3))
        if ffi.abi('le')then assert(l.pixEndianByteSwap(result)==0)end
        local output=ffi.cast('uint8_t*',l.pixGetData(result));local os=tonumber(l.pixGetWpl(result))*4
        -- All fallible native operations have finished. Preserve alpha/padding.
        for y=0,h-1 do
            local a,b=input+y*bs,output+y*os
            if count==1 and not inverse then ffi.copy(a,b,w)
            else for x=0,w-1 do
                local i,j=x*count,x*(count>=3 and 4 or 1)
                for c=0,(count>=3 and 2 or 0)do a[i+c]=inverse and 255-b[j+c]or b[j+c]end
            end end
        end
    end)
    if lib then for i=#owned,1,-1 do local ptr=ffi.new('PIX*[1]',owned[i]);lib.pixDestroy(ptr)end end
    return ok,ok and nil or tostring(err),required
end
function M.apply(bb,mode,budget)
    local count=({[BB.TYPE_BB8]=1,[BB.TYPE_BB8A]=2,[BB.TYPE_BBRGB24]=3,[BB.TYPE_BBRGB32]=4})[bb:getType()]
    if not count or (mode~='sharpen' and mode~='denoise_sharpen')then return apply_piece(bb,mode,budget)end
    local w,h=tonumber(bb.w),tonumber(bb.h)
    local full=M.workspace(w,h,count>=3)
    if full<=(budget or 0)or h<8 then return apply_piece(bb,mode,budget)end
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
            local good,reason=apply_piece(piece,mode,budget-output_bytes-w*(last-first)*count)
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
return M
