local BaseSettingsModule = require("ui.settings.base")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

-- 注意: SettingsManager 直接对模块表调用 :show()，并不会调用 init()，
-- 因此所有依赖必须在构造时就注入，否则 show() 里会取到 nil 并闪退。
-- (旧代码把 self.cache 放在 init() 里，且调用了不存在的 BaseSettingsModule.init)
local CacheSettings = BaseSettingsModule:new{
    name = "cache_settings",
    cache = require("util.cache"),
}

--- 兼容保留: 若被显式调用则重新注入依赖
function CacheSettings:init()
    self.cache = require("util.cache")
end

local function to_mb(bytes)
    return math.floor((bytes or 0) / 1024 / 1024 * 100) / 100
end

function CacheSettings:show()
    -- 一次遍历出全部数字。原来是 5 个 get*Size() = 5 遍全树递归扫描
    -- (而且 covers 被算了两遍), 缓存里页数上千时打开这页就是几千次同步 stat。
    local sizes = self.cache:getSizeBreakdown() or {}
    local total = sizes.total or 0
    local cover_size = sizes.covers or 0
    local reading_size = sizes.reading or 0
    -- images 桶已排除 covers (见 getSizeBreakdown), 不用再扣
    local image_size = sizes.images or 0
    local data_size = sizes.data or 0

    local items = {
        {
            text = T(_("当前缓存大小: %1 MB"), to_mb(total)),
            enabled = false,
            select_enabled = false,
        },
        {
            text = T(_("封面: %1 MB · 阅读页: %2 MB"), to_mb(cover_size), to_mb(reading_size)),
            enabled = false,
            select_enabled = false,
        },
        {
            text = T(_("图片: %1 MB · 数据: %2 MB"), to_mb(image_size), to_mb(data_size)),
            enabled = false,
            select_enabled = false,
        },
        {
            text = T(_("最大缓存容量: %1 MB"), self:safeConfigGet("max_cache_size", 500)),
            callback = function()
                self:setMaxCacheSize()
            end,
        },
        {
            text = _("清除封面/阅读缓存"),
            callback = function()
                self:clearImageCache()
            end,
        },
        {
            text = _("清除所有缓存"),
            callback = function()
                self:clearAllCache()
            end,
        },
        self:createBackButton(),
    }

    local menu = self:createMenu(_("缓存管理"), items)
    self:showMenu(menu)
end

function CacheSettings:setMaxCacheSize()
    local current_max_size = self:safeConfigGet("max_cache_size", 500)

    local widget = self:createSpinWidget{
        title = _("设置最大缓存容量"),
        value = current_max_size,
        min = 100,
        max = 5000,
        step = 100,
        unit = _("MB"),
        callback = function(new_size)
            self:safeConfigSet(
                "max_cache_size",
                new_size,
                T(_("最大缓存容量已设置为 %1 MB"), new_size)
            )
        end,
    }

    UIManager:show(widget, "ui")
end

function CacheSettings:clearImageCache()
    local confirm_box = self:createConfirmBox{
        text = _("确定要清除所有图片缓存吗？"),
        ok_callback = function()
            local success, cleared = pcall(function()
                return self.cache:clearImageCache()
            end)

            if success then
                self:showInfo(T(_("已清除 %1 MB 图片缓存"),
                    math.floor(cleared / 1024 / 1024 * 100) / 100))
                -- 原地刷新缓存大小显示 (不能直接 show: 会叠出第二层缓存页)
                self:refresh()
            else
                self:showError(_("清除图片缓存失败"))
            end
        end,
    }

    UIManager:show(confirm_box, "ui")
end

function CacheSettings:clearAllCache()
    local confirm_box = self:createConfirmBox{
        text = _("确定要清除所有缓存吗？这将包括图片和漫画信息缓存。"),
        ok_callback = function()
            local success, cleared = pcall(function()
                return self.cache:clearAllCache()
            end)

            if success then
                self:showInfo(T(_("已清除 %1 MB 缓存"),
                    math.floor(cleared / 1024 / 1024 * 100) / 100))
                -- 原地刷新缓存大小显示 (不能直接 show: 会叠出第二层缓存页)
                self:refresh()
            else
                self:showError(_("清除缓存失败"))
            end
        end,
    }

    UIManager:show(confirm_box, "ui")
end

return CacheSettings