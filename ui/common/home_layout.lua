-- Layout measured controls, then remove previews in a stable priority order.
-- Rectangles also define the hit areas; bubbles may use any remaining space.
local M={}
local function intersects(a,b,gap)
    return a.x<b.x+b.w+gap and a.x+a.w+gap>b.x
        and a.y<b.y+b.h+gap and a.y+a.h+gap>b.y
end
local function sorted(values)
    local result,seen={},{}
    for _,value in ipairs(values)do
        value=math.floor(value+.5)
        if not seen[value]then result[#result+1]=value;seen[value]=true end
    end
    table.sort(result);return result
end
function M.arrange(opts)
    local scale=opts.scale
    local function px(n)return math.floor(n*scale+.5)end
    local hidden={}
    local function attempt(columns,compact)
        local padding=px(compact and 16 or 24)
        local gap,column_gap=px(compact and 12 or 22),px(compact and 16 or 28)
        local width=opts.width-2*padding
        local top=padding+opts.top_height+px(compact and 12 or 26)
        local bottom=opts.height-opts.footer_height-px(16)
        local cell=math.floor((width-(columns-1)*column_gap)/columns)
        local rects,sections={},{}
        local row_y=top
        for first=1,#opts.sections,columns do
            local row_height=0
            for i=first,math.min(#opts.sections,first+columns-1)do
                local section=opts.sections[i]
                local header_h=opts.header_height(section,cell)
                local preview=not hidden[section.id] and section.has_preview
                local height=header_h+(preview and px(8)+opts.preview_height or 0)
                local r={x=padding+(i-first)*(cell+column_gap),y=row_y,w=cell,h=height,
                    header_height=header_h,preview=preview,id=section.id,kind="section"}
                sections[#sections+1]=r;rects[#rects+1]=r
                row_height=math.max(row_height,height)
            end
            row_y=row_y+row_height+gap
        end
        local bubbles={}
        local bubble_gap=px(12)
        for i,size in ipairs(opts.bubbles)do
            local ys,xs={top},{padding}
            for _,r in ipairs(rects)do
                ys[#ys+1]=r.y;ys[#ys+1]=r.y+r.h+(r.kind=="section" and gap or bubble_gap)
                xs[#xs+1]=r.x;xs[#xs+1]=r.x+r.w+(r.kind=="section" and column_gap or bubble_gap)
            end
            local chosen
            for _,y in ipairs(sorted(ys))do
                for _,x in ipairs(sorted(xs))do
                    local candidate={x=x,y=y,w=size.w,h=size.h,kind="bubble",index=i}
                    local free=x+size.w<=opts.width-padding
                    if free then for _,r in ipairs(rects)do
                        if intersects(candidate,r,bubble_gap)then free=false;break end
                    end end
                    if free then chosen=candidate;break end
                end
                if chosen then break end
            end
            if not chosen then
                local y=top
                for _,r in ipairs(rects)do y=math.max(y,r.y+r.h+gap)end
                chosen={x=padding,y=y,w=size.w,h=size.h,kind="bubble",index=i}
            end
            bubbles[#bubbles+1]=chosen;rects[#rects+1]=chosen
        end
        local extent=top
        for _,r in ipairs(rects)do extent=math.max(extent,r.y+r.h)end
        return {sections=sections,bubbles=bubbles,rects=rects,hidden=hidden,columns=columns,
            padding=padding,top=top,bottom=bottom,content_bottom=extent,fits=extent<=bottom,
            compact=compact}
    end
    local columns=opts.width>opts.height and (opts.width-px(76))/2>=px(260) and 2 or 1
    local result=attempt(columns,false)
    for _,id in ipairs({"downloads","history","favorites"})do
        if result.fits then break end
        hidden[id]=true;result=attempt(columns,false)
    end
    if not result.fits then
        result=attempt(columns,true)
        for count=2,3 do
            if (opts.width-px(32)-(count-1)*px(16))/count>=opts.min_header_width then
                local candidate=attempt(count,true)
                if candidate.content_bottom<result.content_bottom then result=candidate end
            end
        end
    end
    return result
end
return M
