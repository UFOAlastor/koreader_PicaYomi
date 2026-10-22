-- Reviewed migration map. Platform identities belong here, never in readers or
-- download strategies. Existing disk names and account keys must stay stable.
local I={}
local legacy={picacg=true,jm=true,htcomic=true}
local migrated={picacg=true,jm=true,htcomic=true,copymanga=true}
function I.legacyCache(id) return legacy[id]==true end
function I.diskPart(id,value)
    value=tostring(value or "")
    if migrated[id] and value:match("^[%w_.%-]+$") and value~="." and value~=".." then return value end
    return "id_"..require("ffi/sha2").sha256(value):sub(1,40)
end
function I.legacyRenderRequired(id) return id=="jm" end
function I.chapterOrder(manifest,chapter)
    if legacy[manifest.id] and manifest.publisher_id=="picayomi.legacy" then
        assert(chapter.legacy_order~=nil,"迁移章节缺少历史 order")
        return chapter.legacy_order
    end
    if manifest.id=="copymanga" and manifest.publisher_id=="picayomi.copymanga" then
        assert(chapter.id:match("^[%w_%-]+$") and #chapter.id<=160,"历史章节标识无效")
        return "c_"..chapter.id
    end
    return "c_"..require("ffi/sha2").sha256(chapter.id):sub(1,32)
end
return I
