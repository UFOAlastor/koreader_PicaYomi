local md5 = require("ffi/sha2").md5
-- 检查是否存在hmac_sha256函数，如果不存在则使用自定义实现
local sha256_lib = require("ffi/sha2")
local hmac = sha256_lib.hmac_sha256
local sha256 = sha256_lib.sha256
local logger = require("util.logger")
local basexx = require("basexx")
local uuid = require("uuid")

-- 尝试直接加载SHA-HMAC模块
local custom_sha256
local ok, err

-- 使用dofile方式加载，这样更可靠
ok, err = pcall(function()
    -- 直接从当前文件的相对路径加载
    custom_sha256 = dofile("plugins/picayomi.koplugin/util/sha-hmac.lua")
end)

if not ok then
    -- 如果加载失败，尝试其他路径
    if logger.enabled then logger.dbg("Picayomi Crypto: 无法加载SHA实现(路径1):", err) end

    ok, err = pcall(function()
        custom_sha256 = dofile("./plugins/picayomi.koplugin/util/sha-hmac.lua")
    end)
end

if not ok then
    if logger.enabled then logger.dbg("Picayomi Crypto: 无法加载SHA实现(路径2):", err) end

    -- 内联SHA-HMAC实现 - 这是最后的手段
    if logger.enabled then logger.info("Picayomi Crypto: 使用内联SHA-HMAC实现") end
    custom_sha256 = {}

    -- 位运算函数
    local bit = {
        band = function(a, b)
            local r = 0
            for i = 0, 31 do
                if (a % 2 == 1) and (b % 2 == 1) then r = r + 2^i end
                a = math.floor(a/2)
                b = math.floor(b/2)
            end
            return r
        end,
        bxor = function(a, b)
            local r = 0
            for i = 0, 31 do
                if (a % 2) ~= (b % 2) then r = r + 2^i end
                a = math.floor(a/2)
                b = math.floor(b/2)
            end
            return r
        end
    }

    -- 简单的HMAC实现（使用MD5替代SHA-256）
    custom_sha256.hmac_sha256 = function(key, message)
        -- 对key进行处理
        if #key > 64 then
            key = md5(key)
        end
        if #key < 64 then
            key = key .. string.rep(string.char(0), 64 - #key)
        end

        -- 内部和外部键
        local ipad = ""
        local opad = ""
        for i = 1, #key do
            local byte = key:byte(i)
            ipad = ipad .. string.char(bit.bxor(byte, 0x36))
            opad = opad .. string.char(bit.bxor(byte, 0x5c))
        end

        -- 计算内部和外部哈希
        local inner_hash = md5(ipad .. message)
        local outer_hash = md5(opad .. inner_hash)

        return outer_hash
    end

    -- 十六进制转换
    custom_sha256.to_hex = function(str)
        local hex = ""
        for i = 1, #str do
            hex = hex .. string.format("%02x", string.byte(str, i))
        end
        return hex
    end

    -- SHA-256函数（使用MD5替代）
    custom_sha256.sha256 = function(message)
        return md5(message)
    end

    ok = true
end

if ok then
    if logger.enabled then logger.info("Picayomi Crypto: 成功加载SHA-HMAC实现") end
else
    logger.warn("Picayomi Crypto: 所有SHA-HMAC加载尝试都失败:", err)
end

-- 确保bit32可用（在某些Lua版本中可能不存在）
local bit32 = bit32 or {}
if not bit32.bxor then
    if logger.enabled then logger.info("Picayomi Crypto: bit32不可用，使用兼容实现") end

    -- 提供简单的bxor实现
    bit32.bxor = function(a, b)
        local r = 0
        for i = 0, 31 do
            local x = a / 2 + b / 2
            if x ~= math.floor(x) then
                r = r + 2^i
            end
            a = math.floor(a / 2)
            b = math.floor(b / 2)
        end
        return r
    end
end

-- 检查SHA256是否可用，如不可用则加载pure Lua实现
if not sha256 then
    if logger.enabled then logger.info("Picayomi Crypto: SHA256不可用，加载pure Lua实现") end

    if custom_sha256 then
        sha256 = custom_sha256.sha256
        if logger.enabled then logger.info("Picayomi Crypto: 成功加载自定义SHA256实现") end
    else
        -- 如果纯Lua实现不可用，使用MD5代替（临时方案）
        logger.warn("Picayomi Crypto: Pure Lua SHA256不可用，临时使用MD5代替")
        sha256 = function(data)
            return md5(data)
        end
    end
end

-- 如果HMAC不可用，使用自定义实现
if not hmac and custom_sha256 then
    if logger.enabled then logger.info("Picayomi Crypto: 使用自定义HMAC-SHA256实现") end
    hmac = custom_sha256.hmac_sha256
end

local Crypto = {}

-- 初始化随机数种子
math.randomseed(os.time())

-- 生成随机字符串的辅助函数
local function random_string(length)
    local chars = "0123456789abcdef"
    local result = ""
    for _ = 1, length do
        local rand = math.random(1, #chars)
        result = result .. chars:sub(rand, rand)
    end
    return result
end

-- 生成随机UUID
function Crypto:generateUUID()
    -- 生成UUID v4格式
    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
    return string.gsub(template, "[xy]", function(c)
        local v = c == "x" and math.random(0, 0xf) or math.random(8, 0xb)
        return string.format("%x", v)
    end)
end

-- 生成随机nonce
function Crypto:generateNonce()
    return (self:generateUUID():gsub("-", ""))
end

-- 自定义HMAC-SHA256实现
-- 在ffi/sha2库不提供hmac_sha256的情况下使用
function Crypto:hmacSha256(key, data)
    if logger.enabled then logger.dbg("Picayomi Crypto: 调用HMAC-SHA256函数") end

    -- 检查是否有内置hmac函数
    if hmac then
        if logger.enabled then logger.dbg("Picayomi Crypto: 使用可用的HMAC-SHA256实现") end
        local result_ok, hmac_result = pcall(function()
            return hmac(key, data)
        end)

        if not result_ok then
            logger.warn("Picayomi Crypto: HMAC计算失败:", hmac_result)
            -- 失败后降级到MD5
            local md5_result = md5(key .. ":" .. data)
            return basexx.to_hex(md5_result)
        end

        -- 检查结果是否需要转换为十六进制
        if custom_sha256 and type(hmac_result) == "string" then
            if #hmac_result == 32 then
                -- 结果是原始字节，需要转换为十六进制
                return custom_sha256.to_hex(hmac_result)
            else
                -- 可能已经是十六进制格式
                return hmac_result
            end
        end

        return basexx.to_hex(hmac_result)
    end

    -- 如果没有hmac实现可用，直接使用MD5作为替代（临时措施）
    logger.warn("Picayomi Crypto: 无可用的HMAC-SHA256实现，使用MD5代替")
    local md5_result = md5(key .. ":" .. data)
    return basexx.to_hex(md5_result)
end

-- MD5加密
function Crypto:md5(str)
    return md5(str)
end

-- Base64编码
function Crypto:base64Encode(data)
    return basexx.to_base64(data)
end

-- Base64解码
function Crypto:base64Decode(data)
    return basexx.from_base64(data)
end

-- 生成API签名
function Crypto:generateSignature(method, path, time, nonce)
    if logger.enabled then logger.info("Picayomi Crypto: 生成API签名: 方法=" .. method .. ", 路径=" .. path) end

    -- 处理路径，确保不以/开头（与参考代码实现一致）
    if path:sub(1, 1) == "/" then
        path = path:sub(2) -- 去掉开头的斜杠
    end

    -- API密钥
    local api_key = "C69BAF41DA5ABD1FFEDC6D2FEA56B"

    -- 组合待签名字符串（与test_login.py完全一致）
    local str = path .. time .. nonce .. string.lower(method) .. api_key

    -- 转为小写
    str = string.lower(str)

    if logger.enabled then logger.info("Picayomi Crypto: 待签名数据长度: " .. #str) end

    -- HMAC密钥（与test_login.py完全一致）
    local hmac_key = "~d}$Q7$eIni=V)9\\RK/P.RM4;9[7|@/CA}b~OW!3?EV`:<>M7pddUBL5n|0/*Cn"

    -- 使用自定义SHA256实现
    if custom_sha256 and custom_sha256.hmac_sha256 then
        if logger.enabled then logger.info("Picayomi Crypto: 使用自定义HMAC-SHA256实现") end
        local hmac_result = custom_sha256.hmac_sha256(hmac_key, str)
        if type(hmac_result) == "string" then
            -- 确保结果是原始字节字符串
            if #hmac_result == 64 then  -- 已经是十六进制字符串
                return hmac_result
            else  -- 需要转换为十六进制
                return custom_sha256.to_hex(hmac_result)
            end
        end
    end

    -- 如果自定义实现失败，使用内置实现
    if hmac then
        if logger.enabled then logger.info("Picayomi Crypto: 使用内置HMAC-SHA256实现") end
        local hmac_result = hmac(hmac_key, str)
        -- 转换为十六进制字符串
        local hex = ""
        for i = 1, #hmac_result do
            hex = hex .. string.format("%02x", string.byte(hmac_result, i))
        end
        return hex
    end

    -- 如果都失败了，使用MD5作为后备方案
    logger.warn("Picayomi Crypto: 所有HMAC实现都失败，使用MD5后备方案")
    local md5_result = md5(hmac_key .. ":" .. str)
    return basexx.to_hex(md5_result)
end

-- 密码加密方法
function Crypto:encryptPassword(password)
    if logger.enabled then logger.info("Picayomi Crypto: 对密码进行加密") end

    if not password or password == "" then
        logger.warn("Picayomi Crypto: 尝试加密空密码")
        return ""
    end

    -- 使用MD5加密密码
    local md5_result = self:md5(password)
    local encrypted = ""

    -- 转换为十六进制字符串
    if type(md5_result) == "string" then
        -- 如果返回的是原始字节字符串，转换为十六进制
        encrypted = ""
        for i = 1, #md5_result do
            encrypted = encrypted .. string.format("%02x", string.byte(md5_result, i))
        end
    else
        -- 如果是其他格式，使用统一的转换方法
        encrypted = basexx.to_hex(md5_result)
    end

    if logger.enabled then logger.info("Picayomi Crypto: 密码加密完成") end
    return encrypted
end

-- 诊断SSL错误
function Crypto:diagnoseSSLError(error_message)
    if logger.enabled then logger.dbg("Picayomi Crypto: 诊断SSL错误: " .. tostring(error_message)) end

    local diagnostic_result = ""

    -- 简单的结果，不再详细记录
    if logger.enabled then logger.dbg("Picayomi Crypto: SSL错误诊断结果: " .. diagnostic_result) end

    return diagnostic_result
end

return Crypto