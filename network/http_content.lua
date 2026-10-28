-- Bounded HTTP gzip decoding. Use the zlib already shipped with KOReader.
local M={}
local ffi=require("ffi")
require("ffi/zlib")
ffi.cdef[[
typedef struct {
    const unsigned char *next_in; unsigned int avail_in; unsigned long total_in;
    unsigned char *next_out; unsigned int avail_out; unsigned long total_out;
    char *msg; void *state;
    void *(*zalloc)(void *, unsigned int, unsigned int);
    void (*zfree)(void *, void *); void *opaque;
    int data_type; unsigned long adler; unsigned long reserved;
} picayomi_z_stream;
const char *zlibVersion(void);
int inflateInit2_(picayomi_z_stream *, int, const char *, int);
int inflate(picayomi_z_stream *, int);
int inflateEnd(picayomi_z_stream *);
]]
local zlib=ffi.loadlib("z",1)
function M.gunzip(raw,limit)
    limit=limit or 2*1024*1024
    if type(raw)~="string" or #raw>limit then return nil,"压缩响应超出大小限制" end
    local stream=ffi.new("picayomi_z_stream[1]")
    stream[0].next_in=raw;stream[0].avail_in=#raw
    if zlib.inflateInit2_(stream,31,zlib.zlibVersion(),ffi.sizeof(stream[0]))~=0 then return nil,"无法初始化响应解压" end
    local ok,value=pcall(function()
        local buffer=ffi.new("unsigned char[65536]")
        local parts,total={},0
        while true do
            stream[0].next_out=buffer;stream[0].avail_out=65536
            local status=zlib.inflate(stream,0)
            local size=65536-tonumber(stream[0].avail_out)
            total=total+size;assert(total<=limit,"size")
            if size>0 then parts[#parts+1]=ffi.string(buffer,size) end
            if status==1 then assert(stream[0].avail_in==0,"trailing data");return table.concat(parts) end
            assert(status==0 and size>0,"incomplete gzip")
        end
    end)
    zlib.inflateEnd(stream)
    if not ok then return nil,"压缩响应不完整、损坏或超出大小限制" end
    return value
end
function M.decode(response)
    local headers=response.headers or {}
    local encoding=headers["content-encoding"] or headers["Content-Encoding"]
    if not encoding or encoding:lower()=="identity" then return response end
    if encoding:lower()~="gzip" then return nil,"不支持的响应压缩格式" end
    local body,err=M.gunzip(response.body)
    if not body then return nil,err end
    response.body=body
    headers["content-encoding"],headers["Content-Encoding"]=nil,nil
    headers["content-length"],headers["Content-Length"]=nil,nil
    return response
end
return M
