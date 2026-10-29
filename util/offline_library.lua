-- util/offline_library.lua
-- 离线下载库: 记住"哪些漫画的哪些章节已经整章下载完", 以及下载进度。
--
-- 为什么需要单独一份清单:
--   磁盘上的图片文件名只有页码 (0001.jpg ...), 单看文件系统不知道它属于哪部漫画、
--   章节标题是什么、整章有没有下完。阅读页的缓存目录 (cache/reading) 会被
--   trimReadingCache 按"最近若干话"裁剪, 不能用来存用户主动下载的内容 ——
--   用户点了下载, 下次打开却没了, 那就不叫下载。
--
-- 存储:
--   * 图片: <cache>/downloads/<source>/<comic>/<order>/0001.jpg ...
--   * 清单: <data>/picayomi/offline_library.json
--   清单不放缓存目录: 清缓存不该把"我下载了什么"这件事也清掉 (图片是否还在
--   由 isChapterComplete 现查文件系统, 清单与磁盘不一致时以磁盘为准)。
--
-- 线程模型: KOReader 的 Lua 是单线程; 本模块只做内存表操作 + 立即落盘,
-- 不联网、不碰 UI, 因此可以被下载队列与列表页同时调用。
local logger = require("util.logger")
local lfs = require("libs/libkoreader-lfs")
local json = require("rapidjson")
local Cache = require("util.cache")

local M = {}

local VERSION = 2 -- additive page processing manifests; v1 metadata remains readable
-- 逐页进度最多每 3 秒落盘一次: 清单是整份读写的, 一页一次会在 e-ink 存储上
-- 造成可观的写放大 (章完成/状态迁移仍会强制立即落盘)。
local SAVE_INTERVAL = 3

local function to_abs(path)
    if not path or path:sub(1, 1) == "/" then return path end
    local cwd = lfs.currentdir() or "."
    return cwd .. "/" .. path:gsub("^%./", "")
end

M.DATA_FILE = to_abs(Cache.BASE_DIR) .. "/offline_library.json"

local function safe_name(value)
    value = tostring(value or "unknown")
    return (value:gsub("[^%w%._%-]", "_"))
end

local function chapter_key(order)
    return tostring(order)
end

--- 章节图片目录 (与阅读页缓存同一套命名: 第 n 页 = <dir>/%04d.<ext>)
function M.chapterDir(source_id, comic_id, order)
    return to_abs(Cache.DOWNLOAD_CACHE_DIR) .. "/" .. safe_name(source_id)
        .. "/" .. require("source.identity").diskPart(source_id,comic_id)
        .. "/" .. require("source.identity").diskPart(source_id,order)
end

--- 漫画的下载根目录 (封面等附属文件放这里)
function M.comicDir(source_id, comic_id)
    return to_abs(Cache.DOWNLOAD_CACHE_DIR) .. "/" .. safe_name(source_id)
        .. "/" .. require("source.identity").diskPart(source_id,comic_id)
end

local function dir_exists(path)
    return lfs.attributes(path, "mode") == "directory"
end

--- 递归创建目录 (只建到叶子)
local function ensure_dir(path)
    if dir_exists(path) then return true end
    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= path and not dir_exists(parent) then
        ensure_dir(parent)
    end
    return lfs.mkdir(path) and true or false
end
M.ensureDir = ensure_dir

-- ============================================================================
-- 持久化
-- ============================================================================

local loaded = nil
local last_save = 0

local function empty_data()
    return { version = VERSION, comics = {} }
end

