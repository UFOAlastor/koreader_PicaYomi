local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local logger = require("util.logger")
local _ = require("gettext")

local Cache = {}

-- 缓存目录，对齐 rakuyomi 路径格式
-- 全部缓存统一挂在同一个根下, 便于统计大小与按类型清理:
--   <base>/cache/images[/covers]  封面与图片缓存
--   <base>/cache/reading/...      流式阅读按需下载的页面
--   <base>/cache/downloads/...    离线打包的 CBZ
--   <base>/cache/data/...         API 元数据
--   <base>/cache/temp/...         下载中转/占位文件
Cache.BASE_DIR = DataStorage:getDataDir() .. "/picayomi"
Cache.CACHE_DIR = Cache.BASE_DIR .. "/cache"
Cache.IMAGE_CACHE_DIR = Cache.CACHE_DIR .. "/images"
Cache.COVER_CACHE_DIR = Cache.IMAGE_CACHE_DIR .. "/covers"
Cache.READING_CACHE_DIR = Cache.CACHE_DIR .. "/reading"
Cache.DOWNLOAD_CACHE_DIR = Cache.CACHE_DIR .. "/downloads"
Cache.DATA_CACHE_DIR = Cache.CACHE_DIR .. "/data"
Cache.TEMP_DIR = Cache.CACHE_DIR .. "/temp"

-- 缓存存储
local cache_store = {}

-- 将表转换为字符串的函数
function Cache.tableToString(tbl, level)
    level = level or 0
    if type(tbl) ~= "table" then
        if type(tbl) == "string" then
            return string.format("%q", tbl)
        else
            return tostring(tbl)
        end
    end

    local result = "{"
    local indent = string.rep("  ", level)
    local indent_inner = string.rep("  ", level + 1)
    local sep = ""

    for k, v in pairs(tbl) do
        local key
        if type(k) == "string" then
            key = string.format("[%q]", k)
        else
            key = "[" .. tostring(k) .. "]"
        end

        local value
        if type(v) == "table" then
            value = Cache.tableToString(v, level + 1)
        elseif type(v) == "string" then
            value = string.format("%q", v)
        else
            value = tostring(v)
        end

        result = result .. sep .. "\n" .. indent_inner .. key .. " = " .. value
        sep = ","
    end

    if result ~= "{" then
        result = result .. "\n" .. indent
    end
    result = result .. "}"
    return result
end

-- 初始化缓存目录
function Cache:init()
    -- 创建基础目录
    self:createDir(self.BASE_DIR)

    -- 创建主缓存目录
    self:createDir(self.CACHE_DIR)

    -- 创建图片/封面缓存目录
    self:createDir(self.IMAGE_CACHE_DIR)
    self:createDir(self.COVER_CACHE_DIR)

    -- 创建阅读页/下载/数据/临时目录
    self:createDir(self.READING_CACHE_DIR)
    self:createDir(self.DOWNLOAD_CACHE_DIR)
    self:createDir(self.DATA_CACHE_DIR)
    self:createDir(self.TEMP_DIR)

    return true
end

-- 创建目录
function Cache:createDir(path)
    if not lfs.attributes(path, "mode") then
        local ok, err = lfs.mkdir(path)
        if not ok then
            logger.err("Cache", "Failed to create directory: " .. path .. ", error: " .. (err or "unknown"))
            return false
        end
    end
    return true
end

-- 获取文件大小
function Cache:getFileSize(path)
    local attr = lfs.attributes(path)
    return attr and attr.size or 0
end

-- 获取目录大小
function Cache:getDirSize(path)
    local total_size = 0

    if lfs.attributes(path, "mode") ~= "directory" then
        return 0
    end

    for file in lfs.dir(path) do
        if file ~= "." and file ~= ".." then
            local file_path = path .. "/" .. file
            local mode = lfs.attributes(file_path, "mode")

            if mode == "file" then
                total_size = total_size + self:getFileSize(file_path)
            elseif mode == "directory" then
                total_size = total_size + self:getDirSize(file_path)
            end
        end
    end

    return total_size
end

-- 获取缓存大小
function Cache:getCacheSize()
    return self:getDirSize(self.CACHE_DIR)
end

-- 获取图片缓存大小 (封面 + 图片, 不含阅读按需缓存)
function Cache:getImageCacheSize()
    return self:getDirSize(self.IMAGE_CACHE_DIR)
end

-- 获取封面缓存大小
function Cache:getCoverCacheSize()
    return self:getDirSize(self.COVER_CACHE_DIR)
end

-- 获取阅读页缓存大小 (流式阅读按需下载)
function Cache:getReadingCacheSize()
    return self:getDirSize(self.READING_CACHE_DIR)
