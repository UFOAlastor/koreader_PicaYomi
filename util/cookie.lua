-- util/cookie.lua
-- Cookie 解析：把一个可能含**多个** cookie 的 set-cookie 头拆开并合入 jar。
--
-- 为什么需要单独处理：服务端会把多个 cookie 塞进同一个 set-cookie 头，
-- 用逗号分隔：
--   "ipcountry=HK; path=/, ipm5=xxx; path=/, AVS=yyy; path=/"
-- 而 expires 里的日期**本身也含逗号**：
--   "theme=light; expires=Fri, 09-Apr-2027 12:00:34 GMT; Max-Age=...; path=/"
-- 所以不能简单地按逗号切分，否则会话 cookie 会被漏掉 ——
-- 表现就是"登录成功了，但收藏等需要登录的接口全部 401 / 返回空"。

local Cookie = {}

--- 把一个 set-cookie 值拆成多条 cookie 字符串
function Cookie.splitSetCookie(raw)
    local out = {}
    if type(raw) ~= "string" or raw == "" then return out end

    local start = 1
    local i = 1
    while i <= #raw do
        if raw:sub(i, i) == "," then
            -- 只有"逗号后面紧跟 name=" 才是新 cookie 的起点;
            -- "Fri, 09-Apr-2027" 这种日期不匹配, 自然不会被切开。
            local rest = raw:sub(i + 1):gsub("^%s*", "")
            if rest:match("^[%w_%-%.]+=") then
                table.insert(out, raw:sub(start, i - 1))
                start = i + 1
            end
        end
        i = i + 1
    end
    table.insert(out, raw:sub(start))
    return out
end

--- 从一条 cookie 字符串里取出 name=value
function Cookie.parseOne(entry)
    local name, value = tostring(entry):match("^%s*([^=;%s]+)=([^;]*)")
    if name and name ~= "" then
        return name, value or ""
    end
    return nil
end

--- 把响应头里的 set-cookie 合入 jar
-- @param jar     形如 { name = value }
-- @param headers 响应头表 (大小写不敏感地尝试 set-cookie)
-- @return 本次新吸收的 cookie 个数
function Cookie.absorb(jar, headers)
    if type(jar) ~= "table" or type(headers) ~= "table" then return 0 end

    local raw = headers["set-cookie"] or headers["Set-Cookie"]
    if not raw then return 0 end

    local headers_list = type(raw) == "table" and raw or { raw }
    local n = 0
    for _idx, entry in ipairs(headers_list) do
        for _i, one in ipairs(Cookie.splitSetCookie(tostring(entry))) do
            local name, value = Cookie.parseOne(one)
            if name then
                jar[name] = value
                n = n + 1
            end
        end
    end
    return n
end

--- 把 jar 拼成请求用的 Cookie 头
function Cookie.toHeader(jar)
    if type(jar) ~= "table" then return nil end
    local parts = {}
    for k, v in pairs(jar) do
        table.insert(parts, k .. "=" .. v)
    end
    if #parts == 0 then return nil end
    return table.concat(parts, "; ")
end

return Cookie
