-- network/transport_blocking.lua
-- 同步实现的下载传输层 —— 只负责"发起/收割", 不含任何策略。
--
-- 定位: 这是 transport 接口的**基准实现**, 语义与旧 StreamSession:fetch_page 完全一致
-- (同步下载 + 按文件头修正扩展名 + 失败删残file)。它的价值有两层:
--   1. 调度器/会话可以先用它接线, 行为与改造前一致 => 重构的第一批提交不会改变
--      任何可观测行为, 门禁零改动 (见 docs 计划里的"阶段 1")。
--   2. 万一 fork 不可用 (runInSubProcess 创建管道失败), 生产路径回退到它。
--
-- **它仍然是阻塞的**: poll() 会一直卡在网络调用上。因此调用它的一方必须保证
-- "一次只 poll 一个"、且在事件循环里调用 (不能是绘制链)。真正不阻塞的实现见
-- network/transport_worker.lua (常驻 fork worker)。
--
-- 单页耗时为什么必须用**墙钟**:
--   旧实现用 os.clock(), 量的是本进程的 CPU 时间。而下载几乎全是等网络
--   (DNS / TLS / 首字节 / 传输), CPU 几乎不动 —— 一张真机要下好几秒的图会报
--   "0.1s", 于是慢链路熔断永远不触发, 日志里的耗时也全是假的。
--   (与 network/reader_worker.lua 同一处修正; 这条路径只在 fork 不可用时才走。)

local lfs = require("libs/libkoreader-lfs")

local Transport = {}
Transport.__index = Transport

--- 可注入的墙钟 (测试制造"这一页下了很久")
function Transport.wall_time()
    local ok, socket = pcall(require, "socket")
    if ok and type(socket) == "table" and socket.gettime then return socket.gettime() end
    return os.clock()
end

--- @param opts.source        漫画源 (需要 downloadImage(url, dest) -> ok, err)
--- @param opts.fix_extension function(path) -> path  按文件头修正扩展名 (可注入)
function Transport.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Transport)
    self.source = opts.source
    self.fix_extension = opts.fix_extension
    self.pending = {}
    self.ready = {}
    self.cancelled = false
    if self.source and self.source.watchSession then
        self.unwatch=self.source:watchSession(function() self:invalidate() end)
    end
    return self
end

function Transport:start(job)
    if self.cancelled then return end
    if self.invalidated then
        self.ready[#self.ready+1]={page=job.page,ok=false,err="登录状态已改变",code="cancelled",retryable=false}
        return
    end
    self.pending[#self.pending + 1] = job
end

--- 收割一个任务 (同步执行下载)
--
-- 刻意每次只处理一个: 与调度器的"每步预算"对称, 让主线程占用有界。
function Transport:poll(_budget_ms)
    local done = {}
    if self.cancelled then return { done = done, idle = true } end
    if #self.ready>0 then return {done={table.remove(self.ready,1)},idle=#self.ready==0} end

    local job = table.remove(self.pending, 1)
    if not job then
        return { done = done, idle = true }
    end
    self.active=job

    local item = { page = job.page, ok = false }

    if not job.url then
        item.err = "缺少图片地址"
    else
        local t0 = Transport.wall_time()
        -- **必须 pcall。** 这个调用会一路冒泡出去: poll -> Scheduler:step ->
        -- StreamSession:step -> ReaderBridge 的 tick 回调。源侧抛异常 (而不是
        -- 返回 nil, err) 会把整条驱动链打断, 而 ReaderBridge._driving 已经复位成
        -- false 且不会再重排 —— 表现是"下载静默全停", 界面上什么都不再发生,
        -- 也没有任何报错。异常按"这一页下载失败"处理, 链路照常继续。
        --
        -- 注意 pcall 会把被调函数的返回值**一并返回**, 所以这里要接三个值:
        -- called_ok 是"调用本身没抛异常", dl_ok / dl_err 才是下载的结果。
        -- 写成 `local ok, err = pcall(...)` 会把 dl_ok 吞掉 —— 源返回
        -- `false, err` 时 ok 恒为 true, 于是**失败被当成成功**。
        local called_ok, dl_ok, dl_err
        if self.source and self.source._source_runtime then
            called_ok,dl_ok,dl_err=pcall(function()
                local request,err=require("source.image_request").prepare(self.source,job)
                if not request then return false,err end
                local result=require("network.reader_worker").execute{page=job.page,url=request.url,dest=job.dest,
                    headers=request.headers,timeout=request.timeout,post=request.post}
                if not result.ok and result.code then return false,{code=result.code,message=result.err,retryable=result.retryable} end
                return result.ok,result.err
            end)
        else
            called_ok,dl_ok,dl_err=pcall(self.source.downloadImage,self.source,job.url,job.dest)
        end
        item.elapsed = Transport.wall_time() - t0

        if self.cancelled or self.invalidated then
            -- 取消后不再落地 (旧行为: 删掉半成品)
            os.remove(job.dest)
            self.active=nil
            return { done = done, idle = true }
        end

        if called_ok and dl_ok then
            local real = job.dest
            if self.fix_extension then
                real = self.fix_extension(job.dest) or job.dest
            end
            item.ok = true
            item.path = real
            item.size = lfs.attributes(real, "size")
        else
            os.remove(job.dest)
            -- 调用抛异常时 dl_ok 装的是那个异常对象
            local failure=called_ok and dl_err or dl_ok
            if type(failure)=="table" and failure.code then
                item.err,item.code,item.retryable=failure.message,failure.code,failure.retryable
            else item.err=tostring(failure) end
        end
    end

    done[1] = item
    self.active=nil
    return { done = done, idle = #self.pending == 0 }
end

--- 丢弃尚未开始的任务
--
-- 注意: 正在下载中的那一个**无法中断** (它是同步调用) —— 这是本实现的固有限制,
-- 也是生产上要换成 worker 的原因之一。
function Transport:cancel_all()
    self.cancelled = true
    self.pending = {}
    self.ready = {}
    if self.unwatch then self.unwatch();self.unwatch=nil end
end

function Transport:invalidate()
    if self.cancelled or self.invalidated then return end
    local ready={}
    for _,job in ipairs(self.pending) do ready[#ready+1]={page=job.page,ok=false,err="登录状态已改变",code="cancelled",retryable=false} end
    if self.active then ready[#ready+1]={page=self.active.page,ok=false,err="登录状态已改变",code="cancelled",retryable=false} end
    self:cancel_all()
    self.cancelled=false;self.invalidated=true;self.ready=ready
end

function Transport:close()
    self:cancel_all()
    self.source = nil
end

--- 供上层判断"是否已经取消"
function Transport:is_cancelled()
    return self.cancelled
end

--- 还有没跑完的任务吗 (供 transport_worker 汇总"整体是否在忙")
function Transport:busy()
    return #self.pending > 0 or #self.ready>0
end

return Transport
