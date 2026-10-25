-- ui/common/visual_comic_list.lua
-- 带封面缩略图的单列漫画列表，面向 Kindle/KOReader 优化

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui.common.action_style").Button
local Device = require("device")
local Theme = require("ui.common.theme")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local ListView = require("ui/widget/listview")
local Menu = require("ui.common.action_style").Menu
local PageJump = require("ui/common/page_jump")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TapGuard = require("ui.common.tap_guard")
local MenuSwipe = require("ui.common.menu_swipe")
local MenuStyle = require("ui.common.menu_style")
local SwipeRules = require("ui.common.swipe_rules")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local LoadingTask = require("ui.common.loading_task")
local Screen = Device.screen
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local _ = require("gettext")
local T = require("ffi/util").template

local Screen = Device.screen
local Input = Device.input

-- 卡片行高不再写死: 由"实际建一张量一遍"得到, 见 VisualComicList:measureItemHeight。
--
-- 为什么不能写死: 卡片内容是若干 TextBoxWidget, 而它在"声明的 height < 行高"时会把
-- 自己**抬高**到 line_height_px, _bb 还要为下伸部多留几像素 —— 于是"内容实际画出来
-- 的高度"大于调用方声明的高度。写死常量就必然对不上, 而下面三者必须严格相等:
--     绘制区 (内容多高)
--     == 落位基准 (VerticalGroup / ListView 按 getSize().h 排)
--     == 命中区 (dimen)
-- 只要有一处对不上, 卡片就会被裁切、或被后一张盖住, 命中也会落到别处去。
-- 真机实测: 内容 286 vs 声明 260 (溢出 26px)。
-- 回归: test/functional_tap_geometry.lua

-- 封面预取向"后"看几屏。1 表示顺带预热下一屏的封面。
-- 代价是每次翻屏多几个请求, 换来翻页时封面已就位。
local COVER_LOOKAHEAD = 1

local CoverCache = require("util.cover_cache")
local ComicStats = require("ui.common.comic_stats")
local ComicMetadata = require("ui.common.comic_metadata")
local ComicModel = require("model.comic")
local logger = require("util.logger")

local CoverPlaceholder = Widget:extend{
    width = nil,
    height = nil,
    text = nil,
}

function CoverPlaceholder:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function CoverPlaceholder:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_GRAY_E)
    bb:paintBorder(x, y, self.width, self.height, Size.border.thin, Blitbuffer.COLOR_DARK_GRAY)

    local text = TextWidget:new{
        text = self.text or _("封面"),
        face = Theme.face("info"),
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local size = text:getSize()
    text:paintTo(bb, x + math.floor((self.width - size.w) / 2),
        y + math.floor((self.height - size.h) / 2))
end

local ComicListItem = InputContainer:extend{
    width = nil,
    height = nil,
    comic = nil,
    source = nil,
    source_id = nil,
    on_select = nil,
    list_ui = nil,
    index = nil,
    background = nil,
    cover_w = nil,
    cover_h = nil,
}

function ComicListItem:init()
    self.width = self.width or Screen:getWidth()
    self.height = self.height or Screen:scaleBySize(126)
    self.cover_w = self.cover_w or Screen:scaleBySize(72)
    self.cover_h = self.cover_h or Screen:scaleBySize(96)
    self.background = self.background or Blitbuffer.COLOR_WHITE
    self:buildContent()

    -- 点击区必须等于**实际画出来的高度**, 不能等于调用方声明的高度:
    -- 卡片内容是若干 TextBoxWidget, 它们实际的 _bb 高度常常大于声明 height
    -- (行高不足时被抬高 + 为下伸部留白)。绘制 / 落位 / 命中三者必须用同一个高度,
    -- 否则卡片被裁切或盖住, 命中也会落到别处。详见文件头的注释。
    self.height = self.content:getSize().h
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }

    if Device:isTouchDevice() then
        self.ges_events.TapSelect = {
            GestureRange:new{
                ges = "tap",
                range = self.dimen,
            }
        }
        -- 长按 = 针对"这一条"的操作 (目前只有历史页的删除)。
        --
        -- 用 hold_release 而不是 hold: hold 在手指还按着的时候就触发, 随后抬起
        -- 会被刚弹出的对话框当成一次点击 —— 删除这种操作不能有这个风险。
        -- (KOReader 的 MenuItem 也是这个取舍, 见 menu.lua:126。)
        if self.on_hold then
            self.ges_events.HoldSelect = {
                GestureRange:new{
                    ges = "hold_release",
                    range = self.dimen,
                }
            }
        end
    end
end

--- 这一条属于哪个源
-- 已下载页会混排多个源的条目, 条目自带的 source_id 优先; 其余列表页
-- (搜索/收藏/历史) 的条目没有该字段, 仍用列表自己的 source_id。
function ComicListItem:itemSourceId()
    local comic = self.comic or {}
    return comic.source_id or self.source_id
end

function ComicListItem:readingHistory()
    local list = self.list_ui
    local sid = self:itemSourceId()
    if not list or list.allow_continue == false or not self.on_select
        or not self.comic._id or type(sid) ~= "string" or sid == "" or sid == "unknown" or sid == "*" then return end
    local model = list.comic_model or ComicModel
    local ok, history = pcall(model.getHistoryItem, model, self.comic._id, sid)
    if ok and type(history) == "table" then return history end
end

function ComicListItem:coverWidget()
    local comic_id = self.comic and self.comic._id
    local path = comic_id and CoverCache.find(self:itemSourceId(), comic_id)
    if path then
        return ImageWidget:new{
            file = path,
            width = self.cover_w,
            height = self.cover_h,
            scale_factor = nil,
        }
    end

    return CoverPlaceholder:new{
        width = self.cover_w,
        height = self.cover_h,
        text = self.cover_error or ((self.comic and self.comic.thumb and self.comic.thumb ~= ""
            or self.list_ui and self.list_ui.resolve_cover) and _("加载中") or _("无封面")),
    }
end

--- 拼接显示文本
-- 只接受 string/number: JSON null 在 KOReader 里是真值 userdata,
-- 若混进来会让 table.concat 直接报错。
local function join(parts, sep)
    local out = {}
    for _idx, item in ipairs(parts or {}) do
        local t = type(item)
        if t == "string" and item ~= "" then
            table.insert(out, item)
        elseif t == "number" then
            table.insert(out, tostring(item))
        end
    end
    return table.concat(out, sep or " · ")
end

