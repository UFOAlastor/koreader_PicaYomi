-- A local-only source identity for reading downloads after an adapter is removed.
local Offline = {}
local LocalFavorites = require("util.local_favorites")
function Offline.knownIDs()
    local config = require("util.config")
    local ids = {}
    local history = config:get("history")
    for _, item in ipairs(type(history) == "table" and history or {}) do
        if type(item) == "table" and type(item.source) == "string" then ids[item.source] = true end
    end
    local favorites = config:get("local_favorites")
    for id, items in pairs(type(favorites) == "table" and favorites or {}) do
        if type(id) == "string" and type(items) == "table" and next(items) then ids[id] = true end
    end
    for _, comic in ipairs(require("util.offline_library").list()) do
        if type(comic.source_id) == "string" then ids[comic.source_id] = true end
    end
    return ids
end

function Offline.new(id)
    local source = require("source.base"):extend{
        identifier = id, name = id .. "（离线）", capabilities = { local_favorites = true },
        _offline = true,
        init = function(self) self._http_client = {} end,
    }
    function source:getComics()
        local comics = LocalFavorites.list(id)
        return true, { comics = comics, page = 1, pages = 1, total = #comics }
    end
    function source:getComicDetail(comic_id)
        local comic = LocalFavorites.find(id, comic_id)
        local entry = require("util.offline_library").entry(id, comic_id)
        local history = require("model.comic"):getHistoryItem(comic_id, id)
        return true, comic or (entry and entry.comic)
            or { _id = comic_id, title = history and history.title or tostring(comic_id) }
    end
    function source:getChapters(comic_id)
        local episodes = {}
        for _, ch in ipairs(require("util.offline_library").completedChapters(id, comic_id)) do
            episodes[#episodes + 1] = { _id = ch.order, order = ch.order, title = ch.title,
                pagesCount = ch.pages, sort_index = ch.sort_index }
        end
        return true, { episodes = episodes, page = 1, pages = 1, total = #episodes }
    end
    function source:getAllChapterImages(comic_id, chapter)
        local library = require("util.offline_library")
        if not library.isChapterComplete(id, comic_id, chapter) then return false, nil, "此章节尚未下载" end
        return true, { images = library.localImages(id, comic_id, chapter) }
    end
    return source
end
return Offline
