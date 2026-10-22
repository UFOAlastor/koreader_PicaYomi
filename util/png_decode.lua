-- libpng 1.6 simplified API: 文件流读取, 直接输出灰度/RGB。
-- setjmp/longjmp 完全留在 libpng 内部, 不穿越 LuaJIT FFI 栈。
-- decode 输出完整一帧；decode_region 仅转换有界条带。
local ffi = require("ffi")
local BB = require("ffi/blitbuffer")
local lfs = require("libs/libkoreader-lfs")
local ImageGuard = require("util.image_guard")

local PngDecode = {}
local library, load_error

local function load_library()
    if library ~= nil then return library or nil, load_error end
    library = false
    local ok, lib = pcall(function()
        if not pcall(ffi.typeof,"picayomi_png_image") then ffi.cdef[[
            typedef struct {
                void *opaque;
                uint32_t version, width, height, format, flags, colormap_entries;
                uint32_t warning_or_error;
                char message[64];
            } picayomi_png_image;
            typedef struct { uint8_t red, green, blue; } picayomi_png_color;
            int png_image_begin_read_from_file(picayomi_png_image *, const char *);
            int png_image_begin_read_from_memory(picayomi_png_image *, const void *, size_t);
            int png_image_finish_read(picayomi_png_image *,
                const picayomi_png_color *, void *, int32_t, void *);
            void png_image_free(picayomi_png_image *);
        ]] end
        local png = ffi.loadlib("png16", "16")
        assert(png.png_image_begin_read_from_file and png.png_image_finish_read and png.png_image_free)
        return png
    end)
    if ok then library = lib else load_error = tostring(lib) end
    return library or nil, load_error
end

function PngDecode.available()
    return load_library() ~= nil
end

function PngDecode.decode(path, color, budget)
    local lib, err = load_library()
    if not lib then return nil, err end
    local image = ffi.new("picayomi_png_image[1]")
    image[0].version = 1 -- PNG_IMAGE_VERSION, stable simplified API layout
    local bb
    local ok, result, why = pcall(function()
        local size = lfs.attributes(path, "size")
        if not size or size > ImageGuard.FILE_LIMIT then return nil, "文件不存在或超过读取预算" end
        if lib.png_image_begin_read_from_file(image, path) == 0 then
            return nil, ffi.string(image[0].message)
        end
        local w, h = tonumber(image[0].width), tonumber(image[0].height)
        local plan = ImageGuard.plan(w, h, "png", size,
            { native_png = true, color = color, budget = budget })
        if plan.action ~= "png" then return nil, "memory_budget" end
        -- PNG_FORMAT_GRAY=0, PNG_FORMAT_RGB=2; 去透明度时合成到白底。
        image[0].format = color and 2 or 0
        bb = BB.new(w, h, color and BB.TYPE_BBRGB24 or BB.TYPE_BB8)
        local white = ffi.new("picayomi_png_color[1]", { { 255, 255, 255 } })
        if lib.png_image_finish_read(image, white, bb.data, bb.stride, nil) == 0 then
            return nil, ffi.string(image[0].message)
        end
        return bb
    end)
    -- finish_read 成功/失败均可 free, 也释放仅 begin 后被预算拦住的文件句柄。
    lib.png_image_free(image)
    if not ok or not result then
        if bb then bb:free() end
        local message=tostring(ok and why or result)
        return nil,(message:lower():find("memory",1,true) or message:lower():find("allocat",1,true))
            and "memory_budget" or message
    end
    return result
end

-- Same color conversion as full PNG decoding, fed a bounded, lossless strip.
function PngDecode.decode_region(path, y, height, color, budget)
    local lib, err = load_library()
    if not lib then return nil, err end
    local bytes, start, rows = require("util.png_region").extract(path,y,height,color,budget)
    if not bytes then return nil,start end
    local result,err=PngDecode.decode_encoded(bytes,color)
    bytes.free()
    if not result then return nil,err end
    return result,start,rows
end
function PngDecode.decode_encoded(bytes,color)
    local lib,err=load_library()
    if not lib then return nil,err end
    local image=ffi.new("picayomi_png_image[1]")
    image[0].version=1
    local bb
    local ok,result,why=pcall(function()
        if lib.png_image_begin_read_from_memory(image,bytes.data,bytes.size)==0 then
            local msg=ffi.string(image[0].message):lower()
            return nil,(msg:find("memory",1,true) or msg:find("allocat",1,true))
                and "memory_budget" or "corrupt_image"
        end
        image[0].format=color and 2 or 0
        bb=BB.new(tonumber(image[0].width),tonumber(image[0].height),color and BB.TYPE_BBRGB24 or BB.TYPE_BB8)
        local white=ffi.new("picayomi_png_color[1]",{{255,255,255}})
        if lib.png_image_finish_read(image,white,bb.data,bb.stride,nil)==0 then
            local msg=ffi.string(image[0].message):lower()
            return nil,(msg:find("memory",1,true) or msg:find("allocat",1,true))
                and "memory_budget" or "corrupt_image"
        end
        return bb
    end)
    lib.png_image_free(image)
    if not ok or not result then
        if bb then bb:free() end
        return nil,ok and why or "memory_budget"
    end
    return result
end
return PngDecode
