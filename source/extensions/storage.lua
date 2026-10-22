local lfs = require("libs/libkoreader-lfs")
local json = require("rapidjson")
local Storage = {}

function Storage.mkdir(path)
    if lfs.attributes(path, "mode") == "directory" then return end
    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" then Storage.mkdir(parent) end
    assert(lfs.mkdir(path), "无法创建目录: " .. path)
end

function Storage.read(path, limit)
    local f = io.open(path, "rb")
    if not f then return nil end
    local raw = f:read((limit or 2 * 1024 * 1024) + 1)
    f:close()
    assert(raw and #raw <= (limit or 2 * 1024 * 1024), "文件过大或为空")
    return raw
end

function Storage.write(path, raw)
    Storage.mkdir(assert(path:match("^(.*)/[^/]+$")))
    local tmp = path .. ".tmp"
    local f = assert(io.open(tmp, "wb"), "无法写入文件")
    local ok, err = f:write(raw)
    local closed = f:close()
    if not ok or not closed then os.remove(tmp); error(err or "保存失败") end
    assert(os.rename(tmp, path), "原子保存失败")
end

function Storage.json(path, data)
    Storage.write(path, json.encode(data))
end

return Storage