end

-- 获取数据缓存大小
function Cache:getDataCacheSize()
    return self:getDirSize(self.DATA_CACHE_DIR)
end

--- 一次遍历算出各子目录占用 (设置页专用)
--
-- 原来"缓存管理"页连着调 5 个 get*Size(), 每个都从 CACHE_DIR 递归扫一遍全树,
-- 而且 getImageCacheSize 会把 covers 再算一遍 —— 一共 5 遍全树扫描。
-- 缓存里阅读页上千时, 打开这个页面就是几千次**同步** lfs.attributes,
-- 全部发生在 UI 线程上。
--
-- 这里只走一遍: 按路径前缀把每个文件的字节数记到对应桶里。
-- covers 嵌在 images 之下, 因此先匹配 covers, 保证 images 桶里不含封面
-- (与设置页的展示口径一致)。
--
-- @return { total, covers, images, reading, downloads, data, temp, others }
function Cache:getSizeBreakdown()
    local out = {
        total = 0, covers = 0, images = 0, reading = 0,
        downloads = 0, data = 0, temp = 0, others = 0,
    }

    local root = self.CACHE_DIR
    if lfs.attributes(root, "mode") ~= "directory" then
        return out
    end

    local prefixes = {
        { prefix = self.COVER_CACHE_DIR .. "/",     key = "covers" },
        { prefix = self.IMAGE_CACHE_DIR .. "/",     key = "images" },
        { prefix = self.READING_CACHE_DIR .. "/",   key = "reading" },
        { prefix = self.DOWNLOAD_CACHE_DIR .. "/",  key = "downloads" },
        { prefix = self.DATA_CACHE_DIR .. "/",      key = "data" },
        { prefix = self.TEMP_DIR .. "/",            key = "temp" },
    }

    local function walk(path)
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                local p = path .. "/" .. name
                local mode = lfs.attributes(p, "mode")
                if mode == "file" then
                    local size = self:getFileSize(p)
                    out.total = out.total + size

                    local bucket = "others"
                    for _i, entry in ipairs(prefixes) do
                        if p:sub(1, #entry.prefix) == entry.prefix then
                            bucket = entry.key
                            break
                        end
                    end
                    out[bucket] = out[bucket] + size
                elseif mode == "directory" then
                    walk(p)
                end
            end
        end
    end

    walk(root)
    return out
end

-- 清除图片缓存 (封面 + 图片 + 流式阅读按需缓存)
function Cache:clearImageCache()
    local size_before = self:getImageCacheSize() + self:getReadingCacheSize()

    -- 删除图片/封面/阅读缓存目录下所有文件
    self:clearDir(self.IMAGE_CACHE_DIR)
    self:clearDir(self.READING_CACHE_DIR)

    -- 重新创建目录
    self:createDir(self.IMAGE_CACHE_DIR)
    self:createDir(self.COVER_CACHE_DIR)
    self:createDir(self.READING_CACHE_DIR)

    return size_before
end

-- 清除数据缓存
function Cache:clearDataCache()
    cache_store = {}
    local size_before = self:getDataCacheSize()

    -- 删除数据缓存目录下所有文件
    self:clearDir(self.DATA_CACHE_DIR)

    -- 重新创建数据缓存目录
    self:createDir(self.DATA_CACHE_DIR)

    return size_before
end

-- 清除所有缓存
function Cache:clearAllCache()
    cache_store = {}
    local before = self:getSizeBreakdown()

    -- 删除缓存目录下所有文件, **但保留 downloads**: 那是用户主动下载的
    -- 离线漫画 (见 util/offline_library.lua), 删掉清单还在, 列表就会指向空目录。
    -- 已下载内容由「已下载」页单独管理。
    for name in lfs.dir(self.CACHE_DIR) do
        if name ~= "." and name ~= ".." and name ~= "downloads" then
            local path = self.CACHE_DIR .. "/" .. name
            local mode = lfs.attributes(path, "mode")
            if mode == "file" then
                os.remove(path)
            elseif mode == "directory" then
                self:clearDir(path)
                lfs.rmdir(path)
            end
        end
    end

    -- 重新初始化缓存目录
    self:init()

    local after = self:getSizeBreakdown()
    -- Downloads are persistent content. Their bytes must never be reported as
    -- cleared, including when an unrelated download is still growing.
    return math.max(0,(before.total-before.downloads)-(after.total-after.downloads))
end

-- 清除目录下所有文件和子目录
function Cache:clearDir(path)
    if lfs.attributes(path, "mode") ~= "directory" then
        return
    end

    for file in lfs.dir(path) do
        if file ~= "." and file ~= ".." then
            local file_path = path .. "/" .. file
            local mode = lfs.attributes(file_path, "mode")

            if mode == "file" then
                os.remove(file_path)
            elseif mode == "directory" then
                self:clearDir(file_path)
                lfs.rmdir(file_path)
            end
        end
    end
end

-- 缓存数据
--
-- 内存缓存是"只增不减"的: 过期只在**再次读同一个 key** 时才顺手删掉, 没人再读的
-- 条目会一直留着。缓存的是整页漫画列表 (每页 20~40 个表), 浏览一晚上能攒到几 MB,
-- 而设备可用内存只有 ~130MB (已经因为 OOM 被 SIGKILL 过)。
-- 这里做机会式清理: 条目数超过上限就先清过期, 仍超就按"最快要过期"淘汰最早的。
local CACHE_STORE_MAX = 200

function Cache:cacheData(key, data, expiry)
    if not key then
        return false
    end

    cache_store[key] = {
        data = data,
        expiry = expiry or (os.time() + 3600) -- 默认1小时过期
    }

    local count = 0
    for _ in pairs(cache_store) do count = count + 1 end
    if count > CACHE_STORE_MAX then
        self:clearExpired()

        count = 0
        for _ in pairs(cache_store) do count = count + 1 end
        if count > CACHE_STORE_MAX then
            local entries = {}
            for k, entry in pairs(cache_store) do
                entries[#entries + 1] = { key = k, expiry = entry.expiry or 0 }
            end
            table.sort(entries, function(a, b) return a.expiry < b.expiry end)
            for i = 1, count - CACHE_STORE_MAX do
                cache_store[entries[i].key] = nil
            end
            if logger.enabled then logger.info("Picayomi Cache: 内存缓存超出 " .. CACHE_STORE_MAX ..
                " 条, 已淘汰最早过期的 " .. (count - CACHE_STORE_MAX) .. " 条") end
        end
    end

    return true
end

-- 获取缓存数据
function Cache:getData(key)
    if not key or not cache_store[key] then
        return nil
    end

    local cache_entry = cache_store[key]

    -- 检查是否过期
    if cache_entry.expiry and cache_entry.expiry < os.time() then
        -- 已过期，删除并返回nil
        cache_store[key] = nil
        return nil
    end

    return cache_entry.data
end

-- 清除指定缓存
function Cache:clear(key)
    if key then
        cache_store[key] = nil
        return true
    end

    -- 如果没有指定key，清除所有缓存
    cache_store = {}
    return true
end

-- 按模式清除缓存 (前缀匹配)
function Cache:clearPattern(pattern)
    local cleared = 0
    for key, _ in pairs(cache_store) do
        if key:match(pattern) or key:sub(1, #pattern) == pattern then
            cache_store[key] = nil
            cleared = cleared + 1
        end
    end
    if cleared > 0 then
        if logger.enabled then logger.info("Picayomi Cache: 按模式 " .. pattern .. " 清除了 " .. cleared .. " 个缓存") end
    end
    return cleared
end

-- 清除过期缓存
function Cache:clearExpired()
    local now = os.time()
    local cleared = 0

    for key, entry in pairs(cache_store) do
        if entry.expiry and entry.expiry < now then
            cache_store[key] = nil
            cleared = cleared + 1
        end
    end

    if logger.enabled then logger.info("Picayomi Cache: 已清除", cleared, "个过期缓存") end
    return cleared
end

-- 获取缓存项数量
function Cache:getCount()
    local count = 0

    for _ in pairs(cache_store) do
        count = count + 1
    end

    return count
end

-- 生成缓存文件名
-- 注意: KOReader 的 ffi/sha2.md5() 直接返回十六进制字符串, 不需要再转码;
-- 之前这里 require("basexx") 会直接报错 (KOReader 并不带 basexx 模块)。
function Cache:generateFilename(input)
    local md5 = require("ffi/sha2").md5
    return md5(tostring(input))
end

-- 缓存目录的清理见 network/download_manager.lua:
--   cleanCache        按容量清理封面/图片/阅读页/数据/临时文件，不含持久下载
--   trimReadingCache  按话裁剪阅读页 (当前话永不裁剪)
--   maybeCleanCache   长会话里的总量检查 (靠下载上报的字节数增量触发, 不扫盘)
--
-- 这里曾经有一份 Cache:checkAndCleanCache / cleanOldestCache / collectFilesInfo,
-- 但它的唯一调用者是同样没人用的 Cache:cacheImage —— 也就是说 max_cache_size
-- 这条设置**从来没有生效过** (改设置、缓存涨到几百 MB 也没有任何反应)。
-- 三处一起删掉, 只留真正会被调到的那一份实现。

-- 初始化缓存
Cache:init()

return Cache
