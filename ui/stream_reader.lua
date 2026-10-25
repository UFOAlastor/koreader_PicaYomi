-- ui/stream_reader.lua
-- 流式漫画阅读 (按需取页)
--
-- 为什么是现在这个样子 (2026-10 重构):
--   阅读期"卡不卡"几乎全由**下载调度的时序**决定, 而旧实现把"发起下载/失败重试/提示"
--   全挂在 Document:openPage 上 —— 而 openPage 位于 KOReader 的绘制链内部:
--     UIManager:_repaint -> paintTo -> Document:renderPage -> openPage
--   于是"失败重试"也落在绘制路径里, 只能靠一堆补丁去堵 (失败冷却 15s / 连续失败熔断 /
--   慢页熔断 / 每页只提示一次 / 翻页放行重试 / DocCache 键带 epoch —— 六个机制,
--   同一个根因)。
--
--   现在把"决策"从"绘制"里彻底摘出来, 四层分工:
--     * util/page_store.lua        每页的本地状态 (路径/尺寸/状态/渲染键)。纯查, 渲染链安全。
--     * util/download_scheduler    唯一的决策点 (优先级/去重/退避/熔断/取消/每步预算)。
--     * network/transport_blocking 只发起/收割 I/O, 不含任何策略。
--     * ui/reader_bridge.lua       驱动层: 决定"什么时候推进一步调度" (tick 预算/重排)。
--   本文件把前三层组装成"会话", 并实现 KOReader 的 Document 接口 (按需取页);
--   会话只回答"下哪一页 / 失败了怎么办", 不安排自己的执行时机。
--
--   不变量 (test/scheduler_offline.lua 与 functional_stream.lua 会断言):
--     * 绘制链 (openPage / getUsedBBox / getNativePageDimensions / getFullPageHash /
--       getPagePartHash / hintPage) 内**零网络、零 UI、零写盘**: 缺页只返回占位页。
--     * 下载由调度器在事件循环里推进 (每步 ≤1 个新请求 + ≤1 个完成), 完成后触发
--       一次重绘, 占位页被真实页替换。
--     * 文档 close / 会话 cancel ⇒ 不再有任何下载落地。
--
-- 实现方式: KOReader 的 Document:renderPage() 是通过
--   local page = self._document:openPage(n); page:draw(dc, bb)
-- 来渲染的。因此只要给 self._document 提供一个"按需取页"的实现,
-- 就能直接复用 KOReader 整套排版/缩放/缓存逻辑。

local logger = require("util.logger")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Document = require("document/document")
local DrawContext = require("ffi/drawcontext")
local CanvasContext = require("document/canvascontext")
local DownloadManager = require("network/download_manager")
local Config = require("util.config")
local Diag = require("util.diag")
local Geom = require("ui/geometry")
local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local RenderText = require("ui/rendertext")

local PageStore = require("util.page_store")
local Scheduler = require("util.download_scheduler")
local ImageSize = require("util.image_size")
local ImageGuard = require("util.image_guard")
local ScaledDecode = require("util.scaled_decode")
local PngDecode = require("util.png_decode")
local MemoryGuard = require("util.memory_guard")
local TransportBlocking = require("network.transport_blocking")
local TransportWorker = require("network.transport_worker")
local ReaderBridge = require("ui.reader_bridge")
local ViewMode = require("ui.common.view_mode")
local lfs = require("libs/libkoreader-lfs")

-- 预取页数的默认值与上下限
-- 用户在"阅读设置 → 提前加载页数"里可调 (0 = 关闭预取)。
--
-- 默认 3 (原为 1): 真机 diag.log 实测单页下载只要 ~0.1s, 所以"翻页闪加载中"不是带宽问题,
-- 而是"翻页那一刻才开始下"。窗口 1 页意味着下一张图得等用户真翻过去才开始取; 3 页让
-- 翻页时目标页通常已经落盘。代价只在磁盘 (预取只写文件, 解码只在 openPage 发生)。
local PREFETCH_DEFAULT = 3
local PREFETCH_MAX = 9

-- 预取之间的间隔 (秒)。太小会让界面一直没机会处理输入。
--
-- 0.2 (原为 0.5): 队列里每 0.2s 才有一页进入调度器, 窗口 3 页 = 最慢 0.6s 才全部排上。
-- 这个延迟**只 gate 第 n+2 页往后** —— 用户翻到的那一页永远是以 P_CURRENT 立刻请求的
-- (见 request_page / on_page_turn), 所以缩小它不会让当前页和预取抢带宽。
-- 必须 > 0: 0 延迟的自调度会让 UIManager:handleInput 永不退出 (见 ui/reader_bridge.lua 文件头)。
local PREFETCH_DELAY = 0.2

-- 占位页的字号 (居中显示"加载中…" / "本页加载失败")
local PLACEHOLDER_FONT_SIZE = 22

-- 一次 openPage (解码 + 交给排版) 超过这个毫秒数就记一行诊断。
-- 150ms 是"用户能感觉到的一顿"的门槛; 真机上正常页应该在几十毫秒。
local RENDER_SLOW_MS = 150

-- 单调墙钟 (秒)。只给诊断计时用 —— **不能用 os.clock()**: 它量的是 CPU 时间,
-- 而"翻页卡一下"绝大多数时间是等 I/O / 等绘制, CPU 时间几乎不动。
local function now_seconds()
    local ok, socket = pcall(require, "socket")
    if ok and type(socket) == "table" and socket.gettime then return socket.gettime() end
    return os.clock()
end

-- "这一页此刻画在屏幕上的是什么"的指纹。
-- 与 DocCache 的键同源 (内容身份 + 排版尺寸): 下载完成时若它没变, 说明屏幕上
-- 已经是这张图了, 再发一次 PageUpdate 只会白刷一屏。
local function render_key(session, n)
    local key = session.store:render_key(n)
    local epoch = session.memory_epoch and session.memory_epoch[n]
    return epoch and epoch > 0 and (key .. "|memory:" .. epoch) or key
end

local function painted_key(session, n)
    local sz = session.store.sizes[n]
    return render_key(session, n) .. "|" .. (sz and (sz.w .. "x" .. sz.h) or "?")
end

--- 取 ffi/pic 模块
--
-- 刻意**不做模块级缓存**: require 本身就是 package.loaded 的一次查表 (O(1)),
-- 而缓存会让"后来替换了 package.loaded['ffi/pic']"的测试拿不到新模块。
local function pic_module()
    return require("ffi/pic")
end

--- 占位页尺寸: 直接用屏幕大小
--
-- 这样"加载中"能按正常字号居中画出来。旧实现是 1x1 的空白页再放大铺满,
-- 整页只有一个像素, 既画不下字、也看不出"到底是在加载还是这页本来就是白的"。
local function placeholder_dims()
    return {
        w = CanvasContext:getWidth() or 600,
        h = CanvasContext:getHeight() or 800,
    }
end

--- 把字节数变成好读的文案 ("41.2MB" / "512KB" / "800B")
local function human_size(n)
    n = tonumber(n)
    if not n then return "?" end
    if n >= 1024 * 1024 then return string.format("%.1fMB", n / 1024 / 1024) end
    if n >= 1024 then return string.format("%.0fKB", n / 1024) end
    return string.format("%dB", n)
end

--- 文件字节数 (供大图守卫的文件大小闸用)
--
-- 一次 stat。渲染键 (util/page_store.lua 的 render_key) 本来每次渲染就要 stat 两次,
-- 所以这不引入新的量级; 而 openPage 只在 DocCache 未命中 (真要重画) 时才被调到。
local function file_size_of(path)
    if not path then return nil end
    return lfs.attributes(path, "size")
end

--- 从路径后缀猜图片格式 (**兜底**用)
--
-- 正常情况下尺寸记录里已经带了**从文件内容嗅探**出来的格式 (util/image_size.lua),
-- 那才是权威。这里只在尺寸记录缺失时兜底 —— 而 F-READ-009 保证了下载落盘时
-- 扩展名与内容一致 (network/download_manager 的 fix_image_extension), 所以后缀可信。
local function format_from_path(path)
    if not path then return nil end
    return path:match("%.([%w]+)$")
end

--- 递归创建目录 (等价于 mkdir -p)
--
-- 为什么不用 `os.execute("mkdir -p ...")`: 每开一话都要 fork 一个 shell, 而这一步
-- 就在"点开始"的等待窗口里 —— shell 启动本身要几十毫秒, 且它完全不必要。
-- (同类问题见 network/http_client.lua:243 的注释: 那里保留 shell 是因为它要处理
--  "相对路径逐级拼接会拼出 /xxx" 的坑; 这里的路径已经过 DownloadManager.to_abs, 是绝对路径。)
--
-- lfs.mkdir 只建最后一级, 所以逐级向上补齐; 已存在就什么都不做。
local function mkdir_p(path)
    if not path or path == "" then return end
    if lfs.attributes(path, "mode") == "directory" then return end
    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" and parent ~= path then
        mkdir_p(parent)
    end
    lfs.mkdir(path)
end

--- 下载完成后, 若用户还停在这一页, 触发一次重绘
--
-- 绘制链里返回的是占位页, 真实图片要等下载完才有 —— 这里负责"替换":
--   PageUpdate -> ReaderView:onPageUpdate -> drawn=false + recalculate()
--   -> 重绘时 DocCache 因渲染键不同而未命中 -> 渲染真实页。
-- (KOReader 自己也这么做: readerpaging.lua 的 onRedrawCurrentPage)
--
-- **为什么要重试**: 第 1 页是在 `ReaderUI:showReader` **之前**就入队的
-- (api/comic.lua), 而下载跑在 fork 出来的子进程里 —— 它常常正好在
-- `ReaderUI:new` 排版那 ~2s 里落盘。那个时刻:
--   * `ReaderUI.instance` 还是 nil (readerui.lua:546 才赋值),
--   * 或 `paging.current_page` 还是 0 (readerpaging.lua:32 的初值, 到
--     onReadSettings 才变成 1)。
-- 旧实现在这两种情况下直接 return, 之后再没有任何东西触发重绘 —— 首屏就永久停在
-- "加载中…", 用户翻下一页再翻回来才看到图。所以这里把"还没就绪"与"用户已经翻走"
-- 分开: 前者有限次重试, 后者立刻放弃。
local REFRESH_RETRY_DELAY = 0.25   -- 秒
local REFRESH_MAX_RETRIES = 40     -- 0.25 * 40 = 10s, 足够覆盖建阅读器 + 首屏排版

-- @param force true = 无视"屏幕上已经是这张图"的判据, 一定发一次 PageUpdate
--
-- force 是为**排版尺寸**准备的, 不是为内容准备的:
--   首帧常常落在 ReaderUI 还在排版的 4~6 秒里, 那时这一页还没下载, 排版只能按
--   占位页尺寸 (屏幕大小) 算 —— zoom 也就按那个比例定了。等真图落盘、openPage
--   解码成功, painted 记下的是**真图**的尺寸, 于是"内容没变"的判据成立, 刷新被
--   跳过; 但 zoom 还是按占位尺寸算的那个 —— 用户看到的就是"第一页尺寸不对,
--   不全屏" (真机 2026-10-18)。尺寸从"未知"变"已知"时必须强制重算一次 zoom。
local function refresh_page_if_current(session, n, attempt, force)
    if session.cancelled then return end
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok or not ReaderUI then return end

    local function retry()
        attempt = (attempt or 0) + 1
        if attempt > REFRESH_MAX_RETRIES then return end
        UIManager:scheduleIn(REFRESH_RETRY_DELAY, function()
            refresh_page_if_current(session, n, attempt, force)
        end)
    end

    local ui = ReaderUI.instance
    if not ui or not ui.document then
        return retry()                 -- 阅读器还没建好
    end
    local doc_session = ui.document.session
    if doc_session ~= session then
        if doc_session ~= nil then return end   -- 已经是别的章了, 别去动它
        return retry()                          -- 文档还没 init 完
    end

    local paging = ui.paging
    local cur = paging and tonumber(paging.current_page)
    if not cur or cur <= 0 then
        return retry()                 -- 页码还没落到 1
    end

    -- 连续滚动模式: 一屏里可能同时摆着 2 页 (view.page_states), 而 current_page
    -- 记的是**最下面**那一页 (readerpaging 的 onScrollPanRel)。只认 current_page
    -- 的话, 上面那页下载完成时会被判成"用户已经翻走", 于是永远停在「加载中…」。
    local scroll_mode = (ui.view and ui.view.page_scroll) and true or false
    local visible = (cur == tonumber(n))
    if not visible and scroll_mode and type(ui.view.page_states) == "table" then
        for _i, st in ipairs(ui.view.page_states) do
            if st.page == tonumber(n) then visible = true break end
        end
    end
    -- 用户已经翻走了: 别去动他现在的画面
    if not visible then return end

    -- 屏幕上画的**已经**是这张文件: 什么都不用做。
    --
    -- 真机 (2026-10-18) 的典型场景: 第 1 页在 `ReaderUI:new` 排版的那 4~6 秒里
    -- 就落盘了 (下载跑在子进程里, 和排版重叠), 于是**首帧直接画的就是真图**;
    -- 等排版结束、事件循环终于能跑时, 落盘回调才发出 PageUpdate —— 屏幕内容
    -- 一个像素都没变, 却整屏白刷一次 (墨水屏 ~0.3s)。用户感知就是
    -- "第一页总是比后面卡一下"。
    --
    -- 判据用与 DocCache 同源的键 (内容身份 + 尺寸): 文件被换掉 / 尺寸修正过
    -- (说明刚才那张是按占位尺寸拉伸画的) 时键会变, 该重绘的仍然重绘。
    local painted = session.painted
    if not force and painted and painted.n == tonumber(n)
       and painted.key == painted_key(session, n) then
        return
    end

    if scroll_mode then
        -- 滚动模式下刷新占位页有两条完全不同的路, 分清楚:
        --
        -- ① 只是"图下好了" (force == false): **只重绘**。渲染键变了 DocCache 自然
        --    不命中, 占位 tile 被真图替换, 而 page_states 原样保留 => 滚动位置
        --    不动。绝不能发 PageUpdate: ReaderPaging:onPageUpdate 在滚动模式下会
        --    重建 page_states (InitScrollPageStates), 那等于"跳到这一页顶部"。
        --
        -- ② 尺寸由未知变已知 (force == true): 必须**重建**。滚动模式下一屏里每页
        --    的排版高度都是按"当时的缩放"算好存在 page_states 里的; 尺寸未知时
        --    排版用的是占位页尺寸 (屏幕), zoom 退化成 1.0 => 一页占满一屏, 连续
        --    滚动就退化成"一屏一页"。只 setZoom 不重建的话, page_states 里那些
        --    旧的 visible_area 会一直错下去 (还会按错误的区域去 blit 真图)。
        --    代价是回到这一页顶部 —— 而这一页刚才还是「加载中…」, 可以接受。
        if force then
            -- **先重算 zoom, 再重排。**
            --
            -- 首帧排版时这一页还没下载, 尺寸按占位页 (= 屏幕) 算, getZoom 于是
            -- 得到 1.0。图下好后如果只重建 page_states, 这一页就按 zoom=1.0
            -- 画在**左上角**, 右/下留白 (真机 2026-10-18: 源 B 第一页)。
            --
            -- 以前以为 InitScrollPageStates 里的 _gotoPage 会顺带触发
            -- setZoom —— 那只在"填进去的下一页页码不同"时成立。一屏只放 1 页
            -- (长条漫画按宽度铺满时很常见) 页码没变, _gotoPage 直接返回,
            -- zoom 永远停在 1.0。
            pcall(function()
                if ui.zooming and ui.zooming.setZoom then ui.zooming:setZoom() end
            end)
            local ok_event, Event = pcall(require, "ui/event")
            if ok_event and Event then
                -- 重建是**破坏性**的: onInitScrollPageStates 先把 page_states
                -- 置空再逐页填 (readerpaging.lua:679)。中途出错就会留下一张空表,
                -- 而空表是"滚动位置"的合法输入 —— 下一次 pan 的
                -- _pan_page_states_to_restore 会指向它, 之后 HandledAsSwipe
                -- 回滚时 readerpaging.lua:529 索引 nil 直接打崩阅读器
                -- (真机 2026-10-18 20:38)。所以: 出错要留痕, 而且要还原。
                local before = ui.view and ui.view.page_states
                local ok, err = pcall(function()
                    ui:handleEvent(Event:new("InitScrollPageStates"))
                end)
                local after = ui.view and ui.view.page_states
                if not ok or type(after) ~= "table" or #after == 0 then
                    logger.warn("Picayomi Stream: 重建滚动排版失败: "
                        .. tostring(err or ("page_states 为空")))
                    if type(before) == "table" and #before > 0 then
                        ui.view.page_states = before
                    end
                end
            end
        end
        pcall(function() UIManager:setDirty(ui.dialog, "partial") end)
        return
    end

    local e_ok, Event = pcall(require, "ui/event")
    if not e_ok or not Event then return end
    -- PageUpdate 会一路走进 KOReader 的缩放 / 分页 / 解码 (内存见底时在那里抛,
    -- v0.9.13 的真机闪退就是这一带的分配失败)。调用者里有两条是**定时任务**
    -- (本函数自己的重试定时器、openPage 排的 nextTick), 任务队列不兜异常 ——
    -- 抛出来就是整个 KOReader 退出。重绘失败的代价只是这一页暂时停在占位页,
    -- 用户翻页会重新触发, 不值得为它崩溃。
    local ok_update, err_update = pcall(function()
        ui:handleEvent(Event:new("PageUpdate", n))
    end)
    if not ok_update then
        logger.warn("Picayomi Stream: 第 " .. tostring(n) .. " 页重绘 (PageUpdate) 失败: "
            .. tostring(err_update))
    end
