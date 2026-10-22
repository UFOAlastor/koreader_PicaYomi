# 诊断开关

发布默认关闭 `info`、`dbg` 和 `diag.log`。保留 `warn`、`err`，不改变 KOReader 的全局日志级别。关闭时日志调用点先检查布尔开关，跳过字符串拼接、格式化及日志参数计算；Diag 不加载采样依赖，不读进程内存，不打开文件，不安排定时采样。

构建时统一生成 `util/log_config.lua`。发布构建为 `debug=false, allow_env=false`；KOReader 自身启用 debug 或环境变量均不能打开插件诊断。排障版本为 `debug=true, allow_env=false`。需要排障时可把该文件的 debug 改为 true，重启 KOReader，结束后改回 false 并重启。旧日志不会自动删除。

源 SDK 的 `ctx.logger.enabled` 与 `ctx.trace.enabled` 继承同一个开关。源应使用 `if ctx.logger.enabled then ... end` 包住诊断参数计算，错误用 warn/err；旧源无法避免自身预先计算参数，但宿主关闭时会跳过日志脱敏与输出。任何级别均不得打印密码、会话、Cookie、签名原文或个人响应。
