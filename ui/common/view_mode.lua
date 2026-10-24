-- ui/common/view_mode.lua
-- 阅读版式: 竖屏 / 条漫 (上下滚动) / 横屏 (旋转 90°)
--
-- 判据为什么改成**像素长宽比** (v0.9.41):
--   以前按源站分类/标签 ("韓漫"/"webtoon") 判条漫。真机反馈里有一类作品正好相反:
--   分类写着韓漫, 画法却是仿日漫的整页分镜 (实测源 B 339033 一话的切片是
--   800x1129, 与日漫 1451x2048 / 1080x1525 / 2129x3006 的比例完全一样),
--   按分类判会把它切成滚动 —— 而它本该整页翻。
--
--   真正决定"怎么读"的是画面本身:
--     条漫切片:  720x3008  -> h/w = 4.18 (真机实测, 人妻獵人)
--     普通漫画:  1451x2048 -> h/w = 1.41 (各种日漫/韩漫仿日漫)
--   设备 PW5:   1236x1648 -> h/w = 1.33
--
--   规则 (与用户约定):
--     画面比 > 设备比 × 2   -> 条漫 (比屏幕高出一倍以上, 只能连续滚)
--     宽 > 高               -> 横屏 (横向页面按长边阅读)
--     其余                  -> 竖屏整页
--
--   优先取章节中段页，避开开头的封面、跨页或介绍图。
--
-- 三种模式的文档设置 (见 ui/stream_reader.lua:applyDefaultDocSettings):
--   竖屏:  kopt_page_scroll=0, zoom_mode=page
--   条漫:  kopt_page_scroll=1, zoom_mode=pagewidth, 页间距 0
--   横屏:  kopt_page_scroll=0, zoom_mode=page, kopt_rotation_mode=90°
--
-- 单本覆盖: 详情页「版式」按钮在三项之间轮换, 写进 config 的 comic_view_modes
-- (见 model/comic.lua:setViewMode)。**单本设置优先于全局设置** —— 用户对某一本
-- 的选择不该被全局策略改回去。
--
-- 为什么**不**挂在阅读历史条目上: 历史每个源只留 50 条, 用户还能一键清空。
-- 把"这本书怎么读"挂在会被淘汰的列表上, 表现为"清了历史后又变回自动"。
local config = require("util.config")
local Screen = require("device").screen

local M = {}

M.AUTO = "auto"
M.PAGE = "page"
M.SCROLL = "scroll"
M.LANDSCAPE = "landscape"

--- 详情页按钮的轮换顺序 (不含 auto: 用户点它就是要一个确定的结果)
M.CYCLE = { M.PAGE, M.SCROLL, M.LANDSCAPE }

--- 全局策略 (设置 → 阅读设置 → 条漫滚动阅读)
--   auto   按长宽比自动判定
--   always 一律条漫
--   never  一律竖屏
M.CONFIG = "webtoon_scroll"
M.POLICIES = { auto = true, always = true, never = true }

--- 横屏时的旋转方向 (LinuxFB 常量: 1 = 顺时针 90°, 3 = 逆时针 90°)
--
-- 为什么做成设置项: 横屏是把屏幕转 90°, 但"往哪边转"没有客观答案 —— 画面正立时
-- 设备该顺时针还是逆时针躺下, 取决于用户怎么拿 (左手/右手、坐着/躺着)。写死一个
-- 方向, 另一半用户看到的就是倒着的画面。
--   设置 → 阅读设置 → 横屏方向
-- 改完对**之后打开的章节**生效: 文档设置 (kopt_rotation_mode) 只在打开文档时读一次。
--
-- **默认 3 (逆时针)**: 真机 (PW5) 实测顺时针会看到倒着的画面, 逆时针才是正立的。
-- 反过来的设备/拿法可在设置里切回顺时针。
M.ROTATION_CONFIG = "landscape_rotation"
M.ROTATION_DEFAULT = 3                     -- 3 = 逆时针 90° (真机正立)
M.ROTATIONS = { [1] = true, [3] = true }   -- 1 = 顺时针 90°, 3 = 逆时针 90°

