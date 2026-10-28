-- ui/common/comment_list.lua
-- 评论列表页 (只读): 浏览预览 / 分页 / 跳页 / 长评论本地全文。
--
-- 为什么继承 VisualComicList 而不是另写一个:
--   评论页要"上页/下页/跳页", 而跳页需要"缓冲区 + 绝对屏号 + 跳到远处时换缓冲区"
--   这一整套分页核心 —— 它已经完整存在于 visual_comic_list.lua。复制一份正是本次
--   组件收敛要消灭的东西, 所以这里只覆写"一行长什么样 / 头尾长什么样"。
--   基类通过 items_key 指定评论数组字段。
--
-- 零图片:
--   评论行不显示头像, 也**不排任何下载**。头像要逐行联网, 会重演"关了页面还在后台
--   下载 / 对死控件 setDirty"那一整类问题 (见 F-PERF-008), 而只读浏览下头像没有
--   信息增量。于是 onCloseWidget 只需基类那一句 `_closed = true`。
--
-- 只读:
--   不做发表/回复/点赞 (需要登录态与 Kindle 上难用的键盘输入)。

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui.common.action_style").Button
local Device = require("device")
local FixedBox = require("ui.common.fixed_box")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local Theme = require("ui.common.theme")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VisualComicList = require("ui.common.visual_comic_list")
local CommentTime = require("util.comment_time")
local JN = require("util.json_null")
local _ = require("gettext")
local T = require("ffi/util").template

local Screen = Device.screen

-- 行内各块的高度 (声明值)。FixedBox 保证"实际绘制高度 == 声明高度",
-- 所以这三个常量一改, 行高与命中区同步跟着变, 不会出现"看得见点不着"。
local META_H = Screen:scaleBySize(24)
local CONTENT_H = Screen:scaleBySize(60)   -- 正文约两行
local ROW_PADDING = Screen:scaleBySize(8)

--- 取评论作者名 (缺失/null 时给"匿名")
local function authorOf(comment)
    local author = JN.str(comment and comment.author and comment.author.name)
    if not author or author == "" then
        return _("匿名")
    end
    return author
end

--- 取评论时间。created_at 可能是 ISO 串, 也可能是 epoch 秒。
-- 两种都交给 CommentTime.format; JSON null 会退化成"未知时间"而不是打崩拼接。
local function timeOf(comment)
    if not comment then return CommentTime.format(nil) end
    local raw = JN.num(comment.created_at) or JN.str(comment.created_at)
    return CommentTime.format(raw)
end

--- 一行元信息: 作者 · 时间 · N 赞
local function metaOf(comment)
    local parts = { authorOf(comment), timeOf(comment) }
    local likes = JN.num(comment and comment.likesCount, 0)
    if likes and likes > 0 then
        table.insert(parts, T(_("%1 赞"), likes))
    end
    local replies=JN.num(comment and comment.repliesCount,0)
    if replies>0 then table.insert(parts,T(_("%1 回复"),replies)) end
    return table.concat(parts, " · ")
end

--- 正文 (空评论给个说明, 而不是留一片空白让人以为没加载出来)
local function contentOf(comment)
    local content = JN.str(comment and comment.content)
    if not content or content == "" then
        return _("（无文字内容）")
    end
    return content
end

-- ============================================================================
-- 一行评论: 元信息一行 + 正文两行, 溢出带省略号
-- ============================================================================
local CommentRow = InputContainer:extend{
    width = nil,
    comment = nil,
    on_select = nil,
    background = nil,
}

function CommentRow:init()
    self.width = self.width or Screen:getWidth()
    local comment = self.comment or {}
    local text_w = self.width - ROW_PADDING * 2

    -- 占位行 (加载中/暂无评论/加载失败): 只有一句说明, 不显示元信息。
    -- 它必须与真实评论行**等高** —— ListView 要求所有行等高。
    local is_placeholder = comment._placeholder ~= nil
    local meta_text = is_placeholder and "" or metaOf(comment)
    local body_text = is_placeholder and comment._placeholder or contentOf(comment)

    local group = VerticalGroup:new{ align = "left" }
    if meta_text ~= "" then
        table.insert(group, TextBoxWidget:new{
            text = meta_text,
            face = Theme.face("info"),
            width = text_w,
            height = META_H,
            height_overflow_show_ellipsis = true,
        })
    end
    local body=TextBoxWidget:new{
        text = body_text,
        face = Theme.face("row"),
        width = text_w,
        height = CONTENT_H,
        height_overflow_show_ellipsis = true,
    }
    table.insert(group,body)
    self.truncated=body.line_with_ellipsis~=nil
    if not is_placeholder and not self.truncated and not self.has_replies and comment.content_complete~=false then self.on_select=nil end

    -- 行高固定 = 上下留白 + 元信息 + 正文。内容再长也不改变行高 (FixedBox),
    -- 于是绘制区 / 落位基准 / 命中区三者严格一致。
    self.height = ROW_PADDING * 2 + META_H + CONTENT_H
    self[1] = FrameContainer:new{
        padding = ROW_PADDING,
        margin = 0,
        bordersize = 0,
        background = self.background or Blitbuffer.COLOR_WHITE,
        width = self.width,
        height = self.height,
        FixedBox:new{
            width = text_w,
            height = self.height - ROW_PADDING * 2,
            group,
        },
    }
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }

    -- 占位行也装手势: 让落在这行上的 tap 被它吃掉, 不穿透到下层详情页
    -- (TapGuard 只兜整屏, 行内具体位置还是各行自己认领最稳)。
    if self.on_select and Device:isTouchDevice() then
        self.ges_events.TapSelect = {
            GestureRange:new{
                ges = "tap",
                range = self.dimen,
            }
        }
    end
