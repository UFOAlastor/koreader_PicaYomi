-- Convert untrusted chapter HTML into a closed local document, without JS.
local M={}
local function escape(s)
    return (s:gsub("&","&amp;"):gsub("<","&lt;"):gsub(">","&gt;"):gsub('"',"&quot;"))
end
function M.normalize(html)
    assert(type(html)=="string" and #html<=262144,"chapter HTML too large")
    local util=require("util")
    local root=require("htmlparser").parse('<div id="pychapter">'..html..'</div>',2000000)
    local wrapper=assert(root:select("#pychapter")[1])
    local allowed={p=true,div=true,span=true,br=true,hr=true,h1=true,h2=true,h3=true,
        h4=true,strong=true,b=true,em=true,i=true,u=true,blockquote=true,ul=true,ol=true,li=true,ruby=true,rt=true,rp=true}
    local blocked={script=true,style=true,iframe=true,object=true,embed=true,svg=true,math=true,
        form=true,input=true,button=true,textarea=true,link=true,meta=true}
    local assets,by_url={},{}
    local nodes=0
    local function text(s) return escape(util.htmlEntitiesToUtf8(s)) end
    local function render(node,depth)
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
        for _,child in ipairs(node.nodes) do
            assert(child._openstart>=cursor and child._closeend<=node._closestart,"malformed chapter DOM")
            parts[#parts+1]=text(node.root._text:sub(cursor,child._openstart-1))
            parts[#parts+1]=render(child,depth+1);cursor=child._closeend+1
        end
        parts[#parts+1]=text(node.root._text:sub(cursor,node._closestart-1))
        local value=table.concat(parts)
        if allowed[tag] then return '<'..tag..'>'..value..'</'..tag..'>' end
        return value
    end
    local cleaned=render(wrapper,0)
    assert(cleaned:gsub("<[^>]+>",""):find("%S") or #assets>0,"empty chapter")
    return {html=cleaned,assets=assets}
end
return M
