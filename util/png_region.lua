-- Bounded PNG row decoder. zlib reports errors as return codes; no libpng
-- longjmp can cross an FFI callback. Keep only two source rows and the requested
-- strip, then let libpng's simplified API perform its usual color conversion.
-- PNG filters/Adam7: https://www.w3.org/TR/png-3/
-- z_stream ABI: https://www.zlib.net/manual.html
local ffi = require("ffi")
local bit = require("bit")
local ImageGuard = require("util.image_guard")
local R = {}
local zlib
local function load_zlib()
    if zlib then return zlib end
    require("ffi/zlib_h")
    if not pcall(ffi.typeof,"picayomi_z_stream") then ffi.cdef[[
        typedef struct {
            const unsigned char *next_in; unsigned int avail_in; unsigned long total_in;
            unsigned char *next_out; unsigned int avail_out; unsigned long total_out;
            const char *msg; void *state;
            void *(*zalloc)(void *, unsigned int, unsigned int);
            void (*zfree)(void *, void *); void *opaque;
            int data_type; unsigned long adler; unsigned long reserved;
        } picayomi_z_stream;
        const char *zlibVersion(void);
        int inflateInit_(picayomi_z_stream *, const char *, int);
        int inflate(picayomi_z_stream *, int);
        int inflateEnd(picayomi_z_stream *);
    ]] end
    zlib = ffi.loadlib("z", 1)
    return zlib
end
local function be(n)
    return string.char(math.floor(n/16777216)%256, math.floor(n/65536)%256, math.floor(n/256)%256, n%256)
end
local function uint(s)
    local a,b,c,d = s:byte(1,4)
    return ((a*256+b)*256+c)*256+d
end
local function paeth(a,b,c)
    local p=a+b-c
    local pa,pb,pc=math.abs(p-a),math.abs(p-b),math.abs(p-c)
    if pa<=pb and pa<=pc then return a elseif pb<=pc then return b else return c end
end
local passes={{0,0,8,8},{4,0,8,8},{0,4,4,8},{2,0,4,4},{0,2,2,4},{1,0,2,2},{0,1,1,2}}