end

function CommentRow:onTapSelect()
    if self.on_select then
        self.on_select(self.comment)
    end
    return true
end

-- ============================================================================
-- 评论页
-- ============================================================================
local CommentList = VisualComicList:extend{
    is_picayomi_page = true,
    -- 取数返回里条目数组的字段名
    items_key = "comments",
    title = nil,
    -- 评论所属漫画 id
    comic_id = nil,
    -- 加载、空列表、失败三种状态文案
    loading_text = nil,
    empty_text = nil,
    fail_text = nil,
    -- 关闭时回调 (调用方用来清掉自己的引用)
    on_back = nil,
}

--- 首次取数前先放一条占位行
--
-- 为什么不能留空: ListView 用**空** items 构造时会直接早退 (listview.lua:58),
-- 于是 items_per_page 停在 nil, 之后 renderWindow 里 _populateItems 拿它当除数
-- 就会崩。顺带也让页面上先有内容, 而不是一片空白干等网络。
function CommentList:init()
    self.access_feature = "comments"
    if not self.comics then
        self.comics = { { _placeholder = self.loading_text or _("正在加载评论…") } }
    end
    VisualComicList.init(self)

    if not (self.fetch_page and self.comic_id and self.source) then
        return
    end
    UIManager:nextTick(function()
        self:loadFirstPage()
    end)
end

--- 取第一页 (首次进入, 以及失败后重试都走这里)
function CommentList:loadFirstPage()
    if not require("ui.common.source_access").check(self.source,"comments") then return end
    if self._closed then return end
    self:loadServerPage(1, function(ok)
        if self._closed then return end
        if ok then
            self.prefetch_blocked = false
            self.screen_index = 1
        else
            -- 一页真数据都没拿到: 用一条说明行替掉"正在加载"。
            -- 空列表时 loadServerPage 已把 has_more 置 false 并提示过"没有更多内容了"。
            local is_empty = (self.has_more == false)
            -- 置 false 是必须的: 否则"下页"会去取第 2 页, 追加到这条占位行后面。
            -- (置 false 后下页按钮自动禁用, 重试走"点这一行"。)
            self.has_more = false
            self.prefetch_blocked = true
            self.buffer = { {
                _placeholder = is_empty and (self.empty_text or _("暂无评论"))
                    or (self.fail_text or _("评论加载失败, 点这一行重试")),
                -- 只有"失败"可重试; "暂无评论"点它没意义
                -- (注意别写成 `is_empty and nil or "reload"` —— Lua 的 and/or 惯用法
                --  在 and 分支取 nil 时会掉到 or 分支去)
                _action = (not is_empty) and "reload" or nil,
            } }
        end
        self:renderWindow()
    end, 1)
end

--- 失败后重试: 把第一页重新取一遍
function CommentList:reloadFirstPage()
    if self.loading_more then return end
    self.has_more = nil
    self.prefetch_blocked = false
    self.server_page = 1
    self.server_page_start = 1
    self.screen_index = 1
    self.buffer = { { _placeholder = self.loading_text or _("正在加载评论…") } }
    self:renderWindow()
    self:loadFirstPage()
end

--- 评论页零图片: 覆盖基类的封面预取, 什么都不排 (见文件头注释)
function CommentList:scheduleVisibleCovers() end

--- 量出一行的真实高度
--
-- 行内各块高度都是声明值, 与文本内容无关, 所以量一行即可代表全部
-- (同 VisualComicList:measureItemHeight 的做法, 靠 FixedBox 保证内容不改变高度)。
function CommentList:measureItemHeight()
    local probe = CommentRow:new{
        width = self.width,
        comment = { content = string.rep("测", 200) },
        background = Blitbuffer.COLOR_WHITE,
    }
    return probe.height
end