function ComicListItem:buildContent()
    local comic = self.comic or {}
    local padding = Screen:scaleBySize(8)
    local gap = Screen:scaleBySize(10)
    local text_w = self.width - self.cover_w - gap - padding * 2
    local title = comic.title or _("未知标题")
    local resumable = self:readingHistory() ~= nil
    self.resume_button = nil
    local author = comic.author_text or comic.author or _("未知作者")
    local categories = comic.categories_text
    if (not categories or categories == "") and type(comic.categories) == "table" then
        categories = join(comic.categories, " / ")
    end

    -- 第二行: 作者 / 分类合并且各占一行, 避免行数过多溢出卡片
    -- (下载状态并进第三行: 卡片行高必须与 measureItemHeight 的探针一致,
    --  多一行会让所有列表的行高一起变大。)
    -- 第二行: [来源] 作者 · 分类
    local configured_second,configured_third=ComicMetadata.lines(comic)
    local second_line = configured_second or author
    -- 跨源列表 (已下载) 必须标出来源: 同一部作品在不同源是不同的条目。
    -- 用方括号包起来, 免得被读成"作者名的一部分"。
    if type(comic.source_text) == "string" and comic.source_text ~= "" then
        second_line = second_line ~= "" and ("[" .. comic.source_text .. "] " .. second_line)
            or ("[" .. comic.source_text .. "]")
    end
    if configured_second==nil and categories and categories ~= "" then
        second_line = second_line ~= "" and (second_line .. " · " .. categories) or categories
    end
    -- 作者与分类都没有时 (源 C 的列表接口两者都不给), 用更新日期补位:
    -- 空着会让三种源的卡片长得不一样, 而日期是接口里现成的信息。
    -- 第二行整行空着时用更新日期补位。补过之后第三行就不要再写一次 (下面的
    -- updated_on_second 会告诉 ComicStats.line 跳过)。
    local updated_on_second = false
    if configured_second==nil and second_line == "" then
        local updated = ComicStats.updated_text(comic)
        if updated then
            second_line = T(_("更新 %1"), updated)
            updated_on_second = true
        end
    end

    -- 第三行 = 统一统计行 (话数 · 页数 · 完结/连载 · 喜欢 · 更新日期 · 编号兜底)。
    -- 与详情页表头共用 ComicStats.line, 否则同一部作品在列表和详情里显示的东西
    -- 不一样 (真机反馈: "有些显示话数, 有些显示页数, 有些又不显示")。
    local third_line = configured_third or ComicStats.line(comic, { updated_shown = updated_on_second })
    -- 下载状态: 正在下载 -> 进度条 (与第三行同高, 不改变行高);
    -- 已完成/部分完成 -> 第三行追加章节统计 (追加, 不覆盖: 能显示的就显示)。
    -- 第三行为空时不能留下开头的 " · "。
    local download_state = comic.download_state
    local downloading = download_state == "downloading"
    local function append_meta(text)
        third_line = third_line ~= "" and (third_line .. " · " .. text) or text
    end
    if download_state == "done" then
        append_meta(T(_("已下载 %1 话"), comic.download_total or 0))
    elseif download_state == "partial" then
        append_meta(T(_("已下载 %1/%2 话 · 部分未完成"),
            comic.download_done or 0, comic.download_total or 0))
    end

    -- 记下来供测试/排查 (列表与详情必须显示同一行)
    self.meta_text = third_line
    self.second_line = second_line

    --- 第三行 (下载中 = 进度条, 否则统计文本)。宽度随文字列宽度变化。
    local function makeThird(w)
        if comic.download_preparing then
            return TextBoxWidget:new{text=_("正在获取章节信息…"),face=Theme.face("info"),
                width=w,height=Screen:scaleBySize(30),height_overflow_show_ellipsis=true}
        end
        if downloading then
            local pct = math.max(0, math.min(1, tonumber(comic.download_progress) or 0))
            local bar_w = math.max(Screen:scaleBySize(80), math.floor(w * 0.5))
            local label_w = math.max(Screen:scaleBySize(80), w - bar_w - Screen:scaleBySize(8))
            return HorizontalGroup:new{
                ProgressWidget:new{
                    width = bar_w,
                    height = Screen:scaleBySize(24),
                    margin_v = Screen:scaleBySize(7),
                    margin_h = Screen:scaleBySize(2),
                    percentage = pct,
                },
                HorizontalSpan:new{ width = Screen:scaleBySize(8) },
                TextBoxWidget:new{
                    text = T(_("%1% · %2/%3 话"),
                        math.floor(pct * 100 + 0.5),
                        comic.download_done or 0,
                        comic.download_total or 0),
                    face = Theme.face("info"),
                    width = label_w,
                    height = Screen:scaleBySize(24),
                    height_overflow_show_ellipsis = true,
                },
            }
        end
        return TextBoxWidget:new{
            text = third_line,
            face = Theme.face("info"),
            width = w,
            height = Screen:scaleBySize(24),
            height_overflow_show_ellipsis = true,
        }
    end

    --- 文字列 (标题 / 第二行 / 统计行)
    -- 高度与宽度**无关** (每行都声明了固定高度, 超出部分省略号), 所以量一次即可。
    local function makeTextColumn(w)
        local button_w = resumable and math.min(math.floor(w * 0.48), Screen:scaleBySize(112)) or 0
        local title_widget = TextBoxWidget:new{
            text = title,
            face = Theme.face("list_title"),
            bold = true,
            width = w - (resumable and button_w + Screen:scaleBySize(4) or 0),
            height = Screen:scaleBySize(48),
            height_overflow_show_ellipsis = true,
        }
        local title_row = title_widget
        if resumable then
            self.resume_button = Button:new{
                text = _("继续阅读"), width = button_w,
                height = Screen:scaleBySize(32), padding = 0,
                text_font_size = 18,
                callback = function() self:onContinueReading() end,
                hold_callback = function() end, -- 不把按钮长按传给历史条目的删除操作。
            }
            title_row = HorizontalGroup:new{
                align = "top", title_widget,
                HorizontalSpan:new{width = Screen:scaleBySize(4)}, self.resume_button,
            }
        end
        return VerticalGroup:new{
            align = "left",
            title_row,
            VerticalSpan:new{ width = Screen:scaleBySize(2) },
            TextBoxWidget:new{
                text = second_line,
                face = Theme.face("info"),
                width = w,
                height = Screen:scaleBySize(30),
                height_overflow_show_ellipsis = true,
            },
            makeThird(w),
        }
    end

    -- 封面撑满整行: 行高由文字块决定 (标题+作者行+统计行), 封面按原比例放大到
    -- 与文字块等高 —— 否则右边文字排满、左边封面上下各空一截, 看着就是
    -- "封面没占满一行的高度"。
    --
    -- 文字块高度只能实测 (TextBoxWidget 会按字体行高把声明值抬高), 所以:
    --   * 列表已经量过 (measureItemHeight 的探针) -> self.text_h, 其余条目直接用;
    --   * 没有 text_h (探针/测试里单建一张) -> 先建一遍量一次, 再按最终宽度重建。
    local text_h = self.text_h
    if not text_h then
        text_h = makeTextColumn(text_w):getSize().h
    end
    self.text_h = text_h

    -- 只放大、不缩小: 用户调大字号时封面跟着变高
    if text_h > self.cover_h then
        local ratio = self.cover_w / self.cover_h
        self.cover_h = text_h
        self.cover_w = math.max(1, math.floor(text_h * ratio + 0.5))
        text_w = self.width - self.cover_w - gap - padding * 2
    end

    self.content = FrameContainer:new{
        padding = padding,
        margin = 0,
        bordersize = 0,
        background = self.background,
        width = self.width,
        height = self.height,
        HorizontalGroup:new{
            self:coverWidget(),
            HorizontalSpan:new{ width = gap },
            makeTextColumn(text_w),
        },
    }
    self[1] = self.content
end

function ComicListItem:select(continue_reading)
    if self.list_ui and self.list_ui._closed then return true end
    if continue_reading and not self:readingHistory() then
        self:buildContent(); self:refreshRow()
        return true
    end
    -- The list remains below the detail page. Stop speculative metadata work
    -- before navigating so it cannot rebuild a hidden list or compete for RAM.
    if self.list_ui and self.list_ui.fetch_task then self.list_ui.fetch_task:cancel() end
    if self.on_select then
        self.on_select(self.comic, {
            continue_reading = continue_reading == true,
            origin_list = self.list_ui,
            source_id = self:itemSourceId(),
            source = self.source and self.source.identifier == self:itemSourceId() and self.source or nil,
        })
    end
    return true
end

function ComicListItem:onTapSelect()
    return self:select(false)
end

function ComicListItem:onContinueReading()
    return self:select(true)
end

function ComicListItem:onHoldSelect()
    if self.on_hold then
        self.on_hold(self.comic)
    end
    return true
end

--- 确保本行封面已缓存
-- @param delay   延迟秒数 (0 表示立刻)
-- @param on_done function(path或nil) 无论成功失败都会回调, 用于串行队列推进
function ComicListItem:loadCover(delay, on_done)
    local comic = self.comic or {}
    local own_source = not comic.source_id or comic.source_id == self.source_id
    if self.cover_loaded then
        if on_done then on_done(CoverCache.find(self:itemSourceId(), comic._id)) end
        return
    end
    if self.cover_loading then
        -- 已在下载中: 不重复发起, 但要让队列能继续推进
        if on_done then on_done(nil) end
        return
    end
    if not comic.thumb or comic.thumb == "" or not comic._id then
        if on_done then on_done(nil) end
        return
    end

    local existing = CoverCache.find(self:itemSourceId(), comic._id)
    if existing then
        self.cover_loaded = true
        if on_done then on_done(existing) end
        return
    end

    if not own_source then
        -- 跨源条目: 只能用已缓存的封面, 不能拿当前源的请求头去下别的源的图
        if on_done then on_done(nil) end
        return
    end

    self.cover_loading = true
    local function start()
        CoverCache.ensure(self.source, self.source_id, comic, function(path)
            self.cover_loading = false
            -- 页面已关闭: 不必再重建控件 (省下这份无用功), 但 on_done 仍要回调
            if (path or self.list_ui and self.list_ui.resolve_cover)
                    and not (self.list_ui and self.list_ui._closed) then
                self.cover_loaded = path ~= nil
                self.cover_error = not path and _("加载失败") or nil
                -- 重建/刷新抛异常不能让 on_done 丢掉: on_done 是推进封面队列的唯一
                -- 动力 (pumpCoverQueue 的 next_one 负责复位 cover_busy 并排下一拍)。
                -- CoverCache 对回调有 pcall, 异常不会闪退, 但 on_done 没被调用的话,
                -- 这一屏剩下的封面**永远**加载不出来, 且没有任何报错。
                local ok_build, err_build = pcall(function()
                    self:buildContent()
                    self:refreshRow()
                end)
                if not ok_build then
                    logger.warn("Picayomi VisualComicList: 封面就位后重建行失败: "
                        .. tostring(err_build))
                end
            end
            if on_done then on_done(path) end
        end)
    end

    if delay and delay > 0 then
        UIManager:scheduleIn(delay, start)
    else
        start()
    end
