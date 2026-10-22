-- ui/common/comic_stats.lua
-- 漫画卡片/详情表头共用的"统计行"
--
-- 为什么要有这个模块: 列表卡片与详情表头各自拼一遍, 字段顺序和单位都不一致
-- (卡片写 "%1P", 表头写 "%1P", 又只在没有页数/话数时才显示"喜欢"), 于是同一部
-- 作品在不同页面/不同源上显示的东西五花八门 —— 真机反馈"漫画列表展示的内容都不
-- 统一, 有些显示话数, 有些显示页数, 有些又不显示"。
--
-- 统一规则 (只显示源真的给了的字段, 顺序固定):
--   话数 -> 页数 -> 阅读量(无话数/页数时) -> 状态 -> 喜欢 -> 编号(兜底) -> 更新日期
--
-- 更新日期放最后: 它是"元信息", 前面几项是"作品属性"。三个源都给得出
-- (源 B update_at 秒级时间戳 / 源 A updated_at ISO 串 / 源 C 列表的日期),
-- 以前只接了源 C 那一份, 现在统一接上 (真机反馈: 有的都显示出来)。
--
-- 兜底为什么是作品编号: 源 B / 源 C 的列表接口不返回页数或话数 (只有详情页有),
-- 以前卡片就留空; 编号至少能让人去网页上找到同一部作品, 也让第三行高度稳定。

local _ = require("gettext")
local T = require("ffi/util").template
local JN = require("util.json_null")

local M = {}

--- 单个字段取"有效数字": JSON null / 字符串 / nil 一律当 0
local function num(v)
    local n = tonumber(v)
    if not n or n < 0 then return 0 end
    return math.floor(n)
end

--- 更新日期 (三种形态都认: epoch 秒 / ISO 串 / 已经格式化好的日期)
-- 各源给的不一样: 源 B 是 epoch 秒, 源 A 是 ISO 串, 源 C 是 "2026-10-18"。
-- @return "YYYY-MM-DD" 或 nil (源没给/认不出)
function M.updated_text(comic)
    local v = comic and comic.update_time
    if type(v) == "number" and v > 0 then
        local ok, s = pcall(os.date, "%Y-%m-%d", v)
        return (ok and s) or nil
    end
    if type(v) ~= "string" or v == "" then return nil end
    return v:match("^(%d%d%d%d%-%d%d%-%d%d)")
end

--- 拼接统计行
-- @param comic 已标准化 (或原始) 的漫画表; 字段缺省即可
-- @param opts  { updated_shown = true } 表示"更新时间"已经在第二行显示过, 不要重复
-- @return string 可能为空串 (源什么都不知道时)
function M.line(comic, opts)
    comic = comic or {}
    local parts = {}

    local eps = num(comic.epsCount)
    if eps > 0 then
        parts[#parts + 1] = T(_("%1话"), eps)
    end

    local pages = num(comic.pagesCount)
    if pages > 0 then
        parts[#parts + 1] = T(_("%1页"), pages)
    end

    -- Pica 分类/搜索接口不提供话数、页数, 用已知阅读量补位, 不逐本请求详情。
    local views = num(comic.viewsCount)
    if eps == 0 and pages == 0 and views > 0 then
        parts[#parts + 1] = T(_("%1阅读"), views)
    end

    -- finished 用三态: true = 完结 / false = 连载 / nil = 源没说
    if comic.finished ~= nil then
        parts[#parts + 1] = comic.finished and _("完结") or _("连载")
    end

    local likes = num(comic.likesCount)
    if likes > 0 then
        parts[#parts + 1] = T(_("%1喜欢"), likes)
    end

    -- 兜底: 作品编号 (源 B 的列表接口没有页数/话数, 编号至少能去网页上找到同一部作品)
    -- 必须排在更新时间**前面**: 否则"只有编号"会变成"只有更新时间"。
    if #parts == 0 then
        local fallback = JN.str(comic.subtitle)
        if fallback and fallback ~= "" then
            parts[#parts + 1] = fallback
        end
    end

    -- 更新时间: 有的源给 (源 B/源 A/源 C), 有的不给 (缺省即跳过)。
    -- 第二行已经用它补位时不要再写一遍 —— 同一行信息出现两次比不显示更糟。
    if not (opts and opts.updated_shown) then
        local updated = M.updated_text(comic)
        if updated then
            parts[#parts + 1] = T(_("更新 %1"), updated)
        end
    end

    return table.concat(parts, " · ")
end

return M