end

-- ============================================================================
-- 会话: 组装 PageStore + Scheduler + transport, 管理一话的按需取页
-- ============================================================================
local StreamSession = {}
StreamSession.__index = StreamSession

--- 创建会话
-- @param opts.source      漫画源实例
-- @param opts.images      图片列表 [{url=...}]
-- @param opts.cache_dir   本地缓存目录
-- @param opts.path        用于注册到 KOReader 的占位文件路径
function StreamSession.new(opts)
    local self = setmetatable({}, StreamSession)
    -- Explicit content type: future text/novel sessions must not inherit image actions.
    self.content_type = opts.content_type
    self.source = opts.source
    self.comic_id = opts.comic_id
    self.order = opts.order
    self.title = opts.title or ""
    -- 阅读上下文 { comic = ..., episodes = ... }，供阅读器内菜单使用
    self.context = opts.context
    self.images = opts.images or {}
    self.total = #self.images
    -- 这一话怎么读: 竖屏整页 / 条漫滚动 / 横屏旋转 (见 ui/common/view_mode.lua)。
    -- 在**创建会话时**定一次: 打开文档那一刻 (registerSession -> 文档设置) 要用它,
    -- 阅读器起来后的提示也要用它 —— 两处必须看到同一个结论。
    --
    -- 判据是**章节中段页的像素长宽比** (与源站分类无关),
    -- 由 prepareComic 在打开前量好并传进来; 量不到时退回竖屏。
    self.view_mode = opts.view_mode or ViewMode.PAGE
    self.cache_dir = opts.cache_dir
    if self.source and self.source._source_runtime then
        self.cache_dir=require("source.page_manifest").bind(self.cache_dir,self.images,self.source._extension_digest)
    end
    self.path = opts.path

    self.cancelled = false

    -- 本话的本地状态 (路径/尺寸/状态/渲染键), 纯查 —— 见 util/page_store.lua
    --
    -- 图片列表与总页数的权威在**会话**手里 (本对象), 所以注入取用函数而不是拷一份:
    -- 调用方可能整个替换 self.images (测试/换章都会), 拷副本会读到旧表。
    self.store = PageStore.new{
        get_images = function() return self.images end,
        get_total = function() return self.total end,
        cache_dir = self.cache_dir,
        -- 占位页"加载中…"与"本页加载失败"的分界: 与调度器的熔断阈值同源
        -- (见 util/page_store.lua 的状态机说明)
        retry_limit = Scheduler.DEFAULT_POLICY.failure_threshold,
        cache = {
            find = function(base) return DownloadManager.findExistingImage(base) end,
            valid = function(path) return DownloadManager.isValidImageFile(path) end,
            forget = function(path) DownloadManager.forgetImage(path) end,
            remove = function(path) os.remove(path) end,
        },
        -- 源可能升级过图片处理方式 (源 B 的解扰就是): 旧缓存必须丢弃重下,
        -- 否则会一直显示旧(且错误)的画面。
        --
        -- 这个判定是在**渲染链**上被调用的 (openPage / getUsedBBox / getFullPageHash
        -- -> PageStore:get_local), 所以源实现一旦抛异常, 就会顺着 _repaint 把整个
        -- 阅读器打崩。判不出来时保守地当作"没失效"(继续用缓存文件): 崩溃和"反复重下"
        -- 都比"显示一张可能过时的图"更糟。
        is_stale = function(path, url)
            local s = self.source
            if s == nil or s.isCachedImageStale == nil then return false end
            local ok, stale = pcall(s.isCachedImageStale, s, path, url)
            if not ok then
                logger.warn("Picayomi Stream: 缓存失效判定抛异常, 暂按未失效处理: "
                    .. tostring(stale))
                return false
            end
            return stale == true
        end,
    }

    -- 兼容别名: 既有测试/诊断直接读写这些字段 (见 test/regression_robustness.lua
    -- 与 test/simulator_smoke.lua)。别名指向 store 的同一张表, 就地增删不会失联。
    self.page_sizes = self.store.sizes
    self.page_epoch = self.store.gen
    self.failed_at = self.store.failed_at
    self.failed_reason = self.store.failed_reason
    self.loading = self.store.loading

    -- 计数器镜像 (store 是权威, 这里跟着同步, 供外部读)
    self.downloaded = self.store.downloaded
    self.consecutive_failures = self.store.consecutive_failures
    self.prefetch_disabled = self.store.prefetch_disabled

    -- 预取队列 (页码 FIFO) 与"已排了一次预取调度"的标记
    self.prefetch_queue = {}
    self.prefetch_scheduled = false

    -- 失败页的自动重试次数 (见 _schedule_retry)
    self.retry_attempts = {}

    -- 驱动 (决定"什么时候推进一步调度"; 见 ui/reader_bridge.lua)。
    -- nil 时 _kick 会懒建一个默认驱动, 所以这里不必先建。
    self.driver = nil

    -- 已经探过尺寸但探不出来的页 (见 measure_page)。没有它的话, 一张"魔数合法但头
    -- 残缺"的图会让排版链每次都重读 128KB 文件头。
    self.size_probe_failed = {}

    -- 传输层: 只发起/收割 I/O, 不含策略 (策略全在 Scheduler)。
    --
    -- 生产用 TransportWorker: 真正的 HTTP (含 DNS/TLS) 与源的图片后处理都跑在
    -- fork 出来的子进程里, 所以弱网下翻页/返回照样有响应 (见 network/transport_worker.lua)。
    -- 它自带三条回退: 源没实现 imageHeaders / 起子进程失败 / 子进程意外死亡
    -- —— 都会退到同步实现, 功能不会丢。
    --
    -- opts.transport 是给测试的注入点: L3 的手动泵模型下无法确定性地等子进程,
    -- 所以那些用例显式传 TransportBlocking (fork 路径由真机走查 + L2 协议用例覆盖)。
    -- 并发下载: 子进程里同时推进 2 个请求 (非阻塞 socket), 父进程记两条 inflight。
    -- 只对**真实 worker** 开 —— 测试注入的 TransportBlocking 是同步实现, 开并发
    -- 只会让断言里的"发起/完成"计数变得难读, 没有任何收益。
    local use_worker = (opts.transport == nil)
    self.transport = opts.transport or TransportWorker.new{
        source = self.source,
        tag = "read",
        async = true,
        max_inflight = 2,
        fix_extension = function(path) return DownloadManager.fixImageExtension(path) end,
        fallback = TransportBlocking.new{
            source = self.source,
            fix_extension = function(path) return DownloadManager.fixImageExtension(path) end,
        },
    }

    -- 唯一的决策点
    self.scheduler = Scheduler.new{
        store = self.store,
        transport = self.transport,
        wall_clock = os.time,
        current_page = 1,
        -- 与 transport 的并发上限保持一致: 调度器这边也要允许"同时发起两个",
        -- 否则队列再深也只会一次放一个出去 (policy.concurrency 是硬闸)。
        policy = use_worker and {
            concurrency = 2,
            preempt_after = 0.25,
            keep_radius = math.max(1, self:prefetch_count()),
            max_start_per_step = 2,
            max_harvest_per_step = 2,
        } or nil,
        on_ready = function(n, path, elapsed, size, post)
            self:measure_page(n, path)
            -- 缓存总量记账: 纯内存加法, 只有估计值越过 max_cache_size 时才真去遍历清理。
            -- 没有它的话, 总量上限只在**启动时**检查一次 —— 一直读、从不重启的会话里
            -- 缓存可以无限涨, 而 Kindle 的存储本来就紧张。
            DownloadManager:noteCacheBytes(size)
            DownloadManager:maybeCleanCache()
            -- 内存压力响应: 可用内存真的低时砍掉一半渲染缓存。
            --
            -- 为什么挂在这里: "一页刚落盘"是唯一既高频又**真的发生了内存变化**的时刻
            -- (解码/落盘/写盘产生的脏页都在这条链上)。KOReader 自己有同样的机制
            -- (Cache:memoryPressureCheck) 却只挂在 kopt 文档上, 图片文档永远不触发 ——
            -- 见 util/memory_guard.lua 的文件头。
            -- 函数内部自带节流 (RELIEVE_INTERVAL), 每页调一次不构成开销。
            pcall(function() MemoryGuard.instance():relieve() end)
            -- 这一页真的下来了: 清掉它的自动重试计数 (以后再失败仍然是 3 次机会)
            self.retry_attempts[n] = nil
            if self.retry_pending and self.retry_pending[n] then
                UIManager:unschedule(self.retry_pending[n]); self.retry_pending[n] = nil
            end
            if n == self.scheduler.current_page then require("ui.reader_feedback").clear(self) end
            -- 诊断: 记下每次真实下载的页码与耗时 (缓存命中不计), 便于事后看崩溃前进度。
            -- 括号里是其中**后处理**占的那一段 (源 B 解扰: 解码整图 + 逐带重排 +
            -- 重新编码, 很可能比 HTTP 还贵)。两个数字分开才能决定该修网络还是修解扰。
            local el = tonumber(elapsed) or 0
            local po = tonumber(post)
            if po and po >= 0.05 then
                if Diag.enabled then Diag.mark(string.format("page %d/%d ok %.1fs (后处理 %.1fs)",
                    n, self.total, el, po)) end
            else
                if Diag.enabled then Diag.mark(string.format("page %d/%d ok %.1fs", n, self.total, el)) end
            end
            -- 首屏就绪: 第 1 页落盘的时刻。它与上面的 "open ...: 打开阅读器…" 之差
            -- 就是"点开始到能看见图"里属于下载的那一段 (其余是图片列表请求与排版)。
            if n == 1 and not self.first_page_marked then
                self.first_page_marked = true
                if Diag.enabled then Diag.mark(string.format("open %s 第%s话: 首屏就绪 (第1页已落盘)",
                    tostring(self.comic_id), tostring(self.order))) end
            end
            refresh_page_if_current(self, n)
        end,
        on_failed = function(n, err)
            logger.warn(string.format("Picayomi Stream: 第 %d 页下载失败: %s",
                n, tostring(err)))
            self:_schedule_retry(n)
            require("ui.reader_feedback").queue(self, n, "download")
            self:refresh_failed_page(n)
        end,
    }

    mkdir_p(self.cache_dir)
    return self
end

--- 把 store 的权威状态同步到会话的镜像字段上
--
-- 熔断是单向的 (一旦停预取就不再自动恢复), 所以只做"或"不覆盖 —— 既不会把
-- 熔断状态抹掉, 也不会把外部显式置的 prefetch_disabled 抹掉。
function StreamSession:_sync_mirrors()
    self.downloaded = self.store.downloaded
    self.consecutive_failures = self.store.consecutive_failures
    if self.store.prefetch_disabled then
        self.prefetch_disabled = true
        if #self.prefetch_queue > 0 then self.prefetch_queue = {} end
    end
end

--- 推进一步调度 (收割 + 发起) 并同步状态镜像
--
-- **驱动方是 ui/reader_bridge.lua** (它决定什么时候调这里, 以及每步的 CPU 预算)。
-- 本方法只做"推进 + 记账", 不安排自己的下一次执行 —— 那是驱动层的事。
--
-- @return pending 是否还有活没干完 (驱动层据此决定要不要排下一拍)
function StreamSession:step(budget_ms)
    if self.cancelled then return false end
    local _did_work, pending = self.scheduler:step(budget_ms)
    self:_sync_mirrors()
    return pending
end

--- 注入驱动 (任何带 :tick() 的对象; 见 ui/reader_bridge.lua)
function StreamSession:set_driver(driver)
    self.driver = driver
end

--- 请求推进调度器 (非阻塞)
--
-- 没有显式接桥时懒建一个默认驱动 —— 否则"忘了接桥"会变成"静默永远不下页",
-- 这种故障在真机上极难定位。默认驱动只依赖 UIManager, 不依赖 ReaderUI。
function StreamSession:_kick()
    local driver = self.driver
    if not driver then
        driver = ReaderBridge.attach(self)
    end
    if driver then driver:tick() end
end

--- 第 n 页的文件基名 (不含扩展名)
function StreamSession:page_base(n)
    return self.store:base(n)
end

--- 第 n 页是否已在本地 (不做有效性校验)
function StreamSession:find_page(n)
    return self.store:has_local(n)
end

--- 预取页数 (读设置, 0~9; 0 = 关闭)
function StreamSession:prefetch_count()
    if MemoryGuard.instance():under_pressure() then return 0 end
    local n = tonumber(Config:get("prefetch_pages"))
    if not n then n = PREFETCH_DEFAULT end
    n = math.floor(n)
    if n < 0 then n = 0 elseif n > PREFETCH_MAX then n = PREFETCH_MAX end
    return n