function R.extract(path, y, height, color, budget, consume)
    budget=tonumber(budget) or 0
    if budget~=budget or budget==math.huge or budget<0 then budget=0 end
    local file, stream, initialized
    local allocations = {}
    local function free(p)
        if p and allocations[p] then allocations[p]=nil;ffi.C.free(p) end
    end
    local function alloc(n)
        local p=ffi.C.malloc(n)
        if p==nil then error("memory_budget",0) end
        p=ffi.cast("uint8_t*",p)
        allocations[p]=true
        ffi.fill(p,n)
        return p
    end
    local ok,result,origin,rows=pcall(function()
        local loaded,lib=pcall(load_zlib)
        if not loaded then return nil,"backend_unavailable" end
        local size=require("libs/libkoreader-lfs").attributes(path,"size")
        if not size or size>ImageGuard.FILE_LIMIT then return nil,"file_too_large" end
        file=io.open(path,"rb")
        if not file then return nil,"read_failed" end
        local consumed=0
        local next_gc=256*1024
        local function read(n)
            local data=file:read(n)
            if not data or #data~=n then error("corrupt_image",0) end
            consumed=consumed+n
            -- Small emergency grants cannot leave megabytes of dead input
            -- strings waiting for LuaJIT's heap-wide GC threshold.
            if budget<=3*1048576 and consumed>=next_gc then
                collectgarbage("collect")
                next_gc=consumed+256*1024
            end
            return data
        end
        if read(8)~="\137PNG\13\10\26\10" then return nil,"corrupt_image" end
        if read(8)~=be(13).."IHDR" then return nil,"corrupt_image" end
        local header=read(13)
        if uint(read(4))~=tonumber(lib.crc32(0,"IHDR"..header,17)) then return nil,"corrupt_image" end
        local w,h=uint(header:sub(1,4)),uint(header:sub(5,8))
        local depth,kind,compression,filter,interlace=header:byte(9,13)
        local channels=({[0]=1,[2]=3,[3]=1,[4]=2,[6]=4})[kind]
        local valid_depth=(depth==8 or depth==16) and kind~=3
            or kind==3 and (depth==1 or depth==2 or depth==4 or depth==8)
            or kind==0 and (depth==1 or depth==2 or depth==4)
        if not channels or not valid_depth or compression~=0 or filter~=0 or interlace>1
                or w<1 or h<1 or w>2147483647 or h>2147483647 then return nil,"corrupt_image" end
        if type(y)~="number" or type(height)~="number" or y~=y or height~=height then return nil,"invalid region" end
        y=math.max(0,math.floor(y));height=math.min(math.ceil(height),h-y)
        if height<1 then return nil,"invalid region" end
        local bits=channels*depth
        local rowbytes=math.ceil(w*bits/8)
        local rawbytes=(rowbytes+1)*height
        -- Input chunks, two rows, output plus encoded copies and native codec
        -- workspace. No allocation proportional to the full image height.
        local need=rawbytes*3+w*height*(color and 3 or 1)+rowbytes*3+2*1048576
        if rawbytes>2147483647 or rowbytes>2147483647 or need>budget then return nil,"memory_budget" end
        local raw=alloc(rawbytes)
        local capacity=rawbytes
        local metadata,metabytes={},0
        local function make_chunk(name,data)
            local crc=lib.crc32(0,name,4);crc=lib.crc32(crc,data,#data)
            return be(#data)..name..data..be(tonumber(crc))
        end
        local function encode_region()
            local header_bytes=be(w)..be(height)..header:sub(9,12).."\0"
            local prefix="\137PNG\13\10\26\10"..make_chunk("IHDR",header_bytes)..table.concat(metadata)
            local bound=tonumber(lib.compressBound(rawbytes))
            local encoded=alloc(#prefix+bound+24)
            ffi.copy(encoded,prefix,#prefix)
            local outlen=ffi.new("unsigned long[1]",bound)
            if lib.compress2(encoded+#prefix+8,outlen,raw,rawbytes,0)~=0 then error("memory_budget",0) end
            local count=tonumber(outlen[0])
            ffi.copy(encoded+#prefix,be(count).."IDAT",8)
            local crc=lib.crc32(0,encoded+#prefix+4,count+4)
            ffi.copy(encoded+#prefix+8+count,be(tonumber(crc))..make_chunk("IEND",""),16)
            return {data=encoded,size=#prefix+count+24,free=function() free(encoded) end}
        end
        local emitted=false
        local current,previous=alloc(rowbytes+1),alloc(rowbytes+1)
        local passlist=interlace==0 and {{0,0,1,1}} or passes
        local pi,py,pw,ph,len,filled=0,0,0,0,0,0
        local function next_pass()
            repeat
                pi=pi+1
                if not passlist[pi] then len=1; return end
                local p=passlist[pi]
                pw=math.max(0,math.ceil((w-p[1])/p[3]))
                ph=math.max(0,math.ceil((h-p[2])/p[4]))
            until pw>0 and ph>0
            py=0;len=math.ceil(pw*bits/8)+1
            ffi.fill(previous,rowbytes+1)
        end
        next_pass()
        local function row_ready()
            if not passlist[pi] then error("corrupt_image",0) end
            local f=current[0]
            if f>4 then error("corrupt_image",0) end
            local bpp=math.max(1,math.ceil(bits/8))
            for i=1,len-1 do
                local a=i>bpp and current[i-bpp] or 0
                local b=previous[i]
                local c=i>bpp and previous[i-bpp] or 0
                local delta=0
                if f==1 then delta=a elseif f==2 then delta=b
                elseif f==3 then delta=math.floor((a+b)/2)
                elseif f==4 then delta=paeth(a,b,c) end
                current[i]=(current[i]+delta)%256
            end
            local p=passlist[pi]
            local iy=p[2]+py*p[4]
            if iy>=y and iy<y+height then
                local dest=raw+(iy-y)*(rowbytes+1)+1
                if p[3]==1 then ffi.copy(dest,current+1,rowbytes)
                elseif bits>=8 then
                    local bytes=bits/8
                    for x=0,pw-1 do ffi.copy(dest+(p[1]+x*p[3])*bytes,current+1+x*bytes,bytes) end
                else
                    local mask=2^bits-1
                    for x=0,pw-1 do
                        local sourcebit=x*bits
                        local value=bit.band(bit.rshift(current[1+math.floor(sourcebit/8)],8-bits-sourcebit%8),mask)
                        local destbit=(p[1]+x*p[3])*bits
                        local index=math.floor(destbit/8)
                        dest[index]=bit.bor(dest[index],bit.lshift(value,8-bits-destbit%8))
                    end
                end
            end
            current,previous=previous,current
            filled=0;py=py+1
            if py==ph then next_pass() end
            if consume and interlace==0 and height>0 and iy==y+height-1 then
                local encoded=encode_region()
                local next_y,next_height
                repeat
                    next_y,next_height=consume(encoded,y,height)
                    -- At large zoom several display strips refer to the same
                    -- source rows. Reuse them instead of treating that as bad PNG.
                until next_y==nil or next_y<y or next_y+next_height>y+height
                encoded.free();emitted=true
                if next_y==nil then y=h;height=0
                else
                    next_y=math.max(0,math.floor(next_y))
                    next_height=math.min(math.ceil(next_height),h-next_y)
                    if next_y<y or next_y+next_height<=y+height or next_height<1 then error("invalid region",0) end
                    local next_bytes=(rowbytes+1)*next_height
                    local next_need=next_bytes*3+w*next_height*(color and 3 or 1)+rowbytes*3+2*1048576
                    if next_need>budget then error("memory_budget",0) end
                    local overlap=math.max(0,y+height-next_y)
                    local next_raw=raw
                    if next_bytes>capacity then next_raw=alloc(next_bytes) end
                    if overlap>0 then ffi.C.memmove(next_raw,raw+(next_y-y)*(rowbytes+1),overlap*(rowbytes+1)) end
                    ffi.fill(next_raw+overlap*(rowbytes+1),next_bytes-overlap*(rowbytes+1))
                    if next_raw~=raw then free(raw);raw=next_raw;capacity=next_bytes end
                    y,height,rawbytes=next_y,next_height,next_bytes
                end
            end
        end
        stream=ffi.new("picayomi_z_stream[1]")
        if lib.inflateInit_(stream,lib.zlibVersion(),ffi.sizeof(stream[0]))~=0 then return nil,"memory_budget" end
        initialized=true
        local ended=false
        local function feed(data)
            if ended and #data>0 then error("corrupt_image",0) end
            stream[0].next_in=ffi.cast("const uint8_t*",data)
            stream[0].avail_in=#data
            repeat
                stream[0].next_out=current+filled
                stream[0].avail_out=len-filled
                local before=tonumber(stream[0].avail_in)
                local rc=lib.inflate(stream,0)
                local produced=len-filled-tonumber(stream[0].avail_out)
                filled=filled+produced
                if filled==len then row_ready() end
                if rc==1 then
                    ended=true
                    if stream[0].avail_in~=0 or passlist[pi] or filled~=0 then error("corrupt_image",0) end
                    break
                elseif rc==-4 then error("memory_budget",0)
                elseif rc~=0 and rc~=-5 then error("corrupt_image",0) end
                if before==tonumber(stream[0].avail_in) and produced==0 then
                    if stream[0].avail_in>0 then error("corrupt_image",0) end
                    break
                end
            until stream[0].avail_in==0 and stream[0].avail_out>0
        end
        local keep={PLTE=true,tRNS=true,gAMA=true,cHRM=true,sRGB=true,sBIT=true}
        local seen_idat,closed_idat=false,false
        while true do
            local n=uint(read(4));local name=read(4)
            if n>size-consumed-4 or n>2147483647 then return nil,"corrupt_image" end
            if name=="IDAT" then
                if closed_idat then return nil,"corrupt_image" end
                seen_idat=true
            elseif seen_idat then closed_idat=true end
            if name=="IHDR" or (name:byte(1)<97 and name~="IDAT" and name~="IEND" and name~="PLTE") then return nil,"corrupt_image" end
            if keep[name] and seen_idat then return nil,"corrupt_image" end
            if keep[name] then
                metabytes=metabytes+n+12
                if metabytes>65536 then return nil,"memory_budget" end
            end
            local chunks={}
            local crc=lib.crc32(0,name,4)
            local left=n
            while left>0 do
                local data=read(math.min(left,65536))
                crc=lib.crc32(crc,data,#data)
                if name=="IDAT" then feed(data)
                elseif keep[name] then chunks[#chunks+1]=data end
                left=left-#data
            end
            local checksum=read(4)
            if uint(checksum)~=tonumber(crc) then return nil,"corrupt_image" end
            if keep[name] then metadata[#metadata+1]=be(n)..name..table.concat(chunks)..checksum end
            if name=="IEND" then
                if n~=0 or not seen_idat or not ended or consumed~=size then return nil,"corrupt_image" end
                break
            end
        end
        lib.inflateEnd(stream);initialized=false
        if emitted then return true end
        local encoded=encode_region()
        if consume then
            -- Adam7 needs all passes before any region is complete. The caller
            -- handles remaining strips with separately bounded passes.
            consume(encoded,y,height)
            encoded.free()
            return true,y,height
        end
        allocations[encoded.data]=nil
        encoded.free=function() if encoded.data then ffi.C.free(encoded.data);encoded.data=nil end end
        return encoded,y,height
    end)
    if initialized then zlib.inflateEnd(stream) end
    if file then file:close() end
    for p in pairs(allocations) do ffi.C.free(p) end
    if not ok then
        return nil,tostring(result):find("memory_budget",1,true) and "memory_budget" or "corrupt_image"
    end
    return result,origin,rows
end
return R
