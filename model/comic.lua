local config = require("util.config")
local cache = require("util.cache")
local logger = require("util.logger")
local JN = require("util.json_null")
local _ = require("gettext")

local ComicModel = {}

--- 把(可能带"JSON 对象"标记的)表转成普通 Lua 数组
--
-- **踩过的坑**: `rapidjson.decode("{}")` 返回的表带 metatable, 被标记为"JSON 对象"。
-- 对这种表 `table.insert` 之后 `#t` 会变成 1, 但 `json.encode(t)` **仍然输出 `{}`** ——
-- 新数据被静默丢弃。
-- 后果: 只要 history 曾经被写成空对象 `{}` (例如点过"清空"), 之后就**再也写不进**
-- 任何记录, 表现为"浏览历史永远是空的 / 看过不记录"。
-- 因此读出来必须先重建一个**普通数组**, 再修改与写回。
local function as_array(t)
    local out = {}
    if type(t) == "table" then
        for _i, v in ipairs(t) do
            table.insert(out, v)
        end
    end
    return out
end

-- 历史记录按漫画源隔离
-- --------------------
-- 记录里带 `source` 字段 (源的 identifier), 读取/删除都只看当前源的记录 ——
-- 否则各源的 id 命名空间互不相干却混在一张表里, 切源后会在"阅读历史"里看到
-- 别的源的条目, 甚至把 A 源读过的进度当成 B 源同一 id 的进度。

--- 当前源 identifier (历史记录归属用)
local function currentSourceId()
    local ok, reg = pcall(require, "source.registry")
    if ok and reg and reg.getCurrentId then
        local id = reg:getCurrentId()
        if id then return id end
    end
    return nil
end

--- 读出全部历史 (所有源), 普通数组, 按时间倒序
local function readAllHistory()
    local history = as_array(require("util.config"):get("history"))
    table.sort(history, function(a, b)
        return (tonumber(a and a.time) or 0) > (tonumber(b and b.time) or 0)
    end)
    return history
end

--- 保存历史记录
-- @param source_id 可选: 缺省取当前源 (见 currentSourceId)
-- @param progress  可选: { page = 当前页码, pages = 本话总页数 } —— 历史页据此显示
--        "读到 第N话 · 第3/20页"。不传时: 同一话保留已有页码, 换话则清掉。
function ComicModel:saveHistory(comic_id, title, episode, source_id, progress)
    if not comic_id or not title then
        return false
    end
    source_id = source_id or currentSourceId()

    -- 必须在**全部**记录上改: 只拿当前源那一份回写会把别的源的记录抹掉
    local history = readAllHistory()

    local function apply(item)
        item.title = title
        item.time = os.time()
        -- 换话: 旧页码属于上一话, 必须丢掉 —— 否则历史里会出现
        -- "第 3 话 · 第 50/20 页" 这种自相矛盾的记录。
        if tostring(item.episode) ~= tostring(episode) then
            item.page = nil
            item.pages = nil
            item.episode_title = nil
        end
        item.episode = episode
        if progress and type(progress.episode_title) == "string" then
            item.episode_title = progress.episode_title
        end
        if progress then
            if progress.content_type=="novel" then item.content_type="novel" end
            if type(progress.thumb) == "string" and progress.thumb ~= "" then item.thumb = progress.thumb end
            local p = tonumber(progress.page)
            local total = tonumber(progress.pages)
            if p and p >= 1 then item.page = p end
            if total and total >= 1 then item.pages = total end
        end
    end

    -- 查找是否已存在 (同源 + 同 id 才算同一条)
    local exists = false
    for _i, item in ipairs(history) do
        if item.id == comic_id and item.source == source_id then
            apply(item)
            exists = true
            break
        end
    end

    -- 添加新记录
    if not exists then
        local item = {
            id = comic_id,
            source = source_id,
        }
        apply(item)
        table.insert(history, item)
    end

    table.sort(history, function(a, b)
        return (tonumber(a and a.time) or 0) > (tonumber(b and b.time) or 0)
    end)

    -- Reading progress is user data, never evicted as a cache or by list length.
    return require("util.config"):save("history", history)
end

-- 补齐旧历史的封面地址，不改变阅读时间、顺序或进度，也不复活已删除记录。
function ComicModel:updateHistoryCover(comic_id, source_id, thumb)
    if type(thumb) ~= "string" or thumb == "" then return false end
    local history = as_array(require("util.config"):get("history"))
    for _, item in ipairs(history) do
        if item.id == comic_id and item.source == source_id then
            if item.thumb == thumb then return true end
            item.thumb = thumb
            return require("util.config"):save("history", history)
        end
    end
    return false
end

-- ============================================================================
-- 单本漫画的阅读版式 (竖屏 / 条漫 / 横屏)
-- ============================================================================
-- 为什么**不**放进 history 数组:
--   用户可以在「浏览历史」里一键清空。把"这本书怎么读"
--   这种设置挂在会被淘汰/清空的列表上, 表现为"清了历史之后这本书又变回自动" ——
--   用户没有任何线索。放在 config 的独立小表里: 同样持久化, 但不受列表策略影响。
--   (数据量: 每条 30 字节左右, 与阅读进度同量级。)
local VIEW_KEY = "comic_view_modes"