end

--- 预取是否开启 (页数 0 即关闭)
function StreamSession:prefetch_on()
    return self:prefetch_count() > 0
end

--- 只取"已经在本地"的页, **绝不联网**
--
-- 供绘制链/排版链调用 (openPage / getUsedBBox): 那里同步下载会冻住整屏,
-- 所以这两条路径只能拿现成的页, 缺页时返回 nil 交给占位页 + 后台任务。
function StreamSession:local_page(n)
    return self.store:get_local(n)
end

--- 第 n 页当前处于什么状态
--
-- 同时被两处使用, 因此必须集中在一个地方判断:
--   1. 占位页的文案 ("加载中…" vs "本页加载失败，翻页重试")
--   2. DocCache 的键后缀 (见 StreamDocument:getFullPageHash)
--
-- @return "ready" 已在本地的有效图片 / "loading" 下载已排队 / "failed" 刚失败过 / "idle" 还没下
function StreamSession:page_state(n)
    return self.store:state(n)
end

--- 量出一页的真实尺寸并记下 (供排版用)。不联网, 也**不解码**。
--
-- 尺寸一律从**文件头**读 (util/image_size.lua), 理由是这条链的时序:
--   排版 (getNativePageDimensions) 早于渲染, 而 ReaderZooming:getZoom 在
--   zoom_mode="page" (本插件默认) 时**只**用 getNativePageDimensions 算 zoom
--   (readerzooming.lua:526/537)。尺寸不知道就按占位页尺寸 (屏幕大小) 排版 ——
--   整页的显示尺寸就是错的, 而这条链上没有"尺寸到齐后再算一次"的机会。
--
-- 曾经这里是 `pic.openDocument` + 取 `page.width`: 那是**整图解码**
-- (base/ffi/pic.lua:140, 漫画页实测 ~19MB)。于是"量个尺寸"要付一次全图解码的代价,
-- 后果是排版链里不敢调它、每次下载完还要在主线程上卡几十到几百毫秒。
-- 而宽高本来就在文件头的前几十字节里。
--
-- 解析失败 (不是已知格式 / 头被截断) 就**什么都不做** —— 绝不退回整图解码: 那等于把
-- 上面那个代价又搬回排版链, 而且这类文件在渲染时本来也解不出来。真正的兜底在
-- MultiImageDoc:openPage: 解码成功后会用真实页面的宽高覆盖一次。
--
-- 探不出来要**记住**(size_probe_failed): 本方法会被排版链调用 (经 ensure_size),
-- 不记住的话一张"魔数合法但头残缺"的图每次排版都要重读一遍 128KB 文件头。
function StreamSession:measure_page(n, path)
    if self.store.sizes[n] or self.size_probe_failed[n] then return end
    local w, h, fmt = ImageSize.from_file(path)
    if w and h then
        -- 顺手把**从内容嗅探**出的格式记下来: 大图守卫要靠它决定"能不能缩放解码",
        -- 而这一次文件头已经读进来了, 不必为了知道格式再读一遍。
        self.store.sizes[n] = { w = w, h = h, fmt = fmt }
    else
        self.size_probe_failed[n] = true
    end
end

--- 取第 n 页的尺寸; 没有就在本地量一次 (纯本地: stat + 读文件头)
--
-- 排版链 (getNativePageDimensions / getUsedBBox) 直接调它 —— 所以这里**不能**有任何
-- 联网或整图解码, 否则一次翻页就会冻住整屏。
function StreamSession:ensure_size(n)
    local sz = self.store.sizes[n]
    if sz then return sz end
    local path = self:local_page(n)
    if not path then return nil end
    self:measure_page(n, path)
    return self.store.sizes[n]
end

--- 请求下载第 n 页 (**非阻塞**): 只把任务排进调度器, 立刻返回
--
-- **这是唯一的"按需下载"入口。** openPage 位于 KOReader 的绘制链内部,
-- 在那里同步下载整屏就冻在"翻页请求"上 (慢网下就是"点了没反应")。
-- 改成: 绘制链里立刻返回一张占位页, 下载由调度器在事件循环里推进;
-- 下载完成后由 refresh_page_if_current 触发重绘, 占位页被真实页替换。
--
-- 去重/冷却/在途判断全在 scheduler:request 里 (它才是决策点)。
function StreamSession:request_page(n)
    if self.cancelled then return end
    n = tonumber(n)
    if not n or n < 1 or n > self.total then return end
    if self.store:has_local(n) then return end

    -- 入队成功 => 状态立刻变 loading, 占位页显示"加载中…"; 然后开始推调度器。
    if self.scheduler:request(n, Scheduler.P_CURRENT) then
        self:_kick()
        require("ui.reader_feedback").queue(self, n, "connectivity")
    end
end

function StreamSession:refresh_failed_page(n)
    if self.cancelled or n ~= self.scheduler.current_page then return end
    if self.failure_refresh then UIManager:unschedule(self.failure_refresh) end
    self.failure_refresh = function()
        self.failure_refresh = nil
        if not self.cancelled then refresh_page_if_current(self, n, nil, true) end
    end
    UIManager:scheduleIn(0.1, self.failure_refresh)
end

--- 失败页自动重试的等待时间 (秒)
--
-- 必须**大于**调度器的 cooldown (15 秒), 否则定时器到点时 request 仍被冷却挡掉,
-- 而这里不会再排第二次 —— 那一页就永远停在失败状态了。用 17 秒留出
-- os.time 的整秒粒度余量。
StreamSession.RETRY_DELAY = 17

--- 同一页最多自动重试几次 (之后只保留"翻页重试"这条人工路径)
--
-- 有上限的理由: 断网时定时器会一直排下去, 每 17 秒发一次请求既费电, 也会
-- 反复 preventStandby 让设备睡不着。3 次足够扛过地铁/电梯这种短时断网。
StreamSession.RETRY_MAX = 3

--- 给失败页排一次"到冷却结束再试"的定时器
--
-- **为什么需要**: 失败页有 15 秒冷却, 而唯一会重新请求它的路径是"用户翻页"
-- (ui/reader.lua 的 ensurePagesCached 清冷却 + request_page)。用户停在原地时,
-- 没有任何东西会再试一次 —— 真机日志 (2026-10-17 13:42:58~13:44:34) 里第 1 页
-- 下载失败后一直显示"加载中…", 直到用户翻走再翻回来才落盘, 中间空了 96 秒。
--
-- 三条边界:
--   * 只重试**用户正看着的那一页** (current_page): 翻走了就不该再为旧页占带宽;
--   * 次数有上限 (RETRY_MAX), 见上;
--   * 冷却由调度器自己判 (request 会挡), 这里只负责"到期后再问一次" ——
--     不 clear_failure, 否则等于绕过了那条挡住绘制链重试风暴的闸。
function StreamSession:_schedule_retry(n)
    if self.cancelled then return end
    if self.store.non_retryable and self.store.non_retryable[n] then return end
    n = tonumber(n)
    if not n or n ~= self.scheduler.current_page then return end

    self.retry_pending = self.retry_pending or {}
    if self.retry_pending[n] then return end
    self.retry_attempts[n] = (self.retry_attempts[n] or 0) + 1
    if self.retry_attempts[n] > StreamSession.RETRY_MAX then return end

    self.retry_pending[n] = function()
        self.retry_pending[n] = nil
        if self.cancelled then return end
        -- 定时器触发时再判一次: 这 17 秒里用户可能已经翻走 / 已经换章
        -- 这是定时任务, 任务队列不兜异常; 抛出来 = 阅读中途整个 KOReader 退出,
        -- 而这里要做的只是"再试一次", 失败了最多是这一页还没加载出来。
        local ok, err = pcall(function()
            if self.scheduler.current_page ~= n then return end
            if self.store:has_local(n) then return end
            self:request_page(n)
        end)
        if not ok then
            logger.warn("Picayomi Stream: 失败页自动重试出错 (p" .. tostring(n) .. "): " .. tostring(err))
        end
    end
    UIManager:scheduleIn(StreamSession.RETRY_DELAY, self.retry_pending[n])
    return true
end

--- 第 n 页是否处在失败冷却期
--
-- 冷却结束只放开"允许再发一次网络请求"; failed_reason 会保留到真正下载成功,
-- 这样占位页能一直显示"本页加载失败，翻页重试", 而不是过 15 秒又变回"加载中…"
-- 却没有任何东西在加载。
function StreamSession:in_failure_cooldown(n)
    return self.store:in_cooldown(n, os.time(), self.scheduler.policy.cooldown)
end

--- 清掉某页的失败冷却 (供"用户主动翻页"这条路径调用 -> 允许重试一次)
function StreamSession:clear_failure(n)
    if self.retry_pending and self.retry_pending[n] then
        UIManager:unschedule(self.retry_pending[n]); self.retry_pending[n] = nil
    end
    self.scheduler:clear_failure(n)
    if self.memory_blocked and self.memory_blocked[n] then
        self.memory_epoch[n] = (self.memory_epoch[n] or 0) + 1
        self.memory_blocked[n] = nil
        self.memory_retry_counts[n] = nil
    end
end

-- Temporary memory pressure must not cache a refusal for the lifetime of the
-- file. Recheck without decoding or downloading, and redraw only after the
-- normal planner accepts it. Timers are bounded and always yield to input.
function StreamSession:wait_for_memory(n, can_retry)
    self.memory_epoch = self.memory_epoch or {}
    self.memory_blocked = self.memory_blocked or {}
    self.memory_retry_counts = self.memory_retry_counts or {}
    self.memory_blocked[n] = true
    if self.cancelled or (self.memory_retry_counts[n] or 0) >= 3 then return end
    if self.memory_wait and self.memory_wait.page == n then return end
    self.memory_wait = {page=n, can_retry=can_retry, checks=0}
    if self.memory_retry then return end
    self.memory_retry = function()
        local wait = self.memory_wait
        if self.cancelled or not wait then self.memory_retry=nil; return end
        wait.checks = wait.checks + 1
        local ok, ready = pcall(wait.can_retry)
        if ok and ready then
            self.memory_wait, self.memory_retry = nil, nil
            self.memory_epoch[wait.page] = (self.memory_epoch[wait.page] or 0) + 1
            self.memory_retry_counts[wait.page] = (self.memory_retry_counts[wait.page] or 0) + 1
            self.memory_blocked[wait.page] = nil
            refresh_page_if_current(self, wait.page)
        elseif wait.checks < 15 then
            UIManager:scheduleIn(2, self.memory_retry)
        else
            self.memory_wait, self.memory_retry = nil, nil
        end
    end
    UIManager:scheduleIn(2, self.memory_retry)
end

--- 确保第 n 页在本地 (**会阻塞**, 缺页时同步下载)
--
-- **只在事件循环里调用** (打开前的预热 / 预取 / 兼容旧的同步调用点), 绝不要在
-- 绘制链里调用 —— 那里同步下载会冻住整屏。绘制链走 local_page + 占位页。
--
-- **本函数绝不能碰 UI。** 绘制过程中弹提示会让 _repaint 重入并无限递归
-- (实测以 "./luajit: stack overflow" 打崩程序)。失败由占位页文案表达。
--
-- @return: 本地文件路径 或 nil, err
function StreamSession:fetch_page(n)
    if self.cancelled then return nil, "已取消" end
    n = tonumber(n)
    if not n or n < 1 or n > self.total then
        return nil, "页码超出范围: " .. tostring(n)
    end
    local img = self.images[n]
    if not img or not img.url then return nil, "缺少图片地址" end

    local existing = self:local_page(n)
    if existing then return existing end

    -- 刚失败过的页: 直接失败返回, 不再发起网络请求 (冷却由调度器判定)
    if self:in_failure_cooldown(n) then
        return nil, self.store.failed_reason[n] or "刚刚失败过"
    end

    -- 同步跑完这一页: 入队 -> 一直 step 到没有活。绝不在绘制链里走到这里。
    self.scheduler:request(n, Scheduler.P_CURRENT)
    self.scheduler:run_until_idle(8)
    self:_sync_mirrors()

    local path = self.store:get_local(n)
    if path then return path end
    return nil, self.store.failed_reason[n] or "下载失败"
end

--- 后台预取 (从 from 起向后, 含 from 本身)
--
-- 提前几页**由设置决定** (阅读设置 → 提前加载页数, 0 = 关闭); `count` 只是一个
-- 可选上限, 不能突破设置 —— 否则"设置成 0"会被某个传了具体页数的调用点绕过。
-- @param from:  从第几页开始 (含)
-- @param count: 可选上限
function StreamSession:prefetch(from, count)
    if self.cancelled or self.prefetch_disabled then return end

    local ahead = self:prefetch_count()
    if count and count < ahead then ahead = count end
    if ahead <= 0 then return end

    local last = math.min(from + ahead - 1, self.total)
    for i = from, last do
        self:_queue_prefetch(i)
    end
    self:_schedule_prefetch()
end

--- 按阅读位置与方向预取 (阅读期真正走的入口)
--
-- dir=+1 向后: [n+1, n+K] —— "马上要画的", 先排进队列;
-- dir=-1 回看: [n-1, n-K] —— "顺手补", 排在向后窗口之后。
-- 已在本地 / 越界的页由 _queue_prefetch 直接跳过 (回看因此天然零新请求)。
--
-- 方向**只能从翻页入口拿到**: PageUpdate 不带方向, 且程序性跳转也发它
-- (readerpaging.lua:1143/1161/625/641/1123)。
function StreamSession:prefetch_around(page, dir)
    if self.cancelled or self.prefetch_disabled then return end
    page = tonumber(page)
    if not page then return end
    dir = ((tonumber(dir) or 1) >= 0) and 1 or -1

    local ahead = self:prefetch_count()
    if ahead <= 0 then return end

    for i = 1, ahead do
        self:_queue_prefetch(page + dir * i)
    end
    self:_schedule_prefetch()
end

