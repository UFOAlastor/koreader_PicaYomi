-- settings模块初始化文件
-- 这个文件确保所有设置模块都可以被正确加载

local logger = require("util.logger")

-- 预加载所有设置模块以检查语法错误
-- 注意: 这里必须与 manager 实际挂载的模块保持一致,
-- 否则会出现"文件在、菜单里没有"的死代码。
local modules = {
    "ui.settings.base",
    "ui.settings.manager",
    "ui.settings.reading",
    "ui.settings.cache",
    "ui.settings.about",
}

for _, module_name in ipairs(modules) do
    local success, err = pcall(require, module_name)
    if not success then
        logger.err("Failed to load settings module:", module_name, err)
    else
        if logger.enabled then logger.info("Settings module loaded:", module_name) end
    end
end

return {
    manager = require("ui.settings.manager"),
    base = require("ui.settings.base"),
    reading = require("ui.settings.reading"),
    cache = require("ui.settings.cache"),
    about = require("ui.settings.about"),
}