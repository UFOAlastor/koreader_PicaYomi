-- util/aes.lua
-- 纯 Lua AES (ECB 模式)。仅为 源 B 的接口解密提供支持 ——
-- KOReader 只带 md5/sha256, 没有任何 Lua 可用的 AES。
--
-- 实现说明:
--   * 面向小块数据 (几十 KB 的 JSON), 因此优先正确与可读, 不做查表加速
--   * 用 LuaJIT 的 bit 库做字节运算, 在 Kindle 上性能足够
--   * 支持 128/192/256 位密钥 (源 B 用的是 256 位)
--   * 正确性由 test/test_picayomi.lua 的 NIST FIPS-197 向量保证

local bit = require("bit")
local band, bxor = bit.band, bit.bxor
local lshift, rshift = bit.lshift, bit.rshift

-- LuaJIT 里是全局 unpack; 为兼容可能的 5.2+ 环境做个兜底
local unpack = table.unpack or unpack

local AES = {}

-- AES S-box (FIPS-197 Figure 7)
local SBOX_HEX = table.concat({
    "637c777bf26b6fc53001672bfed7ab76",
    "ca82c97dfa5947f0add4a2af9ca472c0",
    "b7fd9326363ff7cc34a5e5f171d83115",
    "04c723c31896059a071280e2eb27b275",
    "09832c1a1b6e5aa0523bd6b329e32f84",
    "53d100ed20fcb15b6acbbe394a4c58cf",
    "d0efaafb434d338545f9027f503c9fa8",
    "51a3408f929d38f5bcb6da2110fff3d2",
    "cd0c13ec5f974417c4a77e3d645d1973",
    "60814fdc222a908846eeb814de5e0bdb",
    "e0323a0a4906245cc2d3ac629195e479",
    "e7c8376d8dd54ea96c56f4ea657aae08",
    "ba78252e1ca6b4c6e8dd741f4bbd8b8a",
    "703eb5664803f60e613557b986c11d9e",
    "e1f8981169d98e949b1e87e9ce5528df",
    "8ca1890dbfe6426841992d0fb054bb16",
})

-- 逆 S-box (FIPS-197 Figure 14)
local INV_SBOX_HEX = table.concat({
    "52096ad53036a538bf40a39e81f3d7fb",
    "7ce339829b2fff87348e4344c4dee9cb",
    "547b9432a6c2233dee4c950b42fac34e",
    "082ea16628d924b2765ba2496d8bd125",
    "72f8f66486689816d4a45ccc5d65b692",
    "6c704850fdedb9da5e154657a78d9d84",
    "90d8ab008cbcd30af7e45805b8b34506",
    "d02c1e8fca3f0f02c1afbd0301138a6b",
    "3a9111414f67dcea97f2cfcef0b4e673",
    "96ac7422e7ad3585e2f937e81c75df6e",
    "47f11a711d29c5896fb7620eaa18be1b",
    "fc563e4bc6d279209adbc0fe78cd5af4",
    "1fdda8338807c731b11210592780ec5f",
    "60517fa919b54a0d2de57a9f93c99cef",
    "a0e03b4dae2af5b0c8ebbb3c83539961",
    "172b047eba77d626e169146355210c7d",
})

local RCON = { 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36 }

