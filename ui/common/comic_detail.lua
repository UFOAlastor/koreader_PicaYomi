-- ui/common/comic_detail.lua
-- 统一漫画详情页：封面、元信息、章节列表和阅读入口

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui.common.action_style").Button
local ButtonDialog = require("ui.common.action_style").ButtonDialog
local ActionStyle = require("ui.common.action_style")
local ConfirmBox = require("ui.common.action_style").ConfirmBox
local Device = require("device")
local Theme = require("ui.common.theme")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui.common.action_style").InputDialog
local InputContainer = require("ui/widget/container/inputcontainer")
local ListView = require("ui/widget/listview")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LoadingTask = require("ui.common.loading_task")
local logger = require("util.logger")
local PageJump = require("ui.common.page_jump")
local Size = require("ui/size")
local SwipeRules = require("ui.common.swipe_rules")
local TapGuard = require("ui.common.tap_guard")
local CenterContainer = require("ui/widget/container/centercontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local ComicStats = require("ui.common.comic_stats")
local CommentList = require("ui.common.comment_list")
local OfflineLibrary = require("util.offline_library")
local ViewMode = require("ui.common.view_mode")
local VisualComicList = require("ui.common.visual_comic_list")
local CoverPlaceholder = require("ui.common.cover_placeholder")
local _ = require("gettext")
local T = require("ffi/util").template

local Screen = Device.screen
local Input = Device.input

-- 详情页行高。详情页是按"等高行"分屏的 (ListView 要求 item_height 一致, 见 :301
-- 的 per_screen 与 test/functional_tap_geometry.lua 的"所有行等高"断言), 所以这是
-- **一个**常量, 不是每行各算各的。
--
-- 取值依据: 行内文字只有**一行** (标题与提示已合并, 例如章节行的「第1话 · 13 页」),
-- 所以行高只需容得下 字体行高 + 上下内边距。旧值 scaleBySize(84) 是为"标题 + 提示
-- 两行"留的, 单行之后每行有一半以上是空白 (用户报的就是这个)。
-- 下限提醒: TextBoxWidget 在 height < 字体行高时会**静默抬高 height** (见
-- ui/common/theme.lua), 于是内容溢出行框、绘制区/落位基准/命中区三者错位 ——
-- FixedBox 正是为这条而立, 但行高本身也不能低于字体行高。
local ROW_H = Screen:scaleBySize(48)

--- 固定尺寸盒子: 见 ui/common/fixed_box.lua 的注释 (绘制区/落位基准/命中区三者一致)
local FixedBox = require("ui.common.fixed_box")

local CoverCache = require("util.cover_cache")
local SourceRegistry = require("source.registry")
local ComicModel = require("model.comic")
local JN = require("util.json_null")
local WidgetSweep = require("util.widget_sweep")

local function join(values, sep)
    local out = {}
    if type(values) == "table" then
        for _idx, value in ipairs(values) do
            if value and value ~= "" then table.insert(out, tostring(value)) end
        end
    elseif values and values ~= "" then
        table.insert(out, tostring(values))
    end
    return table.concat(out, sep or " · ")
end

--- 这段文案是不是列表项里的"作品属性", 而不是分类
--
-- 源 C 列表页的 info_col 长这样: "25張圖片，創建於2026-10-17"。老版本的解析
-- 把它整段塞进了 categories, 于是详情页的「分类」一行显示的就是这句话。
-- 列表项现在不这么干了 (source/htcomic/api.lua), 但**历史记录 / 本地收藏里存着
-- 旧值**, 打开时还会原样带进来 —— 所以展示层也要能认出来, 把它挪到简介的 meta 行。
local function looksLikeListMeta(text)
    if type(text) ~= "string" or text == "" then return false end
    if text:find("張圖片", 1, true) or text:find("张图片", 1, true) then return true end
    if text:find("創建於", 1, true) or text:find("创建于", 1, true) then return true end
    return false
end

local function normalizeComic(comic)
    comic = comic or {}
    local processed = ComicModel:processComicData(comic)
    for k, v in pairs(comic) do
        if processed[k] == nil or processed[k] == "" then
            processed[k] = v
        end
    end
    -- **空串要归一成 nil**: 有些源的列表项把 author 给成 "" (源 C 就是这样),
    -- 而 "" 在 Lua 里是真值 —— 表头会显示成"作者："后面一片空白, 连"未知作者"
    -- 的兜底都走不到。留 nil 让展示层决定兜底文案。
    processed.author_text = JN.str(processed.author_text) or JN.str(processed.author)
    if processed.author_text == "" then processed.author_text = nil end
    processed.categories_text = JN.str(processed.categories_text)
        or join(processed.categories, " / ")
    if processed.categories_text == "" then processed.categories_text = nil end

    -- 旧数据里的"假分类" (见 looksLikeListMeta): 从分类里摘掉, 内容挪到 meta 行,
    -- 分类留空 -> 详情接口会把它补成真正的分类。
    if looksLikeListMeta(processed.categories_text) then
        processed.meta_text = JN.str(processed.meta_text) or processed.categories_text
        processed.categories = nil
        processed.categories_text = nil
    end
    processed.meta_text = JN.str(processed.meta_text) or JN.str(comic.meta_text)
    if processed.meta_text == "" then processed.meta_text = nil end
    processed.tags_text = JN.str(processed.tags_text) or join(processed.tags, " / ")
    processed.description = JN.str(processed.description) or JN.str(comic.description) or ""
    processed.chineseTeam = JN.str(processed.chineseTeam) or JN.str(comic.chineseTeam) or ""
    processed.epsCount = JN.num(processed.epsCount, 0)
    processed.pagesCount = JN.num(processed.pagesCount, 0)
    processed.likesCount = JN.num(processed.likesCount, 0)
    processed.finished = JN.bool(processed.finished, JN.bool(comic.finished))
    processed.isFavourite = JN.bool(processed.isFavourite, JN.bool(comic.isFavourite))

    -- 时间戳按日期展示 (部分源直接给 epoch 秒)
    local ut = processed.update_time
    if type(ut) == "number" then
        processed.update_time = os.date("%Y-%m-%d", ut)
    elseif not JN.str(ut) then
        processed.update_time = nil
    end

    return processed
end

local DetailRow = InputContainer:extend{
    width = nil,
    height = nil,
    text = nil,
    callback = nil,
    enabled = true,
}

function DetailRow:init()
    self.width = self.width or Screen:getWidth()
    self.height = self.height or ROW_H
    local padding = Screen:scaleBySize(8)
    local text_w = self.width - padding * 2
    local text_h = self.height - padding * 2
    local clickable = self.enabled ~= false and self.callback ~= nil
    if self.action_button then
        self[1]=ActionStyle.row{width=self.width,height=self.height,text=self.text,
            enabled=clickable,align=self.action_align,expandable_text=self.expandable_text}
    else
    -- 样式只按可点击性区分, 不按行号交替; 多格动作与普通行共用同一套尺寸。
    -- 单行文本统一左对齐、垂直居中, 长标签省略, 不因换行改变视觉高度。
    self[1] = FrameContainer:new{
        padding = padding,
        margin = 0,
        bordersize = 0,
        background = clickable and Blitbuffer.COLOR_GRAY_E or Blitbuffer.COLOR_WHITE,
        width = self.width,
        height = self.height,
        FixedBox:new{
            width = text_w,
            height = text_h,
            LeftContainer:new{
                dimen = Geom:new{ x = 0, y = 0, w = text_w, h = text_h },
                TextWidget:new{
                    text = self.text or "",
                    face = Theme.face("row"),
                    bold = clickable or self.section_header,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                    max_width = text_w,
                    truncate_with_ellipsis = true,
                    picayomi_expandable_text = clickable and self.expandable_text,
                },
            },
        },
    }
    end
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }

    if clickable and Device:isTouchDevice() then
        self.ges_events.TapSelect = {
            GestureRange:new{
                ges = "tap",
                range = self.dimen,
            }
        }
    end
end

function DetailRow:onTapSelect()
    if self.enabled ~= false and self.callback then
        self.callback()
    end
    return true
end

local ComicDetail = InputContainer:extend{
    -- 标记为"插件顶层页面": 退出 Picayomi 时由 util/widget_sweep 统一清扫
    -- (见 widget_sweep 的注释)。标在类上, 所有实例都继承。
    is_picayomi_page = true,
    comic = nil,
    source = nil,
    source_id = nil,
    comic_model = ComicModel,
    reader = nil,
    fetch_chapters = nil,
    -- 若入口已有章节数据可直接传入, 详情页会跳过首次拉取
    episodes_data = nil,
    favorite_action = nil,
    extra_actions = nil,
    start_label = nil,
    on_back = nil,
    on_return_from_reader = nil,
    resume_episode_order = nil,
    navigation = nil,
    -- 离线模式 (从「已下载」进入): 不再向源要章节/评论/收藏状态, 也不下载封面。
    -- 只读清单里已完整下载的章节。
    offline = false,
    width = nil,
    height = nil,
}

function ComicDetail:isNovel()
    return self.source and self.source.content_type=="novel" or self.comic and self.comic.content_type=="novel"
end

