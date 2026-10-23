-- Standalone entry, launched by posix_spawn; never initializes a screen/UI.
require("setupkoenv")
local plugin = assert(arg[1])
package.path = plugin .. "/?.lua;" .. package.path
local Fork = require("network.subprocess_fork")
local Worker = require("network.background_worker")
Worker.background = true
local session = Fork.from_fds(3, 4)
local ok, err = pcall(function()
    local job = assert(session:recv(), "后台任务描述缺失")
    Worker.run(session, job.kind, job.options)
end)
if not ok then
    -- Log only a sanitized exception; never print the request descriptor.
    require("util.logger").warn("Picayomi Worker: " .. require("util.log_redact").text(err))
    session:send({ error = "后台任务执行失败，请重试" })
end
session:close()
os.exit(ok and 0 or 1)
