-- network/http_conn.lua
-- 可复用的 HTTP/1.1 连接 (TLS / 明文) 与按 host 复用的池。
--
-- 为什么需要它:
--   `ssl.https.request` 每次调用都会**重新 DNS + TCP + TLS 握手**。真机实测
--   (2026-10-18, Mac 上同一条链路对比):
--     每张图新建连接: TLS 0.43s + 传输 0.80s = 1.23s
--     复用同一条连接: 首次 0.41s, 之后每张 0.79~1.03s
--   也就是**每张图白白多花 0.4s 左右**(Kindle 的 CPU 更慢, 握手只会更贵)。
--   一话 20 页就是 8 秒, 正好是用户说的"翻页偶尔卡一下"。
--
-- 边界 (故意做得很窄):
--   * 只做 GET, 不跟重定向 (跟跳/状态判定/落盘/改名仍归 network/http_client);
--   * 响应体边收边交给 sink (写文件), 不在内存里拼字符串;
--   * 响应定界交给 network/http_parse (与子进程里的并发调度共用同一套规则);
--   * 任何异常 (超时/半截/协议怪) 都**关掉连接**并报错 —— 绝不复用一条状态
--     不明的连接。调用方 (http_client 的重试循环) 会重新建连再试一次。
--
-- 复用前的健康检查: socket.select 可读 = 对端已经关了 (或有多余数据), 直接丢弃。
-- 这是 keep-alive 唯一必须做对的事 —— 否则下一张图会把上一个响应剩下的字节
-- 当成自己的状态行。

local socket = require("socket")
local logger = require("util.logger")
local Parser = require("network.http_parse")

local Pool = {}
Pool.__index = Pool

Pool.DEFAULT_TIMEOUT = 20
Pool.READ_CHUNK = 16384
Pool.IDLE_TTL = 60
Pool.DNS_TTL = 60

--- 解析 URL -> scheme, host, port, path
-- 只处理 http/https; 其它协议返回 nil。
function Pool.parseUrl(url)
    if type(url) ~= "string" then return nil end
    local scheme, rest = url:match("^(https?)://(.+)$")
    if not scheme then return nil end
    local hostport, path = rest:match("^([^/]+)(/.*)$")
    if not hostport then hostport, path = rest, "/" end
    local host, port = hostport:match("^(.+):(%d+)$")
    if not host then
        host = hostport
        port = (scheme == "https") and 443 or 80
    end
    if host == "" then return nil end
    return scheme, host, tonumber(port), path
end

--- @param opts.timeout    单次 IO 超时 (秒)
--- @param opts.connect    可注入的连接工厂 (测试用): function(pool, host, port, tls) -> sock|nil, err
--- @param opts.healthy    可注入的健康检查 (测试替身没有真 fd)
--- @param opts.on_connect 新建连接成功时的回调 (诊断: 复用率)
--- @param opts.wall_time 墙钟 (测试注入; 空闲连接与 DNS 缓存到期)
function Pool.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Pool)
    self.timeout = opts.timeout or Pool.DEFAULT_TIMEOUT
    self.connector = opts.connect
    self.healthy_fn = opts.healthy
    self.on_connect = opts.on_connect
    self.wall_time = opts.wall_time or socket.gettime or os.time
    -- key -> { { sock =, busy = }, ... }
    -- 每个 host 可能有多条连接 (并发下载时一个任务占一条)。HTTP/1.1 一条连接
    -- 同一时刻只能跑一个请求, 所以"并行"= 同一 host 开两条连接。
    self.conns = {}
    self.dns = {}        -- host -> ip; 有界缓存, 不能跨休眠一直钉在旧 CDN 节点
    self.dns_time = {}
    return self
end

----------------------------------------------------------------------------
-- 建连
----------------------------------------------------------------------------