--- 读清单。坏文件当作空库 (不让一条损坏的 JSON 把整个功能卡死)。
function M.load(force)
    if loaded and not force then return loaded end
    M.load_error=nil
    local f = io.open(M.DATA_FILE, "r")
    if not f then
        loaded = empty_data()
        return loaded
    end
    local text = f:read("*a")
    f:close()
    local ok, data = pcall(json.decode, text or "")
    if not ok or type(data) ~= "table" or type(data.comics) ~= "table"
        or type(data.version)~="number" or data.version>VERSION then
        logger.warn("Picayomi OfflineLibrary: 清单损坏, 当作空库: " .. tostring(data))
        loaded = empty_data()
        M.load_error="离线清单损坏或版本不兼容；原文件已保留"
        return loaded
    end
    if data.version==1 then
        -- Backup before the first additive write. Never overwrite a prior backup.
        local backup=M.DATA_FILE..".v1.backup"
        local existing=io.open(backup,"rb")
        if existing then existing:close()
        else
            local f=io.open(backup,"wb")
            if not f then M.load_error="无法备份离线清单" else f:write(text); f:close() end
        end
    end
    data.version = VERSION
    -- rapidjson 会把 {"1": ...} 这种纯数字键解码成**数组**, 于是
    -- chapters["1"] 变成 nil (只有 chapters[1] 有值)。清单的键语义是"章节号",
    -- 必须统一成字符串 —— 每次读盘重建一遍映射, 否则重启后进度全部丢失。
    for _sid, bucket in pairs(data.comics) do
        if type(bucket) == "table" then
            for _cid, entry in pairs(bucket) do
                if type(entry) == "table" then
                    local chapters, targets = {}, {}
                    for k, v in pairs(entry.chapters or {}) do chapters[tostring(k)] = v end
                    for k, v in pairs(entry.targets or {}) do targets[tostring(k)] = v end
                    entry.chapters = chapters
                    entry.targets = targets
                    entry.comic = type(entry.comic) == "table" and entry.comic or {}
                    if require("source.identity").legacyRenderRequired(_sid) then
                        for _,ch in pairs(chapters) do
                            if ch.state=="done" and not ch.page_manifest then
                                ch.state="partial";ch.error="旧下载缺少图片处理信息，请重新下载此章节"
                            end
                        end
                    end
                end
            end
        end
    end
    loaded = data
    return loaded
end

--- 落盘。非强制时最多每秒一次 —— 每下完一页都整份写盘会磨损闪存。
function M.save(force)
    local data = loaded
    if not data or M.load_error then return false end
    local now = os.time()
    if not force and last_save > 0 and now - last_save < SAVE_INTERVAL then
        return true
    end
    -- 失败后必须允许立即重试，包括成功节流窗口内的强制保存失败。
    -- 只有原子替换成功才能开始下一轮节流。
    last_save = 0

    ensure_dir(M.DATA_FILE:match("^(.*)/[^/]+$") or ".")
    local text = json.encode(data)
    local tmp = M.DATA_FILE .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then
        logger.warn("Picayomi OfflineLibrary: 无法写入 " .. tmp)
        return false
    end
    local written=f:write(text)
    local closed=f:close()
    if not written or not closed then os.remove(tmp);return false end
    -- 同目录 rename 在 POSIX 上是原子替换, 不需要先删旧文件 ——
    -- 先删会留下"清单暂时不存在"的窗口 (此刻崩溃就丢光历史)。
    local ok = os.rename(tmp, M.DATA_FILE)
    if not ok then
        logger.warn("Picayomi OfflineLibrary: 清单改名失败 " .. tostring(tmp))
    else
        last_save = now
    end
    return ok
end

--- 测试/换账号用: 丢弃内存状态, 下次 load 重新读盘
function M.reset()
    loaded = nil
    M.load_error=nil
    last_save = 0
end

local function entry_of(source_id, comic_id, create)
    local data = M.load()
    local sid = tostring(source_id or "unknown")
    local cid = tostring(comic_id or "")
    data.comics[sid] = data.comics[sid] or {}
    local bucket = data.comics[sid]
    local entry = bucket[cid]
    if not entry and create then
        entry = {
            source_id = sid,
            comic_id = cid,
            comic = {},
            chapters = {},
            targets = {},
            state = "none",
            added_at = os.time(),
            updated_at = os.time(),
        }
        bucket[cid] = entry
    end
    return entry
end

-- ============================================================================
-- 写入
-- ============================================================================

-- 卡片 / 详情页真正会读的字段。与 util/local_favorites.lua 同一套口径:
-- 清单是整份读写的, 不把源的原始响应整个塞进来。
local KEEP_FIELDS = {
    "content_type", "text_filters",
    "_id", "title", "author", "author_text",
    "categories", "categories_text", "tags", "tags_text",
    "thumb", "description", "epsCount", "pagesCount", "likesCount",
    "commentsCount", "viewsCount", "finished", "update_time",
}

