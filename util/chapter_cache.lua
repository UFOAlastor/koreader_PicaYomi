-- Last complete chapter directory, separate from image/offline-download data.
-- No source code, image URLs, credentials or partial responses are persisted.
local C = require("source.contract")
local json = require("rapidjson")
local lfs = require("libs/libkoreader-lfs")
local Storage = require("source.extensions.storage")
local Cache = { FRESH_SECONDS = 300, MAX_AGE = 7*86400,
    MAX_BYTES = 2*1024*1024, MAX_FILES = 64, MAX_TOTAL = 16*1024*1024 }

local function folder() return require("util.cache").DATA_CACHE_DIR .. "/chapters" end
local function path(key) return folder() .. "/" .. require("ffi/sha2").sha256(key) .. ".json" end
local fields = { "id", "manga_id", "title", "order", "legacy_order", "page_count", "pagesCount" }
local function snapshot(data, manga_id)
    assert(data.has_more == false, "incomplete chapter directory")
    local checked = C.list(data, "chapter", false, {manga_id=manga_id})
    local items = {}
    for i, item in ipairs(checked.items) do
        local out = {position=i}
        for _, field in ipairs(fields) do out[field] = item[field] end
        assert(type(out.order)=="string" or type(out.order)=="number", "invalid chapter order")
        items[i] = out
    end
    return {items=items, has_more=false, total=#items}
end

function Cache.read(key, manga_id, now)
    local ok, entry = pcall(function()
        local raw = Storage.read(path(key), Cache.MAX_BYTES)
        if not raw then return end
        local value = json.decode(raw)
        assert(value.format==1 and value.key==key and type(value.checked_at)=="number")
        local age = (now or os.time()) - value.checked_at
        assert(age>=0 and age<=Cache.MAX_AGE)
        return {data=snapshot(value.data, manga_id), fresh=age<Cache.FRESH_SECONDS}
    end)
    if ok then return entry end -- Corrupt/old cache is a miss, never a source error.
end

function Cache.diff(previous, current)
    local result = {added=0, removed=0, changed=0, reordered=0}
    local before, after = {}, {}
    for i, item in ipairs(previous and previous.items or {}) do
        local id=item.id or item._id or item.order
        if id==nil then result.different=true;return result end
        before[id]={item=item,index=i}
    end
    for i, item in ipairs(current.items) do
        local id=item.id or item._id or item.order
        if id==nil then result.different=true;return result end
        after[id]=true
        local old = before[id]
        if not old then result.added=result.added+1
        else
            if old.index~=i then result.reordered=result.reordered+1 end
            for _, field in ipairs(fields) do
                if old.item[field]~=item[field] then result.changed=result.changed+1; break end
            end
        end
    end
    for id in pairs(before) do if not after[id] then result.removed=result.removed+1 end end
    result.different=result.added+result.removed+result.changed+result.reordered>0
    return result
end

local function trim(keep)
    local files, total = {}, 0
    for name in lfs.dir(folder()) do
        if name:match("^[a-f0-9]+%.json$") then
            local file = folder() .. "/" .. name
            local attr = lfs.attributes(file)
            if attr and attr.mode=="file" then
                total=total+attr.size
                files[#files+1]={path=file,size=attr.size,time=attr.modification}
            end
        end
    end
    table.sort(files,function(a,b)
        if a.path==keep then return false end
        if b.path==keep then return true end
        return a.time==b.time and a.path<b.path or a.time<b.time
    end)
    local count = #files
    for _, file in ipairs(files) do
        if count<=Cache.MAX_FILES and total<=Cache.MAX_TOTAL then break end
        if os.remove(file.path) then count=count-1; total=total-file.size end
    end
end

function Cache.write(key, manga_id, data, now)
    local previous = Cache.read(key, manga_id, now)
    local value = snapshot(data, manga_id)
    local diff = Cache.diff(previous and previous.data, value)
    local raw = json.encode({format=1,key=key,checked_at=now or os.time(),data=value})
    assert(#raw<=Cache.MAX_BYTES, "chapter cache exceeds limit")
    Storage.write(path(key), raw)
    trim(path(key))
    return diff
end

return Cache
