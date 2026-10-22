-- util/download_queue.lua
-- 离线下载队列: 一次下一章, 逐页推进, 进度写进 util/offline_library。
--
-- 与阅读期下载 (util/download_scheduler.lua) 的分工:
--   * 阅读期调度按"用户正看哪一页"排优先级, 目标是**尽快显示当前页**;
--   * 离线下载没有"当前页", 目标是把用户勾选的章节**整章下完**,
--     所以它是一条朴素的队列: 一章下完再下一章, 章内逐页串行。
--   两者都复用同一个子进程传输层 (network/transport_worker), 主线程只做
--   poll/派活, 不阻塞输入。
--
-- 不变量:
--   * step() 单次最多收割 1 条、发起 1 条 (与 scheduleIn 的延迟 > 0 配合,
--     绝不 0 延迟自排 —— 那会饿死 UIManager 的输入循环);
--   * 任何网络/解析异常都只让**当前这一章**失败, 不影响队列里其余章节;
--   * 清单先写"downloading", 每下完一页更新 done; 真下完才写 "done"。
--     中途退出后 manifest 里的 done 页数仍在, 下次可以从头补 (已存在的页跳过)。
local logger = require("util.logger")
local lfs = require("libs/libkoreader-lfs")

local OfflineLibrary = require("util.offline_library")
local DownloadManager = require("network.download_manager")

local Queue = {}
Queue.__index = Queue

local TICK = 0.08          -- 秒; 必须 > 0 (见文件头)
local RETRY_LIMIT = 3      -- 单页最多尝试几次
local BUDGET_MS = 20       -- 单步留给 transport 的 CPU 预算
-- 单步最多往 transport 里塞几页。transport 自己是串行 (concurrency=1), 这里限制
-- 的是**主线程**的工作量: 一章可能有 200 页, 一次 step 里全 start 一遍就是 200 次
-- lfs.attributes (断点续传检查) + 200 次管道写 —— 在 e-ink 存储上足以卡住输入。
local MAX_PENDING = 2

local function default_schedule(fn, delay)
    local ok, UIManager = pcall(require, "ui/uimanager")
    if ok and UIManager then
        UIManager:scheduleIn(delay, fn)
        return true
    end
    return false
end

local function default_transport(source)
    return require("network.transport_worker").new{
        source = source,
        tag = "offline",
        fix_extension = function(path) return DownloadManager.fixImageExtension(path) end,
    }
end

--- 默认失败提示 (只在单例里启用; 单元测试用 Queue.new{} 不会弹窗)
local function default_error_notifier(job, msg)
    local ok, UIManager = pcall(require, "ui/uimanager")
    if not ok or not UIManager then return end
    local ok2, InfoMessage = pcall(require, "ui/widget/infomessage")
    if not ok2 or not InfoMessage then return end
    local name = (job and (job.title or (job.order and ("第" .. tostring(job.order) .. "话"))))
        or "章节"
    pcall(function()
        UIManager:show(InfoMessage:new{
            text = string.format("「%s」下载失败：%s", tostring(name), tostring(msg)),
            timeout = 5,
        }, "ui")
    end)
end

local function default_get_images(source, comic_id, order)
    -- 源的契约是 **(ok, data, err)**; pcall 自己还会再包一层状态, 所以必须接 4 个值。
    -- 只接 (ok, result) 会把源的布尔 ok 当成数据 —— 所有真实源都会失败, 而
    -- 测试里的假源直接返回 data, 恰好绕过了这个形态 (真机 源 B 下载报"获取图片失败")。
    local pok, ok, data, err = pcall(source.getAllChapterImages, source, comic_id, order)
    if not pok then return nil, tostring(ok) end
    if not ok then return nil, tostring(err or "获取章节图片失败") end
    if type(data) ~= "table" or type(data.images) ~= "table"
        or #data.images == 0 then
        return nil, "图片列表为空"
    end
    return data.images
end