local function trim_comic(comic)
    local out = {}
    for _i, name in ipairs(KEEP_FIELDS) do
        local v = comic[name]
        -- JSON null 在 KOReader 里是真值 userdata; rapidjson.encode 处理不了,
        -- 会让整份清单写盘失败 (失败是静默的: 下载照跑, 重启后记录没了)。
        if v ~= nil and type(v) ~= "userdata" then out[name] = v end
    end
    local Contract=require("source.contract")
    local valid,display=pcall(Contract.listDisplay,comic._list_display)
    if valid and display then
        out._list_display=display
    end
    local ok,metadata=pcall(Contract.metadata,comic.metadata)
    if ok then out.metadata=metadata end
    out._id = tostring(comic._id or "")
    return out
end

--- 开始一批章节的下载 (写清单 + 把状态置为 downloading)
-- @param chapters  {{order=, title=, pages=}, ...}
function M.begin(source_id, comic, chapters)
    local entry = entry_of(source_id, comic and comic._id, true)
    if not entry then return nil end

    entry.comic = trim_comic(comic or {})
    entry.state = "downloading"
    entry.updated_at = os.time()
    entry.targets = entry.targets or {}
    entry.chapters = entry.chapters or {}

    for _i, ch in ipairs(chapters or {}) do
        local key = chapter_key(ch.order)
        entry.targets[key] = {
            id=ch._id or ch.id,
            order = ch.order,
            sort_index = ch.sort_index,
            title = ch.title,
            pages = tonumber(ch.pages),
        }
        local prev = entry.chapters[key]
        entry.chapters[key] = {
            id=ch._id or ch.id or (prev and prev.id),
            order = ch.order,
            title = ch.title or (prev and prev.title),
            sort_index = ch.sort_index or (prev and prev.sort_index),
            state = (prev and prev.state == "done") and "done" or "queued",
            done = (prev and prev.state == "done") and (prev.done or 0) or 0,
            total = tonumber(ch.pages) or (prev and prev.total) or 0,
            bytes = (prev and prev.state == "done") and (prev.bytes or 0) or 0,
            page_manifest = prev and prev.page_manifest,
            document = prev and prev.document,
            updated_at = os.time(),
        }
    end

    M.save(true)
    return entry
end

--- 更新某一章的状态/进度 (增量字段)
function M.updateChapter(source_id, comic_id, order, patch, opts)
    local entry = entry_of(source_id, comic_id, true)
    if not entry then return nil end
    entry.chapters = entry.chapters or {}
    local key = chapter_key(order)
    local ch = entry.chapters[key] or { order = order, done = 0, total = 0 }
    for k, v in pairs(patch or {}) do ch[k] = v end
    ch.updated_at = os.time()
    entry.chapters[key] = ch
    entry.updated_at = os.time()
    entry.state = M.deriveState(entry)
    -- 状态迁移 (queued -> done/partial/failed) 必须立刻落盘: 那是"重启后还能不能
    -- 认出这一章"的依据。只有下载中途的逐页 done 计数可以按秒节流 —— 一页一次
    -- 整份写盘会磨损闪存。
    local force = (opts and opts.force) or (patch and patch.state ~= nil
        and patch.state ~= "downloading")
    local saved=M.save(force)
    return ch,saved
end

-- Stop a whole queue with one atomic save; retain completed files and counters.
function M.stopChapters(jobs,reason)
    local touched={}
    for _,job in ipairs(jobs)do
        local entry=entry_of(job.source_id,job.comic_id,false)
        local ch=entry and entry.chapters and entry.chapters[chapter_key(job.order)]
        if ch and ch.state~="done"then
            ch.state="partial";ch.error=reason or "已停止下载";ch.updated_at=os.time()
            touched[entry]=true
        end
    end
    local changed=false
    for entry in pairs(touched)do
        entry.state=M.deriveState(entry);entry.updated_at=os.time();changed=true
    end
    return not changed or M.save(true)
end

