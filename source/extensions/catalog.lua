local B=require("source.extensions.package")
local N=require("source.extensions.https")
local C={}
function C.digest(v) return type(v)=="string" and #v==64 and v:match("^[0-9a-f]+$")~=nil end
function C.validate(data)
    assert(type(data)=="table" and (data.format==1 or data.format==2)
        and type(data.name)=="string" and #data.name<=160 and type(data.sources)=="table", "订阅目录格式无效")
    if data.format==2 then
        assert(type(data.publisher_id)=="string" and #data.publisher_id<=100 and data.publisher_id:match("^[%w_%.%-]+$"),"目录发布者无效")
        assert(type(data.revision)=="number" and data.revision%1==0 and data.revision>=1 and data.revision<2^53,"目录修订号无效")
    end
    assert(#data.sources<=200,"订阅源版本数量超限")
    local seen={}
    for k,e in pairs(data.sources) do
        assert(type(k)=="number" and k>=1 and k<=#data.sources and k%1==0,"目录必须为数组")
        assert(type(e)=="table" and B.id(e.id) and B.version(e.version) and C.digest(e.sha256)
            and N.validURL(e.url) and type(e.name)=="string" and #e.name<=160
            and type(e.api_version)=="number" and e.api_version%1==0 and e.api_version>=1
            and B.version(e.min_app_version) and (not e.max_app_version or B.version(e.max_app_version))
            and (e.notes==nil or type(e.notes)=="string" and #e.notes<=4000),"订阅条目无效")
        local key=e.id..(data.format==2 and ":"..e.version or "")
        assert(not seen[key],"订阅有重复源版本"); seen[key]=true
        if data.format==2 then
            assert(type(e.size)=="number" and e.size>=1 and e.size<=B.MAX_BYTES and e.size%1==0,"发行包大小无效")
            require("source.extensions.signature").unhex(e.signature,64)
            assert(e.publisher_id==data.publisher_id,"条目发布身份不符")
        end
        assert(e.revoked==nil or type(e.revoked)=="boolean","撤回状态无效")
    end
    return data
end
function C.compatible(e,host)
    if type(e.api_version)~="number" or e.api_version%1~=0 or not B.version(e.min_app_version)
        or e.max_app_version and not B.version(e.max_app_version) then return false end
    return (e.api_version>=1 and e.api_version<=B.API_VERSION) and B.compare(host,e.min_app_version)>=0
        and (not e.max_app_version or B.compare(host,e.max_app_version)<=0)
end
function C.candidate(repo,rec,id,host)
    local status={code="latest",label="已是最新",entry=nil}
    if rec and (rec.publisher_id and (repo.publisher_id~=rec.publisher_id or repo.public_key~=rec.public_key)
        or not rec.publisher_id and rec.origin~=repo.url) then
        return {code="origin_conflict",label="其他来源"}
    end
    local newer,revoked,quarantined=false,false,false
    for _,e in ipairs(repo.sources or {}) do
        if e.id==id then
            if rec and e.version==rec.manifest.version and e.revoked then revoked=true end
            if not rec or B.compare(e.version,rec.manifest.version)>0 then
                newer=true
                if not e.revoked and not (rec and rec.quarantine and rec.quarantine[e.sha256]) and C.compatible(e,host) then
                    if not status.entry or B.compare(e.version,status.entry.version)>0 then status.entry=e end
                elseif rec and rec.quarantine and rec.quarantine[e.sha256] then quarantined=true end
            end
        end
    end
    if status.entry then status.code,status.label="update","可更新"
    elseif newer then status.code,status.label=quarantined and "quarantined" or "incompatible",quarantined and "失败版本已隔离" or "没有兼容的新版本" end
    if revoked and not status.entry then status.code,status.label="revoked","当前版本已撤回" end
    if rec and rec.pinned then status.code,status.label="pinned","已固定版本" end
    if rec and rec.pending then status.code,status.label="pending","待重启" end
    return status
end
return C
