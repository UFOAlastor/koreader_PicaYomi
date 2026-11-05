-- Local, field-weighted BM25 over the collected candidates. No network or model.
local M={}
local function normalized(value)
    if type(value)~="string" then return "" end
    local out={}
    for c in value:sub(1,4096):gmatch("[%z\1-\127\194-\244][\128-\191]*")do
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
    for i,item in ipairs(items)do
        local fields={normalized(item.title),normalized(text(item.author)),normalized(text(item.aliases or item.alias))}
        local doc={item=item,fields={},exact=q~=""and fields[1]==q,contains=q~=""and fields[1]:find(q,1,true)~=nil}
        local seen={}
        for f,value in ipairs(fields)do
            local ts=tokens(value,chars==1);local tf={}
            for _,term in ipairs(ts)do if unique[term]then tf[term]=(tf[term]or 0)+1;seen[term]=true end end
            doc.fields[f]={tf=tf,len=#ts};lengths[f]=lengths[f]+#ts
        end
        for term in pairs(seen)do df[term]=(df[term]or 0)+1 end
        docs[i]=doc
        if yield_fn and i%64==0 then yield_fn()end
    end
    local n=#docs;local weights={3,1,1.5}
    for i,doc in ipairs(docs)do
        local score=doc.contains and 8 or 0
        for f,field in ipairs(doc.fields)do
            local avg=lengths[f]/math.max(1,n)
            for _,term in ipairs(terms)do
                local tf=field.tf[term]or 0
                if tf>0 then
                    local idf=math.log(1+(n-(df[term]or 0)+.5)/((df[term]or 0)+.5))
                    score=score+weights[f]*idf*(tf*2.2)/(tf+1.2*(.25+.75*field.len/math.max(1,avg)))
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