-- Persist only replayable processing data, never request headers or signed URLs.
-- This is committed before downloading the first page, so interrupted jobs and
-- completed jobs share the same replay semantics.
function M.setPageManifest(source_id,comic_id,order,source,images)
    local entry=entry_of(source_id,comic_id,false)
    local chapter=entry and (entry.chapters or {})[chapter_key(order)]
    local previous=chapter and chapter.page_manifest
    local items,reuse={},{}
    for i,page in ipairs(images) do
        local processing=page.processing or {}
        local key=require("source.page_manifest").fileKey(page)
        local old=previous and previous.items and previous.items[i]
        local ready=old and old.content_key==key and old.ready==true and type(old.file)=="string"
        reuse[i]=ready==true
        items[i]={index=i,context=require("source.contract").context(page.context),processing={
            file=require("source.processors").persist(processing.file),
            render=require("source.processors").persist(processing.render),
        },content_key=key,ready=ready==true,file=ready and old.file or nil}
    end
    local manifest={format=1,source_digest=source._extension_digest,items=items}
    local _,saved=M.updateChapter(source_id,comic_id,order,{page_manifest=manifest},{force=true})
    assert(saved and not M.load_error,"离线清单无法写入")
    return manifest,reuse
end

function M.markPageReady(source_id,comic_id,order,page,path)
    local entry=entry_of(source_id,comic_id,false)
    local chapter=entry and (entry.chapters or {})[chapter_key(order)]
    local item=chapter and chapter.page_manifest and chapter.page_manifest.items[page]
    local name=type(path)=="string" and path:match("([^/]+)$")
    assert(item and name and tonumber(name:match("^(%d+)%.[%w]+$"))==page,"离线页面文件名无效")
    item.ready,item.file=true,name
    M.save(false)
end

function M.reusablePage(source_id,comic_id,order,page)
    local entry=entry_of(source_id,comic_id,false)
    local chapter=entry and (entry.chapters or {})[chapter_key(order)]
    local item=chapter and chapter.page_manifest and chapter.page_manifest.items[page]
    if not (item and item.ready and type(item.file)=="string" and tonumber(item.file:match("^(%d+)%.[%w]+$"))==page) then return nil end
    local path=M.chapterDir(source_id,comic_id,order).."/"..item.file
    if require("network.download_manager").isValidImageFile(path) then return path end
end

function M.packageReferences()
    local data=M.load()
    if M.load_error then return nil end
    local refs={}
    for sid,bucket in pairs(data.comics) do
        for _,entry in pairs(bucket) do
            for _,ch in pairs(entry.chapters or {}) do
                for _,page in ipairs(ch.page_manifest and ch.page_manifest.items or {}) do
                    for _,desc in pairs(page.processing or {}) do
                        if type(desc)=="table" and type(desc.digest)=="string" then
                            refs[sid]=refs[sid] or {}; refs[sid][desc.digest]=true
                        end
                    end
                end
            end
        end
    end
    return refs
end

--- 从"开始下载"到"下完"应记的元信息
function M.setTargetsDone(source_id, comic_id)
    local entry = entry_of(source_id, comic_id, false)
    if not entry then return end
    entry.state = M.deriveState(entry)
    entry.updated_at = os.time()
    M.save(true)
end

-- ============================================================================
-- 读取
-- ============================================================================

