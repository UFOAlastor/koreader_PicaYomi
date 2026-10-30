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

function Worker.request(spec,pool)
    assert(type(spec) == "table", "后台请求描述无效")
    if spec.kind=='kosync'then
        assert(spec.operation=='get_progress' or spec.operation=='update_progress','无效同步操作')
        local folder=type(spec.service_spec)=='string' and spec.service_spec:match('^(.-kosync%.koplugin)/api%.json$')
        assert(folder and not folder:find('..',1,true),'无效同步协议路径')
        -- This operation runs only in a child. The native client needs the
        -- looper flag, not a screen, device or a second settings instance.
        package.loaded['ui/uimanager']={looper=nil}
        if not package.loaded.device then package.loaded.device={model=spec.device_model or 'KOReader'}end
        -- Native debug logging includes progress payloads; never emit them here.
        require('util.logger')
        package.loaded.logger.dbg=function()end
        local Client=dofile(folder..'/KOSyncClient.lua')
        local client=Client:new{service_spec=spec.service_spec,custom_url=spec.custom_url}
        local count=spec.operation=='get_progress' and 3 or 8
        local args=spec.args
        local response
        args[count+1]=function(ok,status,body)
            if spec.operation=='get_progress'then body,status=status,nil end
            response={ok=ok==true,status=status,body=body}
        end
        client[spec.operation](client,unpack(args,1,count+1))
        return response or {ok=false}
    end
    if spec.kind == "novel_image" then
        return require("network.novel_http").download(spec.request,spec.timeout,spec.destination,nil,spec.deadline)
    end
    if spec.kind == "extension_https" then
        return require("source.extensions.https").get(spec.url, spec.limit)
    end
    assert(spec.kind == "http" and
        (spec.operation == "request" or spec.operation == "requestWithRetry" or spec.operation=="requestOnce"), "未知后台请求")
    local http = require("network.http_client")
    if pool and pool.requestOnce and spec.operation=='requestOnce' and (spec.method=='GET' or spec.method=='POST') then
        return http:_httpsOncePooled(pool,spec.method,spec.url,spec.headers,spec.body,spec.timeout)
    end
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
                return Worker.request(request,pool)
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
