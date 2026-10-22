--[[
 * UUID生成模块
 * 简化版本：生成符合RFC4122的UUID
--]]

local random = math.random

-- 种子随机数生成器
local function seed()
    -- 使用当前时间和内存地址作为随机种子
    random(1, 1000)
    random(1, 1000)
    math.randomseed(os.time() * 1000 + tostring({}):sub(8):match(".[a-fA-F0-9]+"):sub(1, 6))
    random(1, 1000)
    random(1, 1000)
end

-- 生成十六进制字符
local function hex(n, len)
    local result = ""
    for i = 1, len do
        local digit = random(0, 15)
        result = result .. string.format("%x", digit)
    end
    return result
end

-- 生成随机UUID
local function generate()
    -- 格式: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
    -- 其中y是8,9,a,b中的一个
    local uuid = hex(0, 8) .. "-" .. hex(0, 4) .. "-4" .. hex(0, 3) .. "-"

    -- 生成y (8,9,a,b中的一个)
    local y = {"8", "9", "a", "b"}
    uuid = uuid .. y[random(1, 4)] .. hex(0, 3) .. "-" .. hex(0, 12)

    return uuid
end

-- 导出接口
return function()
    return generate()
end