--- @param opts.transport_factory function(source) -> transport (测试注入)
--- @param opts.get_images        function(source, comic_id, order) -> images, err
--- @param opts.schedule          function(fn, delay) (测试注入; 不注入则用 UIManager)
function Queue.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Queue)
    self.transport_factory = opts.transport_factory or default_transport
    self.get_images = opts.get_images or default_get_images
    self.schedule = opts.schedule or default_schedule
    self.retry_limit = opts.retry_limit or RETRY_LIMIT
    self.max_pending = math.max(1, tonumber(opts.max_pending) or MAX_PENDING)
    self.tick = opts.tick or TICK

    self.jobs = {}
    self.active = nil
    self.running = false
    self.scheduled = false
    self.pauses = {}
    self.version = 0          -- 每完成一页 +1, 供 UI 判断"要不要重绘"
    self.on_change = opts.on_change
    -- 失败必须让用户看见: 选择页关闭后队列在后台跑, 没有提示的话
    -- "点了没反应"和"下载失败"在界面上完全一样。
    self.on_error = opts.on_error
    return self
end

local function job_key(source_id, comic_id, order)
    return tostring(source_id) .. "|" .. tostring(comic_id) .. "|" .. tostring(order)
end

function Queue:_has_job(key)
    if self.active and self.active.key == key then return true end
    for _i, job in ipairs(self.jobs) do
        if job.key == key then return true end
    end
    return false
end

--- 已排队的章节数 (供 UI 显示)
function Queue:pending_count()
    local n = #self.jobs
    if self.active then n = n + 1 end
    return n
end

function Queue:is_active()
    return self.running or self.active ~= nil or #self.jobs > 0
end

-- Foreground reading owns the memory/IO budget until its session closes. Keep
-- committed pages and queued chapters; an unacknowledged in-flight page can be
-- fetched again on resume. Tokens allow overlapping old/new chapter sessions.
function Queue:pause(reason)
    local token = {}
    local first = next(self.pauses) == nil
    self.pauses[token] = reason or "reading"
    if first then
        self._tick_id = (self._tick_id or 0) + 1
        self.scheduled = false
        local job = self.active
        if job and job.transport then
            job.transport:close()
            job.transport = nil
            job.phase = "paused"
            OfflineLibrary.updateChapter(job.source_id, job.comic_id, job.order, {
                state = "partial", done = job.done, total = job.total,
            }, { force = true })
        end
        if self:is_active() then
            if logger.enabled then logger.info("Picayomi DownloadQueue: 阅读优先，暂停离线下载并释放通道") end
        end
    end
    local released = false
    return function()
        if released then return end
        released = true
        self.pauses[token] = nil
        if next(self.pauses) == nil then self:_schedule() end
    end
end