function ComicDetail:init()
    self.width = self.width or Screen:getWidth()
    self.height = self.height or Screen:getHeight()
    -- 全屏控件: 告诉 UIManager:_repaint 不必再绘制下层控件
    self.covers_fullscreen = true
    self.source = self.source or SourceRegistry:getCurrent()
    if self.source and self.source.init and not self.source._http_client then
        self.source:init()
    end
    self.source_id = self.source_id or (self.source and self.source.identifier) or "unknown"
    self.auto_continue = self.navigation and (self.navigation.continue_reading == true or self.navigation.open_reading == true)
    self._quick_entry=self.auto_continue==true
    self.covers_fullscreen=not self._quick_entry
    self.offline = self.offline or (self.source and self.source._offline) or false
    self.comic = normalizeComic(self.comic or {})
    if self:isNovel() then self.comic.content_type="novel" end
    -- 本地收藏 (未登录兜底): 状态在本地就有, 先填上 —— 否则按钮会先显示"收藏",
    -- 再等 syncFromSource 去问源 (未登录问源只会拿到 401)
    self:seedLocalFavoriteState()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    -- 滑动: 左滑 = 下一屏 (章节列表), 右滑 = 上一屏; 已在第一屏时右滑 = 返回。
    -- 规则与漫画列表页完全一致 (见 ui/common/visual_comic_list.lua 的 onSwipe) ——
    -- 详情页**也是分屏的** (章节列表), 所以不能简单地"右滑即返回", 否则退不回上一屏。
    if Device:isTouchDevice() then
        self.ges_events.Swipe = {
            GestureRange:new{
                ges = "swipe",
                range = self.dimen,
            },
        }
    end
    -- 慢速边缘拖动也算返回 (swipe 超过 900ms 就变成 pan, 见 SwipeRules.isBackPan)
    SwipeRules.installSlowDragBack(self, function() return self:goBack() end)
    -- 章节数据可能在构造时就由调用方给了 (历史页 / 渲染测试):
    -- 必须**先排序再构建**, 否则首屏会按源的原始(可能是倒序)顺序显示
    if not self.episodes_data and not self.offline and self.source and self.source.peekChapters
            and require("ui.common.source_access").check(self.source,nil,true) then
        local data,fresh=self.source:peekChapters(self.comic._id)
        self.episodes_data=data
        self._chapters_stale=data and not fresh
    end
    if self.episodes_data then
        self:setEpisodesData(self.episodes_data)
    end
    -- 收藏按钮文案按当前状态定 (入口可能写死, 这里统一按状态覆盖)
    self:syncFavoriteLabel()
    self:buildContent()

    if Input and Input.group then
        self.key_events = {
            Close = { { "Back" } },
            PageForward = { { Input.group.PgFwd } },
            PageBackward = { { Input.group.PgBack } },
        }
    end

    -- 兜底消费 tap: 页脚按钮之间/四周、行与行之间都有内边距, 这些点若没人消费,
    -- 事件会继续往下层窗口传 (见 tap_guard 的注释), 可能触发与本页无关的动作。
    TapGuard.install(self, self.dimen)

    -- 点封面放大: TapGuard 装的是一条"吃掉落空 tap"的兜底处理器, 这里在它
    -- **前面**先判封面区域 —— 命中就放大, 没命中就原样交回兜底。
    -- (落在按钮/章节行上的 tap 会先被子控件消费, 根本到不了这里。)
    local consume_tap = self.onTapConsume
    self.onTapConsume = function(_self, arg, ges)
        if self:showTitle(ges) then return true end
        if self:showCoverZoom(ges) then return true end
        if self:showDescription(ges) then return true end
        if consume_tap then return consume_tap(_self, arg, ges) end
        return true
    end

    UIManager:nextTick(function()
        if self._closed or self.opening_reader then return end
        -- 这是 init 排下的**延迟任务**: KOReader 的任务队列不兜异常, 抛出来就一路
        -- 冒到 reader.lua, 整个进程退出 —— 用户只是"点进了一部漫画"。
        -- 三件事互相独立, 各自兜底: 取封面失败不该让章节不加载, 取详情补充信息
        -- (syncFromSource 里是对源接口的裸调用) 失败也不该影响前两件。
        local function guarded(label, fn)
            local ok, err = pcall(fn)
            if not ok then
                self:revealQuickEntry()
                logger.warn("Picayomi ComicDetail: 首拍任务 " .. label .. " 失败: " .. tostring(err))
            end
        end
        guarded("continueReading", function() self:tryAutoContinue() end)
        if self.opening_reader then return end
        guarded("loadCover", function() self:loadCover() end)
        -- 入口已提供章节数据 (如历史页 / 渲染测试) 时不再重复拉取
        if not self:isNovel() and (not self.episodes_data or self._chapters_stale) and not self.offline then
            guarded("loadChapters", function() self:loadChapters(1) end)
        end
        if not self.offline then
            guarded("syncFromSource", function() self:loadDetails() end)
        end
    end)
end

function ComicDetail:loadMissingNovelChapters()
    if self:isNovel() and not self.offline and not self._closed and not self.opening_reader
        and (not self.episodes_data or self._chapters_stale) then self:loadChapters(1) end
end

function ComicDetail:loadDetails()
    if self._loading_detail or self._closed or self.opening_reader or self.offline then return end
    if not self.source or type(self.source.getComicDetail)~="function" then
        self:loadMissingNovelChapters();return
    end
    local need_fav,need_info=self:detailNeeds()
    if not need_fav and not need_info and not self._detail_error then
        self:loadMissingNovelChapters();return
    end
    self._loading_detail=true
    local hint=require("ui.common.loading_progress"):new{title=self:isNovel() and _("加载小说详情") or _("加载漫画详情"),
        progress={message=_("正在获取作品信息…（最多等待 60 秒）")}}
    UIManager:show(hint,"ui");UIManager:forceRePaint()
    local function reset() self._loading_detail=false end
    self._detail_task=LoadingTask.background(hint,function()
        local ok,err=self:syncFromSource()
        reset();LoadingTask.close(hint)
        if self._closed or self.opening_reader then return end
        local prior_error=self._detail_error
        self._detail_error=ok==false and err or nil
        if self._detail_error or prior_error then self:refresh() end
        self:tryAutoContinue()
        if ok==false then LoadingTask.showFailure(err) end
        self:loadMissingNovelChapters()
    end,{
        delay=.05,timeout=60,
        is_cancelled=function()return self._closed or self.opening_reader end,
        on_cancel=function()reset();self.auto_continue=nil;self:revealQuickEntry()end,
        on_error=function(err)
            reset();self._detail_error=err
            self:revealQuickEntry()
            if not self._closed then self:refresh();LoadingTask.showFailure(err);self:loadMissingNovelChapters() end
        end,
    })
end

-- 列表快捷入口先保留真实详情页作为返回目标, 只消费一次续读意图。
function ComicDetail:revealQuickEntry()
    if not self._quick_entry then return end
    self._quick_entry=nil;self.covers_fullscreen=true
    if not self._closed then UIManager:setDirty(self,"ui")end
end

-- Both comic and novel quick entries defer metadata. Restore it only after
-- the reader has gone, and discard the scheduled work if the detail closes.
function ComicDetail:loadDetailsAfterReading()
    if self._closed or self.offline or self._return_detail_timer then return end
    self._return_detail_timer=function()
        self._return_detail_timer=nil
        if self._closed or self.opening_reader or require('apps/reader/readerui').instance
            or not require('util.widget_sweep').isInStack(self) then return end
        self:loadDetails()
    end
    UIManager:scheduleIn(.05,self._return_detail_timer)
end

function ComicDetail:paintTo(bb,x,y)
    if self._quick_entry then return end
    return InputContainer.paintTo(self,bb,x,y)
end

function ComicDetail:handleEvent(event)
    if self._quick_entry and event.handler=="onGesture" then return true end
    return InputContainer.handleEvent(self,event)
end

function ComicDetail:tryAutoContinue()
    if not self.auto_continue then return end
    local stack = UIManager._window_stack or {}
    if self._closed or self.opening_reader or not stack[#stack] or stack[#stack].widget ~= self then return end
    if self.navigation and self.navigation.source_id ~= self.source_id then self.auto_continue=nil;self:revealQuickEntry();return end
    local ok, history = pcall(self.comic_model.getHistoryItem, self.comic_model, self.comic._id, self.source_id)
    local order = ok and history and (history.episode or history.last_page)
    if not self.episodes_data and self:isNovel()and order~=nil and self.source.restoreNovelResume then
        local episode=self.source:restoreNovelResume(self.comic._id,history.novel_resume,order)
        if not episode then
            local entry=require("util.offline_library").entry(self.source_id,self.comic._id)
            local target=entry and entry.targets and entry.targets[tostring(order)]
            local record=target and self.source:makeNovelResume(self.comic._id,target)
            episode=record and self.source:restoreNovelResume(self.comic._id,record,order)
        end
        if episode then
            self.auto_continue=nil;self._resume_direct=true
            self:openReader(episode,{from_beginning=false})
            return
        end
    end
    if not self.episodes_data then return end
    self.auto_continue=nil
    if ok and order==nil and self.navigation.open_reading then
        self:startReadingFromBeginning()
        return
    end
    for _, episode in ipairs(self.episodes_data.episodes or {}) do
        if order ~= nil and tostring(episode.order) == tostring(order) then
            self.resume_episode_order = order
            self:startReading()
            return
        end
    end
    self:revealQuickEntry()
    UIManager:show(InfoMessage:new{
        text = _("上次阅读的章节暂不可用，请在详情页选择章节。"), timeout = 3,
    }, "ui")
end

--- 兜底消费 tap (见 init 里的说明)
function ComicDetail:onTapConsume()
    return true
end

--- 点封面 -> 放大显示 (悬浮在本页之上, **不是**新页面)
--
-- 真机反馈: 封面只有 96x136, 想看清封面 / 确认是不是这一本时没有放大入口。
-- 交互按用户要求: 点封面放大, **屏幕任意位置再点一次退出**。
--
-- 为什么用一层全屏控件而不是 ReaderUI 之类的"新页面": 用户明确要"悬浮在详情页上",
-- 而且新页面会进窗口栈 —— 返回时多一层、还要处理"返回的是谁"。
-- 这层只做两件事: 黑底 + 等比放大的图; 点哪都关。
--
-- @param ges 触发 tap 的事件 (带 .pos), 用来判断有没有点在封面上
-- @return true 表示这次 tap 已被本方法处理
function ComicDetail:showCoverZoom(ges)
    local cover = self.cover_widget
    local pos = ges and ges.pos
    if not (cover and cover.dimen and pos) then return false end
    if not cover.dimen:contains(pos) then return false end
    local path = self.cover_path
    if not path then return false end

    -- 已经开着: 这一下就是"退出" (避免叠第二层)
    if self.cover_zoom then
        self:closeCoverZoom()
        return true
    end

    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local margin = Screen:scaleBySize(6)
    local max_w = sw - margin * 2
    local max_h = sh - margin * 2

    local overlay = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh },
        -- 下层 (详情页) 不必再画; 也保证整屏都是黑的
        covers_fullscreen = true,
        modal = true,
        -- 退出 Picayomi 时由 util/widget_sweep 一并扫掉
        is_picayomi_page = true,
    }
    overlay.ges_events = {
        TapClose = {
            GestureRange:new{
                ges = "tap",
                range = overlay.dimen,
            },
        },
    }
    overlay.onTapClose = function()
        self:closeCoverZoom()
        return true
    end
    overlay[1] = FrameContainer:new{
        width = sw,
        height = sh,
        dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh },
        margin = 0,
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_BLACK,
        CenterContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh },
            ImageWidget:new{
                file = path,
                width = max_w,
                height = max_h,
                -- 0 = 等比缩放到刚好放进 width/height (不拉伸)
                scale_factor = 0,
            },
        },
    }

    self.cover_zoom = overlay
    UIManager:show(overlay, "ui")
    return true
end

--- 关掉封面放大层 (幂等)
function ComicDetail:closeCoverZoom()
    local overlay = self.cover_zoom
    if not overlay then return end
    self.cover_zoom = nil
    pcall(function() UIManager:close(overlay, "ui") end)
end

--- 点标题查看全文; TextViewer 自带长按拖选复制。
function ComicDetail:showTitle(ges)
    local widget = self.title_widget
    if not widget or not widget.dimen or not ges or not ges.pos then return false end
    if not widget.dimen:contains(ges.pos) then return false end
    local title = self.comic and self.comic.title
    if not title or title == "" then return false end
    if self.title_viewer then return true end

    local TextViewer = require("ui/widget/textviewer")
    local viewer
    viewer = TextViewer:new{
        title = self:isNovel() and _("小说标题") or _("漫画标题"),
        text = title,
        show_menu = false,
        buttons_table = { {
            {
                text = _("复制完整标题"),
                enabled = Device:hasClipboard(),
                callback = function()
                    Device.input.setClipboardText(title)
                    UIManager:show(InfoMessage:new{ text = _("已复制标题"), timeout = 1 }, "ui")
                end,
            },
            { text = _("关闭"), callback = function() viewer:onClose() end },
        } },
        close_callback = function()
            if self.title_viewer == viewer then self.title_viewer = nil end
        end,
    }
    self.title_viewer = viewer
    UIManager:show(viewer, "ui")
    return true