function M.samplePage(total)
    total=math.max(1,math.floor(tonumber(total) or 1))
    return math.min(total,math.floor(total/2)+1)
end

--- 当前设置的横屏方向 (非法/缺失一律按默认值)
function M.landscape_rotation()
    local v = tonumber(config:get(M.ROTATION_CONFIG, M.ROTATION_DEFAULT))
    if not M.ROTATIONS[v] then v = M.ROTATION_DEFAULT end
    return v
end

--- 全局策略
function M.policy()
    local v = config:get(M.CONFIG, "auto")
    if not M.POLICIES[v] then return "auto" end
    return v
end

--- 按像素尺寸判版式
-- @return "scroll" | "landscape" | "page"; 尺寸未知时返回 nil (调用方决定兜底)
function M.classify(w, h)
    w, h = tonumber(w), tonumber(h)
    if not w or not h or w <= 0 or h <= 0 then return nil end
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    if not (sw and sh and sw > 0 and sh > 0) then return nil end
    -- 设备比要**与当前旋转无关**: 横屏模式下 getWidth/getHeight 是交换的,
    -- 直接用 sh/sw 会得到 0.75 (而不是 1.33), 阈值整体错位。
    -- 取"长边/短边"才是这台设备竖着放时的比例。
    local device = math.max(sw, sh) / math.min(sw, sh)
    local ratio = h / w
    if ratio > device * 2 then return M.SCROLL end
    if w > h then return M.LANDSCAPE end
    return M.PAGE
end

--- 已经定下来的版式 (不含"按画面自动判定"那一步)
-- 顺序: 单本设置 > 全局策略; 两者都没有 => nil (交给自动判定)
--
-- 详情页的「版式」按钮用这个: 那一页量不到中段图片的尺寸, 显示"自动"才是诚实的
-- (真正读的时候会按画面判), 而不是假装已经是竖屏。
function M.current(saved)
    if saved == M.PAGE or saved == M.SCROLL or saved == M.LANDSCAPE then
        return saved
    end
    local p = M.policy()
    if p == "always" then return M.SCROLL end
    if p == "never" then return M.PAGE end
    return nil
end

--- 最终版式: 单本设置 > 全局策略 > 自动判定 > 竖屏
-- @param saved 单本设置 (nil = 没设过)
-- @param size  { w=, h= } 中段采样页的像素尺寸; 未知时传 nil
function M.resolve(saved, size)
    local known = M.current(saved)
    if known then return known end
    return M.classify(size and size.w, size and size.h) or M.PAGE
end

--- 按钮上的文案 (也是当前版式的显示)
-- @param mode  M.PAGE / M.SCROLL / M.LANDSCAPE; nil = 自动
function M.label(mode)
    local _ = require("gettext")
    if mode == M.SCROLL then return _("条漫") end
    if mode == M.LANDSCAPE then return _("横屏") end
    if mode == M.PAGE then return _("竖屏") end
    return _("自动")
end

--- 进入条漫模式时的弹窗提示次数 (跨章节/跨启动累计)
-- 两次之后只在**打开时的加载文案**里带一句 (见 api/comic.lua)。
M.NOTICE_TIMES = 2
M.NOTICE_CONFIG = "webtoon_notice_count"

--- 这次还要不要弹提示 (要就返回 true, 并累计已提示次数)
function M.take_notice()
    local shown = tonumber(config:get(M.NOTICE_CONFIG, 0)) or 0
    if shown >= M.NOTICE_TIMES then return false end
    config:set(M.NOTICE_CONFIG, shown + 1)
    return true
end

--- 轮换到下一个版式 (nil / 非法值 -> 竖屏)
function M.next(mode)
    for i, m in ipairs(M.CYCLE) do
        if m == mode then return M.CYCLE[i % #M.CYCLE + 1] end
    end
    return M.CYCLE[1]
end

return M
