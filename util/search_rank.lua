-- Local, field-weighted BM25 over the collected candidates. No network or model.
local M={}
local function normalized(value)
    if type(value)~="string" then return "" end
    value=value:sub(1,4096)
    if not value:find("[\128-\255]")then
        return (value:lower():gsub("%s+"," "):gsub("^ ",""):gsub(" $",""))
    end
    local out={}
    for c in value:gmatch("[%z\1-\127\194-\244][\128-\191]*")do
        local a,b,d=c:byte(1,3)
        if a==239 and b and d then
            local cp=(a-224)*4096+(b-128)*64+d-128
            if cp>=65281 and cp<=65374 then c=string.char(cp-65248)end
        elseif c=="　"then c=" "end
        out[#out+1]=c:lower()
    end
    return (table.concat(out):gsub("%s+"," "):gsub("^ ",""):gsub(" $",""))
end
M.normalize=normalized
local function tokens(text,single)
    local out,word,previous={},"",nil
    local function flush()if word~=""then out[#out+1]=word;word=""end end
    for c in text:gmatch("[%z\1-\127\194-\244][\128-\191]*")do
        if #c==1 then
            previous=nil
            if c:match("[%w]")then word=word..c else flush()end
        else
            flush()
            if c=="，"or c=="。"or c=="："or c=="！"or c=="？"or c=="《"or c=="》"then previous=nil
            else
                if single then out[#out+1]=c elseif previous then out[#out+1]=previous..c end
                previous=c
            end
        end
    end
    flush();return out
end
local function text(value)
    if type(value)=="string"then return value end
    if type(value)=="table"then
        local out={};for _,s in ipairs(value)do if type(s)=="string"then out[#out+1]=s end end
        return table.concat(out," ")
    end
    return ""
end
function M.rank(items,query,current_source,yield_fn)
    local q=normalized(query)
    local chars=0;for _ in q:gmatch("[%z\1-\127\194-\244][\128-\191]*")do chars=chars+1 end
    local terms,unique={},{}
    for _,term in ipairs(tokens(q,chars==1))do if not unique[term]then unique[term]=true;terms[#terms+1]=term end end
    local docs,df,lengths={},{},{0,0,0}
    -- Only this invocation owns the cache. Repeated short author/alias fields
    -- share immutable query statistics; titles and long fields are not retained.
    local field_cache,cache_count={},0
    local function field(raw,cacheable)
        local cached=cacheable and field_cache[raw]
        if cached then return cached end
        local value=normalized(raw)
        local ts=tokens(value,chars==1);local tf={}
        for _,term in ipairs(ts)do if unique[term]then tf[term]=(tf[term]or 0)+1 end end
        local result={tf=tf,len=#ts,value=value}
        if cacheable and #raw<=256 and cache_count<64 then
            field_cache[raw]=result;cache_count=cache_count+1
        end
        return result
    end
    for i,item in ipairs(items)do
        local title=field(type(item.title)=="string"and item.title or "",false)
        local doc={item=item,fields={title,field(text(item.author),true),field(text(item.aliases or item.alias),true)},
            exact=q~=""and title.value==q,contains=q~=""and title.value:find(q,1,true)~=nil}
        local seen={}
        for f,value in ipairs(doc.fields)do
            lengths[f]=lengths[f]+value.len
            for term in pairs(value.tf)do seen[term]=true end
        end
        for term in pairs(seen)do df[term]=(df[term]or 0)+1 end
        docs[i]=doc
        if yield_fn and i%64==0 then yield_fn()end
    end
    local n=#docs;local weights={3,1,1.5}
    -- Corpus statistics do not change between documents or fields.
    local idfs,averages={},{}
    for _,term in ipairs(terms)do
        idfs[term]=math.log(1+(n-(df[term]or 0)+.5)/((df[term]or 0)+.5))
    end
    for f,length in ipairs(lengths)do averages[f]=math.max(1,length/math.max(1,n))end
    for i,doc in ipairs(docs)do
        local score=doc.contains and 8 or 0
        for f,field in ipairs(doc.fields)do
            local avg=averages[f]
            for _,term in ipairs(terms)do
                local tf=field.tf[term]or 0
                if tf>0 then
                    local idf=idfs[term]
                    score=score+weights[f]*idf*(tf*2.2)/(tf+1.2*(.25+.75*field.len/avg))
                end
            end
        end
        doc.score=score
        if yield_fn and i%64==0 then yield_fn()end
    end
    table.sort(docs,function(a,b)
        if a.exact~=b.exact then return a.exact end
        if a.score~=b.score then return a.score>b.score end
        local ar,br=a.item.search_rank or 1,b.item.search_rank or 1
        if ar~=br then return ar<br end
        local ac,bc=a.item.source_id==current_source,b.item.source_id==current_source
        if ac~=bc then return ac end
        if a.item.source_id~=b.item.source_id then return a.item.source_id<b.item.source_id end
        return tostring(a.item._id)<tostring(b.item._id)
    end)
    local result={};for i,doc in ipairs(docs)do result[i]=doc.item end
    return result
end
return M
