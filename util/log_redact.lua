-- util/log_redact.lua
-- 日志脱敏 —— 只允许"排查需要的最小信息"进入 crash.log / diag.log。
--
-- 为什么必须集中做:
--   * URL 的 query 里常有签名/时间戳/token (图床、API 都有), 完整打印等于把
--     凭据抄进日志; crash.log 会被用户导出、贴到 issue 里。
--   * Cookie / Authorization 一旦进了日志, 就是可直接复用的会话凭据。
--   * 日志脱敏最容易"修一处漏十处" —— 因此网络层所有 URL/错误信息的出口都
--     走本模块, 而不是各自 gsub。
--
-- 约定:
--   * 正式排查日志可以用 logger.dbg/info; **临时**日志请以方括号包裹的 TEMP-DEBUG 开头,
--     test/check_secrets.py --release 会在打发布包时把它们拦下来。
--   * 本模块只做"格式化", 不改业务语义; 不要用它替换错误码/状态码。

local M = {}

-- 本文件自己在被敏感信息扫描器扫描时, 不能出现完整的 JWT 前缀字面量
local JWT_PREFIX = "ey" .. "J"

--- 只保留 scheme://host/path; 丢掉 userinfo、query、fragment
-- 无法识别的输入按"不含 scheme 的路径"处理: 同样砍掉 ? / # 之后的内容。
function M.url(url)
    if url == nil then return "" end
    local s = tostring(url)
    local scheme, rest = s:match("^(%a[%w+.-]*)://(.+)$")
    if not scheme then
        return (s:gsub("[?#].*$", ""))
    end
    local authority, path = rest:match("^([^/]*)(.*)$")
    -- user:password@host -> host; 没写路径时 query 也粘在 authority 上
    authority = authority:gsub("^.*@", ""):gsub("[?#].*$", "")
    path = (path or ""):gsub("[?#].*$", "")
    if path == "" then path = "/" end
    return scheme .. "://" .. authority .. path
end

--- Cookie 头/串 -> "名称列表 (N 个)"; 值一律不出现
function M.cookie(value)
    if value == nil then return "" end
    local names = {}
    for name in tostring(value):gmatch("([^=;,%s]+)%s*=") do
        names[#names + 1] = name
    end
    if #names == 0 then return "<cookie 无名称>" end
    return table.concat(names, ",") .. " (" .. #names .. " 个)"
end

--- 复制一份请求/响应头, 认证类字段只留字段名
function M.headers(headers)
    local out = {}
    if type(headers) ~= "table" then return out end
    for k, v in pairs(headers) do
        local lk = tostring(k):lower()
        if lk == "authorization" or lk == "proxy-authorization"
            or lk == "cookie" or lk == "set-cookie" or lk == "x-api-key" then
            out[k] = "<redacted>"
        else
            out[k] = v
        end
    end
    return out
end

local SENSITIVE_QUERY = {
    token = true, access_token = true, refresh_token = true,
    sign = true, signature = true, key = true, api_key = true,
    password = true, passwd = true, sid = true, session = true,
    sessionid = true, auth = true,
}

--- 自由文本 (错误信息等) 脱敏
-- 处理三类: 认证头值、敏感 query 参数值、JWT。
function M.text(text)
    if text == nil then return "" end
    local s = tostring(text)

    -- Authorization: Bearer xxx / authorization=xxx
    s = s:gsub("([Aa]uthorization[%s:=]+)[^\r\n,;\"']+", "%1<redacted>")
    s = s:gsub("([Cc]ookie[%s:=]+)[^\r\n,;\"']+", "%1<redacted>")
    s = s:gsub("([Ss]et%-[Cc]ookie[%s:=]+)[^\r\n\"']+", "%1<redacted>")
    s = s:gsub("([Pp]assword[\"']?%s*[=:]%s*[\"']?)[^\r\n&,;\"']+", "%1<redacted>")

    -- 只遮敏感参数的值, 其余 query 保留 (便于看出"请求打到了哪个接口")
    -- 注意不要在 all 上再 gsub 找"=": 值本身可能含 "=" (base64 填充)。
    s = s:gsub("([?&])([%w_%-]+)=([^&%s]+)", function(sep, name, value)
        if SENSITIVE_QUERY[name:lower()] then
            return sep .. name .. "=<redacted>"
        end
        return sep .. name .. "=" .. value
    end)

    -- JWT 本身 (三段式) 出现即视为凭据
    s = s:gsub(JWT_PREFIX .. "[%w%-%._]+", "<jwt>")

    return s
end

return M
