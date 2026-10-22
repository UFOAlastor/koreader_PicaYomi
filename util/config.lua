local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("util.logger")
local json = require("rapidjson")

local Config = {}

-- 插件数据目录
local PLUGIN_ID = "picayomi"
local DATA_DIR = DataStorage:getDataDir() .. "/" .. PLUGIN_ID
local CONFIG_FILE = DATA_DIR .. "/config.json"

-- 确保插件数据目录存在
--
-- 记忆化: 本函数在每次 get/set 前都会走一遍, 而 get 在翻页路径上每页要调 ≥2 次
-- (stream_reader 的 prefetch_count)、每下载一张图 1 次 (picacg headers)。一次
-- lfs.attributes 在 e-ink 存储上也是开销。
local data_dir_ready = false
local function ensureDataDir()
    if data_dir_ready then return end
    if not lfs.attributes(DATA_DIR, "mode") then
        if logger.enabled then logger.info("Picayomi Config: 创建数据目录", DATA_DIR) end
        lfs.mkdir(DATA_DIR)
    end
    data_dir_ready = true
end

-- 内存缓存
--
-- 原来每次 get 都 io.open + read("*all") + json.decode 整个 config.json。
-- 这个文件是"单体"的 —— 除了设置项, 还装着 history(每源≤50) 与
-- local_favorites(每源≤500), 可以到几百 KB。而 get 的调用密度极高:
--   · 翻页路径每页 ≥2 次 (stream_reader.lua prefetch_count)
--   · 每下载一张图 1 次 (source/picacg/headers.lua)
--   · 每次 源 B 元数据请求 1 读 + 1 写 (source/jm/api.lua rememberDomain)
--   · 每个详情页若干次 (历史/本地收藏状态)
-- 用 mtime 守卫的缓存把这一整类开销抹掉。
--
-- 注意: 返回的是**同一个表**。调用方目前都只读或先复制 (model/comic.lua 的
-- as_array、local_favorites 的 list 都重建数组), 因此共享是安全的; 但新增
-- 调用方时不要直接改 get 的返回值 —— 改完要么 set 落盘, 要么会被下次读覆盖。
local cached_config = nil
local cached_stamp = nil   -- 文件 mtime(number); false 表示文件不存在

local function configStamp()
    return lfs.attributes(CONFIG_FILE, "modification") or false
end

--- 丢弃内存缓存, 下次 get 重新读盘
local function invalidateConfig()
    cached_config = nil
    cached_stamp = nil
end

-- 加载配置 (带 mtime 守卫的内存缓存)
local function loadConfig()
    ensureDataDir()

    local stamp = configStamp()
    if cached_config and cached_stamp == stamp then
        return cached_config
    end

    local config = {}
    local f = io.open(CONFIG_FILE, "r")

    if f then
        local content = f:read("*all")
        f:close()

        if content and content ~= "" then
            local ok, decoded = pcall(json.decode, content)
            if ok and decoded then
                config = decoded
            else
                logger.warn("Picayomi Config: 解析配置文件失败")
            end
        end
    end

    cached_config = config
    cached_stamp = stamp
    return cached_config
end

-- 保存配置
local function saveConfig(config)
    ensureDataDir()

    local ok, encoded = pcall(json.encode, config)
    if not ok or not encoded then
        logger.err("Picayomi Config: 序列化配置失败")
        invalidateConfig()   -- 内存里已被 set 改过, 但没落盘: 丢掉缓存以免与磁盘不一致
        return false
    end

    local f = io.open(CONFIG_FILE, "w")
    if not f then
        logger.err("Picayomi Config: 无法打开配置文件进行写入")
        invalidateConfig()
        return false
    end

    f:write(encoded)
    f:close()

    -- 直接刷新缓存而不是靠 mtime: 同一秒内连写两次时 mtime 可能不变,
    -- 那样下一次 get 会读到旧内容。
    cached_config = config
    cached_stamp = configStamp()

    return true
end

-- 解析点分隔的路径，返回最终值
local function getNested(config, key)
    -- 如果 key 不含点，直接查
    if not key:find("%.") then
        return config[key]
    end

    local parts = {}
    for part in key:gmatch("[^.]+") do
        table.insert(parts, part)
    end

    local current = config
    for _, part in ipairs(parts) do
        if type(current) ~= "table" then
            return nil
        end
        current = current[part]
    end

    return current
end

