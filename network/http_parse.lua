-- network/http_parse.lua
-- HTTP/1.1 响应解析器 (增量式): 喂多少字节解析多少, 不要求一次拿到完整响应。
--
-- 为什么单独抽出来:
--   下载有两条驱动方式 ——
--     ① 阻塞式 (network/http_conn 的连接池): receive(16KB) 拿到就喂;
--     ② 非阻塞式 (下载子进程里的并发调度): 每次只读到"当前可读"的那点,
--        两个任务交替推进。
--   两条路必须用**同一套定界规则** (Content-Length / chunked / 读到关闭),
--   否则"某条分支修好了、另一条还漏着"—— 这正是 v0.9.12 踩过的坑
--   (明文 302 的响应体被写在文件开头, 而 HTTPS 那条早就修了)。
--
-- 纯 Lua, 不碰 socket, 可以完全离线测 (见 test/http_parse.lua)。

local Parser = {}
Parser.__index = Parser

Parser.MAX_HEADER_BYTES = 64 * 1024

--- @param sink function(chunk) -> 1|nil  响应体去哪 (写文件); 传 nil 表示丢弃
function Parser.new(sink)
    return setmetatable({
        sink = sink,
        buf = "",
        state = "status",
        headers = {},
        header_bytes = 0,
        remaining = 0,        -- Content-Length 还剩多少
        framing = nil,        -- "length" | "chunked" | "close"
        status_code = nil,
        chunk_left = 0,
    }, Parser)
end

local function no_body(code)
    return code == 204 or code == 304 or (code >= 100 and code < 200)
end
Parser.no_body = no_body

--- 从缓冲区取一行 (不含 CRLF)。取不到返回 nil (不消费)
function Parser:_take_line()
    local i = self.buf:find("\r\n", 1, true)
    if not i then return nil end
    local line = self.buf:sub(1, i - 1)
    self.buf = self.buf:sub(i + 2)
    return line
end

--- 下一次读多少字节才"刚好" (驱动方用; 返回 nil = 行模式, 按行读)
--
-- 为什么需要它: 阻塞式驱动如果一律 receive(16KB), 而响应体只剩 500 字节且
-- 连接保持打开, 这一次读会一直等到超时 (实测: 480KB 的图变成 20 秒)。
-- 所以必须"要多少读多少"; 行模式 (状态行/头部/chunk 大小/trailer) 则由
-- 驱动方按行读, 交给 feed 时补回 CRLF。
function Parser:want()
    local st = self.state
    if st == "body" and self.framing == "length" then return self.remaining end
    if st == "body" then return -1 end          -- close 定界: 读满一块, 关闭时收尾
    if st == "chunk_data" then return self.chunk_left end
    if st == "chunk_crlf" then return 2 end
    return nil                                   -- 行模式
end

--- 当前还剩多少字节没到 (只在 framing == "length" 时有意义)
function Parser:missing()
    if self.framing == "length" then return self.remaining end
    return nil
end

--- 这条连接还能不能复用 (必须等 done 之后再看)
function Parser:keep_alive()
    if self.framing == "close" then return false end
    local c = self.headers["connection"]
    return not (c and c:lower() == "close")
end

--- 喂一段字节
-- @return done(bool), err
--   done = true 表示整个响应 (含 body) 已经解析完
--   err 非空表示协议错误 (调用方必须关连接)
function Parser:feed(chunk)
    if chunk and #chunk > 0 then
        self.buf = self.buf .. chunk
    end

    while true do
        local st = self.state

        if st == "status" then
            local line = self:_take_line()
            if not line then return false end
            local code = tonumber(line:match("^HTTP/%d%.%d%s+(%d%d%d)"))
            if not code then return false, "状态行非法: " .. tostring(line) end
            self.status_code = code
            self.state = "headers"

        elseif st == "headers" then
            local line = self:_take_line()
            if not line then return false end
            if line == "" then
                -- 头部结束: 决定 body 定界 (RFC 7230 §3.3.3)
                local code = self.status_code
                local te = self.headers["transfer-encoding"]
                if no_body(code) then
                    self.framing = "none"
                    self.state = "done"
                elseif te and te:lower():find("chunked", 1, true) then
                    self.framing = "chunked"
                    self.state = "chunk_size"
                elseif self.headers["content-length"] then
                    self.framing = "length"
                    self.remaining = tonumber(self.headers["content-length"]) or 0
                    self.state = (self.remaining == 0) and "done" or "body"
                else
                    self.framing = "close"
                    self.state = "body"
                end
            else
                self.header_bytes = self.header_bytes + #line
                if self.header_bytes > Parser.MAX_HEADER_BYTES then
                    return false, "响应头过大"
                end
                local k, v = line:match("^([^:]+):%s*(.-)%s*$")
                if k then self.headers[k:lower()] = v end
            end

        elseif st == "body" then
            if self.framing == "length" then
                if #self.buf == 0 then return false end
                local take = math.min(#self.buf, self.remaining)
                local piece = self.buf:sub(1, take)
                self.buf = self.buf:sub(take + 1)
                self.remaining = self.remaining - take
                if piece ~= "" and self.sink and self.sink(piece) == nil then
                    return false, "写入失败"
                end
                if self.remaining == 0 then
                    self.state = "done"
                else
                    return false          -- 等更多数据
                end
            else
                -- close 定界: 有多少交多少, 由驱动方在 EOF 时收尾
                if #self.buf == 0 then return false end
                local piece = self.buf
                self.buf = ""
                if self.sink and self.sink(piece) == nil then
                    return false, "写入失败"
                end
                return false
            end

        elseif st == "chunk_size" then
            local line = self:_take_line()
            if not line then return false end
            local size_hex = line:match("^%s*([0-9a-fA-F]+)")
            local size = size_hex and tonumber(size_hex, 16)
            if not size then return false, "chunk 大小非法: " .. tostring(line) end
            if size == 0 then
                self.state = "trailer"
            else
                self.chunk_left = size
                self.state = "chunk_data"
            end

        elseif st == "chunk_data" then
            if #self.buf == 0 then return false end
            local take = math.min(#self.buf, self.chunk_left)
            local piece = self.buf:sub(1, take)
            self.buf = self.buf:sub(take + 1)
            self.chunk_left = self.chunk_left - take
            if piece ~= "" and self.sink and self.sink(piece) == nil then
                return false, "写入失败"
            end
            if self.chunk_left == 0 then self.state = "chunk_crlf" end
            if self.chunk_left > 0 then return false end

        elseif st == "chunk_crlf" then
            if #self.buf < 2 then return false end
            local crlf = self.buf:sub(1, 2)
            if crlf ~= "\r\n" then
                return false, "chunk 结尾不是 CRLF: " .. tostring(crlf)
            end
            self.buf = self.buf:sub(3)
            self.state = "chunk_size"

        elseif st == "trailer" then
            local line = self:_take_line()
            if line == nil then return false end
            if line == "" then self.state = "done" end

        elseif st == "done" then
            return true
        end
    end
end

--- 读到 EOF 时调用: close 定界算正常结束, 其它定界算半截
-- @return done(bool), err
function Parser:eof()
    if self.state == "done" then return true end
    if self.framing == "close" then
        if #self.buf > 0 then
            if self.sink and self.sink(self.buf) == nil then return false, "写入失败" end
            self.buf = ""
        end
        self.state = "done"
        return true
    end
    if self.framing == "length" then
        return false, "连接提前关闭 (还差 " .. tostring(self.remaining) .. " 字节)"
    end
    return false, "连接提前关闭 (响应未结束)"
end

return Parser
