-- Convert untrusted chapter HTML into a closed local document, without JS.
local M={}
local function escape(s)
    return (s:gsub("&","&amp;"):gsub("<","&lt;"):gsub(">","&gt;"):gsub('"',"&quot;"))
end
function M.normalize(html)
    assert(type(html)=="string" and #html<=262144,"chapter HTML too large")
    local util=require("util")
    local parser=require("htmlparser")
    local raw='<div id="pychapter">'..html..'</div>'
    local root
    local blocked={script=true,style=true,iframe=true,object=true,embed=true,svg=true,math=true,
        form=true,input=true,button=true,textarea=true,link=true,meta=true}
    local formatting={b=true,strong=true,em=true,i=true,u=true,span=true}
    -- Invalid inline formatting can cross a paragraph boundary. Remove only
    -- the offending wrapper; keep every paragraph, illustration and text byte.
    for attempt=1,16 do
        root=parser.parse(raw,2000000)
        local visited=0
        local function crossing(node,depth)
            visited=visited+1;assert(visited<=50000 and depth<=64,"chapter DOM too large")
            if blocked[node.name:lower()]then return end
            for _,child in ipairs(node.nodes or {})do
                if node._closestart>node._openend and formatting[child.name:lower()]
                    and child._openstart<node._closestart and child._closestart>node._closestart then return child end
                local found=crossing(child,depth+1);if found then return found end
            end
        end
        local bad=crossing(assert(root:select("#pychapter")[1]),0)
        if not bad then break end
        assert(attempt<16,"too many malformed formatting wrappers")
        local text=root._text
        raw=text:sub(1,bad._closestart-1)..text:sub(bad._closeend+1)
        raw=raw:sub(1,bad._openstart-1)..raw:sub(bad._openend+1)
    end
    local wrapper=assert(root:select("#pychapter")[1])
    local allowed={p=true,div=true,span=true,br=true,hr=true,h1=true,h2=true,h3=true,
        h4=true,strong=true,b=true,em=true,i=true,u=true,blockquote=true,ul=true,ol=true,li=true,ruby=true,rt=true,rp=true}
    local assets,by_url={},{}
    local void=require("htmlparser.voidelements")
    local nodes=0
    local function text(s) return escape(util.htmlEntitiesToUtf8(s)) end
    local function render(node,depth,implicit_end)
        nodes=nodes+1;assert(nodes<=50000 and depth<=64,"chapter DOM too large")
        local tag=node.name:lower()
        if blocked[tag] then return "" end
        if tag=="img" then
            local url=node.attributes["data-src"] or node.attributes.src
            assert(type(url)=="string" and #url>0 and #url<=16384,"missing image")
            url=util.htmlEntitiesToUtf8(url)
            local path=by_url[url]
            if not path then
                assert(#assets<64,"too many illustrations")
                path=string.format("images/%04d.img",#assets+1)
                assets[#assets+1]={path=path,url=url};by_url[url]=path
            end
            return '<img src="'..path..'" alt="'..escape(node.attributes.alt or "")..'">'
        end
        if tag=="br" or tag=="hr" then return '<'..tag..'>' end
        local parts,cursor={},node._openend+1
        local content_end=implicit_end or node._closestart-1
        for i,child in ipairs(node.nodes) do
            -- htmlparser leaves an unclosed element at its opening range,
            -- while its children still contain the following paragraphs.
            -- Bound that element by its next sibling or the enclosing content.
            local unclosed=not void[child.name:lower()] and child._closestart==child._openstart and child._closeend==child._openend
            local boundary=node.nodes[i+1] and node.nodes[i+1]._openstart-1 or content_end
            local child_end=unclosed and boundary or child._closeend
            assert(child._openstart>=cursor and child_end<=content_end,"malformed chapter DOM")
            parts[#parts+1]=text(node.root._text:sub(cursor,child._openstart-1))
            parts[#parts+1]=render(child,depth+1,unclosed and boundary or nil);cursor=child_end+1
        end
        parts[#parts+1]=text(node.root._text:sub(cursor,content_end))
        local value=table.concat(parts)
        if allowed[tag] then return '<'..tag..'>'..value..'</'..tag..'>' end
        return value
    end
    local cleaned=render(wrapper,0)
    assert(cleaned:gsub("<[^>]+>",""):find("%S") or #assets>0,"empty chapter")
    return {html=cleaned,assets=assets}
end
return M
