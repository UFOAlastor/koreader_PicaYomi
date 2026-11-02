-- Pointwise display correction. Decoder bitmaps and downloaded files stay raw.
local ffi = require("ffi")
local BB = require("ffi/blitbuffer")
local M = { CONFIG = "comic_display_enhancement", TONE_CONFIG = "comic_display_tone", ADAPTIVE_CONFIG = "comic_enhancement_adaptive" }
local gamma = { light=1.12, standard=1.25 }
local library
local context_svg = '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>'

function M.normalize(mode) return (mode=="contrast" or gamma[mode] or mode=="denoise_sharpen" or mode=="sharpen") and mode or "off" end
function M.tone(mode,tone)
    if tone==nil or tone=="auto" then return gamma[mode] and mode or "off" end
    return (gamma[tone] or tone=="contrast") and tone or "off"
end
function M.key(mode,tone,adaptive)
    return "display-filter-v7:"..M.normalize(mode)..":"..M.tone(mode,tone)..(adaptive==false and ":fixed" or ":adaptive")
end
-- Small images keep source-resolution filtering. At a material downscale,
-- filter the display-resolution neighborhood instead of every source pixel.
function M.at_display(mode,zoom,adaptive)
    return adaptive~=false and M.spatial(mode) and type(zoom)=="number" and zoom>0 and zoom<=0.8
end

-- A bounded monotone S curve. Endpoints and mid-gray stay fixed; no extra
-- bitmap or neighborhood is needed, so tiles and full pages agree exactly.
local contrast_lut=ffi.new("uint8_t[256]")
for i=0,255 do
    local x=i/255;local d=x-0.5
    contrast_lut[i]=math.floor(255*(x+0.35*d*(1-4*d*d))+0.5)
end
local function contrast(bb,count,alpha)
    local data=ffi.cast("uint8_t*",bb.data)
    local inverse=bb:getInverse()==1
    for y=0,tonumber(bb.h)-1 do
        local row=data+y*tonumber(bb.stride)
        for x=0,tonumber(bb.w)-1 do
            for c=0,count-alpha-1 do
                local i=x*count+c;local v=tonumber(row[i])
                row[i]=inverse and 255-contrast_lut[255-v] or contrast_lut[v]
            end
        end
    end
end

function M.spatial(mode)return mode=="denoise_sharpen" or mode=="sharpen" end

local function backend()
    if library then return library end
    require("ffi/mupdf") -- Use the installed host's declarations/version handling.
    local lib = ffi.loadlib("wrap-mupdf")
    assert(lib.fz_gamma_pixmap and lib.mupdf_new_pixmap_with_data)
    library = lib
    return lib
end

local function invert_samples(bb,count,alpha)
    if BB.getUseCBB() then
        local inverse=bb:getInverse()
        bb:setInverse(0)
        local ok,err=pcall(bb.invertRect,bb,0,0,bb:getWidth(),bb:getHeight())
        bb:setInverse(inverse)
        if not ok then error(err) end
        return
    end
    -- Some host Lua fallbacks use a size_t as a numeric-for limit. Work on
    -- visible samples with numeric bounds, preserving alpha and stride padding.
    local data=ffi.cast("uint8_t*",bb.data)
    local stride=tonumber(bb.stride)
    for y=0,tonumber(bb.h)-1 do
        local row=data+y*stride
        for x=0,tonumber(bb.w)-1 do
            local offset=x*count
            for c=0,count-alpha-1 do row[offset+c]=255-row[offset+c] end
        end
    end
end

-- A tiny in-memory SVG obtains the host-managed context without opening the
-- source image or duplicating its compressed input. Every call closes it.
function M.available(mode)
    if mode=="contrast" or mode=="off" then return true end
    if M.spatial(mode)then return require("util.image_filter").available()end
    local doc
    local ok = pcall(function()
        backend()
        doc = require("ffi/mupdf").openDocumentFromText(context_svg,"svg")
    end)
    if doc then ok=pcall(doc.close,doc) and ok end
    return ok
end

function M.apply(bb,mode)
    mode=M.normalize(mode)
    if mode=="off" or M.spatial(mode) then return true end
    local kind=bb:getType()
    local gray=kind==BB.TYPE_BB8 or kind==BB.TYPE_BB8A
    if not gray and kind~=BB.TYPE_BBRGB24 and kind~=BB.TYPE_BBRGB32 then
        return false,"unsupported_bitmap"
    end
    local alpha=(kind==BB.TYPE_BB8A or kind==BB.TYPE_BBRGB32) and 1 or 0
    local count=gray and 1+alpha or 3+alpha
    if mode=="contrast" then contrast(bb,count,alpha);return true end
    local doc,pix,lib,inverted
    local ok = pcall(function()
        lib=backend()
        doc=require("ffi/mupdf").openDocumentFromText(context_svg,"svg")
        local cs=gray and lib.fz_device_gray(doc.ctx) or lib.fz_device_rgb(doc.ctx)
        pix=lib.mupdf_new_pixmap_with_data(doc.ctx,cs,bb.w,bb.h,nil,alpha,bb.stride,
            ffi.cast("unsigned char*",bb.data))
        assert(pix~=nil,"cannot wrap display bitmap")
        -- The physical buffer may be inverse-tagged in the direct screen path.
        if bb:getInverse()==1 then
            invert_samples(bb,count,alpha);inverted=true
        end
        lib.fz_gamma_pixmap(doc.ctx,pix,gamma[mode])
    end)
    if inverted then invert_samples(bb,count,alpha) end
    if pix then lib.fz_drop_pixmap(doc.ctx,pix) end
    if doc then doc:close() end
    if ok then return true end
    return false,"native_unavailable"
end
return M
