-- Shared bounded source-band assembly for foreground and speculative rendering.
local Blitbuffer=require('ffi/blitbuffer')
local PngDecode=require('util.png_decode')
local ScaledDecode=require('util.scaled_decode')
local M={}
function M.decode(path,sz,color,post_plan,format,y,height,current_budget,zoom,region_input)
        local function read_piece(py,ph,remaining,pzoom)
            if format=="png" then return PngDecode.decode_region(path,py,ph,color,remaining) end
            -- WebP region scaling depends on crop height; resample below
            -- in page coordinates so pressure crops keep identical pixels.
            return ScaledDecode.decode_region(path,format,py,ph,color,remaining,format=="webp" and 1 or pzoom,region_input)
        end
        if not post_plan then return read_piece(y,height,current_budget,zoom) end
        -- Assemble only the requested output strip. Source rows may be far
        -- apart; no full decoded page is needed for host band reordering.
        local bytes=sz.w*height*(color and 4 or 1)
        if bytes>=current_budget then return nil,"memory_budget",bytes+1 end
        local output,piece
        local ok,result,why,needed=pcall(function()
            output=Blitbuffer.new(sz.w,height,color and Blitbuffer.TYPE_BBRGB32 or Blitbuffer.TYPE_BB8)
            for _,part in ipairs(require("source.image_service").regionPieces(post_plan,y,height)) do
                local origin,required
                piece,origin,required=read_piece(part.source_y,part.height,current_budget-bytes,1)
                if not piece then return nil,origin,required and required+bytes end
                output:blitFrom(piece,0,part.target_y,0,part.source_y-origin,sz.w,part.height)
                piece:free();piece=nil
            end
            return output
        end)
        if piece then piece:free() end
        if not ok or not result then
            if output then output:free() end
            return nil,ok and why or "memory_budget",needed
        end
        return result,y,height
    end
return M
