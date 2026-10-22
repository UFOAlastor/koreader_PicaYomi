-- network/http_client.lua
-- 通用 HTTP 客户端
-- 从 api/http.lua 重构，分离通用 HTTP 与源专属逻辑

local socket_http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local logger = require("util.logger")
local json = require("rapidjson")
local Redact = require("util.log_redact")

local HttpClient = {}

--- 发送 HTTP 请求
-- @param method: "GET"/"POST"/"PUT"/"DELETE"
-- @param url: 完整 URL
-- @param headers: 请求头表
-- @param body: 请求体 (字符串或 nil)
-- @param timeout: 超时秒数 (默认 10)
-- @return: response 表 { status_code, headers, body } 或 nil, err
function HttpClient:request(method, url, headers, body, timeout)
    local Async = require("network.async_task")
    if Async.active() then
        return Async.await(function() return self:request(method, url, headers, body, timeout) end)
    end
    timeout = timeout or 10
    method = string.upper(method or "GET")

    -- dbg: 每个 API 请求一行。info 级会在一次正常浏览里刷几十行, 把真正重要的
    -- 生命周期日志 (打开/关闭/崩溃前) 埋掉; 排查网络时打开 KOReader 的调试日志即可。
    -- URL 必须脱敏: query 里常有签名/token, 日志会被用户导出贴出来。
    if logger.enabled then logger.dbg("Picayomi HttpClient: " .. method .. " " .. Redact.url(url)) end

    -- 准备请求体
    local source = nil
    local request_headers = headers or {}

    if body then
        if type(body) == "table" then
            body = json.encode(body)
        end
        request_headers["Content-Length"] = tostring(#body)
        source = ltn12.source.string(body)
    end

    -- 响应容器
    local response_body = {}

    -- 构造请求
    local request = {
        url = url,
        method = method,
        headers = request_headers,
        source = source,
        sink = ltn12.sink.table(response_body),
        redirect = true,
    }

    -- 设置超时
    socket_http.TIMEOUT = timeout
    -- socket.http 的 HTTPS 连接由 LuaSec 创建; 其 settimeout 会读取自身 TIMEOUT,
    -- 忽略 socket.http 传入的值。只设置上面一项会让 JM 的 15 秒仍按默认 60 秒等待。
    if url:match("^https://") then
        require("ssl.https").TIMEOUT = timeout
    end

    -- 发送请求
    local ok, code, resp_headers = socket_http.request(request)

    if not ok then
        local reason = Redact.text(code)
        logger.err("Picayomi HttpClient: 请求失败: " .. reason)
        return nil, "HTTP请求失败: " .. reason
    end

    -- 处理重定向
    if type(code) == "table" then
        -- 某些情况下 socket.http 返回 (1, status_table, headers)
        resp_headers = code
        code = resp_headers and resp_headers.code or 200
    end

    local body_str = table.concat(response_body)

    if logger.enabled then logger.dbg("Picayomi HttpClient: 响应状态码: " .. tostring(code) ..
        ", 响应大小: " .. #body_str .. " 字节") end

    return {
        status_code = code,
        headers = resp_headers,
        body = body_str,
    }
end

--- 判断是否为 TLS 层错误
-- 这类错误是**确定性**的 (证书不受信/握手失败/协议不兼容), 重试只会多冻一次
-- 界面, 更不能降级到明文 HTTP —— 那等于把 Authorization/Cookie 明文发出去。
-- 保留这个判定只为了给出明确、可排查的错误信息。
local function is_tls_error(err)
    if not err then return false end
    local e = tostring(err):lower()
    return e:find("ssl", 1, true) ~= nil
        or e:find("tls", 1, true) ~= nil
        or e:find("certificate", 1, true) ~= nil
        or e:find("handshake", 1, true) ~= nil
        or e:find("protocol", 1, true) ~= nil
end
HttpClient.isTlsError = is_tls_error

--- 发送 HTTPS 请求 (失败时重试一次, **绝不降级到明文 HTTP**)
--
-- 历史: 早期 Kindle 的 LuaSec 不支持 TLS 1.2, 这里曾把 TLS 错误自动改成
-- http:// 再发一次。现在三个源的 API/图片入口都支持 HTTPS, 目标设备
-- (Kindle PW5) 也支持 TLS 1.2 —— 自动降级只剩坏处:
--   * 带 Authorization/Cookie/token 的请求会以明文重发 (中间人可直接截获);
--   * 证书错误被"降级成功"掩盖, 用户以为一切正常。
-- 因此 TLS 失败时直接报错, 由用户/日志定位证书或协议问题。
--
-- 注意: KOReader 的 Lua 是单线程的, 这里每多等一轮超时,
-- 界面就多冻结同样长的时间, 因此非 TLS 失败也只重试一次。
-- @return: response 表 或 nil, err
function HttpClient:requestWithRetry(method, url, headers, body, timeout)
    local Async = require("network.async_task")
    if Async.active() then
        return Async.await(function() return self:requestWithRetry(method, url, headers, body, timeout) end)
    end
    if url:match("^https://") then
        local last_reason
        local attempts = 2

        for attempt = 1, attempts do
            local ok, result, err = pcall(function()
                return self:httpsRequest(method, url, headers, body, timeout)
            end)

            if ok and result then
                return result
            end

            last_reason = (not ok) and tostring(result) or tostring(err)

            if is_tls_error(last_reason) then
                local reason = Redact.text(last_reason)
                logger.err("Picayomi HttpClient: TLS 失败, 不降级: " .. reason)
                return nil, "HTTPS 请求失败 (TLS): " .. reason
            end

            if attempt < attempts then
                logger.warn("Picayomi HttpClient: HTTPS 请求失败(" ..
                    Redact.text(last_reason) .. ")，第 " ..
                    (attempt + 1) .. "/" .. attempts .. " 次重试")
                socket.sleep(0.3 * attempt)
            end
        end

        return nil, "HTTPS 请求失败: " .. Redact.text(last_reason)
    end

    -- 显式给出的 HTTP 地址仍按原样请求 (是否允许由调用方决定);
    -- 但**自动**降级已删除 —— 只有这里收到的才是 http://.
    return self:request(method, url, headers, body, timeout)
end



--- 单次 HTTPS 请求 (不处理重定向)
-- luasec 的 ssl.https.request 明确不支持 redirect/proxy/create 选项，
-- 传入 redirect 会直接返回 "redirect not supported" 错误。
--
-- @param sink 可选: 传入时响应体**直接交给它**(如写文件), 返回值里不带 body。
--             下载大图必须走这条 —— 否则整张图会先被拼成一个 Lua 字符串。
-- @return: { status_code, headers, body } 或 nil, err
function HttpClient:_httpsOnce(method, url, headers, body, timeout, sink)
    local https = require("ssl.https")

    local source = nil
    local request_headers = {}
    for k, v in pairs(headers or {}) do
        request_headers[k] = v
    end

    local payload = body
    if payload then
        if type(payload) == "table" then
            payload = json.encode(payload)
        end
        request_headers["Content-Length"] = tostring(#payload)
        source = ltn12.source.string(payload)
    end

    local response_body = {}
    local request = {
        url = url,
        method = string.upper(method or "GET"),
        headers = request_headers,
        source = source,
        sink = sink or ltn12.sink.table(response_body),
        -- 注意: 不要设置 redirect (luasec 不支持)
    }

    https.TIMEOUT = timeout or 10
    local ok, code, resp_headers = https.request(request)
    if not ok then
        return nil, tostring(code)
    end

    return {
        status_code = code,
        headers = resp_headers,
        body = (not sink) and table.concat(response_body) or nil,
    }
end

--- HTTPS 请求 (使用 ssl.https，手动跟随重定向)
function HttpClient:httpsRequest(method, url, headers, body, timeout)
    timeout = timeout or 10
    method = string.upper(method or "GET")

    local current_url = url
    local current_method = method
    local current_body = body

    -- 手动跟随重定向 (最多 5 次)
    for _ = 1, 5 do
        local result, err = self:_httpsOnce(current_method, current_url, headers, current_body, timeout)
        if not result then
            return nil, "HTTPS请求失败: " .. tostring(err)
        end

        local code = result.status_code
        local location = result.headers and result.headers.location
        if code and code >= 300 and code < 400 and location then
            -- 处理相对路径重定向
            if location:match("^/") then
                local origin = current_url:match("^(https?://[^/]+)")
                location = (origin or "") .. location
            end
            if logger.enabled then logger.dbg("Picayomi HttpClient: HTTPS 重定向 -> " .. Redact.url(location)) end
            current_url = location
            -- 301/302/303 后按惯例改为 GET
            if code == 303 or ((code == 301 or code == 302) and current_method == "POST") then
                current_method = "GET"
                current_body = nil
            end
        else
            return result
        end
    end

    return nil, "HTTPS请求失败: 重定向次数过多"
end

--- GET 请求
function HttpClient:get(url, headers, timeout)
    return self:requestWithRetry("GET", url, headers, nil, timeout)
end

--- POST 请求
function HttpClient:post(url, headers, body, timeout)
    return self:requestWithRetry("POST", url, headers, body, timeout)
end

--- 下载文件到指定路径
-- @param url: 下载 URL
-- @param dest_path: 目标文件路径
-- @param headers: 请求头
-- @param timeout: 超时秒数 (默认 30)
-- @param retries: 快速失败时的额外重试次数 (默认 1)
-- @return: true 或 nil, err
function HttpClient:_downloadOnce(url, dest_path, response_headers, timeout, pool)
    -- 确保目标目录存在
    -- 直接用 mkdir -p: 之前的逐级拼接对 "./xxx" 这类相对路径会错误地
    -- 生成 "/xxx" (根目录) 从而创建失败
    local dir = dest_path:match("(.*/)")
    if dir then
        local lfs = require("libs/libkoreader-lfs")
        if not lfs.attributes(dir, "mode") then
            os.execute("mkdir -p \"" .. dir .. "\"")
        end
    end

    -- 响应体**边收边写文件**, 不先读进内存。
    --
    -- 旧实现是 ltn12.sink.table(response_body) 收完再 table.concat: 一张 2MB 的
    -- 漫画页会同时存在"chunk 表 + 拼接出的字符串"(HTTPS 路径在 _httpsOnce 里还有
    -- 一份 body), 单次下载峰值约为图片大小的 2~3 倍。设备可用内存只有 ~130MB,
    -- 而这是**每张图**都要来一遍的峰值 —— 真机上就是"翻页时被 OOM 盯上"的窗口。
    --
    -- 句柄放在一张小表里: 跟随重定向时要换成**新的(被截断的)**句柄, 复用旧句柄
    -- 会在"重定向响应体比最终响应体长"时把尾巴残留在文件里 (给图片粘上几字节 HTML)。
    local out = { fh = io.open(dest_path, "wb") }
    if not out.fh then
        return nil, "无法创建文件: " .. dest_path, false
    end

    local written = 0
    local sink = function(chunk)
        if chunk then
            written = written + #chunk
            local wok, werr = out.fh:write(chunk)
            if not wok then return nil, werr end
        end
        return 1
    end

    --- 重开 (截断) 目标文件, 丢弃已经写进去的重定向响应体
    local function restart_file()
        out.fh:close()
        out.fh = io.open(dest_path, "wb")
        written = 0
        return out.fh ~= nil
    end

    --- 发一次 GET, **不跟随重定向** (响应体交给 sink)
    --
    -- 两条协议都自己跟跳转, 不用 socket.http 的 redirect=true: 它复用**同一个
    -- sink**, 也就是把 302 的响应体写在前面、最终响应体接在后面。图片文件开头
    -- 于是是一段 HTML, 解码必然失败 (真机表现: 这页永远"加载中", 而且每次翻回
    -- 来都重下一遍)。HTTPS 那边早就因为 luasec 不支持 redirect 而手动跟了,
    -- 明文这条一直漏着 —— 两个分支必须同形。
    local function fetch_once(target_url)
        -- 有连接池就走复用路径 (keep-alive)。池自己解析响应定界并把 body 交给
        -- 同一个 sink; 状态码/重定向/落盘判定全部留在本函数里, 两条路径同形。
        -- 复用省下的是**每张图一次 DNS+TCP+TLS**: 实测 0.43s/张 (Mac),
        -- Kindle 上更贵 —— 一话 20 页就是好几秒 (见 network/http_conn.lua)。
        if pool then
            local resp, perr = pool:get(target_url, response_headers, sink)
            if not resp then return nil, tostring(perr) end
            return resp
        end
        if target_url:match("^https://") then
            return self:_httpsOnce("GET", target_url, response_headers, nil, timeout, sink)
        end
        socket_http.TIMEOUT = timeout
        local ok2, code2, headers2 = socket_http.request{
            url = target_url,
            method = "GET",
            headers = response_headers,
            sink = sink,
            redirect = false,
        }
        if not ok2 then return nil, tostring(code2) end
        return { status_code = code2, headers = headers2 }
    end

    --- 跟随重定向 (最多 5 跳); 每跳之前截断文件, 丢掉上一跳的响应体
    local function follow(start_url)
        local current_url = start_url
        local result, last_err
        local hops = 0
        for _attempt = 1, 5 do
            local r, e = fetch_once(current_url)
            result, last_err = r, e
            if not r then break end
            local rcode = tonumber(r.status_code) or 0
            local location = r.headers and r.headers.location
            if rcode >= 300 and rcode < 400 and location then
                location = HttpClient.resolveLocation(current_url, location)
                -- 解析不出来 (base_url 不合法) 就别往下走了: 交给非 2xx 分支报状态码
                if not location then break end
                if not restart_file() then
                    return nil, "无法创建文件: " .. dest_path
                end
                hops = hops + 1
                current_url = location
            else
                break
            end
        end
        return result, last_err, hops
    end

    local result, last_dl_err, hops = follow(url)

    if not result then
        out.fh:close()
        os.remove(dest_path)
        local reason = Redact.text(last_dl_err)
        -- TLS 失败是确定性的, 且**绝不能**改成 http:// 重下 (图床 URL 里可能有
        -- 签名; 阅读页请求还带着 Referer/Cookie)。明确报错, 让证书问题可见。
        if is_tls_error(last_dl_err) then
            logger.err("Picayomi HttpClient: 下载 TLS 失败, 不降级: " .. reason)
            return nil, "下载失败 (TLS): " .. reason, false
        end
        return nil, "下载失败: " .. reason, true
    end

    -- 5 跳用完还在重定向: 不能把最后一跳的响应体当图片发布
    -- (没有 location 的 3xx 不算"次数过多", 交给下面的非 2xx 分支报真实状态码)
    local status = tonumber(result.status_code) or 0
    if status >= 300 and status < 400 and hops >= 5 then
        out.fh:close()
        os.remove(dest_path)
        return nil, "下载失败: 重定向次数过多", false
    end

    -- 非 2xx 一律当失败, 且必须在**发布之前**拦住 (判定集中在 check_download,
    -- 并发下载那条路径用的是同一份规则)。
    --
    -- 真机现场: 图床在 Referer/签名过期时回的是 404/403 + 一张 HTML 错误页,
    -- Cloudflare 回源失败时是 520/522 + HTML。旧实现只看"收到了字节", 于是把
    -- 这页 HTML 原子改名成 0001.jpg —— 绘制链解码失败 -> 判坏缓存 -> 删掉重下,
    -- 每翻回这一页就重下一遍, 用户看到的是"这页永远加载中"。
    --
    -- 4xx 是永久失败 (重试只会白等), 5xx 属瞬时 (值得按预算重试一次)。
    local vok, verr, vtransient = self:check_download(status, written)
    if not vok then
        out.fh:close()
        os.remove(dest_path)
        return nil, verr, vtransient
    end

    out.fh:close()
    return true, written, false
end

--- 下载结果判定 (纯规则, 不碰文件)
--
-- **两条下载路径共用**: 阻塞式 (本文件的 download) 与子进程里的并发调度
-- (network/download_async.lua)。这类"错的东西被当成对的东西"的判定只允许有
-- 一份 —— v0.9.12 的 404 错误页就是"HTTPS 修了、明文那条还漏着"。
--
-- @return true | nil, err, transient (true = 值得按瞬时失败重试)
function HttpClient:check_download(status, written)
    status = tonumber(status) or 0
    if status < 200 or status >= 300 then
        logger.warn("Picayomi HttpClient: 下载返回 HTTP " .. tostring(status) ..
            ", 丢弃响应体 (" .. tostring(written) .. " 字节)")
        return nil, "HTTP " .. tostring(status), status >= 500
    end
    if (written or 0) == 0 then
        return nil, "下载数据为空", true
    end
    return true
end

--- 判定 + 原子发布 (临时文件 -> 最终路径)
-- @return ok, size, err, transient
function HttpClient:publish_download(tmp_path, dest_path, status, written)
    local ok, err, transient = self:check_download(status, written)
    if not ok then
        os.remove(tmp_path)
        return nil, err, transient
    end
    local rok, rerr = os.rename(tmp_path, dest_path)
    if not rok then
        os.remove(tmp_path)
        return nil, "改名失败: " .. tostring(rerr), false
    end
    return true, written, false
end

--- 下载到文件
-- @param pool 可选: network/http_conn 的连接池。传了就走 keep-alive 复用,
--             不传则每次新建连接 (旧行为, 也便于离线用例注入假 socket)。
-- 重试策略只覆盖"瞬时失败":
--   1. 快速失败 (耗时 < 2s) —— 疑似瞬时抖动
--   2. 连接被对端关闭/重置 —— 立刻返回, 重试成本极低
--      (实测部分图片 CDN 会对同一出口 IP 做短时速率限制, 掐断连续请求;
--       递增退避后可以恢复)
-- 慢失败多为超时, 重试只会让界面冻结翻倍, 因此不重试。
-- 另外有总耗时上限, 保证最坏情况下不会长时间卡住界面。
local RETRY_BUDGET_SECONDS = 6
local RETRY_BASE_DELAY = 0.4

--- 下载过程中的临时后缀 (最终路径 = 去掉它)
--
-- **为什么必须写临时文件再改名**: _downloadOnce 是"边收边写"的 (见那里的注释),
-- 而阅读页的校验 (network/download_manager.lua 的 find_existing_image) 会在**同一
-- 时间**、从绘制链上反复查同一个路径。直接写最终路径时, 校验会看到"刚创建、还是
-- 0 字节"或"只写了一半"的文件, 判无效 -> os.remove -> 在途下载继续往一个已被删除的
-- inode 里写, 最后报 "No such file or directory"。
--
-- 真机证据 (2026-10-17 diag.log + crash.log): 81 次 "缓存不是有效图片, 已丢弃重下"
-- 里有 36 次紧跟着**同一页**的 "下载失败: No such file or directory"; 第 1 页
-- 13:42:58 开始下载, 13:43:01 失败, 直到 13:44:34 用户翻走再翻回来才落盘 —— 96 秒
-- 卡在"加载中…"。用户报的"第一页容易持续卡加载中"就是这条。
--
-- 改名在同一目录内是原子的, 所以最终路径上只会出现**完整**的文件; 也顺带修掉
-- "只写了一半但文件头合法的图" (crash.log 里的 "无法解码")。
HttpClient.DOWNLOAD_TMP_SUFFIX = ".part"

function HttpClient:download(url, dest_path, headers, timeout, retries, pool)
    timeout = timeout or 30
    retries = retries or 2
    -- 每张图都会打, 属高频噪音 -> dbg (默认不输出)
    if logger.enabled then logger.dbg("Picayomi HttpClient: 下载 " .. Redact.url(url) .. " → " .. dest_path) end

    -- 真正的写入目标是临时文件, 成功后原子改名 (见 DOWNLOAD_TMP_SUFFIX)
    local tmp_path = dest_path .. HttpClient.DOWNLOAD_TMP_SUFFIX

    local response_headers = headers or {}
    response_headers["Accept"] = response_headers["Accept"] or "image/*,*/*;q=0.8"
    response_headers["Connection"] = response_headers["Connection"] or "close"

    local now = function()
        return socket.gettime and socket.gettime() or os.clock()
    end

    local total_t0 = now()
    local attempt = 0
    local delay = RETRY_BASE_DELAY

    while true do
        attempt = attempt + 1
        local t0 = now()
        local ok, size, transient = self:_downloadOnce(url, tmp_path, response_headers, timeout, pool)
        if ok then
            -- 原子发布: 只有**完整**文件才会出现在最终路径上 (见 DOWNLOAD_TMP_SUFFIX)
            local rok, rerr = os.rename(tmp_path, dest_path)
            if not rok then
                os.remove(tmp_path)
                return nil, "改名失败: " .. tostring(rerr)
            end
            if logger.enabled then logger.dbg("Picayomi HttpClient: 下载完成, " .. tostring(size) .. " 字节") end
            return true, size
        end
        -- 失败不留残file (_downloadOnce 删的是它自己写的那个路径, 这里兜一次)
        os.remove(tmp_path)

        local elapsed = now() - t0
        local msg = type(size) == "string" and size or ""
        local conn_drop = msg:find("closed", 1, true) ~= nil
            or msg:find("reset", 1, true) ~= nil
            or msg:find("broken pipe", 1, true) ~= nil

        local within_budget = (now() - total_t0) < RETRY_BUDGET_SECONDS
        if transient and attempt <= retries and (elapsed < 2 or conn_drop) and within_budget then
            logger.warn(string.format(
                "Picayomi HttpClient: 下载可重试(%.2fs, %s), 第 %d/%d 次",
                elapsed, Redact.text(msg), attempt + 1, retries + 1))
            socket.sleep(delay)
            delay = delay * 3
        else
            return nil, size
        end
    end
end

--- 解析 JSON 响应
-- @param response: { status_code, headers, body }
-- @return: 解析后的表 或 nil, err
function HttpClient:parseJsonResponse(response)
    if not response or not response.body or response.body == "" then
        return nil, "空响应体"
    end

    local ok, result = pcall(json.decode, response.body)
    -- rapidjson 对某些非法输入不抛错, 而是**直接返回 nil**; 只判 pcall 的话
    -- 上层拿到的是"没数据也没原因", 日志里什么都查不到。
    if not ok or result == nil then
        logger.err("Picayomi HttpClient: JSON解析失败: " .. tostring(result))
        return nil, "JSON解析失败"
    end

    return result
end

--- 把 Location 解析成绝对地址 (**纯函数, 不发请求**)
--
-- 两条下载路径 (阻塞式 follow / 子进程里的 download_async) 共用这一份规则 ——
-- "跳转怎么算"只允许有一个答案。曾经各自内联过一遍, 于是并发那条忘了跟跳转:
-- 源 A 把图床换到 img.源站 之后, storage1 一律回 301, 阻塞路径照常
-- (封面/详情能用), 而**阅读页**每页都 HTTP 301 失败, 整话加载不出来。
--
-- 四种写法都要认 (RFC 3986 §5.2 里实际会遇到的):
--   https://h/p   绝对地址
--   //h/p         协议相对
--   /p            站内绝对路径
--   p             相对当前目录
-- @return 绝对地址 或 nil (location 为空/非法)
function HttpClient.resolveLocation(base_url, location)
    if type(location) ~= "string" or location == "" then return nil end
    if location:match("^https?://") then return location end
    local scheme, origin = base_url:match("^(https?)://([^/]+)")
    if not scheme then return nil end
    if location:sub(1, 2) == "//" then
        return scheme .. ":" .. location
    end
    if location:sub(1, 1) == "/" then
        return scheme .. "://" .. origin .. location
    end
    -- 相对路径: 按当前 URL 所在目录解析 ("a/b/c.jpg" + "d.jpg" -> "a/b/d.jpg")
    local dir = base_url:match("^(.*/)")
    if not dir then return scheme .. "://" .. origin .. "/" .. location end
    return dir .. location
end

--- 处理重定向 (会真的发请求; 只在需要"先探一下最终地址"时用)
-- @param url: 原始 URL
-- @param max_redirects: 最大重定向次数 (默认 5)
-- @return: 最终 URL
function HttpClient:resolveRedirect(url, max_redirects)
    max_redirects = max_redirects or 5
    local redirect_count = 0

    while redirect_count < max_redirects do
        local response_body = {}
        local request = {
            url = url,
            method = "GET",
            headers = { ["Connection"] = "close" },
            sink = ltn12.sink.table(response_body),
            redirect = false,
        }

        socket_http.TIMEOUT = 5
        local _, code, resp_headers = socket_http.request(request)

        if code and code >= 300 and code < 400 and resp_headers and resp_headers.location then
            url = resp_headers.location
            redirect_count = redirect_count + 1
            if logger.enabled then logger.dbg("Picayomi HttpClient: 重定向到 " .. Redact.url(url)) end
        else
            break
        end
    end

    return url
end

--- 修复图片 URL
-- @param url: 原始 URL
-- @return: 修复后的 URL
function HttpClient:fixImageUrl(url)
    if not url then return url end

    -- URL 编码空格
    url = url:gsub(" ", "%%20")

    -- 修复重复的 /static/static/
    url = url:gsub("static/static/", "static/")

    return url
end

return HttpClient