--- 造一行。占位行不可看回复 (失败行可点重试), 但仍吃 tap。
function CommentList:makeItem(comment, index)
    local bg = (index % 2 == 0) and Blitbuffer.COLOR_GRAY_E or Blitbuffer.COLOR_WHITE
    return CommentRow:new{
        width = self.width,
        comment = comment,
        background = bg,
        has_replies=not self.is_reply and self.source and self.source.capabilities
            and self.source.capabilities.replies=="paged" and (tonumber(comment.repliesCount) or 0)>0,
        on_select = function(c)
            if not c then return end
            if c._placeholder ~= nil then
                if c._action == "reload" then
                    self:reloadFirstPage()
                end
                return
            end
            if not self.is_reply and self.source and self.source.capabilities
                and self.source.capabilities.replies=="paged" and (tonumber(c.repliesCount) or 0)>0 then
                self:showCommentActions(c)
            else self:showFullComment(c) end
        end,
    }
end

function CommentList:showCommentActions(comment)
    local dialog
    local function close() UIManager:close(dialog,"ui");self.comment_actions=nil end
    dialog=require("ui.common.action_style").ButtonDialog:new{
        title=_("评论"),is_picayomi_page=true,
        buttons={
            {{text=_("查看全文"),callback=function()close();self:showFullComment(comment) end}},
            {{text=T(_("查看回复（%1）"),comment.repliesCount),callback=function()
                close()
                local parent_id=comment._id or comment.id
                local replies=CommentList:new{
                    title=_("评论回复"),source=self.source,source_id=self.source_id,comic_id=self.comic_id,is_reply=true,items_key="replies",
                    fetch_page=function(page)return self.source:getCommentReplies(self.comic_id,parent_id,page) end,
                }
                UIManager:show(replies,"ui")
            end}},
            {{text=_("取消"),callback=close}},
        },
    }
    self.comment_actions=dialog
    UIManager:show(dialog,"ui")
end

--- 头部: 标题 + 页码
function CommentList:createHeader()
    local inner_w = self.width - Screen:scaleBySize(16)
    local group = VerticalGroup:new{
        align = "left",
        TextBoxWidget:new{
            text = self.title or _("评论"),
            face = Theme.face("list_title"),
            bold = true,
            width = inner_w,
            height = Screen:scaleBySize(30),
            height_overflow_show_ellipsis = true,
        },
    }

    table.insert(group, self.page_text)
    return FrameContainer:new{
        padding = Screen:scaleBySize(6),
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        width = self.width,
        group,
    }
end

--- 页脚: 上页 / 下页 / 跳页 / 返回 (评论页没有排序)
function CommentList:createFooter()
    return require("ui.common.visual_comic_list").createFooter(self)
end

--- 长评论只打开本地全文浮层，不请求回复。
function CommentList:showFullComment(comment)
    if self._closed or self.comment_viewer or not comment or comment._placeholder then return end
    if comment.content_complete==false then
        if self._comment_task then return end
        if not require("ui.common.source_access").check(self.source,"comment_details") then return end
        local generation=self.source.sessionGeneration and self.source:sessionGeneration()
        local function stale()
            return self._closed or generation and self.source:sessionGeneration()~=generation
        end
        -- Lists often contain only a title or a shortened preview. Fetch only
        -- the selected post, never one extra request for every list row.
        self._comment_task=require("ui.common.loading_task").run{
            message=_("正在加载评论全文…"),async=true,delay=.01,
            is_cancelled=stale,
            fetch=function()return self.source:getCommentDetails(self.comic_id,comment._id or comment.id)end,
            set_busy=function(busy)if not busy then self._comment_task=nil end end,
            on_done=function(ok,full,err)
                if stale() then return end
                if not ok then require("ui.common.loading_task").showFailure(err);return end
                if full.content_complete==false then
                    require("ui.common.loading_task").showFailure(_("站点未返回完整评论"));return
                end
                comment.content=full.content;comment.content_complete=true
                self:showFullComment(comment)
            end,
        }
        return
    end
    local viewer
    viewer=require("ui/widget/textviewer"):new{
        title=_("评论全文"),text=contentOf(comment),show_menu=false,
        width=math.floor(self.width*.9),height=math.floor(self.height*.75),
        close_callback=function()
            if self.comment_viewer==viewer then self.comment_viewer=nil end
            UIManager:setDirty(nil,"full")
        end,
    }
    self.comment_viewer=viewer
    UIManager:show(viewer,"ui")
    UIManager:setDirty(nil,"full")
end

function CommentList:closeCommentViewer()
    local viewer=self.comment_viewer
    self.comment_viewer=nil
    if viewer then UIManager:close(viewer,"ui") end
end

function CommentList:onCloseWidget()
    if self._comment_task then self._comment_task:cancel();self._comment_task=nil end
    if self.comment_actions then UIManager:close(self.comment_actions,"ui");self.comment_actions=nil end
    self:closeCommentViewer()
    VisualComicList.onCloseWidget(self)
end

--- 返回: 关掉自己, 再通知调用方
-- 必须显式带 "ui" 刷新模式 —— mode 为 nil 时 UIManager 会丢弃这次刷新
-- (见 ComicDetail:goBack 的注释)。
function CommentList:goBack()
    self:closeCommentViewer()
    UIManager:close(self, "ui")
    if self.on_back then
        self.on_back(self)
    end
    return true
end

return CommentList
