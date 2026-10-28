-- Literal text only: never match HTML attributes, URLs, or regular expressions.
local M={}
function M.validate(lines)
    assert(type(lines)=='table' and #lines<=32,'过滤文案最多 32 行')
    require('source.contract').array(lines,'text_filters')
    for _,line in ipairs(lines) do
        assert(type(line)=='string' and #line>0 and #line<=512 and not line:find('[%c]'),'每行过滤文案须为 1 至 512 字节的普通文本')
    end
    return lines
end
function M.defaults(source)
    return source and source.text_filters or {}
end
function M.options(source)
    local id=assert(source and source.identifier,'missing source')
    local config=require('util.config')
    return config:get('novel_filters.'..id..'.enabled',true),
        M.validate(config:get('novel_filters.'..id..'.lines',M.defaults(source)))
end
function M.parse(value)
    local lines={}
    for line in (value..'\n'):gmatch('(.-)\n') do
        line=line:gsub('\r$',''):gsub('^%s+',''):gsub('%s+$','')
        if line~='' then lines[#lines+1]=line end
    end
    return M.validate(lines)
end
function M.apply(html,lines)
    M.validate(lines)
    local util=require('util')
    local function text(value)
        value=util.htmlEntitiesToUtf8(value)
        for _,line in ipairs(lines) do
            local parts,start={},1
            while true do
                local a,b=value:find(line,start,true)
                if not a then parts[#parts+1]=value:sub(start);break end
                parts[#parts+1]=value:sub(start,a-1);start=b+1
            end
            value=table.concat(parts)
        end
        return value:gsub('&','&amp;'):gsub('<','&lt;'):gsub('>','&gt;')
    end
    -- Input is the host's sanitized local chapter, not source HTML.
    local parts,cursor={},1
    for a,tag,b in html:gmatch('()(<[^>]+>)()') do
        parts[#parts+1]=text(html:sub(cursor,a-1));parts[#parts+1]=tag;cursor=b
    end
    parts[#parts+1]=text(html:sub(cursor))
    return table.concat(parts)
end
function M.document(prepared,source)
    if not source then return prepared end
    local enabled,lines=M.options(source)
    if not enabled or #lines==0 then return prepared end
    local Store=require('source.extensions.storage')
    local original=assert(Store.read(prepared.path,1024*1024))
    local filtered=M.apply(original,lines)
    if filtered==original then return prepared end
    -- Keep the canonical downloaded chapter intact. Illustrations remain local
    -- siblings, and toggling the feature restores the exact original bytes.
    local profile=require('ffi/sha2').sha256(require('rapidjson').encode(lines))
    local path=prepared.path:gsub('/chapter%.html$','/chapter-filter-'..profile..'.html')
    assert(path~=prepared.path,'unexpected prepared document path')
    if Store.read(path,1024*1024)~=filtered then Store.write(path,filtered) end
    local view={};for k,v in pairs(prepared) do view[k]=v end
    view.path=path
    return view
end
return M
