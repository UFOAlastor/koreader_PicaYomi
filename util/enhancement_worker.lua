-- Headless raster work. No Device/UI, source callbacks, downloads or input writes.
local M={MAX_TILE=8*1024*1024}
function M.render(s)
    local BB=require('ffi/blitbuffer')
    local Enhance=require('util.image_enhance')
    local Decode=require('util.scaled_decode')
    local Guard=require('util.memory_guard').instance()
    assert(s.width>0 and s.height>0 and s.width*s.height*(s.color and 4 or 1)<=M.MAX_TILE)
    assert(s.budget>0 and s.budget<=16*1024*1024)
    local function budget()return math.min(s.budget,Guard:decode_budget())end
    local bypass=s.bypass==true
    local function filter(bb,defer,fast,upscale)
        if bypass or defer or not Enhance.spatial(s.mode)then return true end
        local mode=s.mode
        if upscale and not s.legacy then
            if mode=='sharpen'then mode='bounded_sharpen'elseif mode=='denoise_sharpen'then mode='denoise_bounded_sharpen'end
        end
        local ok,why=require('util.image_filter').apply(bb,mode,budget(),fast)
        if not ok then
            if why=='memory_budget'then error('speculation_budget',0)end
            bypass=true
        end
        return true
    end
    local function resize(bb,w,h,mapping)
        if w>tonumber(bb.w) and h>tonumber(bb.h) and not s.legacy then
            local out,why,need=require('util.image_upscale').scale(bb,w,h,budget(),mapping)
            if out or why=='memory_budget'then return out,why,need end
        end
        w,h=math.floor(w),math.floor(h)
        if bb:getWidth()==w and bb:getHeight()==h then return bb end
        if s.legacy then return bb:scale(w,h)end
        return require('ffi/mupdf').scaleBlitBuffer(bb,w,h)
    end
    local target=BB.new(s.width,s.height,s.color and BB.TYPE_BBRGB32 or BB.TYPE_BB8)
    local ok,err=pcall(function()
        local dc=require('ffi/drawcontext').new();dc:setZoom(s.zoom);dc:setRotate(0)
        local done=require('util.image_region_render').draw({size=s.size,path=s.input,format=s.format,color=s.color,
            mode=s.mode,adaptive=s.adaptive,budget=budget,filter=filter,resize=resize,
            bypassed=function()return bypass end,failed=function(why)error(why,0)end,
            decode=function(format,y,height,grant,zoom,input)
                return Decode.decode_region(s.input,format,y,height,s.color,grant,format=='webp'and 1 or zoom,input)
            end},dc,target,0,0)
        assert(done,'incomplete raster')
        if not bypass then assert(Enhance.apply(target,Enhance.tone(s.mode,s.tone)))end
        local ffi=require('ffi');local bytes=tonumber(target.stride)*target.h
        assert(bytes<=M.MAX_TILE)
        local f=assert(io.open(s.output,'wb'))
        local wrote,why=pcall(function()
            for offset=0,bytes-1,65536 do assert(f:write(ffi.string(ffi.cast('uint8_t*',target.data)+offset,math.min(65536,bytes-offset))))end
        end)
        local closed=f:close();assert(wrote and closed,why)
        return {bytes=bytes,stride=tonumber(target.stride),bypass=bypass}
    end)
    target:free()
    if not ok then error(err,0)end
    return err
end
return M