end

--- 补上封面后只刷新**这一行**
--
-- 原来这里对整屏 setDirty。补封面是一屏多条逐个到的 (一屏 4 条就是 4 次), 每次
-- 整屏刷新在 e-ink 上都是一次可见的闪动 —— 累积起来就是"滚动列表一直在闪",
-- 这是列表页最主要的观感成本 (CPU 反而不是瓶颈: 实测补满一屏封面 CPU 只占 ~33ms)。
-- 行的 dimen 是 paintTo 落位后的**屏幕绝对坐标**, 直接当刷新区域即可。
--
-- 退回整屏的两种情况: 行还没落位 (dimen 为空/零尺寸), 或已滚出屏幕 (坐标越界)。
-- 宁可多刷一块, 也不能漏刷 —— 漏刷会让封面永远不显示。
function ComicListItem:refreshRow()
    local list_ui = self.list_ui
    if not list_ui then return end
    -- 页面已关闭: 别再对死控件 setDirty (会刷到当前画面上去)
    if list_ui._closed then return end

    local d = self.dimen
    -- 还没落位 / 已滚出屏幕: 不刷新。
    --
    -- 旧实现在这两种情况下退回整屏刷新。对"还没落位"是必要的, 但列表为了
    -- 虚拟化会把**屏幕外**的条目也建出来 (它们的 dimen 落在屏幕外), 于是
    -- 一次进度刷新会连带整屏重绘 —— 电子墨水屏上就是持续闪动。
    -- 屏幕外的行下次真正画到时会用重建后的内容, 不需要现在刷。
    if not (d and d.w and d.h and d.w > 0 and d.h > 0) then return end
    if d.x < 0 or d.y < 0
        or d.x + d.w > Screen:getWidth()
        or d.y + d.h > Screen:getHeight() then
        return
    end

    UIManager:setDirty(list_ui, function() return "ui", d end)
end

-- 单层分页模型:
--   用户看到的一"屏"就是一次翻页单位, 不再区分"屏内翻"和"翻数据页"。
--   已取回的数据留在 buffer 里, 翻到缓冲区末尾时再向服务器补一页,
--   并在快到底时后台预取 —— 所以"上页"永远是瞬时的, 不会重新发请求。
local VisualComicList = InputContainer:extend{
    -- 标记为"插件顶层页面": 退出 Picayomi 时由 util/widget_sweep 统一清扫
    -- (见 widget_sweep 的注释)。标在类上, 所有实例都继承。
    is_picayomi_page = true,
    title = nil,
    -- 首批数据 (已由调用方标准化过的条目)
    comics = nil,
    source = nil,
    source_id = nil,
    -- 首批数据来自服务器的第几页
    server_page = 1,
    -- 服务器给出的总页数 (可选; 很多源不返回, 那就不知道总量)
    total_pages = nil,
    -- 服务器是否还有更多数据; 不传则由 server_page/total_pages 推导
    has_more = nil,
    -- function(page) -> ok, data, err  用于补货
    fetch_page = nil,
    -- function(raw_comic) -> comic    补货时标准化 (可选)
    processor = nil,
    -- 取数返回里"条目数组"的字段名。
    -- 默认 "comics"; 子类可改 (评论页用 "comments" / 回复页用 "replies") ——
    -- 这样分页核心 (loadServerPage / fetchMore) 不用为每种列表各写一份。
    items_key = "comics",
    on_select = nil,
    -- 选择/删除等操作列表可关闭续读; 普通漫画列表统一启用。
    allow_continue = true,
    comic_model = ComicModel,
    -- function(comic) 长按某一条 (可选)。不传则条目没有长按手势。
    on_hold = nil,
    on_back = nil,
    -- 额外的页脚按钮: { text = ..., callback = function(list) end }
    extra_buttons = nil,
    -- 可用的排序方式: { { value = <接口取值>, text = <界面文案> }, ... }
    -- 由各源声明 (source:getSortOptions(list_kind)); 空表则不显示"排序"按钮
    sort_options = nil,
    -- 当前排序取值 (仅用于在菜单里打勾)
    sort = nil,
    -- function(value, text) 选中某个排序后回调; 由调用方重新拉取列表
    -- (列表自己不知道取数细节, 所以不在这里改数据)
    on_sort_change = nil,
    width = nil,
    height = nil,
}

function VisualComicList:init()
    self.width = self.width or Screen:getWidth()
    self.height = self.height or Screen:getHeight()
    -- 全屏控件: 告诉 UIManager:_repaint 不必再绘制下层控件
    -- (KOReader 的 InputDialog 也用这个标记)
    self.covers_fullscreen = true
    if not self.source then
        local ok, SourceRegistry = pcall(require, "source.registry")
        if ok and SourceRegistry then
            self.source = SourceRegistry:getCurrent()
        end
    end
    self.source_id = self.source_id or (self.source and self.source.identifier) or "unknown"
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.items = {}

    -- 滑动: 左滑 = 下一屏, 右滑 = 上一屏; 已在第一屏时右滑 = 返回 (见 onSwipe)。
    -- 做法与 KOReader 自己的 SortWidget / ImageViewer 一致 (ges_events + onSwipe),
    -- 不要自己去接原始的 touch 事件 —— 那样拿不到"方向 + 距离"的判定。
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

    -- 单层分页状态
    self.buffer = self.comics or {}          -- 已取回的全部条目
    -- 缓冲区最新一笔来自服务器的哪一页。**统一成数字**: 源可能给字符串,
    -- 而它到处参与比大小 (见 fetchMore 里的注释)。
    self.server_page = tonumber(self.server_page) or 1
    self.server_page_start = self.server_page_start or self.server_page
    -- 服务端一页给多少条: 用于把"服务端总页数"折算成"总屏数", 也用于跳转定位
    self.server_page_size = self.server_page_size or #self.buffer
    -- 服务端给的总条数 (用于推算总屏数; 不可信时下面会丢弃)
    self.total_count = self.total_count or self.total
    -- 缓冲区第一条在整个列表里的绝对序号 (1-based)。
    -- 有了它才能给出"绝对第几屏": 缓冲区不一定从第 1 条开始
    -- (跳到远处时会把缓冲区换成目标所在的服务端页)。
    self.buffer_first_item = self.buffer_first_item or 1
    if self.has_more == nil then
        -- 服务器没给总页数时保守认为还有更多 (翻到底会自然停下)
        local total = tonumber(self.total_pages)
        local server_page = tonumber(self.server_page) or 1
        self.has_more = not (total and total > 0 and server_page >= total)
    end

    -- 行高由实际内容决定 (不能写死常量, 见 ComicListItem:init 的注释)
    self.item_h = self:measureItemHeight()
    local item_h = self.item_h

    -- 当前所在屏 (1-based)。ListView 内部只放"当前屏"的条目,
    -- 具体见 renderWindow 的注释。
    self.screen_index = 1

    self.page_text = TextWidget:new{
        text = "",
        face = Theme.face("info"),
    }

    -- 注意: FrameContainer:getSize() 忽略 self.height, 按内容实际高度计算,
    -- 因此列表高度必须用 header/footer 的**真实**尺寸来算, 否则页脚会被挤出屏幕。
    local header = self:createHeader()
    local footer = self:createFooter()
    local list_h = self.height - header:getSize().h - footer:getSize().h
    if list_h < item_h then list_h = item_h end

    -- 与 ListView 内部算法保持一致 (floor(height / item_height))
    self.per_screen = math.max(1, math.floor(list_h / item_h))
    self:buildWindow()

    self.list_view = ListView:new{
        padding = 0,
        items = self.items,
        width = self.width,
        height = list_h,
        item_height = item_h,
        page_update_cb = function()
            self:updatePageText()
        end,
    }
    -- **必须关掉内层 ListView 自己的 swipe 处理。**
    --
    -- ListView 是 InputContainer, init 里给自己注册了 ges_events.Swipe 和 onSwipe
    -- (frontend/ui/widget/listview.lua:64/116), 而 WidgetContainer:propagateEvent 是
    -- **先派发给子控件**的 —— 事件到不了本控件的 onSwipe。
    -- 更糟的是它并不会"看起来动了": 我们每次只把**当前一屏**交给它 (buildWindow),
    -- 所以它内部 pages 恒为 1, nextPage() 什么都不做 —— 表现就是"左滑右滑完全没反应"。
    -- 它的翻页职责在本控件里, 内层那份是死代码, 留着只会吞事件。
    --
    -- 两处都要关, 少一处都还是会吞:
    --   1) ges_events.Swipe  —— 否则它自己的 onGesture 就把原始 Gesture 吃了;
    --   2) onSwipe 方法      —— 本控件匹配到手势后会合成一个 `Swipe` **命名事件**
    --      往下发, 子控件先收到, 它的 onSwipe 照样返回 true。
    --      注意不能置 nil: 实例上没有该字段时会从类上回退, 必须给一个返回 nil 的
    --      空实现 (返回 nil = 没处理, 事件继续派发给本控件)。
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
            footer,
        },
    }

    -- 按钮的初始可用状态必须按"缓冲区里是否还有屏可翻"重算一次。
    -- 只用 has_more 判定是错的: 接口常自称只有 1 页 (has_more=false),
    -- 但一次返回的几十条本身就能翻好几屏。
    self:updatePageButtons()
    self:updatePageText()

    -- 兜底消费 tap: 页脚按钮之间/四周有内边距, 列表底部也可能留半屏空白 ——
    -- 这些点若没人消费, 事件会继续往下层窗口传, 可能触发与本页无关的动作。
    -- 详见 tap_guard 的注释。
    TapGuard.install(self, self.dimen)

    if Input and Input.group then
        self.key_events = {
            Close = { { "Back" } },
            PageForward = { { Input.group.PgFwd } },
            PageBackward = { { Input.group.PgBack } },
        }
    end

    UIManager:nextTick(function()
        self:scheduleVisibleCovers()
    end)