local function resolve(self, host)
    local ip = self.dns[host]
    if ip and self.dns_time[host] and self.wall_time() - self.dns_time[host] < Pool.DNS_TTL then return ip end
    self.dns[host], self.dns_time[host] = nil, nil
    local ok, res = pcall(socket.dns.toip, host)
    if not ok or type(res) ~= "string" then return nil end
    self.dns[host] = res
    self.dns_time[host] = self.wall_time()
    return res
end

--- 默认连接工厂: DNS (带缓存) + TCP + TLS 握手
function Pool._connect(self, host, port, tls)
    local ip = resolve(self, host)
    local target = ip or host

    local tcp = socket.tcp()
    tcp:settimeout(self.timeout)
    local ok, err = tcp:connect(target, port)
    if not ok and ip then
        -- 缓存的 IP 可能已经失效 (CDN 换节点): 丢掉缓存, 用域名再试一次
        self.dns[host], self.dns_time[host] = nil, nil
        pcall(function() tcp:close() end)
        tcp = socket.tcp()
        tcp:settimeout(self.timeout)
        ok, err = tcp:connect(host, port)
    end
    if not ok then
        pcall(function() tcp:close() end)
        return nil, "TCP 连接失败: " .. tostring(err)
    end

    if not tls then return tcp end

    local ok_ssl, ssl = pcall(require, "ssl")
    if not ok_ssl then
        pcall(function() tcp:close() end)
        return nil, "没有 ssl 库"
    end
    -- 参数与 ssl.https 保持一致 (protocol="any" + sni): 少了 sni 时
    -- 共享 IP 的 CDN 会直接回 "sslv3 alert handshake failure" (实测)。
    local conn, werr = ssl.wrap(tcp, {
        mode = "client",
        protocol = "any",
        verify = "none",
        options = { "all" },
        ciphers = "ALL",
    })
    if not conn then
        pcall(function() tcp:close() end)
        return nil, "TLS 包装失败: " .. tostring(werr)
    end
    pcall(function() conn:sni(host) end)
    -- LuaSec wraps the fd but does not inherit the TCP timeout. Set it before
    -- handshaking, otherwise a stalled TLS peer can wait until the task watchdog.
    conn:settimeout(self.timeout)
    local hok, herr = conn:dohandshake()
    -- Blocking LuaSec reports an expired handshake as wantread/wantwrite.
    if not hok and (herr=="wantread" or herr=="wantwrite") then herr="timeout" end
    if not hok then
        pcall(function() conn:close() end)
        return nil, "TLS 握手失败: " .. tostring(herr)
    end
    return conn
end

--- 这条连接还能用吗 (对端已关 / 有多余数据都算不能)
--
-- 注意: 这里只是**省一次重连**, 不是正确性依赖 —— 真失效由"复用失败后重连一次"
-- 兜住。所以判断不了时一律当作可用。
function Pool:_healthy(sock)
    if self.healthy_fn then return self.healthy_fn(sock) end
    if type(sock.getfd) ~= "function" then return true end
    local ok, readable = pcall(socket.select, { sock }, nil, 0)
    if not ok then return true end
    return type(readable) == "table" and #readable == 0
end

function Pool:_open(host, port, tls)
    local factory = self.connector or Pool._connect
    local sock, err = factory(self, host, port, tls)
    -- TCP 能连通而 TLS 被关闭/重置时, 旧代码永远保留同一个 IP。
    -- 下一次尝试必须重新解析, 证书/协议错误仍原样返回。
    if not sock then self.dns[host], self.dns_time[host] = nil, nil end
    -- 诊断钩子挂在"新建成功"这一层: 换 connector (测试替身) 也照样能数复用率
    if sock and self.on_connect then pcall(self.on_connect, host) end
    return sock, err
end