--- 加入下载队列
-- @param source  漫画源实例
-- @param comic   漫画 (至少 _id/title)
-- @param chapters {{order=, title=, pages=}, ...}
-- @return queued, skipped
function Queue:enqueue(source, comic, chapters)
    if not (source and comic and comic._id and type(chapters) == "table") then
        return 0, 0
    end
    local source_id = source.identifier or "unknown"

    local accepted = {}
    for _i, ch in ipairs(chapters) do
        if ch and ch.order ~= nil then
            local key = job_key(source_id, comic._id, ch.order)
            if not self:_has_job(key)
                and not OfflineLibrary.isChapterComplete(source_id, comic._id, ch.order) then
                accepted[#accepted + 1] = ch
                self.jobs[#self.jobs + 1] = {
                    key = key,
                    source = source,
                    source_id = source_id,
                    comic = comic,
                    comic_id = comic._id,
                    order = ch.order,
                    title = ch.title,
                    pages = tonumber(ch.pages),
                    phase = "queued",
                    done = 0,
                    total = 0,
                    bytes = 0,
                    attempts = {},
                    failed = {},
                }
            end
        end
    end

    local skipped = #chapters - #accepted
    if #accepted > 0 then
        OfflineLibrary.begin(source_id, comic, accepted)
        -- 顺手把封面存进封面缓存: 「已下载」列表要能在断网/未登录时显示封面。
        -- 失败不影响下载本身 (列表会退化成占位图)。
        pcall(function()
            require("util.cover_cache").ensure(source, source_id, comic, function() end)
        end)
        self.running = true
        self:_schedule()
    end
    if logger.enabled then logger.info(string.format("Picayomi DownloadQueue: 加入 %d 章 (跳过 %d 章: 已下载/已在队列)",
        #accepted, skipped)) end
    return #accepted, skipped
end

--- 取消: 停掉当前 transport, 队列清空, 当前章标 partial
function Queue:cancel(reason)
    if self.active then
        local job = self.active
        if job.transport then
            pcall(function() job.transport:cancel_all() end)
        end
        OfflineLibrary.updateChapter(job.source_id, job.comic_id, job.order, {
            state = "partial",
            done = job.done,
            total = job.total,
            error = reason or "已取消",
        }, { force = true })
    end
    -- 还没轮到的章节也要标成 partial: 否则清单里永远是 queued,
    -- 「已下载」列表会一直显示"下载中"转圈, 但队列其实已经停了。
    local touched = {}
    for _i, job in ipairs(self.jobs) do
        OfflineLibrary.updateChapter(job.source_id, job.comic_id, job.order, {
            state = "partial",
            error = reason or "已取消",
        }, { force = true })
        touched[job.source_id .. "|" .. tostring(job.comic_id)] = true
    end
    for key in pairs(touched) do
        local sid, cid = key:match("^(.-)|(.*)$")
        OfflineLibrary.setTargetsDone(sid, cid)
    end
    self.active = nil
    self.jobs = {}
    self.running = false
    if logger.enabled then logger.info("Picayomi DownloadQueue: 已取消 (" .. tostring(reason or "") .. ")") end
end

--- 取消**某一部漫画**的下载 (删除下载时用)
--
-- 与 cancel() 的区别: 只停这一部, 别的漫画照常继续下。删除下载必须先走这里 ——
-- 否则队列里的任务会在文件被删掉之后继续往那个目录里写, 于是"删了又回来"。
--
-- 被取消的章节标 partial 而不是删清单条目: 清单的删除由调用方
-- (OfflineLibrary.remove) 统一做, 这里只保证不再有写入。
--
-- @return 取消的章节数 (在跑的 + 排队的)
function Queue:cancelComic(source_id, comic_id, reason)
    local sid, cid = tostring(source_id), tostring(comic_id)
    local function match(job)
        return job ~= nil
            and tostring(job.source_id) == sid
            and tostring(job.comic_id) == cid
    end

    local n = 0
    if self.active and match(self.active) then
        local job = self.active
        if job.transport then
            -- cancel_all 会收掉 worker 子进程; 不做这一步的话, 正在写的这一页
            -- 会在 os.remove 之后落盘
            pcall(function() job.transport:cancel_all() end)
        end
        OfflineLibrary.updateChapter(job.source_id, job.comic_id, job.order, {
            state = "partial",
            done = job.done,
            total = job.total,
            error = reason or "已删除",
        }, { force = true })
        self.active = nil
        n = n + 1
    end

    local kept = {}
    for _i, job in ipairs(self.jobs) do
        if match(job) then
            OfflineLibrary.updateChapter(job.source_id, job.comic_id, job.order, {
                state = "partial",
                error = reason or "已删除",
            }, { force = true })
            n = n + 1
        else
            kept[#kept + 1] = job
        end
    end
    self.jobs = kept

    if self.active or #self.jobs > 0 then
        self.running = true
        self:_schedule()
    else
        self.running = false
    end

    if n > 0 then
        if logger.enabled then logger.info(string.format("Picayomi DownloadQueue: 取消 %s/%s 的 %d 章 (%s)",
            sid, cid, n, tostring(reason or ""))) end
    end
    return n
end

--- 退出应用: 杀掉子进程但不等待 (与 StreamSession:shutdown 同一约定)
function Queue:shutdown()
    if self.active then
        local job = self.active
        if job.transport and job.transport.terminate then
            pcall(function() job.transport:terminate() end)
        elseif job.transport then
            pcall(function() job.transport:cancel_all(true) end)
        end
        OfflineLibrary.updateChapter(job.source_id, job.comic_id, job.order, {
            state = "partial",
            done = job.done,
            total = job.total,
        }, { force = true })
    end
    self.active = nil
    self.jobs = {}
    self.running = false
end

--- 把一页已经落盘的文件算进进度 (重下/断点续传时跳过)
local function existing_page(job, page)
    if job.reuse_pages then
        if not job.reuse_pages[page] then return nil end
        return OfflineLibrary.reusablePage(job.source_id,job.comic_id,job.order,page)
    end
    local base = string.format("%s/%04d", job.dir, page)
    return DownloadManager.findExistingImage(base)
end

--- 为当前章取图片列表并起 transport
function Queue:_notify_error(job, msg)
    if self.on_error then pcall(self.on_error, job, msg) end
end

function Queue:_prepare(job)
    job.phase = "preparing"
    OfflineLibrary.updateChapter(job.source_id, job.comic_id, job.order, {
        state = "preparing",
        title = job.title,
        total = job.pages or 0,
        done = 0,
    }, { force = true })

    -- 取图片列表是**同步 HTTP**, 弱网下可能几秒。先弹一条提示并强制刷新,
    -- 否则用户看到的是"界面卡住/点了没反应" —— 这正是 v0.8.0 真机反馈。
    local UI, notice
    pcall(function()
        UI = require("ui/uimanager")
        local InfoMessage = require("ui/widget/infomessage")
        notice = InfoMessage:new{
            text = string.format("正在获取「%s」的章节信息…",
                tostring(job.title or job.order)),
        }
        UI:show(notice, "ui")
        UI:forceRePaint()
    end)

    local pok, images, err = pcall(self.get_images, job.source, job.comic_id, job.order)
    if notice and UI then pcall(function() UI:close(notice, "ui") end) end
    if not pok then
        err = images
        images = nil
    end

    if not images then
        job.phase = "failed"
        OfflineLibrary.updateChapter(job.source_id, job.comic_id, job.order, {
            state = "failed",
            error = tostring(err or "获取章节图片失败"),
        }, { force = true })
        logger.warn("Picayomi DownloadQueue: 第 " .. tostring(job.order)
            .. " 章取图片列表失败: " .. tostring(err))
        self:_notify_error(job, tostring(err or "获取章节图片失败"))
        return false
    end

    job.images = images
    job.total = #images
    local saved,save_error,reuse=pcall(OfflineLibrary.setPageManifest,job.source_id,job.comic_id,job.order,job.source,images)
    if not saved then
        job.phase="failed"
        OfflineLibrary.updateChapter(job.source_id,job.comic_id,job.order,{state="failed",error=tostring(save_error)},{force=true})
        self:_notify_error(job,"无法保存离线图片处理信息，请升级源后重试")
        return false
    end
    job.reuse_pages=reuse
    job.dir = OfflineLibrary.chapterDir(job.source_id, job.comic_id, job.order)
    OfflineLibrary.ensureDir(job.dir)

    local transport = self.transport_factory(job.source)
    if not transport then
        job.phase = "failed"
        OfflineLibrary.updateChapter(job.source_id, job.comic_id, job.order, {
            state = "failed", error = "无法创建下载通道", total = job.total,
        }, { force = true })
        self:_notify_error(job, "无法创建下载通道")
        return false
    end
    job.transport = transport
    job.next_page = 1
    job.phase = "downloading"
    OfflineLibrary.updateChapter(job.source_id, job.comic_id, job.order, {
        state = "downloading",
        total = job.total,
        done = job.done,
    }, { force = true })

    -- 真正的逐页发起在 _fill_transport 里 (每步有预算, 见 MAX_PENDING 的说明)
    return true
end

--- 往 transport 里补任务, 但每步的工作量有上界
--
-- 两步预算分开设:
--   * started: 真正发起下载的页数 (transport 串行, 多了也只是排队);
--   * checked: 断点续传检查的页数 (每页一次 stat, e-ink 存储上不便宜)。
-- 全部做完只是"把 200 页 start 一遍"的话, 主线程会卡住 —— 这正是本插件
-- 一直在消灭的那类卡顿。
function Queue:_fill_transport(job)
    if job.phase ~= "downloading" or not job.transport then return false end
    local checks = 16
    local starts = self.max_pending
    local changed = false

    while job.next_page <= job.total and checks > 0 and starts > 0 do
        local page = job.next_page
        job.next_page = page + 1
        checks = checks - 1

        if existing_page(job, page) then
            -- 上次下到一半 / 阅读过这一章: 不重复下载
            job.done = job.done + 1
            changed = true
        elseif not job.failed[page] then
            job.transport:start{
                page = page,
                image = job.images[page],
                url = job.images[page]
                    and (job.images[page].url or job.images[page].local_path),
                dest = string.format("%s/%04d.jpg", job.dir, page),
            }
            starts = starts - 1
        end
    end

    if changed then
        OfflineLibrary.updateChapter(job.source_id, job.comic_id, job.order, {
            state = "downloading",
            done = job.done,
            total = job.total,
        })
    end
    return changed
end

--- 当前章收尾: 没失败页才算 done
function Queue:_finish_chapter(job)
    if job.transport then
        pcall(function() job.transport:close() end)
        job.transport = nil
    end

    local failed_count = 0
    for _p in pairs(job.failed) do failed_count = failed_count + 1 end

    local state = (failed_count == 0 and job.done >= job.total) and "done" or "partial"
    OfflineLibrary.updateChapter(job.source_id, job.comic_id, job.order, {
        state = state,
        done = job.done,
        total = job.total,
        bytes = job.bytes,
        error = failed_count > 0 and (failed_count .. " 页下载失败") or nil,
    }, { force = true })
    OfflineLibrary.setTargetsDone(job.source_id, job.comic_id)

    if logger.enabled then logger.info(string.format("Picayomi DownloadQueue: 第 %s 章 %s (%d/%d 页)",
        tostring(job.order), state, job.done, job.total)) end
    local cancelled = job.failed[-1] ~= nil
    if failed_count > 0 and not cancelled then
        self:_notify_error(job,
            string.format("%d 页下载失败，可重新下载", failed_count))
    end
    job.phase = "done"
    return true
end

--- 推进一步 (公开: 测试里手动泵; 生产由 _schedule 驱动)
function Queue:step()
    if next(self.pauses) ~= nil then return false end
    if not self.running and not self.active and #self.jobs == 0 then
        return false
    end

    -- 1) 没有在跑的章: 取下一章
    if not self.active then
        self.active = table.remove(self.jobs, 1)
        if not self.active then
            self.running = false
            return false
        end
        return self:_prepare(self.active)
    end

    local job = self.active

    if job.phase == "paused" then
        -- Rebuild from the manifest, never trust a file whose completion frame
        -- was discarded while releasing the worker.
        job.done = 0
        return self:_prepare(job)
    end

    -- 2) 准备阶段失败/完成: 换下一章
    if job.phase == "failed" or job.phase == "done" then
        self.active = nil
        return true
    end

    -- 3) 正在下载: 补任务 -> 收割 -> 再补 (让腾出的并发位下一拍就能用上)
    self:_fill_transport(job)
    local res = job.transport:poll(BUDGET_MS) or {}
    local changed = false
    for _i, item in ipairs(res.done or {}) do
        if item.ok then
            OfflineLibrary.markPageReady(job.source_id,job.comic_id,job.order,item.page,item.path)
            job.done = job.done + 1
            job.bytes = job.bytes + (tonumber(item.size) or 0)
            changed = true
            self.version = self.version + 1
        else
            local n = (job.attempts[item.page] or 0) + 1
            job.attempts[item.page] = n
            if item.retryable~=false and n < self.retry_limit then
                -- 失败不留残文件 (transport 已删); 原样重排这一页
                job.transport:start{
                    page = item.page,
                    image = job.images[item.page],
                    url = job.images[item.page] and
                        (job.images[item.page].url or job.images[item.page].local_path),
                    dest = string.format("%s/%04d.jpg", job.dir, item.page),
                }
            else
                job.failed[item.page] = item.err or "下载失败"
                logger.warn(string.format(
                    "Picayomi DownloadQueue: 第 %s 章第 %d 页放弃 (%s)",
                    tostring(job.order), item.page, tostring(item.err)))
            end
        end
    end

    if changed then
        OfflineLibrary.updateChapter(job.source_id, job.comic_id, job.order, {
            state = "downloading",
            done = job.done,
            total = job.total,
        })
        -- UI 回调抛异常不能连累下载本身 (它只是"顺便刷新一下")
        if self.on_change then pcall(self.on_change, self, job) end
    end

    -- 4) 所有页都发过 + 通道空闲: 本章结束
    --
    -- **不能只看 res.idle**: 它是 poll 返回时的快照, 而上面可能刚把失败页
    -- 重新 start 回队列 —— 那一刻 pending 里已经有活了, 用旧快照收尾会把
    -- "还会重试的页"直接判死 (真机表现: 偶发失败一次就永久 partial)。
    -- 判据是"没有下一页要发" + transport 当前真的空闲。
    -- 这里不再补任务: 补了会让"单步发起页数"超过 max_pending 的上界
    -- (测试会断言), 而 80ms 后的下一拍马上就会补上。
    local still_busy = job.transport and job.transport.busy and job.transport:busy()
    if job.next_page > job.total and not still_busy then
        local cancelled = job.transport and job.transport.is_cancelled
            and job.transport:is_cancelled()
        if cancelled then
            job.failed[-1] = "已取消"
        end
        self:_finish_chapter(job)
        self.active = nil
        return true
    end
    return true