end

--- 量出一张卡片的实际高度 (行高真值)
--
-- 卡片高度由字体行高 + TextBoxWidget 的"抬高/留白"行为共同决定, 只有真的建一张
-- 量一遍才准。好在它与文本内容**无关** (TextBoxWidget 的声明 height 已封顶行数),
-- 所以量一张即可代表全部 —— 已用超长标题验证过 (见 test/functional_tap_geometry.lua)。
--- 只重绘当前屏已存在的行 (进度条刷新用)
--
-- 不能走 renderWindow: 它会 free 掉整屏控件再重建, 在电子墨水屏上就是一次
-- 整屏闪动。这里只重建每一行的内容, 再按行刷新; 行高不变 (进度行与文本行同高,
-- 见 buildContent), 所以 ListView 的布局不被打乱。
function VisualComicList:refreshVisible(changed_ids)
    for _i, item in ipairs(self.items or {}) do
        local changed = not changed_ids
            or (item.comic and changed_ids[item.comic._id])
        if changed and type(item.buildContent) == "function" then
            item:buildContent()
            -- 只刷新已经落位过的行。未落位的行 (还没 paintTo) 没有可信的
            -- dimen, refreshRow 会退化成整屏刷新 —— 它们下次整屏绘制时
            -- 自然会用到刚重建的内容。
            local d = item.dimen
            if type(item.refreshRow) == "function" and d and d.w and d.h
                and d.w > 0 and d.h > 0 then
                item:refreshRow()
            end
        end
    end
    self:updatePageText()
end

function VisualComicList:measureItemHeight()
    local probe = ComicListItem:new{
        width = self.width,
        comic = {
            _id = "picayomi_probe", title = "测", author_text = "测",
            categories_text = "测", pagesCount = 1, epsCount = 1, finished = true,
        },
        background = Blitbuffer.COLOR_WHITE,
    }
    -- 探针顺带量出了文字块高度 (封面就是按它放大的)。记下来给其余条目用,
    -- 免得每一行都"建两遍文字列"去量 —— 一屏 6 行就是 6 次多余的文字排版。
    self.text_h = probe.text_h
    return probe.height
end

--- 兜底消费 tap (见 init 里的说明)
function VisualComicList:onTapConsume()
    return true
end

--- 造一条列表项
function VisualComicList:makeItem(comic, index)
    local bg = (index % 2 == 0) and Blitbuffer.COLOR_GRAY_E or Blitbuffer.COLOR_WHITE
    return ComicListItem:new{
        width = self.width,
        height = self.item_h or Screen:scaleBySize(126),
        -- 列表量过的文字块高度: 条目据此把封面放大到与文字块等高 (见 buildContent)
        text_h = self.text_h,
        comic = comic,
        source = self.source,
        source_id = self.source_id,
        on_select = self.on_select,
        on_hold = self.on_hold,
        list_ui = self,
        index = index,
        background = bg,
    }
end

--- 当前屏能显示的条目数
function VisualComicList:perScreen()
    return self.per_screen
        or (self.list_view and self.list_view.items_per_page)
        or 1
end

--- 已加载数据总共能撑多少屏 (仅缓冲区内部)
function VisualComicList:loadedScreens()
    local total = #self.buffer
    if total <= 0 then return 1 end
    return math.ceil(total / self:perScreen())
end

--- 缓冲区第一屏在整个列表里的**绝对**屏号 (1-based)
function VisualComicList:firstLoadedScreen()
    local first_item = self.buffer_first_item or 1
    return math.floor((first_item - 1) / self:perScreen()) + 1
end

--- 缓冲区最后一屏的绝对屏号
function VisualComicList:lastLoadedScreen()
    return self:firstLoadedScreen() + self:loadedScreens() - 1
end

--- 当前屏的绝对屏号 (界面与按钮都用它)
function VisualComicList:absScreen()
    return self:firstLoadedScreen() + (self.screen_index or 1) - 1
end