-- 仅识别传输中断; TLS 告警、证书、协议、超时等错误不在此自动重试。
function Pool.isTransientDisconnect(err)
    local reason = tostring(err):lower()
    reason = reason:match("^tls 握手失败: (.+)$")
        or reason:match("^发送请求失败: (.+)$")
        or reason:match("^读取响应失败: (.+)$")
        or reason:match("^读取状态行失败: (.+)$") or reason
    return reason == "closed" or reason == "connection reset by peer" or reason == "broken pipe"
end

----------------------------------------------------------------------------
-- 请求
----------------------------------------------------------------------------

--- 发一个 GET 并把响应解析完 (body 交给 sink)
-- @return { status_code, headers, parser } 或 nil, err
function Pool:_exchange(sock, host, port, path, headers, sink)
    -- 请求头: 调用方的 Connection/Host 一律改写 —— 上层 download() 为了旧路径
    -- 会显式塞 Connection: close, 原样带过去就等于"每次用完关掉", 复用无从谈起。
    local lines = { "GET " .. path .. " HTTP/1.1" }
    local host_header = (port == 80 or port == 443) and host or (host .. ":" .. port)
    lines[#lines + 1] = "Host: " .. host_header
    for k, v in pairs(headers or {}) do
        local lk = tostring(k):lower()
        if lk ~= "connection" and lk ~= "host" then
            lines[#lines + 1] = tostring(k) .. ": " .. tostring(v)
        end
    end
    lines[#lines + 1] = "Connection: keep-alive"
    local payload = table.concat(lines, "\r\n") .. "\r\n\r\n"

    local sent, serr = sock:send(payload)
    if not sent then return nil, "发送请求失败: " .. tostring(serr) end
    while sent < #payload do
        local n, e = sock:send(payload:sub(sent + 1))
        if not n then return nil, "发送请求失败: " .. tostring(e) end
        sent = sent + n
    end

    local p = Parser.new(sink)
    local got_any = false
    while true do
        -- 按解析器"想要多少"来读: 多要一个字节都会让最后一次读等到超时
        -- (连接是 keep-alive, 对端不会因为我们读够了就关)。行模式用 receive("*l"),
        -- 拿到的是去掉 CRLF 的行, 补回去再喂给解析器。
        local want = p:want()
        local chunk, err, partial
        if want == nil then
            chunk, err, partial = sock:receive("*l")
            if chunk then chunk = chunk .. "\r\n" end
        elseif want < 0 then
            chunk, err, partial = sock:receive(Pool.READ_CHUNK)
        else
            chunk, err, partial = sock:receive(math.min(want, Pool.READ_CHUNK))
        end
        local piece = chunk or partial
        local done, perr
        if piece and #piece > 0 then
            got_any = true
            done, perr = p:feed(piece)
        end
        if perr then return nil, perr end
        if done then break end
        if not chunk then
            if err == "closed" then
                -- 一个字节都没收到: 对端直接关了 (常见于空闲期被回收的 keep-alive
                -- 连接)。这条错误要能和"响应中途断"分开, 否则日志里分不清
                -- "服务端拒绝"还是"传到一半断了"。
                if not got_any then
                    return nil, "读取状态行失败: " .. tostring(err)
                end
                local dok, derr = p:eof()
                if dok then break end
                return nil, derr .. ": " .. tostring(err)
            end
            if p.state == "status" then
                return nil, "读取状态行失败: " .. tostring(err)
            end
            return nil, "读取响应失败: " .. tostring(err)
        end
    end
    return { status_code = p.status_code, headers = p.headers, parser = p }
end

----------------------------------------------------------------------------
-- 对外
----------------------------------------------------------------------------

--- 取一条连接 (优先复用空闲且健康的, 没有就新建)
-- @return sock, key, reused, err
function Pool:acquire(url)
    local scheme, host, port = Pool.parseUrl(url)
    if not scheme then return nil, nil, false, "无法解析地址: " .. tostring(url) end
    local tls = (scheme == "https")
    local key = scheme .. "://" .. host .. ":" .. tostring(port)

    local list = self.conns[key] or {}
    -- 顺手清掉对端已经关掉的空闲连接 (否则下次还会拿到它)
    for i = #list, 1, -1 do
        local slot = list[i]
        if not slot.busy and (self.wall_time() - (slot.idle_since or 0) >= Pool.IDLE_TTL
            or not self:_healthy(slot.sock)) then
            pcall(function() slot.sock:close() end)
            table.remove(list, i)
        end
    end
    for _i, slot in ipairs(list) do
        if not slot.busy then
            slot.busy = true
            self.conns[key] = list
            return slot.sock, key, true
        end
    end

    local sock, err = self:_open(host, port, tls)
    if not sock then return nil, key, false, err end
    list[#list + 1] = { sock = sock, busy = true }
    self.conns[key] = list
    return sock, key, false
end

--- 归还一条连接
-- @param keep false = 关掉并从池里移除 (协议异常 / 对端要关 / 复用失败)
function Pool:release(key, sock, keep)
    local list = self.conns[key]
    if list then
        for i, slot in ipairs(list) do
            if slot.sock == sock then
                if keep then
                    slot.busy = false
                    slot.idle_since = self.wall_time()
                else
                    pcall(function() slot.sock:close() end)
                    table.remove(list, i)
                end
                if #list == 0 then self.conns[key] = nil end
                return
            end
        end
    end
    if not keep then pcall(function() sock:close() end) end
end

--- GET 一个地址, 响应体写进 sink
--
-- @return { status_code, headers } 或 nil, err
function Pool:get(url, headers, sink)
    local scheme, host, port, path = Pool.parseUrl(url)
    if not scheme then return nil, "无法解析地址: " .. tostring(url) end
    local tls = (scheme == "https")
    local key = scheme .. "://" .. host .. ":" .. tostring(port)

    -- 本次已写进 sink 的字节数。重连重发只在**一个字节都没写**时允许 ——
    -- 否则文件里会留下"死连接的前半截 + 新连接的完整响应", 解码出来是花屏/坏图,
    -- 而且大小看起来还"正常"。有字节落盘就让上层走它自己的重试 (那里会截断文件)。
    local written = 0
    local counted_sink = sink and function(chunk)
        if chunk and #chunk > 0 then written = written + #chunk end
        return sink(chunk)
    end or nil

    -- 最多两次: keep-alive 的经典坑是服务端在空闲期悄悄关了连接, 我们发出去
    -- 才发现。这种情况重发一次就够 (上层在每次尝试前会截断文件, 这里再加一道
    -- "已写字节就不重发" 的闸 —— 见 written 的说明)。
    for attempt = 1, 2 do
        local sock, akey, reused, terr = self:acquire(url)
        if not sock then
            if attempt == 2 or not Pool.isTransientDisconnect(terr) then return nil, terr end
        else
            key = akey

            local sock_timeout_ok = pcall(function() sock:settimeout(self.timeout) end)
            if not sock_timeout_ok then
                self:release(key, sock, false)
                return nil, "设置超时失败"
            end

            local resp, err = self:_exchange(sock, host, port, path, headers, counted_sink)
            if not resp then
                self:release(key, sock, false)
                if reused and attempt == 1 and written == 0 then
                    if logger.enabled then logger.dbg("Picayomi HTTP: 复用的连接已失效 (" .. tostring(err) .. "), 重连一次") end
                else
                    return nil, err
                end
            else
                self:release(key, sock, resp.parser:keep_alive())
                return { status_code = resp.status_code, headers = resp.headers }
            end
        end
    end
    return nil, "连接不可用"
end

--- 关掉池里所有连接 (worker 退出 / 换章节)
function Pool:close()
    for key, list in pairs(self.conns) do
        for _i, slot in ipairs(list) do
            pcall(function() slot.sock:close() end)
        end
        self.conns[key] = nil
    end
    self.dns = {}
    self.dns_time = {}
end

return Pool
