local BaseSettingsModule = require("ui.settings.base")
local UIManager = require("ui/uimanager")
local ViewMode = require("ui.common.view_mode")
local _ = require("gettext")
local T = require("ffi/util").template

local ReadingSettings = BaseSettingsModule:new{
    name = "reading_settings",
}

--- 给选中的菜单项打勾
--
-- 我们的设置页用的是 KOReader 的 **Menu** (ui/widget/menu), 它不渲染 `checked`
-- 字段 —— 认 checked_func 的是 TouchMenu (touchmenu.lua:78)。所以以前写
-- `checked = true` 在屏幕上**什么都不会变**, 两行选项长得一模一样, 用户自然
-- 认为"这个设置项没用/没生效" (真机 2026-10-18)。
-- 用文字后缀打勾: 与 Menu 的实现无关, 也不会被样式改动吃掉。
local function checkLabel(selected, text)
    return selected and (text .. "  ✓") or text
end

function ReadingSettings:show()
    local items = {
        {
            text = _("图片模式"),
            callback = function() self:setImageMode() end,
        },
        {
            -- 只有源 A 有这两档: 源 B/源 C 给的就是原图, 没有可切的东西。
            -- 写清楚适用范围, 免得在别的源下看起来像"这个设置没用"。
            text = _("图片质量（仅哔咔）"),
            callback = function()
                self:setImageQuality()
            end,
        },
        {
            text = _("提前加载页数"),
            callback = function()
                self:setPrefetch()
            end,
        },
        {
            text = _("翻页刷新"),
            callback = function()
                self:setPageRefresh()
            end,
        },
        {
            text = _("条漫滚动阅读"),
            callback = function()
                self:setWebtoonScroll()
            end,
        },
        {
            -- 只影响「横屏」版式。放在条漫下面: 两者是同一组"怎么读"的设置。
            text = _("横屏方向"),
            callback = function()
                self:setLandscapeRotation()
            end,
        },
        self:createBackButton(),
    }

    local menu = self:createMenu(_("阅读设置"), items)
    self:showMenu(menu)
end

