-- util/b64.lua
-- 纯 Lua Base64 编解码
--
-- KOReader 既不带 `basexx` 也不带 `mime` (实测 require 都会失败),
-- 因此这里自带一份实现, 供 源 B 接口解密与其它需要 base64 的地方使用。

local B64 = {}

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

-- 字符 -> 6bit 值
local DECODE_MAP = {}
for i = 1, #ALPHABET do
    DECODE_MAP[ALPHABET:sub(i, i)] = i - 1
end

local BITS = {}
for i = 0, 63 do
    BITS[i] = ALPHABET:sub(i + 1, i + 1)
end

--- Base64 解码
-- 自动忽略空白与换行, 兼容缺失的 '=' 填充
-- @return 解码后的二进制字符串; 遇到非法字符返回 nil, err
function B64.decode(input)
    if type(input) ~= "string" then
        return nil, "base64 input must be a string"
    end

    -- 去掉 BOM、空白和换行 (接口返回可能带 BOM, 如 源 B 的域名配置)
    local s = input:gsub("^\239\187\191", ""):gsub("[%s]", "")

    local out = {}
    local buf, bits = 0, 0

    for i = 1, #s do
        local ch = s:sub(i, i)
        if ch == "=" then
            break
        end
        local v = DECODE_MAP[ch]
        if v == nil then
            return nil, "invalid base64 character: " .. ch
        end
        buf = buf * 64 + v
        bits = bits + 6
        if bits >= 8 then
            bits = bits - 8
            local byte = math.floor(buf / (2 ^ bits)) % 256
            out[#out + 1] = string.char(byte)
            buf = buf % (2 ^ bits)
        end
    end

    return table.concat(out)
end

--- Base64 编码 (供测试与调试使用)
function B64.encode(data)
    if type(data) ~= "string" then
        return nil, "base64 input must be a string"
    end

    local out = {}
    local i = 1
    local n = #data

    while i <= n do
        local b1 = data:byte(i)
        local b2 = data:byte(i + 1)
        local b3 = data:byte(i + 2)

        local c1 = math.floor(b1 / 4)
        local c2 = (b1 % 4) * 16 + (b2 and math.floor(b2 / 16) or 0)
        local c3 = b2 and ((b2 % 16) * 4 + (b3 and math.floor(b3 / 64) or 0)) or nil
        local c4 = b3 and (b3 % 64) or nil

        out[#out + 1] = BITS[c1]
        out[#out + 1] = BITS[c2]
        out[#out + 1] = c3 and BITS[c3] or "="
        out[#out + 1] = c4 and BITS[c4] or "="

        i = i + 3
    end

    return table.concat(out)
end

return B64
