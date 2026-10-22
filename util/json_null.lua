-- util/json_null.lua
-- 处理 KOReader rapidjson 的 JSON null
--
-- 重要: KOReader 的 rapidjson 把 JSON 的 null 解码成**真值 userdata 哨兵**
-- (类似 cjson.null), 而不是 nil。因此
--     local x = data.field or ""
-- 这种写法**挡不住 null**, 后续 table.concat / 字符串拼接会报
--     "invalid value (userdata) at index N in table for 'concat'"
--
-- 所有从 JSON 取字段并要参与字符串拼接/数值运算的地方, 都应该走这里。

local JsonNull = {}

--- 是否是 JSON null 哨兵
function JsonNull.is(v)
    -- rapidjson 的 null 是 userdata; 正常 JSON 解出的值只可能是
    -- string / number / boolean / table / userdata(null)
    return type(v) == "userdata"
end

--- 安全取字符串; 非字符串一律回退到 default
function JsonNull.str(v, default)
    if type(v) == "string" then return v end
    return default
end

--- 安全取数字; 无法转换时回退
function JsonNull.num(v, default)
    if type(v) == "number" then return v end
    local n = tonumber(v)
    if n then return n end
    return default
end

--- 安全取布尔
function JsonNull.bool(v, default)
    if type(v) == "boolean" then return v end
    return default
end

--- 安全取数组 (只保留合法表)
function JsonNull.list(v)
    if type(v) == "table" then return v end
    return {}
end

--- 把数组里的元素安全转成字符串数组 (丢掉 null / 非字符串)
function JsonNull.str_list(v)
    local out = {}
    if type(v) ~= "table" then return out end
    for _idx, item in ipairs(v) do
        if type(item) == "string" then
            table.insert(out, item)
        elseif type(item) == "number" then
            table.insert(out, tostring(item))
        end
    end
    return out
end

--- 把数组里的元素安全转成数字数组
function JsonNull.num_list(v)
    local out = {}
    if type(v) ~= "table" then return out end
    for _idx, item in ipairs(v) do
        local n = JsonNull.num(item)
        if n then table.insert(out, n) end
    end
    return out
end

return JsonNull