end

--- 内部一拍: 走一步并按 TICK 重排自己
--- @param id 排期号: 挂起恢复后旧 timer 仍可能被触发, 只认最新那一拍
function Queue:_tick(id)
    if id and id ~= self._tick_id then return end
    self.scheduled = false
    if not self.running and not self.active and #self.jobs == 0 then
        return
    end
    local ok, err = pcall(self.step, self)
    if not ok then
        logger.warn("Picayomi DownloadQueue: step 异常: " .. tostring(err))
        if self.active then
            self.active.phase = "failed"
            OfflineLibrary.updateChapter(self.active.source_id, self.active.comic_id,
                self.active.order, { state = "partial", error = tostring(err) }, { force = true })
            if self.active.transport then
                pcall(function() self.active.transport:cancel_all() end)
            end
            self.active = nil
        end
    end
    self:_schedule()
end

--- 外部补一脚 (挂起恢复后事件循环里的排期可能被丢掉)
--
-- 挂起时 UIManager 会丢掉已排期的任务, 但 self.scheduled 可能还停在 true ——
-- 不强制重排的话队列就永远停住。旧 timer 若之后又被触发, 由 _tick_id 挡住,
-- 避免出现两条并行的自续期链 (每一拍都做两次 step)。
function Queue:kick()
    if not self:is_active() then return end
    self.scheduled = false
    self._tick_id = (self._tick_id or 0) + 1
    self:_schedule()
end

function Queue:_schedule()
    if next(self.pauses) ~= nil then return end
    if self.scheduled then return end
    if not (self.running or self.active or #self.jobs > 0) then return end
    self.scheduled = true
    self._tick_id = (self._tick_id or 0) + 1
    local id = self._tick_id
    if not self.schedule(function() self:_tick(id) end, self.tick) then
        -- 无 UI 环境 (纯逻辑测试): 不自动泵, 由调用方 step()
        self.scheduled = false
    end
end

-- ============================================================================
-- 单例 (生产路径)
-- ============================================================================
local instance

function Queue.instance()
    if not instance then
        instance = Queue.new{ on_error = default_error_notifier }
    end
    return instance
end

--- 测试用: 替换单例 (传 nil 恢复默认)
function Queue.set_instance(q)
    instance = q
end

return Queue