local function view_key(comic_id, source_id)
    return tostring(source_id or currentSourceId() or "") .. ":" .. tostring(comic_id)
end

--- 读某一本漫画的阅读版式 (nil = 没设过 -> 全局策略/自动判定)
function ComicModel:getViewMode(comic_id, source_id)
    if not comic_id then return nil end
    local map = config:get(VIEW_KEY)
    if type(map) ~= "table" then return nil end
    local v = map[view_key(comic_id, source_id)]
    if v == "page" or v == "scroll" or v == "landscape" then return v end
    return nil
end

--- 写某一本漫画的阅读版式
function ComicModel:setViewMode(comic_id, source_id, mode)
    if not comic_id then return false end
    if mode ~= "page" and mode ~= "scroll" and mode ~= "landscape" then
        return false
    end
    -- 必须重建普通表再写: 从 JSON 读回来的表带"对象"标记, 直接改完再编码会输出 {}
    -- (与 as_array 的注释同一个坑)
    local raw = config:get(VIEW_KEY)
    local map = {}
    if type(raw) == "table" then
        for k, v in pairs(raw) do map[k] = v end
    end
    map[view_key(comic_id, source_id)] = mode
    config:set(VIEW_KEY, map)
    return true
end

--- 旧数据迁移: 早期版本的历史记录没有 source 字段
--
-- 那些记录**无法事后判断**属于哪个源 (id 命名空间不通用), 只能按"当时只在一个源里
-- 读过"来推断: 首次读取时盖上当前源并落盘。迁移后所有记录都带 source,
-- 这段逻辑不会再有第二次机会执行。
-- @return 是否有记录被改写 (需要落盘)
local function migrateLegacyRecords(history, source_id)
    if not source_id then return false end
    local changed = false
    for _i, item in ipairs(history) do
        if item.source == nil then
            item.source = source_id
            changed = true
        end
    end
    return changed
end

--- 获取历史记录 (默认只含指定源)
-- @param source_id 可选: 缺省取当前源; 传 "*" 表示不限源 (全部源的记录)
function ComicModel:getHistory(source_id)
    local history = readAllHistory()

    if source_id == nil then source_id = currentSourceId() end

    if source_id ~= "*" and migrateLegacyRecords(history, source_id) then
        require("util.config"):save("history", history)
    end

    if source_id == "*" then
        return history
    end

    local out = {}
    for _i, item in ipairs(history) do
        if item.source == source_id then
            table.insert(out, item)
        end
    end
    return out
end

--- 获取特定漫画的历史记录 (必须同源, 否则不同源的同名 id 会互相串)
function ComicModel:getHistoryItem(comic_id, source_id)
    if not comic_id then
        return nil
    end

    -- 走 getHistory 而不是直接读原始表: 顺带完成旧数据迁移
    local history = self:getHistory(source_id)

    for _i, item in ipairs(history) do
        if item.id == comic_id then
            return item
        end
    end

    return nil
end

--- 删除历史记录
-- @param comic_id  可选: 只删这一条; 缺省则清空该源的全部记录
-- @param source_id 可选: 缺省取当前源
function ComicModel:clearHistory(comic_id, source_id)
    return config:clearHistory(comic_id, source_id)
end

