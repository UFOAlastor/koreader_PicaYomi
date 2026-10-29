-- ui/downloads.lua
-- 「已下载」: 用户主动下载过的漫画列表。
--
-- 复用漫画列表的卡片样式 (封面 + 标题 + 元信息), 只有正在下载的条目多一条
-- 进度条 —— 用户一眼就能分清"下好了"和"还在下"。
--
-- 数据来源是 util/offline_library 的清单 + util/download_queue 的实时状态:
--   * 清单管持久化 (重启后还在);
--   * 队列管"现在下到哪了";
--   列表页每 1.5 秒对一次账, 只在真的变化时重绘, 避免电子墨水屏持续闪烁。
local Device = require("device")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local ButtonDialog = require("ui.common.action_style").ButtonDialog
local ConfirmBox = require("ui.common.action_style").ConfirmBox
local Screen = Device.screen
local _ = require("gettext")
local T = require("ffi/util").template
local logger = require("util.logger")

local VisualComicList = require("ui.common.visual_comic_list")
local ComicDetail = require("ui.common.comic_detail")
local OfflineLibrary = require("util.offline_library")
local DownloadQueue = require("util.download_queue")
local WidgetSweep = require("util.widget_sweep")

local Downloads = WidgetContainer:extend{
    name = "picayomi_downloads",
    title = _("已下载"),
    is_picayomi_page = true,
    queue = nil,                -- 测试注入; 缺省用单例
    refresh_interval = 1.5,
}

local function chapter_unit(comic)
    return comic and comic.content_type=="novel" and _("章") or _("话")
end

local instances=setmetatable({},{__mode="k"})
function Downloads:init()
    instances[self]=true
    self.width = Screen:getWidth()
    self.height = Screen:getHeight()
end

function Downloads:shutdown()
    self._closed=true
    if self._timer_callback then UIManager:unschedule(self._timer_callback)end
    self._timer_callback=nil;self._timer=false
    if type(self._delete_task)=="table"then self._delete_task:cancel()end
    self._delete_task=nil
end
function Downloads.shutdownAll()
    for instance in pairs(instances)do instance:shutdown()end
end

local function key_of(comic)
    return tostring(comic.source_id or "unknown") .. "|" .. tostring(comic._id)
end

--- 源 id -> 列表里显示的来源名
--
-- 已下载清单是**跨源聚合**的 (源 A / 源 B / 源 C 混在同一页), 不标来源就
-- 分不清这部作品到底来自哪个源 —— 同一部作品在不同源是不同的条目。
-- 源没注册起来 (模块加载失败) 时退回 identifier: 显示 "jm" 也比 "未知来源" 有用。
local function source_label(source_id)
    local sid = tostring(source_id or "")
    if sid == "" then return nil end
    local ok, SourceRegistry = pcall(require, "source.registry")
    local source = ok and SourceRegistry and SourceRegistry:get(sid)
    if source and type(source.name) == "string" and source.name ~= "" then
        return source.name
    end
    return sid
end

--- 把清单条目转成列表页认识的漫画字段
local function to_comic(entry)
    local comic = {}
    for k, v in pairs(entry) do
        if k ~= "download_chapters" then comic[k] = v end
    end
    comic.author_text = comic.author_text or comic.author
    comic.source_text = source_label(comic.source_id)
    return comic
end

