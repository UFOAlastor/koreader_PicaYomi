-- 兼容性封装，提供与旧接口相同的API
local SettingsManager = require("ui.settings.manager")
local logger = require("util.logger")
local _ = require("gettext")

local Settings = {}

-- 创建单例实例
local instance = nil

function Settings:new()
    if not instance then
        instance = SettingsManager:new()
        if logger.enabled then logger.info("Picayomi Settings: 创建新的设置管理器实例") end
    end
    return instance
end

-- 兼容旧接口
function Settings:show()
    local settings_manager = self:new()
    settings_manager:show()
end

function Settings:init()
    -- 向后兼容，实际初始化工作在SettingsManager中完成
    return self:new()
end

return Settings