--- 清掉"已经落在行进方向身后"的预取条目
--
-- 预取队列是 FIFO, 只追加、从不回看。方向一反转 (或跳页), 之前排进去的页就
-- 变成了反方向的噪音: 它们还在队头, 而队列每 0.2s 才放一页进调度器 ——
-- 结果新方向的那几页要等旧方向全部放完才排得上 (调度器内部再排序也救不回来,
-- 因为那些页还没进调度器)。
--
-- 判据用**严格的不等号**: 当前页自己由 request_page 以 P_CURRENT 负责,
-- 不需要留在预取队列里。
function StreamSession:_prune_prefetch(page, dir)
    if #self.prefetch_queue == 0 then return end
    dir = ((tonumber(dir) or 1) >= 0) and 1 or -1
    local kept = {}
    for _i, n in ipairs(self.prefetch_queue) do
        -- 不能用 and/or 三元式: 前进方向且 n <= page 时前半句是 false,
        -- Lua 会接着算 or (n < page), 结果把身后的页也留下了。
        local ahead
        if dir > 0 then ahead = n > page else ahead = n < page end
        if ahead and math.abs(n - page) <= self:prefetch_count() then
            kept[#kept + 1] = n
        end
    end
    table.sort(kept, function(a, b) return math.abs(a - page) < math.abs(b - page) end)
    self.prefetch_queue = kept
end

--- 把一个页码排进预取队列 (去重 + 跳过越界/已在本地)
function StreamSession:_queue_prefetch(n)
    if not n or n < 1 or n > self.total then return end
    if self.store:has_local(n) then return end
    for _j, q in ipairs(self.prefetch_queue) do
        if q == n then return end
    end
    table.insert(self.prefetch_queue, n)
end

--- 用户翻页: 更新当前页并按其方向预取
--
-- 只影响"预取方向/窗口", 不在这里下载 (下载交给调度器, 见 request_page)。
function StreamSession:on_page_turn(page, dir)
    if self.cancelled then return end
    page = tonumber(page)
    if not page then return end
    -- 方向要一起交给调度器: 它的排序键里 dist 是对称的, 不传方向就分不出
    -- "刚翻过的 n+1" 与 "马上要看的 n-1" (两者距离都是 1)。
    if self.scheduler.policy.keep_radius then
        self.scheduler.policy.keep_radius = math.max(1, self:prefetch_count())
    end
    self.scheduler:set_current_page(page, dir)
    -- 方向变了, 队列里"已经落在身后"的预取条目就没意义了 —— 清掉, 否则它们
    -- 会占着 FIFO 的队头, 每 0.2s 才放一页进调度器, 把新方向的页挤到后面。
    self:_prune_prefetch(page, dir)
    self:prefetch_around(page, dir)
    -- 诊断: 翻页是整条预取链的起点。没有这一行, 事后只能从"page N ok"的
    -- 时间差反推用户什么时候翻的页 (diag.log 里翻页与落盘混在一起)。
    if Diag.enabled then Diag.mark(string.format("turn p%d dir%s", page, tostring(dir or "?"))) end
end

--- HintPage: 只作"向前补页"的补充信号
--
-- **它不是用户翻页信号** —— ReaderView 每次画页都会发 (含换章 / 恢复位置 /
-- 程序性重绘), 所以只补前方窗口, 不改变"当前页"。
function StreamSession:on_hint_page(pageno)
    if self.cancelled then return end
    pageno = tonumber(pageno)
    if not pageno or pageno < 1 then return end
    -- HintPage 永远指"正在画的那一页的**下一页**" (readerhinting.lua:15-19,
    -- DHINTCOUNT=1), 也就是**向前**。用户正在回看时它是反方向的噪音:
    -- 会把刚翻过的那页塞进预取队列, 与"下一张"抢带宽。
    if (self.scheduler.direction or 1) < 0 then return end
    self:prefetch_around(pageno, 1)
end

--- 每隔 PREFETCH_DELAY 从预取队列取一页交给调度器
--
-- 之所以不一次全塞进调度器: 预取是"顺手补", 不该和用户当前页抢带宽;
-- 一次一页 + 调度器的优先级/并发度, 保证用户当前页永远先下。
function StreamSession:_schedule_prefetch()
    if self.prefetch_scheduled or self.cancelled or self.prefetch_disabled
       or not self:prefetch_on() then
        return
    end
    self.prefetch_scheduled = true

    UIManager:scheduleIn(PREFETCH_DELAY, function()
        self.prefetch_scheduled = false
        if self.cancelled or self.prefetch_disabled or not self:prefetch_on() then return end

        local n = table.remove(self.prefetch_queue, 1)
        if not n then return end

        -- 定时任务: 任务队列不兜异常, 抛出来 = 阅读中途整个 KOReader 退出。
        -- 预取只是"顺手补", 一页没补成最多是翻到时现下 —— 不值得为它崩溃。
        -- 出错后仍要排下一拍: 队列每次已弹出一页, 不会死循环; 不排的话一次异常
        -- 就让后面所有页的预取都停掉。
        local ok, err = pcall(function()
            -- 诊断: 预取队列的"放出"是判断预取到底有没有跑的唯一证据。
            -- 三种结果分开记: 已有本地文件 / 已交给调度器 / 调度器拒收 (在途、冷却、
            -- 已排过队) —— 第三种如果连续出现, 就是"翻页总要现下"的直接原因。
            local requested = false
            local has = self.store:has_local(n)
            if not has then
                requested = self.scheduler:request(n, Scheduler.P_HINT)
                if requested then self:_kick() end
            end
            -- 拒收要分清原因: "在途/已排队"是正常的去重 (说明它在别处推进),
            -- 只有"已排队却没人推进"才是 bug —— 那种情况由 ReaderBridge 的看门狗兜。
            local why
            if has then
                why = "已有"
            elseif requested then
                why = "已入队"
            elseif self.scheduler.inflight and self.scheduler.inflight[n] then
                why = "在途"
            else
                local inq = false
                for _i, q in ipairs(self.scheduler:queued_pages()) do
                    if q == n then inq = true break end
                end
                why = inq and "已排队" or "被拒"
            end
            if Diag.enabled then Diag.mark(string.format("prefetch p%d 剩%d %s", n, #self.prefetch_queue, why)) end
        end)
        if not ok then
            logger.warn("Picayomi Stream: 预取定时器出错 (p" .. tostring(n) .. "): " .. tostring(err))
        end
        self:_schedule_prefetch()
    end)
end

--- 已下载页数 / 总页数
function StreamSession:progress()
    return self.store:progress()
end

function StreamSession:cancel()
    self.cancelled = true
    require("ui.reader_feedback").clear(self)
    for _, task in pairs(self.retry_pending or {}) do UIManager:unschedule(task) end
    self.retry_pending = {}
    if self.failure_refresh then UIManager:unschedule(self.failure_refresh); self.failure_refresh = nil end
    self.prefetch_queue = {}
    self.scheduler:cancel_all()
    if self.memory_retry then UIManager:unschedule(self.memory_retry); self.memory_retry = nil end
    self.memory_wait = nil
    if self.release_start_guard then self.release_start_guard() end
    if self.release_downloads then self.release_downloads(); self.release_downloads = nil end
end

--- 关闭会话, 但**不等待**下载子进程被回收 —— 只给"进程正在退出"的路径用
--
-- 与 cancel() 的唯一区别: cancel() 会一路走到 Fork:kill() 的**阻塞** waitpid
-- (network/subprocess_fork.lua)。退出/重启/关机时子进程可能正卡在一个 15 秒的
-- DNS 解析里 —— 阻塞等它就是把"退出卡顿"原样留着。队列/在途/"已排队"标记照样
-- 清干净, 只是不做阻塞回收 (孤儿进程由 init 收养, 无害)。
function StreamSession:shutdown()
    self.cancelled = true
    require("ui.reader_feedback").clear(self)
    for _, task in pairs(self.retry_pending or {}) do UIManager:unschedule(task) end
    self.retry_pending = {}
    if self.failure_refresh then UIManager:unschedule(self.failure_refresh); self.failure_refresh = nil end
    self.prefetch_queue = {}
    self.scheduler:cancel_all(true)
    if self.memory_retry then UIManager:unschedule(self.memory_retry); self.memory_retry = nil end
    self.memory_wait = nil
    if self.release_start_guard then self.release_start_guard() end
    if self.release_downloads then self.release_downloads(); self.release_downloads = nil end
end

-- ============================================================================
-- 多图文档: 实现 ffi/pic 的 Document 接口, 但按需取页
-- ============================================================================
local MultiImageDoc = {}
MultiImageDoc.__index = MultiImageDoc

function MultiImageDoc.new(session)
    return setmetatable({ session = session }, MultiImageDoc)
end

function MultiImageDoc:getPages() return self.session.total end
function MultiImageDoc:getToc() return {} end
function MultiImageDoc:getCacheSize() return 0 end
function MultiImageDoc:cleanCache() end

--- 释放当前持有的子文档
--
-- **必须显式 close, 不能指望 Lua GC。**
-- pic.openDocument 会把整张图解码进 image_bb (漫画页实测约 19MB), 而 KOReader
-- 的 LuaJIT GC 是惰性的、Kindle 可用内存又只有 ~130MB —— 每翻一页丢一份解码图,
-- 十几页就耗尽内存, 被内核 OOM-killer 强杀 (crash.log 里只有 "Killed"、没有 traceback)。
-- 真机 diag.log 实测: RSS 17 秒内从 52MB 涨到 146MB 后被 SIGKILL。
function MultiImageDoc:releaseSub()
    if self.current_sub then
        pcall(function() self.current_sub:close() end)
        self.current_sub = nil
    end
end

function MultiImageDoc:close()
    self:releaseSub()
end

--- "过大"占位页的文案
--
-- 必须让用户看懂两件事: 为什么这页不是图, 以及**接下来还能翻页**。
-- 旧实现遇到画不出的页只画一片空白, 用户分不清"在加载 / 加载失败 / 这页本来就是白的",
-- 更看不出是被跳过了。文案单行显示 (RenderText 不处理换行), 所以尽量短。
-- @param info 守卫的 plan (或退化时的等价表): { reason=, w=, h=, file_size= }
local function too_large_text(info)
    local reason = info and info.reason
    if reason == "file_too_large" then
        return _("图片文件过大，已跳过") .. "（" .. human_size(info.file_size) .. "）"
    elseif reason == "scale_failed" then
        return _("图片过大，缩小解码失败")
    elseif reason == "memory_budget" then
        local dims = info.w and info.h and ("（" .. info.w .. "×" .. info.h .. "）") or ""
        return _("可用内存不足，暂时无法显示") .. dims
    end
    -- format_unsupported (以及任何未知原因): 说清尺寸, 这是"不能缩"的依据
    if info and info.w and info.h then
        return _("内存预算不足，无法缩小显示") .. "（" .. info.w .. "×" .. info.h .. "）"
    end
    return _("无法安全解码此图片")
end

--- 构造一张"占位页": 白底 + 居中文字
--
-- 用屏幕尺寸而不是 1x1 空白: 1x1 的 tile 只有一个像素, 画不下任何字。
-- 文案由页面状态决定 —— "加载中…" / "本页加载失败，翻页重试" / "图片过大，已跳过"。
-- (旧实现返回纯空白页, 用户分不清"在加载" / "加载失败" / "这页本来就是白的")
-- @param state: "loading" | "failed" | "too_large"
-- @param info: 仅 state=="too_large" 时需要 (守卫的判定结果, 用来拼文案)
--- 取页面状态的兼容入口
-- 生产 session 有 page_state; 旧测试桩可能只有 store, 甚至两者都没有。
-- 拿不到时保守返回 "loading" —— 比误报"加载失败"安全 (用户会白等, 但不会
-- 被误导去翻页重试)。
local function current_page_state(session, n)
    if session.page_state then return session:page_state(n) end
    if session.store and session.store.state then return session.store:state(n) end
    return "loading"
end

local function placeholder_page(state, info)
    local dims = placeholder_dims()
    local w, h = dims.w, dims.h
    local text
    if state == "too_large" then
        text = too_large_text(info)
    elseif state == "processing_failed" then
        text = info or _("图片处理失败，请更新漫画源后重试")
    elseif state == "failed" then
        text = _("本页加载失败，翻页重试")
    else
        text = _("加载中…")
    end

    local page = {
        width = w, height = h, is_placeholder = true, placeholder_state = state,
        -- 文案也挂出来: 它是"用户看到什么"的唯一可断言处 (渲染结果截图不可断言),
        -- 离线用例据此钉住"过大"页确实写明了原因 (见 test/regression_robustness.lua)。
        placeholder_text = text,
        getSize = function() return w, h end,
        getUsedBBox = function() return 0, 0, w - 1, h - 1 end,
        close = function() end,
    }

    -- 签名与 pic 的页一致: draw(dc, bb, w, h, mode) —— bb 就是本页的 tile,
    -- 第 3/4 个参数是目标宽高 (见 document.lua:514 的调用), 不是坐标。
    page.draw = function(_self, _dc, bb, _w, _h)
        bb:fill(Blitbuffer.COLOR_WHITE)
        local bw, bh = bb:getWidth(), bb:getHeight()
        local face = Font:getFace("cfont", PLACEHOLDER_FONT_SIZE)
        local text_w = RenderText:sizeUtf8Text(0, nil, face, text, true, false).x
        -- 基线算法同 ui/widget/textwidget.lua:113-114 (按 freetype 的 ascender 居中)
        local face_height, face_ascender = face.ftsize:getHeightAndAscender()
        local baseline = math.floor((bh - math.ceil(face_height)) / 2)
            + math.floor(face_ascender + 0.5)
        RenderText:renderUtf8Text(bb, math.floor((bw - text_w) / 2), baseline,
            face, text, true, false, Blitbuffer.COLOR_BLACK)
    end

    return page
end

--- 把 source_bb 缩放到 target_bb 的尺寸并贴上去。
--
-- 为什么不用 page:draw 里原本的 bb:scale():
--   1) 清晰度: KOReader 自己写明它是 "very simple nearest neighbour scaling"
--      (base/ffi/blitbuffer.lua:1441)。放大 -> 块状锯齿; 缩小 -> 网点/细线上出
--      摩尔纹和噪点。漫画正是这两种情况的高发区 (源图 800px 或 2000px, 屏幕 1236px)。
--   2) 速度: bb:scale 是 Lua 逐像素循环, 每页固定 new_w*new_h 次 (1236*1648 ≈ 2M),
--      **与原图大小无关** —— 每翻一页都要付这笔固定开销, 而 Kindle 的 CPU 跑
--      LuaJIT 逐像素远不如跑 MuPDF 的 C 循环。
--   MuPDF 1.27.2 的 simple 核为 1-3x²+2x³ (0≤x<1), 缩小时扩大支撑域,
--   且 8bpp 灰度原生支持 (走 fz_device_gray, 不会转成 RGB 把内存涨上去)。
--
-- 回退: MuPDF 不可用/抛错时退回 bb:scale —— 宁可变钝, 不能整页画不出来。
local RenderImage  -- 懒加载: 只有真的要画一页时才 require, 不拖插件加载
local function get_renderimage()
    if RenderImage == nil then
        local ok, mod = pcall(require, "ui/renderimage")
        RenderImage = ok and mod or false
    end
    return RenderImage or nil
end

local function blit_scaled(source_bb, target_bb, dc, logical_w, logical_h, offset_x, offset_y)
    local w, h = target_bb:getWidth(), target_bb:getHeight()
    local RenderImage_mod = get_renderimage()
    -- Document:renderPage falls back to a viewport when a full page cannot fit
    -- its cache. Honor that rectangle instead of squeezing the entire image
    -- into it. Both the borrowed viewport and scaling come from KOReader.
    if dc and dc:getRotate()==0 and logical_w and logical_h then
        local zoom=dc:getZoom()
        local full_w,full_h=logical_w*zoom,logical_h*zoom
        local ox,oy=offset_x or 0,offset_y or 0
        if full_w>0 and full_h>0 and (ox~=0 or oy~=0 or w<math.floor(full_w) or h<math.floor(full_h)) then
            local sw,sh=source_bb:getWidth(),source_bb:getHeight()
            local x0=math.max(0,math.floor(ox*sw/full_w))
            local y0=math.max(0,math.floor(oy*sh/full_h))
            local x1=math.min(sw,math.ceil((ox+w)*sw/full_w))
            local y1=math.min(sh,math.ceil((oy+h)*sh/full_h))
            target_bb:fill(Blitbuffer.COLOR_WHITE)
            if x1<=x0 or y1<=y0 then return end
            local view=source_bb:viewport(x0,y0,x1-x0,y1-y0)
            local dx,dy=math.floor(x0*full_w/sw)-ox,math.floor(y0*full_h/sh)-oy
            local rw,rh=math.max(1,math.ceil(x1*full_w/sw)-math.floor(x0*full_w/sw)),
                math.max(1,math.ceil(y1*full_h/sh)-math.floor(y0*full_h/sh))
            local ok,scaled
            if RenderImage_mod then
                ok,scaled=pcall(RenderImage_mod.scaleBlitBuffer,RenderImage_mod,view,rw,rh,false)
            end
            if not ok or not scaled then scaled=view:scale(rw,rh) end
            target_bb:blitFrom(scaled,dx,dy,0,0,rw,rh)
            if scaled~=view then scaled:free() end
            view:free()
            return
        end
    end
    if RenderImage_mod then
        -- free_orig_bb = false: source_bb 归文档所有 (PicPage.image_bb 或 scaled_sub
        -- 的 bb), 由各自的 close 释放 —— 这里绝不能顺手 free 别人的内存。
        local ok, scaled = pcall(RenderImage_mod.scaleBlitBuffer, RenderImage_mod,
            source_bb, w, h, false)
        if ok and scaled then
            target_bb:blitFullFrom(scaled, 0, 0)
            if scaled ~= source_bb then scaled:free() end
            return
        end
        logger.warn("Picayomi Stream: MuPDF 缩放失败, 回退最近邻:", tostring(scaled))
    end

    local scaled = source_bb:scale(w, h)
    target_bb:blitFullFrom(scaled, 0, 0)
    scaled:free()
end

--- 构造一个"解码器已经缩好"的页 (形状对齐 pic 的 page / document)
--
-- 为什么需要它: 缩放解码拿到的是一张**现成的 BlitBuffer**, 不再是"一个能 openPage
-- 的文档"。而渲染链对 page 的全部要求只有两条 (document.lua:514-516):
--     page:draw(dc, tile.bb, size.x, size.y, render_mode)   然后   page:close()
-- (placeholder_page 已经证明"非 pic 的合成 page"完全可用。)
--
-- 结构刻意与 pic 对齐 (PicPage:close 是空操作, 内存归**文档**的 close 释放):
-- 这样放进 self.current_sub 之后, 现有的 MultiImageDoc:releaseSub 就会统一 close 掉,
-- **不新增任何释放路径** —— 少一条释放路径就少一类"翻几页就 OOM"的隐患。
-- @param bb 已经缩放解码好的 BlitBuffer
-- @param w,h **原图**尺寸 (不是 bb 的尺寸; 排版/zoom 要按原图比例算)
local function scaled_sub(bb, w, h)
    local sub = { width = w, height = h }

    function sub:close()
        if bb then
            bb:free()
            bb = nil
        end
    end

    function sub:openPage()
        local page = {
            width = w, height = h,
            -- 与 PicPage:getSize 一致 (document.lua:146 会带 dc 调它)
            getSize = function(_self, dc)
                local zoom = (dc and dc:getZoom()) or 1
                return w * zoom, h * zoom
            end,
            -- 与 PicPage:getUsedBBox 一致
            getUsedBBox = function() return 0.01, 0.01, -0.01, -0.01 end,
            -- 空操作: 内存归 sub:close (与 PicPage:close 一致)
            close = function() end,
        }
        -- 与 PicPage:draw 的职责相同 (把已解码的图缩到 tile 尺寸再整块贴上),
        -- 但缩放走 blit_scaled 的高质量路径 —— 见该函数的说明。
        page.draw = function(_self, dc, target_bb, offset_x, offset_y)
            blit_scaled(bb, target_bb, dc, w, h, offset_x, offset_y)
        end
        return page
    end

    return sub
end

--- 这一页的解码预算 (字节)
--
-- 固定 32MB 的闸门只管"这张图本身会不会太大", 管不了"设备此刻还剩多少"。
-- 真机 crash.log (2026-10-18 03:57:09):
--     ./luajit: ./ffi/blitbuffer.lua:2360: cannot allocate bb copy buffer
--     ./ffi/webp.lua:95 getFrameImage -> ./ffi/pic.lua:286 openPage
--     -> plugins/picayomi.koplugin/ui/stream_reader.lua:1193 openPage
--     -> document.lua:514 renderPage -> ... -> UIManager:_repaint
-- 也就是: 可用内存只剩 41MB 时解一张 1444x2048 的 webp (11.8MB), getFrameImage
-- 还会**再复制一份** -> malloc 失败 -> assert -> 整个 KOReader 退出。
-- 预算跟着可用内存走 (只给 1/3)，不再以 32MiB 封顶。内存不足不降低画质。
--
-- @return budget 字节
local function decode_budget()
    return MemoryGuard.instance():decode_budget()
end

--- 这一页有没有"解码后要在内存里做的变换" (例如源 B 的分带还原)
--
-- 返回描述符 + 图片地址; 没有就 nil。地址要一起带出来: 变换函数需要它来算
-- 分带数, 而 store 里的 images 表是唯一知道"第 n 页对应哪个 URL"的地方。
--
-- 为什么放在渲染期而不是下载后 (见 source/base.lua 的 imageRenderPost):
-- 下载后做只能落盘, 而落盘要重新编码一张照片 —— 真机实测 3.5 秒/页,
-- 比变换本身贵两个数量级。
local function render_post_for(session,n)
    local images=session.store.page_images and session.store:page_images()
    local image=images and images[n]
    if image and image.processing_error then return nil,nil,image.processing_error end
    if image and image.processing then return image.processing.render,image.url end
    local source=session.source
    if not (source and source.imageRenderPost and image and image.url) then return nil end
    local ok,desc=pcall(source.imageRenderPost,source,image.url)
    if not ok then return nil,nil,"图片处理信息加载失败" end
    return desc,image.url
end

-- Success transfers ownership to the output; failure leaves the input owned by
-- the caller. A failed required transform must never display the original.
local function apply_render_post(desc,url,bb)
    if not desc or not bb then return bb end
    if desc.digest then return require("source.processors").render(desc,bb,url) end
    local ok,out=pcall(function()
        local mod=require(desc.module)
        return mod[desc.fn](bb,desc.context or url)
    end)
    if not ok or not out then return nil,"图片渲染处理失败" end
    if out~=bb then bb:free() end
    return out
end

--- 打开第 n 页
--
-- **绝不在这里下载。** 本方法在 _repaint/paintTo -> renderPage 内部被调用:
--   - 同步下载 -> 整屏冻在翻页请求上 (慢网下就是"点了没反应");
--   - 弹提示/请求重绘 -> _repaint 重入, 无限重绘。
-- 所以缺页时只"排队下载"并立刻返回一张占位页; 下载完成后由
-- refresh_page_if_current 发 PageUpdate 把占位页换成真实页。
--
-- 这里还多了一道**大图守卫** (util/image_guard.lua): 解码一张 w*h*4 的图会一次分配
-- 几十到几百 MB, 在 Kindle 上会被内核 OOM killer 直接 SIGKILL —— 而且 overcommit
-- 让 pcall 接不住 (calloc 返回成功, 等解码器真去写像素时才被杀)。
-- 这是全项目**唯一真的要解码一张图**的地方, 也就是唯一能拦住它的地方。
function MultiImageDoc:openPage(n)
    local t0 = Diag.enabled and now_seconds() or 0
    -- 绘制这一刻用的尺寸 (正常排版链已经量好; 量不出来时是占位页尺寸)。
    -- 留一份快照: 解码成功后 store.sizes 会被真实宽高覆盖, 而"刚才画出来的是
    -- 按哪个尺寸排的"只能靠它判断 —— 见 refresh_page_if_current 的跳过判据。
    local sz_at_paint = self.session.store.sizes[n]

    --- 收口: 记下"屏幕上这一页画的是什么", 慢渲染留一行诊断
    -- 每个返回点都必须经过它 —— 少一处就会让那一类页面在下载完成时被
    -- 误判成"已经画好了", 于是永远停在占位页。
    local function finish(page, label)
        if page.is_placeholder and (page.placeholder_state == "too_large" or page.placeholder_state == "processing_failed") then
            require("ui.reader_feedback").queue(self.session, n, "display", page.placeholder_text)
        elseif page.is_placeholder and self.session.store.failed_reason and self.session.store.failed_reason[n] then
            require("ui.reader_feedback").queue(self.session, n, "download")
        end
        self.session.painted = {
            n = n,
            key = render_key(self.session, n) .. "|"
                .. (sz_at_paint and (sz_at_paint.w .. "x" .. sz_at_paint.h) or "?"),
        }
        local ms = Diag.enabled and ((now_seconds() - t0) * 1000) or 0
        if ms >= RENDER_SLOW_MS then
            if Diag.enabled then Diag.mark(string.format("render p%d %.0fms (%s)", n, ms, label)) end
        end
        return page
    end

    local path = self.session:local_page(n)
    -- 上一页已经画进 DocCache, 原始解码缓冲可立即释放。
    -- 必须在读取可用内存、制定新页预算之前释放, 缺页也不能留着它。
    self:releaseSub()
    if not path then
        self.session:request_page(n)
        return finish(placeholder_page(current_page_state(self.session, n)), "loading")
    end

    -- 守卫的输入全部是"已经知道的事实": 尺寸与格式来自文件头 (measure_page),
    -- 文件大小一次 stat。**都不解码**。
    local sz = self.session.store.sizes[n]
    -- 这一页解码后要不要再做一次内存重排 (源 B 解扰)。
    --
    -- 重排会同时持有源和结果。JPEG 的旧模型按 4 字节/像素预算,
    -- 已覆盖两份灰度输出; native PNG 按实际通道数预算, 必须显式计入复制。
    local render_post, post_url, post_error = render_post_for(self.session, n)
    if post_error then return finish(placeholder_page("processing_failed",post_error),"processing_failed") end
    -- 第三个输入是**屏幕尺寸**: 一页最终只画到屏幕上, 比屏幕大得多的图按 1/2
    -- 解码就够 (解码量降到 1/4)。这是纯"省时间"的决策, 与预算闸相互独立。
    local budget = MemoryGuard.instance():prepare_decode()
    -- WebP 包含整帧复制, 渲染后处理也可能持有两份像素缓冲。
    local fmt = (sz and sz.fmt) or format_from_path(path)
    local copy_factor = (ImageGuard.normalize_format(fmt) == "webp") and 2 or 1
    local color = self.color == true
    if fmt == "webp" and not color then copy_factor = 1.25 end
    if render_post and (fmt == "png" or color) then copy_factor = math.max(copy_factor, 2) end
    local display_w, display_h = CanvasContext:getWidth(), CanvasContext:getHeight()
    local request=self.render_request
    -- Only an existing screen viewport may borrow the emergency allowance.
    -- Full-image fallback retains the ordinary admission policy.
    local function decode_budget()
        if request and request.direct then
            return MemoryGuard.instance():region_budget((fmt=="png" and 3 or 8)*1024*1024)
        end
        return MemoryGuard.instance():decode_budget()
    end
    if request and sz and sz.w and sz.h and request.zoom and request.zoom>0 then
        -- Width-fit webtoons need detail at their actual zoom, not a thumbnail
        -- sized to fit the entire long image on one screen.
        display_w,display_h=math.ceil(sz.w*request.zoom),math.ceil(sz.h*request.zoom)
    end
    local function make_plan(current_budget)
        return ImageGuard.plan(sz and sz.w, sz and sz.h, fmt, file_size_of(path), {
            display_w = display_w,
            display_h = display_h,
            budget = current_budget,
            decode_factor = copy_factor,
            native_png = fmt == "png" and PngDecode.available(),
            color = color,
            grayscale_webp = not color,
            preserve_quality = true,
        })
    end
    local post_plan
    if render_post and render_post.digest and sz and sz.w and sz.h then
        post_plan=require("source.processors").regionPlan(render_post,sz.w,sz.h)
    end
    local region_input
    local function region_decode(format,y,height,current_budget,zoom)
        local function read_piece(py,ph,remaining,pzoom)
            if format=="png" then return PngDecode.decode_region(path,py,ph,color,remaining) end
            return ScaledDecode.decode_region(path,format,py,ph,color,remaining,pzoom,region_input)
        end
        if not post_plan then return read_piece(y,height,current_budget,zoom) end
        -- Assemble only the requested output strip. Source rows may be far
        -- apart; no full decoded page is needed for host band reordering.
        local bytes=sz.w*height*(color and 4 or 1)
        if bytes>=current_budget then return nil,"memory_budget" end
        local output,piece
        local ok,result,why=pcall(function()
            output=Blitbuffer.new(sz.w,height,color and Blitbuffer.TYPE_BBRGB32 or Blitbuffer.TYPE_BB8)
            for _,part in ipairs(require("source.image_service").regionPieces(post_plan,y,height)) do
                local origin
                piece,origin=read_piece(part.source_y,part.height,current_budget-bytes,1)
                if not piece then return nil,origin end
                output:blitFrom(piece,0,part.target_y,0,part.source_y-origin,sz.w,part.height)
                piece:free();piece=nil
            end
            return output
        end)
        if piece then piece:free() end
        if not ok or not result then
            if output then output:free() end
            return nil,ok and why or "memory_budget"
        end
        return result,y,height
    end
    if sz and sz.w and sz.h and (not render_post or post_plan) and request
            and (request.rotation or 0)==0 and (fmt=="jpeg" or fmt=="jpg" or fmt=="webp" or fmt=="png" and PngDecode.available()) then
        local format=ImageGuard.normalize_format(fmt)
        local page={width=sz.w,height=sz.h,close=function() end,
            getSize=function(_,dc) local z=dc and dc:getZoom() or 1; return sz.w*z,sz.h*z end,
            getUsedBBox=function() return 0.01,0.01,-0.01,-0.01 end}
        page.draw=function(_,dc,target,ox,oy)
            local started=now_seconds()
            local function record(reason)
                local elapsed=(now_seconds()-started)*1000
                if elapsed>=1000 then
                    logger.warn("Picayomi: slow page render", "page", n, "format", format,
                        "width", sz.w, "height", sz.h, "ms", math.floor(elapsed), "result", reason)
                elseif Diag.enabled then
                    Diag.mark(string.format("draw p%d %dms (%s)",n,math.floor(elapsed),format))
                end
            end
            ox,oy=ox or 0,oy or 0
            local zoom=dc:getZoom()
            local tw,th=target:getWidth(),target:getHeight()
            local row=0
            local halo=math.max(2,math.ceil(1/zoom)+1)
            local function range(lines)
                local first=math.max(0,math.floor((oy+row)/zoom)-halo)
                local last=math.min(sz.h,math.ceil((oy+row+lines)/zoom)+halo)
                return first,last-first
            end
            local function draw_strip(bb,start,raw_height,lines)
                local scaled,view,canvas
                local ok,err=pcall(function()
                    local consumed=0
                    repeat
                        -- Resampling geometry must not change when the decode
                        -- batch shrinks. Keep canonical 64-display-row windows.
                        local canonical=format=="png" or format=="jpeg"
                        local vertical=bb:getHeight()/raw_height
                        local band=canonical and math.floor((row+consumed)/64)*64 or row
                        local count=canonical and math.min(lines-consumed,band+64-row-consumed) or lines
                        local first,last=start,start+raw_height
                        if canonical then
                            first=math.max(0,math.floor((oy+band)/zoom)-halo)
                            last=math.min(sz.h,math.ceil((oy+math.min(band+64,th))/zoom)+halo)
                            first=math.floor(first*vertical)/vertical
                            last=math.ceil(last*vertical)/vertical
                        end
                        local top=math.floor(first*zoom)
                        local height=math.ceil(last*zoom)-top
                        local ratio=bb:getWidth()/sz.w
                        local xhalo=math.max(2,math.ceil(ratio/zoom)+1)
                        local x0=math.max(0,math.floor(ox/zoom*ratio)-xhalo)
                        local x1=math.min(bb:getWidth(),math.ceil((ox+tw)/zoom*ratio)+xhalo)
                        local left=math.floor(x0/ratio*zoom)
                        local width=math.ceil(x1/ratio*zoom)-left
                        local extra=canonical and (x1-x0)*math.ceil((last-first)*vertical)*(color and 4 or 1) or 0
                        if bb:getWidth()*bb:getHeight()*(color and 4 or 1)+width*height*(color and 8 or 2)+extra>decode_budget() then error("memory_budget") end
                        if canonical then
                            local cy=math.floor((first-start)*vertical+0.5)
                            local ch=math.floor((last-first)*vertical+0.5)
                            if cy>=0 and cy+ch<=bb:getHeight() then
                                view=bb:viewport(x0,cy,x1-x0,ch)
                            else
                                -- Fixed geometry even when the decode batch is
                                -- smaller than the canonical resampling window.
                                canvas=Blitbuffer.new(x1-x0,ch,bb:getType())
                                canvas:fill(Blitbuffer.COLOR_WHITE)
                                local y0,y1=math.max(0,cy),math.min(bb:getHeight(),cy+ch)
                                canvas:blitFrom(bb,0,y0-cy,x0,y0,x1-x0,y1-y0)
                                view=canvas
                            end
                        else
                            view=bb:viewport(x0,0,x1-x0,bb:getHeight())
                        end
                        scaled=get_renderimage():scaleBlitBuffer(view,width,height,false)
                        target:blitFrom(scaled,0,row+consumed,ox-left,oy+row+consumed-top,tw,count)
                        if scaled~=view then scaled:free() end
                        scaled=nil
                        view:free();view=nil;canvas=nil
                        consumed=consumed+count
                    until consumed>=lines
                end)
                if scaled and scaled~=view then scaled:free() end
                if view then view:free();canvas=nil end
                if canvas then canvas:free() end
                bb:free()
                if not ok then logger.warn("Picayomi region render:",err);return false end
                row=row+lines
                return true
            end
            local function failed(reason)
                record(reason)
                page.is_placeholder=true
                logger.warn("Picayomi region decode:",reason)
                if reason=="corrupt_image" then
                    pcall(function()
                        DownloadManager.forgetImage(path)
                        os.remove(path)
                        self.session.store:mark_failed(n,"图片损坏",os.time())
                        self.session:_schedule_retry(n)
                    end)
                    require("ui.reader_feedback").queue(self.session, n, "download")
                    placeholder_page(current_page_state(self.session,n)):draw(dc,target)
                else
                    local placeholder = placeholder_page("too_large",{reason=reason=="memory_budget" and reason or "decode_failed"})
                    require("ui.reader_feedback").queue(self.session, n, "display", placeholder.placeholder_text)
                    placeholder:draw(dc,target)
                    if reason=="memory_budget" then
                        local before=decode_budget()
                        self.session:wait_for_memory(n,function() return decode_budget()>before end)
                    end
                end
            end
            target:fill(Blitbuffer.COLOR_WHITE)
            if format~="png" then
                local err
                region_input,err=ScaledDecode.region_input(path,decode_budget())
                if not region_input then failed(err);return end
            end
            while row<th do
                -- Each native strip restarts the codec. Start with the visible
                -- viewport when memory permits; failed budget checks halve it.
                -- PNG keeps its streaming/canonical 64-row extraction path.
                local batch=format=="png" and 64 or th
                local lines=math.min(batch,th-row)
                local success,reason
                repeat
                    local y0,height=range(lines)
                    if height<=0 then return end
                    if format=="png" and not post_plan then
                        -- Noninterlaced PNG consumes the source once for all
                        -- visible strips. Adam7 uses independently bounded passes.
                        success,reason=require("util.png_region").extract(path,y0,height,color,decode_budget(),
                            function(encoded,start,raw_height)
                                local bb,err=PngDecode.decode_encoded(encoded,color)
                                if not bb then error(err,0) end
                                if not draw_strip(bb,start,raw_height,lines) then error("memory_budget",0) end
                                if row>=th then return nil end
                                lines=math.min(lines,th-row)
                                return range(lines)
                            end)
                    else
                        local bb,start,raw_height=region_decode(format,y0,height,decode_budget(),zoom)
                        if bb then success=draw_strip(bb,start,raw_height,lines);reason="memory_budget"
                        else reason=start end
                    end
                    if success or reason~="memory_budget" or lines==1 then break end
                    lines=math.max(1,math.floor(lines/2))
                until false
                if not success then failed(reason);return end
            end
            record("ok")
        end
        return finish(page,"region")
    end
    local plan = make_plan(budget)

    -- 超长图埋点 (不会崩, 但会糊): 一张图比屏幕高好几倍时, 缩放解码到够显示
    -- 的那一档后按屏宽铺满 = 明显模糊。这类图很罕见 (源 A 有些韩漫一话就是一张
    -- 800x12000), 用户主动找很难 —— 命中就留一行 info + Diag, 事后能定位到
    -- 具体哪一话哪一页 (见 util/image_guard.lua 的 ULTRA_LONG_*)。
    if logger.enabled and ImageGuard.is_ultra_long(plan.w, plan.h, display_w, display_h) then
        local detail = string.format("%sx%s, 屏幕 %.1f 倍, %s",
            tostring(plan.w), tostring(plan.h),
            (plan.h and display_h > 0) and (plan.h / display_h) or 0,
            plan.action == "scaled"
                and string.format("缩放解码 %sx%s", tostring(plan.target_w), tostring(plan.target_h))
                or tostring(plan.action))
        if logger.enabled then logger.info(string.format("Picayomi Stream: 超长图 %s 第%s话 p%d/%d: %s",
            tostring(self.session.comic_id), tostring(self.session.order),
            n, self.session.total, detail)) end
        if Diag.enabled then Diag.mark(string.format("超长图 %s/%s p%d %s",
            tostring(self.session.comic_id), tostring(self.session.order), n, detail)) end
    end

    if plan.action == "refuse" then
        if plan.reason == "memory_budget" then
            self.session:wait_for_memory(n, function()
                return make_plan(decode_budget()).action ~= "refuse"
            end)
        end
        -- 超过当前路径预算时显示明确原因, 不绕过保护去调用更高峰值的解码器。
        logger.warn(string.format(
            "Picayomi Stream: 第 %d 页跳过解码 (%s, %sx%s, %s)",
            n, tostring(plan.reason), tostring(plan.w), tostring(plan.h),
            human_size(plan.file_size)))
        if Diag.enabled then Diag.mark(string.format("page %d/%d 跳过 (%s %s %sx%s need=%.1fMB budget=%.1fMB)",
            n, self.session.total, tostring(plan.reason), tostring(plan.format),
            tostring(plan.w), tostring(plan.h), (plan.need_bytes or 0) / 1024 / 1024,
            budget / 1024 / 1024)) end
        return finish(placeholder_page("too_large", plan), "too_large")
    end

    if plan.action == "png" then
        local bb, err = PngDecode.decode(path, color, budget)
        if bb then
            local w, h = bb:getWidth(), bb:getHeight()
            self.session.store.sizes[n] = { w = w, h = h, fmt = "png" }
            local processed=apply_render_post(render_post,post_url,bb)
            if not processed then bb:free(); return finish(placeholder_page("processing_failed"),"processing_failed") end
            bb=processed
            self.current_sub = scaled_sub(bb, w, h)
            return finish(self.current_sub:openPage(1), "png")
        end
        -- 不回退到内存峰值更大的 lodepng。坏缓存沿用有次数上限的重试机制。
        logger.warn("Picayomi Stream: PNG 解码失败: " .. tostring(err))
        if err=="memory_budget" then
            self.session:wait_for_memory(n,function() return make_plan(decode_budget()).action~="refuse" end)
            return finish(placeholder_page("too_large",{reason="memory_budget"}),"memory_budget")
        end
        pcall(function()
            DownloadManager.forgetImage(path)
            os.remove(path)
            self.session.store:mark_failed(n, "PNG 解码失败", os.time())
            self.session:_schedule_retry(n)
        end)
        return finish(placeholder_page(current_page_state(self.session, n)), "png_failed")
    end

    if plan.action == "scaled" then
        -- 所有解码路径共用当前文档的颜色模式。
        local bb, err = ScaledDecode.decode(path, plan.format,
            plan.target_w, plan.target_h, color, budget)
        if bb then
            local processed=apply_render_post(render_post,post_url,bb)
            if not processed then bb:free(); return finish(placeholder_page("processing_failed"),"processing_failed") end
            bb=processed
            -- 尺寸仍按**原图**登记: 等比缩放不改宽高比, 所以排版/zoom 与不缩放时
            -- 完全一致。清晰度只降到"刚好覆盖屏幕"的那一档 (见 ImageGuard.display_target)。
            -- (store.sizes[n] 里已经是原图尺寸 —— plan 就是从它算出来的。)
            self.current_sub = scaled_sub(bb, plan.w, plan.h)
            return finish(self.current_sub:openPage(1), "scaled")
        end

        -- **安全不变量**: 缩放失败 -> 退化成拒绝。
        -- 绝不能"缩不了就整图解" —— 那等于把刚刚要避免的 OOM 又请回来。
        ScaledDecode.log_unavailable(path, err)
        if Diag.enabled then Diag.mark(string.format("page %d/%d 缩放失败, 已跳过", n, self.session.total)) end
        return finish(placeholder_page("too_large",
            { reason = "scale_failed", w = plan.w, h = plan.h, file_size = plan.file_size }),
            "scale_failed")
    end

    -- action == "full": 在解码预算内, 维持原有的整图解码路径
    local pic = pic_module()
    local previous_color = pic.color
    pic.color = color
    local ok, sub = pcall(pic.openDocument, path)
    pic.color = previous_color
    if not ok or not sub then
        logger.warn("Picayomi Stream: 无法解码 " .. tostring(path))
        -- 缓存里躺着一个"文件头合法但解不开"的文件 (半截下载, 或源真的返回了坏图)。
        -- 不删的话它永远命中缓存 -> 这一页永远显示"加载失败", 没有任何路径能修好它
        -- (校验只看文件头, 解不开是它看不见的那一层)。
        -- 删掉 + 记一次失败, 交给 _schedule_retry 在冷却后重下一次 (次数有上限,
        -- 源一直返回坏图时不会无限重试)。
        pcall(function()
            DownloadManager.forgetImage(path)
            os.remove(path)
        end)
        pcall(function()
            self.session.store:mark_failed(n, "图片损坏", os.time())
            self.session:_schedule_retry(n)
        end)
        -- **不要硬编码 "failed"**: 解不开的缓存会被删掉并自动重下一次。
        -- 第一次失败时 gen 还没到 retry_limit, 状态是 loading —— 用户应该看到
        -- "加载中…" 等它重试成功, 而不是先闪一句"加载失败"再变回加载中
        -- (真机反馈: 第一页先显示加载失败, 没两秒又变加载中, 然后成功)。
        return finish(placeholder_page(current_page_state(self.session, n)), "broken")
    end

    -- 保持对当前子文档的引用, 否则本页 draw 期间 image_bb 会被回收
    self.current_sub = sub

    -- **必须 pcall**: 分配失败在 blitbuffer 里是 assert
    -- ("cannot allocate bb copy buffer", blitbuffer.lua:2360), 而这条调用链一直
    -- 通到 UIManager:_repaint —— 抛出去就是整个 KOReader 退出。
    -- 真机 crash.log 2026-10-18 03:57:09 的栈顶就是这里:
    --   ffi/webp.lua:95 getFrameImage -> ffi/pic.lua:286 openPage
    --   -> ui/stream_reader.lua openPage -> document.lua:514 renderPage -> _repaint
    local open_ok, page = pcall(sub.openPage, sub, 1)
    if not open_ok or not page then
        logger.warn("Picayomi Stream: 解码失败", tostring(page))
        pcall(function() sub:close() end)
        self.current_sub = nil
        local message=tostring(page):lower()
        if message:find("allocat",1,true) or message:find("memory",1,true) then
            local before=decode_budget()
            self.session:wait_for_memory(n,function() return decode_budget()>before end)
            return finish(placeholder_page("too_large",{reason="memory_budget"}),"memory_budget")
        end
        -- A damaged bitstream is retryable; allocation failures above keep the
        -- original and never substitute a lower-resolution emergency thumbnail.
        pcall(function()
            DownloadManager.forgetImage(path)
            os.remove(path)
            self.session.store:mark_failed(n,"图片损坏",os.time())
            self.session:_schedule_retry(n)
        end)
        return finish(placeholder_page(current_page_state(self.session,n)),"broken")
    end
    page._parent_sub = sub

    -- 上游 PicPage:draw 同样是最近邻缩放 (base/ffi/pic.lua:38-41)。这条路径
    -- (action == "full") 拿到的是 pic 自己的 page 对象, 这里就地覆盖 draw,
    -- 让两条解码路径的画质/耗时一致 —— 否则同一话里大图和小图会一会儿清楚一会儿糊。
    -- 只在确实有 image_bb 时覆盖: 拿不到就保留上游行为, 不要凭空造一个新失败点。
    local image_bb = page.image_bb
    if image_bb then
        -- 渲染期变换 (源 B 解扰)。换掉的是**同一份**位图的两个引用:
        --   sub.image_bb  —— PicDocument:close 靠它释放 (不换会 double free);
        --   page.image_bb —— 上游 page 对象自己也存了一份引用。
        -- 旧位图在这里释放 (apply_render_post 里), 新位图归 sub 释放。
        local new_bb = apply_render_post(render_post, post_url, image_bb)
        if not new_bb then
            sub:close(); self.current_sub=nil
            return finish(placeholder_page("processing_failed"),"processing_failed")
        end
        if new_bb ~= image_bb then
            image_bb = new_bb
            sub.image_bb = new_bb
            page.image_bb = new_bb
        end
        page.draw = function(_self, dc, target_bb, offset_x, offset_y)
            blit_scaled(image_bb, target_bb, dc, page.width or sub.width, page.height or sub.height, offset_x, offset_y)
        end
    end

    -- 注意: pic.openDocument 对 WEBP 不会填 doc.width/height (始终为 nil),
    -- 尺寸只能从 page 上取。若只用 sub.width 会让 renderPage 拿不到尺寸而返回 nil。
    local pw = page.width or sub.width
    local ph = page.height or sub.height
    -- 保留**从内容嗅探**出来的格式 (守卫下次还要用), 别被这次覆盖丢掉。
    local prev = self.session.store.sizes[n]
    self.session.store.sizes[n] = { w = pw, h = ph,
        fmt = (sz and sz.fmt) or format_from_path(path) }

    -- 尺寸从"未知"变成"已知" (或与排版时用的不同): 这一页**刚才是按占位页尺寸
    -- (屏幕) 排版的** —— zoom 也是按那个比例算的, 画面于是被拉伸/留白。
    -- 必须**强制**发一次 PageUpdate: 它会走 ReaderZooming:onPageUpdate -> setZoom,
    -- 用新尺寸重算 zoom。不能只靠"内容变了"的判据 —— 真图已经画上去时内容确实
    -- 没变, 但 zoom 是错的 (见 refresh_page_if_current 的 force 说明)。
    -- 排在下一个 tick: 这里正在绘制链内部, 不能同步请求重绘。
    -- 只有**确实量到**尺寸时才比: pw/ph 都拿不到时 (理论上不会, 但别赌) 若也判
    -- "变了", 就会每次 openPage 都强制一次, 变成无限重绘。
    local size_known = type(pw) == "number" and type(ph) == "number"
    if size_known and (not (prev and prev.w and prev.h)
       or prev.w ~= pw or prev.h ~= ph) then
        UIManager:nextTick(function()
            refresh_page_if_current(self.session, n, nil, true)
        end)
    end

    -- 注意: 这里**不再顺手预取下一页**。预取由"阅读位置 + 方向"驱动
    -- (ReaderBridge → StreamSession:on_page_turn / on_hint_page), 因为 openPage
    -- 只是"要画这一页", 它既不知道用户往哪个方向翻, 也在绘制链上 —— 不该在这里
    -- 产生新的下载决策。
    return finish(page, "full")
end

function MultiImageDoc:getOriginalPageSize(n)
    local sz = self.session.store.sizes[n]
    if sz then return sz.w, sz.h, 3 end
    return 800, 1200, 3
end

-- ============================================================================
-- KOReader Document: 复用 Document:renderPage 的排版/缩放/缓存
-- ============================================================================
local StreamDocument = Document:extend{
    provider = "picayomi_stream",
    provider_name = "Picayomi Stream",
    -- **不能**设成 true (曾经设成 true, 这就是"页脚 N/A"的根因)。
    --
    -- PicDocument 用 is_pic 标记"纯图片文档"。KOReader 全树里 is_pic 只有**一个**
    -- 用途 —— plugins/statistics.koplugin/main.lua:2735:
    --     if not self.document.is_pic then ... self:initData() end
    -- 即"图片文档不做阅读统计"。设成 true 的后果是 statistics 永远不 initData:
    -- is_doc 一直 false、avg_time 一直 nil, 于是页脚里
    -- book_time_to_read / chapter_time_to_read 两项**永远**渲染成 "N/A"
    -- (readerfooter.lua:340/347 都是 `statistics:getTimeForPages(...) or _("N/A")`)。
    --
    -- 我们按章各建一个文档, 每章各自累计阅读时长 —— 统计对漫画同样有意义。
    -- (模拟器实测: is_pic=true -> getTimeForPages()=nil -> 页脚 "⏳ N/A";
    --             is_pic=false -> avg_time=60 -> 页脚 "⏳ 00:04", 显示项不变。)
    is_pic = false,
    -- Document:getNativePageDimensions 会用它来取页面尺寸, 必须提供
    dc_null = DrawContext.new(),
    -- ReaderView 之后会按用户设置覆盖它; 这里给默认值,
    -- 避免在没有 ReaderView 的场景 (如测试) 下 getFullPageHash 取到 nil
    render_mode = "default",
}

-- 已注册的会话 (占位文件路径 -> session)
-- KOReader 只会把 file 传给 provider.new, 因此用文件路径做关联
local active_sessions = {}

function StreamDocument:updateColorRendering()
    self.render_color = Config:get("grayscale_images", false) == false
        and CanvasContext.is_color_rendering_enabled == true
    if self._document then
        if self._document.color ~= self.render_color then self._document:releaseSub() end
        self._document.color = self.render_color
    end
end

function StreamDocument:init()
    self:updateColorRendering()

    local session = active_sessions[self.file]
    if not session then
        error("Picayomi: 找不到流式阅读会话: " .. tostring(self.file))
    end
    self.session = session

    self._document = MultiImageDoc.new(session)
    self._document.color = self.render_color

    -- 阅读页的内存策略: 把 DocCache 的字节预算收到一个明确的量。
    --
    -- **必须在这里而不是 registerSession**: registerSession 在 showReader 之前跑,
    -- 而 showReader 可能失败 —— 那样就没有任何东西会去 close 文档, 收紧的预算
    -- 会一直留着 (KOReader 里别的文档就少了几十 MB 缓存)。init 是"文档真的开了"
    -- 的确定性时刻, close 是它的对偶。
    -- 为什么需要它: 见 util/memory_guard.lua 的文件头 (真机 264 秒卡死的根因)。
    pcall(function() MemoryGuard.instance():cap_doc_cache() end)

    self.is_open = true
    self.info.has_pages = true
    self.info.number_of_pages = session.total
    self.info.configurable = false

    -- 与 PicDocument 一致: 墨水屏启用抖动
    if CanvasContext:hasEinkScreen() then
        if CanvasContext:canHWDither() then
            self.hw_dithering = true
        elseif CanvasContext.fb_bpp == 8 then
            self.sw_dithering = true
        end
    end

    self:_readMetadata()
end

--- 每一页尺寸可能不同, 因此按页返回
--
-- **绝不联网, 也不解码**: 本方法在排版链里被调用 (getPageDimensions -> 这里),
-- 旧实现在这里同步下载一页只为量尺寸, 同样会冻住整屏。尺寸取不到时退回占位页尺寸
-- (屏幕大小), 至少能画出东西。
function StreamDocument:getUsedBBox(pageno)
    pageno = pageno or 1
    local sz = self.session:ensure_size(pageno)

    local dims = placeholder_dims()
    local w = (sz and sz.w) or dims.w
    local h = (sz and sz.h) or dims.h
    return { x0 = 0, y0 = 0, x1 = w, y1 = h }
end

--- 每页的原始尺寸 (排版用)
--
-- **必须覆盖基类实现。** 基类是这样做的 (document.lua:140-148):
--     local hash = "pgdim|"..self.file.."|"..self.mod_time.."|"..pageno
--     local cached = DocCache:check(hash)
--     if cached then return cached[1] end
--     local page = self._document:openPage(pageno)  -- 会下载!
--     ... DocCache:insert(hash, CacheItem:new{ page_size })
-- 而 renderPage 每次都先调本方法。两个后果:
--   1. openPage 会同步下载 -> 冻屏;
--   2. 未下载的页会被**缓存成占位页尺寸**, 真实图片下完也永远按占位尺寸排版。
-- 所以这里只认 store.sizes (ensure_size 会顺手用文件头量一次本地已存在的页),
-- 不写 DocCache。
--
-- 注意本方法的调用者里有一个**必须拿到正确宽高**的: ReaderZooming:getZoom
-- (zoom_mode="page" 时只用它算 zoom)。所以 ensure_size 那条"本地就量"的捷径
-- 是必要的 —— 回看已缓存章节时, 没有它就会一直按屏幕尺寸算 zoom。
function StreamDocument:getNativePageDimensions(pageno)
    local sz = self.session:ensure_size(pageno)
    if sz and sz.w and sz.h then
        return Geom:new{ w = sz.w, h = sz.h }
    end
    local dims = placeholder_dims()
    return Geom:new{ w = dims.w, h = dims.h }
end

function StreamDocument:isComic()
    return self.session and not self.session.cancelled and self.session.content_type == "comic"
end

-- Resolve the original local image, independently of screen zoom, rotation and
-- grayscale. Reading a placeholder must never export that placeholder as art.
function StreamDocument:getPageImageInfo(pageno)
    if not self:isComic() then return nil, "当前不是漫画阅读" end
    if type(pageno) ~= "number" or pageno % 1 ~= 0 or pageno < 1 or pageno > self.session.total then
        return nil, "无法确定当前漫画页"
    end
    local path = self.session:local_page(pageno)
    if not path then return nil, "本页图片尚未下载完成，请加载完成后重试" end
    local processing, url, err = render_post_for(self.session, pageno)
    if err then return nil, err end
    local size = self.session:ensure_size(pageno)
    if not size then return nil, "无法读取原图尺寸" end
    return { path = path, width = size.w, height = size.h, format = size.fmt,
        processing = processing, url = url }
end

-- KOReader calls this unconditionally when Panel Zoom is enabled. Our image
-- provider has no PDF/K2pdfopt panel detector: fall back to the complete page,
-- which the native ImageViewer can zoom and pan, rather than call a missing API.
function StreamDocument:getPanelFromPage(pageno, pos)
    if not self:isComic() or not self.session:local_page(pageno) then return nil end
    local size = self.session:ensure_size(pageno)
    if not size then return nil end
    return { x = 0, y = 0, w = size.w, h = size.h }
end

function StreamDocument:drawPagePart(pageno, rect, rotation)
    local ok, image, rotate = pcall(Document.drawPagePart, self, pageno, rect, rotation)
    if ok then return image, rotate end
    logger.warn("Picayomi: 无法打开局部图片视图: " .. tostring(image))
    require("ui.reader_feedback").queue(self.session, pageno, "display", "图片暂时无法放大，请稍后重试。")
    return nil
end

--- HintPage 只是"提前缓存下一页"的提示, **不是用户翻页信号**
--
-- 基类实现是 renderPage(pageno, ..., hinting=true) —— 把该页**完整解码并画进
-- DocCache**。对我们这种按需取页的文档, 这是纯浪费: 该页通常还没下载, 画进去的
-- 只是一张"加载中"占位图 (等它真下好了, 渲染键变了又要重画一遍)。而且
-- ReaderView 每次画页都会发 HintPage (含换章/恢复位置/程序重绘), 不能当翻页用。
--
-- 所以这里**不渲染**, 只把它当作"向前补页"的补充信号交给会话 (真正的预取窗口
-- 由翻页入口的方向决定)。
function StreamDocument:hintPage(pageno, _zoom, _rotation, _gamma, _saturation)
    if self.session then self.session:on_hint_page(pageno) end
end

--- DocCache 的键里带上"这一页这次画的是什么"
--
-- **必须覆盖基类实现。** 基类的键只含 文件/修改时间/页码/缩放/渲染模式,
-- 与图片内容无关 (document.lua:393)。于是占位页渲染出的 tile 会被 DocCache 命中,
-- 下载完成后重绘仍然拿回那张"加载中"占位图 —— 页面永远不会被替换。
-- 用 render_key (内容身份 + 代数) 作后缀后, 占位 tile 与真实 tile 永不碰撞,
-- 也就不需要去删缓存条目; 已就绪的页键稳定 => 同页重绘命中 DocCache。
-- (跨会话也安全: 占位文件每次重写, mod_time 变, md5 键本来就不同)
function StreamDocument:getFullPageHash(pageno, zoom, rotation, gamma, saturation)
    return Document.getFullPageHash(self, pageno, zoom, rotation, gamma, saturation)
        .. "|" .. render_key(self.session, pageno)
        .. "|" .. self:size_key(pageno)
end

--- 页面尺寸指纹: 排版用的尺寸一变, 渲染缓存键就得跟着变
--
-- 为什么必须带上: 尺寸探不到时 (文件头解析失败) getNativePageDimensions 退回占位页
-- 尺寸 (屏幕大小), 于是这一页被画进一张**长宽比错误**的 tile —— 图片就被拉伸了。
-- MultiImageDoc:openPage 解码成功后会用真实宽高覆盖 store.sizes, 但渲染键里不含
-- 尺寸, 于是 DocCache 继续命中那张变形的旧 tile: 画面永远歪着, 直到缓存被淘汰。
-- 带上尺寸后, 尺寸一修正键就变了, 下一次重绘自然重画成正确比例。
function StreamDocument:size_key(pageno)
    local sz = self.session.store.sizes[pageno]
    if sz and sz.w and sz.h then return sz.w .. "x" .. sz.h end
    return "?"
end

--- 同上: 局部渲染 (长按看大图) 走的是另一套键, 也要带上, 否则会命中旧占位图
function StreamDocument:getPagePartHash(pageno, zoom, rotation, gamma, saturation, rect)
    return Document.getPagePartHash(self, pageno, zoom, rotation, gamma, saturation, rect)
        .. "|" .. render_key(self.session, pageno)
        .. "|" .. self:size_key(pageno)
end

function StreamDocument:getDocumentProps()
    return {
        title = self.session and self.session.title or "",
        authors = "",
    }
end

-- Under pressure, render into a borrowed portion of the screen's existing
-- buffer. No full-page/tile allocation and no retained DocCache copy. The
-- normal host path remains responsible for caching when memory recovers.
function StreamDocument:drawPage(target, x, y, rect, pageno, zoom, rotation, gamma, saturation)
    local guard = MemoryGuard.instance()
    if not guard:under_pressure() or rotation ~= 0 then
        return Document.drawPage(self,target,x,y,rect,pageno,zoom,rotation,gamma,saturation)
    end
    local raw = self._document
    raw:releaseSub()
    TransportWorker.reclaim_idle()
    collectgarbage("collect") -- discard prior strips before granting a new viewport
    guard:prepare_decode()
    local previous = raw.render_request
    raw.render_request = {zoom=zoom,rotation=rotation,direct=true}
    local view,page
    local ok,err = pcall(function()
        self:getPageDimensions(pageno,zoom,rotation) -- metadata only, as in the host path
        view = target:viewport(x,y,rect.w,rect.h)
        local dc = DrawContext.new()
        dc:setRotate(rotation);dc:setZoom(zoom)
        dc:setGamma(gamma)
        if dc.setSaturation then dc:setSaturation(saturation) end
        dc:setBackgroundCleanup((self.configurable.background_cleanup or 0) ~= 0)
        page = raw:openPage(pageno)
        page:draw(dc,view,rect.x,rect.y,self.render_mode)
        -- Match the host's final screen-copy semantics, including SW dithering.
        if self.sw_dithering then target:ditherblitFrom(view,x,y,0,0,rect.w,rect.h) end
    end)
    if page then page:close() end
    if view then view:free() end
    raw.render_request = previous
    raw:releaseSub()
    if not ok then error(err) end
end

function StreamDocument:renderPage(pageno, rect, zoom, rotation, gamma, saturation, hinting)
    local raw=self._document
    local previous=raw.render_request
    -- Cached tiles own their pixels; never retain a previous full decoded PNG
    -- while the host allocates the next tile (or after rendering has finished).
    raw:releaseSub()
    if MemoryGuard.instance():under_pressure() then TransportWorker.reclaim_idle() end
    MemoryGuard.instance():prepare_decode() -- before the host allocates its tile
    raw.render_request={zoom=zoom,rotation=rotation}
    local ok,tile=pcall(Document.renderPage,self,pageno,rect,zoom,rotation,gamma,saturation,hinting)
    raw.render_request=previous
    raw:releaseSub()
    if not ok then error(tile) end
    return tile
end

function StreamDocument:getCoverPageImage()
    return nil
end

function StreamDocument:close()
    -- 计时点: 真机反馈"从阅读页返回要 3~5 秒", 而 main.lua 只在整条返回链的两端
    -- 打了点 (点击返回 / 阅读器已关闭), 中间这一段到底是"KOReader 自己存设置"
    -- 还是"我们等子进程收尸"分不出来。这三行把 close 切成三段:
    --   点击返回 -> 开始取消会话   = KOReader 的 saveSettings/serialize/CloseDocument
    --   开始取消 -> 会话已取消     = session:cancel() (含 Fork:kill 的阻塞 waitpid)
    --   会话已取消 -> 阅读器已关闭 = 放回渲染预算 + Document.close
    -- Diag.mark 自带 flush, 被强杀也不丢; 正常路径上只有 3 次小写入。
    if self.session then
        logger.notice("Picayomi: reader close", "source", self.session.source and self.session.source.identifier)
        if Diag.enabled then Diag.mark("close: 开始取消会话") end
        self.session:cancel()
        if Diag.enabled then Diag.mark("close: 会话已取消") end
        active_sessions[self.file] = nil
        self.session = nil
    end
    -- 与 init 的 cap_doc_cache 成对 (引用计数): 放回 DocCache 的原始字节预算。
    -- 不放在 session:cancel() 里 —— 换章/关文档/退出都只有这一条释放路径。
    pcall(function() MemoryGuard.instance():restore_doc_cache() end)
    if Diag.enabled then Diag.mark("close: 渲染预算已放回") end
    -- 预算放回只是"允许用到原值", 已经躺在里面的整屏 tile 不会自己消失 ——
    -- doc:close() 不释放 DocCache (见 util/memory_guard.lua 的文件头)。
    -- 真机实测: 关文档那一刻 RSS 100.9MB (整段阅读的最高点), DocCache 22.9MB
    -- 原样留着; 48 秒后开下一话, 进程被杀、Kindle 重启。关掉阅读器之后
    -- 我们本来就不需要这些 tile 了, 在这里一次还清。
    pcall(function() MemoryGuard.instance():release_doc_cache() end)
    if Diag.enabled then Diag.stop() end
    return Document.close(self)
end

-- ============================================================================
-- 对外接口
-- ============================================================================

-- 会被"纠正"的缩放模式: 都是 KOReader 的自动默认值 (content 系)
-- 高图用这些模式会被纵向切成多屏, 而漫画期望"一张图 = 一屏"。
-- 用户显式选择的其它模式 (columns/rows/manual/...) 一律尊重, 不覆盖。
local AUTO_ZOOM_MODES = {
    content = true, contentwidth = true, contentheight = true,
}

-- DocSettings 里"这个值是我们写的"的标记 (见 applyDefaultDocSettings)
--
-- 为什么需要: kopt_page_scroll / zoom_mode 都是**按文档**保存的, 用户随时能在
-- KOReader 自己的菜单里改 (视图模式 / 缩放)。我们不能每次打开都把自己的默认值
-- 盖回去 —— 那会变成"我明明把滚动关了, 下次打开又变回滚动"。
--   nil    = 从没碰过 -> 可以写
--   0/1    = 上次写进去的值; 与当前值不一致 => 用户改过 -> 记成 "user"
--   "user" = 用户改过 -> 以后一律不碰
local SCROLL_MARK = "picayomi_scroll_applied"
local ZOOM_MARK = "picayomi_zoom_applied"
local ROTATION_MARK = "picayomi_rotation_applied"

--- 标记归属: 用户自己改过的话, 把它记成 "user" 并从此不再碰
-- @return owned ("user" | nil | 上次写的值), user_changed
local function resolve_owner(ds, mark, current)
    local owned = ds:readSetting(mark)
    if owned == nil or owned == "user" then return owned, false end
    if current ~= owned then
        ds:saveSetting(mark, "user")
        return "user", true
    end
    return owned, false
end

--- 为漫画阅读设定合适的默认视图 (竖屏 / 条漫 / 横屏) 与缩放
--
-- 三种形态 (判据见 ui/common/view_mode.lua):
--   * 竖屏: 一张图 = 一屏 (page_scroll = 0 + zoom_mode = page)。
--     KOReader 对新文档的默认缩放是 genus=3 (content) → contentwidth,
--     高图会被纵向切成多屏。
--   * 条漫: 按宽度铺满 + 上下连续滚动 (page_scroll = 1 + zoom_mode = pagewidth)。
--     一话几十上百张切片, 翻页读要翻一百多次, 滚动才是它本来的读法。
--   * 横屏: 中段页宽大于高。整页缩放 + **旋转 90°**,
--     用户把设备横过来读。旋转是屏幕级的 (Screen:setRotationMode), 所以菜单/
--     页脚/手势坐标一起转 —— 这正是要的效果。退出阅读时由 ui/reader.lua 还原。
--
-- 两条硬约束:
--   1. **用户自己选过的，一个字都不改。** 判据见 resolve_owner (标记 + 现值)。
--   2. 这个方法跑在 showReader **之前**, 是唯一能改到"文档设置"的时机 ——
--      ReaderView:onReadSettings 只在建阅读器时读一次 kopt_page_scroll。
local function applyDefaultDocSettings(path, session)
    local ok, DocSettings = pcall(require, "docsettings")
    if not ok or not DocSettings then return end

    local dok, ds = pcall(function() return DocSettings:open(path) end)
    if not dok or not ds then return end

    local mode = (session and session.view_mode) or ViewMode.PAGE
    local want_scroll = mode == ViewMode.SCROLL
    local want_landscape = mode == ViewMode.LANDSCAPE
    local changed = false

    -- 横屏要把屏幕转 90°。记下打开前的旋转, 退出阅读时还原 (见 ui/reader.lua)
    --
    -- 只在屏幕**当前是竖屏**时记: 那才是"我们自己转的, 该我们转回来"。
    -- 用户本来就把设备转着用 (文件管理器里转过) 的话不记 —— 退出时不该把人家
    -- 恢复成竖屏。换章时由 ui/reader.lua 把最初的旋转带过来 (新会话是在横屏
    -- 状态下量的, 直接记会记成横屏)。
    if want_landscape and session then
        local Screen = require("device").screen
        local cur = Screen:getRotationMode()
        if cur == Screen.DEVICE_ROTATED_UPRIGHT then
            session.prev_rotation = cur
        end
    end

    -- ---- 视图模式: 整页 / 连续滚动 ----
    local cur_scroll = ds:readSetting("kopt_page_scroll")
    local scroll_owner, scroll_changed = resolve_owner(ds, SCROLL_MARK, cur_scroll)
    if scroll_changed then
        changed = true
        if logger.enabled then logger.info("Picayomi Stream: 用户自己改过视图模式, 保持 " .. tostring(cur_scroll)) end
    end
    if scroll_owner ~= "user" then
        local target = want_scroll and 1 or 0
        if cur_scroll ~= target or scroll_owner ~= target then
            ds:saveSetting("kopt_page_scroll", target)
            ds:saveSetting(SCROLL_MARK, target)
            changed = true
        end
    end

    -- ---- 缩放模式 ----
    local cur_zoom = ds:readSetting("zoom_mode")
    local normal = ds:readSetting("normal_zoom_mode")
    local zoom_owner, zoom_changed = resolve_owner(ds, ZOOM_MARK, cur_zoom)
    if zoom_changed then
        changed = true
        if logger.enabled then logger.info("Picayomi Stream: 用户自己改过缩放模式, 保持 " .. tostring(cur_zoom)) end
    end
    if zoom_owner ~= "user" then
        -- 当前值还是"自动默认"或"我们上次写的"时才可以改。
        -- "page" 也算我们的: 0.9.33 之前每个文档都被写成整页, 那些章节不能因为
        -- 这次加了条漫支持就永远留在整页。
        local function may_override(v)
            if v == nil or AUTO_ZOOM_MODES[v] then return true end
            if v == "page" and want_scroll then return true end
            return v == zoom_owner
        end
        if may_override(cur_zoom) and may_override(normal) then
            local want_zoom = want_scroll and "pagewidth" or "page"
            if cur_zoom ~= want_zoom or normal ~= want_zoom then
                ds:saveSetting("zoom_mode", want_zoom)
                ds:saveSetting("normal_zoom_mode", want_zoom)  -- ReaderKoptListener 走这个键
                -- genus 4 = page; type 1 = width / 2 = full (见 readerzooming 的
                -- zoom_mode_to_type / mode_to_combo)。zoom_mode 字符串本身优先,
                -- 这两个只是让 KOReader 的缩放对话框显示正确的组合。
                ds:saveSetting("kopt_zoom_mode_genus", 4)
                ds:saveSetting("kopt_zoom_mode_type", want_scroll and 1 or 2)
                ds:saveSetting(ZOOM_MARK, want_zoom)
                changed = true
            end
        else
            if logger.enabled then logger.info("Picayomi Stream: 保留用户已选的缩放模式 " .. tostring(cur_zoom)) end
        end
    end

    -- ---- 旋转 (横屏) ----
    -- 与视图/缩放同一套归属判定: 用户自己在 KOReader 里转过屏, 就从此不碰。
    local Screen = require("device").screen
    local cur_rot = ds:readSetting("kopt_rotation_mode")
    local rot_owner, rot_changed = resolve_owner(ds, ROTATION_MARK, cur_rot)
    if rot_changed then
        changed = true
        if logger.enabled then logger.info("Picayomi Stream: 用户自己改过旋转, 保持 " .. tostring(cur_rot)) end
    end
    if rot_owner ~= "user" then
        local target = want_landscape and ViewMode.landscape_rotation()
            or Screen.DEVICE_ROTATED_UPRIGHT
        if cur_rot ~= target or rot_owner ~= target then
            ds:saveSetting("kopt_rotation_mode", target)
            ds:saveSetting(ROTATION_MARK, target)
            changed = true
        end
    end

    -- ---- 页间距 ----
    -- 条漫是"一整条", 页与页之间画分隔缝会把连续的画面切断。只在用户没设过时写 0。
    if want_scroll and ds:readSetting("kopt_page_gap_height") == nil then
        ds:saveSetting("kopt_page_gap_height", 0)
        changed = true
    end

    if not changed then return end
    pcall(function() ds:flush() end)
    if logger.enabled then logger.info(string.format(
        "Picayomi Stream: 阅读设置已应用 (版式=%s, 缩放=%s, 旋转=%s)",
        tostring(mode), tostring(ds:readSetting("zoom_mode")),
        tostring(ds:readSetting("kopt_rotation_mode")))) end
end

-- 已排了一次缓存裁剪 (见 registerSession) —— 连开几话时不必堆叠
local trim_scheduled = false

--- 缓存裁剪延后多久 (秒) —— 见 registerSession 的说明
--
-- 做成常量而不是写死的字面量: 离线用例要断言"它确实被延后了", 而那个延迟值
-- 正是这条约定的全部内容 (改小了就等于没延后)。
StreamDocument.TRIM_DELAY = 1

--- 注册一个流式会话, 返回可直接传给 ReaderUI:showReader 的路径
function StreamDocument.registerSession(session)
    -- 必须**先**清掉残留的旧文档实例, 再登记新会话 —— 顺序不能反。
    -- 旧实例的 close() 里有 `active_sessions[self.file] = nil`, 而它的 file 与新会话
    -- 是同一个路径 (路径按"漫画+章节"固定)。先登记后清理的话, 刚登记好的会话会被
    -- 旧实例的 close() 抹掉, 随后打开文档就报
    --   "找不到流式阅读会话: <path>"
    -- 表现为"同一话第二次打开失败"(点开始/继续没反应)。
    local ok, DocumentRegistry = pcall(require, "document/documentregistry")
    if ok and DocumentRegistry and DocumentRegistry.registry[session.path] then
        logger.warn("Picayomi Stream: 清理残留的旧文档实例 " .. tostring(session.path))
        pcall(function()
            DocumentRegistry.registry[session.path].doc:close()
        end)
        DocumentRegistry.registry[session.path] = nil
    end

    active_sessions[session.path] = session

    -- 开新一话时顺手裁剪阅读页缓存: 只留最近若干话, 当前这一话永远保留。
    -- 放在这里 (而不是退出时) 是因为"开新一话"是天然的、低频的清理时机。
    --
    -- **延后 1 秒再跑。** 裁剪要遍历整个 <reading>/ 目录树、并对每一话 os.execute
    -- 一次 `rm -rf`, 而本函数就在"点开始"到阅读器画完这段等待窗口里 —— 真机日志里
    -- 00:51:43→45 那两秒正是它。延后之后它落在阅读器已经起来、用户在翻页的空档。
    -- 当前话由 protect 参数保住, 所以此刻它自己的目录已经建好也不会被误删。
    -- (先例: main.lua 启动时也是延后 cleanCache。)
    if not trim_scheduled then
        trim_scheduled = true
        local comic_id, order = session.comic_id, session.order
        UIManager:scheduleIn(StreamDocument.TRIM_DELAY, function()
            trim_scheduled = false
            pcall(function()
                DownloadManager:trimReadingCache(
                    DownloadManager.READING_CACHE_KEEP_CHAPTERS,
                    comic_id, order, session.source and session.source.identifier)
            end)
        end)
    end

    logger.notice("Picayomi: reader open", "source", session.source and session.source.identifier, "pages", session.total)
    -- 诊断: 阅读期间周期采样内存 (真机 OOM 被强杀时, diag.log 里有崩溃前的内存曲线)
    if Diag.enabled then Diag.start(string.format("read %s 第%s话 共%d页",
        tostring(session.title or ""), tostring(session.order), session.total)) end

    -- ReaderUI:showReader 要求 file 是一个真实存在的文件 (内部会检查 mode=="file")
    --
    -- 内容里带上路径, 让每一话的 md5 互不相同: KOReader 用
    -- util.partialMD5(占位文件) 当书籍指纹 (readerui.lua:497), 而阅读统计是按
    -- (标题, 作者, md5) 建行的 (statistics/main.lua:722)。若所有漫画共用同一串
    -- 内容, 同名漫画会被并成同一本, 阅读时长/页数互相污染 —— 页脚"还需阅读时间"
    -- 也跟着算错。路径按"漫画+章节"固定, 所以 md5 也稳定。
    local f = io.open(session.path, "w")
    if f then
        f:write("picayomi stream placeholder\n", tostring(session.path), "\n")
        f:close()
    else
        logger.err("Picayomi Stream: 无法创建占位文件 " .. tostring(session.path))
    end

    applyDefaultDocSettings(session.path, session)

    return session.path
end

StreamDocument.Session = StreamSession
StreamDocument.getSession = function(path) return active_sessions[path] end

-- 暴露给测试: "首屏占位页替换"的时序只在真机上看得见 (下载正好落在 ReaderUI 建好
-- 之前的那 ~2s 里), 只能靠假 ReaderUI 断言重试逻辑。见 test/regression_robustness.lua §14。
StreamDocument._refresh_page_if_current = refresh_page_if_current

-- 暴露给测试: MultiImageDoc 是本文件的局部表, 而"解不开的缓存文件必须丢弃"
-- 只有一条入口 (openPage 里解码失败那个分支)。见 test/regression_robustness.lua §15。
StreamDocument._openPage = MultiImageDoc.openPage

return StreamDocument
