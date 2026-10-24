-- ui/download_select.lua
-- 章节选择页: 勾选要离线保存的章节, 开始下载。
--
-- 为什么是独立页面而不是详情页里的弹窗:
--   章节可能几十上百条, 弹窗放不下; 详情页本身是"等高行分页 ListView",
--   结构上不支持再嵌一个可滚动区域 (与评论页同一类约束)。
--
-- 交互: 点一行切换勾选; 「全选本页」批量切换; 「开始下载」把勾选的章节
-- 交给 util/download_queue。已下载的章节显示 ✓ 且不可重复勾选。
local Device = require("device")
local Menu = require("ui.common.action_style").Menu
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local Screen = Device.screen
local _ = require("gettext")
local T = require("ffi/util").template
local logger = require("util.logger")
local util = require("util")

local MenuStyle = require("ui.common.menu_style")
local MenuSwipe = require("ui.common.menu_swipe")
local TapGuard = require("ui.common.tap_guard")
local OfflineLibrary = require("util.offline_library")
local DownloadQueue = require("util.download_queue")

local DownloadSelect = WidgetContainer:extend{
    name = "picayomi_download_select",
    title = _("下载章节"),
    is_picayomi_page = true,
    comic = nil,
    source = nil,
    source_id = nil,
    episodes_data = nil,
    queue = nil,            -- 测试注入; 缺省用 DownloadQueue 单例
    -- 开始下载后自动跳到「已下载」页: 那里有进度条, 用户能立刻看到"真的在下载"。
    -- 测试里关掉, 避免多压一层页面。
    auto_show_downloads = true,
    on_back = nil,
    width = nil,
    height = nil,
}

