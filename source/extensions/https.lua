-- Executable updates require verified certificates AND DNS identity. This path
-- is deliberately separate from source networking and never follows redirects.
local Net = {}

function Net.validURL(url)
    if type(url) ~= "string" or #url > 2048 or url:find("[%s%c]") then return false end
    local authority = url:match("^https://([^/?#]+)")
    return authority ~= nil and authority:match("^[a-zA-Z0-9][a-zA-Z0-9%.%-]*$") ~= nil
        and authority:find("%.") ~= nil and not url:find("#", 1, true)
end

function Net.matches(host, name)
    if type(name) ~= "string" or name:find("\0", 1, true) then return false end
    host, name = host:lower(), name:lower()
    if host == name then return true end
    if name:sub(1, 2) ~= "*." then return false end
    local suffix = name:sub(2)
    local prefix = host:sub(1, #host - #suffix)
    return #prefix > 0 and not prefix:find(".", 1, true)
        and host:sub(-#suffix) == suffix and name:sub(3):find("%.") ~= nil
end

function Net.get(url, limit)
    assert(Net.validURL(url), "订阅和源包仅支持无认证信息的 HTTPS 域名地址")
    local Async = require("network.async_task")
    if Async.active() then
        return Async.await(function() return Net.get(url, limit) end,
            { kind = "extension_https", url = url, limit = limit })
    end
    local http, https = require("socket.http"), require("ssl.https")
    assert(not http.PROXY, "扩展更新不支持全局代理")
    local host = url:match("^https://([^/?:#]+)")
    local chunks, size = {}, 0
    local connection
    local previous_timeout = https.TIMEOUT
    https.TIMEOUT = 20
    local function create()
        connection = https.tcp{ verify = "peer", cafile = "data/ca-bundle.crt",
            protocol = "any", options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1", "no_tlsv1_1" } }()
        local connect = connection.connect
        connection.connect = function(self, ...)
            connect(self, ...)
            local cert = self.sock:getpeercertificate()
            local ext = cert and cert:extensions()
            local names = ext and ext["2.5.29.17"] and ext["2.5.29.17"].dNSName or {}
            for _, name in ipairs(names) do
                if Net.matches(host, name) then return 1 end
            end
            self.sock:close()
            error("TLS 主机名校验失败")
        end
        return connection
    end
    local ok, result, status = pcall(http.request, {
        url = url, method = "GET", create = create, redirect = false,
        headers = { ["User-Agent"] = "PicaYomi-Extensions/1", ["Accept"] = "application/json" },
        sink = function(chunk, err)
            if err then return nil, err end
            if chunk then
                size = size + #chunk
                if size > limit then return nil, "扩展响应过大" end
                chunks[#chunks + 1] = chunk
            end
            return 1
        end,
    })
    https.TIMEOUT = previous_timeout
    if connection then pcall(function() connection:close() end) end
    assert(ok and result and tonumber(status) == 200, "HTTPS 获取失败: " .. tostring(ok and status or result))
    return table.concat(chunks)
end

return Net
