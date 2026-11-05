-- Small, bounded metadata snapshots. Keys are scoped by source/account/settings.
local json=require('rapidjson')
local Storage=require('source.extensions.storage')
local lfs=require('libs/libkoreader-lfs')
local Cache={FRESH_SECONDS=300,RETRY_SECONDS=30,MAX_AGE=7*86400,MAX_BYTES=128*1024,MAX_FILES=64}
local attempts={}
local fields={'title','chineseTeam','description','author','updated_at','update_time','metadata','pagesCount','epsCount',
    'likesCount','finished','tags','categories','meta_text'}
local function folder()return require('util.cache').DATA_CACHE_DIR..'/details'end
local function path(key)return folder()..'/'..require('ffi/sha2').sha256(key)..'.json'end
function Cache.read(key)
    if not key then return end
    local ok,value=pcall(function()
        local raw=Storage.read(path(key),Cache.MAX_BYTES)
        if not raw then return end
        local entry=json.decode(raw)
        assert(entry.format==1 and entry.key==key and type(entry.data)=='table' and type(entry.time)=='number')
        local age=os.time()-entry.time
        assert(age>=0 and age<=Cache.MAX_AGE)
        return entry
    end)
    if ok then return value end
end
function Cache.write(key,data)
    if not key then return end
    -- Never persist session/favorite state or source response fields not displayed.
    return pcall(function()
        local value={}
        for _,field in ipairs(fields)do value[field]=data[field]end
        local raw=json.encode{format=1,key=key,time=os.time(),data=value}
        assert(#raw<=Cache.MAX_BYTES)
        local keep=path(key);Storage.write(keep,raw)
        local files={}
        for name in lfs.dir(folder())do
            if name:match('^[a-f0-9]+%.json$')then
                local file=folder()..'/'..name
                files[#files+1]={path=file,time=lfs.attributes(file,'modification')or 0}
            end
        end
        table.sort(files,function(a,b)return a.time==b.time and a.path<b.path or a.time<b.time end)
        local count=#files
        for _,file in ipairs(files)do
            if count<=Cache.MAX_FILES then break end
            if file.path~=keep and os.remove(file.path)then count=count-1 end
        end
    end)
end
function Cache.admit(key,force,missing_favorite)
    if not key then return true end
    local now=os.time()
    local attempt=attempts[key]
    local deadline=attempt and attempt.deadline
    if not force and deadline and now<deadline
        and not (missing_favorite and attempt.success) then return false end
    -- Bound the in-memory cooldown table too.
    local count=0
    for k,v in pairs(attempts)do if now>=v.deadline then attempts[k]=nil else count=count+1 end end
    if count>=Cache.MAX_FILES then attempts={}end
    local lease={deadline=now+Cache.RETRY_SECONDS}
    attempts[key]=lease
    return true,lease
end
function Cache.cancel(key,lease)
    if key and attempts[key]==lease then attempts[key]=nil end
end
function Cache.failure(key,lease)
    if key and attempts[key]==lease then lease.deadline=os.time()+Cache.RETRY_SECONDS end
end
function Cache.success(key)
    if key then attempts[key]={deadline=os.time()+Cache.FRESH_SECONDS,success=true} end
end
return Cache
