-- Shared synchronous/background pixel renderer. UI effects stay with the caller.
local Blitbuffer=require("ffi/blitbuffer")
local ImageEnhance=require("util.image_enhance")
local ScaledDecode=require("util.scaled_decode")
local PngDecode=require("util.png_decode")
local logger=require("util.logger")
local M={}
-- Larger grants already need few codec starts. Keep their established strip
-- ordering: front-loading larger crops can increase WebP prefix decoding.
local WEBP_PLAN_BUDGET=8*1024*1024
function M.draw(o,dc,target,ox,oy)
    local sz,path,format,color=o.size,o.path,o.format,o.color
    local mode,adaptive=o.mode,o.adaptive
    local decode_budget,filter_source,region_decode=o.budget,o.filter,o.decode
    local timings=o.timings
    local clock=timings and require('socket').gettime
    local function timed(stage,fn)
        if not timings then return fn end
        return function(...)
            local started=clock();local a,b,c,d=fn(...)
            timings[stage]=(timings[stage] or 0)+(clock()-started)*1000
            return a,b,c,d
        end
    end
    filter_source=timed('filter',filter_source)
    region_decode=timed('decode',region_decode)
    local resize=timed('resize',o.resize)
    local read_input=timed('decode',ScaledDecode.region_input)
    local decode_png=timed('decode',PngDecode.decode_encoded)
    local bypassed,failed=o.bypassed,o.failed
    local region_input
    local function record(reason) if o.record then o.record(reason) end end
    local zoom=dc:getZoom()
    local bypass_before=bypassed()
    local display_filter=not bypass_before and ImageEnhance.at_display(mode,zoom,adaptive)
    ox,oy=ox or 0,oy or 0
    local tw,th=target:getWidth(),target:getHeight()
    local row=0
    local halo=math.max(2,math.ceil(1/zoom)+1)+(display_filter and math.ceil(3/zoom) or ImageEnhance.spatial(mode)and 3 or 0)
    local page_w,page_h=math.ceil(sz.w*zoom),math.ceil(sz.h*zoom)
    local function range(lines)
        local top,bottom=oy+row,oy+row+lines
        local first=math.max(0,math.floor(top/zoom)-halo)
        local last=math.min(sz.h,math.ceil(math.min(bottom,page_h)/zoom)+halo)
        return first,last-first
    end
    local function draw_strip(bb,start,raw_height,lines)
        local scaled,view,canvas
        local required_extra
        local ok,err=pcall(function()
            local filtered,reason,needed=filter_source(bb,display_filter,false,zoom>1)
            if not filtered then required_extra=needed;error(reason)end
            local consumed=0
            repeat
                -- Resampling geometry must not change when the decode
                -- batch shrinks. Keep canonical 64-display-row windows.
                local vertical=bb:getHeight()/raw_height
                local band=math.floor((oy+row+consumed)/64)*64
                local count=math.min(lines-consumed,band+64-oy-row-consumed)
                local first=math.max(0,math.floor(band/zoom)-halo)
                local last=math.min(sz.h,math.ceil(math.min(band+64,page_h)/zoom)+halo)
                first=math.floor(first*vertical)/vertical
                last=math.ceil(last*vertical)/vertical
                local top=math.floor(first*zoom)
                local height=math.ceil(last*zoom)-top
                local ratio=bb:getWidth()/sz.w
                local xhalo=math.max(2,math.ceil(ratio/zoom)+1)+(display_filter and math.ceil(3*ratio/zoom) or 0)
                -- Anchor resampling in page coordinates, not in the
                -- requested viewport. Keep horizontal work bounded when
                -- zoomed into an unusually wide image.
                local cell=page_w<=2048 and page_w or 512
                local column=0
                while column<tw do
                    local anchor=math.floor((ox+column)/cell)*cell
                    local columns=math.min(tw-column,anchor+cell-ox-column)
                    local right=math.min(page_w,anchor+cell)
                    local x0=math.max(0,math.floor(anchor/zoom*ratio)-xhalo)
                    local x1=math.min(bb:getWidth(),math.ceil(right/zoom*ratio)+xhalo)
                    local left=math.floor(x0/ratio*zoom)
                    local width=math.ceil(x1/ratio*zoom)-left
                    local extra=(x1-x0)*math.ceil((last-first)*vertical)*(color and 4 or 1)
                    -- bb is already resident in the freshly sampled free
                    -- memory. Charge only new crop/resampling allocations.
                    required_extra=width*height*(color and 8 or 2)+extra
                    if required_extra>decode_budget() then error("memory_budget") end
                    local cy=math.floor((first-start)*vertical+0.5)
                    local ch=math.floor((last-first)*vertical+0.5)
                    if cy>=0 and cy+ch<=bb:getHeight() then
                        view=bb:viewport(x0,cy,x1-x0,ch)
                    else
                        -- Fixed geometry even when the decode batch is
                        -- smaller than the canonical resampling window.
                        canvas=Blitbuffer.new(x1-x0,ch,bb:getType())
                        canvas:fill(Blitbuffer.COLOR_WHITE)
                        local y0,y1=math.max(0,cy),math.min(bb:getHeight(),cy+ch)
                        canvas:blitFrom(bb,0,y0-cy,x0,y0,x1-x0,y1-y0)
                        view=canvas
                    end
                    local resize_reason,resize_need
                    scaled,resize_reason,resize_need=resize(view,width,height,
                        {x=left/zoom-x0,y=top/zoom-first,step_x=1/zoom,step_y=1/zoom},decode_budget)
                    if not scaled then required_extra=resize_need;error(resize_reason)end
                    if display_filter then
                        -- A no-op resize aliases the source viewport. Keep
                        -- overlapping halos pristine for the next window.
                        if scaled==view then scaled=view:copy() end
                        local enhanced,reason,needed=filter_source(scaled,false,true)
                        if not enhanced then required_extra=needed;error(reason)end
                    end
                    target:blitFrom(scaled,column,row+consumed,ox+column-left,oy+row+consumed-top,columns,count)
                    if scaled~=view then scaled:free() end
                    scaled=nil
                    view:free();view=nil;canvas=nil
                    column=column+columns
                end
                consumed=consumed+count
            until consumed>=lines
        end)
        if scaled and scaled~=view then scaled:free() end
        if view then view:free();canvas=nil end
        if canvas then canvas:free() end
        bb:free()
        if not ok then logger.warn("Picayomi region render:",err);return false,required_extra end
        row=row+lines
        return true
    end
    target:fill(Blitbuffer.COLOR_WHITE)
    if format~="png" then
        local err,required
        region_input,err,required=read_input(path,decode_budget())
        if not region_input then failed(err,required,true);return end
    end
    local native_batch=th
    while row<th do
        -- Each native strip restarts the codec. Start with the visible
        -- viewport when memory permits; failed budget checks halve it.
        -- PNG keeps its streaming/canonical 64-row extraction path.
        -- Keep conservative planning under tight budgets; otherwise a
        -- display-sized filter should process each 64-row window once.
        local lean_png=not display_filter or decode_budget()<4*1024*1024
        local plan_webp=format=="webp" and decode_budget()<=WEBP_PLAN_BUDGET
        local batch=format=="png" and (ImageEnhance.spatial(mode)and lean_png and zoom<1 and 32 or 64)or (plan_webp and native_batch or th)
        local lines=math.min(batch,th-row)
        local success,reason,required
        repeat
            local y0,height=range(lines)
            if height<=0 then return end
            local capacity
            if format=="png" and not o.post_plan then
                -- Noninterlaced PNG consumes the source once for all
                -- visible strips. Adam7 uses independently bounded passes.
                success,reason=require("util.png_region").extract(path,y0,height,color,decode_budget(),
                    function(encoded,start,raw_height)
                        local bb,err=decode_png(encoded,color)
                        if not bb then error(err,0) end
                        if not draw_strip(bb,start,raw_height,lines) then error("memory_budget",0) end
                        if row>=th then return nil end
                        lines=math.min(lines,th-row)
                        return range(lines)
                    end)
            else
                local bb,start,raw_height,fit=region_decode(format,y0,height,decode_budget(),zoom,region_input)
                if bb then success,required=draw_strip(bb,start,raw_height,lines);reason="memory_budget"
                else reason=start;required=raw_height;capacity=fit end
            end
            if not bypass_before and bypassed() then
                -- Earlier strips may already be enhanced. Redraw once
                -- from the compressed source so the entire view agrees.
                region_input=nil
                return M.draw(o,dc,target,ox,oy)
            end
            if success or reason~="memory_budget" or lines==1 then break end
            if plan_webp and not o.post_plan and capacity then
                -- Find the largest display strip whose complete source halo
                -- fits, including WebP's even crop origin. This search does
                -- not start a codec or allocate pixels. A new decode always
                -- rechecks the budget, so pressure changes still shrink it.
                local lo,hi=1,lines-1
                while lo<hi do
                    local mid=math.ceil((lo+hi)/2)
                    local first,count=range(mid)
                    if count+first%2<=capacity then lo=mid else hi=mid-1 end
                end
                lines=lo
            else
                lines=math.max(1,math.floor(lines/2))
            end
        until false
        if not success then failed(reason,required);return end
        -- Reuse the proven batch within this draw only. Never retain a grant
        -- across pages or use it to bypass fresh allocation checks.
        if plan_webp then native_batch=lines end
    end
    region_input=nil
    record("ok")
    return true
end
return M
