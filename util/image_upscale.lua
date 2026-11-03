-- Pixel-aligned Catmull-Rom enlargement. Clamp each pass to its source
-- neighborhood so sharpening the interpolation does not introduce new halos.
local ffi=require('ffi')
local BB=require('ffi/blitbuffer')
local M={}
local function axis(size,count,start,step)
    local indices=ffi.new('int[?]',count*4)
    local weights=ffi.new('float[?]',count*4)
    for x=0,count-1 do
        local position=start+x*step
        local base=math.floor(position);local t=position-base;local t2,t3=t*t,t*t*t
        local k=x*4
        indices[k]=math.max(0,math.min(size-1,base-1));indices[k+1]=math.max(0,math.min(size-1,base))
        indices[k+2]=math.max(0,math.min(size-1,base+1));indices[k+3]=math.max(0,math.min(size-1,base+2))
        weights[k]=-.5*t+t2-.5*t3;weights[k+1]=1-2.5*t2+1.5*t3
        weights[k+2]=.5*t+2*t2-1.5*t3;weights[k+3]=-.5*t2+.5*t3
    end
    return indices,weights
end
function M.workspace(bb,w,h)
    local n=bb:getType()==BB.TYPE_BB8 and 1 or 3
    return w*4*n*4+w*h*n+(w+h)*32+65536
end
function M.scale(bb,w,h,budget,mapping)
    local kind=bb:getType();local n=({[BB.TYPE_BB8]=1,[BB.TYPE_BBRGB24]=3})[kind]
    if not n or bb:getRotation()~=0 then return nil,'unsupported_bitmap' end
    if not require('jit').status()then return require('util.image_filter').upscale(bb,w,h,false,budget)end
    local required=M.workspace(bb,w,h)
    if required>budget then return nil,'memory_budget',required end
    mapping=mapping or {}
    local output,scratch
    local ok,err=pcall(function()
        local sw,sh=tonumber(bb.w),tonumber(bb.h)
        local ix,wx=axis(sw,w,mapping.x or 0,mapping.step_x or sw/w)
        local iy,wy=axis(sh,h,mapping.y or 0,mapping.step_y or sh/h)
        -- Four adjacent source rows suffice for any output row. Reuse their
        -- horizontal results instead of retaining an entire float image.
        scratch=BB.new(w*n*4,4,BB.TYPE_BB8)
        local temp=ffi.cast('float*',scratch.data)
        output=BB.new(w,h,kind);output:setInverse(bb:getInverse())
        local input=ffi.cast('uint8_t*',bb.data);local dest=ffi.cast('uint8_t*',output.data)
        local rows={};local width=w*n
        for y=0,h-1 do
            local k=y*4
            for tap=0,3 do
                local sy=tonumber(iy[k+tap]);local slot=sy%4
                if rows[slot]~=sy then
                    local row=input+sy*bb.stride;local base=slot*width
                    for c=0,n-1 do
                        for x=0,w-1 do
                            local j=x*4
                            local a,b,d,e=tonumber(row[ix[j]*n+c]),tonumber(row[ix[j+1]*n+c]),tonumber(row[ix[j+2]*n+c]),tonumber(row[ix[j+3]*n+c])
                            local v=a*wx[j]+b*wx[j+1]+d*wx[j+2]+e*wx[j+3]
                            temp[base+x*n+c]=math.max(math.min(a,b,d,e),math.min(math.max(a,b,d,e),v))
                        end
                    end
                    rows[slot]=sy
                end
            end
            local row=dest+y*output.stride
            local a,b,d,e=(iy[k]%4)*width,(iy[k+1]%4)*width,(iy[k+2]%4)*width,(iy[k+3]%4)*width
            if wy[k]==0 and wy[k+1]==1 and wy[k+2]==0 and wy[k+3]==0 then
                -- An exact source-row sample needs no interpolation or clamp.
                for i=0,width-1 do row[i]=math.floor(tonumber(temp[b+i])+.5) end
            else
                for i=0,width-1 do
                    local p,q,r,s=tonumber(temp[a+i]),tonumber(temp[b+i]),tonumber(temp[d+i]),tonumber(temp[e+i])
                    local v=p*wy[k]+q*wy[k+1]+r*wy[k+2]+s*wy[k+3]
                    row[i]=math.floor(math.max(math.min(p,q,r,s),math.min(math.max(p,q,r,s),v))+.5)
                end
            end
        end
    end)
    if scratch then scratch:free()end
    if not ok then if output then output:free()end;return nil,tostring(err),required end
    return output
end
return M