--- 重建"当前屏"的条目并交给 ListView
-- 关键: 不能把同一批控件反复塞回 ListView。
-- ListView:_populateItems() 每次都会 main_content:clear(), 而
-- WidgetContainer:clear() 会 free() 掉子控件 (TextWidget:free 释放 _xtext,
-- 但 _xshaping 仍指向已释放对象) —— 复用它们会导致文字再也画不出来。
-- 因此这里只构建当前屏所需的那几条, 被 free 掉的那批直接丢弃。
function VisualComicList:buildWindow()
    local per = self:perScreen()
    local start_idx = (self.screen_index - 1) * per + 1
    self.items = {}
    for i = start_idx, math.min(start_idx + per - 1, #self.buffer) do
        table.insert(self.items, self:makeItem(self.buffer[i], i))
    end
    return self.items
end

--- 把当前屏交给 ListView 并重绘
-- @param allow_prefetch  为 false 时不触发后台预取 (避免"补货完又预取"的连锁)
function VisualComicList:renderWindow(allow_prefetch)
    local lv = self.list_view
    if not lv then return end
    self:buildWindow()
    lv.items = self.items
    lv.show_page = 1
    lv:_populateItems()      -- 内部会 free 掉上一屏的控件 (那批已不再使用)
    self:updatePageText()
    self:updatePageButtons()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    UIManager:nextTick(function() self:scheduleVisibleCovers() end)
    if allow_prefetch ~= false then
        self:maybePrefetch()
    end
end

--- 当前屏还能再放几条 (缓冲区末尾那一屏常常是半屏)
function VisualComicList:windowCapacity()
    local per = self:perScreen()
    local start_idx = (self.screen_index - 1) * per + 1
    return math.max(0, math.min(per, #self.buffer - start_idx + 1))
end

--- 刷新上下页按钮的可用状态
-- 用**绝对屏号**判断: 缓冲区可能不从第 1 屏开始 (跳到远处后会换成目标那一页)
function VisualComicList:updatePageButtons()
    local can_prev = self:absScreen() > 1
    local can_next = self:absScreen() < self:lastLoadedScreen()
        or self.has_more == true
    if self.prev_button then self.prev_button:enableDisable(can_prev) end
    if self.next_button then self.next_button:enableDisable(can_next) end
    if self.jump_button then self.jump_button:enableDisable(self:totalScreens()~=1) end
end

--- 下一屏 (到底时自动向服务器补货)
function VisualComicList:nextScreen()
    if not self.list_view then return true end

    if (self.screen_index or 1) < self:loadedScreens() then
        self.screen_index = self.screen_index + 1
        self:renderWindow()
        return true
    end

    -- 已在缓冲区末尾: 拉下一页数据, 成功后再翻
    if self.has_more == false or not self.fetch_page then
        return true
    end
    if self.fetching_more then
        -- Coalesce taps while speculative fetching is in flight. The response
        -- must honor the user's request to advance, not silently eat the tap.
        self.advance_after_fetch = true
        return true
    end
    self.advance_after_fetch = true
    self:fetchMore(false)
    return true
end

--- 上一屏
-- 缓冲区里能翻就本地翻 (瞬时); 到了缓冲区开头而前面还有数据时,
-- 才去拉"上一个服务端页"并把缓冲区换成它。
function VisualComicList:prevScreen()
    -- A later navigation action supersedes a pending next-page tap.
    self.advance_after_fetch = nil
    if (self.screen_index or 1) > 1 then
        self.screen_index = self.screen_index - 1
        self:renderWindow()
        return true
    end

    local page = (self.server_page_start or 1) - 1
    if page < 1 or not self.fetch_page then return true end

    if self.fetch_task then self.fetch_task:cancel() end
    self:loadServerPage(page, function(ok)
        if not ok then return end
        -- 落在新缓冲区的最后一屏 (即"往回一页")
        self.screen_index = self:loadedScreens()
        self:renderWindow()
    end, self:absScreen() - 1)          -- 提示里显示"用户看到的页码"
    return true
end

--- 直接拉取某个"服务端数据页"并**替换**缓冲区
--
-- 为什么需要它: 逐页往后补货是 O(N) 次阻塞请求。跳到很远的一屏(或从缓冲区
-- 开头往回翻)时, 只要直接定位到目标所在的服务端页、拉回来替换缓冲区即可,
-- 一次请求就够了 —— 这样"跳页"才真正跳得动, 也不需要人为设一个"最多跳 N 屏"。
--
-- @param page     服务端页码 (1-based)
-- @param notify   function(ok) 拉取并落位后回调
-- @param display_page  用户在界面上看到的页码 (仅用于提示文案)
--   注意别把"服务端第几页"写进提示 —— 那是内部概念, 与界面上的"第 N 页"不是一个数
--   (跳第 480 页时服务端可能只需要取它的第 96 页, 提示写 96 会让人看不懂)。
function VisualComicList:loadServerPage(page, notify, display_page)
    if not require("ui.common.source_access").check(self.source,self.access_feature,notify==false) then return end
    -- 页面已关闭就别开始了: 连"加载中"提示都不该闪一下 (见下面的 _closed 守卫)
    if not self.fetch_page or self.loading_more or self._closed then
        if notify then notify(false) end
        return
    end

    self.loading_more = true
    -- LoadingTask 保证"提示一定被关掉"(抛异常时也关), 并负责延迟一拍 ——
    -- 这些是**延迟**任务, 页面关掉之后照样会被调度执行, 所以还要 is_cancelled
    -- 拦一道: 不拦就是"离开列表页之后还在发请求" (同 fetchMore 里的同名守卫)。
    -- loading_more 必须无条件复位: 不复位就再也补不了货 —— 交给 set_busy。
    self.fetch_task = LoadingTask.run{
        async = true,
        message = display_page and T(_("正在加载第 %1 页…（点击取消）"), display_page)
            or _("正在加载…（点击取消）"),
        delay = 0.05,
        is_cancelled = function() return self._closed end,
        set_busy = function(v) self.loading_more = v end,
        fetch = function() return self.fetch_page(page) end,
        on_done = function(ok, data, err)
            -- 取数期间页面被关了: 别再动控件 (重建窗口 / setDirty 都会作用到死控件上,
            -- 还会给当前画面发多余刷新)。
            if self._closed then
                if notify then notify(false) end
                return
            end

            if not ok or type(data) ~= "table" then
                logger.warn("Picayomi List: 取第 " .. tostring(page) .. " 页失败: "
                    .. tostring(err or ok))
                UIManager:show(InfoMessage:new{
                    text = T(_("加载第 %1 页失败：%2"), page, require("ui.common.error_message").describe(err)),
                    timeout = 3,
                }, "ui")
                if notify then notify(false) end
                return
            end

            local comics = {}
            for _i, raw in ipairs(data[self.items_key or "comics"] or {}) do
                local c = self.processor and self.processor(raw) or raw
                if c then table.insert(comics, c) end
            end

            if #comics == 0 then
                -- 服务端没有这一页了: 到底了
                self.server_page=tonumber(data.page) or page
                self.has_more=data.has_more==true
                self.prefetch_blocked=self.has_more
                UIManager:show(InfoMessage:new{ text = self.has_more and _("本批暂无内容，可继续翻页") or _("没有更多内容了"), timeout = 2 }, "ui")
                self:updatePageText()
                self:updatePageButtons()
                if notify then notify(false) end
                return
            end

            self.buffer = comics
            self.server_page_start = page
            self.server_page = tonumber(data.page) or page
            self.server_page_size = tonumber(data.page_size) or #comics
            if tonumber(data.pages) then self.total_pages = tonumber(data.pages) end
            if tonumber(data.total) then self.total_count = tonumber(data.total) end
            self.buffer_first_item = (page - 1) * self.server_page_size + 1
            local total_pages = tonumber(data.pages)
            local server_page = tonumber(self.server_page) or page
            if type(data.has_more)=="boolean" then self.has_more=data.has_more
            else self.has_more=not (total_pages and server_page>=total_pages) end

            if notify then notify(true) end
        end,
    }
end

--- 向服务器补一页, 追加到缓冲区
--
-- 这里**故意不用 LoadingTask.run**, 继续手写 pcall:
--   本函数要区分"抛异常"和"返回失败"两件事 —— 异常时保留 has_more 以便用户
--   再点"下页"重试、并置 prefetch_blocked 停掉自动预取; 而"服务端没有这一页了"
--   才是真正的到底 (has_more=false)。`LoadingTask.call` 会把这两种情况都归一成
--   `ok=false`, 那个区别就没了。同 loading_task.lua 模块注释里点明的例外。
--   另外 silent 预取本来就不弹提示 (loading 为 nil), 也不需要那套时序。
--
-- @param silent   为 true 时是后台预取, 不弹"加载中"
-- @param on_done  function(ok) 追加完成后回调
function VisualComicList:fetchMore(silent, on_done)
    if not require("ui.common.source_access").check(self.source,self.access_feature,silent) then return end
    if self.loading_more then return end
    if self.has_more == false or not self.fetch_page then
        if on_done then on_done(false) end
        return
    end

    self.loading_more = true
    self.fetching_more = true
    local callback = on_done
    on_done = function(ok)
        self.fetching_more = false
        local advance = self.advance_after_fetch
        self.advance_after_fetch = nil
        if callback then callback(ok) end
        if ok and advance and not self._closed then self:nextScreen() end
    end
    local loading
    if not silent then
        loading = InfoMessage:new{ text = _("加载中…（点击取消）") }
        UIManager:show(loading, "ui")
        -- 同步刷一次: show 只是把刷新入队, 而这里马上要阻塞做网络请求,
        -- 不等这一下的话事件循环没机会重绘, 提示等于没显示
        UIManager:forceRePaint()
    end

    local page = (self.server_page or 1) + 1
    self.fetch_task = LoadingTask.background(loading, function()
        -- 页面已关闭: 别再联网 (预取是延迟任务, 关掉页面后它照样会被调度执行)。
        -- 同 onCloseWidget 注释: 否则"离开列表页之后还在补货", 且回调还会去刷新死控件。
        if self._closed then
            if loading then LoadingTask.close(loading) end
            self.loading_more = false
            if on_done then on_done(false) end
            return
        end

        -- 必须 pcall: 抛异常时若走不到 close(loading),
        -- 那个不会自动关闭的加载提示会永久盖住屏幕。
        local pok, ok, data, err = pcall(self.fetch_page, page)
        if loading then LoadingTask.close(loading) end
        self.loading_more = false

        if not pok then
            -- 异常 != 到底: 保留 has_more, 用户再点"下页"可以重试;
            -- 只是不再自动预取, 免得反复失败把界面拖住。
            logger.warn("Picayomi VisualComicList: 补货异常: " .. tostring(ok))
            self.prefetch_blocked = true
            if not silent or self.advance_after_fetch then
                UIManager:show(InfoMessage:new{
                    text = T(_("加载失败: %1"), require("ui.common.error_message").describe(ok)),
                    timeout = 3,
                }, "ui")
            end
            self:updatePageButtons()
            if on_done then on_done(false) end
            return
        end

        -- **"失败" 与 "到底" 是两件事, 必须分开。**
        --
        -- 旧写法把 `not ok` 和"空列表"合并成一个分支: 于是一次网络抖动 / 一次页面
        -- 结构解析失败就把 has_more 永久置 false —— 用户从此再也翻不动, 而且界面上
        -- 没有任何提示, 看起来就是"翻到最后一页就失败了"。
        -- 现在: 失败只提示 + 保留 has_more (手动点"下页"可以重试), 只有**真的取回
        -- 空列表**才算到底。
        if not ok then
            logger.warn("Picayomi VisualComicList: 补货失败: " .. tostring(err))
            -- 不再自动预取 (否则失败会自己循环), 但手动"下页"仍然放行
            self.prefetch_blocked = true
            if not silent or self.advance_after_fetch then
                UIManager:show(InfoMessage:new{
                    text = T(_("加载失败：%1"), require("ui.common.error_message").describe(err)),
                    timeout = 3,
                }, "ui")
            end
            self:updatePageText()
            self:updatePageButtons()
            if on_done then on_done(false) end
            return
        end

        local list = data and data[self.items_key or "comics"]
        if not list or #list == 0 then
            -- 没有更多数据, 不是错误 —— 静默停住 (下页按钮随之置灰)
            if logger.enabled then logger.info("Picayomi VisualComicList: 已到达数据末尾") end
            self.server_page=tonumber(data and data.page) or page
            self.has_more=data and data.has_more==true or false
            self.prefetch_blocked=self.has_more
            self:updatePageText()
            self:updatePageButtons()
            if on_done then on_done(false) end
            return
        end

        -- Process the whole batch before publishing it. A malformed entry must
        -- not leave a partial page that will be duplicated on retry.
        local pending = {}
        for _idx, raw in ipairs(list) do
            local comic = self.processor and self.processor(raw) or raw
            if comic then
                table.insert(pending, comic)
            end
        end
        local appended = #pending
        for _, comic in ipairs(pending) do table.insert(self.buffer, comic) end

        -- **必须 tonumber**: 有的源把 page 当字符串返回 ("2"), 而下面要拿它和
        -- tonumber(pages) 比大小 —— 直接比就是 "attempt to compare number with
        -- string", 而且这段跑在 scheduleIn 的任务里, 未捕获错误会直接把 KOReader
        -- 整个退掉 (真机表现: 点返回后突然闪退, 因为补货任务正好在那一拍跑)。
        self.server_page = tonumber(data.page) or page
        if appended > 0 then self.server_page_size = tonumber(data.page_size) or appended end
        -- 顺带记录服务端给的总条数 (总屏数靠它来推算并自洽校验)
        if tonumber(data.total) then self.total_count = tonumber(data.total) end
        -- 服务器给了总页数时, 到末尾就停
        local total = tonumber(data.pages)
        local server_page = tonumber(self.server_page) or page
        if type(data.has_more)=="boolean" then self.has_more=data.has_more
        elseif total and server_page>=total then self.has_more=false end

        self.prefetch_blocked = false

        -- 补到的是"当前屏还缺的那几条"时, 必须重建窗口, 否则末屏会少显示
        if self:windowCapacity() > #self.items then
            self:renderWindow(false)
        else
            self:updatePageText()
            self:updatePageButtons()
        end

        if on_done then on_done(appended > 0) end
    end, {
        delay = silent and 0.6 or 0.05,
        is_cancelled = function() return self._closed end,
        on_cancel = function()
            self.loading_more = false
            self.fetching_more = false
            self.advance_after_fetch = nil
        end,
        on_error = function(err)
            self.loading_more = false
            self.prefetch_blocked = true
            if self._closed then return end
            if not silent or self.advance_after_fetch then
                UIManager:show(InfoMessage:new{
                    text = T(_("加载失败：%1"), require("ui.common.error_message").describe(err)), timeout = 3,
                }, "ui")
            end
            if on_done then on_done(false) end
        end,
    })
end

--- 快到底时后台预取下一页, 让"下页"不用等网络
function VisualComicList:maybePrefetch()
    if self.has_more ~= true or self.loading_more then return end
    if self.prefetch_blocked then return end
    -- 本地还有可翻的屏, 不必预取
    if (self.screen_index or 1) < self:loadedScreens() then return end

    self:fetchMore(true, function(ok)
        -- 预取失败就等用户手动点"下页"时再试
        if not ok then self.prefetch_blocked = true end
    end)
end

function VisualComicList:createHeader()
    local title = self.title or _("漫画列表")
    return FrameContainer:new{
        padding = Screen:scaleBySize(6),
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        width = self.width,
        VerticalGroup:new{
            align = "left",
            TextBoxWidget:new{
                text = title,
                face = Theme.face("list_title"),
                bold = true,
                width = self.width - Screen:scaleBySize(16),
                height = Screen:scaleBySize(30),
                height_overflow_show_ellipsis = true,
            },
            self.page_text,
        },
    }
end

function VisualComicList:createFooter()
    local button_h = Screen:scaleBySize(40)
    -- 只有一对翻页按钮: 一"页"就是屏幕上的一屏
    local specs = {
        { text = _("上页"), enabled = false, callback = function() self:prevScreen() end },
        { text = _("下页"), enabled = self.has_more ~= false, callback = function() self:nextScreen() end },
        { text = _("跳页"), callback = function() self:showJumpDialog() end },
    }
    -- 只有源声明了可用排序时才显示按钮 (点了没反应的按钮比没有更糟)
    if #(self.sort_options or {}) > 0 then
        table.insert(specs, { text = _("排序"), callback = function() self:showSortMenu() end })
    end
    for _idx, extra in ipairs(self.extra_buttons or {}) do
        table.insert(specs, {
            text = extra.text,
            enabled = extra.enabled,
            callback = function() if extra.callback then extra.callback(self) end end,
        })
    end
    table.insert(specs, { text = _("返回"), callback = function() self:goBack() end })

    -- 长文案留出左右空隙，与详情页共用宽度规则；短按钮分享剩余空间。
    local padding = Screen:scaleBySize(4)
    local inner_w = self.width - (padding + Size.border.thin) * 2
    local widths = require("ui.common.action_style").footerWidths(inner_w,specs,button_h)
    local group = HorizontalGroup:new{}
    for idx, spec in ipairs(specs) do
        local btn = Button:new{
            text = spec.text,
            enabled = spec.enabled ~= false,
            width = widths[idx],
            height = button_h,
            callback = spec.callback,
        }
        -- 记住分页按钮, 换页后需要同步它们的可用状态
        if spec.text == _("上页") then self.prev_button = btn end
        if spec.text == _("下页") then self.next_button = btn end
        if spec.text == _("跳页") then self.jump_button = btn end
        table.insert(group, btn)
    end

    return FrameContainer:new{
        padding = padding,
        margin = 0,
        bordersize = Size.border.thin,
        background = Blitbuffer.COLOR_GRAY_E,
        width = self.width,
        group,
    }
end

--- 服务端给的总条数; 与总页数对不上时视为不可信 (封顶哨兵值)
--
-- 源 B 的分类接口会回 total=10000 这种封顶值, 按它折算会得到"共 20 万屏"这种既没意义
-- 又误导的数字。判据: ceil(总条数 / 每页条数) 必须与总页数对得上。
-- @return 可信的总条数 或 nil
function VisualComicList:credibleTotalItems()
    local items = tonumber(self.total_count)
    if not (items and items > 0) then return nil end

    local pages = tonumber(self.total_pages)
    local page_size = tonumber(self.server_page_size)
    if not (pages and pages > 0 and page_size and page_size > 0) then
        -- 没有页数可比, 无从校验; 有总比没有强
        return items
    end
    if math.abs(math.ceil(items / page_size) - pages) > 1 then return nil end
    return items
end

--- 总屏数
--
-- 数据取完时是准确值; 没取完时用服务端给的"总页数"或"总条数"折算。
--
-- **总页数与总条数分开判断**: 源 C 只给分页器里的最大页码, 不给总条数 ——
-- 旧实现要求三者齐全才肯显示, 于是页脚永远退化成"第 N 页 · 已加载 K 项",
-- 明明能翻到第 40 页却不肯说。现在只要总页数在, 就能给出"第 N/M 页"。
--
-- @return screens(数字 或 nil=未知), exact(是否准确), total_items(可信的总条数 或 nil)
function VisualComicList:totalScreens()
    if self.has_more == false then
        -- 已经到底: 最后一屏的绝对编号就是总数
        return self:lastLoadedScreen(), true, self:credibleTotalItems()
    end
    local items = self:credibleTotalItems()
    if items then
        -- API v3 gives an exact item count without requiring server page counts.
        return math.max(self:lastLoadedScreen(),math.ceil(items/self:perScreen())),false,items
    end
    local pages = tonumber(self.total_pages)
    local page_size = tonumber(self.server_page_size)
    if not (pages and pages > 0 and page_size and page_size > 0) then return nil,false end
    -- 服务器**给了**总条数却与总页数对不上 -> 两个数字至少有一个是封顶的哨兵值
    -- (源 B: pages=9999 + total=10000), 页数也就不可信了, 宁可不显示。
    -- 只在"压根没给总条数"时才单信页数 (源 C: 只有分页器里的最大页码)。
    if tonumber(self.total_count) and not items then
        return nil, false
    end

    local total
    if items then
        total = math.ceil(items / self:perScreen())
    else
        -- 没有可信条数: 按"服务端页数 × 每页条数"折算屏数
        total = math.ceil(pages * page_size / self:perScreen())
    end
    -- 不会小于已经加载到的屏
    return math.max(self:lastLoadedScreen(), total), false, items
end

function VisualComicList:updatePageText()
    if not self.page_text then return end
    local cur = self:absScreen()
    local loaded = #(self.buffer or {})
    local total, _exact, items = self:totalScreens()

    if total and items then
        -- 页数与条数都可信: 都显示, 用户才知道能跳到哪、一共多少
        self.page_text:setText(T(_("第 %1/%2 页 · 共 %3 项"), cur, total, items))
    elseif total then
        -- 只知道总页数 (源 C): 如实说能翻到第几页, 不编总条数
        self.page_text:setText(T(_("第 %1/%2 页"), cur, total))
    else
        -- 服务端没给出可信总量: 只如实说已加载了多少条, 不编总屏数
        self.page_text:setText(T(_("第 %1 页 · 总页数未知 · 已加载 %2 项"), cur, loaded))
    end
end

--- 跳到指定屏 (绝对屏号)
-- 在已加载范围内就直接翻, 不发请求;
-- 超出范围则**直接定位到目标所在的服务端页**并换成缓冲区 —— 一次请求,
-- 所以再远也跳得动, 不需要"最多只能跳 N 屏"这种人为限制。
function VisualComicList:jumpToScreen(n)
    n = tonumber(n)
    if not n or n ~= math.floor(n) or n < 1 then
        return false, _("请输入 1 以上的整数页码")
    end

    local total = self:totalScreens()
    if total and n > total then
        return false, T(_("超出范围：共 %1 页"), total)
    end

    if self.fetch_task then self.fetch_task:cancel() end
    self.advance_after_fetch = nil
    -- 已在缓冲区里: 直接翻
    local first, last = self:firstLoadedScreen(), self:lastLoadedScreen()
    if n >= first and n <= last then
        self.screen_index = n - first + 1
        self:renderWindow()
        return true
    end

    -- 超出缓冲区: 算出目标落在哪个服务端页
    local page_size = tonumber(self.server_page_size)
    if not (page_size and page_size > 0) then
        return false, _("无法定位目标位置（缺少分页信息）")
    end
    local target_item = (n - 1) * self:perScreen() + 1
    local page = math.floor((target_item - 1) / page_size) + 1

    self:loadServerPage(page, function(ok)
        if not ok then return end
        local f = self:firstLoadedScreen()
        self.screen_index = math.max(1, math.min(n - f + 1, self:loadedScreens()))
        self:renderWindow()
    end, n)                              -- 提示里显示"正在加载第 n 页"
    return true
end

--- 弹出排序方式选择
--
-- 只负责"选", 不负责"取": 选完交给 on_sort_change, 由调用方带着新排序重新拉列表。
-- 列表本身不碰取数细节 (不同列表走的是不同接口, 排序参数也可能不同)。
function VisualComicList:showSortMenu()
    local options = self.sort_options or {}
    if #options == 0 then return end

    local item_table = {}
    for _i, opt in ipairs(options) do
        table.insert(item_table, {
            text = opt.text,
            checked = (opt.value == self.sort),
            callback = function()
                -- 必须带刷新模式, 否则关掉菜单不刷新屏幕
                if self.sort_menu then
                    UIManager:close(self.sort_menu, "ui")
                    self.sort_menu = nil
                end
                if opt.value == self.sort then return end
                if self.fetch_task then self.fetch_task:cancel() end
                self.sort = opt.value
                if self.on_sort_change then
                    self.on_sort_change(opt.value, opt.text)
                end
            end,
        })
    end

    -- 「返回」: 去掉右上角 ✕ 之后, 这里必须有一个看得见的退出口
    -- (菜单里只有排序项, 选一项也会关掉菜单; 但用户想"不改了, 退出去"时得有地方点)
    table.insert(item_table, {
        text = _("返回"),
        callback = function()
            if self.sort_menu then
                UIManager:close(self.sort_menu, "ui")
                self.sort_menu = nil
            end
        end,
    })

    local title_bar = MenuStyle.titleBar{ title = _("排序方式") }
    self.sort_menu = Menu:new{
        is_picayomi_page = true, -- 退出 Picayomi 时由 util/widget_sweep 清扫
        title = title_bar.title,
        custom_title_bar = title_bar,
        item_table = item_table,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        full_width = true,
        -- 整屏菜单必须显式声明: Menu 类默认 is_popout=true, 那会画 radius=w/20 的
        -- 大圆角, 四角露出下层界面 (点那里就穿透过去)
        is_popout = false,
        covers_fullscreen = true,
        -- 返回键关掉这一页: 清掉引用 (选中排序项时由条目自己关, 不走这里)
        close_callback = function()
            self.sort_menu = nil
        end,
    }
    MenuStyle.disableSelectAutoClose(self.sort_menu)
    TapGuard.install(self.sort_menu)
    -- 左右滑动: 与其它全屏菜单一致。排序页只有一屏, 所以左滑只消费事件,
    -- 右滑 = 关掉菜单回到列表 (与「返回」项同一个动作)。
    MenuSwipe.attach(self.sort_menu, function()
        if self.sort_menu then
            UIManager:close(self.sort_menu, "ui")
            self.sort_menu = nil
        end
    end)
    UIManager:show(self.sort_menu, "ui")
end

--- 弹出输入框让用户填写要跳转的屏号
-- 弹窗本体在 ui/common/page_jump.lua (与详情页共用); 这里只负责"说明文案 + 跳转"。
function VisualComicList:showJumpDialog()
    local cur = self:absScreen()
    local total = self:totalScreens()
    local tip
    if total then
        -- 有可信总量: 明确给出起止点
        tip = T(_("共 %1 页，请输入要跳转的页码"), total)
    else
        -- 服务端没给可信总量: 说明只能给到已加载范围, 但更大的屏号照样能跳
        tip = T(_("已加载至第 %1 页；更大的页码会自动加载"),
            self:lastLoadedScreen())
    end

    return PageJump.show{
        description = tip,
        current = cur,
        -- jumpToScreen 自己会校验并给出 (false, err) —— 非法页号/超出范围
        -- 都在那里变成一条可见提示, 这里不重复判断。
        on_jump = function(n) return self:jumpToScreen(n) end,
    }
end

--- 当前屏优先，最多两项在途，避免一张慢封面阻塞整屏。
-- 图片仍共用一个异步 worker；不一次性提交整页预取。
function VisualComicList:scheduleVisibleCovers()
    -- 页面已关闭: 别再排新的下载 (见 onCloseWidget 注释)
    if self._closed then return end

    self._cover_generation = (self._cover_generation or 0) + 1
    for _, task in pairs(self._cover_metadata_tasks or {}) do task:cancel() end
    self._cover_metadata_tasks = {}
    self.cover_queue = {}
    self._cover_active = 0
    self.cover_busy = false

    local per = self:perScreen()
    local first = (self.screen_index - 1) * per + 1
    -- 当前屏 + 向前看一屏 (预取), 让"下页"时封面已经就位
    local last = math.min(first + per * (1 + COVER_LOOKAHEAD) - 1, #self.buffer)

    for idx = first, last do
        local item = self.items[idx - first + 1]
        if not item then
            -- 属于下一屏: 按数据临时造一个条目只为拿封面? 不行, 会多一份控件。
            -- 改为按 comic 直接走 CoverCache, 不建控件。
            local comic = self.buffer[idx]
            if comic and comic.thumb and comic.thumb ~= "" then
                table.insert(self.cover_queue, { comic = comic })
            end
        else
            table.insert(self.cover_queue, { item = item })
        end
    end

    self:pumpCoverQueue()
end

--- 队列最多两项在途；完成后再派发下一项，关闭后不继续补货。
function VisualComicList:pumpCoverQueue()
    if self._closed or self.cover_busy then return end
    self.cover_busy = true
    self._cover_active = self._cover_active or 0
    self._cover_metadata_tasks = self._cover_metadata_tasks or {}
    while not self._closed and self._cover_active < 2 do
        local entry = table.remove(self.cover_queue or {}, 1)
        if not entry then break end
        self._cover_active = self._cover_active + 1
        local ok, err = pcall(self.dispatchCover, self, entry, self._cover_generation)
        if not ok then
            self._cover_active = math.max(0, self._cover_active - 1)
            logger.warn("Picayomi VisualComicList: 封面任务启动失败: " .. tostring(err))
        end
    end
    self.cover_busy = false
end

function VisualComicList:dispatchCover(entry, generation)
    local function stale() return self._closed or self._cover_generation ~= generation end
    -- 只复位一次: 下面既有"正常回调推进", 也有"派发时抛异常的兜底推进",
    -- 回调已经跑过 next_one 之后才抛的话, 兜底不能再推第二次 (会排出两条并行链)。
    local advanced = false
    local function next_one()
        if advanced or stale() then return end
        advanced = true
        self._cover_active = math.max(0, self._cover_active - 1)
        self._cover_metadata_tasks[entry] = nil
        -- 留一小段空闲, 让点击/翻页能被处理
        UIManager:scheduleIn(0.05, function() self:pumpCoverQueue() end)
    end

    -- 派发取封面: 里面会建下载通道 (fork 子进程 / 取请求头), 内存见底时 fork 会抛。
    -- 这是延迟任务, KOReader 的任务队列不兜异常 —— 逃出去就是整个进程退出; 而且
    -- cover_busy 已置 true, 抛出时若走不到 next_one, 这一屏的封面会永久停摆。
    -- 所以整个派发包进 pcall, 出错就当这一张失败, 继续下一张。
    local function dispatch()
        if stale() then return end
        local ok_dispatch, err_dispatch = pcall(function()
            if entry.item then
                -- 当前屏: 下完要重建该行内容
                entry.item:loadCover(0, function(path)
                    -- 该行可能已随窗口翻页被换掉, 但 loadCover 内部有 cover_loaded 守卫, 安全
                    next_one()
                end)
            else
                -- 下一屏: 只预热磁盘缓存, 不碰控件
                local comic = entry.comic
                local existing = CoverCache.find(self.source_id, comic._id)
                if existing then
                    next_one()
                else
                    CoverCache.ensure(self.source, self.source_id, comic, function()
                        next_one()
                    end)
                end
            end
        end)
        if not ok_dispatch then
            logger.warn("Picayomi VisualComicList: 取封面派发失败 (已跳过这一张): "
                .. tostring(err_dispatch))
            -- loadCover 在抛异常前可能已把 cover_loading 置 true, 不复位的话这一行以后都拒绝重试
            if entry.item then entry.item.cover_loading = false end
            next_one()
        end
    end
    local comic = entry.item and entry.item.comic
    if comic and self.resolve_cover and (not comic.thumb or comic.thumb == "")
            and not CoverCache.find(self.source_id, comic._id) then
        local function failed(reason)
            if stale() then return end
            entry.item.cover_error = reason == "missing" and _("无封面") or _("加载失败")
            pcall(function() entry.item:buildContent(); entry.item:refreshRow() end)
            next_one()
        end
        self._cover_metadata_tasks[entry] = LoadingTask.background(nil, function()
            local thumb, reason = self.resolve_cover(comic)
            if stale() then return end
            if type(thumb) == "string" and thumb ~= "" then
                comic.thumb = thumb
                entry.item.cover_error = nil
                dispatch()
            else failed(reason) end
        end, {delay=0.05,timeout=20,is_cancelled=stale,on_error=function() failed() end})
    else
        dispatch()
    end
end

function VisualComicList:onPageForward()
    return self:nextScreen()
end

function VisualComicList:onPageBackward()
    return self:prevScreen()
end

function VisualComicList:goBack()
    if self.on_back then
        self.on_back(self)
    else
        -- 显式刷新模式: mode 为 nil 时 UIManager 会丢弃刷新 (见 ComicDetail:goBack 注释)
        UIManager:close(self, "ui")
    end
    return true
end

function VisualComicList:onClose()
    return self:goBack()
end

--- 滑动: 边缘返回, 中间左右翻屏
--
-- 分区规则见 ui/common/swipe_rules.lua: **从最左/最右 8% 往中间划 = 返回**;
-- 中间区域沿用方向语义 (west = 下一屏 / east = 上一屏), 与 KOReader 的 SortWidget
-- 一致, 用户在别处养成的习惯能直接迁移。
--
-- 边缘必须先判: 左边缘右滑的方向也是 east, 不先拦就会被当成"上一屏"。
--
-- 中间滑到边界就停住 (**不再**"第一屏再右滑 = 返回"): 退出只归边缘滑动,
-- 中间多滑一下就把页面退掉太容易误触。
-- 竖直/斜向滑动一律不处理 (返回 true 表示"已消费", 不让它继续往下层传)。
function VisualComicList:onSwipe(_arg, ges)
    if SwipeRules.isBackSwipe(ges) then
        return self:goBack()
    end
    local direction = ges and ges.direction
    if direction == "west" then
        return self:nextScreen()
    elseif direction == "east" then
        if (self:absScreen() or 1) > 1 then
            return self:prevScreen()
        end
        -- 第一屏再右滑 = 什么都不做: 退出只归边缘滑动 (见 SwipeRules),
        -- 中间滑动到边界就停住, 不会"再滑一下退出去"。
        return true
    end
    return true
end

--- 关闭时停掉后台的封面下载队列。
--
-- 为什么必须有: `scheduleVisibleCovers` 是**延迟**跑的 (`UIManager:nextTick`),
-- 封面下载也是逐张 `scheduleIn` 排下去的 —— 页面关掉之后这些任务照样会执行。
-- 后果有两层:
--   1. **离开列表页后还在下封面**。真机阅读时, 底下的列表页仍在后台抢带宽/内存,
--      正是 OOM 排查里"阅读时列表封面仍在下载"那一条。
--   2. 下载回调还会 `refreshRow()` 对**已关闭**的控件 `setDirty`, 给当前画面
--      (阅读器) 发多余的局部刷新。
-- 实测: 关掉列表后继续泵事件循环, 仍会发生 6 次封面下载。
function VisualComicList:onCloseWidget()
    self._closed = true
    for _, task in pairs(self._cover_metadata_tasks or {}) do task:cancel() end
    self._cover_metadata_tasks = {}
    if self.fetch_task then self.fetch_task:cancel(); self.fetch_task = nil end
    self.cover_queue = {}
    -- 置为 busy 让在途的那条 pump 链就此停住 (pumpCoverQueue 会直接 return)
    self.cover_busy = true
    -- 本页自己弹出的浮层也要收掉: 列表被替换时 (排序 / 换页 / 换分类) 若还压着
    -- 一个排序菜单, 它就成了栈里的孤儿 —— 关掉上层页面时它会突然冒出来。
    if self.sort_menu then
        pcall(function() UIManager:close(self.sort_menu, "ui") end)
        self.sort_menu = nil
    end
end

return VisualComicList