function Downloads:entries()
    local out={}
    for _,entry in ipairs(OfflineLibrary.list()) do
        local kind=entry.content_type=="novel" and "novel" or "comic"
        if kind==(self.content_type or "comic") then out[#out+1]=entry end
    end
    return out
end

function Downloads:show(return_callback)
    self._home_preview=nil
    self.content_type=self.content_type or "comic"
    local section=self.content_type=="novel" and _("小说下载") or _("漫画下载")
    self.return_callback = return_callback
    self._closed = false

    -- 旧列表收在最后一步 (replace_page): 先 show 新的, 再关旧的。
    -- 先关再建的话, 中间露出的是主页 —— 刷新/删完一部都会"退回上一页"闪一下。
    local old_list = self.list
    self.list = nil

    local entries = self:entries()
    if #entries == 0 then
        -- 一部都没有了 (删掉最后一部): 过期的列表必须收掉, 不能留在栈里
        if old_list then UIManager:close(old_list, "ui") end
        UIManager:show(InfoMessage:new{
            text = section.._("为空。\n在作品详情页点「下载章节」即可离线保存。"),
            timeout = 4,
        }, "ui")
        if self.return_callback then self.return_callback() end
        return false
    end

    local comics = {}
    local downloading = 0
    local retryable = 0
    for _i, e in ipairs(entries) do
        comics[#comics + 1] = to_comic(e)
        if e.download_state == "downloading" then downloading = downloading + 1 end
        retryable = retryable + #OfflineLibrary.failedChapters(e.source_id, e._id)
    end
    self._retry_available = retryable > 0
    self._downloading_count = downloading

    -- 标题直接写清"有几章在下", 用户一眼知道这里是下载中的列表
    local list_title = downloading > 0
        and T(_("%1 · %2 部下载中"), section,downloading)
        or section

    self.list = VisualComicList:new{
        title = list_title,
        comics = comics,
        cover_concurrency = 1, -- One source-bound transport; do not cancel another row's source.
        resolve_cover = function(comic)
            local source=self:sourceFor(comic.source_id)
            if not source or not source.getComicDetail or not require("ui.common.source_access").check(source,nil,true) then return nil,"failed" end
            local ok,detail=source:getComicDetail(comic._id)
            if not ok or type(detail)~="table" then return nil,"failed" end
            local thumb=detail.thumb or detail.cover
            return thumb,thumb and "ready" or "missing"
        end,
        server_page = 1,
        total_pages = 1,
        total_count = #comics,
        has_more = false,
        fetch_page = function(page)
            if tonumber(page) == 1 then
                return true, { comics = comics, page = 1, pages = 1, total = #comics }
            end
            return true, { comics = {}, page = page, pages = 1, total = #comics }
        end,
        processor = function(item) return item end,
        on_select = function(comic, navigation) self:openComic(comic, navigation) end,
        on_back = function(list)
            if list then UIManager:close(list, "ui") end
            self.list = nil
            if self.return_callback then self.return_callback() end
        end,
        extra_buttons = (function()
            local extras = {
                {
                    text = _("刷新"),
                    callback = function(list) self:refreshList(list, true) end,
                },
            }
            if retryable > 0 then
                extras[#extras + 1] = {
                    -- 只在真的存在失败/未完成章节时出现 (空按钮比没有更糟)
                    text = _("继续下载"),
                    callback = function() self:retryAllFailed() end,
                }
            end
            -- 删除入口放最后 (紧挨「返回」): 破坏性操作不该在常用按钮旁边
            extras[#extras + 1] = {
                text = _("删除下载"),
                callback = function() self:showDeleteMenu() end,
            }
            return extras
        end)(),
    }
    WidgetSweep.replace_page(old_list, self.list)
    self:startTimer()
    return true
end

--- 把实时进度同步到列表缓冲区; 返回是否发生了变化
function Downloads:syncProgress()
    if not self.list or self.list._closed then return false, {} end
    local fresh = self:entries()
    local map = {}
    local retryable, downloading = false, 0
    for _i, e in ipairs(fresh) do
        map[key_of(e)] = e
        if e.download_state == "downloading" then downloading = downloading + 1 end
        if #OfflineLibrary.failedChapters(e.source_id, e._id) > 0 then retryable = true end
    end
    local controls_changed = retryable ~= self._retry_available
        or downloading ~= self._downloading_count

    local changed = false
    local changed_ids = {}
    for i, comic in ipairs(self.list.buffer) do
        local e = map[key_of(comic)]
        if e then
            local pct = e.download_progress or 0
            if e.download_state ~= comic.download_state
                or e.download_done ~= comic.download_done or e.download_failed ~= comic.download_failed
                or e.download_retryable ~= comic.download_retryable or e.download_pending ~= comic.download_pending
                or e.download_wait_message ~= comic.download_wait_message
                or e.download_prepare_stage~=comic.download_prepare_stage
                or e.download_prepare_current~=comic.download_prepare_current
                or e.download_prepare_total~=comic.download_prepare_total
                or e.download_total~=comic.download_total
                or e.download_preparing ~= comic.download_preparing
                or math.abs(pct - (comic.download_progress or 0)) >= 0.005 then
                changed = true
                changed_ids[comic._id] = true
            end
            comic.download_state = e.download_state
            comic.download_preparing = e.download_preparing
            comic.download_prepare_stage=e.download_prepare_stage
            comic.download_prepare_current=e.download_prepare_current
            comic.download_prepare_total=e.download_prepare_total
            comic.download_wait_message=e.download_wait_message
            comic.download_progress = pct
            comic.download_done = e.download_done
            comic.download_total = e.download_total
            comic.download_failed=e.download_failed;comic.download_retryable=e.download_retryable;comic.download_pending=e.download_pending
            self.list.buffer[i] = comic
        end
    end
    -- 新增/删除的条目: 整页重来 (数量变化很少发生, 值得一次重建)
    local count_changed = (#fresh ~= #self.list.buffer)
    if count_changed or controls_changed then changed = true end
    return changed, changed_ids, count_changed or controls_changed
end

--- 本页当前是否是最上层 (详情页/对话框盖在上面时不要刷它)
function Downloads:isTop()
    local stack = UIManager._window_stack
    return stack ~= nil and #stack > 0 and stack[#stack].widget == self.list
end

--- 重绘当前屏 (不重新取数)
function Downloads:refreshList(list, force)
    list = list or self.list
    if not list or list._closed then return end
    -- 被详情页/对话框盖住时不要 setDirty: 刷新一个不在顶层的控件会作用到
    -- 当前画面上。也不要提前消耗变化，回到本页时 timer 会补一次。
    if not self:isTop() then return end
    local changed, changed_ids, page_changed = self:syncProgress()
    if not force and not changed then return end
    if page_changed then
        -- 条目、标题计数或重试入口变化时重建；普通进度仍只刷新对应行。
        self:reloadPage()
        return
    end
    if force then list:renderWindow(false);return end
    -- 只刷新**变化了的**可见行: 下载中每 1.5 秒整屏重绘在电子墨水屏上
    -- 就是持续闪动; 没变化的行也不该重建控件。
    list:refreshVisible(changed_ids)
end

function Downloads:startTimer()
    if self._timer or self._closed then return end
    self._timer = true
    local callback
    callback=function()
        if self._timer_callback~=callback then return end
        self._timer_callback=nil
        self._timer = false
        if self._closed or not self.list or self.list._closed then return end
        if not self:isTop() then
            -- 下载可能在弹窗/详情背后结束，返回列表后仍须补上最终状态。
            self:startTimer()
            return
        end
        local q = self.queue or DownloadQueue.instance()
        local active = q and q:is_active()
        if active then
            self:refreshList()
            self:startTimer()
        else
            -- 队列刚结束: 再对一次账, 让最后一条从"下载中"变成普通样式
            self:refreshList()
        end
    end
    self._timer_callback=callback
    UIManager:scheduleIn(self.refresh_interval,callback)
end

--- 按源的 identifier 找源实例
function Downloads:sourceFor(sid)
    local ok, SourceRegistry = pcall(require, "source.registry")
    if not ok or not SourceRegistry then return nil end
    local source = SourceRegistry:get(sid)
    return source and not source._offline and source or nil
end

--- 把指定章节重新加入下载队列 (不弹提示, 供单个/批量复用)
-- @return queued, err
function Downloads:_enqueueRetry(comic, chapters)
    if not chapters or #chapters == 0 then return 0 end
    local sid = comic.source_id or "unknown"
    local source = self:sourceFor(sid)
    if not source then
        return 0, T(_("找不到源 %1"), sid)
    end
    local queue = self.queue or DownloadQueue.instance()
    local ok,queued,skipped = pcall(queue.enqueue, queue, source, comic, chapters)
    if not ok then
        return 0, tostring(queued)
    end
    return tonumber(queued) or 0,nil,tonumber(skipped)or 0
end

-- Use the current manifest after enqueue: stale buttons may refer to chapters
-- that completed or entered the queue while a dialog was open.
function Downloads:retryStatusMessage(err, skipped, comic)
    if err then return require("ui.common.error_message").describe(err, _("重新下载失败")) end
    if (skipped or 0)>0 then return _("这些章节已完成或已在队列中，无需重复加入。") end
    local pending, unfinished = 0, 0
    for _,entry in ipairs(self:entries()) do
        if not comic or entry.source_id==comic.source_id and entry._id==comic._id then
            pending=pending+(entry.download_pending or 0)
            unfinished=unfinished+math.max(0,(entry.download_total or 0)-(entry.download_done or 0))
        end
    end
    if pending>0 then return _("其余章节正在排队或下载，当前没有需要重试的章节。") end
    if unfinished==0 then return _("全部章节已下载完成。") end
    return _("下载状态已变化，请刷新后重试。")
end

--- 重新下载一部漫画的失败章节 (详情页/整行入口)
function Downloads:retryChapters(comic, chapters)
    local queued,err,skipped = self:_enqueueRetry(comic, chapters)
    self:repaintAfterRetry()
    self:startTimer()
    UIManager:show(InfoMessage:new{
        text = queued>0 and T(_("已重新加入 %1 %2下载"), queued,chapter_unit(comic))
            or self:retryStatusMessage(err, skipped, comic),
        timeout = queued>0 and 3 or 4,
    }, "ui")
    return queued
end

--- 列表页脚「继续下载」: 把所有漫画的失败章节一起重新排队
function Downloads:retryAllFailed()
    local entries = self:entries()
    local plans = {}
    for _i, e in ipairs(entries) do
        local chapters = OfflineLibrary.failedChapters(e.source_id, e._id)
        if #chapters > 0 then
            plans[#plans + 1] = { comic = to_comic(e), chapters = chapters }
        end
    end
    local total,first_err,skipped=0,nil,0
    for _i, p in ipairs(plans) do
        local queued,err,already = self:_enqueueRetry(p.comic, p.chapters)
        total = total + queued
        skipped=skipped+(already or 0)
        if queued <= 0 and not first_err then first_err = err end
    end
    if total <= 0 then
        local message=self:retryStatusMessage(first_err, skipped)
        self:repaintAfterRetry();self:startTimer()
        UIManager:show(InfoMessage:new{
            text = message,
            timeout = 4,
        }, "ui")
        return 0
    end
    self:repaintAfterRetry();self:startTimer()
    UIManager:show(InfoMessage:new{
        text = T(_("已重新加入 %1 个章节下载"), total),
        timeout = 3,
    }, "ui")
    return total
end

--- 整页重来 (条目数变化/页脚需要重建时)
function Downloads:reloadPage()
    local cb = self.return_callback
    local screen = self.list and self.list.screen_index or 1
    self._closed = false
    -- 不在这里关旧列表: show 内部会先建新列表再关旧的 (见其注释)
    if self:show(cb) and self.list and screen > 1 then
        self.list:jumpToScreen(math.min(screen,self.list:loadedScreens()))
    end
end

--- 重试后整屏重画一次
--
-- 只走 refreshVisible 的逐行刷新时, 底部按钮栏可能停在"没被标脏"的状态
-- (真机反馈: 点完重试, 列表刷了一下, 页脚整条消失)。重试是低频操作,
-- 直接重建当前屏 + 整页标脏, 保证页脚也跟着画出来。
function Downloads:repaintAfterRetry()
    if not self.list or self.list._closed then return end
    if not self:isTop() then return end
    self:refreshList(nil,true)
end

--- 打开一部已下载漫画的详情
-- 只把**已完整下载**的章节放进 episodes_data: 离线状态下点没下完的章节
-- 只会走到网络请求, 然后失败 —— 那不如不显示。
function Downloads:openComic(comic, navigation)
    local sid = comic.source_id or "unknown"
    -- A novel catalogue uses committed metadata. Verify only the chapter the
    -- user opens, rather than hashing every chapter and illustration here.
    local chapters = OfflineLibrary.completedChapters(sid, comic._id,{verify=comic.content_type~="novel"})
    local failed = OfflineLibrary.failedChapters(sid, comic._id)
    if #chapters == 0 then
        if #failed > 0 then
            -- 一章都没下成: 直接给"重新下载", 不要只留一句"没有完整章节"
            local dialog
            dialog = ButtonDialog:new{
                is_picayomi_page = true,
                title = T(_("「%1」上次下载未完成"), comic.title or comic._id),
                text = T(_("还有 %1 %2没有下载完成，要重新下载吗？"), #failed,chapter_unit(comic)),
                buttons = {
                    {
                        {
                            text = _("重新下载"),
                            callback = function()
                                UIManager:close(dialog, "ui")
                                self:retryChapters(comic, failed)
                            end,
                        },
                    },
                    {
                        {
                            text = _("取消"),
                            callback = function() UIManager:close(dialog, "ui") end,
                        },
                    },
                },
            }
            UIManager:show(dialog, "ui")
        else
            UIManager:show(InfoMessage:new{
                text = _("这部作品还没有完整下载的章节"),
                timeout = 3,
            }, "ui")
        end
        return
    end

    local SourceRegistry = require("source.registry")
    local source = SourceRegistry:get(sid)
    if not source then
        source = require("source.offline").new(sid)
    end
    if comic.content_type=="novel" then source.content_type="novel" end
    -- Detail and reader carry source_id explicitly. Opening a downloaded work
    -- must not change the source selected for browsing on the home page.

    local episodes = {}
    for _i, ch in ipairs(chapters) do
        episodes[#episodes + 1] = {
            _id=ch.id,
            order = ch.order,
            title = ch.title,
            pagesCount = ch.pages,
            sort_index = ch.sort_index,
        }
    end

    local extra_actions
    if #failed > 0 then
        extra_actions = {
            {
                text = T(_("重新下载失败章节（%1 %2）"), #failed,chapter_unit(comic)),
                callback = function()
                    self:retryChapters(comic, failed)
                end,
            },
        }
    end

    UIManager:show(ComicDetail:new{
        navigation = navigation,
        comic = comic,
        source = source,
        source_id = sid,
        episodes_data = {
            episodes = episodes,
            page = 1,
            pages = 1,
            total = #episodes,
        },
        offline = true,
        extra_actions = extra_actions,
        on_back = navigation and navigation.on_back,
        on_return_from_reader = function() end,
    }, "ui")
end

-- ============================================================================
-- 删除下载
-- ============================================================================
--
-- 为什么要有: 已下载页只管"看"和"重试", 没有任何办法把占空间的旧漫画删掉 ——
-- Kindle 的存储本来就紧, 用户只能连电脑删目录 (而且清单里还留着一条空记录)。
--
-- 交互: 页脚「删除下载」-> 选一部 -> 确认框 -> 取消该漫画在跑的/排队的任务,
-- 再删图片与清单条目。**必须先取消队列**: 否则正在写的那一页会在 os.remove
-- 之后落盘, 于是"删了又回来", 而且清单里会重新出现一条半截记录。

--- 列出已下载的漫画, 选一部来删
--
-- 用**漫画列表的卡片样式**而不是纯文字菜单: 只有标题时, 同名作品/译名不同/
-- 记不清哪本是哪本的情况根本分不清 (用户反馈"看不到封面, 容易分不清")。
-- 卡片里自带封面 + 作者/分类 + 下载进度, 与「已下载」页长得一模一样,
-- 用户点的就是刚才看到的那一行。
function Downloads:showDeleteMenu()
    local entries = self:entries()
    if #entries == 0 then
        UIManager:show(InfoMessage:new{
            text = _("还没有下载任何作品"),
            timeout = 3,
        }, "ui")
        return
    end

    -- 点选后要拿回**原始清单条目** (comic 是 to_comic 出来的副本)
    self.delete_entries = {}
    local comics = {}
    for _i, e in ipairs(entries) do
        local comic = to_comic(e)
        self.delete_entries[key_of(comic)] = e
        comics[#comics + 1] = comic
    end

    self.delete_menu = VisualComicList:new{
        title = T(_("删除下载（%1 部）"), #comics),
        comics = comics,
        server_page = 1,
        total_pages = 1,
        total_count = #comics,
        has_more = false,
        fetch_page = function(page)
            if tonumber(page) == 1 then
                return true, { comics = comics, page = 1, pages = 1, total = #comics }
            end
            return true, { comics = {}, page = page, pages = 1, total = #comics }
        end,
        processor = function(item) return item end,
        -- 点一部 -> 确认框 (不直接删)
        on_select = function(comic, navigation)
            if navigation and navigation.continue_reading then
                self:openComic(comic, navigation)
            else
                self:pickForDelete(comic)
            end
        end,
        on_back = function() self:closeDeleteMenu() end,
    }
    UIManager:show(self.delete_menu, "ui")
end

--- 删除页里点中一部: 找回原始条目, 弹确认框
function Downloads:pickForDelete(comic)
    local entry = comic and self.delete_entries and self.delete_entries[key_of(comic)]
    if not entry then return false end
    self:confirmDelete(entry)
    return true
end

function Downloads:closeDeleteMenu()
    if self.delete_menu then
        UIManager:close(self.delete_menu, "ui")
        self.delete_menu = nil
    end
    self.delete_entries = nil
end

--- 删除前的确认 (破坏性且不可恢复)
function Downloads:confirmDelete(entry)
    local title = entry.title or entry._id
    -- ConfirmBox 自己会在 ok_callback 之后关掉自己, 这里不要再 close 一次
    UIManager:show(ConfirmBox:new{
        text = T(_("确定删除《%1》的下载吗？\n\n可删除全部，或仅删除已读完章节；未读和半读章节会保留。删除的文件无法恢复。"), title),
        ok_text = _("删除全部"),
        cancel_text = _("取消"),
        no_ok_button = true,
        other_buttons_first = true,
        other_buttons = {{
            {text=_("删除已读"),callback=function()self:startDeleteDownload(entry,true)end},
            {text=_("删除全部"),callback=function()self:startDeleteDownload(entry)end},
        }},
        ok_callback = function()
            self:startDeleteDownload(entry)
        end,
    }, "ui")
end

function Downloads:startDeleteDownload(entry,read_only)
    if self._delete_task then return false end
    local Loading=require("ui.common.loading_task")
    local Async=require("network.async_task")
    local notice=require("ui.common.loading_progress"):new{
        title=_("删除下载"),progress={message=_("正在停止下载…")}}
    self._delete_task=true
    UIManager:show(notice,"ui");UIManager:forceRePaint()
    local ticks,last_update=0,0
    local function progress(done,total)
        ticks=ticks+1
        local now=require("socket").gettime()
        if now-last_update>=.25 or done==total then
            notice:update{message=_("正在删除章节文件…"),completed=done,total=total}
            last_update=now
        end
        if ticks%16==0 or done==total then Async.wait(.001)end
    end
    local function finish(rebuild)
        self._delete_task=nil
        if not self._closed then
            if rebuild and self.delete_menu then
                self:closeDeleteMenu();self:reloadPage()
                if self.list and not self._closed then self:showDeleteMenu()end
            else self:refreshList(nil,true)end
        end
    end
    self._delete_task=Loading.background(notice,function()
        self:deleteDownload(entry,progress,read_only)
        Loading.close(notice);finish()
    end,{delay=.05,timeout=600,is_cancelled=function()return self._closed end,
        on_cancel=function()finish(true)end,on_error=function(err)
            finish(true);if not self._closed then Loading.showFailure(err)end
        end})
    return true
end

--- 真正删除: 先取消队列, 再删文件与清单条目
-- @return 是否删掉了清单条目
function Downloads:deleteDownload(entry,progress,read_only)
    if type(entry) ~= "table" then return false end
    local sid = entry.source_id or "unknown"
    local cid = entry._id
    if cid == nil then return false end

    local orders=read_only and require("model.comic"):completedChapters(cid,sid)
    if orders and not next(orders)then
        UIManager:show(InfoMessage:new{text=_("没有已读完的下载章节，未删除任何文件。"),timeout=3},"ui")
        return false
    end
    -- 1) 停掉这一部在跑的/排队的任务 (别的漫画不受影响)
    local q = self.queue or DownloadQueue.instance()
    if q and q.cancelComic then
        local ok, err = pcall(function()
            q:cancelComic(sid, cid, _("已删除"))
        end)
        if not ok then
            logger.warn("Picayomi Downloads: 取消下载任务失败: " .. tostring(err))
            UIManager:show(InfoMessage:new{text=_("停止下载失败，未删除文件，请重试。"),timeout=3},"ui")
            return false
        end
    end

    -- 2) 删图片 + 清单
    local ok,remove_error
    if read_only then ok,remove_error=OfflineLibrary.removeChapters(sid,cid,orders,progress)
    else ok,remove_error=OfflineLibrary.remove(sid,cid,progress)end
    if not ok then
        UIManager:show(InfoMessage:new{
            text = T(_("删除未能完成：%1"),require("ui.common.error_message").describe(remove_error,_("该作品不在下载清单中。"))),
            timeout = 3,
        }, "ui")
        return false
    end

    if logger.enabled then logger.info(string.format("Picayomi Downloads: 已删除下载 %s/%s", sid, tostring(cid))) end

    -- 3) 重建列表。列表的 comics 是构造时定下的, 就地删一行会让分页/总数
    --    与页脚按钮对不上; reloadPage 是现成的整页重建路径。
    --    (删掉最后一条时它会走"还没有下载任何漫画"并返回上一层。)
    --
    --    删除页本身也要刷新: 用户常常连着删好几部, 每删一部就被踢回列表
    --    再重新点「删除下载」太啰嗦。先收掉旧的删除页, 主列表重建后再按新
    --    清单压回来; 清单空了 show() 会自己退出, 这时就不再压。
    local was_deleting = self.delete_menu ~= nil
    self:closeDeleteMenu()
    self:reloadPage()
    if was_deleting and self.list and not self._closed then
        self:showDeleteMenu()
    end
    return true
end

function Downloads:onClose()
    self:shutdown()
    if self.list then
        UIManager:close(self.list, "ui")
        self.list = nil
    end
    -- 跨源打开时可能切换了当前源; 返回前把主页菜单重建,
    -- 否则用户看到的是旧源的名字/能力 (点进去还会串 id)。
    pcall(function() require("ui.home").syncCurrentSource() end)
    if self.return_callback then self.return_callback() end
    return true
end

return Downloads