function ReadingSettings:setImageMode()
    local current = self:safeConfigGet("grayscale_images", false)
    local items = {}
    for _idx, opt in ipairs({
        { text = _("跟随 KOReader（默认）"), value = false },
        { text = _("始终黑白（节省内存）"), value = true },
    }) do
        items[#items + 1] = {
            text = checkLabel(current == opt.value, opt.text),
            callback = function()
                self:safeConfigSet("grayscale_images", opt.value,
                    _("图片模式已保存，重新打开章节后生效"))
                self:goBack()
            end,
        }
    end
    items[#items + 1] = self:createBackButton()
    self:showMenu(self:createMenu(_("图片模式"), items))
end

--- 图片质量
--
-- 只有两档, 因为源那边就只有两档:
--   * 原图      —— 图床的原图 (源 A 1200x1695 / 480KB, 源 C 1444x2048)
--   * 缩略图    —— 源 A 服务端缩放到 800px 的版本 (566x800 / 66KB, 明显糊)
-- 中间档拿不到: 图片代理 的缩放参数在签名里, 改不了 (见
-- source/picacg/api.lua 的 originalImageUrl)。
--
-- 以前这里是 低/中/高 三档, 写进 image-quality 请求头 —— 而那个头对图床无效,
-- 三档实际是同一个画面。用户选「高」还是觉得糊 (真机 2026-10-18)。
function ReadingSettings:setImageQuality()
    local current_quality = self:safeConfigGet("image_quality", "original")
    -- 老配置里还留着三档时代的 medium / high。它们对图片地址的影响和 original
    -- **完全一样** (见 PicacgAPI.preferOriginal: 只有 low 才走缩略图), 所以显示
    -- 时一律归到「原图」—— 否则两行都不打勾, 看起来像"设置项坏了/没生效"。
    -- (真机 2026-10-18: config.json 里是 high, 菜单里两项都没勾)
    if current_quality ~= "low" then current_quality = "original" end

    local qualities = {
        { text = _("原图（清晰，推荐）"), quality = "original" },
        { text = _("缩略图（省流量）"), quality = "low" },
    }

    local items = {}
    for _idx, quality in ipairs(qualities) do
        table.insert(items, {
            text = checkLabel(current_quality == quality.quality, quality.text),
            checked = current_quality == quality.quality,
            callback = function()
                self:safeConfigSet(
                    "image_quality",
                    quality.quality,
                    T(_("图片质量已设置为 %1"), quality.text)
                )
                self:goBack()
            end,
        })
    end
    table.insert(items, self:createBackButton())

    local menu = self:createMenu(_("图片质量"), items)
    self:showMenu(menu)
end

--- 翻页刷新
--
-- 「完整刷新」= 每翻一页整屏闪一次, 消掉上一页的残影 (漫画是整页换图, 局部刷新
-- 留下的印子比文字页明显)。「跟随系统」= 交给 KOReader 自己的刷新计数, 翻页更快,
-- 但中间几页会带印子 (KOReader 默认每 6 次局部刷新才补一次全刷)。
--
-- 实现见 ui/reader.lua 的 PicaReader:forceFullRefresh —— 追加 setDirty(dialog,"full"),
-- 与 KOReader 排的 "ui"/"partial" 会被 UIManager 合并成一次刷新。
function ReadingSettings:setPageRefresh()
    local current = self:safeConfigGet("refresh_on_page_turn", true)
    local options = {
        { text = _("完整刷新（推荐，无残影）"), value = true,
          toast = _("已开启翻页完整刷新") },
        { text = _("跟随系统（更快，可能留残影）"), value = false,
          toast = _("已改为跟随系统刷新") },
    }
    local items = {}
    for _idx, opt in ipairs(options) do
        table.insert(items, {
            text = checkLabel(current == opt.value, opt.text),
            checked = (current == opt.value),
            callback = function()
                self:safeConfigSet("refresh_on_page_turn", opt.value, opt.toast)
                self:goBack()
            end,
        })
    end
    table.insert(items, self:createBackButton())
    local menu = self:createMenu(_("翻页刷新"), items)
    self:showMenu(menu)
end

--- 提前加载页数 (0~9)
--
-- 0 = 关闭: 只按需下载当前页, 翻到哪页下哪页 (省流量/省电, 弱网更稳)。
-- 数值越大翻页越顺, 但预取本身也要占网络和界面时间 —— 弱网下大数值反而
-- 更容易触发熔断 (单页 >3s 或连续失败 2 次就自动暂停预取)。
function ReadingSettings:setPrefetch()
    local current = self:safeConfigGet("prefetch_pages", 1)
    if type(current) ~= "number" then current = 1 end

    local widget = self:createSpinWidget{
        title = _("提前加载页数（0 = 关闭）"),
        value = current,
        min = 0,
        max = 9,
        step = 1,
        unit = _("页"),
        callback = function(new_value)
            self:safeConfigSet(
                "prefetch_pages",
                new_value,
                new_value == 0
                    and _("已关闭提前加载（翻到哪页下哪页）")
                    or T(_("提前加载页数已设置为 %1 页"), new_value)
            )
        end,
    }

    UIManager:show(widget, "ui")
end

--- 横屏方向 (顺时针 90° / 逆时针 90°)
--
-- 横屏是把屏幕转 90°, 但"往哪边转"没有客观答案: 画面正立时设备该顺时针还是
-- 逆时针躺下, 取决于用户怎么拿 (左手/右手、坐着/躺着)。所以做成设置项,
-- 默认逆时针 (3, 真机 PW5 实测正立); 看到的是倒着的画面就切到顺时针 (1)。
--
-- 只影响「横屏」版式 (画面比屏幕宽一倍以上的跨页图, 或在详情页手动选横屏)。
-- 改完对**之后打开的章节**生效: kopt_rotation_mode 只在打开文档时读一次。
function ReadingSettings:setLandscapeRotation()
    local current = ViewMode.landscape_rotation()
    local options = {
        { text = _("逆时针 90°（默认）"), value = 3,
          toast = _("横屏方向：逆时针 90°") },
        { text = _("顺时针 90°"), value = 1,
          toast = _("横屏方向：顺时针 90°") },
    }
    local items = {}
    for _idx, opt in ipairs(options) do
        table.insert(items, {
            text = checkLabel(current == opt.value, opt.text),
            checked = (current == opt.value),
            callback = function()
                self:safeConfigSet("landscape_rotation", opt.value, opt.toast)
                self:goBack()
            end,
        })
    end
    table.insert(items, self:createBackButton())
    local menu = self:createMenu(_("横屏方向"), items)
    self:showMenu(menu)
end

--- 条漫滚动阅读 (自动 / 总是 / 关闭)
--
-- 条漫 (韩漫) 是为手机竖屏画的: 一话就是一条很长的画, 源站把它切成几十上百张
-- 短图。按"一张图 = 一屏"翻页读要翻一百多次, 而且每张切片只有一屏多一点, 翻页
-- 反而把连续画面切碎。滚动模式 (KOReader 的 continuous view + 适配宽度) 才是
-- 正确的读法。
--
-- 判定逻辑在 ui/common/view_mode.lua (自动 = 看**第 1 页画面的像素长宽比**,
-- 与源站分类/页数无关), 真正写进文档设置的是 ui/stream_reader.lua 的
-- applyDefaultDocSettings。
--
-- 这是**全局**策略; 单本漫画可以在详情页用「版式」按钮单独指定 (优先级更高,
-- 见 model/comic.lua 的 getViewMode/setViewMode)。
-- 改完对**之后打开的章节**生效: 已经在读的这一话要退回详情页重进 (文档设置
-- 只在打开文档时读一次)。
function ReadingSettings:setWebtoonScroll()
    local ViewMode = require("ui.common.view_mode")
    local current = ViewMode.policy()
    local options = {
        { text = _("自动（按画面长宽比判断）"), value = "auto",
          toast = _("已改为自动判断版式") },
        { text = _("总是滚动（所有漫画）"), value = "always",
          toast = _("已改为总是滚动") },
        { text = _("关闭（整页翻页）"), value = "never",
          toast = _("已关闭滚动阅读") },
    }
    local items = {}
    for _idx, opt in ipairs(options) do
        table.insert(items, {
            text = checkLabel(current == opt.value, opt.text),
            checked = (current == opt.value),
            callback = function()
                self:safeConfigSet("webtoon_scroll", opt.value, opt.toast)
                self:goBack()
            end,
        })
    end
    table.insert(items, self:createBackButton())
    local menu = self:createMenu(_("条漫滚动阅读"), items)
    self:showMenu(menu)
end

return ReadingSettings
