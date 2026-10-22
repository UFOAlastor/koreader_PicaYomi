local logger = require("util.logger")
local sha256 = require("util.sha256")

local HMAC = {}

-- 将字符串转换为十六进制
function HMAC.to_hex(str)
    return sha256.str2hexa and sha256.str2hexa(str) or
        (string.gsub(str, ".", function(c)
            return string.format("%02x", string.byte(c))
        end))
end

-- HMAC-SHA256实现
function HMAC.hmac_sha256_hex(key, message)
    -- 记录处理信息
    -- 每次请求都会调用, 属高频噪音 -> dbg (默认不输出)
    if logger.enabled then logger.dbg("Picayomi HMAC: 计算签名，消息长度: " .. #message) end

    -- 计算HMAC-SHA256
    local result = sha256.hmac_sha256(key, message)

    return result
end

return HMAC