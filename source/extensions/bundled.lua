-- Only packages physically shipped with the host may bootstrap legacy identities.
local B={}
local Storage=require("source.extensions.storage")
local json=require("rapidjson")
local root=assert(debug.getinfo(1,"S").source:match("^@(.*)/source/extensions/[^/]+$"))
function B.read(base)
    local root=base or root
    local index=Storage.read(root.."/bundled/index.json")
    local result,errors={},{}
    if index then
        local entries=json.decode(index)
        assert(type(entries)=="table" and #entries<=3,"附带源清单无效")
        for _,entry in ipairs(entries) do
            local ok,raw=pcall(function()
                assert(type(entry)=="table" and require("source.extensions.package").legacy(entry.id),"附带源 ID 无效")
                local raw=assert(Storage.read(root.."/bundled/"..entry.id..".pysource"))
                assert(require("ffi/sha2").sha256(raw)==entry.sha256,"附带源摘要不符")
                return raw
            end)
            if ok then result[entry.id]=raw else errors[type(entry)=="table" and entry.id or "bundled"]=tostring(raw) end
        end
    else
        -- Source checkout only. Release artifacts contain bundles, never extensions/.
        local lfs=require("libs/libkoreader-lfs")
        for _,id in ipairs({"picacg","jm","htcomic"}) do
            local dir=root.."/extensions/"..id
            local manifest=Storage.read(dir.."/manifest.json")
            if manifest then
                local files={}
                for name in lfs.dir(dir) do
                    if name:match("^[%w_%-]+%.lua$") then files[name]=Storage.read(dir.."/"..name) end
                end
                result[id]=json.encode({format=1,manifest=json.decode(manifest),files=files})
            end
        end
    end
    return result,errors
end
return B