-- 处理漫画数据，统一格式
-- 注意: KOReader 的 rapidjson 把 JSON null 解码为真值 userdata,
-- 因此所有字段都要做类型过滤 (JN), 不能只依赖 `or 默认值`。
function ComicModel:processComicData(comic)
    if not comic then
        return {}
    end

    -- 创建一个新表，避免修改原始数据
    local processed = {}
    if comic._list_display then
        local Contract=require("source.contract")
        local ok,spec=pcall(Contract.listDisplay,comic._list_display)
        if ok then
            processed._list_display=spec
        end
    end

    if comic.metadata then
        local valid,metadata=pcall(require("source.contract").metadata,comic.metadata)
        if valid then processed.metadata=metadata end
    end

    -- 复制基本字段
    local id = JN.str(comic._id) or JN.str(comic.id) or JN.num(comic._id) or JN.num(comic.id)
    processed._id = id and tostring(id) or ""
    processed.title = JN.str(comic.title) or "未知标题"

    -- 作品编号兜底 (源 B 列表: "JM1483331")。**必须显式复制**: 本函数新建一张表,
    -- 漏一个字段列表上就少一块信息 —— 之前 subtitle 没接, 源 B 卡片第三行整行是空的
    -- (真机反馈: "源 B 的漫画列表还是不显示页数/话数这类")。
    processed.subtitle = JN.str(comic.subtitle) or ""

    -- 页数: 各源字段名不统一 (pagesCount / pages / pages_count / total_photos)。
    -- 历史与收藏里存的是**源原始字段**, 少认一个名字, 卡片那一行就是空的
    -- (真机反馈: "有些显示页数, 有些又不显示")。
    processed.pagesCount = JN.num(comic.pagesCount,
        JN.num(comic.pages, JN.num(comic.pages_count, JN.num(comic.total_photos, 0))))

    -- 处理作者信息
    processed.author = JN.str(comic.author) or (processed._list_display and "" or "未知作者")
    processed.author_text = processed.author

    -- 处理分类信息
    processed.categories = type(comic.categories) == "table" and JN.str_list(comic.categories)
        or (JN.str(comic.categories) and { JN.str(comic.categories) } or {})
    processed.categories_text = table.concat(processed.categories, ", ")

    -- 处理标签信息
    processed.tags = type(comic.tags) == "table" and JN.str_list(comic.tags)
        or (JN.str(comic.tags) and { JN.str(comic.tags) } or {})
    processed.tags_text = table.concat(processed.tags, ", ")

    -- 处理缩略图
    if type(comic.thumb) == "table" then
        local fs = JN.str(comic.thumb.fileServer)
        local path = JN.str(comic.thumb.path)
        processed.thumb = (fs and path) and (fs .. "/" .. path) or ""
    else
        processed.thumb = JN.str(comic.thumb, "")
    end

    -- 处理统计信息
    -- 话数同理: 有 chapters 表的 (源 C 详情 / 离线清单) 也能数出来
    processed.epsCount = JN.num(comic.epsCount, JN.num(comic.eps_count, 0))
    if processed.epsCount <= 0 and type(comic.chapters) == "table" then
        processed.epsCount = #comic.chapters
    end
    processed.likesCount = JN.num(comic.likesCount, JN.num(comic.likes_count, JN.num(comic.totalLikes, 0)))
    processed.viewsCount = JN.num(comic.viewsCount, JN.num(comic.views_count, JN.num(comic.totalViews, 0)))
    processed.commentsCount = JN.num(comic.commentsCount, JN.num(comic.comments_count, 0))

    -- 处理状态/简介/汉化组等详情页字段
    processed.finished = JN.bool(comic.finished)
    processed.description = JN.str(comic.description, "")
    processed.chineseTeam = JN.str(comic.chineseTeam) or JN.str(comic.chinese_team) or ""
    processed.isFavourite = JN.bool(comic.isFavourite)

    -- 处理时间信息
    processed.updated_at = JN.str(comic.updated_at) or JN.str(comic.updatedAt) or ""
    processed.created_at = JN.str(comic.created_at) or JN.str(comic.createdAt) or ""

    -- 格式化时间显示
    if processed.updated_at ~= "" then
        -- 简单处理，只显示日期部分
        processed.update_time = processed.updated_at:match("^(%d%d%d%d%-%d%d%-%d%d)")
    end
    if not processed.update_time then
        -- 兼容直接给时间戳/字符串的源 (如 源 B 的 update_at)
        processed.update_time = JN.str(comic.update_time) or JN.num(comic.update_time)
    end

    return processed
end

-- 从列表中查找指定ID的漫画
function ComicModel:findComicById(comics, comic_id)
    if not comics or not comic_id then
        return nil
    end

    for _, comic in ipairs(comics) do
        if comic._id == comic_id then
            return comic
        end
    end

    return nil
end

-- 缓存处理后的漫画数据
function ComicModel:cacheProcessedComic(comic_id, comic)
    if not comic_id or not comic then
        return false
    end

    local cache_key = "processed_comic_" .. comic_id
    return cache:cacheData(cache_key, comic, os.time() + 3600) -- 1小时缓存
end

-- 获取缓存的处理后漫画数据
function ComicModel:getCachedProcessedComic(comic_id)
    if not comic_id then
        return nil
    end

    local cache_key = "processed_comic_" .. comic_id
    return cache:getData(cache_key)
end

-- 获取排序选项
function ComicModel:getSortOptions()
    return {
        { text = "新到旧", value = "ua" },
        { text = "旧到新", value = "dd" },
        { text = "最多爱心", value = "ld" },
        { text = "最多绅士指名", value = "vd" }
    }
end

-- 获取默认分类
function ComicModel:getDefaultCategories()
    return {
        { text = "全彩", value = "5821a9a5a3b6c05c20f79b39" },
        { text = "長篇", value = "5821a9caa3b6c05c20f79b3b" },
        { text = "同人", value = "5821a9f0a3b6c05c20f79b3c" },
        { text = "短篇", value = "5821aa32a3b6c05c20f79b3e" },
        { text = "圓神", value = "5821aa60a3b6c05c20f79b3f" },
        { text = "韓漫", value = "5821aa7fa3b6c05c20f79b40" },
        { text = "日文", value = "62ee7a4cac4b2c4c13b1b2b2" },
        { text = "性轉換", value = "5821aaa3a3b6c05c20f79b41" },
        { text = "CG雜圖", value = "5821aac9a3b6c05c20f79b42" },
        { text = "重口地帶", value = "5821ab9fa3b6c05c20f79b45" }
    }
end

return ComicModel
