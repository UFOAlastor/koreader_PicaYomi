-- ui/common/theme.lua
-- 插件界面的字体出口 (统一在这里定字号, 别在各页面各写一份)
--
-- ============================================================================
-- 为什么必须集中管理 —— 踩过的坑 (真机表现: "字体忽大忽小, 页面显示异常")
-- ============================================================================
-- KOReader 的 `Font:getFace(font, size)` **内部自己会做一次 Screen:scaleBySize**:
--
--     function Font:getFace(font, size)
--         if not size then size = self.sizemap[font] end   -- 只传名字时取默认字号
--         size = Screen:scaleBySize(size)                  -- ← 关键
--         ...
--
-- 所以第二个参数必须是**未缩放**的字号 (KOReader 全库都这么用, 例如
-- `Font:getFace("cfont", 20)`)。而本插件曾经写成
--
--     Font:getFace("cfont", Screen:scaleBySize(20))        -- ← 缩放了两次
--
-- Kindle PW5 的 scaleBySize(x) ≈ x*2.06, 于是字号变成 scaleBySize(scaleBySize(20))
-- ≈ 87px, 而只传名字的 `smallinfofont` 是 22*2.06 ≈ 46px —— 标题比正文大近一倍。
--
-- 更糟的是这不止是"难看": TextBoxWidget 在 `height < 行高` 时会**静默把 height 抬到
-- 行高**, 于是卡片内容从 260 涨到 286, 超出声明高度 26px ——
--   1. 卡片背景只画 260, 文字溢出压到下一张卡上 (显示异常);
--   2. 卡片的**点击区仍是 260**, 溢出那 26px 里点下去命中的是下一张卡 (点击错位)。
-- 真机日志/几何探针 (test/functional_tap_geometry.lua) 实测到的就是这两条。
--
-- 结论: 字号只在这里定, 且**只传未缩放值**。
-- ============================================================================

local Font = require("ui/font")

local Theme = {}

-- 逻辑字号 (未缩放)。改这里即可整体调字号。
local FACES = {
    list_title   = { "cfont", 20 },          -- 列表页标题 / 卡片标题 (配合 bold)
    detail_title = { "cfont", 22 },          -- 详情页标题 (配合 bold)
    row          = { "cfont", 18 },          -- 列表行 / 章节行
    info         = { "smallinfofont" },      -- 正文与元信息 (取 sizemap 默认 22)
    cover_title  = { "cfont", 16 },
    cover_status = { "cfont", 12 },
}

--- 取一个字体 face
-- @param name FACES 里的键; 未知键回退到 info
function Theme.face(name)
    local spec = FACES[name]
    if not spec then return Font:getFace("smallinfofont") end
    return Font:getFace(spec[1], spec[2])
end

--- 供测试断言用: 取某个逻辑字号的最终像素高度
function Theme.faceSize(name)
    return Theme.face(name).size
end

--- 全部逻辑字号名 (供测试遍历, 防止新增了字号却漏测)
function Theme.faceNames()
    local names = {}
    for k in pairs(FACES) do table.insert(names, k) end
    table.sort(names)
    return names
end

return Theme