-- 将十六进制字符串展开为字节数组 (1-based)
local function hex_to_bytes(hex)
    local bytes = {}
    for i = 1, #hex, 2 do
        bytes[#bytes + 1] = tonumber(hex:sub(i, i + 1), 16)
    end
    return bytes
end

local sbox = hex_to_bytes(SBOX_HEX)
local inv_sbox = hex_to_bytes(INV_SBOX_HEX)

------------------------------------------------------------------
-- GF(2^8) 乘法与列混合
------------------------------------------------------------------

local function xtime(a)
    a = band(a, 0xFF)
    if band(a, 0x80) ~= 0 then
        return bxor(band(lshift(a, 1), 0xFF), 0x1B)
    end
    return band(lshift(a, 1), 0xFF)
end

-- 通用 GF(2^8) 乘法 (俄式乘法)
local function gmul(a, b)
    a = band(a, 0xFF)
    b = band(b, 0xFF)
    local p = 0
    for _ = 1, 8 do
        if band(b, 1) == 1 then p = bxor(p, a) end
        b = rshift(b, 1)
        a = xtime(a)
    end
    return band(p, 0xFF)
end

------------------------------------------------------------------
-- 轮密钥扩展
------------------------------------------------------------------

local function key_expansion(key)
    local Nk = #key / 4          -- 4 / 6 / 8
    local Nr = Nk + 6            -- 10 / 12 / 14
    local total = 4 * (Nr + 1)

    -- w[i] 为 4 字节数组 (1-based), i 从 1 开始对应规范里的 w[0]
    local w = {}
    for i = 1, Nk do
        local o = (i - 1) * 4
        w[i] = { key[o + 1], key[o + 2], key[o + 3], key[o + 4] }
    end

    for i = Nk + 1, total do
        local prev = w[i - 1]
        local t = { prev[1], prev[2], prev[3], prev[4] }

        if (i - 1) % Nk == 0 then
            -- RotWord + SubWord + Rcon
            t = { t[2], t[3], t[4], t[1] }
            t = { sbox[t[1] + 1], sbox[t[2] + 1], sbox[t[3] + 1], sbox[t[4] + 1] }
            t[1] = bxor(t[1], RCON[(i - 1) / Nk])
        elseif Nk > 6 and (i - 1) % Nk == 4 then
            -- AES-256 额外的一次 SubWord
            t = { sbox[t[1] + 1], sbox[t[2] + 1], sbox[t[3] + 1], sbox[t[4] + 1] }
        end

        local base = w[i - Nk]
        w[i] = {
            bxor(base[1], t[1]),
            bxor(base[2], t[2]),
            bxor(base[3], t[3]),
            bxor(base[4], t[4]),
        }
    end

    return w, Nr
end

------------------------------------------------------------------
-- 轮函数 (state 为 1-based 的 16 字节数组, 列主序: s[r + 4c])
------------------------------------------------------------------

local function add_round_key(s, w, round)
    for c = 0, 3 do
        local word = w[4 * round + c + 1]
        local o = 4 * c
        s[o + 1] = bxor(s[o + 1], word[1])
        s[o + 2] = bxor(s[o + 2], word[2])
        s[o + 3] = bxor(s[o + 3], word[3])
        s[o + 4] = bxor(s[o + 4], word[4])
    end
end

local function sub_bytes(s, box)
    for i = 1, 16 do
        s[i] = box[s[i] + 1]
    end
end

-- 行移位 (加密: 第 R 行左移 R 位)
-- 状态字节位置: 行 R (0-based) 第 c 列 -> s[R + 4*c + 1]
local function shift_rows(s)
    for R = 1, 3 do
        local row = {}
        for c = 0, 3 do row[c + 1] = s[R + 4 * c + 1] end
        local out = {}
        for c = 1, 4 do out[c] = row[(c - 1 + R) % 4 + 1] end
        for c = 0, 3 do s[R + 4 * c + 1] = out[c + 1] end
    end
end

-- 逆行移位 (解密: 第 R 行右移 R 位)
local function inv_shift_rows(s)
    for R = 1, 3 do
        local row = {}
        for c = 0, 3 do row[c + 1] = s[R + 4 * c + 1] end
        local out = {}
        for c = 1, 4 do out[(c - 1 + R) % 4 + 1] = row[c] end
        for c = 0, 3 do s[R + 4 * c + 1] = out[c + 1] end
    end
end

local function mix_columns(s)
    for c = 0, 3 do
        local o = 4 * c
        local a0, a1, a2, a3 = s[o + 1], s[o + 2], s[o + 3], s[o + 4]
        s[o + 1] = bxor(bxor(gmul(a0, 2), gmul(a1, 3)), bxor(a2, a3))
        s[o + 2] = bxor(bxor(a0, gmul(a1, 2)), bxor(gmul(a2, 3), a3))
        s[o + 3] = bxor(bxor(a0, a1), bxor(gmul(a2, 2), gmul(a3, 3)))
        s[o + 4] = bxor(bxor(gmul(a0, 3), a1), bxor(a2, gmul(a3, 2)))
    end
end

local function inv_mix_columns(s)
    for c = 0, 3 do
        local o = 4 * c
        local a0, a1, a2, a3 = s[o + 1], s[o + 2], s[o + 3], s[o + 4]
        s[o + 1] = bxor(bxor(gmul(a0, 14), gmul(a1, 11)), bxor(gmul(a2, 13), gmul(a3, 9)))
        s[o + 2] = bxor(bxor(gmul(a0, 9), gmul(a1, 14)), bxor(gmul(a2, 11), gmul(a3, 13)))
        s[o + 3] = bxor(bxor(gmul(a0, 13), gmul(a1, 9)), bxor(gmul(a2, 14), gmul(a3, 11)))
        s[o + 4] = bxor(bxor(gmul(a0, 11), gmul(a1, 13)), bxor(gmul(a2, 9), gmul(a3, 14)))
    end
end

------------------------------------------------------------------
-- 对外接口
------------------------------------------------------------------

local function check_key(key)
    if type(key) ~= "string" or not (#key == 16 or #key == 24 or #key == 32) then
        return nil, "AES key must be 16/24/32 bytes"
    end
    return true
end

--- 加密单个 16 字节分组
function AES.encrypt_block(key, block)
    local ok, err = check_key(key)
    if not ok then return nil, err end
    if #block ~= 16 then return nil, "AES block must be 16 bytes" end

    local w, Nr = key_expansion({ key:byte(1, #key) })
    local s = { block:byte(1, 16) }

    add_round_key(s, w, 0)
    for round = 1, Nr - 1 do
        sub_bytes(s, sbox)
        shift_rows(s)
        mix_columns(s)
        add_round_key(s, w, round)
    end
    sub_bytes(s, sbox)
    shift_rows(s)
    add_round_key(s, w, Nr)

    return string.char(unpack(s))
end

--- 解密单个 16 字节分组
function AES.decrypt_block(key, block)
    local ok, err = check_key(key)
    if not ok then return nil, err end
    if #block ~= 16 then return nil, "AES block must be 16 bytes" end

    local w, Nr = key_expansion({ key:byte(1, #key) })
    local s = { block:byte(1, 16) }

    add_round_key(s, w, Nr)
    for round = Nr - 1, 1, -1 do
        inv_shift_rows(s)
        sub_bytes(s, inv_sbox)
        add_round_key(s, w, round)
        inv_mix_columns(s)
    end
    inv_shift_rows(s)
    sub_bytes(s, inv_sbox)
    add_round_key(s, w, 0)

    return string.char(unpack(s))
end

--- ECB 模式解密
-- @param key     16/24/32 字节二进制密钥
-- @param data    密文 (长度必须是 16 的倍数)
-- @param padding "none"(默认, 原样返回) 或 "pkcs7"(去除 PKCS#7 填充)
function AES.decrypt_ecb(key, data, padding)
    local ok, err = check_key(key)
    if not ok then return nil, err end
    if type(data) ~= "string" or #data == 0 or #data % 16 ~= 0 then
        return nil, "AES ciphertext length must be a positive multiple of 16"
    end

    local w, Nr = key_expansion({ key:byte(1, #key) })
    local out = {}
    local s = {}

    for base = 0, #data - 1, 16 do
        for i = 1, 16 do s[i] = data:byte(base + i) end

        add_round_key(s, w, Nr)
        for round = Nr - 1, 1, -1 do
            inv_shift_rows(s)
            sub_bytes(s, inv_sbox)
            add_round_key(s, w, round)
            inv_mix_columns(s)
        end
        inv_shift_rows(s)
        sub_bytes(s, inv_sbox)
        add_round_key(s, w, 0)

        out[#out + 1] = string.char(unpack(s))
    end

    local result = table.concat(out)

    if padding == "pkcs7" then
        local pad = result:byte(#result)
        if pad and pad >= 1 and pad <= 16 and pad <= #result then
            result = result:sub(1, #result - pad)
        end
    end

    return result
end

--- ECB 模式加密 (主要用于测试/自检)
function AES.encrypt_ecb(key, data, padding)
    local ok, err = check_key(key)
    if not ok then return nil, err end
    if type(data) ~= "string" or #data == 0 then
        return nil, "AES plaintext must be non-empty"
    end

    if padding == "pkcs7" then
        local pad = 16 - (#data % 16)
        data = data .. string.rep(string.char(pad), pad)
    elseif #data % 16 ~= 0 then
        return nil, "AES plaintext length must be a multiple of 16 (or use pkcs7)"
    end

    local w, Nr = key_expansion({ key:byte(1, #key) })
    local out = {}
    local s = {}

    for base = 0, #data - 1, 16 do
        for i = 1, 16 do s[i] = data:byte(base + i) end

        add_round_key(s, w, 0)
        for round = 1, Nr - 1 do
            sub_bytes(s, sbox)
            shift_rows(s)
            mix_columns(s)
            add_round_key(s, w, round)
        end
        sub_bytes(s, sbox)
        shift_rows(s)
        add_round_key(s, w, Nr)

        out[#out + 1] = string.char(unpack(s))
    end

    return table.concat(out)
end

-- CBC with strict PKCS#7 validation, used by text-only source extensions.
function AES.decrypt_cbc(key, data, iv)
    if type(iv) ~= "string" or #iv ~= 16 or type(data) ~= "string"
            or #data == 0 or #data % 16 ~= 0 then return nil, "无效的 CBC 数据" end
    local decoded_all, err = AES.decrypt_ecb(key, data)
    if not decoded_all then return nil, err end
    local out, previous = {}, iv
    for pos = 1, #data, 16 do
        local block = data:sub(pos, pos + 15)
        local decoded = decoded_all:sub(pos, pos + 15)
        local bytes = {}
        for i = 1, 16 do bytes[i] = string.char(bxor(decoded:byte(i), previous:byte(i))) end
        out[#out + 1] = table.concat(bytes)
        previous = block
    end
    local plain = table.concat(out)
    local pad = plain:byte(-1)
    if pad < 1 or pad > 16 or plain:sub(-pad) ~= string.rep(string.char(pad), pad) then
        return nil, "无效的 CBC 填充"
    end
    return plain:sub(1, -pad - 1)
end

return AES
