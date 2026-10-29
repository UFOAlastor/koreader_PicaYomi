-- main.lua
-- PicaYomi 插件入口
-- 移植 PicaComic 到 KOReader 的漫画阅读插件

local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("util.logger")
local _ = require("gettext")
local T = require("ffi/util").template
local DataStorage = require("datastorage")
local ffiutil = require("ffi/util")

-- ============================================================================
-- package.path 设置: 支持插件内相对路径 require
-- ============================================================================
local BasePath = {}
function BasePath:getBasePath()
    if not self.base_path then
        local str = debug.getinfo(2, "S").source:sub(2)
        str = str:match("(.*/)") or ""
        self.base_path = str
    end
    return self.base_path
end

function BasePath:getDataPath()
    return DataStorage:getDataDir() .. "/picayomi"
end

function BasePath:getPluginDirectory()
    local callerSource = debug.getinfo(1, "S").source
    if callerSource:find("^@") then
        local directory, _ = callerSource:gsub("^@(.*)/[^/]*", "%1")
        return ffiutil.realpath(directory)
    end
    error("could not find the plugin's directory")
end

package.path = BasePath:getBasePath() .. "?.lua;" .. package.path

logger.notice("Picayomi: loading plugin...")

-- 打印构建标记: 真机上确认"当前跑的是哪次构建"的唯一可靠手段
-- (改完代码部署了但 KOReader 没重启时, 界面上看不出区别, 只能看这行日志)
do
    local ok, info = pcall(dofile, BasePath:getBasePath() .. "build_info.lua")
    if ok and type(info) == "table" then
        logger.notice("Picayomi: build", info.version, info.built_at, "debug", logger.enabled)
    else
        logger.notice("Picayomi: development build", "debug", logger.enabled)
    end
end

-- ============================================================================
-- 插件主入口
-- ============================================================================

local Picayomi = InputContainer:extend{
    name = "picayomi"
}

-- KOReader 有**两套** order 表, FileManager 与 Reader 各用一份:
--   frontend/apps/filemanager/filemanagermenu.lua:859 → filemanager_menu_order
--   frontend/apps/reader/modules/readermenu.lua:348  → reader_menu_order
-- 用户是从 FileManager 的「工具」页启动本插件的, 所以**必须**两边都改 ——
-- 只改 reader 那份时 FileManager 里依旧排在末尾 (这是上一版没生效的原因)。
local TOOLS_ORDER_MODULES = {
    "ui/elements/filemanager_menu_order",
    "ui/elements/reader_menu_order",
}