--- 目标章节列表 (按 order 升序)
local function target_list(entry)
    local out = {}
    for _k, t in pairs(entry.targets or {}) do out[#out + 1] = t end
    table.sort(out, function(a, b)
        local sa, sb = tonumber(a.sort_index), tonumber(b.sort_index)
        if sa and sb and sa ~= sb then return sa < sb end
        local na, nb = tonumber(a.order), tonumber(b.order)
        if na and nb then return na < nb end
        return tostring(a.order) < tostring(b.order)
    end)
    return out
end
M.targetList = target_list

--- 由章节状态推导整部漫画的状态
function M.deriveState(entry)
    local targets = entry.targets or {}
    local total, done, active = 0, 0, false
    for _k, t in pairs(targets) do
        total = total + 1
        local ch = (entry.chapters or {})[chapter_key(t.order)]
        local state = ch and ch.state
        if state == "done" then
            done = done + 1
        elseif state == "queued" or state == "preparing" or state == "downloading" then
            active = true
        end
    end
    if total == 0 then return "none" end
    if active then return "downloading" end
    if done >= total then return "done" end
    if done > 0 then return "partial" end
    -- 一页都没下成, 但有章节已经被尝试过 (partial/failed): 这仍是"部分/失败",
    -- 不是"从没开始"。列表要显示"部分未完成", 而不是像新条目一样空白。
    for _k, t in pairs(targets) do
        local ch = (entry.chapters or {})[chapter_key(t.order)]
        if ch and (ch.state == "partial" or ch.state == "failed") then
            return "partial"
        end
    end
    return "failed"
end

--- 整部漫画的整体进度 (0..1)
--
-- 章内按页计, 章间按章计 —— 只按章会让"正在下第 1 章"的进度条一动不动。
function M.progress(entry)
    local targets = entry.targets or {}
    local total_w, got = 0, 0
    for _k, t in pairs(targets) do
        total_w = total_w + 1
        local ch = (entry.chapters or {})[chapter_key(t.order)] or {}
        if ch.state == "done" then
            got = got + 1
        else
            local pages = tonumber(ch.total) or tonumber(t.pages) or 0
            local done = tonumber(ch.done) or 0
            if pages > 0 then
                got = got + math.min(1, done / pages)
            end
        end
    end
    if total_w == 0 then return 0 end
    return math.max(0, math.min(1, got / total_w))
end

local function chapter_stats(entry)
    local targets = entry.targets or {}
    local total,done,failed,pending,retryable=0,0,0,0,0
    for _k, t in pairs(targets) do
        total = total + 1
        local ch = (entry.chapters or {})[chapter_key(t.order)]
        if ch and ch.state=="done"then done=done+1
        elseif ch and(ch.state=="queued"or ch.state=="preparing"or ch.state=="downloading")then pending=pending+1
        else retryable=retryable+1;if ch and ch.state=="failed"then failed=failed+1 end end
    end
    return done,total,failed,pending,retryable
end

--- 磁盘上这一章的图片 (按页码排序); 没有则返回空表
-- @return images, dir
function M.localImages(source_id, comic_id, order)
    local dir = M.chapterDir(source_id, comic_id, order)
    local found = {}
    if not dir_exists(dir) then return {}, dir end
    for name in lfs.dir(dir) do
        local n = tonumber(name:match("^(%d+)%.[%w]+$"))
        if n then
            local path = dir .. "/" .. name
            if lfs.attributes(path, "mode") == "file" then
                found[#found + 1] = { page = n, path = path }
            end
        end
    end
    table.sort(found, function(a, b) return a.page < b.page end)
    local images = {}
    local entry=entry_of(source_id,comic_id,false)
    local chapter=entry and (entry.chapters or {})[chapter_key(order)]
    local manifest=chapter and chapter.page_manifest
    for _i, item in ipairs(found) do
        local saved=manifest and manifest.items and manifest.items[item.page]
        if not manifest or saved and saved.ready and saved.file==item.path:match("([^/]+)$") then
            images[#images + 1] = { url = item.path, local_path = item.path, page = item.page,index=item.page,
            resource={kind="local"},processing=saved and saved.processing or {},context=saved and saved.context,
            processing_error=not saved and require("source.identity").legacyRenderRequired(source_id)
                and "旧下载缺少图片处理信息，请重新下载此章节" or nil }
        end
    end
    return images, dir
end

--- 清单里这一章是否标记为 done (**不查磁盘**)
--
-- 选择页要一次标出几十个章节; 逐章扫目录 (每章一次 lfs.dir + 每条 stat) 会
-- 在打开页面的那一下把主线程占住。这里只看清单: downloads 目录不会被自动清理
-- (见 F-DL-007), 所以清单说 done 基本等价于文件在; 真正打开阅读前
-- (api/comic) 仍会用 isChapterComplete 做磁盘复核。
function M.chapterMarkedDone(source_id, comic_id, order)
    local entry = entry_of(source_id, comic_id, false)
    if not entry then return false end
    local ch = (entry.chapters or {})[chapter_key(order)]
    return ch ~= nil and ch.state == "done"
end

--- 这一章是否真的完整可用 (清单说 done + 磁盘页数够)
function M.isChapterComplete(source_id, comic_id, order)
    local entry = entry_of(source_id, comic_id, false)
    if not entry then return false end
    local ch = (entry.chapters or {})[chapter_key(order)]
    if not ch or ch.state ~= "done" then return false end
    if entry.comic and entry.comic.content_type=="novel" then
        if type(ch.document)~="table" then return false end
        local ok,doc=pcall(require("novel.document").load,Cache.BASE_DIR.."/novels/downloads",ch.document.key,ch.document.generation)
        return ok and doc~=nil
    end
    local total = tonumber(ch.total) or 0
    if total <= 0 then return false end
    local images = M.localImages(source_id, comic_id, order)
    if #images~=total then return false end
    for i,image in ipairs(images) do if image.page~=i then return false end end
    return true
end

--- 已完整下载的章节 (详情页离线模式 / 已下载列表用)
-- @return { {order=, title=, pages=}, ... } 按 order 升序
function M.completedChapters(source_id, comic_id, options)
    local entry = entry_of(source_id, comic_id, false)
    if not entry then return {} end
    local out = {}
    for _k, ch in pairs(entry.chapters or {}) do
        if ch.state == "done" and (options and options.verify==false or M.isChapterComplete(source_id, comic_id, ch.order)) then
            out[#out + 1] = { id=ch.id, order = ch.order, title = ch.title, pages = ch.total, sort_index = ch.sort_index }
        end
    end
    table.sort(out, function(a, b)
        local sa, sb = tonumber(a.sort_index), tonumber(b.sort_index)
        if sa and sb and sa ~= sb then return sa < sb end
        local na, nb = tonumber(a.order), tonumber(b.order)
        if na and nb then return na < nb end
        return tostring(a.order) < tostring(b.order)
    end)
    return out
end

--- 失败/未完成的章节 (供「已下载」页重新下载)
-- 只返回 failed/partial 的目标章节; queued/downloading 说明队列还在跑, 不重复入队。
-- @return { {order=, title=, pages=}, ... } 按 order 升序
function M.failedChapters(source_id, comic_id)
    local entry = entry_of(source_id, comic_id, false)
    if not entry then return {} end
    local out = {}
    for _k, t in pairs(entry.targets or {}) do
        local ch = (entry.chapters or {})[chapter_key(t.order)]
        if ch and ch.state == "done" then
            -- 已完成
        elseif ch and (ch.state == "queued" or ch.state == "preparing"
            or ch.state == "downloading") then
            -- 队列还在处理, 不重复
        else
            out[#out + 1] = {
                id=t.id or (ch and ch.id),
                order = t.order,
                sort_index = t.sort_index,
                title = (ch and ch.title) or t.title,
                pages = (ch and ch.total) or t.pages,
                error = ch and ch.error,
            }
        end
    end
    table.sort(out, function(a, b)
        local sa, sb = tonumber(a.sort_index), tonumber(b.sort_index)
        if sa and sb and sa ~= sb then return sa < sb end
        local na, nb = tonumber(a.order), tonumber(b.order)
        if na and nb then return na < nb end
        return tostring(a.order) < tostring(b.order)
    end)
    return out
end

--- 已下载章节数 (详情页入口文案用; 不查磁盘, 只看清单)
function M.downloadedChapterCount(source_id, comic_id)
    local entry = entry_of(source_id, comic_id, false)
    if not entry then return 0 end
    local _done, _total = chapter_stats(entry)
    return _done
end

-- Home only needs a bounded selection of metadata. Do not traverse every
-- chapter/target or build progress summaries just to show a few thumbnails.
function M.preview(content_type, limit)
    limit=math.max(0,math.floor(tonumber(limit)or 0))
    if limit==0 then return {}end
    local selected={}
    local function newer(a,b)
        local at,bt=tonumber(a.entry.updated_at)or 0,tonumber(b.entry.updated_at)or 0
        if at~=bt then return at>bt end
        if a.sid~=b.sid then return a.sid<b.sid end
        return a.cid<b.cid
    end
    for sid,bucket in pairs(M.load().comics or {})do
        for cid,entry in pairs(bucket)do
            local kind=entry.comic and entry.comic.content_type=="novel"and "novel"or "comic"
            if kind==content_type then
                local candidate={sid=tostring(sid),cid=tostring(cid),entry=entry}
                if #selected<limit or newer(candidate,selected[#selected])then
                    local index=#selected+1
                    while index>1 and newer(candidate,selected[index-1])do index=index-1 end
                    table.insert(selected,index,candidate)
                    if #selected>limit then table.remove(selected)end
                end
            end
        end
    end
    local result={}
    for _,item in ipairs(selected)do
        local comic={}
        for k,v in pairs(item.entry.comic or {})do comic[k]=v end
        comic._id=item.cid;comic.source_id=item.sid
        comic.download_updated_at=item.entry.updated_at
        result[#result+1]=comic
    end
    return result
end

--- 全部已下载漫画 (跨源), 最新下载的排在最前
-- @return { comic, ... } 每个 comic 带 download_* 字段
function M.list(source_id)
    local data = M.load()
    local out = {}
    for sid, bucket in pairs(data.comics or {}) do
        if not source_id or tostring(sid) == tostring(source_id) then
            for cid, entry in pairs(bucket) do
                local done,total,failed,pending,retryable = chapter_stats(entry)
                local state = M.deriveState(entry)
                local comic = {}
                for k, v in pairs(entry.comic or {}) do comic[k] = v end
                comic._id = tostring(cid)
                comic.source_id = tostring(sid)
                comic.download_state = state
                for _,chapter in pairs(entry.chapters or {}) do
                    if chapter.state=="preparing" then
                        comic.download_preparing=true
                        comic.download_prepare_stage=chapter.prepare_stage
                        comic.download_prepare_current=chapter.prepare_current
                        comic.download_prepare_total=chapter.prepare_total
                        break
                    end
                    if chapter.state=="queued"and(tonumber(chapter.wait_until)or 0)>require("socket").gettime()then
                        comic.download_wait_message=chapter.wait_message
                    end
                end
                comic.download_progress = M.progress(entry)
                comic.download_done = done
                comic.download_total = total
                comic.download_failed=failed;comic.download_pending=pending;comic.download_retryable=retryable
                comic.download_chapters = entry.chapters
                comic.download_updated_at = entry.updated_at
                out[#out + 1] = comic
            end
        end
    end
    table.sort(out, function(a, b)
        return (a.download_updated_at or 0) > (b.download_updated_at or 0)
    end)
    return out
end

--- 某部漫画的清单条目 (调试/诊断用, 返回内部表, 不要修改)
function M.entry(source_id, comic_id)
    return entry_of(source_id, comic_id, false)
end

--- 删除一部漫画的全部下载 (图片 + 清单)
function M.remove(source_id, comic_id)
    local entry = entry_of(source_id, comic_id, false)
    if entry then
        if entry.comic and entry.comic.content_type=="novel" then
            local ok=pcall(function()
                for _,ch in pairs(entry.chapters or {}) do
                    if ch.document then require("novel.document").remove(Cache.BASE_DIR.."/novels/downloads",ch.document.key) end
                end
            end)
            if not ok then return false,"部分小说文件未能删除，请重试" end
        end
        for _k, ch in pairs(entry.chapters or {}) do
            local dir = M.chapterDir(source_id, comic_id, ch.order)
            pcall(function()
                for name in lfs.dir(dir) do
                    if name ~= "." and name ~= ".." then
                        os.remove(dir .. "/" .. name)
                    end
                end
                lfs.rmdir(dir)
            end)
        end
        pcall(function()
            for name in lfs.dir(M.comicDir(source_id, comic_id)) do
                if name ~= "." and name ~= ".." then
                    os.remove(M.comicDir(source_id, comic_id) .. "/" .. name)
                end
            end
            lfs.rmdir(M.comicDir(source_id, comic_id))
        end)
        if lfs.attributes(M.comicDir(source_id,comic_id),"mode")=="directory" then
            return false,"部分下载文件未能删除，请重试"
        end
        local data = M.load()
        local sid = tostring(source_id or "unknown")
        if data.comics[sid] then data.comics[sid][tostring(comic_id)] = nil end
        if not M.save(true) then
            data.comics[sid]=data.comics[sid] or {};data.comics[sid][tostring(comic_id)]=entry
            return false,"下载文件已删除，但清单保存失败，请重试"
        end
        return true
    end
    return false
end

-- Cancel only affected books; downloads of the other content type continue.
function M.clearType(kind)
    assert(kind=="comic" or kind=="novel","invalid download type")
    M.load()
    assert(not M.load_error,"下载清单损坏，无法清空")
    local before=Cache:getDirSize(Cache.DOWNLOAD_CACHE_DIR)+Cache:getDirSize(Cache.BASE_DIR.."/novels/downloads")
    local count=0
    for _,comic in ipairs(M.list()) do
        if (comic.content_type=="novel" and "novel" or "comic")==kind then
            require("util.download_queue").instance():cancelComic(comic.source_id,comic._id,"清空分类下载")
            local ok,err=M.remove(comic.source_id,comic._id);assert(ok,err)
            count=count+1
        end
    end
    return {comics=count,bytes=math.max(0,before-Cache:getDirSize(Cache.DOWNLOAD_CACHE_DIR)-Cache:getDirSize(Cache.BASE_DIR.."/novels/downloads"))}
end

-- Caller must stop the download queue before purging its persistent files.
function M.clearAll()
    local data=M.load()
    assert(not M.load_error,"下载清单损坏，无法清空")
    local before_bytes=Cache:getDirSize(Cache.DOWNLOAD_CACHE_DIR)+Cache:getDirSize(Cache.BASE_DIR.."/novels/downloads")
    local count,bytes=0,0
    for sid,bucket in pairs(data.comics or {}) do
        local novels={}
        for cid,entry in pairs(bucket) do if entry.comic and entry.comic.content_type=="novel" then novels[#novels+1]=cid end end
        for _,cid in ipairs(novels) do
            local ok,err=M.remove(sid,cid);assert(ok,err);count=count+1
        end
    end
    for _,bucket in pairs(data.comics or {}) do for _ in pairs(bucket) do count=count+1 end end
    local function clear(path)
        local attr=(lfs.symlinkattributes or lfs.attributes)(path)
        if not attr then return end
        if attr.mode=="directory" then
            for name in lfs.dir(path) do
                if name~="." and name~=".." then clear(path.."/"..name) end
            end
            assert(lfs.rmdir(path),"部分下载目录未能删除，请重试")
        else
            assert(os.remove(path),"部分下载文件未能删除，请重试")
            if attr.mode=="file" then bytes=bytes+(attr.size or 0) end
        end
    end
    for _,download_root in ipairs{Cache.DOWNLOAD_CACHE_DIR,Cache.BASE_DIR.."/novels/downloads"} do
        if lfs.attributes(download_root,"mode")=="directory" then
            for name in lfs.dir(download_root) do if name~="." and name~=".." then clear(download_root.."/"..name) end end
        end
    end
    data.comics={}
    assert(M.save(true),"下载文件已删除，但清单保存失败，请重试")
    return {comics=count,bytes=math.max(0,before_bytes-Cache:getDirSize(Cache.DOWNLOAD_CACHE_DIR)-Cache:getDirSize(Cache.BASE_DIR.."/novels/downloads"))}
end

--- 重启后把上次未完成的状态归为 partial，不归零已经落盘的页数。
function M.markInterrupted()
    local data = M.load()
    local changed = false
    for _sid, bucket in pairs(data.comics or {}) do
        for _cid, entry in pairs(bucket) do
            for _k, ch in pairs(entry.chapters or {}) do
                if ch.state == "downloading" or ch.state == "preparing"
                    or ch.state == "queued" then
                    ch.state = "partial"
                    changed = true
                end
            end
            if M.deriveState(entry) ~= entry.state then
                entry.state = M.deriveState(entry)
                changed = true
            end
        end
    end
    if changed then M.save(true) end
end

--- 把不完整条目的"已落盘页数"重新对账 (清单里 total 可能没记上)
function M.refreshCounts(source_id, comic_id)
    local entry = entry_of(source_id, comic_id, false)
    if not entry then return end
    for _k, ch in pairs(entry.chapters or {}) do
        local images = M.localImages(source_id, comic_id, ch.order)
        if #images > 0 then ch.done = #images end
    end
    entry.state = M.deriveState(entry)
    M.save(true)
end

return M
