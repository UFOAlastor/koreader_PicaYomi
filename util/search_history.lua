-- util/search_history.lua
-- 搜索历史: 记住搜过的关键词, 下次点一下就能重搜
--
-- 存储位置: util/config.lua 管的 config.json, 键 `search_history`,
-- 值是一个**关键词字符串数组** (最新搜的排在最前)。
--
-- 为什么是全局一份而不是按源分桶: 关键词是用户脑子里的词, 不是某个源的内部
-- 编号 —— 换源之后"再看一眼刚才搜的那个词"是最常见的诉求。与「本地收藏」不同,
-- 收藏存的是漫画 id (各源编号空间不同, 必须分桶), 而这里存的是纯文本。
--
-- 只存关键词本身, 不存结果: 结果是时效性的 (源会更新), 存下来反而会误导用户。
local Config = require("util.config")
local logger = require("util.logger")

local M = {}

-- 存储键
local KEY = "search_history"

-- 上限: config.json 是一次性整份读写的, 不能让它无限增长
local MAX_ITEMS = 30

--- 归一化关键词 (去掉首尾空白); 空串返回 nil
--
-- 与 ui/search.lua 的搜索按钮用的是同一套规则 —— 两边不一致的话,
-- "搜的时候算空, 记历史的时候算不空", 会往历史里塞进一串空白。
local function normalize(keyword)
    if type(keyword) ~= "string" then return nil end
    local s = keyword:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    return s
end

--- 读出普通数组
--
-- **踩过的坑**: `rapidjson.decode` 返回的表带 metatable, 被标记为"JSON 对象";
-- 对这种表 `table.insert` 之后 `#t` 会变成 1, 但 `json.encode(t)` **仍然输出 `{}`**
-- —— 新数据被静默丢弃。所以读出来必须先重建一个普通数组, 再改再写回。
-- (同一个坑见 model/comic.lua 的 as_array 与 util/config.lua 的 clearHistory。)
local function read()
    local raw = Config:get(KEY, {})
    local out = {}
    if type(raw) == "table" then
        for _i, v in ipairs(raw) do
            -- 坏数据 (非字符串 / 空串) 直接丢掉, 不让它污染界面
            local s = normalize(v)
            if s then out[#out + 1] = s end
        end
    end
    return out
end

--- 全部历史关键词 (最新在前; 总是返回数组)
function M.list()
    return read()
end

function M.count()
    return #read()
end

--- 记录一次搜索 (已存在则提到最前, 不重复插入)
-- @return ok, err
function M.add(keyword)
    local s = normalize(keyword)
    if not s then return false, "关键词为空" end

    local items = read()
    for i = #items, 1, -1 do
        if items[i] == s then table.remove(items, i) end
    end
    table.insert(items, 1, s)
    while #items > MAX_ITEMS do table.remove(items) end

    local ok = Config:set(KEY, items)
    if not ok then return false, "写入搜索历史失败" end
    return true
end

--- 删除某个关键词 (不存在也算成功: 幂等)
-- @return ok, err
function M.remove(keyword)
    local s = normalize(keyword)
    if not s then return true end

    local items = read()
    local found = false
    for i = #items, 1, -1 do
        if items[i] == s then
            table.remove(items, i)
            found = true
        end
    end
    if not found then return true end

    local ok = Config:set(KEY, items)
    if not ok then return false, "写入搜索历史失败" end
    if logger.enabled then logger.info("Picayomi 搜索历史: 删除 " .. s) end
    return true
end

--- 清空搜索历史 (设置页 / 界面上的「清空历史」)
function M.clear()
    return Config:set(KEY, {})
end

-- 供测试用: 上限值
M.MAX_ITEMS = MAX_ITEMS
M.KEY = KEY

return M