end

function ComicDetail:closeTitleViewer()
    local viewer = self.title_viewer
    if not viewer then return end
    self.title_viewer = nil
    pcall(function() UIManager:close(viewer, "ui") end)
end

--- 点简介区 -> 弹全文 (可滚动)
--
-- 简介区只有两行, 长简介会被省略号截断; 站点上的简介动辄几百字, 没有出口的话
-- 用户永远看不到全文。
function ComicDetail:descriptionText()
    local comic = self.comic or {}
    local description = comic.description or ""
    if description == _("暂无简介") then description = "" end
    local meta = comic.meta_text
    if meta and meta ~= "" then
        description = description ~= "" and (description .. "\n" .. meta) or meta
    end
    return description
end

function ComicDetail:showDescription(ges)
    local widget = self.description_widget
    if not widget or not widget.dimen or not ges or not ges.pos then return false end
    if not widget.dimen:contains(ges.pos) then return false end
    local text = self:descriptionText()
    if text == "" then return false end
    self:openDescriptionViewer(text)
    return true
end

function ComicDetail:openDescriptionViewer(text)
    if self.description_viewer then return end
    local TextViewer = require("ui/widget/textviewer")
    local viewer
    viewer = TextViewer:new{
        title = self.comic and self.comic.title or _("简介"),
        text = text,
        -- 用户用弹窗自己的关闭按钮/手势退出时, 也要允许再次打开。
        close_callback = function()
            if self.description_viewer == viewer then
                self.description_viewer = nil
            end
        end,
    }
    self.description_viewer = viewer
    UIManager:show(viewer, "ui")
end

--- 关掉简介全文层 (幂等; 详情页收起时一并收掉, 免得留在屏幕上)
function ComicDetail:closeDescriptionViewer()
    local viewer = self.description_viewer
    if not viewer then return end
    self.description_viewer = nil
    pcall(function() UIManager:close(viewer, "ui") end)
end

function ComicDetail:coverWidget()
    local cover_w = Screen:scaleBySize(96)
    local cover_h = Screen:scaleBySize(136)
    local path = self.comic and self.comic._id and CoverCache.find(self.source_id, self.comic._id)
    if path then
        local widget = ImageWidget:new{
            file = path,
            width = cover_w,
            height = cover_h,
            scale_factor = nil,
            alpha = true,
            file_do_cache = false,
        }
        -- 记下"当前这一屏的封面控件与图片路径": 点封面放大要用
        -- (封面控件每次重建都换新实例, 所以每次都覆盖)
        self.cover_widget = widget
        self.cover_path = path
        return widget
    end
    -- 没有图 (占位/加载中): 不记, 点它也不该放大
    self.cover_widget = nil
    self.cover_path = nil
    return CoverPlaceholder:new{
        width = cover_w,
        height = cover_h,
        title = self.comic.title,
        background = Blitbuffer.COLOR_GRAY_E,
        text = self.comic.thumb and self.comic.thumb ~= "" and _("加载中") or _("无封面"),
    }
end

--- 简介区固定显示两行 (用户要求), 点一下看全文
-- 表头高度 = 封面高 + 上下内边距 + 简介两行 + 与封面的间距
local HEADER_PADDING = 10
local DESC_LINES = 2
local DESC_LINE_H = 24

