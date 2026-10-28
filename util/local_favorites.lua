-- util/local_favorites.lua
-- 本地收藏: 没登录账号 (或该源没有网络收藏能力) 时的兜底
--
-- 存储位置: util/config.lua 管的 config.json, 键 `local_favorites.<source_id>`,
-- 值是一个漫画数组 (最新收藏排在最前)。按源分桶是必须的 —— picacg 和 源 B 的
-- comic id 是两套编号, 混在一个数组里会互相干扰 (取消收藏删错条)。
--
-- 只存卡片和详情页真正会读的字段 (见 ui/common/visual_comic_list.lua 与
-- comic_detail.lua), 不把源的原始响应整个塞进去: config.json 是整份读写的,
-- 塞进嵌套的原始数据会让每次收藏都重写一大坨。
local Config = require("util.config")
local logger = require("util.logger")

local M = {}

-- 卡片 / 详情页会读到的字段
local KEEP_FIELDS = {
    "content_type",
    "_id", "title", "author",
    "categories", "categories_text", "tags", "tags_text",
    "thumb", "description",
    "epsCount", "pagesCount", "likesCount", "commentsCount", "viewsCount",
    "finished", "updated_at", "created_at", "update_time",
}

local function storageKey(source_id)
    return "local_favorites." .. tostring(source_id or "unknown")
end

local function sameId(a, b)
    if a == nil or b == nil then return false end
    return tostring(a) == tostring(b)
end

--- 裁剪成"能存也能渲染"的一条记录
local function trim(comic, saved_at)
    local entry = {}
    for _i, name in ipairs(KEEP_FIELDS) do
        local v = comic[name]
        if v ~= nil then entry[name] = v end
    end
    local Contract=require("source.contract")
    local valid,display=pcall(Contract.listDisplay,comic._list_display)
    if valid and display then
        entry._list_display=display
    end
    local ok,metadata=pcall(Contract.metadata,comic.metadata)
    if ok then entry.metadata=metadata end
    entry._id = tostring(comic._id or "")
    entry.isFavourite = true
    entry.local_favorite = true
    entry.saved_at = saved_at or os.time()
    return entry
end

--- 某源的本地收藏 (总是返回数组; 坏数据会被丢掉)
function M.list(source_id)
    local raw = Config:get(storageKey(source_id), {})
    if type(raw) ~= "table" then return {} end
    local out = {}
    for _i, item in ipairs(raw) do
        if type(item) == "table" and item._id ~= nil then
            item.isFavourite = true
            item.local_favorite = true
            out[#out + 1] = item
        end
    end
    return out
end

function M.count(source_id)
    return #M.list(source_id)
end

function M.find(source_id, comic_id)
    for _i, item in ipairs(M.list(source_id)) do
        if sameId(item._id, comic_id) then return item end
    end
    return nil
end

function M.isFavorite(source_id, comic_id)
    if comic_id == nil then return false end
    return M.find(source_id, comic_id) ~= nil
end

--- 加入本地收藏 (已存在则只刷新内容, 不重复插入)
function M.add(source_id, comic)
    if type(comic) ~= "table" then return false, "无效的作品数据" end
    if comic._id == nil or tostring(comic._id) == "" then
        return false, "作品缺少 ID, 无法本地收藏"
    end

    local items = M.list(source_id)
    local entry, replaced
    for i, item in ipairs(items) do
        if sameId(item._id, comic._id) then
            entry = trim(comic, item.saved_at)   -- 保留原收藏时间
            items[i] = entry
            replaced = true
            break
        end
    end
    if not replaced then
        entry = trim(comic)
        table.insert(items, 1, entry)            -- 最新收藏排最前
    end

    local ok = Config:set(storageKey(source_id), items)
    if not ok then return false, "写入本地收藏失败" end
    if logger.enabled then logger.info(string.format("Picayomi 本地收藏: %s %s",
        replaced and "更新" or "加入", tostring(entry.title or entry._id))) end
    return true
end

--- 从本地收藏移除 (不存在也算成功: 幂等, 避免"取消"报错)
function M.remove(source_id, comic_id)
    local items = M.list(source_id)
    local found = false
    for i = #items, 1, -1 do
        if sameId(items[i]._id, comic_id) then
            table.remove(items, i)
            found = true
        end
    end
    if not found then return true end
    local ok = Config:set(storageKey(source_id), items)
    if not ok then return false, "写入本地收藏失败" end
    if logger.enabled then logger.info("Picayomi 本地收藏: 移除 " .. tostring(comic_id)) end
    return true
end

--- 按当前状态增/删; 返回**新状态** (true = 已收藏), 失败时返回 nil, err
function M.toggle(source_id, comic)
    if M.isFavorite(source_id, comic and comic._id) then
        local ok, err = M.remove(source_id, comic._id)
        if not ok then return nil, err end
        return false
    end
    local ok, err = M.add(source_id, comic)
    if not ok then return nil, err end
    return true
end

--- 清空某源的本地收藏 (设置页/测试用)
function M.clear(source_id)
    return Config:set(storageKey(source_id), {})
end

return M
