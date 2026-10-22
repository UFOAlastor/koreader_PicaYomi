-- util/page_store.lua
-- 阅读页的"本地状态"唯一持有者: 路径 / 尺寸 / 每页状态 / 渲染键。
--
-- 为什么需要单独一层:
--   旧实现把"这一页有没有 / 下没下过 / 失败过没有 / 该画什么"全部塞在
--   StreamSession 里, 而 StreamSession 同时又是下载器、又是缓存索引、
--   又是 DocCache 键的生成者 —— 结果"取页"这件事在渲染链里被反复调用,
--   每次都可能触发文件删除/网络排队, 谁都不敢动。
--
--   这里只做**纯查询与记账**:
--     * 渲染链 (openPage / getUsedBBox / getFullPageHash / ...) 只调 get_local/state/size/render_key;
--       这几个方法只做 stat 级操作, 绝不联网、绝不碰 UI、绝不写盘(除了"发现坏缓存要删掉")。
--     * 下载与重试决策一律不在这里 (见 util/download_scheduler.lua)。
--
-- 硬约束 (test/scheduler_offline.lua 会断言):
--   **本文件不 require 任何 ui/* 或 network/http_client**。
--   本地文件层通过 `cache` 适配器注入, 默认由调用方 (ui/stream_reader.lua)
--   用 network.download_manager 组装 —— 因为 download_manager 自己会 require
--   ui/uimanager, 一旦在这里 require 它, 渲染链就间接把 UIManager 拉进来了。
--
-- 状态机: idle -> loading -> ready | failed
--   * ready   本地有**有效**图片文件
--   * loading 已排进调度器 (排队或在跑), **或**失败过一次但还会自动重试
--   * failed  已经放弃这一页 (见 retry_limit)
--   * idle    还没下过
-- 判定顺序与旧 StreamSession:page_state 完全一致 (ready > loading > failed > idle),
-- 因为占位页文案与 DocCache 键都依赖它。
--
-- 关于 "loading 也包含'失败过一次'": 真机反馈"刚点进去显示的是加载失败, 等一会儿
-- 还是会加载出来, 提示文本错了吧"。用户的判断是对的 —— 失败一次并不等于失败:
--   * 调度器自己的熔断阈值就是 2 次 (util/download_scheduler.lua 的
--     failure_threshold), 即"1 次失败"在上游语义里还算不上失败;
--   * 冷却 (cooldown 15s) 一到, 翻页/预取就会重新发起, 也就是**会自动恢复**。
-- 旧实现一失败就把 failed_reason 挂上去并立刻显示"本页加载失败，翻页重试",
-- 让用户去做一件不必要的事 (他自己翻页只是让重试提前发生)。
-- 现在只有真的放弃 (尝试次数达到 retry_limit) 才报"失败"。

local logger = require("util.logger")
local lfs = require("libs/libkoreader-lfs")

local PageStore = {}
PageStore.__index = PageStore

--- @param opts table
---   images     = { {url=...}, ... }  图片列表 (独立使用时用)
---   total      = number              总页数 (缺省取 #images)
---   get_images = function() -> table 图片列表取用函数 (权威在会话手里时用; 见下)
---   get_total  = function() -> number 总页数取用函数
---   cache_dir = string               本话的本地目录
---   cache     = table                本地文件层适配器 (见下), 可为 nil (纯逻辑测试)
---   is_stale  = function(path, url)  源声明"这个缓存已失效"时返回真 (如 源 B 解扰升级)
--
-- 关于 get_images / get_total:
--   图片列表与总页数的**权威在会话 (StreamSession) 手里** —— 调用方 (测试 / 换章)
--   可能整个替换 `session.images`, 此时字段引用会指向旧表。所以会话注入取用函数,
--   本模块每次现取, 不会读到过期的列表。
--
-- cache 适配器接口 (全部可选, 缺省视为"永远没有本地文件"):
--   find(base_path) -> path|nil      按序号基名找已存在的有效图片
--   forget(path)                     让该路径的索引失效 (删除/改名后必须调用)
--   remove(path)                     删除文件
local function default_cache()
    -- 没有适配器时的退化实现: 只按扩展名找文件, 不做有效性校验。
    -- 生产路径不会走到这里 (stream_reader 会注入 DownloadManager 的带校验索引版本),
    -- 但纯逻辑测试与单元测试需要一个不依赖 KOReader 的可用默认值。
    local IMAGE_EXTS = { ".jpg", ".jpeg", ".png", ".gif", ".webp" }
    return {
        find = function(base_path)
            for _i, ext in ipairs(IMAGE_EXTS) do
                local p = base_path .. ext
                if lfs.attributes(p, "mode") == "file" then return p end
            end
            return nil
        end,
        forget = function() end,
        remove = function(path) os.remove(path) end,
    }
end

function PageStore.new(opts)
    opts = opts or {}
    local self = setmetatable({}, PageStore)

    self.images = opts.images or {}
    self.total = opts.total or #self.images
    self.get_images = opts.get_images
    self.get_total = opts.get_total
    self.cache_dir = opts.cache_dir
    self.cache = opts.cache or default_cache()
    self.is_stale = opts.is_stale
    -- 一页尝试几次之后才算"真的失败" (占位页据此决定显示"加载中…"还是"加载失败")。
    -- 缺省与调度器的 failure_threshold 一致 —— 两个数字语义相同, 不该各写一个。
    self.retry_limit = tonumber(opts.retry_limit) or 2

    -- 每页状态
    self.sizes = {}          -- n -> { w =, h = } (排版用, 下载完成时量好)
    self.loading = {}        -- n -> true (已排进调度器)
    self.failed_at = {}      -- n -> 失败时刻
    self.failed_reason = {}  -- n -> 失败原因 (保留到成功为止)
    self.non_retryable = {}
    -- 第 n 页"发起过几次下载"。渲染键里必须带上它, 否则重试永远不会发生:
    -- renderPage 是"先算键 -> 查缓存 -> 命中就返回", 而"发起下载"挂在 openPage 上;
    -- 失败页清掉冷却后状态又回到 idle, 算出的键若与最初那次一样, 就会命中那张
    -- "加载中"占位图、根本走不到 openPage。详见 render_key()。
    self.gen = {}

    -- 统计 (对外仍是 StreamSession 上的 downloaded / consecutive_failures)
    self.downloaded = 0
    self.consecutive_failures = 0
    self.prefetch_disabled = false

    return self
end

--- 当前图片列表 (优先用会话注入的取用函数, 保证"换章替换了 images"也能读到)
function PageStore:page_images()
    if self.get_images then return self.get_images() end
    return self.images
end

--- 当前总页数 (同上)
function PageStore:page_count()
    if self.get_total then return self.get_total() end
    return self.total
end

--- 第 n 页的文件基名 (不含扩展名)
-- 四位补零: 保证字典序 == 页序, 且与既有缓存/测试数据一致。
function PageStore:base(n)
    return string.format("%s/%04d", self.cache_dir, n)
end

--- 第 n 页在本地是否已有文件 (不做有效性校验)
--
-- 供 state() 用 —— 与旧 find_page 的语义一一对应 (只看"在不在")。
function PageStore:has_local(n)
    local image=self:page_images()[n]
    if image and image.local_path then
        if self.cache.valid then return self.cache.valid(image.local_path) and image.local_path or nil end
        return lfs.attributes(image.local_path,"mode")=="file" and image.local_path or nil
    end
    if not self.cache_dir then return nil end
    return self.cache.find(self:base(n))
end

--- 取第 n 页可用的本地文件路径 (含"缓存是否已失效"校验)
--
-- 渲染链可以调用: 只有 stat + (必要时)一次文件删除, 不联网不碰 UI。
-- 失效缓存会被**当场删掉并让索引失效**, 否则调用方会一直拿到旧(且错误的)画面。
function PageStore:get_local(n)
    local existing = self:has_local(n)
    if not existing then return nil end

    local img = self:page_images()[n]
    if self.is_stale and self.is_stale(existing, img and img.url) then
        if logger.enabled then logger.info("Picayomi PageStore: 第 " .. n .. " 页缓存已失效, 丢弃: " .. existing) end
        self.cache.remove(existing)
        self.cache.forget(existing)
        return nil
    end
    return existing
end

--- 第 n 页当前状态: "ready" | "loading" | "failed" | "idle"
--
-- 判定顺序不能改: 占位页文案与渲染键都建立在它之上。
--
-- "失败过一次但还会自动重试"归到 loading (理由见文件头的状态机说明):
-- 那种页面对用户来说就是"还在加载", 而不是"加载失败, 要你翻页"。
function PageStore:state(n)
    if self:has_local(n) then return "ready" end
    if self.loading[n] then return "loading" end
    if self.failed_reason[n] then
        if self.non_retryable[n] then return "failed" end
        -- gen[n] 就是"发起过几次下载" (见 bump_gen 的注释), 拿它当尝试次数用,
        -- 不额外维护一份计数 —— 两份计数迟早会不一致。
        if (self.gen[n] or 0) < (self.retry_limit or 2) then return "loading" end
        return "failed"
    end
    return "idle"
end

--- 第 n 页的原始尺寸 (排版用), 没有则 nil
function PageStore:size(n)
    return self.sizes[n]
end

--- DocCache 键的后缀: "这一页这次画出来的东西"是什么
--
-- **必须区分内容身份与代数**, 两件事都要:
--
--   1. 内容身份 (ready|...): 已就绪的页用文件身份 (名字+大小+mtime) 做键。
--      这样同一页重绘能命中 DocCache (翻页不重解码), 而文件被换掉/删掉后键必变。
--   2. 代数 (pending|...#gen): 未就绪的页画的是占位图。占位图与真实图的键绝不能碰撞,
--      否则下载完成后重绘会拿回那张"加载中"; 而"重试"也需要键变化才能走到 openPage。
--
-- 旧实现是 `状态 .. "#" .. page_epoch`, 语义等价但没有"内容身份"那一半:
-- 文件被源判为失效并删除后, 状态恰好又回到 idle 时可能撞上旧键。
function PageStore:render_key(n)
    local path = self:get_local(n)
    if path then
        local size = lfs.attributes(path, "size") or 0
        local mtime = lfs.attributes(path, "modification") or 0
        local name = path:match("([^/]+)$") or path
        return string.format("ready|%s|%d|%d", name, size, mtime)
    end
    return string.format("pending|%s#%d", self:state(n), self.gen[n] or 0)
end

--- 记一次"已排进调度器" (由调度器在入队时调用)
--
-- 入队即置位 (而不是等发起下载): 绘制链里 openPage 返回占位页的那一刻,
-- 状态就必须已经是 loading, 占位页才会显示"加载中…"而不是"还没开始"。
function PageStore:mark_loading(n)
    self.loading[n] = true
end

--- 清掉某页的"已排队"标记 (任务被丢弃/熔断时调用)
--
-- 与 mark_loading 对称。熔断会把排队的预取任务丢掉, 若不清标记,
-- 那些页会永远停在 loading —— 占位页一直显示"加载中…"却没有任何东西在加载。
function PageStore:clear_loading(n)
    self.loading[n] = nil
end

--- 记一次"这次尝试开始" —— 递增代数, 让渲染键变化 (由调度器在 start 前调用)
function PageStore:bump_gen(n)
    self.gen[n] = (self.gen[n] or 0) + 1
    return self.gen[n]
end

--- 下载成功
--
-- @param dims 可选: 页面原始尺寸 { w =, h = } (由上层解码量出后传入)。
--             注意**不是**文件字节数 —— 字节数由 transport 报告, 与排版无关。
function PageStore:mark_ready(n, _path, dims)
    self.loading[n] = nil
    self.failed_at[n] = nil
    self.failed_reason[n] = nil
    self.non_retryable[n] = nil
    if dims then self.sizes[n] = dims end
    self.downloaded = self.downloaded + 1
    self.consecutive_failures = 0
end

--- 下载失败
--
-- 失败原因**保留**: 占位页要一直显示"本页加载失败，翻页重试",
-- 而不是过一会儿又变回"加载中…"却没有任何东西在加载。
function PageStore:mark_failed(n, err, now)
    self.loading[n] = nil
    self.failed_at[n] = now or os.time()
    self.failed_reason[n] = tostring(err or "")
    self.consecutive_failures = self.consecutive_failures + 1
end

--- 清掉某页的失败记录 (用户主动翻到这一页 => 放行一次重试)
function PageStore:clear_failure(n)
    self.failed_at[n] = nil
    self.failed_reason[n] = nil
    self.non_retryable[n] = nil
end

--- 第 n 页是否处在失败冷却期
--
-- 冷却结束只放开"允许再发一次网络请求"; failed_reason 保留 (见 mark_failed)。
function PageStore:in_cooldown(n, now, cooldown)
    local t = self.failed_at[n]
    if not t then return false end
    if ((now or os.time()) - t) >= cooldown then
        self.failed_at[n] = nil
        return false
    end
    return true
end

--- 清掉全部"已排队"标记 (取消/关闭时调用, 否则 state 会永远停在 loading)
--
-- **就地清空**而不是换一张新表: 上层 (StreamSession) 持有对 self.loading 的别名,
-- 换表会让别名失效 (取消后标记仍留在旧表里)。
function PageStore:reset_pending()
    for k in pairs(self.loading) do self.loading[k] = nil end
end

--- 已下载页数 / 总页数
function PageStore:progress()
    local total = self:page_count()
    local have = 0
    for i = 1, total do
        if self:has_local(i) then have = have + 1 end
    end
    return have, total
end

return PageStore
