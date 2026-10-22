-- api/comic.lua (兼容层)
-- 代理到当前漫画源 (source/*), 旧 UI 模块仍可用 require("api.comic") 不需修改。
--
-- 本文件只保留两类东西:
--   1. 薄代理 (getComics / getChapters / 收藏 / 搜索 ...) —— 直接转发给 source
--   2. "打开一话"的准备与时序: prepareComic (取图片列表 + 建流式会话) 与
--      getAndOpenComic (可取消协程, 见其注释)
-- 章节图片的下载与 CBZ 打包都不在这里了 (见 network/download_manager.lua 的说明)。

local logger = require("util.logger")
local SourceRegistry = require("source.registry")
local DownloadManager = require("network.download_manager")
local Diag = require("util.diag")
local ViewMode = require("ui.common.view_mode")

--- 打开链路上的诊断计时点
--
-- 真机上"点开始到看见图"要 ~10s, 而单页下载只要 0.1s —— 剩下的时间花在哪一段,
-- 只能靠时序归因。diag.log 每行都带秒级时间戳, 所以这里只记"阶段开始/结束",
-- 读日志时按行序算差值即可, 不必自己量耗时 (量错时钟反而误导)。
local function open_mark(comic_id, order, msg)
    if Diag.enabled then Diag.mark(string.format("open %s 第%s话: %s",
        tostring(comic_id), tostring(order), tostring(msg))) end
end

--- 决定这一话的阅读版式 (竖屏 / 条漫 / 横屏)
--
-- 顺序: 单本设置 > 全局策略 > 自动判定 (第 1 页的像素长宽比)。
-- 自动判定需要第 1 页的真实尺寸, 而尺寸只能从文件头量 —— 所以这里会**同步**
-- 下第 1 页 (它本来就要下: 打开后第一件事就是画它)。量不到就按竖屏, 不猜。
--
-- 为什么不再看源站分类/标签: 有些作品分类写着韓漫、画法却是仿日漫的整页分镜
-- (实测源 B 339033 的切片 800x1129, 与日漫比例完全一样), 按分类判会把整页翻
-- 错判成滚动。判据只看画面本身, 见 ui/common/view_mode.lua 的说明。
local function resolve_view_mode(source, comic_id, session, context)
    local saved
    pcall(function()
        saved = require("model.comic"):getViewMode(comic_id,
            source and source.identifier)
    end)
    if saved then return saved end

    local policy = ViewMode.policy()
    if policy == "always" then return ViewMode.SCROLL end
    if policy == "never" then return ViewMode.PAGE end

    -- 同一本漫画换章沿用已经判定的版式, 不为再次探测而同步下载第一页。
    -- 新话第一页已在本地时仍按其实际尺寸判断; 单本设置和全局策略始终优先。
    local hint = context and context.view_mode_hint
    if type(hint) == "table" and source and hint.source_id == source.identifier
            and tostring(hint.comic_id) == tostring(comic_id)
            and (hint.mode == ViewMode.PAGE or hint.mode == ViewMode.SCROLL
                or hint.mode == ViewMode.LANDSCAPE) then
        local size = session:ensure_size(1)
        if size then return ViewMode.resolve(nil, size) end
        if Diag.enabled then open_mark(comic_id, session.order, "沿用上一话版式=" .. hint.mode) end
        return hint.mode
    end

    local size
    pcall(function()
        local path = session:fetch_page(1)
        if path then size = session:ensure_size(1) end
    end)
    return ViewMode.resolve(nil, size)
end

-- 确保源已初始化
local function getSource()
    local source = SourceRegistry:getCurrent()
    if source and not source._source_runtime and not source._http_client then
        source:init()
    end
    return source
end

local ComicAPI = {}

-- 处理响应 (兼容旧接口)
function ComicAPI:processResponse(response)
    if not response then
        return { code = 500, message = "无响应", data = {} }
    end
    if response.message == "success" or response.code == 200 then
        if not response.data then response.data = {} end
    end
    return response
end

-- 获取分类
function ComicAPI:getCategories()
    local source = getSource()
    if not source then return false, nil, "源未初始化" end
    return source:getCategories()
end

-- 获取漫画列表
function ComicAPI:getComics(page, category, tag, sort, isRecommend)
    local source = getSource()
    if not source then return false, nil, "源未初始化" end

    if isRecommend then
        return source:getRandom(page)
    elseif category then
        return source:getCategoryComics(category, page, sort)
    else
        return source:getComics(page, sort)
    end
end

-- 获取漫画详情
function ComicAPI:getComicDetail(comicId)
    local source = getSource()
    if not source then return false, nil, "源未初始化" end
    return source:getComicDetail(comicId)
end

-- 获取章节列表
function ComicAPI:getComicEpisodes(comicId, page)
    local source = getSource()
    if not source then return false, nil, "源未初始化" end
    return source:getChapters(comicId, page)
end

-- 获取章节图片
function ComicAPI:getComicImages(comicId, order, page, epId)
    local source = getSource()
    if not source then return false, nil, "源未初始化" end
    return source:getChapterImages(comicId, order, page)
end

-- 获取所有图片
function ComicAPI:getAllComicImages(comicId, order, epId)
    local source = getSource()
    if not source then return false, nil, "源未初始化" end
    return source:getAllChapterImages(comicId, order)
end

-- 获取收藏
function ComicAPI:getFavorites(page, sort)
    local source = getSource()
    if not source then return false, nil, "源未初始化" end
    return source:getFavorites(page, sort)
end

-- 添加收藏 / 取消收藏
--
-- 走**源自己的方法**, 不要伸手去掏 `source._api`:
--   那个字段只有源 A/源 C 这类"把 API 表挂上来"的源才有, 源 B 根本没有 ——
--   旧写法在 源 B 上必然 `attempt to index a nil value (field '_api')`, 用户按下
--   「收藏」只得到一句"操作失败"。而且各源的收藏端点语义不同 (源 A 是明确增/删,
--   源 B 是切换), 统一由源保证"结果 = 请求的状态"。
function ComicAPI:addFavorite(comicId)
    local source = getSource()
    if not source then return false, "源未初始化" end
    if not source.addFavorite then return false, "当前源不支持网络收藏" end
    return source:addFavorite(comicId)
end

function ComicAPI:removeFavorite(comicId)
    local source = getSource()
    if not source then return false, "源未初始化" end
    if not source.removeFavorite then return false, "当前源不支持网络收藏" end
    return source:removeFavorite(comicId)
end

-- 搜索漫画
function ComicAPI:searchComics(keyword, page, sort)
    local source = getSource()
    if not source then return false, nil, "源未初始化" end
    return source:search(keyword, page, sort)
end

-- 获取排行榜
function ComicAPI:getRanking(type, page)
    local source = getSource()
    if not source then return false, nil, "源未初始化" end
    return source:getRankings(type, page)
end

--- 当前源在某类列表下可用的排序方式
-- @param list_kind "recommend" | "category" | "search"
-- @return { { value=, text= }, ... }; 空表表示该列表不支持排序 (界面据此不显示按钮)
function ComicAPI:getSortOptions(list_kind)
    local source = getSource()
    if not source or not source.getSortOptions then return {} end
    return source:getSortOptions(list_kind) or {}
end

-- 获取分类漫画 (兼容旧方法)
-- @param sort 排序取值, 由源声明 (source:getSortOptions); nil 则用源的默认值
function ComicAPI:getComicsByCategory(category_id, page, sort)
    local source = getSource()
    if not source then return false, nil, "源未初始化" end
    return source:getCategoryComics(category_id, page, sort)
end

-- 获取特殊分类漫画 (兼容旧方法)
function ComicAPI:getComicsBySpecialCategory(category_title, page, sort)
    local source = getSource()
    if not source then return false, nil, "源未初始化" end
    -- 源 A 没有特殊分类概念，尝试用标题搜索
    return source:search(category_title, page, sort)
end

-- 只"准备"要打开的文档, 不打开它
--
-- 拆出来是为了让"换章"能复用同一套准备逻辑: 换章时文档要交给
-- `ReaderUI:switchDocument`(在当前阅读器里换文档, 不重开阅读器),
-- 而不是再走一遍 `showReader`。
--
-- @param context: 可选。阅读上下文 { comic = <漫画对象>, episodes = <章节列表>,
--                 from_beginning = <bool, true 表示"从头读">,
--                 view_mode_hint = { comic_id, source_id, mode } (同本换章时提供) }
-- @return ok, path, doc_class, session, err
function ComicAPI:prepareComic(comicId, order, context)
    local sid = context and context.source_id
    local source = sid and SourceRegistry:get(sid) or (not sid and getSource())
    if not source and sid and context.offline then source = require("source.offline").new(sid) end
    if sid and source and not source._source_runtime and not source._http_client then source:init() end
    if not source then
        return false, nil, nil, nil, "源未初始化"
    end

    -- 「开始」= 固定从第一章第一页: 这里(打开文档之前的最后一道关口)清掉 KOReader
    -- 为这一话记住的页码, 否则 ReaderPaging:onReadSettings 会把 last_page 恢复回来,
    -- 表现成"点「开始」却接着上次读"。只有 from_beginning 时才清 ——
    -- 「继续」/换章必须保留进度。
    if context and context.from_beginning then
        -- 注意用 `.` 调用: util.reading_position 的函数不带 self
        require("util.reading_position").clear(comicId, order, source.identifier)
    end

    -- 用户主动下载过的章节: 直接读本地目录, 一次网络请求都不发。
    -- 这是"已下载"能离线阅读的关键 —— 否则断网时连图片列表都取不到。
    local OfflineLibrary = require("util.offline_library")
    local local_images = nil
    local local_dir = nil
    if source.identifier and OfflineLibrary.isChapterComplete(source.identifier, comicId, order) then
        local images, dir = OfflineLibrary.localImages(source.identifier, comicId, order)
        if #images > 0 then
            local_images = images
            local_dir = dir
        end
    end

    local images_result
    if local_images then
        if Diag.enabled then open_mark(comicId, order,
            string.format("离线章节 共%d页 (本地)", #local_images)) end
        images_result = { images = local_images }
    else
        -- 只取图片列表 (不下载)
        -- 先记一行内存: 这里是"从浏览切到阅读"的门口, 也是真机上出过整机重启的位置
        -- (2026-10-18)。崩溃前的可用内存只能靠这一行留下来。
        if Diag.enabled then pcall(Diag.snapshot,"准备打开阅读器") end
        if Diag.enabled then open_mark(comicId, order, "取图片列表…") end
        local ok, fetched = source:getAllChapterImages(comicId, order)
        if not ok or not fetched or not fetched.images or #fetched.images == 0 then
            if Diag.enabled then open_mark(comicId, order, "图片列表失败") end
            return false, nil, nil, nil, "获取漫画图片失败"
        end
        images_result = fetched
        if Diag.enabled then open_mark(comicId, order,
            string.format("图片列表就绪 共%d页", #images_result.images)) end
    end

    -- 流式: 立即进入阅读器, 当前页按需下载, 后续页面后台预取。
    -- (旧实现要求整章下载完再打包 CBZ, 用户必须一直等, 且无法取消;
    --  CBZ 那条链已整体删除 —— 见 network/download_manager.lua 的说明。)
    local StreamReader = require("ui.stream_reader")
    local cache_dir = local_dir or DownloadManager.getChapterDir(comicId, order, source.identifier)

    -- 路径按"漫画+章节"固定 (不含时间戳), 这样 KOReader 能记住阅读进度与缩放设置;
    -- registerSession 会负责清理可能残留的旧文档实例
    local stream_path = DownloadManager.getStreamPath(comicId, order, source.identifier)

    local session = StreamReader.Session.new{
        source = source,
        comic_id = comicId,
        order = order,
        title = (context and context.comic and context.comic.title)
            or images_result.title or tostring(comicId),
        images = images_result.images,
        cache_dir = cache_dir,
        path = stream_path,
        -- 供阅读器内的菜单使用: 返回本话详情 / 打开下一话
        context = context,
        -- 版式: 先给个安全的默认值, 量完第 1 页再定 (见 resolve_view_mode)
        view_mode = ViewMode.PAGE,
    }

    -- 版式必须在 registerSession **之前**定下来: 那一刻写文档设置, 打开文档时
    -- ReaderView:onReadSettings 只读一次 page_scroll / zoom / rotation。
    session.view_mode = resolve_view_mode(source, comicId, session, context)
    if Diag.enabled then open_mark(comicId, order, "版式=" .. tostring(session.view_mode)) end

    StreamReader.registerSession(session)

    if logger.enabled then logger.info(string.format("Picayomi: 流式打开 %s 章节 %s (共 %d 页)",
        tostring(comicId), tostring(order), #images_result.images)) end

    -- 预热第 1 页 + 近邻。**只入队, 一个字节都不等**。
    --
    -- 关键在**时机**: 这两句在"打开阅读器"之前, 而紧接着的 ReaderUI:showReader 要在
    -- 主线程上做整页排版 (真机实测这一段 ~2s)。下载跑在 fork 出来的子进程里, 两者
    -- 天然重叠 —— 等阅读器真去画第 1 页时, 图片往往已经落盘, 首屏不再先闪"加载中"。
    --
    -- 与"被删掉的旧实现"的区别: 旧实现是**同步** fetch_page, 要等下载完才返回,
    -- 于是"点开始"白等一个网络 RTT 且期间界面冻死 (慢网下点不了也退不出);
    -- 这里 request_page / prefetch 都只入队 + 踢一脚驱动 (见 ui/stream_reader.lua 的注释),
    -- 打开路径上仍然只有"一次图片列表请求"。
    session:request_page(1)
    session:prefetch(2)

    if Diag.enabled then open_mark(comicId, order, "会话就绪, 已预热第1页") end

    return true, stream_path, StreamReader, session
end

-- 打开一话: 可取消, 且不阻塞调用方
--
-- 「取章节列表 → 取图片列表 → 打开文档」整条链跑在一个 Trapper 协程里:
--   * 每步之间 `Trapper:info()` 把控制权交回 UIManager, 界面保持可响应;
--   * 恢复时它顺带报告"等待期间用户有没有点屏幕" —— 点了就弹 Paused/Continue/Abort,
--     选 Abort 即中止本次打开。
--
-- 取消只能在**步骤之间**生效: 单条 HTTP 请求是同步的, 中途打不断 (Lua 单线程 +
-- 同步 socket)。所以要压缩的是"步数 × 每步耗时" —— 这也是上面 prepareComic 里
-- 去掉"打开前同步下第 1 页"的原因。
--
-- 本函数**立即返回** (协程在第一个 yield 处让出), 结果经 on_done 送达:
--   on_done(ok, err, episodes)
--     ok       = true   阅读器已打开
--     ok       = false  未打开; err 为原因, **err == nil 表示用户主动中止** (不必报错)
--     episodes 本次取到的章节列表 (调用方已在 context.episodes 里给过时为 nil)
--
-- @param context: 可选。阅读上下文 { comic, episodes, episode, from_beginning }。
--                 只有给了 context 才会去取章节列表 —— 它只服务于阅读器内的
--                 "返回本话详情 / 下一话"菜单, 不要这个菜单的调用方不必多花一次请求。
function ComicAPI:getAndOpenComic(comicId, order, epId, detail_menu_to_close, context, on_done)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local Trapper = require("ui/trapper")
    local _ = require("gettext")
    local T = require("ffi/util").template
    local ReaderUI = require("apps/reader/readerui")
    local release_downloads = require("util.reading_resources").pause()
    local opening_session

    local function finish(ok, err, episodes)
        if not ok then
            if opening_session then opening_session:cancel() end
            release_downloads()
        end
        if ok and not opening_session then release_downloads() end
        if on_done then
            local pok, perr = pcall(on_done, ok, err, episodes)
            if not pok then
                logger.warn("Picayomi: getAndOpenComic 结果回调异常: " .. tostring(perr))
            end
        end
        return ok
    end

    -- 先关掉 Trapper 的加载提示, 再弹错误提示 —— 顺序反了会让错误提示被
    -- 关提示那次刷新盖住 (LoadingTask 的注释里记着同一个坑)。
    -- Trapper:reset() 同时清掉它自己的控件引用, 免得残留到下一次任务。
    local function fail(prefix, err)
        local reason = tostring(err or _("未知错误"))
        logger.err(string.format("Picayomi: %s: %s", prefix, reason))
        Trapper:reset()
        UIManager:show(InfoMessage:new{
            text = T(_("%1: %2"), _(prefix), reason),
            timeout = 3,
        }, "ui")
        return finish(false, reason)
    end

    local function run()
        -- 上一次任务可能被中止过, 会留下未关闭的控件与自定义文案
        Trapper:reset()
        Trapper:setPausedText(_("已暂停"), _("中止"), _("继续"))

        -- 步骤 1: 章节列表 (只在调用方要阅读器内导航时才取)
        local episodes
        if context then
            episodes = context.episodes
            if not episodes then
                Trapper:info(_("正在加载漫画…"))
                local s, data = self:getComicEpisodes(comicId)
                if s and data and data.episodes and #data.episodes > 0 then
                    episodes = data.episodes
                    context.episodes = episodes
                end
            end
        end

        -- 步骤 2: 取图片列表 + 建流式会话 (取消点)
        if not Trapper:info(_("正在打开漫画…")) then
            if logger.enabled then logger.info("Picayomi: 用户中止了本次打开 (取章节列表之后)") end
            return finish(false, nil)
        end
        local ok, path, doc_class, _session, err = self:prepareComic(comicId, order, context)
        opening_session = _session
        if not ok then
            return fail("获取漫画失败", err or _("获取漫画图片失败"))
        end
        if _session then _session.release_downloads = release_downloads end

        -- 步骤 3: 打开阅读器 (取消点)
        --
        -- 条漫: 把"会进滚动模式"写进这条加载文案 —— 它正好显示在
        -- "opening file …/reading/xxx.stream" 那几秒里, 用户不用等阅读器起来
        -- 再被一个弹窗挡一下 (真机反馈: 打开后每次都提示有点烦)。
        local opening_text = _("正在打开阅读器…")
        if _session and _session.view_mode == ViewMode.SCROLL then
            opening_text = _("正在打开阅读器…（条漫：上下滑动阅读，设置可改）")
        elseif _session and _session.view_mode == ViewMode.LANDSCAPE then
            opening_text = _("正在打开阅读器…（横屏：已旋转 90°）")
        end
        if not Trapper:info(opening_text) then
            if logger.enabled then logger.info("Picayomi: 用户中止了本次打开 (取图片列表之后)") end
            -- 会话已经建好, 而且 prepareComic 里已经把它预热了 (第 1 页在下载中)。
            -- 中止就得收掉: 否则预取与下载子进程会挂在一个永远不会被打开的文档上。
            if _session then
                pcall(function() _session:cancel() end)
                pcall(function() _session.transport:close() end)
            end
            return finish(false, nil)
        end
        -- **先把加载提示收掉, 再开阅读器。**
        --
        -- 顺序反了 (showReader -> clear) 就是两次整屏更新叠在一起: 提示框那次
        -- "ui" 更新还没在面板上落稳, 阅读器的整屏 full 更新就压上去, 最后又补一次
        -- 关提示的 "ui" 刷新 —— 墨水屏上会留下提示框的一条, 用户看到的是
        -- "提示框只显示了中间一段" (真机 2026-10-18)。
        -- 现在: 关提示 (一次干净的 ui 刷新) -> 再整屏 full 打开阅读器, 最后一次
        -- 更新覆盖全部像素, 不会有残留。
        Trapper:clear()
        if Diag.enabled then open_mark(comicId, order, "打开阅读器…") end
        local open_ok, open_err = pcall(function()
            if doc_class then
                ReaderUI:showReader(path, doc_class)
            else
                ReaderUI:showReader(path)
            end
        end)
        if not open_ok then
            return fail("打开阅读器失败", open_err)
        end
        if _session and _session.cancel then
            UIManager:nextTick(function()
                local ui = ReaderUI.instance
                if not (ui and ui.document and ui.document.session == _session) then
                    _session:cancel()
                end
            end)
        end
        if Diag.enabled then open_mark(comicId, order, "阅读器已打开") end

        -- **详情页故意不关**: 它就是"读完一话之后要回到的那一页"。
        --
        -- 历史: 这里原来会在阅读器上栈之后 `UIManager:close(detail)`。当时的动机
        -- 只是"别让详情页在阅读器下面碍事", 但代价是返回路径上栈顶变成了详情页
        -- **下面那一层列表页** —— 用户看到的就是"阅读完直接回到漫画列表", 而且
        -- 想再看这一话的章节/评论得重新点进详情页。
        --
        -- 留着它有三个好处, 都没有副作用:
        --   1. 关阅读器后栈顶自然就是详情页 (用户要的"返回详情页"), 不用重建 ——
        --      重建要 new 一遍 ComicDetail, 还会因为 episodes_data 没带而**再发一次
        --      章节请求** (一个完整网络 RTT), 正是返回慢的一部分;
        --   2. 列表页在详情页下面原样保留, 翻页记录/已加载的缓冲都不丢;
        --   3. 阅读器是 covers_fullscreen 的, 重绘不会画下层 —— 阅读期间看不到它。
        -- 内存代价是一张封面 (约 2MB) 加一屏控件, 相对 Avail ~95MB 可以忽略。
        --
        -- 退出 Picayomi / "返回 Picayomi" 时它照样会被 util/widget_sweep 扫掉
        -- (ComicDetail 带 is_picayomi_page 标记)。
        --
        -- 参数 `detail_menu_to_close` 保留: 调用方仍然把详情页传进来, 将来若要
        -- 恢复"关掉"的行为, 判断条件在这里, 不用再改一遍所有调用点。
        if detail_menu_to_close and detail_menu_to_close.handleEvent then
            if logger.enabled then logger.dbg("Picayomi: 详情页留在栈里作为返回目标 (不关闭)") end
        end

        finish(true, nil, episodes)
    end

    Trapper:wrap(function()
        -- pcall 兜住"没预料到的异常": Trapper:wrap 自己的 xpcall 只会记日志,
        -- 加载提示会**永久留在屏幕上** (旧实现用 LoadingTask 防的就是这个)。
        -- 跨 pcall 的 yield 在 LuaJIT 上是支持的 (Trapper:info 内部就这么干)。
        local ok, err = pcall(run)
        if not ok then
            fail("打开漫画失败", err)
        end
    end)

    return true
end

return ComicAPI