function DownloadSelect:init()
    self.width = self.width or Screen:getWidth()
    self.height = self.height or Screen:getHeight()
    self.source_id = self.source_id
        or (self.source and self.source.identifier) or "unknown"

    -- 只取有 order 的章节 (理论上都有; 坏数据直接忽略)
    self.episodes = {}
    for _i, ep in ipairs((self.episodes_data and self.episodes_data.episodes) or {}) do
        if ep and ep.order ~= nil then
            self.episodes[#self.episodes + 1] = ep
        end
    end

    self.selected = {}
    self.downloaded = {}
    for _i, ep in ipairs(self.episodes) do
        if OfflineLibrary.chapterMarkedDone(self.source_id, self.comic and self.comic._id, ep.order) then
            self.downloaded[ep.order] = true
        end
    end

    self:buildMenu()
end

--- 菜单行由 TextWidget 渲染 (不会自动出省略号), 太长会被**静默截断**。
-- 自己截断并补 "…", 至少让用户知道后面还有字。
local MAX_TITLE_CHARS = 16
local function shorten(text, max)
    local chars = util.splitToChars(tostring(text or ""))
    if #chars <= max then return text end
    return table.concat(chars, "", 1, max) .. "…"
end

function DownloadSelect:chapterLabel(ep)
    local title = shorten(ep.title or T(_("第%1话"), ep.order), MAX_TITLE_CHARS)
    local pages = tonumber(ep.pagesCount or ep.total or ep.pages)
    if pages and pages > 0 then
        return T(_("%1 (%2 页)"), title, pages)
    end
    return title
end

function DownloadSelect:selectedCount()
    local n = 0
    for _k, v in pairs(self.selected) do
        if v then n = n + 1 end
    end
    return n
end

function DownloadSelect:allSelected()
    local n = 0
    for _i, ep in ipairs(self.episodes) do
        if not self.downloaded[ep.order] then
            n = n + 1
            if not self.selected[ep.order] then return false end
        end
    end
    return n > 0
end

--- 组装菜单条目 (每次勾选变化后重建; Menu:init 之后调用 updateItems)
function DownloadSelect:buildItemTable()
    local items = {}
    local selectable = 0
    for _i, ep in ipairs(self.episodes) do
        if not self.downloaded[ep.order] then selectable = selectable + 1 end
    end

    -- 这一页有四类行 (跳转 / 主操作 / 批量 / 说明 / 章节), 功能差异很大。
    -- 以前它们全是同一副样子, 真机反馈"分不清哪个是按钮、哪个是标题"。
    -- 现在用**符号 + 缩进 + 字重/灰度**把它们分成三层:
    --   → 跳转     ▶ 主操作 (加粗)     ■/□ 批量操作
    --   · 说明 (灰)                    章节行 (缩进 + 勾选标记)
    local indent = Screen:scaleBySize(16)

    -- 「查看已下载」放最上面: 章节可能几十条, 放在下面就等于"翻到底才能看进度"。
    table.insert(items, {
        text = "→ " .. self:downloadsLabel(),
        callback = function() self:showDownloads() end,
    })

    -- 主操作: 加粗 + ▶, 一眼能认出"这一步是真正开始下载的按钮"。
    table.insert(items, {
        text = T(_("▶ 开始下载（已选 %1 话）"), self:selectedCount()),
        bold = true,
        picayomi_primary = true,
        enabled = self:selectedCount()>0,
        select_enabled = self:selectedCount()>0,
        callback = function() self:startDownload() end,
    })
    table.insert(items, {
        text = self:allSelected()
            and _("□ 取消全选")
            or T(_("■ 全选本页（%1 话可选）"), selectable),
        enabled = selectable > 0,
        callback = function() self:toggleAll() end,
    })
    -- 说明行: 灰字 + 圆点前缀, 与可点的行区分开 (它本来也点不动)
    table.insert(items, {
        text = T(_("· 已下载 %1/%2 话 · 点下面的章节切换选中"),
            self:downloadedCount(), #self.episodes),
        enabled = false,
        select_enabled = false,
        dim = true,
    })
    -- 章节本身是分页的 (源 A 常见): 本页只列当前章节页。说清楚比让用户
    -- 以为"只有这几章"要好 —— 翻章节页仍然在详情页做 (那里已有跳转章节页)。
    local ed = self.episodes_data or {}
    if (tonumber(ed.pages) or 1) > 1 then
        table.insert(items, {
            text = T(_("仅列出当前章节页 (%1/%2)，更多章节请先在详情页翻页"),
                tonumber(ed.page) or 1, tonumber(ed.pages)),
            enabled = false,
            select_enabled = false,
        })
    end

    for _i, ep in ipairs(self.episodes) do
        local is_downloaded = self.downloaded[ep.order] == true
        local is_selected = self.selected[ep.order] == true
        local mark = is_downloaded and _("[已下载]")
            or (is_selected and _("[已选]") or _("[未选]"))
        local text = T(_("%1 %2"), mark, self:chapterLabel(ep))
        table.insert(items, {
            text = text,
            picayomi_list_item = true,
            -- 缩进: 章节是"列表项", 与上面的操作行拉开层级 (与目录树同一套机制)
            indent = indent,
            -- 已勾选的加粗: 一屏里十几行, 靠字重比靠 [已选] 两个字更快扫到
            bold = is_selected,
            enabled = not is_downloaded,
            callback = function() self:toggleChapter(ep.order) end,
        })
    end

    -- 「返回」固定放最后, 与列表页/详情页的按钮顺序一致 (那里也是 返回 收尾)。
    table.insert(items, {
        text = _("返回"),
        callback = function() self:goBack() end,
    })

    return items
end

--- 「查看已下载」按钮文案: 带上部数, 让用户知道点进去有没有东西可看
function DownloadSelect:downloadsLabel()
    local n = 0
    -- 清单读取是纯本地 JSON; 失败也不能让按钮消失 (下载页自己会给空提示)
    pcall(function() n = #OfflineLibrary.list() end)
    if n > 0 then
        return T(_("查看已下载（%1 部）"), n)
    end
    return _("查看已下载")
end

function DownloadSelect:downloadedCount()
    local n = 0
    for _k, v in pairs(self.downloaded) do
        if v then n = n + 1 end
    end
    return n
end

function DownloadSelect:buildMenu()
    local item_table = self:buildItemTable()
    local title_bar = MenuStyle.titleBar{
        title = T(_("选择要下载的章节 · %1"), (self.comic and self.comic.title) or ""),
    }
    self.menu = Menu:new{
        is_picayomi_page = true,
        title = title_bar.title,
        custom_title_bar = title_bar,
        item_table = item_table,
        width = self.width,
        height = self.height,
        full_width = true,
        is_popout = false,
        covers_fullscreen = true,
        close_callback = function() self:_menuClosed() end,
    }
    -- 我们拿 close_callback 当"返回键退出", 而上游 onMenuSelect 在条目 callback
    -- 之后还会**无条件**再调一次 (menu.lua:1394) —— 每点一个章节都会把整页关掉,
    -- 真机表现是"点了没反应/界面一闪没了"。统一用 MenuStyle 的守卫拦住这一段;
    -- 返回键仍走 Menu:onClose -> onCloseAllMenus -> close_callback -> goBack。
    MenuStyle.disableSelectAutoClose(self.menu)
    -- 左右滑动: 左滑 = 下一页, 右滑 = 上一页, **第一页右滑 = 退出选择页**。
    -- 章节多的作品这里会有好几页, 而 Menu 自带的翻页是**循环**的:
    -- 第一页往"上一页"滑会直接跳到最后一页 (真机反馈"怎么不是返回, 而是到了最后一页")。
    MenuSwipe.attach(self.menu, function() self:goBack() end)
    TapGuard.install(self.menu)
end

function DownloadSelect:refresh()
    if not self.menu then return end
    self.menu.item_table = self:buildItemTable()
    self.menu:updateItems()
end

function DownloadSelect:toggleChapter(order)
    if self.downloaded[order] then return end
    self.selected[order] = not self.selected[order] or nil
    self:refresh()
end

function DownloadSelect:toggleAll()
    local target = not self:allSelected()
    self.selected = {}
    if target then
        for _i, ep in ipairs(self.episodes) do
            if not self.downloaded[ep.order] then
                self.selected[ep.order] = true
            end
        end
    end
    self:refresh()
end

--- 勾选的章节 (按本页顺序)
function DownloadSelect:selectedChapters()
    local out = {}
    for _i, ep in ipairs(self.episodes) do
        if self.selected[ep.order] then
            out[#out + 1] = {
                order = ep.order,
                sort_index = ep.sort_index,
                title = ep.title,
                pages = tonumber(ep.pagesCount or ep.total or ep.pages),
            }
        end
    end
    return out
end

--- 这次下载是不是"只存在本机" (源没有账号, 或者当前没登录)
--
-- 源 C 这类免登录源没有账号体系, 下载下来的东西只在本机 —— 提示里要标出来。
-- 用 pcall 包一层: 测试里的桩源不一定实现 isLoggedIn。
function DownloadSelect:isLocalOnlySource()
    local source = self.source
    if not source then return true end
    local ok, logged = pcall(function() return source:isLoggedIn() end)
    return not (ok and logged)
end

--- 「已开始下载 N 章…」的文案 (免登录源追加「(本地)」)
--
-- 单独抽出来是为了能测: 文案在 startDownload 里内联时, 测试只能真的跑一遍
-- 入队 (依赖队列/源实现), 而这句提示本身跟队列无关。
function DownloadSelect:downloadStartedText(queued)
    local text = T(_("已开始下载 %1 话…"), queued)
    if self:isLocalOnlySource() then
        text = text .. _("（本地）")
    end
    return text
end

function DownloadSelect:startDownload()
    local chapters = self:selectedChapters()
    if #chapters == 0 then
        UIManager:show(InfoMessage:new{
            text = _("还没有选中章节。\n先点下面任意章节，行首变成「[已选]」后再点开始下载。"),
            timeout = 5,
        }, "ui")
        return false, 0
    end

    local queue = self.queue or DownloadQueue.instance()
    -- 队列内部要写清单/建目录; 任何异常都要变成可见提示, 不能静默失败
    local ok, queued, skipped = pcall(queue.enqueue, queue, self.source, self.comic, chapters)
    if not ok then
        logger.warn("Picayomi DownloadSelect: 加入队列失败: " .. tostring(queued))
        UIManager:show(InfoMessage:new{
            text = T(_("加入下载队列失败：%1"), require("ui.common.error_message").describe(queued)),
            timeout = 5,
        }, "ui")
        return false, 0
    end

    self.selected = {}
    self:refresh()

    if logger.enabled then logger.info(string.format("Picayomi DownloadSelect: 选中 %d 章, 入队 %d, 跳过 %d",
        #chapters, queued or 0, skipped or 0)) end

    if (queued or 0) == 0 then
        UIManager:show(InfoMessage:new{
            text = _("所选章节都已下载"),
            timeout = 3,
        }, "ui")
        return true, 0
    end

    UIManager:show(InfoMessage:new{
        text = self:downloadStartedText(queued),
        timeout = 2,
    }, "ui")

    -- 立刻进入「已下载」: 进度条在那里。停在选择页会让用户觉得"点了没反应"。
    if self.auto_show_downloads ~= false then
        self:showDownloads()
    end
    return true, queued
end

--- 跳转到「已下载」页 (进度条/失败重试都在那里)
-- 先关掉自己再打开: 下载页是整屏页面, 叠在选择页上会让"返回"多退一层,
-- 而用户的心智是"从选择页去了下载页", 退回来应该直接到详情页。
function DownloadSelect:showDownloads()
    self:goBack()
    local ok, err = pcall(function()
        require("ui.downloads"):new{ queue = self.queue }:show(nil)
    end)
    if not ok then
        logger.warn("Picayomi DownloadSelect: 打开已下载页失败: " .. tostring(err))
        require("ui.common.loading_task").showFailure(err)
    end
end

function DownloadSelect:show()
    UIManager:show(self.menu, "ui")
end

--- 返回键/关闭后只收尾一次 (Menu 返回键会先自己 close, 再调 close_callback)
function DownloadSelect:_menuClosed()
    if self._closed_once then return end
    self._closed_once = true
    self.menu = nil
    if self.on_back then self.on_back() end
end

function DownloadSelect:goBack()
    local menu = self.menu
    if menu then
        self.menu = nil
        UIManager:close(menu, "ui")
    end
    self:_menuClosed()
end

function DownloadSelect:onClose()
    self:goBack()
    return true
end

return DownloadSelect