-- 设置点分隔的嵌套路径
local function setNested(config, key, value)
    -- 如果 key 不含点，直接设
    if not key:find("%.") then
        config[key] = value
        return
    end

    local parts = {}
    for part in key:gmatch("[^.]+") do
        table.insert(parts, part)
    end

    local current = config
    for i = 1, #parts - 1 do
        local part = parts[i]
        if type(current[part]) ~= "table" then
            current[part] = {}
        end
        current = current[part]
    end

    current[parts[#parts]] = value
end

-- 获取设置项
function Config:get(key, default)
    local config = loadConfig()

    if key == nil then
        return config
    end

    local value = getNested(config, key)
    if value == nil then
        return default
    end

    return value
end

--- 在内存里的 config 表上应用一次 set/clear (不落盘)
local function applySet(config, key, value)
    -- 支持 nil 值删除
    if value == nil then
        -- 检查是否是嵌套路径
        if key:find("%.") then
            local parts = {}
            for part in key:gmatch("[^.]+") do
                table.insert(parts, part)
            end
            local current = config
            for i = 1, #parts - 1 do
                if type(current[parts[i]]) ~= "table" then
                    return false  -- 路径不存在，视为已删除
                end
                current = current[parts[i]]
            end
            current[parts[#parts]] = nil
        else
            config[key] = nil
        end
    else
        if key:find("%.") then
            setNested(config, key, value)
        else
            config[key] = value
        end
    end
    return true
end

-- 设置配置项
function Config:set(key, value)
    if key == nil then
        return false
    end

    local config = loadConfig()
    applySet(config, key, value)
    return saveConfig(config)
end

--- 批量设置 / 删除, **只落盘一次**
--
-- 为什么需要: 加密落盘一个凭据要同时写"密文键"和"删明文键"。逐条 set 会在
-- Kindle 的 e-ink 存储上写多次 config.json (每次都是 open+write+close), 登录
-- 一次就要写 6~8 次。这里把同一批变更合并成一次序列化。
--
-- @param updates { {key, value}, ... } value 为 nil 表示删除
function Config:setMany(updates)
    if type(updates) ~= "table" or #updates == 0 then
        return true
    end

    local config = loadConfig()
    for _i, entry in ipairs(updates) do
        local key, value = entry[1], entry[2]
        if key then applySet(config, key, value) end
    end
    return saveConfig(config)
end

-- 保存多个配置项
function Config:save(key, value)
    return self:set(key, value)
end

-- 清除某个配置项
-- 复用 set(key, nil) 的删除逻辑，以支持点分隔的嵌套路径 (如 "source.picacg.token")
function Config:clear(key)
    if key == nil then
        return false
    end

    return self:set(key, nil)
end

-- 注意: 这里曾有一组 saveUserAuth/getUserAuth/saveUserProfile/getUserProfile,
-- 它们会把 token / 用户资料以**明文**写进 config.json。全项目没有调用点, 已删除。
--
-- 需要"记住登录"时一律走 util/secret_store.lua:
--   * 密码 / 会话 Cookie / token 加密后落盘 (且不再保留明文键);
--   * 用户资料用 SecretStore.set_json 落盘 (含邮箱等 PII)。
-- 不要以任何形式直接 config:set 这类内容。

-- 保存历史记录
function Config:saveHistory(history)
    if logger.enabled then logger.info("Picayomi Config: 保存历史记录") end
    return self:set("history", history)
end

-- 获取历史记录
function Config:getHistory()
    return self:get("history", {})
end

-- 清除历史记录
-- @param comic_id  可选: 只删这一条; 缺省则清空
-- @param source_id 可选: 只作用于该源 (历史按源隔离, 见 model/comic.lua);
--                   两者都缺省时清空全部源
function Config:clearHistory(comic_id, source_id)
    -- 必须重建普通数组再改: 从 JSON 读回来的表可能带"对象"标记, 直接改完再编码
    -- 会输出 {} —— 记录被静默丢光 (与 model/comic.lua 里 as_array 的注释同一个坑)
    local raw = self:getHistory()
    local history = {}
    if type(raw) == "table" then
        for _i, item in ipairs(raw) do
            table.insert(history, item)
        end
    end

    if comic_id then
        -- 清除特定漫画的历史记录 (同源才算同一条)
        for i = #history, 1, -1 do
            local item = history[i]
            if item.id == comic_id
               and (source_id == nil or item.source == source_id) then
                table.remove(history, i)
            end
        end
    elseif source_id then
        -- 只清空这一个源的历史
        if logger.enabled then logger.info("Picayomi Config: 清空历史记录 (源 " .. tostring(source_id) .. ")") end
        for i = #history, 1, -1 do
            if history[i].source == source_id then
                table.remove(history, i)
            end
        end
    else
        if logger.enabled then logger.info("Picayomi Config: 清除所有历史记录") end
        history = {}
    end

    return self:saveHistory(history)
end

return Config