--- 构建整页内容
-- @param keep_screen 可选: 重建后停在第几屏 (缺省 1)。页脚/详情刷新时用 ——
--        否则每次刷新都会把章节列表跳回第一屏。
function ComicDetail:buildContent(keep_screen)
    local header_h = Screen:scaleBySize(
        136 + HEADER_PADDING * 2 + DESC_LINE_H * DESC_LINES + 6)
    self.page_text = TextWidget:new{
        text = "",
        face = Theme.face("info"),
    }

    -- 先把行内容算成"数据"(spec), 控件等用到时按屏现建现用。
    -- 不能把控件一次性交给 ListView 让它翻页 —— 见 renderWindow 的注释。
    self.row_specs = self:buildRowSpecs()

    -- FrameContainer:getSize() 忽略 self.height, 故列表高度必须按
    -- header/footer 的真实尺寸计算, 否则页脚会被挤出屏幕。
    local header = self:createHeader(header_h)
    local footer = self:createFooter()
    self.page_status = FrameContainer:new{
        padding=0, margin=0, bordersize=0, width=self.width, self.page_text,
    }
    local list_h = self.height - header:getSize().h - footer:getSize().h - self.page_status:getSize().h
    if list_h < ROW_H then list_h = ROW_H end

    -- 屏游标由我们自己掌控 (与 ListView 内部算法保持一致)
    self.per_screen = math.max(1, math.floor(list_h / ROW_H))
    local total_screens = math.max(1, math.ceil(#(self.row_specs or {}) / self.per_screen))
    local want = tonumber(keep_screen) or 1
    self.screen_index = math.max(1, math.min(want, total_screens))
    self:buildWindow()

    self.list_view = ListView:new{
        padding = 0,
        items = self.rows,
        width = self.width,
        height = list_h,
        item_height = ROW_H,
        page_update_cb = function()
            self:updatePageText()
        end,
    }
    -- **必须关掉内层 ListView 自己的 swipe 处理** —— 与漫画列表页同一个坑:
    -- ListView 是 InputContainer, 自己注册了 ges_events.Swipe, 而事件是**先派发给
    -- 子控件**的, 于是本控件的 onSwipe 永远不触发; 它自己又只拿到一屏 (buildWindow),
    -- pages 恒为 1, nextPage() 什么都不做 —— 用户看到的就是"滑动没反应"。
    --
    -- 两处都要关: ges_events 关掉"原始手势被它自己的 onGesture 吃掉"; onSwipe 关掉
    -- "本控件合成的 Swipe 命名事件又被它先收到"。置 nil 没用 (会回退到类方法)。
    if Device:isTouchDevice() then
        self.list_view.ges_events = {}
        self.list_view.onSwipe = function() return nil end
    end

    self[1] = FrameContainer:new{
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        width = self.width,
        height = self.height,
        VerticalGroup:new{
            align = "left",
            header,
            self.list_view,
            self.page_status,
            footer,
        },
    }
end

--- 当前屏能放几行
function ComicDetail:perScreen()
    return self.per_screen or (self.list_view and self.list_view.items_per_page) or 1
end

--- 全部行一共多少屏
function ComicDetail:loadedScreens()
    local total = #(self.row_specs or {})
    if total <= 0 then return 1 end
    return math.ceil(total / self:perScreen())
end

--- 按屏构建行控件 (只建当前屏需要的这几行)
function ComicDetail:buildWindow()
    local per = self:perScreen()
    local start_i = (self.screen_index - 1) * per + 1
    self.rows = {}
    local total = #(self.row_specs or {})
    for i = start_i, math.min(start_i + per - 1, total) do
        local spec = self.row_specs[i]
        local cells = spec.cells
        if not cells and spec.pair then cells = { spec.left, spec.right } end
        if cells then
            -- 未指定宽度的格子共享剩余空间, 逐格分摊整数余数。
            -- 全行恰好填满, 任意等分格之间最多相差一个像素。
            local n = #cells
            local group = HorizontalGroup:new{}
            local x = 0
            for ci, cell in ipairs(cells) do
                local w = (ci == n) and (self.width - x) or cell.width or math.floor((self.width - x) / (n - ci + 1))
                table.insert(group, DetailRow:new{
                    width = w,
                    height = spec.height or ROW_H,
                    text = cell.text,
                    callback = cell.callback,
                    enabled = cell.enabled ~= false,
                    action_button = cell.action_button,
                    action_align = cell.action_align,
                    section_header = cell.section_header,
                })
                x = x + w
            end
            -- ListView 用 item_height 排; 这里补一个 height 让"检查行高"的断言
            -- 和普通行保持同一种读法 (HorizontalGroup 自己没有 height 字段)。
            group.height = spec.height or ROW_H
            table.insert(self.rows, group)
        else
            table.insert(self.rows, DetailRow:new{
                width = self.width,
                height = spec.height or ROW_H,
                text = spec.text,
                callback = spec.callback,
                action_button = spec.action_button,
                action_align = spec.action_align,
                expandable_text = spec.expandable_text,
            })
        end
    end
    return self.rows
end

--- 把当前屏交给 ListView 并重绘
--
-- 关键: 每次只把**当前屏**的控件交给 ListView, 换屏时重建。
-- 不能一次性交全部行让 ListView 自己翻页 —— ListView:_populateItems 是:
--     self.main_content:clear()          -- 会 free() 掉正在显示的这批控件
--     再把 self.items 里对应的那批实例原样插回去
-- 于是"往回翻"时插回来的是**之前已经被 free 过**的控件, 文字再也画不出来:
-- 实测上屏一次后整块列表变成空白, 而且从此永久空白。
function ComicDetail:renderWindow()
    local lv = self.list_view
    if not lv then return end
    self:buildWindow()
    lv.items = self.rows
    lv.show_page = 1
    lv:_populateItems()
    self:updatePageText()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    -- 留痕: 翻屏类问题一旦复现, 从日志就能看出是"游标动了但没重建"还是"重建了但内容空"
    if logger.enabled then logger.dbg(string.format(
        "Picayomi Detail: 渲染第 %d/%d 屏, 本次构建 %d 行 (共 %d 项)",
        self.screen_index or 1, self:loadedScreens(), #(self.rows or {}),
        #(self.row_specs or {}))) end
end

--- 跳到指定屏 (1-based, 会做范围钳制)
function ComicDetail:goToScreen(n)
    local total = self:loadedScreens()
    n = tonumber(n) or 1
    if n < 1 then n = 1 end
    if n > total then n = total end
    if n == (self.screen_index or 1) then return true end
    self.screen_index = n
    self:renderWindow()
    return true
end

function ComicDetail:updatePageText()
    if not self.page_text then return end
    if self.jump_button then self.jump_button:enableDisable(self:loadedScreens()>1) end
    self.page_text:setText(T(_("第 %1/%2 页"),
        self.screen_index or 1, self:loadedScreens()))
end

function ComicDetail:createHeader(height)
    local padding = Screen:scaleBySize(HEADER_PADDING)
    local gap = Screen:scaleBySize(12)
    local cover_w = Screen:scaleBySize(96)
    local cover_h = Screen:scaleBySize(136)
    -- 表头内容可用宽度: 要把表头**自己的 padding 与边框**都扣掉。
    --   FrameContainer:getSize() 会把 padding 和 bordersize 加在内容宽度之上
    --   (它忽略传入的 width), 所以内容只能占 self.width - padding*2 - bordersize*2。
    -- 两处用同一个预算: 之前"右侧文字"漏扣边框、"简介"漏扣边框, 表头实际宽出 4px,
    -- 右侧边框被挤出屏幕外 (真机 1236 宽时表头实测 1240 宽)。
    local border = Size.border.thin
    local inner_w = self.width - (padding + border) * 2
    local text_w = inner_w - cover_w - gap
    -- 统计行与列表卡片共用同一个函数 (话数 · 页数 · 完结/连载 · 喜欢 · 编号兜底),
    -- 否则同一部作品在列表里显示"5话"、点进去表头却显示"120P"。
    -- 详情页有独立的「更新时间：…」行, 表头统计行不要再写一遍
    local status_text = ComicStats.line(self.comic, { updated_shown = true })
    self.status_text = status_text   -- 供测试断言: 表头与列表卡片必须是同一行

    -- 简介区 = 简介正文 + (作品属性行)。
    --
    -- 页数/编号/创建时间/标签这类东西是"作品属性", 不是分类 (源 C 以前把它们
    -- 塞在分类行里)。放在简介**末尾**: 有正文时用户先看到正文, 想看细节点开全文;
    -- 没有正文时它就顶上来当简介。
    local description = self:descriptionText()
    if description == "" then
        description = _("暂无简介")
    end

    return FrameContainer:new{
        padding = padding,
        margin = 0,
        bordersize = Size.border.thin,
        background = Blitbuffer.COLOR_GRAY_E,
        width = self.width,
        height = height,
        VerticalGroup:new{
            align = "left",
            HorizontalGroup:new{
                self:coverWidget(),
                HorizontalSpan:new{ width = gap },
                VerticalGroup:new{
                    align = "left",
                    (function()
                        local widget = TextBoxWidget:new{
                            bgcolor = Blitbuffer.COLOR_GRAY_E,
                            text = self.comic.title or _("未知标题"),
                            face = Theme.face("detail_title"),
                            bold = true,
                            width = text_w,
                            height = Screen:scaleBySize(54),
                            height_overflow_show_ellipsis = true,
                        }
                        self.title_widget = widget
                        return widget
                    end)(),
                    TextBoxWidget:new{
                            bgcolor = Blitbuffer.COLOR_GRAY_E,
                        text = T(_("作者：%1"), self.comic.author_text or _("未知作者")),
                        face = Theme.face("info"),
                        width = text_w,
                        height = Screen:scaleBySize(24),
                        height_overflow_show_ellipsis = true,
                    },
                    TextBoxWidget:new{
                            bgcolor = Blitbuffer.COLOR_GRAY_E,
                        text = T(_("分类：%1"), self.comic.categories_text or _("未分类")),
                        face = Theme.face("info"),
                        width = text_w,
                        height = Screen:scaleBySize(24),
                        height_overflow_show_ellipsis = true,
                    },
                    TextBoxWidget:new{
                            bgcolor = Blitbuffer.COLOR_GRAY_E,
                        text = status_text,
                        face = Theme.face("info"),
                        width = text_w,
                        height = Screen:scaleBySize(24),
                        height_overflow_show_ellipsis = true,
                    },
                },
            },
            (function()
                -- 两行 + 省略号; 点一下弹全文 (TextViewer)。
                -- 记下实例: tap 走本页的兜底消费者 (onTapConsume), 按绘制区命中,
                -- 与封面放大同一套做法 (子控件先收到事件, 这里只处理落空的 tap)。
                local widget = TextBoxWidget:new{
                    bgcolor = Blitbuffer.COLOR_GRAY_E,
                    text = description,
                    face = Theme.face("info"),
                    width = inner_w,
                    height = Screen:scaleBySize(DESC_LINE_H * DESC_LINES),
                    height_overflow_show_ellipsis = true,
                }
                self.description_widget = widget
                return widget
            end)(),
        },
    }
end

function ComicDetail:createFooter()
    local favorite_label = self.favorite_action and self.favorite_action.label or _("收藏")

    -- 读过 (有阅读历史) 时给两个入口: 「继续」接着看、「开始」从第一章第一页重看。
    -- 只给一个按钮会让"想从头看"和"接着看"混在一起 —— 用户要的正是这个区分。
    local resume_order = self:getResumeOrder()
    local resumable = resume_order ~= nil
    if logger.enabled then logger.info("Picayomi Detail: 阅读入口 resumable=" .. tostring(resumable)
        .. " resume_order=" .. tostring(resume_order)
        .. " episodes=" .. tostring(self:hasEpisodes())) end
    local leading={}
    if resumable then leading[#leading+1]={text=_("继续"),enabled=self:hasEpisodes(),callback=function()self:startReading()end}end
    leading[#leading+1]={text=_("开始"),enabled=self:hasEpisodes(),callback=function()self:startReadingFromBeginning()end}
    local footer,buttons,nav=ActionStyle.navigationFooter(self.width,{
        leading=leading,
        prev={callback=function()self:prevScreen()end},
        next={callback=function()self:nextScreen()end},
        jump={enabled=false,callback=function()self:showJumpDialog()end},
        extra={{text=favorite_label,enabled=self.favorite_action~=nil,callback=function()self:runFavoriteAction()end}},
        back=function()self:goBack()end,
    })
    self.footer_widget,self.footer_buttons=footer,buttons
    self.jump_button=nav.jump
    return footer
end

--- 弹出输入框让用户填写要跳转的屏号
-- 章节行全部在内存里 (row_specs), 所以总屏数是准确值, 起止点确定。
-- 弹窗本体在 ui/common/page_jump.lua (与列表页共用)。
function ComicDetail:showJumpDialog()
    local total = self:loadedScreens()
    return PageJump.show{
        description = T(_("共 %1 页，请输入要跳转的页码"), total),
        current = self.screen_index or 1,
        on_jump = function(n)
            -- goToScreen 是**夹取**语义 (越界就贴到边界), 所以这里必须自己先拦,
            -- 否则用户输 999 会被静默带到最后一页 —— 看起来像跳成功了。
            if n > total then
                return false, T(_("请输入 1 ~ %1 之间的页码"), total)
            end
            self:goToScreen(n)
            return true
        end,
    }
end

--- 全部行的内容 (纯数据: 文案/回调/行高)
-- 由 buildWindow 按屏实例化成 DetailRow 控件。
--
-- 每行只有**一行文字** —— 原来"标题 + 副文案"两行在 ROW_H 上会留一半空白
-- (用户报的就是这个)。所以副文案一律并进主文案: 用「标签：xxx」「第1话 · 13 页」
-- 这种形式。信息不丢, 只是不再各占一行。

--- 「版式：竖屏 / 条漫 / 横屏」这一格 (nil = 没有漫画 id, 不显示)
-- 显示的是**当前生效**的版式: 单本设置 > 全局策略; 两者都没有时显示「自动」
-- (真正打开时按第 1 页的像素长宽比判, 见 ui/common/view_mode.lua)。
function ComicDetail:viewModeCell()
    if self.source and self.source.content_type=="novel" then return nil end
    local id = self.comic and self.comic._id
    if not id then return nil end
    local model = self.comic_model or ComicModel
    local saved
    if type(model.getViewMode) == "function" then
        saved = model:getViewMode(id, self.source_id)
    end
    return {
        text = T(_("版式：%1"), ViewMode.label(ViewMode.current(saved))),
        callback = function() self:cycleViewMode() end,
    }
end

--- 点一下换一种版式: 竖屏 -> 条漫 -> 横屏 -> 竖屏
--
-- 不弹提示框 (用户要求): 按钮文案本身就是反馈, 点完原地变成新值。
-- 写的是**这一本**的设置, 与全局策略无关; 打开阅读器时优先用它。
function ComicDetail:cycleViewMode()
    local id = self.comic and self.comic._id
    if not id then return false end
    local model = self.comic_model or ComicModel
    if type(model.setViewMode) ~= "function" then return false end
    local before = ViewMode.current(model:getViewMode(id, self.source_id))
    local after = ViewMode.next(before)
    if not model:setViewMode(id, self.source_id, after) then return false end
    if logger.enabled then logger.info(string.format("Picayomi Detail: 版式 %s -> %s (%s:%s)",
        ViewMode.label(before), ViewMode.label(after),
        tostring(self.source_id), tostring(id))) end
    -- 原地重建: 只有这一格的文案变了, 屏游标保持不变
    self:refresh()
    return true
end

function ComicDetail:buildRowSpecs()
    local specs = {}
    local action_rows = true
    local function add(text, callback, height)
        table.insert(specs, {
            text = text,
            callback = callback,
            height = height or ROW_H,
            action_button = callback~=nil and action_rows,
            action_align = "left",
        })
    end
    --- 一行多个动作 (等分宽度). 每一格都是独立可点区, 不是"整行一个回调".
    -- 两格时同时填 pair/left/right: 渲染测试与老用例按这三个字段读这一行。
    local function add_cells(cells, height)
        for _,cell in ipairs(cells) do
            if cell.action_button==nil and cell.callback then cell.action_button=true end
        end
        local spec = { cells = cells, height = height or ROW_H }
        if #cells == 2 then
            spec.pair, spec.left, spec.right = true, cells[1], cells[2]
        end
        table.insert(specs, spec)
    end

    if self._detail_error then add(_("详情加载失败，点此重试"),function()self:loadDetails()end) end
    -- 标签: 点击弹出标签菜单, 选中即按该标签搜索
    -- (标签常有十几个且长短不一, 直接铺在页面上会挤成一团 / 放不下)
    if self.comic.tags_text and self.comic.tags_text ~= "" then
        add(T(_("标签：%1"), self.comic.tags_text), function() self:showTagMenu() end)
        specs[#specs].expandable_text = true
    end
    if type(self.comic.categories)=="table" and #self.comic.categories>0 then
        add(T(_("分类：%1"),self.comic.categories_text),function()self:showTagMenu(true)end)
        specs[#specs].expandable_text=true
    end
    -- 作者: 点击按作者名搜索 (头部那行只是展示, 这里是可点入口)
    local author = self.comic.author_text
    if author and author ~= "" and author ~= _("未知作者") then
        add(T(_("作者：%1"), author), function() self:searchByKeyword(author) end)
    end
    if self.comic.chineseTeam and self.comic.chineseTeam ~= "" then
        add(T(_("汉化组：%1"), self.comic.chineseTeam))
    end
    if self.comic.update_time and self.comic.update_time ~= "" then
        add(T(_("更新时间：%1"), self.comic.update_time))
    end

    -- 版式 / 下载 / 评论入口 (同一行, 等分):
    --   * 三个都是 4~5 字, 各占一整行太浪费纵向空间 —— 合成一行多格点击区;
    --   * 没有评论能力的源 (htcomic) 就是「版式」+「下载章节」两格;
    --   * 离线模式没有网络补章节/评论, 但版式仍然可设 —— 只显示「版式」一格。
    -- 放在元信息区而不是页脚: 页脚已经 7 个按钮挤一行, 再加只会更挤。
    local cells = {}
    local view_cell = self:viewModeCell()
    if view_cell then table.insert(cells, view_cell) end
    if not self.offline and self.source and self.comic._id then
        if require("source.capabilities").query(self.source, "download").supported then
            table.insert(cells, { text = _("下载章节"), callback = function() self:showDownloadSelect() end })
        end
        local can_comment = require("source.capabilities").query(self.source, "comments").supported
        if can_comment then
            table.insert(cells, { text = _("查看评论"),
                callback = function() self:showComments() end })
        end
    end
    if #cells == 1 then
        add(cells[1].text, cells[1].callback)
    elseif #cells >= 2 then
        add_cells(cells)
    end

    for _idx, action in ipairs(self.extra_actions or {}) do
        if action and action.text and action.callback then
            -- 入口可能自带副文案 (见 ui/history.lua): 并进同一行, 不另占一行
            local text = action.hint and action.hint ~= ""
                and T(_("%1 · %2"), action.text, action.hint) or action.text
            add(text, function() action.callback(self) end)
        end
    end

    local count=self.episodes_data and (self.episodes_data.total or #(self.episodes_data.episodes or {}))
    local chapter_label=self:isNovel() and _("章节列表 · 共 %1 章") or _("章节列表 · 共 %1 话")
    local summary=count and T(chapter_label,count) or (self._chapter_error and _("章节加载失败") or _("章节加载中…"))
    local progress=self:chapterProgressText()
    if progress then summary=summary.." · "..progress end
    if not self.offline then
        local refresh_width=ActionStyle.compactWidth(_("刷新章节"),ROW_H)
        add_cells({{text=summary,width=(self.width or Screen:getWidth())-refresh_width,section_header=true},
            {text=self._chapter_refresh_manual and _("刷新中…") or _("刷新章节"),
                action_button=true,enabled=not self._chapter_refresh_manual,
                callback=function() self:loadChapters(1,true) end}})
        specs[#specs].text=summary
    else
        add(summary)
    end

    if self._chapter_error then
        add(_("章节获取失败，点此重试"),function()self:loadChapters(1,true)end)
    end
    if not self.episodes_data then
        return specs
    end

    local episodes = self.episodes_data.episodes or {}
    if #episodes == 0 then
        add(self:isNovel() and _("该小说没有可阅读的章节") or _("该漫画没有可阅读的章节"))
        return specs
    end

    -- 这里**不显示**「第 N/M 页」: 那是章节接口的分页, 与页脚的「第 N/M 页」
    -- (屏幕分页) 是两个不同的东西, 并排出现时看起来就是"同一个页码两处不一致"。
    -- 页脚那个是准的, 这里只报章节总数。

    if (self.episodes_data.page or 1) > 1 then
        add(_("◀ 上一页章节"), function() self:loadChapters((self.episodes_data.page or 1) - 1) end)
    end
    if (self.episodes_data.page or 1) < (self.episodes_data.pages or 1) then
        add(_("下一页章节 ▶"), function() self:loadChapters((self.episodes_data.page or 1) + 1) end)
    end
    -- 章节数据本身分页时也给一个直接跳转: 总页数由服务端给出, 是准确值,
    -- 所以这里能明确起止点 (与上面的"上屏/下屏"是两回事, 别混)
    if (self.episodes_data.pages or 1) > 1 then
        add(T(_("跳转章节页…（共 %1 页章节）"), self.episodes_data.pages),
            function() self:showChapterJumpDialog() end)
    end

    action_rows=false
    for idx, episode in ipairs(episodes) do
        local current_episode = episode
        local title = current_episode.title or T(self:isNovel() and _("第%1章") or _("第%1话"), current_episode.order or idx)
        -- 页数并进标题 (原来是第二行, 现在单行显示): 信息不丢, 只是不再占一行
        if current_episode.pagesCount and current_episode.pagesCount > 0 then
            title = T(_("%1 · %2"), title, T(_("%1 页"), current_episode.pagesCount))
        end
        add(title, function()
            -- 点某一话 = 从**这一话的第 1 页**开始, 与「开始」同一套语义。
            -- 旧实现走的是「继续」那条路 (按 KOReader 记住的页码恢复): 用户点第 5 话
            -- 是想看第 5 话, 结果落在上次看到的那一页 —— 与「开始」按钮的行为不一致。
            self:openReader(current_episode, { from_beginning = true })
        end)
    end

    return specs
end

--- 重建整页 (数据变了: 章节/下载状态/收藏文案/详情补全/封面到货)
--
-- **默认保留屏游标**: 这些都是"同一页的数据变了", 用户并没有要换屏 ——
-- 以前每次都从 buildContent 的默认值 1 重来, 于是收藏/封面到货/读完返回
-- 都会把章节列表莫名跳回第一屏。
-- @param opts.reset_screen true = 显式回到第 1 屏 (换了一本漫画时用)
function ComicDetail:refresh(opts)
    -- 注意不能写成 "(opts and opts.reset_screen) and nil or self.screen_index":
    -- Lua 里 "true and nil or x" 恒等于 x (nil 被 or 吃掉), reset 永远不生效。
    local keep = self.screen_index
    if opts and opts.reset_screen then keep = nil end
    self:buildContent(keep)
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function ComicDetail:hasEpisodes()
    return self.episodes_data and self.episodes_data.episodes and #self.episodes_data.episodes > 0
end

--- 存入章节数据, 并统一按 order **升序**排列
--
-- 必须排序: 各源返回的章节顺序并不一致 —— 源 A 是**倒序**的 (首=最新章,
-- 末=第1章), 于是"第一项"其实是最后一章, 「开始」会从最后一章读起。
-- 排序后 episodes[1] 就是第 1 章, 列表也按 1→N 展示, 与预期一致。
-- (续读不受影响: 它是按 order 匹配的, 与排列顺序无关)
local function normalizeEpisodesData(data)
    -- Sorting a view must never alter a source response or another open view.
    if type(data)=="table" then data=require("source.contract").copy(data) end
    -- **边界归一**: 调用方可能直接把一个**裸的章节数组**递进来 (ui/reader.lua 的
    -- episodes_list 就是这个形状, main.lua 一度原样传给了 showComicDetail)。
    -- 不归一的话 `data.episodes` 是 nil → 详情页显示「该漫画没有可阅读的章节」,
    -- 且因为 episodes_data 非空而**不再去拉章节** —— 静默地变成"这本书没章节",
    -- 排查起来毫无线索 (用户看到的就是"刚读完返回, 却说没有章节")。
    -- 这里留一条 warn: 真出现时能直接在日志里看到是谁传错了。
    if type(data) == "table" and type(data.episodes) ~= "table"
            and type(data[1]) == "table" then
        logger.warn("Picayomi Detail: episodes_data 传成了裸数组, 已自动包成 "
            .. "{ episodes = ..., page = 1, pages = 1, total = " .. #data .. " }")
        data = { episodes = data, page = 1, pages = 1, total = #data }
    end
    if data and type(data.episodes) == "table" then
        local has_order = false
        for _i, e in ipairs(data.episodes) do
            if tonumber(e.order) then has_order = true break end
        end
        if has_order then
            table.sort(data.episodes, function(a, b)
                -- 没有 order 的排到最后, 保持相对稳定
                local oa, ob = tonumber(a.order), tonumber(b.order)
                if oa and ob then return oa < ob end
                if oa then return true end
                if ob then return false end
                return false
            end)
        end
    end
    return data
end

function ComicDetail:setEpisodesData(data)
    self.episodes_data = normalizeEpisodesData(data)
end

--- 该漫画"接着读"的目标章节 order; 没有阅读历史则返回 nil
--
-- 入口可以直接给 resume_episode_order (历史页就是这么做的); 否则查本地浏览历史。
-- 有它才说明"这本书读过、可以继续", 页脚据此决定是否多给一个「继续」按钮。
function ComicDetail:getResumeOrder()
    if self.resume_episode_order then
        return self.resume_episode_order
    end
    if not (self.comic_model and self.comic_model.getHistoryItem and self.comic) then
        return nil
    end
    local ok, item = pcall(function() return self.comic_model:getHistoryItem(self.comic._id, self.source_id) end)
    if ok and item then
        return item.episode or item.last_page
    end
    return nil
end

function ComicDetail:chapterProgressText()
    local order=self:getResumeOrder()
    if order==nil then return end
    for i,episode in ipairs(self.episodes_data and self.episodes_data.episodes or {}) do
        if tostring(episode.order)==tostring(order) then
            local title=episode.title
            if type(title)=="string" and title~="" then return _("上次看到：")..title end
            return T(self:isNovel() and _("上次看到第 %1 章") or _("上次看到第 %1 话"),i)
        end
    end
    if self.comic_model and self.comic_model.getHistoryItem then
        local ok,item=pcall(self.comic_model.getHistoryItem,self.comic_model,self.comic._id,self.source_id)
        if ok and item and type(item.episode_title)=="string" and item.episode_title~="" then
            return _("上次看到：")..item.episode_title
        end
    end
end

function ComicDetail:findInitialEpisode()
    local episodes = self.episodes_data and self.episodes_data.episodes or {}
    -- 有阅读历史则从历史那章继续
    local resume_order = self:getResumeOrder()
    if resume_order then
        for _idx, episode in ipairs(episodes) do
            if tostring(episode.order) == tostring(resume_order) then
                return episode
            end
        end
    end
    -- 否则从第一章开始: 取 order 最小的一章, 不依赖源的返回顺序
    return self:findFirstEpisode()
end

--- 第一章 (order 最小的一章), 不依赖源的返回顺序
function ComicDetail:findFirstEpisode()
    local episodes = self.episodes_data and self.episodes_data.episodes or {}
    local first, first_order
    for _idx, episode in ipairs(episodes) do
        local o = tonumber(episode.order)
        if o and (not first_order or o < first_order) then
            first, first_order = episode, o
        end
    end
    return first or episodes[1]
end

--- 「继续」: 按阅读历史/上次页码接着读
--
-- 页码由 KOReader 自己恢复 (ReaderPaging:onReadSettings 读 sidecar 的 last_page),
-- 这里不需要做任何事。
--
-- 注: "清掉阅读位置"的实现不在这里 —— 它在 util/reading_position.lua, 由
-- api/comic.lua:prepareComic 在**打开文档之前**统一调用 (那里是首次打开/换章/续读的
-- 必经关口)。理由: 同一话有两种文档 (流式 .stream / 离线 .cbz) 各有 sidecar,
-- 路径只有 download_manager 知道; 而且放在"打开前最后一步"才最可靠。
function ComicDetail:startReading()
    if not self.offline and not require("ui.common.source_access").check(self.source) then self:revealQuickEntry();return end
    local episode = self:findInitialEpisode()
    if not episode then
        self:revealQuickEntry()
        UIManager:show(InfoMessage:new{ text = self:isNovel() and _("该小说没有可阅读的章节") or _("该漫画没有可阅读的章节"), timeout = 2 }, "ui")
        return
    end
    -- 按阅读历史/上次页码接着读 (from_beginning 为假)
    self:openReader(episode, { from_beginning = false })
end

--- 从第一章第一页开始 (「开始」按钮)
--
-- 语义: 「开始」= 固定从头, **禁止加载任何进度**; 读进度是「继续」的事。
-- 保证分两层:
--   1) 打开前清掉 KOReader 记住的页码 (context.from_beginning -> prepareComic),
--      这样它根本不会恢复, 用户看不到任何跳动;
--   2) 阅读器就绪后再兜一次 (ui/reader.lua:attachReaderHooks) —— 万一哪天 KOReader
--      换了恢复机制, 也仍然落在第 1 页, 并会在日志里留下警告。
function ComicDetail:startReadingFromBeginning()
    if not self.offline and not require("ui.common.source_access").check(self.source) then return end
    local episode = self:findFirstEpisode()
    if not episode then
        UIManager:show(InfoMessage:new{ text = self:isNovel() and _("该小说没有可阅读的章节") or _("该漫画没有可阅读的章节"), timeout = 2 }, "ui")
        return
    end
    if logger.enabled then logger.info("Picayomi Detail: 「开始」= 从第 " .. tostring(episode.order)
        .. " 话第 1 页开始 (不加载阅读进度)") end
    self:openReader(episode, { from_beginning = true })
end

--- 打开某一话
--
-- @param opts.from_beginning true = 「开始」: 固定从第一页读, 打开前会清掉 KOReader
--        为这一话记住的页码 (见 util/reading_position.lua); false/nil = 「继续」/点章节行,
--        按 KOReader 记住的进度恢复。
function ComicDetail:openReader(episode, opts)
    self.auto_continue = nil
    if not self.offline and not require("ui.common.source_access").check(self.source) then return end
    if self.source and self.source.content_type=="novel" then
        return require("novel.open").open(self,episode,opts)
    end
    self.opening_reader = true
    self:cancelChapterLoad()
    if self._detail_task then self._detail_task:cancel() end
    local episodes = self.episodes_data and self.episodes_data.episodes or { episode }
    self.comic_model:saveHistory(self.comic._id, self.comic.title, episode.order, self.source_id,
        { episode_title = episode.title, thumb = self.comic.thumb })
    local outer_return = self.on_return_from_reader or self.on_back
    local self_ = self
    local function return_callback()
        self_.opening_reader=false
        self_:revealQuickEntry()
        self_.resume_episode_order=nil -- Prefer the progress saved during this read.
        -- 读完一话回来: 页脚必须**重算一次**。
        --
        -- 详情页在阅读期间是留在窗口栈里的 (0.7.2 起, 它就是返回目标), 返回时
        -- 只是把它重绘出来 —— 而页脚是 buildContent 时按"有没有阅读历史"定下的。
        -- 于是第一次读一本新漫画时: 进详情页时没有历史 -> 页脚只有「开始」;
        -- 读了一点回来, 历史已经有了, 但页脚从来没重建 -> 「继续」永远不出现
        -- (真机反馈: "新漫画刚看了一点, 回到详情, 不会刷新出继续按钮")。
        --
        -- 保留屏游标 (refresh 默认行为): 用户离开时停在第几屏, 回来还在那一屏。
        if not self_._closed then self_:refresh();self_:loadDetailsAfterReading() end
        if outer_return then outer_return() end
    end
    -- 阅读器要把进度写回**本页的源** (历史按源分桶)。opts 是调用方传进来的,
    -- 复制一份再加字段 —— 不要改别人的表。
    local reader_opts = {}
    for k, v in pairs(opts or {}) do reader_opts[k] = v end
    reader_opts.source_id = reader_opts.source_id or self.source_id
    reader_opts.offline = self.offline == true
    self.reader = self.reader or require("ui.reader")
    self.reader:open(self.comic, episode, episodes, return_callback, self, reader_opts)
end

--- 取章节列表的默认实现
--
-- 关键: 用 **self.source** (本页记录的源), 不是 `api.comic` 那个"当前源"。
--   列表页把条目的源记在 self.source 上传下来 (见 ui/history.lua 的说明:
--   "详情页必须与列表同源, 否则会拿这个源的 id 去问另一个源")。而 api.comic
--   转发给的是 `SourceRegistry:getCurrent()` —— 用户中途切了源, 两者就不再是
--   同一个, 章节列表会拿 A 源的 id 去问 B 源。
--   各入口原先各自塞了一份 `fetch_chapters = api.comic:getComicEpisodes`,
--   恰好把这个隐患写死了, 现已统一删掉、都走这里。
function ComicDetail:defaultFetchChapters(comic_id, page, context)
    if self.source and self.source.refreshChapters then
        return self.source:refreshChapters(comic_id,context)
    end
    if self.source and self.source.getChapters then
        return self.source:getChapters(comic_id, page)
    end
    local comic_api = require("api.comic")
    return comic_api:getComicEpisodes(comic_id, page)
end

function ComicDetail:cancelChapterLoad()
    local task=self._chapter_task
    self._chapter_task=nil
    if task and task.cancel then task:cancel() end
    if self._chapter_unwatch then self._chapter_unwatch();self._chapter_unwatch=nil end
    self.loading_chapters=false
    self._chapter_refresh_manual=nil
end

function ComicDetail:loadChapters(page,force)
    if self._closed or self.opening_reader then return end
    if not self.offline and not require("ui.common.source_access").check(self.source) then return end
    if self.loading_chapters then
        -- A manual tap may join an automatic stale-cache check already in flight.
        if force and not self._chapter_refresh_manual then
            self._chapter_refresh_manual=true
            self:refresh();UIManager:forceRePaint()
        end
        return
    end
    local source=self.source
    local cached,fresh
    if not force and not self.fetch_chapters and source and source.peekChapters then
        cached,fresh=source:peekChapters(self.comic._id)
        if cached then
            if not self.episodes_data then self:setEpisodesData(cached);self:refresh() end
            if fresh then self._chapters_stale=nil;self:tryAutoContinue();return end
        end
    end
    self.loading_chapters = true
    self._chapter_refresh_manual=force==true
    local background=self.episodes_data~=nil
    if force and background then self:refresh();UIManager:forceRePaint() end
    local generation=source and source.sessionGeneration and source:sessionGeneration()
    local started=require("socket").gettime()
    local timeout=60
    local function cancelled()
        return self._closed or self.opening_reader
            or generation and source:sessionGeneration()~=generation
    end
    local function complete(ok,episodes_data,err)
        if logger.enabled then logger.info("Picayomi chapters: source",self.source_id or "unknown","ok",ok,"elapsed",math.floor(require("socket").gettime()-started)) end
        local manual=self._chapter_refresh_manual
        self._chapter_refresh_manual=nil
        self.loading_chapters=false
        if self._chapter_unwatch then self._chapter_unwatch();self._chapter_unwatch=nil end
        if cancelled() then return end
        if ok and episodes_data then
            self._chapter_error=nil
            episodes_data=normalizeEpisodesData(episodes_data)
            local changed=true
            if source and source.peekChapters and self.episodes_data then
                local diff=require("util.chapter_cache").diff(
                    {items=self.episodes_data.episodes or {}},{items=episodes_data.episodes or {}})
                changed=diff.different
            end
            self._chapters_stale=nil
            if changed then self.episodes_data=episodes_data end
            if changed or manual then self:refresh() end
            if manual then
                local total=episodes_data.total or #(episodes_data.episodes or {})
                UIManager:show(InfoMessage:new{
                    text=changed and T(self:isNovel() and _("章节已更新，共 %1 章") or _("章节已更新，共 %1 话"),total)
                        or T(self:isNovel() and _("章节已是最新，共 %1 章") or _("章节已是最新，共 %1 话"),total),timeout=2,
                },"ui")
            end
            self:tryAutoContinue()
        else
            self._chapter_error=err or true
            self.auto_continue = nil
            self:revealQuickEntry()
            if manual and self.episodes_data then self:refresh() end
            UIManager:show(InfoMessage:new{
                text=T(manual and _("刷新章节失败: %1") or _("获取章节列表失败: %1"),require("ui.common.error_message").describe(err))
                    ..(background and _("\n已保留原有章节，可点击“刷新章节”重试。") or ""),timeout=3,
            },"ui")
            if not self.episodes_data then
                self:refresh()
            end
        end
    end
    local function fetch(progress)
        if progress then progress({message="正在获取并核对完整目录…"})end
        local context={deadline=started+timeout,isCancelled=cancelled,force_refresh=force==true,
            on_progress=progress and function(p)
                if not cancelled() and type(p)=="table" then
                    local done,total=tonumber(p.completed),tonumber(p.total)
                    if done and total and done>=0 and total>0 and done<=total and total<=20000 then
                        progress({message="正在核对章节分卷",completed=done,total=total})
                    end
                end
            end}
        local fn=self.fetch_chapters or function(id,target_page) return self:defaultFetchChapters(id,target_page,context) end
        return fn(self.comic._id,page or 1)
    end
    if source and source.watchSession then
        self._chapter_unwatch=source:watchSession(function() self:cancelChapterLoad() end)
    end
    local function on_cancel()
        self.auto_continue = nil
        self:revealQuickEntry()
        local manual=self._chapter_refresh_manual
        self._chapter_refresh_manual=nil
        self.loading_chapters=false
        if self._chapter_unwatch then self._chapter_unwatch();self._chapter_unwatch=nil end
        if manual and background and not self._closed and not self.opening_reader then self:refresh() end
    end
    -- LoadingTask 负责"显示提示 → 延迟一拍 → 取数 → 关提示", 并且**取数抛异常时也关**。
    -- 抛异常时若走不到 close(loading), 后果有两重:
    --   1. "加载漫画章节..." 永久盖在屏幕上;
    --   2. self.loading_chapters 一直是 true, 而本函数开头就是
    --      `if self.loading_chapters then return end` —— 之后每次进详情页都直接返回,
    --      章节列表永远出不来 (用户看到的就是"点了没反应")。
    -- 所以复位交给 set_busy: 它在取数之后**无条件**执行, 不依赖任何分支。
    if background then
        self._chapter_task=LoadingTask.background(nil,function() complete(fetch()) end,{
            delay=0.1,is_cancelled=cancelled,timeout=timeout,reuse_worker=true,
            on_cancel=on_cancel,
            on_error=function(err) complete(false,nil,err) end,
        })
        return
    end
    self._chapter_task=LoadingTask.run{
        progress = true,
        stage = _("正在获取章节目录…（最多等待 60 秒）"),
        message = self:isNovel() and _("加载小说章节") or _("加载漫画章节"),
        delay = 0.1,
        async = true,
        reuse_worker = true,
        timeout = timeout,
        is_cancelled = cancelled,
        fetch = fetch,
        set_busy = function(v) self.loading_chapters = v end,
        on_cancel = on_cancel,
        on_done = complete,
    }
end

--- 跳转到指定"章节页"(章节数据的分页, 与屏幕翻页不是一回事)
-- 总页数来自服务端 (episodes_data.pages), 所以能给出准确的起止点。
function ComicDetail:showChapterJumpDialog()
    local ed = self.episodes_data or {}
    local pages = tonumber(ed.pages) or 1
    local cur = tonumber(ed.page) or 1
    if pages <= 1 then return end

    local dialog
    dialog = InputDialog:new{
        title = _("跳转到章节页"),
        description = T(_("共 %1 页章节，请输入要跳转的页码"), pages),
        input = tostring(cur),
        input_type = "number",
        buttons = {
            {
                {
                    text = _("取消"),
                    id = "close",
                    callback = function() UIManager:close(dialog, "ui") end,
                },
                {
                    text = _("跳转"),
                    is_enter_default = true,
                    callback = function()
                        local value = dialog:getInputText()
                        UIManager:close(dialog, "ui")
                        local n = tonumber(value)
                        if not n or n ~= math.floor(n) or n < 1 or n > pages then
                            UIManager:show(InfoMessage:new{
                                text = T(_("请输入 1 ~ %1 之间的页码"), pages),
                                timeout = 3,
                            }, "ui")
                            return
                        end
                        if n ~= cur then self:loadChapters(n) end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog, "ui")
    dialog:onShowKeyboard()
end

function ComicDetail:loadCover()
    if self.cover_loading or self.cover_loaded then return end
    if not self.comic.thumb or self.comic.thumb == "" or not self.comic._id then return end
    if CoverCache.find(self.source_id, self.comic._id) then
        self.cover_loaded = true
        return
    end
    -- 离线模式: 只能用已缓存的封面, 不再联网补
    if self.offline then return end
    if not self.source then return end

    self.cover_loading = true
    CoverCache.ensure(self.source, self.source_id, self.comic, function(path)
        self.cover_loading = false
        if not path then return end
        -- 页面已关闭: 别再重建/刷新死控件 (会刷到当前画面上去, 见列表页 onCloseWidget)
        if self._closed then return end
        self.cover_loaded = true
        self:refresh()
    end)
end

--- 让收藏按钮文案与当前收藏状态保持一致
--
-- 文案**必须**由状态推导。各入口各写各的会出两类问题 (都真实踩过):
--   1. 已收藏的漫画显示"收藏" —— 收藏列表接口不返回 isFavourite, 而入口
--      把文案写死成"收藏", 于是状态永远显示不对;
--   2. 切换成功后文案不跟着变 —— 有的入口(搜索/分类)压根没有 after_success。
-- 入口若要固定文案 (如收藏页只有"取消收藏"这一种动作), 用 pinned_label 声明。
--- 本地收藏 (未登录兜底) 的收藏状态: 本地就有答案, 不需要问源
--
-- favorite_action.local_state 只在"本地兜底"后端上存在 (见 util/favorites.buildAction);
-- 登录状态下它是 nil, 收藏状态仍由 syncFromSource 去问源。
function ComicDetail:seedLocalFavoriteState()
    local fa = self.favorite_action
    if not (fa and fa.local_state) then return end
    if self.comic.isFavourite ~= nil then return end
    local known = fa.local_state(self.comic)
    if known ~= nil then self.comic.isFavourite = known end
end

--- "没有内容": nil / 空串 / 空表。合并时只填空缺, 不覆盖已有值。
local function blank(value)
    if value == nil or value == "" then return true end
    if type(value) == "table" then return next(value) == nil end
    return false
end

--- 用详情接口的数据补空缺字段; 返回是否真的改了什么
--
-- 只填空缺: 列表数据通常更干净 —— 源 B 的详情接口 author 是空串, 而列表里有作者;
-- 反过来源 A/源 C 的列表项没有简介, 详情接口才有。两边各补各的。
function ComicDetail:mergeDetail(detail)
    local c = self.comic
    local changed = false
    local function fill(key, value)
        if not blank(value) and blank(c[key]) then
            c[key] = value
            changed = true
        end
    end

    -- 数字字段: normalizeComic 会把缺失的归成 0, 而 0 不是 blank —— 单独判
    local function fill_num(key, value)
        local n = tonumber(value) or 0
        if n > 0 and (tonumber(c[key]) or 0) <= 0 then
            c[key] = n
            changed = true
        end
    end

    if self:isNovel() and not blank(JN.str(detail.description)) then
        if c.description~=detail.description then c.description=detail.description;changed=true end
    else
        fill("description", JN.str(detail.description))
    end
    fill("updated_at", JN.str(detail.updated_at))
    fill("update_time", JN.str(detail.update_time) or JN.str(detail.updated_at))
    local author=JN.str(detail.author)
    if author and author~="" and author~="未知作者" and author~=_("未知作者") then
        if blank(c.author) or c.author=="未知作者" or c.author==_("未知作者") then
            c.author=author;changed=true
        end
        if blank(c.author_text) or c.author_text=="未知作者" or c.author_text==_("未知作者") then
            c.author_text=c.author;changed=true
        end
    end
    if type(detail.metadata)=="table" and next(detail.metadata) then
        c.metadata=detail.metadata;changed=true
    end
    fill_num("pagesCount", JN.num(detail.pagesCount, 0))
    fill_num("epsCount", JN.num(detail.epsCount, 0))
    fill_num("likesCount", JN.num(detail.likesCount, 0))
    if c.finished == nil and detail.finished ~= nil then
        c.finished = detail.finished
        changed = true
    end
    if blank(c.tags) and type(detail.tags) == "table" and #detail.tags > 0 then
        c.tags = detail.tags
        changed = true
    end
    if blank(c.tags_text) then
        local txt = join(c.tags, " / ")
        if txt ~= "" then
            c.tags_text = txt
            changed = true
        end
    end
    -- 分类: 详情接口可能给数组 (源 A/源 B) 也可能给字符串 (源 C)。
    --
    -- 这里是**详情优先** (非空就覆盖), 不是只填空缺: 列表项的分类经常缺失或不可靠
    -- —— 源 C 的列表页根本没有分类; 老版本还把标签串、"25張圖片，創建於…"
    -- 塞进过 categories, 历史记录里就存着这些旧值, 只填空缺永远换不掉。
    if not blank(detail.categories) then
        local txt = type(detail.categories) == "table"
            and join(detail.categories, " / ") or tostring(detail.categories)
        if txt ~= "" and txt ~= (c.categories_text or "") then
            c.categories = detail.categories
            c.categories_text = txt
            changed = true
        end
    end
    -- 作品属性 (页数/编号): 展示在简介区 (见 createHeader)
    if blank(c.meta_text) and not blank(detail.meta_text) then
        c.meta_text = detail.meta_text
        changed = true
    end

    -- 派生展示文本。作者: 空串/未知作者占位都要能被真作者替换
    if not blank(c.author) and blank(c.author_text) then
        c.author_text = c.author
        changed = true
    end
    if blank(c.categories_text) then
        local txt = join(c.categories, " / ")
        if txt ~= "" then
            c.categories_text = txt
            changed = true
        end
    end
    return changed
end

--- 打开详情页后向源补一次数据 (信息 + 收藏状态, **同一次请求**)
--
-- 两件事共用一次详情请求:
--   1. 收藏状态: **列表接口不返回 isFavourite**(只有收藏列表才被 markAll 标记成
--      "已收藏"), 从搜索/分类/首页/历史进入时它是 nil, 按钮会错误地显示"收藏"。
--   2. 元信息: 列表项往往没有简介 (源 A/源 C), 源 C 连作者/分类都没有 ——
--      详情页只拿列表项, 于是显示"暂无简介 / 作者：空 / 分类：25張圖片…"。
--
-- 本地数据已经齐了就不发请求 (从收藏列表进入时 isFavourite 已知, 简介也常在)。
function ComicDetail:detailNeeds()
    local c=self.comic
    local fa = self.favorite_action
    -- 本地兜底后端: 收藏状态只可能在本地, 不为它去请求源 (未登录必然 401)
    local need_fav = fa ~= nil and c.isFavourite == nil and fa.local_state == nil
    local need_info = blank(c.description) or blank(c.author_text) or blank(c.author)
        or blank(c.categories_text) or blank(c.tags)
        -- 合集没有页数、只有章节数 —— 两者都缺才算"信息不全"
        or ((tonumber(c.pagesCount) or 0) <= 0 and (tonumber(c.epsCount) or 0) <= 0)
    if self:isNovel() then
        need_info=blank(c.description) or blank(c.author_text) or c.author_text=="未知作者"
            or c.author_text==_("未知作者") or blank(c.categories_text)
    end
    return need_fav,need_info
end

function ComicDetail:syncFromSource()
    if not self.offline and not require("ui.common.source_access").check(self.source,nil,true) then return end
    local source = self.source
    local c = self.comic
    if not (source and source.getComicDetail) or not c._id then return end

    local fa = self.favorite_action
    local need_fav,need_info=self:detailNeeds()
    if not need_fav and not need_info then return true end

    local ok, detail, err = source:getComicDetail(c._id)
    if not ok or type(detail) ~= "table" then return false,err or detail or _("详情加载失败") end
    if self._closed or self.closing_by_back or self.opening_reader then return end

    local changed = self:mergeDetail(detail)

    if need_fav and detail.isFavourite ~= nil then
        c.isFavourite = detail.isFavourite
        if fa then
            local want = fa.pinned_label
                or (c.isFavourite and _("取消收藏") or _("收藏"))
            if fa.label ~= want then
                fa.label = want
                changed = true
            end
        end
    end

    -- 一次重建就够: syncFavoriteLabel 自己也会 refresh, 合并后不要刷两遍
    if changed and self.list_view then self:refresh() end
    return true
end

function ComicDetail:syncFavoriteLabel()
    local fa = self.favorite_action
    if not fa then return end
    local want = fa.pinned_label
        or ((self.comic and self.comic.isFavourite) and _("取消收藏") or _("收藏"))
    if fa.label == want then return end
    fa.label = want
    -- 构建期(list_view 还没建)只需把文案准备好; 之后才需要重建界面
    if self.list_view then self:refresh() end
end

function ComicDetail:runFavoriteAction()
    if self.favorite_action and self.favorite_action.backend == "online"
        and not require("ui.common.source_access").check(self.source,"favorites") then return end
    if not self.favorite_action or not self.favorite_action.run then return end
    local function run()
        LoadingTask.run{
            message = self.favorite_action.loading_text or _("处理中..."),
            delay = 0.1,
            -- 闭包必须按 (ok, data, err) 契约返回 —— favorite_action.run 只返回
            -- (ok, err) 两位, 若直接透传, 抛异常时 LoadingTask 归一出的消息会落在
            -- **第 3 位**, 而调用方只取两位就会拿到 nil, 提示变成"操作失败: 未知错误"。
            fetch = function()
                local r_ok, r_err = self.favorite_action.run(self.comic)
                return r_ok, nil, r_err
            end,
            on_done = function(ok, _data, err)
                if ok then
                    UIManager:show(InfoMessage:new{ text = self.favorite_action.success_text or _("操作成功"), timeout = 2 }, "ui")
                    if self.favorite_action.after_success then
                        self.favorite_action.after_success(self)
                    end
                    -- 状态变了, 文案要跟上 (入口可能忘了更新, 这里统一兜底)
                    self:syncFavoriteLabel()
                else
                    UIManager:show(InfoMessage:new{
                        text = T(_("操作失败: %1"), require("ui.common.error_message").describe(err)),
                        timeout = 3,
                    }, "ui")
                end
            end,
        }
    end

    local confirm_text = self.favorite_action.confirm_text
        or (self.comic.isFavourite == true and _("确定取消收藏这部作品吗？"))
    if confirm_text then
        UIManager:show(ConfirmBox:new{
            text = confirm_text,
            ok_text = _("确定"),
            cancel_text = _("取消"),
            ok_callback = run,
        }, "ui")
    else
        run()
    end
end

function ComicDetail:nextScreen()
    if (self.screen_index or 1) < self:loadedScreens() then
        self.screen_index = self.screen_index + 1
        self:renderWindow()
    end
    return true
end

function ComicDetail:prevScreen()
    if (self.screen_index or 1) > 1 then
        self.screen_index = self.screen_index - 1
        self:renderWindow()
    end
    return true
end

function ComicDetail:onPageForward()
    return self:nextScreen()
end

function ComicDetail:onPageBackward()
    return self:prevScreen()
end

-- ==================== 标签 / 作者 -> 搜索 ====================

--- 标签菜单: 选中某个标签即按它搜索
-- 这里用弹菜单而不是"一行多个按钮": 标签常有十几个且长短不一, 铺在页面上会挤成一团,
-- 页面也可能放不下。
function ComicDetail:showTagMenu(categories)
    local tags = categories and self.comic.categories or self.comic.tags
    local has_list = type(tags) == "table" and #tags > 0

    -- 没有结构化标签时退回按整串搜索 —— 保证"点了有反应"
    if not has_list then
        local text = self.comic.tags_text
        if text and text ~= "" then
            self:searchByKeyword(text)
        else
            UIManager:show(InfoMessage:new{ text = _("没有可搜索的标签") }, "ui")
        end
        return
    end

    local buttons = {}
    local row = {}
    for _i, tag in ipairs(tags) do
        local name = tostring(tag)
        table.insert(row, {
            text = name,
            callback = function()
                if self.tag_dialog then
                    UIManager:close(self.tag_dialog, "ui")
                    self.tag_dialog = nil
                end
                self:searchByKeyword(name)
            end,
        })
        -- 一行两个: 标签名通常不长, 两列既省纵向空间又不至于挤
        if #row == 2 then
            table.insert(buttons, row)
            row = {}
        end
    end
    if #row > 0 then table.insert(buttons, row) end
    table.insert(buttons, { {
        text = _("取消"),
        callback = function()
            if self.tag_dialog then
                UIManager:close(self.tag_dialog, "ui")
                self.tag_dialog = nil
            end
        end,
    } })

    self.tag_dialog = ButtonDialog:new{
        title = categories and _("选择分类进行搜索") or _("选择标签进行搜索"),
        buttons = buttons,
    }
    UIManager:show(self.tag_dialog, "ui")
end

--- 按关键词搜索并展示结果 (标签 / 作者点击后走这里)
-- @param sort 可选: 结果列表里切换排序时传入
function ComicDetail:searchByKeyword(keyword, sort)
    if not require("ui.common.source_access").check(self.source,"search") then return end
    keyword = tostring(keyword or "")
    if keyword == "" then return end

    if not (self.source and self.source.search) then
        UIManager:show(InfoMessage:new{ text = _("当前源不支持搜索") }, "ui")
        return
    end

    -- 抛异常时也关掉提示, 否则"搜索【…】…"永久盖屏 (见 loading_task 注释)
    -- 不传 delay: 这里保持同步取数 (调用方紧接着就要用结果开新列表),
    -- 提示照样看得见 —— run 在取数前已经 forceRePaint 过一次。
    LoadingTask.run{
        message = T(_("搜索【%1】…"), keyword),
        fetch = function()
            return self.source:search(keyword, 1, sort or self.related_sort)
        end,
        on_done = function(ok, data, err)
            if not ok or not data or type(data.comics) ~= "table" or #data.comics == 0 then
                UIManager:show(InfoMessage:new{
                    text = err and require("ui.common.error_message").describe(err) or T(self:isNovel() and _("没有找到与【%1】相关的小说") or _("没有找到与【%1】相关的漫画"), keyword),
                }, "ui")
                return
            end
            self:showRelatedResults(keyword, data)
        end,
    }
end

--- 展示"按标签 / 作者搜索"的结果
function ComicDetail:showRelatedResults(keyword, data)
    -- 换排序时会重建列表: 旧的要收掉, 免得窗口栈里堆出多层一模一样的列表。
    -- 收在最后一步 (replace_page): 先 show 新的, 再关旧的 —— 否则中间那一瞬
    -- 露出来的是详情页, 看起来像"点排序先退回上一页"。
    local old_menu = self.related_menu
    self.related_menu = nil

    local comics = {}
    for _i, raw in ipairs(data.comics) do
        local processed = self.comic_model:processComicData(raw)
        if processed then table.insert(comics, processed) end
    end

    local source = self.source
    local model = self.comic_model
    local page = self

    self.related_menu = VisualComicList:new{
        title = T(_("搜索: %1"), keyword),
        comics = comics,
        server_page = data.page or 1,
        total_pages = data.pages, server_page_size = data.page_size,
        total_count = data.total,
        fetch_page = function(p) return source:search(keyword, p, page.related_sort) end,
        processor = function(raw) return model:processComicData(raw) end,
        -- 结果列表也支持排序 (换排序 = 用新排序重搜第一页)
        sort_options = (source.getSortOptions and source:getSortOptions("search")) or {},
        sort = self.related_sort,
        on_sort_change = function(value)
            page.related_sort = value
            page:searchByKeyword(keyword, value)
        end,
        source = source,
        source_id = self.source_id,
        comic_model = model,
        on_select = function(comic, navigation) page:openRelatedDetail(comic, navigation) end,
        on_back = function(list)
            if list then UIManager:close(list, "ui") end
            page.related_menu = nil
        end,
    }
    WidgetSweep.replace_page(old_menu, self.related_menu)
end

--- 从结果列表打开另一部作品的详情页 (压在当前页之上, 返回即回到结果)
--
-- **必须传 on_back / on_return_from_reader。**
-- 少了它们, 这一页进阅读器时 return_callback (= on_return_from_reader or on_back)
-- 就是 nil, PicaReader 会走它自己的默认回调 —— Home:new{}:show() ——
-- 于是「标签检索 -> 结果列表 -> 某本 -> 阅读 -> 返回」直接掉回主页, 检索结果整条
-- 路径都没了 (真机 2026-10-18 反馈 3 / 6)。这一页关掉时结果列表还在栈里,
-- 所以两个回调都不需要重建任何东西, 只要把引用清掉。
function ComicDetail:openRelatedDetail(comic, navigation)
    if not comic then return end
    local parent = self
    local FavoriteActions = require("util.favorites")
    self.related_detail = ComicDetail:new{
        navigation = navigation,
        comic = comic,
        source = self.source,
        source_id = self.source_id,
        comic_model = self.comic_model,
        reader = self.reader,
        -- 收藏按钮: 不传 favorite_action 的话它是**禁用**的 (见 init 里的按钮构建),
        -- 用户从标签结果进来就只能看不能收藏。
        favorite_action = FavoriteActions.buildAction{
            source = self.source,
            source_id = self.source_id,
            comic_api = require("api.comic"),
            comic = comic,
        },
        on_back = function()
            parent.related_detail = nil
        end,
    }
    UIManager:show(self.related_detail, "ui")
end

--- 打开评论页 (只读浏览)
--
-- 独立成页而不是内嵌在详情页里: 详情页是"等高行分页 ListView" (header + 列表 + 页脚),
-- 结构上不支持再嵌一个可滚动区域; 而且评论正文长短差异大, 硬塞进等高行只能全截断。
function ComicDetail:showComments()
    if not require("ui.common.source_access").check(self.source,"comments") then return end
    local status = require("source.capabilities").query(self.source, "comments")
    if not status.available then
        UIManager:show(InfoMessage:new{ text = status.reason, timeout = 3 }, "ui")
        return
    end
    if not (self.source and self.source.getComments and self.comic and self.comic._id) then
        UIManager:show(InfoMessage:new{
            text = _("当前源不支持评论"),
            timeout = 3,
        }, "ui")
        return
    end

    local comic_id = self.comic._id
    local source = self.source
    self.comment_list = CommentList:new{
        title = T(_("评论 · %1"), self.comic.title or ""),
        comic_id = comic_id,
        source = source,
        source_id = self.source_id,
        fetch_page = function(page)
            return source:getComments(comic_id, page)
        end,
        on_back = function()
            self.comment_list = nil
        end,
    }
    UIManager:show(self.comment_list, "ui")
end

--- 打开章节选择页 (多选后交给下载队列)
function ComicDetail:showDownloadSelect()
    if not require("ui.common.source_access").check(self.source,"download") then return end
    local status = require("source.capabilities").query(self.source, "download")
    if not status.available then
        UIManager:show(InfoMessage:new{ text = status.reason, timeout = 3 }, "ui")
        return
    end
    if not self.episodes_data then
        UIManager:show(InfoMessage:new{
            text = _("章节还在加载，请稍后再试"),
            timeout = 3,
        }, "ui")
        return
    end
    local DownloadSelect = require("ui.download_select")
    local page
    page = DownloadSelect:new{
        comic = self.comic,
        source = self.source,
        source_id = self.source_id,
        episodes_data = self.episodes_data,
        on_back = function()
            self.download_select = nil
            -- 下载可能已经开始/完成, 回到详情时把入口行刷新一下
            self:refresh()
        end,
    }
    self.download_select = page
    page:show()
end

function ComicDetail:goBack()
    -- 放大层/简介全文盖在本页之上: 本页关掉时必须一起收, 否则它们会留在屏幕上 (点不掉)
    self:closeCoverZoom()
    self:closeTitleViewer()
    self:closeDescriptionViewer()
    self.closing_by_back = true
    -- 必须显式给刷新模式: UIManager:_refresh() 在 mode 为 nil 时会**直接丢弃**这次刷新,
    -- 结果就是控件已关闭、点击也能穿透到下层列表, 但屏幕完全不更新。
    -- KOReader 文档也建议: 覆盖在文件管理器之上的全屏控件, onCloseWidget 用 "ui"。
    UIManager:close(self, "ui")
    local list = self.navigation and self.navigation.origin_list
    if list and not list._closed then list:refreshVisible({[self.comic._id] = true}) end
    if self.on_back then self.on_back() end
    return true
end

function ComicDetail:onClose()
    return self:goBack()
end

--- 滑动: 边缘返回, 中间左右翻屏 (与列表页同一套规则, 见 ui/common/swipe_rules.lua)
function ComicDetail:onSwipe(_arg, ges)
    SwipeRules.dispatchPageSwipe(ges,{
        back=function()self:goBack()end,
        next=function()self:nextScreen()end,
        prev=function()if (self.screen_index or 1)>1 then self:prevScreen()end end,
    })
    return true
end

function ComicDetail:onCloseWidget()
    if self._closed then return end
    self._closed = true
    if self._novel_session and self._novel_session.close then self._novel_session.close() end
    if self._novel_task then self._novel_task:cancel();self._novel_task=nil end
    -- 先落标记: 之后的异步封面回调据此放弃刷新死控件 (见 loadCover)
    self.auto_continue = nil
    self:cancelChapterLoad()
    if self._detail_task then self._detail_task:cancel() end
    -- 本页被任何路径关掉 (返回 / 清扫 / 换章) 时, 放大层与简介全文不能留下
    if self._return_detail_timer then UIManager:unschedule(self._return_detail_timer);self._return_detail_timer=nil end
    self:closeCoverZoom()
    self:closeTitleViewer()
    self:closeDescriptionViewer()
    if self.opening_reader then return end
    -- sweeping: 被 util/widget_sweep 清扫 (退出 Picayomi 时)。此时不能调 on_back ——
    -- 那会"重建/重载"刚关掉的页面, 正是清扫要避免的。
    if self.closing_by_back or self.sweeping then
        self.closing_by_back = nil
        return
    end
    if self.on_back then self.on_back() end
end

return ComicDetail
