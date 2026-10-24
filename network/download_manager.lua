-- network/download_manager.lua
-- 章节文件的**命名 / 落盘 / 查找 / 清理**。
--
-- 注意这里**不再有下载与打包**:
--   * 页面下载由 util/download_scheduler.lua 决策 + network/transport_worker.lua 执行
--     (见 ui/stream_reader.lua 的 StreamSession);
--   * CBZ 打包整条链已删除 (阅读统一走流式, 打包只会在 Kindle 上白占磁盘与内存)。
-- 本模块保留的是被那些路径复用的"文件在哪 / 叫什么 / 是不是有效图片"这类纯函数。

local logger = require("util.logger")
local lfs = require("libs/libkoreader-lfs")
local Cache = require("util.cache")

local DownloadManager = {}

--- 转为绝对路径
-- 数据目录在某些平台是相对路径 (模拟器下为 ".")，会导致
--   1) 目录创建逻辑把路径错误地拼成 /cache/... (根目录)
--   2) 外部命令 (zip) 先 cd 后相对路径失效
-- 因此所有缓存路径统一转成绝对路径。
local function to_abs(path)
    if not path or path:sub(1, 1) == "/" then
        return path
    end
    local cwd = lfs.currentdir() or "."
    return cwd .. "/" .. path:gsub("^%./", "")
end

--- 获取阅读页缓存根目录 (绝对路径)
-- 统一挂在 util.cache 的缓存根下, 这样设置页的容量统计与清理能覆盖到阅读页。
function DownloadManager.getCacheDir()
    return to_abs(Cache.READING_CACHE_DIR)
end

-- External cache identities include the source; builtins keep legacy paths.
local function cache_identity(comic_id, order, source_id)
    source_id = source_id or require("source.registry"):getCurrentId()
    if source_id and not require("source.identity").legacyCache(source_id) then
        local hash = require("ffi/sha2").sha256
        return "ext_" .. hash(source_id .. ":" .. tostring(comic_id)):sub(1, 32),
            "ch_" .. hash(tostring(order)):sub(1, 32)
    end
    return tostring(comic_id), tostring(order)
end

--- 获取章节图片目录
-- 注意: 这三个路径函数既被内部 `self.xxx()` 调用, 也被外部以 `.` 调用
-- (api/comic.lua), 因此不能依赖 self。
function DownloadManager.getChapterDir(comic_id, order, source_id)
    comic_id, order = cache_identity(comic_id, order, source_id)
    return DownloadManager.getCacheDir() .. "/" .. comic_id .. "/" .. order
end

--- 获取 CBZ 文件路径 (离线打包, 与阅读页缓存分开存放)
function DownloadManager.getCBZPath(comic_id, order, source_id)
    comic_id, order = cache_identity(comic_id, order, source_id)
    return to_abs(Cache.DOWNLOAD_CACHE_DIR) .. "/" .. comic_id .. "_" .. order .. ".cbz"
end

--- 获取流式阅读的占位文件路径 (绝对路径)
--
-- 路径按"漫画+章节"固定 (不含时间戳), 这样 KOReader 能记住阅读进度与缩放设置。
-- **只在这一处拼这个路径**: 以前 api/comic.lua 与详情页各拼一份, 两边一旦不一致,
-- "清阅读进度"就会清到另一个文件上 —— 表现就是"点「开始」却接着上次读"。
function DownloadManager.getStreamPath(comic_id, order, source_id)
    comic_id, order = cache_identity(comic_id, order, source_id)
    return DownloadManager.getCacheDir() .. "/" .. tostring(comic_id)
        .. "_" .. tostring(order) .. ".stream"
end

--- 支持的图片扩展名
local IMAGE_EXTS = { ".jpg", ".jpeg", ".png", ".gif", ".webp" }

