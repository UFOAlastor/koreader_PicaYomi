-- Turn transport/runtime failures into short, actionable UI text. Keep the
-- original reason in local logs; never render Lua paths or response bodies.
local _ = require("gettext")
local Message = {}

function Message.describe(err, fallback)
    fallback = fallback or _("操作未完成，请重试；若仍失败，请重新打开此页面。")
    if err == nil or err == false or err == "" then return fallback end
    local ok, raw = pcall(tostring, err)
    if not ok then return fallback end
    require("util.logger").warn("Picayomi operation failed:", require("util.log_redact").text(raw))
    local text = raw
    -- pcall/assert wrappers can prepend several different file locations.
    while text:find("%.lua:%d+:") do text = text:gsub("^.-%.lua:%d+:%s*", "", 1) end
    local lower = text:lower()
    local function has(...)
        for i=1,select("#",...) do
            if lower:find(select(i,...),1,true) then return true end
        end
        return false
    end
    if has("密钥已改变", "发布者改变", "身份改变", "身份不符", "来源冲突") then
        return _("订阅或源的发布身份发生变化，已停止操作。请核对订阅来源后重试。")
    elseif has("签名", "sha256", "摘要", "同一源版本内容发生变化", "回放旧", "同一修订号内容发生变化", "大小不符") then
        return _("订阅或源包校验失败，已拒绝本次更新。请联系订阅维护者。")
    elseif has("超时", "timeout", "timed out") then
        return _("请求超时，请检查网络或稍后重试。")
    elseif has("证书", "certificate", "主机名校验", "hostname mismatch") then
        return _("安全连接验证失败，请检查设备时间和网络后重试。")
    elseif has("tls", "ssl") then
        return _("安全连接建立失败，请检查网络或稍后重试。")
    elseif has("https 域名", "https 网站", "订阅地址无效", "无认证信息", "请输入 https") then
        return _("请输入有效的 HTTPS 地址，且不要包含账号、密码或空格。")
    elseif has("host or service", "name or service", "nodename", "getaddrinfo", "resolve", "域名解析") then
        return _("域名解析失败，请检查网络连接和 DNS 后重试。")
    elseif has("后台请求意外退出", "后台响应", "无效的后台任务", "无法启动后台", "无法创建下载子进程") then
        return _("后台请求中断，请重试；若反复发生，请重启 KOReader。")
    elseif has("可用内存不足", "out of memory", "not enough memory") then
        return _("可用内存不足，请关闭其他页面后重试。")
    elseif has("no space", "磁盘空间", "空间不足") then
        return _("存储空间不足，请清理缓存或下载文件后重试。")
    elseif has("无法写入", "无法创建目录", "保存失败", "保存设置失败", "保存配置失败", "permission denied", "read-only", "写入失败") then
        return _("无法保存数据，请检查存储空间和目录写入权限后重试。")
    elseif has("http 401", "unauthorized", "登录状态", "请先登录", "登录已过期", "会话已过期") then
        return _("登录状态已失效或尚未登录，请登录后重试。")
    elseif has("http 403", "https 获取失败: 403", "forbidden") then
        return _("服务器拒绝访问，请检查账号权限或稍后重试。")
    elseif has("http 404", "https 获取失败: 404") then
        return _("请求的地址或内容不存在，请确认地址或刷新列表后重试。")
    elseif has("http 429", "https 获取失败: 429", "too many requests", "rate limit") then
        return _("请求过于频繁，请稍后重试。")
    elseif lower:find("http[s]?[^\n]-5%d%d") then
        return _("服务器暂时不可用，请稍后重试。")
    elseif has("network is unreachable", "network unreachable", "not connected", "网络未连接") then
        return _("网络未连接，请连接网络后重试；已下载内容仍可使用。")
    elseif has("connection refused", "connection reset", "closed", "连接失败", "https 获取失败") then
        return _("连接失败或中断，请检查网络或稍后重试。")
    elseif has("过大", "数量超限", "响应过大") then
        return _("返回数据超过可处理的大小，请缩小范围或联系源维护者。")
    elseif has("状态损坏", "格式无效", "数据损坏", "invalid json", "decode error", "expected value") then
        return _("返回数据或本地状态异常，请重试；若仍失败，请联系维护者。")
    end
    -- Preserve short, human-readable source/validation messages. Unexpected
    -- English exceptions, HTML, URLs and multiline bodies use a safe fallback.
    text = text:match("^%s*(.-)%s*$")
    if #text<=300 and text:find("[\128-\255]")
        and not text:find("[\r\n<>/\\]") and not text:find("stack traceback",1,true)
        and not text:find("%a+://") and not text:find("%.lua:%d+") and not text:find("[%w_]+%s*=") then
        return text
    end
    return fallback
end

return Message
