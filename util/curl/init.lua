local curl = {}

function curl.curl_with_headers(url, headers)
    local http_headers = {}
    for k, v in pairs(headers or {}) do
        table.insert(http_headers, k .. ": " .. v)
    end

    local cmd = "curl -s"

    -- 添加请求头
    for _, header in ipairs(http_headers) do
        cmd = cmd .. string.format(" -H \"%s\"", header)
    end

    -- 添加URL
    cmd = cmd .. string.format(" \"%s\"", url)

    -- 执行curl命令
    local f = io.popen(cmd)
    if not f then return nil end
    local content = f:read("*a")
    f:close()

    return content
end

return curl