--- 判断文件名是否为支持的图片
local function is_image_name(name)
    for _, ext in ipairs(IMAGE_EXTS) do
        if name:sub(-#ext) == ext then
            return true
        end
    end
    return false
end

--- 按文件头识别图片格式
-- @return: 扩展名 (".jpg" / ".png" / ...) 或 nil (不是可识别的图片)
local function detect_image_ext(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local sig = f:read(16) or ""
    f:close()

    if sig:sub(1, 3) == "\255\216\255" then
        return ".jpg"
    elseif sig:sub(1, 8) == "\137PNG\r\n\26\n" then
        return ".png"
    elseif sig:sub(1, 6) == "GIF87a" or sig:sub(1, 6) == "GIF89a" then
        return ".gif"
    elseif sig:sub(1, 4) == "RIFF" and sig:sub(9, 12) == "WEBP" then
        return ".webp"
    end
    return nil
end

--- 缓存文件是否真的是图片
--
-- **踩过的坑**: 目标站点的错误页同样是"HTTP 200 + 非空内容"。
-- 源 C 的图片地址需要签名, 签名失效时 CDN 返回 403 + 一个 1.5KB 的 HTML
-- 错误页, 曾被原样存成 .jpg。首次下载路径有"必须是图片"的断言, 但**走缓存**
-- 这条路当时只判断"文件存在" —— 于是坏文件被永久当成有效缓存,
-- 用户每次打开那一页都是坏画面, 而且永远等不到自动修复。
--
-- @return: true 表示可安全交给 KOReader 解码
local function is_valid_image_file(path)
    return detect_image_ext(path) ~= nil
end

--- 已校验缓存索引: base_path -> { path = 真实路径, size = 文件大小 }
--
-- 原来每次查找都要对 5 个候选扩展名各做一次 lfs.attributes, 命中后再 io.open +
-- read(16) 嗅探文件头。而这个函数在**绘制链**上被反复调用
-- (StreamDocument:getFullPageHash / getUsedBBox / MultiImageDoc:openPage ->
-- StreamSession:find_page), 一次翻页要走上 3~4 遍 —— 也就是 15~20 次 stat 加
-- 3~4 次文件打开, 全部同步发生在渲染路径里。有索引后命中退化成 1 次 stat。
--
-- 正确性靠两条:
--   1. 只在**校验通过**后写入;
--   2. 任何写入 / 改名 / 删除都必须让它失效 (fix_image_extension、forget_image),
--      另外每次命中都比对文件大小, 挡住"原地被改坏"。
-- 少了任何一条, "HTTP 200 的 HTML 错误页"就可能被当成有效缓存永久使用 ——
-- 那正是 is_valid_image_file 当初要修的 bug。

-- 索引条目上限 (长会话内存有界, 见 F-PERF-004)
--
-- 索引是**纯优化**: 丢一条只是下次多一次 stat + 嗅探文件头, 不会让任何判定变错
-- (写入前一定校验过, 命中还会比对文件大小)。所以超限时**整表清空**即可 ——
-- 比维护 LRU 时间戳省内存, 也避免"淘汰逻辑自己有 bug 反而把有效缓存判坏"。
-- 不设上限的话, 每个看过的页/封面都会留一条 (base_path -> {path,size}), 长期不重启
-- 的会话里它无界增长, 而设备可用内存只有 ~130MB。
--
-- 做成模块字段是为了让测试能临时改小 (否则要造 2048 个文件才碰得到这条路径)。
DownloadManager.KNOWN_GOOD_MAX = 2048

local known_good = {}
local known_good_count = 0

--- 写入一条索引 (统一走这里, 才能维护计数与上限)
local function remember_image(base_path, path, size)
    if not known_good[base_path] then
        local max = DownloadManager.KNOWN_GOOD_MAX or 2048
        if known_good_count >= max then
            known_good = {}
            known_good_count = 0
            if logger.enabled then logger.info("Picayomi DownloadManager: 缓存索引超过 " .. max ..
                " 条, 已清空重建 (下次查找会重新校验)") end
        end
        known_good_count = known_good_count + 1
    end
    known_good[base_path] = { path = path, size = size }
end

--- 当前索引条目数 (仅供测试 / 诊断)
function DownloadManager._knownGoodCount()
    return known_good_count
end

--- 让某个缓存路径的索引失效 (写入 / 改名 / 删除后必须调用)
local function forget_image(path)
    if not path then return end
    local base = path:gsub("%.[^%.]+$", "")
    if known_good[base] then
        known_good[base] = nil
        known_good_count = known_good_count - 1
    end
end

--- 在目录中查找已存在的**有效**图片 (同一序号可能有不同扩展名)
-- 无效文件 (HTML 错误页 / 空文件 / 截断文件) 会被删除并返回 nil,
-- 从而让调用方重新下载, 而不是把坏画面一直交给用户。
local function find_existing_image(base_path)
    -- 快路径: 上次校验过的那一个扩展名。一次 stat 同时确认"还在"与"没被改过"
    -- (大小不同 = 被重写过, 必须重新校验)
    local hit = known_good[base_path]
    if hit then
        if lfs.attributes(hit.path, "size") == hit.size then
            return hit.path
        end
        forget_image(hit.path)
    end

    for _, ext in ipairs(IMAGE_EXTS) do
        local p = base_path .. ext
        if lfs.attributes(p, "mode") == "file" then
            if is_valid_image_file(p) then
                remember_image(base_path, p, lfs.attributes(p, "size"))
                return p
            end
            logger.warn("Picayomi DownloadManager: 缓存不是有效图片, 已丢弃重下: " .. p)
            os.remove(p)
            forget_image(p)
        end
    end
    return nil
end

--- 根据文件头修正扩展名
-- 各图源返回的图片格式未必与假定的 .jpg 一致 (例如 旧源 大量返回 WEBP)，
-- 而 KOReader 是按扩展名选择图片解码器的，因此必须修正。
-- @return: 修正后的真实路径
local function fix_image_extension(path)
    -- 文件刚被写过/改名过, 索引里的旧结论不再可信 (否则一个"200 的 HTML 错误页"
    -- 会被当成有效缓存, 因为路径没变)
    forget_image(path)

    local ext = detect_image_ext(path)
    if not ext then return path end

    local base = path:gsub("%.[^%.]+$", "")
    local new_path = base .. ext
    if new_path == path then return path end

    os.remove(new_path)          -- 覆盖可能存在的旧文件
    os.rename(path, new_path)
    return new_path
end

-- 供流式阅读等模块复用 (必须在上面三个函数定义之后)
DownloadManager.fixImageExtension = fix_image_extension
DownloadManager.findExistingImage = find_existing_image
DownloadManager.isImageName = is_image_name
DownloadManager.isValidImageFile = is_valid_image_file
DownloadManager.forgetImage = forget_image

--- 检查章节是否已下载
function DownloadManager:isChapterDownloaded(comic_id, order, total_images)
    local cache_dir = self.getChapterDir(comic_id, order)
    if lfs.attributes(cache_dir, "mode") ~= "directory" then
        return false, 0, total_images or 0
    end

    local count = 0
    for file in lfs.dir(cache_dir) do
        if is_image_name(file) then
            count = count + 1
        end
    end

    if total_images and total_images > 0 then
        return count >= total_images, count, total_images
    end

    return count > 0, count, total_images or count
end

--- 阅读页缓存最多保留多少话 (正在读的那一话永远保留)
--
-- 为什么按"话"而不是按"页": 页面本来就以话为单位存在
-- <reading>/<comic_id>/<order>/ 下, 按话删是一整个目录, 干净且便宜;
-- 用户回看时命中的也是整话。
DownloadManager.READING_CACHE_KEEP_CHAPTERS = 10

--- 裁剪阅读页缓存: 只保留最近 keep_chapters 话 (占位文件与 .sdr 保留)
--
-- 流式阅读按需下载的页面留在 <reading>/<comic_id>/<order>/ 下 —— 这就是
-- "已看过的页保留下来, 回看不用重新联网"的落地方式。但页面会一直堆积,
-- 所以需要一条明确的清理策略: 按话保留最近 N 话, 其余整目录删除。
--
-- 调用时机: 每次开新一话 (StreamDocument.registerSession)。那是天然的、低频的
-- 清理点, 而且此刻当前话的目录还没建, 不会误伤。
--
-- @param keep_chapters: 保留几话, 缺省取 READING_CACHE_KEEP_CHAPTERS
-- @param protect_comic_id, protect_order: 正在读的那一话, 永远不删
-- @return: 删掉的话数
function DownloadManager:trimReadingCache(keep_chapters, protect_comic_id, protect_order, source_id)
    keep_chapters = keep_chapters or self.READING_CACHE_KEEP_CHAPTERS
    local root = self.getCacheDir()
    if lfs.attributes(root, "mode") ~= "directory" then return 0 end

    local protect_key
    if protect_comic_id ~= nil and protect_order ~= nil then
        protect_comic_id, protect_order = cache_identity(protect_comic_id, protect_order, source_id)
        protect_key = tostring(protect_comic_id) .. "/" .. tostring(protect_order)
    end

    -- 收集所有章节目录 <reading>/<comic_id>/<order>/
    local chapters = {}
    for comic in lfs.dir(root) do
        -- <...>.stream.sdr 是文档设置目录, 不是章节目录 (见下面"配置项不清理")
        if comic ~= "." and comic ~= ".." and not comic:find("%.sdr$") then
            local comic_dir = root .. "/" .. comic
            if lfs.attributes(comic_dir, "mode") == "directory" then
                for order in lfs.dir(comic_dir) do
                    if order ~= "." and order ~= ".." then
                        local chap_dir = comic_dir .. "/" .. order
                        local attr = lfs.attributes(chap_dir)
                        if attr and attr.mode == "directory" then
                            table.insert(chapters, {
                                key = comic .. "/" .. order,
                                path = chap_dir,
                                mtime = attr.modification or 0,
                            })
                        end
                    end
                end
            end
        end
    end

    -- 最新的在前; 当前正在读的那一话无条件保留
    table.sort(chapters, function(a, b) return a.mtime > b.mtime end)
    local kept, removed = 0, 0
    for _idx, chap in ipairs(chapters) do
        if chap.key == protect_key or kept < keep_chapters then
            kept = kept + 1
        else
            os.execute("rm -rf \"" .. chap.path .. "\"")
            removed = removed + 1
        end
    end

    -- **占位文件与 .sdr 一律保留** (包括已删章节的)。
    --
    -- 以前这里会把"章节目录已删、只剩 <comic>_<order>.stream 与 .sdr"的孤儿
    -- 一并清掉, 理由是它们没用了。但 .sdr 里是 KOReader 的文档设置: 读到第几页、
    -- 缩放、旋转。删掉章节目录只是省了图片空间, 不该顺带把"上次读到哪"也抹掉
    -- (用户约定: 配置/进度类占用极低, 最次清理)。
    -- 代价: 每读过一话多两个小文件 (占位 0 字节 + .sdr 几 KB), 可忽略。

    if removed > 0 then
        if logger.enabled then logger.info(string.format(
            "Picayomi DownloadManager: 阅读页缓存裁剪, 保留 %d 话, 删除 %d 话",
            kept, removed)) end
    end
    return removed
end

--- 按总量上限清理可再生缓存，下载内容不参与统计或淘汰
--
-- **淘汰顺序 (分层)**: 临时文件 / 封面 (1) -> 阅读页 (2) -> 数据 (3), 同层内
-- 最旧的先删。这是用户约定的策略: 缓存满时优先清**历史最早**的图片, 因为
-- 它们都能再下回来, 代价只有一次网络请求。
--
-- **永不主动清 (第 0 层)**: `<...>.stream` 占位文件与 `<...>.stream.sdr` 目录。
-- 它们装的是 KOReader 的文档设置 —— 读到第几页、缩放、旋转, 以及我们写的
-- picayomi_*_applied 标记。占用只有几 KB, 却是用户最不容易重建的东西
-- (进度丢了要自己找回那一页)。以前 cleanCache 的递归扫描会扫进 .sdr 里按
-- mtime 删文件, 于是"清缓存把阅读进度清了" —— 这正是要避免的。
--
-- @param max_size_mb: 最大缓存大小 (MB), 缺省取配置 max_cache_size
-- @param protect_seconds: 修改时间在这么多秒以内的文件**一律不动** (缺省 0 = 不保护)。
--        会话中的清理必须传它: 用户正在读的那一页是**刚刚**写进去的, 删掉就会
--        看到"明明刚看过却又要重新下载"。启动时那次清理不需要 (那时没人正在读)。
-- @return 实际删掉的字节数
function DownloadManager:cleanCache(max_size_mb, protect_seconds)
    max_size_mb = max_size_mb or require("util.config"):get("max_cache_size") or 500
    local max_bytes = max_size_mb * 1024 * 1024
    local cutoff = (protect_seconds and protect_seconds > 0)
        and (os.time() - protect_seconds) or nil

    -- 收集所有缓存文件 (递归, 覆盖阅读页的多层目录结构)
    local files = {}
    local total_size = 0
    local cover_dir = to_abs(Cache.COVER_CACHE_DIR)
    local function scanDir(dir, tier)
        if lfs.attributes(dir, "mode") ~= "directory" then return end
        for name in lfs.dir(dir) do
            if name ~= "." and name ~= ".." then
                local fpath = dir .. "/" .. name
                local attr = lfs.attributes(fpath)
                if attr and attr.mode == "file" then
                    -- 占位文件: 0 字节, 但删了 KOReader 就找不到对应进度
                    if not name:find("%.stream$") then
                        table.insert(files, {
                            path = fpath,
                            size = attr.size,
                            mtime = attr.modification,
                            tier = tier or 2,
                        })
                        total_size = total_size + attr.size
                    end
                elseif attr and attr.mode == "directory" then
                    -- .sdr = 文档设置 (阅读进度/缩放/旋转), 属于第 0 层, 不进淘汰列表
                    if not name:find("%.sdr$") and fpath ~= cover_dir then
                        scanDir(fpath, tier)
                    end
                end
            end
        end
    end

    -- 第 1 层: 临时文件 + 封面 (丢了最不心疼, 也最小)
    scanDir(to_abs(Cache.TEMP_DIR), 1)
    scanDir(cover_dir, 1)
    -- 第 2 层: 阅读页 (再下回来要一次网络请求, 但内容可再生)
    scanDir(to_abs(Cache.IMAGE_CACHE_DIR), 2)
    scanDir(to_abs(Cache.READING_CACHE_DIR), 2)
    -- 第 3 层: 数据缓存 (源站响应/列表, 删了只是下次慢一点)
    scanDir(to_abs(Cache.DATA_CACHE_DIR), 3)
    -- **不扫 downloads**: 那是用户主动下载的离线内容, 不是可再生的缓存。
    -- 按 mtime 淘汰会把"下载好的漫画"清掉, 而清单还在 —— 用户看到列表里有,
    -- 点开却读不了。容量上限只约束缓存, 下载由用户自己管理 (已下载页可删)。

    if total_size <= max_bytes then return 0 end

    -- 先按层、再按修改时间 (同层里最旧的在前), 清理到 80% 上限
    table.sort(files, function(a, b)
        if a.tier ~= b.tier then return a.tier < b.tier end
        return (a.mtime or 0) < (b.mtime or 0)
    end)
    local removed = 0
    for _, file in ipairs(files) do
        if total_size <= max_bytes * 0.8 then break end
        -- 刚写进去的 (用户正在读的那一页/那一话) 不删
        if cutoff and file.mtime and file.mtime > cutoff then
            -- 跳过, 继续看下一个 (旧的在后面对不上就继续往后找)
        else
            os.remove(file.path)
            total_size = total_size - file.size
            removed = removed + file.size
            if logger.enabled then logger.dbg("Picayomi DownloadManager: 清理缓存: " .. file.path) end
        end
    end
    return removed
end

-- ============================================================================
-- 缓存总量记账: 让 max_cache_size 在**长会话里**也生效
-- ============================================================================
-- 背景: 总量上限以前只在**启动时**检查一次 (main.lua 排的那个后台任务),
-- 于是"一直读、从不重启"的长会话里缓存可以无限涨 —— 而 Kindle 的存储本来就紧张。
--
-- 为什么不用"每下一页就 getCacheSize()": 那是一次**全树递归 stat** (缓存里几千个
-- 文件就是几千次同步 IO), 发生在下载完成的事件循环里 —— 正是本项目一直在消灭的
-- 东西。而下载路径本来就知道自己写了多少字节 (transport 上报的 size), 累加即可。
-- 只有"估计值越过上限"时才做一次精确遍历。
DownloadManager.pending_bytes = 0
DownloadManager.known_cache_bytes = nil    -- 懒建立的基线 (nil = 还没量过)
DownloadManager.clean_recheck_at = 0       -- 下次允许清理的水位

--- 清理之后至少要再长这么多字节, 才允许下一次清理。
--
-- 防止"清理没删掉东西 (全被保护了) -> 下一次下载立刻又触发 -> 反复全树遍历"。
-- 实际取值是它与"上限的 10%"里更大的那个。
DownloadManager.CACHE_RECHECK_BYTES = 8 * 1024 * 1024

--- 刚写入的缓存文件多久之内不许被自动清理 (秒)
--
-- 600 秒是个粗粒度但够用的界: 用户此刻在读的那一话页都是刚写的。
DownloadManager.CLEAN_PROTECT_SECONDS = 600

--- 记一次"刚往缓存里写了 n 字节" (下载完成回调调用)
--
-- **纯内存加法**, 不做任何 IO —— 这是本方案能在事件循环里安全调用的前提。
function DownloadManager:noteCacheBytes(n)
    n = tonumber(n)
    if not n or n <= 0 then return end
    self.pending_bytes = self.pending_bytes + n
end

--- 需要时按总量上限清理缓存 (下载完成回调调用)
--
-- 绝大多数调用只做几次算术就返回; 只有估计值真的越过上限时才做一次目录遍历。
-- **纯家务**: 任何失败都只记日志, 绝不抛出去 —— 它跑在下载完成回调里, 抛出去会
-- 连带把"把这一页显示出来"也一起干掉 (见 Scheduler:_complete 的 pcall 注释)。
-- @return true 表示这次真的做了清理
function DownloadManager:maybeCleanCache()
    local pending = self.pending_bytes
    if pending <= 0 then return false end
    self.pending_bytes = 0

    local max_mb = require("util.config"):get("max_cache_size") or 500
    local max_bytes = max_mb * 1024 * 1024

    -- 首次调用才量一次基线 (一次遍历); 之后靠增量维护
    local known = self.known_cache_bytes
    if known == nil then
        local ok, size = pcall(Cache.getCacheSize, Cache)
        -- downloads 不是可淘汰的缓存 (见 cleanCache 的说明): 从基线里扣掉,
        -- 否则用户下载了几百 MB 漫画后, 每次记账都会"超限", 把封面/阅读页
        -- 反复清空, 而下载内容一个字节都动不了。
        local ok_dl, dl_size = pcall(Cache.getDirSize, Cache, Cache.DOWNLOAD_CACHE_DIR)
        if ok and size and ok_dl and dl_size then size = size - dl_size end
        if not ok or not size then
            logger.warn("Picayomi DownloadManager: 量不出缓存总量, 本次跳过: "
                .. tostring(size))
            return false
        end
        known = size
    end
    known = known + pending
    self.known_cache_bytes = known

    if known <= max_bytes or known < self.clean_recheck_at then
        return false
    end

    local ok, removed = pcall(self.cleanCache, self, max_mb, self.CLEAN_PROTECT_SECONDS)
    if not ok then
        logger.warn("Picayomi DownloadManager: 缓存清理失败: " .. tostring(removed))
        return false
    end

    local after = known - (removed or 0)
    self.known_cache_bytes = after
    self.clean_recheck_at = after + math.max(max_bytes * 0.1, self.CACHE_RECHECK_BYTES)
    if logger.enabled then logger.info(string.format(
        "Picayomi DownloadManager: 会话中缓存超限, 已清理 %.1fMB (估计剩余 %.1fMB)",
        (removed or 0) / 1024 / 1024, after / 1024 / 1024)) end
    return true
end

return DownloadManager
