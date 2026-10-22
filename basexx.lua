--[[
 * basexx - base encoding / decoding of any alphabet (base64, base32, base16)
 *
 * 简化版本：仅实现必要的base64编码和解码功能
 * 基于原版basexx库 (https://github.com/aiq/basexx)
--]]

local basexx = {}

--------------------------------------------------------------------------------
-- 基础函数

local function divide_string(str, max)
    local result = {}
    local start = 1
    for i = 1, #str, max do
        result[#result + 1] = string.sub(str, i, i + max - 1)
    end
    return result
end

local function number_to_bit(num, length)
    local bits = {}
    local remainder

    for i = 1, length do
        remainder = math.floor(math.fmod(num, 2))
        bits[length - i + 1] = remainder
        num = (num - remainder) / 2
    end

    return table.concat(bits)
end

local function ignore_set(str, set)
    if not set then return str end
    local result = ""
    for i = 1, #str do
        local c = str:sub(i,i)
        if not set[c] then
            result = result .. c
        end
    end
    return result
end

local function pure_from_bit(str)
    local result = ""
    local length = #str
    -- 末尾不足 8 位的余数是 base64/base32 的填充产物, 必须丢弃。
    -- 原实现会为这段余数再补一个字节 (内容恒为 0), 于是 `from_base64("...==")`
    -- 总比正确结果多一个 "\0" 尾字节 —— 解码出来的二进制被静默污染。
    length = length - (length % 8)
    for i = 1, length, 8 do
        local c = 0
        for j = 0, 7 do
            local k = i + j
            if str:sub(k,k) == "1" then
                c = c + 2^(7-j)
            end
        end
        result = result .. string.char(c)
    end
    return result
end

--------------------------------------------------------------------------------
-- base64函数

local base64_alphabet = {
    [0] = "A", [1] = "B", [2] = "C", [3] = "D", [4] = "E", [5] = "F", [6] = "G", [7] = "H",
    [8] = "I", [9] = "J", [10] = "K", [11] = "L", [12] = "M", [13] = "N", [14] = "O", [15] = "P",
    [16] = "Q", [17] = "R", [18] = "S", [19] = "T", [20] = "U", [21] = "V", [22] = "W", [23] = "X",
    [24] = "Y", [25] = "Z", [26] = "a", [27] = "b", [28] = "c", [29] = "d", [30] = "e", [31] = "f",
    [32] = "g", [33] = "h", [34] = "i", [35] = "j", [36] = "k", [37] = "l", [38] = "m", [39] = "n",
    [40] = "o", [41] = "p", [42] = "q", [43] = "r", [44] = "s", [45] = "t", [46] = "u", [47] = "v",
    [48] = "w", [49] = "x", [50] = "y", [51] = "z", [52] = "0", [53] = "1", [54] = "2", [55] = "3",
    [56] = "4", [57] = "5", [58] = "6", [59] = "7", [60] = "8", [61] = "9", [62] = "+", [63] = "/"
}

local base64_reverse_alphabet = {}
for k, v in pairs(base64_alphabet) do
    base64_reverse_alphabet[v] = k
end

function basexx.to_base64(str)
    local result = ""
    local bitstr = ""

    for i = 1, #str do
        local c = str:byte(i)
        bitstr = bitstr .. number_to_bit(c, 8)
    end

    -- 填充比特串，使其长度为3的倍数
    local padding = 3 - math.fmod(#str, 3)
    if padding == 3 then padding = 0 end

    for i = 1, padding do
        bitstr = bitstr .. "00000000"
    end

    for i = 1, #bitstr, 6 do
        local bits = bitstr:sub(i, i+5)
        if #bits == 6 then
            local value = tonumber(bits, 2)
            result = result .. base64_alphabet[value]
        end
    end

    if padding == 1 then
        result = result:sub(1, -2) .. "="
    elseif padding == 2 then
        result = result:sub(1, -3) .. "=="
    end

    return result
end

function basexx.from_base64(str)
    str = ignore_set(str, {[" "]=true, ["\t"]=true, ["\n"]=true, ["\r"]=true, ["="]=true})

    local bitstr = ""
    for i = 1, #str do
        local c = str:sub(i,i)
        local value = base64_reverse_alphabet[c]
        if value then
            bitstr = bitstr .. number_to_bit(value, 6)
        end
    end

    return pure_from_bit(bitstr)
end

--------------------------------------------------------------------------------
-- 16进制编码/解码

local hexalphabet = {
    [0] = "0", [1] = "1", [2] = "2", [3] = "3", [4] = "4", [5] = "5", [6] = "6", [7] = "7",
    [8] = "8", [9] = "9", [10] = "a", [11] = "b", [12] = "c", [13] = "d", [14] = "e", [15] = "f"
}

local hex_reverse_alphabet = {}
for k,v in pairs(hexalphabet) do
    hex_reverse_alphabet[v] = k
    hex_reverse_alphabet[string.upper(v)] = k
end

function basexx.to_hex(str)
    local result = ""
    for i = 1, #str do
        local c = str:byte(i)
        local high = math.floor(c / 16)
        local low = c % 16
        result = result .. hexalphabet[high] .. hexalphabet[low]
    end
    return result
end

function basexx.from_hex(str)
    str = ignore_set(str, {[" "]=true, ["\t"]=true, ["\n"]=true, ["\r"]=true})
    local result = ""
    for i = 1, #str, 2 do
        local high = hex_reverse_alphabet[str:sub(i,i)]
        local low = hex_reverse_alphabet[str:sub(i+1,i+1)]
        if high and low then
            result = result .. string.char(high * 16 + low)
        end
    end
    return result
end

return basexx