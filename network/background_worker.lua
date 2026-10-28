-- Named network operations can run in a fresh interpreter on macOS. Only data
-- crosses the pipe; source parsing, cookies and UI callbacks stay in the parent.
local Worker = {}

function Worker.reply(child, fetch, limit)
    local ok, value, err = pcall(fetch)
    if not ok then value = tostring(value) end
    local encoded = require("string.buffer").encode({ ok = ok, value = value, err = err })
    if #encoded > limit then child:send({ error = "响应过大，请缩小查询范围" }); return end
    for offset = 1, #encoded, 48000 do
        if not child:send({ chunk = encoded:sub(offset, offset + 47999),
            last = offset + 48000 > #encoded }) then return end
        if offset + 48000 <= #encoded and not child:recv() then return end
    end
end

function Worker.request(spec)
    assert(type(spec) == "table", "后台请求描述无效")
    if spec.kind == "novel_image" then
        return require("network.novel_http").download(spec.request,spec.timeout,spec.destination,nil,spec.deadline)
    end
    if spec.kind == "extension_https" then
        return require("source.extensions.https").get(spec.url, spec.limit)
    end
    assert(spec.kind == "http" and
        (spec.operation == "request" or spec.operation == "requestWithRetry" or spec.operation=="requestOnce"), "未知后台请求")
    local http = require("network.http_client")
    return http[spec.operation](http, spec.method, spec.url, spec.headers, spec.body, spec.timeout)
end

function Worker.run(session, kind, options)
    if kind == "novel" then
        local pool=require("network.http_conn").new{timeout=20}
        local request=options
        while request do
            Worker.reply(session,function()
                if request.kind=="novel_image" then
                    return require("network.novel_http").download(request.request,request.timeout,request.destination,pool,request.deadline)
                end
                return Worker.request(request)
            end,require("network.async_task").MAX_RESULT)
            local message=session:recv()
            request=message and message.request
        end
        pool:close()
        return
    end
    if kind == "reader" then
        return require("network.reader_worker").loop(session, options)
    end
    assert(kind == "request", "未知后台任务")
    Worker.reply(session, function() return Worker.request(options) end,
        require("network.async_task").MAX_RESULT)
end

return Worker
