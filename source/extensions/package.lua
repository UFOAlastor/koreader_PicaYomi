-- Text-only extension bundles. Validation never executes extension code.
local json = require("rapidjson")
local Bundle = { API_VERSION = 3, MAX_BYTES = 2 * 1024 * 1024, MAX_FILES = 64 }
local builtin = { picacg = true, jm = true, htcomic = true }

function Bundle.version(v)
    if type(v) ~= "string" then return nil end
    local a, b, c = v:match("^(%d+)%.(%d+)%.(%d+)$")
    if not a or #v > 32 then return nil end
    return { tonumber(a), tonumber(b), tonumber(c) }
end

function Bundle.compare(a, b)
    a, b = Bundle.version(a), Bundle.version(b)
    assert(a and b, "版本必须为三段数字")
    for i = 1, 3 do
        if a[i] ~= b[i] then return a[i] < b[i] and -1 or 1 end
    end
    return 0
end

function Bundle.id(id)
    return type(id) == "string" and #id <= 80
        and id:match("^[a-z][a-z0-9_%-]*$") ~= nil
end

function Bundle.legacy(id) return builtin[id] == true end

function Bundle.path(path)
    return type(path) == "string" and #path <= 160
        and path:match("^[%w_%-/]+%.lua$") ~= nil
        and path:sub(1, 1) ~= "/" and not path:find("//", 1, true)
end

function Bundle.manifest(m, host_version, allow_incompatible)
    assert(type(m) == "table" and Bundle.id(m.id), "无效的源 ID")
    assert(type(m.name) == "string" and #m.name > 0 and #m.name <= 160, "源名称无效")
    assert(type(m.author) == "string" and #m.author > 0 and #m.author <= 200, "作者无效")
    assert(Bundle.version(m.version), "源版本无效")
    assert(type(m.api_version) == "number" and m.api_version >= 1
        and m.api_version == math.floor(m.api_version), "源 API 版本无效")
    assert(allow_incompatible or (m.api_version>=1 and m.api_version<=Bundle.API_VERSION), "不兼容的源 API 版本")
    assert(Bundle.version(m.min_app_version), "最低主程序版本无效")
    assert(allow_incompatible or Bundle.compare(host_version, m.min_app_version) >= 0, "请先升级 PicaYomi")
    if m.max_app_version then
        assert(Bundle.version(m.max_app_version) and Bundle.compare(m.max_app_version,m.min_app_version)>=0, "最高主程序版本无效")
        assert(allow_incompatible or Bundle.compare(host_version,m.max_app_version)<=0, "此源不支持当前主程序版本")
    end
    if m.api_version>=2 then
        assert(type(m.publisher_id)=="string" and m.publisher_id:match("^[%w_%.%-]+$") and #m.publisher_id<=100, "发布者身份无效")
    end
    if m.api_version==3 then
        assert(Bundle.compare(m.min_app_version,"0.10.6")>=0,"API v3 最低主程序版本为 0.10.6")
    end
    assert(m.identity_policy==nil or m.identity_policy=="stable" or m.identity_policy=="legacy", "章节身份策略无效")
    assert(m.identity_policy~="legacy" or builtin[m.id], "历史身份仅用于旧源")
    for _,key in ipairs({"data_schema_version","cache_schema_version"}) do
        assert(m[key]==nil or type(m[key])=="number" and m[key]>=1 and m[key]%1==0, "数据版本无效")
    end
    assert(Bundle.path(m.entry), "入口路径无效")
    assert(m.settings == nil or type(m.settings) == "table" and #m.settings <= 16, "源设置无效")
    if m.api_version==3 and m.settings then
        assert(pcall(require("source.contract").array,m.settings,"manifest.settings"),"源设置必须为连续数组")
    end
    local keys = {}
    for _, field in ipairs(m.settings or {}) do
        assert(type(field) == "table" and type(field.key) == "string"
            and field.key:match("^[a-z][a-z0-9_]*$") and #field.key <= 64
            and type(field.title) == "string" and #field.title <= 160
            and type(field.default) == "string" and #field.default <= 2048
            and not keys[field.key], "源设置字段无效")
        keys[field.key] = true
    end
    return m
end

function Bundle.decode(raw, host_version)
    assert(type(raw) == "string" and #raw <= Bundle.MAX_BYTES, "源包过大")
    local pkg = json.decode(raw)
    assert(type(pkg) == "table" and pkg.format == 1, "源包格式无效")
    Bundle.manifest(pkg.manifest, host_version)
    assert(type(pkg.files) == "table", "缺少源文件")
    local count, folded = 0, {}
    for path, code in pairs(pkg.files) do
        count = count + 1
        assert(count <= Bundle.MAX_FILES and Bundle.path(path), "文件数量或路径无效")
        assert(not folded[path:lower()], "重复文件路径")
        folded[path:lower()] = true
        assert(type(code) == "string" and code:byte(1) ~= 27 and not code:find("\0", 1, true),
            "源包只允许 Lua 文本")
        assert(loadstring(code, "@extension/" .. path), "Lua 语法错误: " .. path)
    end
    assert(count > 0 and pkg.files[pkg.manifest.entry], "缺少入口文件")
    return pkg
end

return Bundle