--- 在单个 order 表里把 ids 按给定顺序提到 tools 的最前面
--- (ids[1] 最终在最前, 依次往后; 结构不符时静默不动)
local function promoteInOneOrder(ids, order)
    if not (order and type(order.tools) == "table") then return end
    -- 倒着插: 先插 ids[#ids], 最后插 ids[1], 于是 ids[1] 落在第一位
    for i = #ids, 1, -1 do
        local id = ids[i]
        -- 先去重再插: Picayomi:init() / addToMainMenu 都会跑, 不去重会越插越多
        for j = #order.tools, 1, -1 do
            if order.tools[j] == id then table.remove(order.tools, j) end
        end
        table.insert(order.tools, 1, id)
    end
end

--- 把本插件的菜单项提到「工具」菜单的**最前面**, 并保持给定的相对顺序
--
-- 为什么需要: KOReader **没有**给插件用的排序 API —— 没写进 order 表的菜单项一律被
-- append 到 sorting_hint 子菜单的**末尾** (frontend/ui/menusorter.lua:161-186),
-- 所以插件永远排在最后。唯一可行的做法是在内存里改那份**已被 require 缓存**的
-- order 表: menusorter 会因此按 order 里的位置把它插进去, 并从 item_table 摘掉,
-- 于是不再走 orphan 追加。
--
-- 注意 order 表是**按 id** 匹配的: 本插件的动态项 ("返回 Picayomi" / 上/下一话) 也得
-- 一并写进去, 否则它们会被追加到末尾 —— 表现就是"返回 Picayomi 跑到列表最末,
-- 和 Picayomi 分家了"。id 在当次菜单里不存在时 menusorter 会直接跳过, 所以多列无妨。
--
-- 这是 hack, 所以每个模块单独包 pcall: KOReader 升级改了菜单排序机制时静默退回
-- 原状 (排在末尾), 不会把插件打崩。
--
-- @param ids 菜单项 id (单个字符串, 或按期望顺序排列的数组)
-- @param order_module 可选, 注入点 (给测试用假表; 见 ui/stream_reader.lua 的 opts.transport)
--                     给了就只改它, 没给就改 TOOLS_ORDER_MODULES 里所有真实模块
function promoteInToolsMenu(ids, order_module)
    if type(ids) == "string" then ids = { ids } end
    if type(ids) ~= "table" or #ids == 0 then return end
    if order_module ~= nil then
        pcall(promoteInOneOrder, ids, order_module)
        return
    end
    for _i, modname in ipairs(TOOLS_ORDER_MODULES) do
        pcall(function()
            promoteInOneOrder(ids, require(modname))
        end)
    end
end

-- 暴露给测试 (与 restoreFileManagerBase 同例)
Picayomi.promoteInToolsMenu = promoteInToolsMenu
Picayomi.TOOLS_ORDER_MODULES = TOOLS_ORDER_MODULES

function Picayomi:init()
    local ok, err = pcall(function()
        -- 凭据落盘迁移: 旧版本把 JM 密码 / 会话 Cookie / 哔咔 token 明文写在
        -- config.json 里。这里在**任何源初始化之前**加密并删除明文键 ——
        -- 源初始化会读这些值, 必须先完成迁移。
        local mig_ok, mig_err = pcall(function()
            require("util.secret_store").migrate()
        end)
        if not mig_ok then
            -- 迁移失败不能静默: 否则 config.json 里的明文会一直留着
            logger.warn("Picayomi: 凭据落盘迁移失败: " .. tostring(mig_err))
        end

        -- 初始化源注册表
        local SourceRegistry = require("source.registry")
        SourceRegistry:initBuiltinSources()

        -- 上次退出时没下完的章节标成"部分完成": 进程已经换了, 队列里的
        -- queued/downloading 状态不可能再被推进 —— 留着会让列表一直转圈。
        pcall(function()
            require("util.offline_library").markInterrupted()
        end)

        -- 菜单排位: 默认会被追加到「工具」页最末, 这里提到第一项
        promoteInToolsMenu("picayomi")

        -- 缓存清理: 全树递归扫描 (5 个缓存根, 每个文件一次 lfs.attributes) 会明显
        -- 拖慢 KOReader 启动 —— 而插件 init 正好在启动路径上。改成排到事件循环,
        -- 让界面先起来, 再在后台把该清的清掉 (清理是纯家务, 不影响任何交互)。
        local UIManager = require("ui/uimanager")
        UIManager:scheduleIn(2, function()
            local clean_ok, clean_err = pcall(function()
                local DownloadManager = require("network.download_manager")
                DownloadManager:cleanCache(
                    require("util.config"):get("max_cache_size") or 500
                )
            end)
            if not clean_ok then
                logger.warn("Picayomi: 后台缓存清理失败: " .. tostring(clean_err))
            end
        end)

        if self.ui.name == "ReaderUI" then
            -- 在阅读器中: 注册返回菜单
            self.ui.menu:registerToMainMenu(self)

            -- 阅读器侧的确定性接线点。
            --
            -- 为什么不用 `PicaReader:open` 之后的轮询: `ReaderUI:showReader` 是异步的
            -- (内部 nextTick + 协程), 调用方拿到"实例已就绪"没有可靠的同步点。
            -- KOReader 自己提供了两个回调 (frontend/apps/reader/readerui.lua):
            --   :486 postInitCallback      —— view/footer/paging 都建好了, 但
            --                                 ReaderUI.instance **尚未**赋值 (:546)
            --   :520 postReaderReadyCallback —— ReaderReady 之后, 页码才有意义
            -- 注册时闭包里的 `self.ui` 就是那个 ReaderUI, 不必去猜 ReaderUI.instance。
            -- 这两个回调在每次 ReaderUI:new (含 switchDocument 重建) 时都会跑。
            local PicaReader = require("ui.reader")
            self.ui:registerPostInitCallback(function()
                local ok, err = pcall(function()
                    PicaReader:onReaderInit(self.ui)
                end)
                if not ok then
                    logger.warn("Picayomi: 阅读器钩子安装失败: " .. tostring(err))
                end
            end)
            self.ui:registerPostReaderReadyCallback(function()
                local native_ok,native_err=pcall(function()require("ui.native_edge_back").install(self.ui)end)
                if not native_ok then logger.warn("Picayomi: 原生边缘返回安装失败: "..tostring(native_err))end
                local ok, err = pcall(function()
                    PicaReader:onReaderReady(self.ui)
                end)
                if not ok then
                    logger.warn("Picayomi: 阅读器就绪钩子失败: " .. tostring(err))
                end
            end)
        else
            -- 在文件管理器中: 注册主菜单
            self.ui.menu:registerToMainMenu(self)
        end
    end)

    if not ok then
        logger.err("Picayomi: init failed: " .. tostring(err))
    end
end

--- 阅读器关闭时清理插件侧状态
--
-- 触发链: `ReaderUI:onClose()` -> `UIManager:close(self)` -> `handleEvent(CloseWidget)`
--   -> `WidgetContainer:propagateEvent` 遍历 ReaderUI 的数组子控件 (插件实例是
--      在 readerui.lua:474 被 registerModule 插进去的, 所以也在其中) -> 本函数。
--
-- 为什么需要: PicaReader 是模块级单例, `attachReaderHooks` 会把 ReaderUI 存进
-- `self._hooks_reader_ui`。不松手的话, 关掉阅读器后那棵控件树 (document /
-- StreamSession / 图片列表 / page_sizes) 一直可达 —— 恰好在用户回到列表页、
-- 最需要内存的时候白占几 MB (这台设备因为 OOM 被 SIGKILL 过)。
--
-- 注意用 `self.ui` (插件实例持有的那个 ReaderUI): 换章时 switchDocument 会关掉
-- **旧**实例, 而新实例有自己的插件实例, 所以这里拿到的一定是正在关闭的那个。
function Picayomi:onCloseWidget()
    -- 诊断: 关掉的是哪个 UI 的插件实例 + 此刻窗口栈里还剩什么。
    --
    -- 这条日志专门用来定位"从阅读页回来、点主页「返回」之后 KOReader 自己退出"
    -- (真机 01:07:47 / 23:20:51: "No dialogs left to show" -> "exit code: 0")。
    -- 需要区分两种完全不同的情况:
    --   ui=FileManager —— 文件浏览器被关掉了 (谁关的? 栈里还剩什么?)
    --   ui=ReaderUI    —— 阅读器被关掉了 (是不是残留实例又被关了一次?)
    if logger.enabled then pcall(function()
        local names = {}
        for _i, entry in ipairs(UIManager._window_stack or {}) do
            local w = entry.widget
            local label = w and (w.name or w.id)
            if not label then
                label = (w and w.is_picayomi_page) and "picayomi_page" or "?"
            end
            names[#names + 1] = tostring(label)
        end
        if logger.enabled then logger.info(string.format("Picayomi: 插件实例关闭 (ui=%s), 窗口栈=[%s]",
            tostring(self.ui and self.ui.name), table.concat(names, ", "))) end
    end) end

    local ok, err = pcall(function()
        require("ui.reader"):onReaderClosed(self.ui)
    end)
    if not ok then
        logger.warn("Picayomi: 阅读器关闭清理失败: " .. tostring(err))
    end
end

--- 读到最后一页: 交给 PicaReader 处理 (下一话确认框 / 完结提示)
--
-- 触发链: KOReader 翻过最后一页时 `handleEvent(Event:new("EndOfBook"))`
--   (readerpaging.lua:1043 / readerrolling.lua:916) -> `WidgetContainer:propagateEvent`
--   遍历 ReaderUI 的数组子控件 (插件实例也在其中) -> 本函数。
--
-- 为什么必须接这一层: 这条链以前断在 `reader_ui.pica_end_callback` 上 —— 写它的
-- `attachReaderHooks` 是活的, 但读它的 eventListener 挂在 `hookWithPriorityOntoReaderUiEvents`
-- 里, 而那个函数全项目没有调用点。于是 `PicaReader:onEndOfBook` 永远不执行,
-- 用户翻到最后一页什么都不会发生。
function Picayomi:onEndOfBook()
    local novel=self.ui and self.ui._picayomi_novel_controls
    if novel then return novel:onEndOfBook() end
    local ok, handled = pcall(function()
        return require("ui.reader"):onEndOfBook()
    end)
    if not ok then
        logger.warn("Picayomi: 章节结束处理失败: " .. tostring(handled))
        return false
    end
    return handled
end

--- 当前阅读器是否正在看 PicaYomi 的漫画
-- @return: session, StreamReader 或 nil
function Picayomi:getActiveStream()
    local ui = self.ui
    local doc = ui and ui.document
    if not doc or doc.provider ~= "picayomi_stream" then
        return nil
    end

    local ok, StreamReader = pcall(require, "ui.stream_reader")
    if not ok or not StreamReader then
        return nil
    end
    return StreamReader.getSession(doc.file), StreamReader
end

--- 退出 / 重启 / 关机前把流式会话收干净
--
-- 为什么必须接这一层: 这些路径**可能不经过** onCloseWidget —— `UIManager:quit`
-- (frontend/ui/uimanager.lua:892-919) 直接清空 `_window_stack` / `_task_queue`,
-- **不关控件**, 于是 `Fork:kill()` 永远不会被调用。而下载子进程在 `runInSubProcess`
-- 里 `setpgid(0,0)` 过、是**独立进程组** —— 父进程退出后被 init 收养, 继续跑
-- (泄漏进程 + 占着 socket + 下次启动又 fork 一个)。
-- 已核实的此类路径: `frontend/device/input.lua:858` 的兜底退出、
-- `frontend/ui/elements/mass_storage.lua:74/87` 的 `quit(86)` (插 USB 时)。
-- 菜单里的「退出」走的是 `ReaderMenu:exitOrRestart` —— 那条路会先 `ui:onClose()`,
-- 所以这里通常是空操作 (getActiveStream 在文档关闭后返回 nil), 留着是为了兜住别的入口。
--
-- 用 shutdown (非阻塞) 而不是 cancel: 退出路径上子进程可能正卡在一个 15 秒的 DNS
-- 解析里, 阻塞等它回收本身就是"退出卡顿"的一部分。
--
-- **不返回值** (nil): 生命周期事件必须继续冒泡, 返回 true 会吞掉它、打断 KOReader
-- 自己的退出流程 (DeviceListener 与别的模块也要处理同一个事件)。
function Picayomi:_shutdownActiveStream()
    local ok, err = pcall(function()
        local session = self:getActiveStream()
        if not session then return end
        session:shutdown()
        if logger.enabled then logger.info("Picayomi: 退出前已收掉流式会话 (取消下载子进程, 不阻塞等待)") end
    end)
    if not ok then
        logger.warn("Picayomi: 退出清理失败: " .. tostring(err))
    end
end

--- 退出前收掉离线下载队列 (与流式会话同一约定: 杀子进程, 不等待)
function Picayomi:_shutdownDownloads()
    require("util.widget_sweep").shutdownTasks()
end

-- KOReader 用 `UIManager:broadcastEvent` 广播这些事件
-- (frontend/ui/elements/common_exit_menu_table.lua 的 Exit / Restart, devicelistener
-- 的 PowerOff / Reboot), 插件实例作为 ReaderUI 的数组子控件能收到 —— 与 onEndOfBook
-- 同一条链 (见上面的注释)。
function Picayomi:onExit() self:_shutdownActiveStream(); self:_shutdownDownloads() end
function Picayomi:onRestart() self:_shutdownActiveStream(); self:_shutdownDownloads() end
function Picayomi:onPowerOff() self:_shutdownActiveStream(); self:_shutdownDownloads() end
function Picayomi:onReboot() self:_shutdownActiveStream(); self:_shutdownDownloads() end

--- USBMS / 其它"广播 Close 后直接 quit"的路径
--
-- `MassStorage:start` 的顺序是 `UIManager:broadcastEvent(Event:new("Close"))`
-- 然后 `UIManager:quit(86)` (frontend/ui/elements/mass_storage.lua:74/87)。
-- `quit` 直接清空窗口栈与任务队列、**不关控件**, 所以 `onCloseWidget` 永远不会跑,
-- 下载子进程 (自己 setpgid 过, 是独立进程组) 会被 init 收养继续跑。
--
-- 真机反馈"退出 KOReader 后插 USB 会断连, 重启 Kindle 才好" 的排查里, 这正是
-- 唯一可能由我们留下来、又能影响 USB  gadget 状态的东西 (子进程还握着 socket 与
-- 文件句柄)。这里用广播的 `Close` 把它收掉 —— 它是 quit 之前**唯一**的信号。
--
-- 不返回值: 生命周期事件必须继续冒泡 (ReaderUI 自己也要处理同一个 Close)。
function Picayomi:onClose()
    self:_shutdownActiveStream()
    -- USBMS 那条路会紧接着 UIManager:quit, 不关控件; 下载子进程同样是独立进程组,
    -- 不在这里收就会变成孤儿继续占用 socket。
    self:_shutdownDownloads()
end

--- 挂起: **只**放开 standby 锁, 绝不取消会话
--
-- 取消之后恢复时页永远下不来, 用户只会看到一片"加载中…"。子进程挂起后若 socket 断了,
-- transport 会靠 `not session:alive()` 发现并报失败 (network/transport_worker.lua:218-225),
-- 下一页重试即可 —— 比"整话静默作废"好得多。
--
-- 为什么必须放开: `ReaderBridge:_prevent_standby` 在有下载在跑时会钉住设备不睡
-- (frontend/ui/uimanager.lua:1732), 挂起路径上如果不放, 恢复后那次 `_allow_standby`
-- 就可能与 UIManager 的计数器错位 —— 而 allowStandby 里是一个 assert (:1722)。
function Picayomi:onSuspend()
    require("source.extensions.updater").cancel()
    require("network.async_task").cancelAll()
    pcall(function()
        local session = self:getActiveStream()
        local driver = session and session.driver
        if driver and driver._allow_standby then driver:_allow_standby() end
    end)
end

--- 恢复: 把可能被挂起打断的驱动循环重新拉起来
--
-- 挂起期间排进 UIManager 的 tick 会被丢掉, 驱动链就断在那里 (它只靠"还有活就重排自己"
-- 往前走, 没有任何外部心跳)。这里补一脚, 剩下的它会自己续上。
function Picayomi:onResume()
    pcall(function()
        local session = self:getActiveStream()
        local driver = session and session.driver
        if driver and driver.resume then driver:resume()
        elseif driver and driver.tick then driver:tick() end
        if session and session.scheduler then
            require("ui.reader_feedback").queue(session, session.scheduler.current_page, "connectivity")
        end
    end)
    -- 离线下载用的是同一种"自己重排自己"的驱动; 挂起期间排进 UIManager 的
    -- tick 会被丢掉, 不补这一脚队列就永远停在那里 (进度条不动, 也没有报错)。
    pcall(function()
        require("util.download_queue").instance():kick()
    end)
end

--- 把 KOReader 的文件浏览器补回"底层界面"
-- 为什么必须补: 打开书本时 KOReader 会关掉 FileManager
-- (FileManager:onShowingReader -> onClose), 所以**阅读期间窗口栈里只有 ReaderUI**。
-- 如果插件关掉阅读器后只显示自己的界面, 那么用户再关掉插件界面时窗口栈就空了 ——
-- KOReader 判定"没有界面了", 会直接退出整个程序。
-- 真机日志 (用户点主页右上角 ✕ 后):
--   "UIManager: No dialogs left to show" -> "Tearing down UIManager with exit code: 0"
-- 这正是 KOReader 自己的 ReaderUI:onHome 做的事 (onClose + showFileManager)。
-- 具体实现 (含"放栈底"的理由) 在 util/widget_sweep.lua 的 ensureBase。
local function restoreFileManagerBase()
    pcall(function()
        require("util.widget_sweep").ensureBase()
    end)
end

-- 暴露给测试 (与 StreamDocument.Session 同例): 验证"关阅读器后窗口栈不会变空"
Picayomi.restoreFileManagerBase = restoreFileManagerBase

--- 结束阅读并回到 PicaYomi (优先回到本话所属漫画的详情页)
function Picayomi:returnToPicayomi()
    local session = self:getActiveStream()
    local ctx = session and session.context or nil

    -- 计时点: 这条路径上全是**同步**开销 (关阅读器 + 补底层 + 重建主页与详情页),
    -- 真机反馈"从阅读页返回有点慢"。没有这几个点, 下次只能再猜是哪一段。
    --
    -- 用 socket.gettime (墙钟, 亚秒) 而不是 os.time: 整条路径要量的就是"慢在哪
    -- 几百毫秒", 秒级精度什么都看不出来。拿不到 luasocket 时退回 os.time (至少
    -- 能区分"1 秒内"和"十几秒")。
    local Diag = require("util.diag")
    local clock = os.time
    if Diag.enabled then
        local cok, socket = pcall(require, "socket")
        if cok and type(socket) == "table" and socket.gettime then clock = socket.gettime end
    end
    local t0 = Diag.enabled and clock() or 0
    local function mark(what)
        if Diag.enabled then Diag.mark(string.format("return %s: %s (+%.2fs)",
            tostring(ctx and ctx.comic and ctx.comic._id), what, clock() - t0)) end
    end
    if Diag.enabled then mark(string.format("点击返回 (已读 %s/%s 页)",
        tostring(session and session.downloaded), tostring(session and session.total))) end

    -- 关阅读器是**同步阻塞**的 1~5 秒 (saveSettings / DocCache / Fork:kill)。
    -- 不先画一条提示的话, 这段时间屏幕完全不动, 用户只会觉得"点了没反应/卡死"。
    -- 必须在 nextTick **之前** show + forceRePaint: 真正的关阅读器在下一拍里,
    -- 不强制刷一次的话提示根本还没画出来就开始阻塞了。
    if self._return_info then return end
    local info = require("ui.common.loading_task").showReturning()
    self._return_info = info

    -- **关阅读器与补底层界面必须落在同一轮同步代码里**, 不能先关再排期补。
    --
    -- 原因: `UIManager:handleInput` 每轮都检查 `_window_stack[1]`, 空就记
    -- "No dialogs left to show" 并退出整个 KOReader (uimanager.lua:1556)。
    -- 而阅读期间窗口栈里**只有 ReaderUI** (打开书本时 KOReader 关掉了 FileManager)。
    -- 所以"先关阅读器, 再靠一个延迟任务补底层"会让窗口栈空掉一整段 ——
    -- 而那个空栈检查是**立即**的, 定时器根本轮不到执行:
    --   真机日志 23:09:00 / 01:06:28 都是 "ReaderUI 关闭" 与
    --   "No dialogs left to show" 同一秒, 用户根本没想退出 KOReader。
    -- (栈里恰好还有别的插件页面时才侥幸躲过 —— 那正是 00:20:09 那次为什么没事。)
    --
    -- 为什么是 nextTick 而不是原来的 0.3 秒: 那个 0.3s 是**上一版结构的残留** ——
    -- 上一版是"立刻关阅读器, 0.3 秒后再补底层", 延迟是为了让阅读器关掉的那次重绘
    -- 先落地。现在关阅读器与补底层已经在同一个回调里 (同一次刷新前完成), 那个理由
    -- 不成立了, 而 0.3s 是**每次返回都要白等**的一段死时间 (用户感觉到的"有点慢")。
    -- nextTick = scheduleIn(0) 的**单次**任务: 不违反 reader_bridge 那条
    -- "不能 0 延迟自我重排"的约束 (这里只排一次, 不续期), 也让出当前这一轮
    -- 事件处理 (菜单项回调还在栈上)。
    UIManager:nextTick(function()
        -- 关闭阅读器 (会触发文档关闭与会话清理)
        pcall(function() self.ui:onClose() end)
        if Diag.enabled then mark("阅读器已关闭") end

        local sweep
        local sweep_ok, sweep_mod = pcall(require, "util.widget_sweep")
        if sweep_ok then sweep = sweep_mod end

        -- **阅读器下面压着的就是"打开阅读的那条路径"。**
        --
        -- api/comic.lua 在打开阅读器时**故意不关详情页** (它注释里写得很清楚:
        -- 详情页就是读完要回到的那一页), 详情页下面的列表 (收藏/分类/搜索/历史)
        -- 也一直留着。所以关掉阅读器之后, 栈顶天然就是那张详情页, 再返回一次
        -- 就是用户原来那个列表 —— 位置、页码、已加载的缓冲全都在。
        --
        -- 因此这里**绝不能清扫、也不能重建**。旧实现无条件 closeAll + new Home
        -- + new 详情页, 把"来路"整条丢掉了: 新详情页的 on_back 指向主页, 于是
        --   收藏页 -> 详情 -> 阅读 -> 「返回 Picayomi」-> 详情 -> 返回 = **主页**
        -- 收藏列表连同它的页码一起消失 (真机反馈 2026-10-17)。
        --
        -- 只在**栈里没有任何插件页面**时才退回旧行为 (理论上不该发生: 所有阅读
        -- 入口都要经过详情页; 这是给"将来某个新入口直接开阅读器"的兜底)。
        local preserved = (sweep and sweep.list and sweep.list()) or {}

        local function finish_return()
            if Diag.enabled then mark("完成") end
            -- 目标页面已经在提示框下面了, 收掉提示让用户看到它
            if self._return_info then
                pcall(function() UIManager:close(self._return_info, "ui") end)
                self._return_info = nil
            end
        end

        if #preserved > 0 then
            -- 阅读期间 KOReader 关掉了 FileManager, 补回栈底即可; 插件页面一个不动。
            restoreFileManagerBase()
            if Diag.enabled then mark(string.format("保留来路页面 %d 个", #preserved)) end
            return finish_return()
        end

        -- 兜底: 栈里没有任何插件页面 (理论上不该发生) —— 才重建主页 + 详情页。
        pcall(function() if sweep then sweep.closeAll() end end)

        -- 补上文件浏览器作为底层, 再叠插件界面 —— 三件事在同一次刷新前完成,
        -- 所以窗口栈不会出现"空"的瞬间, 用户也看不到中间的闪动。
        restoreFileManagerBase()
        if Diag.enabled then mark("底层已补回") end

        local ok, err = pcall(function()
            local HomeView = require("ui.home")
            local home = HomeView:new{}
            -- 先建立主菜单作为返回目标
            home:show()
            if Diag.enabled then mark("主页已建") end
            -- 再叠上刚才那本漫画的详情, 方便接着看下一话。
            --
            -- **把章节列表一起给它**: ComicDetail:init 在拿到 episodes_data 时会跳过
            -- `loadChapters(1)` (ui/common/comic_detail.lua:258), 而那个调用是一次
            -- **同步网络请求** —— 压在"关阅读器回详情页"这条路径上, 用户看到的就是
            -- 一个网络 RTT 的卡顿。章节列表本来就在阅读上下文里, 白拿。
            if ctx and ctx.comic then
                -- **形状必须包一层**: ctx.episodes 是 ui/reader.lua 的 episodes_list ——
                -- 一个**裸的章节数组** (main.lua 的 openEpisodeAt 就是按 ctx.episodes[i]
                -- 取用的, 所以它本身不能改形状)。而 ComicDetail 要的是
                -- `{ episodes = ..., page =, pages =, total = }`。
                --
                -- 直接把裸数组当 episodes_data 传下去的后果 (用户报的就是这个):
                --   * 详情页 `data.episodes` 是 nil → 判定"一章都没有", 显示
                --     「该漫画没有可阅读的章节」;
                --   * 而且 episodes_data 非空, comic_detail.lua:258 的短路生效 ——
                --     连章节都不会去拉, 于是这句话会一直挂着;
                --   * 页脚「开始」「继续」也被 hasEpisodes() 判为不可用。
                -- 触发路径: 读完一话 -> 菜单「返回 Picayomi」-> 回到该漫画详情页。
                local eps = ctx.episodes
                local episodes_data = eps and {
                    episodes = eps,
                    page = 1,
                    pages = 1,
                    total = #eps,
                } or nil
                home:showComicDetail(ctx.comic, episodes_data)
                if Diag.enabled then mark("详情页已建") end
            end
        end)
        if not ok then
            logger.err("Picayomi: returnToPicayomi failed: " .. tostring(err))
        end
        finish_return()
    end)
end

--- 打开指定索引的章节 (用于"上一话/下一话")
--
-- 统一交给 PicaReader:switchToChapter: 它在当前阅读器里换文档 (switchDocument),
-- 不重开阅读器、不闪文件浏览器。这里只做一个"当前确实在看漫画"的守卫。
function Picayomi:openEpisodeAt(index)
    local session = self:getActiveStream()
    local ctx = session and session.context or nil
    if not ctx or not ctx.episodes or not ctx.comic then
        UIManager:show(InfoMessage:new{
            text = _("无法获取章节列表，请从漫画详情页进入"),
            timeout = 3,
        }, "ui")
        return
    end

    if not ctx.episodes[index] then return end

    require("ui.reader"):switchToChapter(index)
end

function Picayomi:addToMainMenu(menu_items)
    -- 本插件在「工具」页里注册的所有项, 按期望的显示顺序收集起来
    -- (最后统一排位 —— 见下面的 promoteInToolsMenu)
    local ordered_ids = {}
    -- Clear dynamic entries before rebuilding a reused menu for another book.
    for _i, id in ipairs({"picayomi", "picayomi_return", "picayomi_prev_episode", "picayomi_next_episode", "picayomi_save_image", "picayomi_chapter_directory", "picayomi_novel"}) do
        menu_items[id] = nil
    end
    local novel=self.ui and self.ui._picayomi_novel_controls
    if novel then
        novel:addToMainMenu(menu_items)
        promoteInToolsMenu({"picayomi_return","picayomi_prev_episode","picayomi_next_episode"})
        return
    end

    -- 正在阅读 PicaYomi 漫画时, 补上"看完怎么回去"的入口。
    -- addToMainMenu 每次打开菜单都会被调用, 因此这里可以按状态动态添加。
    local session = self:getActiveStream()

    -- 「Picayomi」= "从 KOReader 进插件"的入口。已经在插件里的时候它就没有意义了,
    -- 而且旁边还有「返回 Picayomi」—— 两项并列反而让人分不清该点哪个
    -- (用户反馈"已经进入 picayomi 后, 多一个 picayomi 选项很多余")。
    -- 所以只在**没有活动会话**时注册它; 阅读中靠「返回 Picayomi」回详情页,
    -- 详情页的「返回」再回主页, 路径是通的。
    if not session then
        menu_items.picayomi = {
            text = _("Picayomi"),
            -- 放到"工具"菜单页 (扳手图标)，与 Wallabag / 新闻下载器等
            -- 功能型插件同级，便于查找
            sorting_hint = "tools",
            callback = function()
                self:openHome()
            end
        }
        ordered_ids[#ordered_ids + 1] = "picayomi"
    end

    if session then
        menu_items.picayomi_return = {
            text = _("返回 Picayomi"),
            sorting_hint = "tools",
            callback = function()
                -- Same exit-reading path as the footer/edge action: preserve
                -- the detail/list and run its return callback to refresh state.
                require("ui.reader"):onReturn()
            end,
        }
        ordered_ids[#ordered_ids + 1] = "picayomi_return"

        local ctx = session.context
        if ctx and ctx.episodes then
            local idx
            for i, ep in ipairs(ctx.episodes) do
                if tostring(ep.order) == tostring(session.order) then
                    idx = i
                    break
                end
            end

            if idx and ctx.episodes[idx + 1] then
                menu_items.picayomi_next_episode = {
                    text = T(_("下一话：%1"), ctx.episodes[idx + 1].title or ""),
                    sorting_hint = "tools",
                    callback = function()
                        self:openEpisodeAt(idx + 1)
                    end,
                }
            end
            if idx and idx > 1 then
                menu_items.picayomi_prev_episode = {
                    text = T(_("上一话：%1"), ctx.episodes[idx - 1].title or ""),
                    sorting_hint = "tools",
                    callback = function()
                        self:openEpisodeAt(idx - 1)
                    end,
                }
                ordered_ids[#ordered_ids + 1] = "picayomi_prev_episode"
            end
            if menu_items.picayomi_next_episode then
                ordered_ids[#ordered_ids + 1] = "picayomi_next_episode"
            end
        end

        local ComicImage = require("ui.comic_image")
        if ComicImage.available(self.ui) then
            menu_items.picayomi_save_image = {
                text = _("保存当前页原图"),
                sorting_hint = "tools",
                callback = function() ComicImage.chooseAndSave(self.ui) end,
            }
            ordered_ids[#ordered_ids + 1] = "picayomi_save_image"
        end
    end

    -- 排位: 本插件的项要**连在一起**排在「工具」页最前。
    -- 不写进 order 表的项会被 menusorter 追加到末尾 —— 那样"返回 Picayomi"
    -- 会跟 Picayomi 分家、掉到列表最末。id 不存在时 menusorter 会跳过, 多列无妨。
    promoteInToolsMenu(ordered_ids)
end

--- 进入应用时检查网络
--
-- 为什么必须提示: 首页一进来就是网络列表 (推荐/最新), 断网时用户看到的是
-- "加载推荐漫画..."转几秒然后一句"获取失败: ..." —— 像是插件坏了。明确说
-- "没有网络连接"才是可行动的信息 (去开 Wi-Fi)。
--
-- **只提示, 不拦截**: 已缓存的漫画、浏览历史、收藏里的本地条目都还能看,
-- 挡住入口反而更糟。提示自己带 timeout, 不占用户操作。
--
-- `NetworkMgr:isConnected()` 在 Kindle 上是"当前有已连接的 Wi-Fi 且拿到地址"
-- (frontend/ui/network/manager.lua 的平台实现), 比 ping 外网便宜且不耗流量。
function Picayomi:checkNetwork()
    local ok, connected = pcall(function()
        return require("ui/network/manager"):isConnected()
    end)
    -- 取不到网络状态 (老版本/别的设备) 时不打扰用户: 宁可少提示, 不要误报
    if not ok or connected then return true end

    if logger.enabled then logger.info("Picayomi: 进入应用时没有网络连接, 已提示用户") end
    UIManager:show(InfoMessage:new{
        text = _("当前没有网络连接。\n\n"
            .. "请先在 KOReader 里打开 Wi-Fi 再浏览/阅读；\n"
            .. "已缓存的作品与浏览历史仍可查看。"),
        timeout = 6,
    }, "ui")
    return false
end

--- 打开主界面
function Picayomi:openHome()
    local loading = InfoMessage:new{ text = _("Picayomi 启动中...") }
    UIManager:show(loading, "ui")
    -- 同步刷一次: show 只是把刷新入队, 而这里马上要阻塞做网络请求,
    -- 不等这一下的话事件循环没机会重绘, 提示等于没显示
    UIManager:forceRePaint()

    UIManager:scheduleIn(0.1, function()
        UIManager:close(loading, "ui")

        local ok, err = pcall(function()
            -- 从工具菜单再次打开时, 上一次留下的页面可能还在栈里 (用户没走"返回"),
            -- 先清掉, 免得栈里堆出好几层长得一模一样的界面。
            require("util.widget_sweep").closeAll()

            local HomeView = require("ui.home")
            local home = HomeView:new{}
            -- Home 是容器，必须调用 :show() 才会显示主菜单；
            -- 直接 UIManager:show(home) 会显示一个空容器 (白屏)。
            home:show()
        end)

        if not ok then
            logger.err("Picayomi: openHome failed: " .. tostring(err))
            UIManager:show(InfoMessage:new{
                text = T(_("Picayomi 启动失败: %1"), require("ui.common.error_message").describe(err)),
                timeout = 5,
            }, "ui")
        end

        -- 断网提示放在"清扫"之后: closeAll 会关掉栈里所有插件页面**以及压在其上的
        -- 弹窗**, 先弹的话会被它自己清掉 (用户什么都看不到)。
        self:checkNetwork()
    end)
end

return Picayomi
