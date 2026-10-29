local logger = require("util.logger")
local _ = require("gettext")

local ConfigDefaults = {}

-- 配置项默认值定义
--
-- 重要: 这里只保留**真正被读取**的配置项。
-- 历史上一度定义了一大堆既没有界面、也没有任何逻辑读取的"死配置"
-- (代理三项、阅读方向、翻页模式、主题、字号、自动登录、记住凭据、缓存策略...),
-- 它们既不会被用户看到、也不会产生任何效果 —— 是最典型的"假设置"。
-- 已全部清理; 新增配置项时必须同时接上读取方, 否则
-- test/static_check.py 的"设置项接线检查"会直接报错。
ConfigDefaults.defaults = {
    -- 阅读设置
    -- 图片质量: source/picacg/api.lua 的 preferOriginal() 读取。
    -- 只有两档 (原图 / 缩略图), 因为源那边就只有两档 (见 ui/settings/reading.lua)。
    image_quality = "original",
    -- 默认跟随 KOReader; true 时强制灰度。保留已有用户选择。
    grayscale_images = false,
    -- 提前加载页数 (0~9, 0 = 关闭): ui/stream_reader.lua 读取。
    -- 默认 3 (原为 1): 真机实测单页下载+落盘只要 ~0.1s, 真正的等待来自"翻页那一刻才开始下",
    -- 预取窗口太小就来不及 —— 翻页时看到的仍是"加载中…"。预取的代价只有磁盘
    -- (解码只发生在 MultiImageDoc:openPage, 且上一页的缓冲立刻释放), 所以放宽到 3。
    prefetch_pages = 3,
    novel_prefetch_chapters = 1,
    -- 翻页刷新: ui/reader.lua 的 forceFullRefresh 读取。
    -- true = 每翻一页整屏刷一次 (消墨水屏残影); false = 交给 KOReader 的刷新计数。
    refresh_on_page_turn = true,
    -- 阅读版式 (全局策略): ui/common/view_mode.lua 读取 (ui/stream_reader.lua 据此
    -- 写文档的 kopt_page_scroll / zoom_mode / kopt_rotation_mode)。
    --   auto   按章节中段页的像素长宽比判断
    --   always 一律条漫 (上下滚动)   never 一律竖屏整页
    -- 单本漫画可在详情页「版式」按钮单独指定, 存 comic_view_modes, 优先级更高。
    webtoon_scroll = "auto",
    -- 滚动模式弹窗已提示的次数 (内部计数, 不在设置页): 满 ViewMode.NOTICE_TIMES
    -- 次后不再弹窗, 只在打开时的加载文案里带一句。
    webtoon_notice_count = 0,
    -- 横屏方向: ui/common/view_mode.lua 读取 (设置 → 阅读设置 → 横屏方向)。
    -- 3 = 逆时针 90° (默认, 真机 PW5 实测正立), 1 = 顺时针 90°。只影响「横屏」版式。
    landscape_rotation = 3,

    -- 缓存设置
    max_cache_size = 500,       -- 最大缓存容量(MB): util/cache.lua 等读取

    -- 操作与手势: ui/common/swipe_rules.lua 读取 (每次判定现读, 改完立刻生效)
    --   边缘返回开关 / 允许哪一侧 / 边缘宽度 (narrow 3% / normal 5% / wide 8%)
    swipe_edge_back = true,
    native_reader_edge_back = false,
    swipe_edge_side = "both",
    swipe_edge_width = "normal",
}

-- 配置验证规则
ConfigDefaults.validators = {
    grayscale_images = function(value)
        return type(value) == "boolean"
    end,
    -- medium/high 是旧值: 老配置文件里还有, 一律按原图处理 (见 preferOriginal),
    -- 不拒绝 —— 拒绝会让整个配置文件校验失败, 用户的其它设置一起丢。
    image_quality = function(value)
        return value == "low" or value == "medium"
            or value == "high" or value == "original"
    end,

    novel_prefetch_chapters = function(value)
        return type(value)=="number" and value%1==0 and value>=0 and value<=5
    end,
    prefetch_pages = function(value)
        return type(value) == "number" and value >= 0 and value <= 9
    end,

    max_cache_size = function(value)
        return type(value) == "number" and value >= 100 and value <= 5000
    end,

    refresh_on_page_turn = function(value)
        return type(value) == "boolean"
    end,

    webtoon_scroll = function(value)
        return value == "auto" or value == "always" or value == "never"
    end,

    native_reader_edge_back = function(value)return type(value)=="boolean"end,

    swipe_edge_back = function(value)
        return type(value) == "boolean"
    end,

    swipe_edge_side = function(value)
        return value == "both" or value == "left" or value == "right"
    end,

    swipe_edge_width = function(value)
        return value == "narrow" or value == "normal" or value == "wide"
    end,
}

-- 配置描述（用于生成帮助文档）
ConfigDefaults.descriptions = {
    grayscale_images = _("图片模式"),
    image_quality = _("图片质量"),
    novel_prefetch_chapters = _("提前加载章节数（0~5，0 = 关闭）"),
    prefetch_pages = _("提前加载页数（0~9，0 = 关闭）"),
    max_cache_size = _("最大缓存容量（MB）"),
    refresh_on_page_turn = _("翻页刷新"),
    webtoon_scroll = _("条漫滚动阅读"),
    swipe_edge_back = _("边缘滑动返回"),
    native_reader_edge_back = _("原生 Reader 边缘返回"),
    swipe_edge_side = _("允许返回的边缘"),
    swipe_edge_width = _("边缘宽度"),
}

-- 获取配置项的默认值
function ConfigDefaults:getDefault(key)
    return self.defaults[key]
end

-- 验证配置值
function ConfigDefaults:validate(key, value)
    local validator = self.validators[key]
    if validator then
        return validator(value)
    end
    -- 如果没有验证器，认为值有效
    return true
end

-- 获取所有默认值
function ConfigDefaults:getAllDefaults()
    local result = {}
    for k, v in pairs(self.defaults) do
        result[k] = v
    end
    return result
end

-- 应用默认值到配置对象
function ConfigDefaults:applyDefaults(config)
    local updated = false

    for key, default_value in pairs(self.defaults) do
        local current_value = config:get(key)

        if current_value == nil then
            if logger.enabled then logger.info("ConfigDefaults: 应用默认值", key, "=", default_value) end
            config:set(key, default_value)
            updated = true
        elseif not self:validate(key, current_value) then
            logger.warn("ConfigDefaults: 配置值无效，重置为默认值", key, current_value, "->", default_value)
            config:set(key, default_value)
            updated = true
        end
    end

    return updated
end

-- 获取配置项描述
function ConfigDefaults:getDescription(key)
    return self.descriptions[key] or key
end

-- 重置配置到默认值
function ConfigDefaults:resetToDefaults(config, keys)
    keys = keys or {}

    if #keys == 0 then
        -- 重置所有配置
        for key, default_value in pairs(self.defaults) do
            config:set(key, default_value)
        end
        if logger.enabled then logger.info("ConfigDefaults: 所有配置已重置为默认值") end
    else
        -- 重置指定配置
        for _, key in ipairs(keys) do
            local default_value = self.defaults[key]
            if default_value ~= nil then
                config:set(key, default_value)
                if logger.enabled then logger.info("ConfigDefaults: 配置已重置", key, "=", default_value) end
            end
        end
    end
end

return ConfigDefaults
