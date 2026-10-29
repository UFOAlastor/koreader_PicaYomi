-- util/widget_sweep.lua
-- 清扫窗口栈里遗留的插件页面
--
-- 背景 (真机反馈"退出 Picayomi 偶尔还是冒出来历史打开过的页面"):
-- 插件的每个页面都是独立的全屏控件, 各自压进 UIManager 的窗口栈。只要有一条路径
-- 忘了把它弹出去, 它就会一直躺在栈里; 之后关掉上层页面时, 它就被"露"出来 ——
-- 用户看到的就是"刚才那个页面又冒出来了"。
-- 最典型的一处: main.lua 的 returnToPicayomi 会 new 一个**全新的 Home**, 而进入
-- 阅读器之前那个旧 Home 的主菜单还留在栈里, 于是返回 KOReader 时会先弹出一层旧菜单。
--
-- 约定: 顶层页面标记 `is_picayomi_page = true` (类上标一次即可覆盖全部实例,
-- 或在 `Menu:new{}` 的字面量里标), 清扫时统一关掉。
-- **阅读器 (ReaderUI) 不标记** —— 它由 KOReader 自己管, 插件不去碰。
local UIManager = require("ui/uimanager")
local logger = require("util.logger")

local M = {}

function M.shutdownTasks()
    local actions={
        function()require("ui.downloads").shutdownAll()end,
        function()require("source.extensions.updater").cancel()end,
        function()require("util.download_queue").instance():shutdown("已退出 PicaYomi，可在下载页重试")end,
        function()require("ui.common.loading_task").cancelAll()end,
        function()require("network.async_task").cancelAll(true)end,
        function()require("util.cover_cache").shutdown()end,
        function()require("util.favorites").releaseMemory()end,
        function()require("util.cache"):clear()end,
        function()
            for _,source in pairs(require("source.registry"):getAll())do
                if source.releaseMemory then source:releaseMemory()end
            end
        end,
        function()require("ui.home").instance=nil end,
    }
    for _,action in ipairs(actions)do
        local ok,err=pcall(action)
        if not ok then logger.warn("Picayomi: 退出任务清理失败: "..tostring(err))end
    end
end

--- 用新页面替换旧页面: **先 show 新的, 再关旧的**
--
-- 反过来写 (先 close 再 show) 在真机上一眼就能看见: 取数是同步的 1~2 秒,
-- 那段时间屏幕上露出的是**上一页** (主页 / 分类菜单 / 搜索框) —— 用户报的
-- "点了排序先退回上一页, 再刷出排序后的列表" 全是这一个原因。
--
-- 先 show 再 close 的代价是窗口栈里会短暂同时存在两页, 但新页是整屏的,
-- 视觉上就是"旧页直接被新页盖住", 没有空档。close 时旧页已经不在栈顶,
-- 不会把下层露出来。
--
-- @param old 旧页面 (可为 nil / 已不在栈里)
-- @param new 新页面
-- @return new
function M.replace_page(old, new)
    if new then
        UIManager:show(new, "ui")
    end
    if old and old ~= new and M.isInStack(old) then
        UIManager:close(old, "ui")
    end
    return new
end

--- 把一个控件标记为"插件顶层页面"
function M.mark(widget)
    if type(widget) == "table" then
        widget.is_picayomi_page = true
    end
    return widget
end

--- 窗口栈里的插件页面 (从下到上, 与栈顺序一致)
function M.list()
    local out = {}
    local stack = UIManager._window_stack
    if type(stack) ~= "table" then return out end
    for _i, entry in ipairs(stack) do
        local w = entry and entry.widget
        if type(w) == "table" and w.is_picayomi_page then
            out[#out + 1] = w
        end
    end
    return out
end

--- 某个控件是否在窗口栈里
function M.isInStack(widget)
    if type(widget) ~= "table" then return false end
    local stack = UIManager._window_stack
    if type(stack) ~= "table" then return false end
    for _i, entry in ipairs(stack) do
        if entry and entry.widget == widget then return true end
    end
    return false
end

--- 把 KOReader 自己的文件浏览器放回窗口栈**底部** (已经在底层则什么都不做)
--
-- 为什么必须有它: `UIManager:handleInput` 每轮都检查 `_window_stack[1]`, 空就记
-- "UIManager: No dialogs left to show" 并退出整个 KOReader (uimanager.lua:1556)。
-- 而打开书本时 KOReader 会**关掉** FileManager (`FileManager:onShowingReader` ->
-- `onClose` -> `onCloseWidget` 把 `FileManager.instance` 置 nil), 所以阅读期间栈里
-- 只剩 ReaderUI —— 插件页面一旦成了"最后一层", 关掉它就会连 KOReader 一起退掉。
-- 真机日志里这条序列出现过多次 (见 docs/真机验收清单.md 的 4.15)。
--
-- 注意是放**底部**而不是 `UIManager:show`: show 只会追加到栈顶, 会在插件界面
-- **之上**盖一层文件浏览器 —— 用户看到闪一下, 而且层级是反的。
function M.ensureBase()
    local FileManager = require("apps/filemanager/filemanager")
    local stack = UIManager._window_stack
    if type(stack) ~= "table" then return nil end

    local fm = FileManager.instance
    -- 已经在栈里就什么都不做: 不 reinit, 免得白白重排一次目录
    if fm and M.isInStack(fm) then return fm end

    if fm then
        -- 实例还在但不在栈里 (半关闭状态): 直接放回去
        if logger.enabled then logger.info("Picayomi: 把文件浏览器放回窗口栈底") end
        UIManager:show(fm)
    else
        if logger.enabled then logger.info("Picayomi: 文件浏览器已被关掉, 重建一个作为底层") end
        FileManager:showFiles()      -- 内部就是 new + UIManager:show
        fm = FileManager.instance
    end

    -- 挪到栈底 (只有它一个时本来就在栈底, 循环自然不做事)
    if fm then
        for i = #stack, 1, -1 do
            if stack[i].widget == fm then
                table.insert(stack, 1, table.remove(stack, i))
                break
            end
        end
    end
    return fm
end

--- 关掉所有遗留的插件层; 返回关掉的个数
--
-- 关闭前置 `sweeping` 标记: 页面的 onCloseWidget 一般会调 on_back 去"重建/重载"
-- (例如详情页返回收藏列表)。清扫时那是反效果 —— 会把刚关掉的页面又建回来, 甚至
-- 顺带发起网络请求。ComicDetail 认这个标记, 直接跳过 on_back。
--
-- **清扫范围 = 从最下面那层插件页面起, 往上全部关掉**, 而不是只关带标记的那些。
--
-- 为什么: 插件页面之上叠着的东西一定是本次 Picayomi 会话自己压上去的 —— 搜索输入框、
-- 跳页弹窗、确认框、标签菜单、虚拟键盘…… 它们都是直接 `UIManager:show` 出来的,
-- 不会(也不该)记得给自己带标记。只认标记的话, 漏标一个就漏一个:
--   用户报的"点过搜索后, 从 Picayomi 返回 KOReader, 搜索框还留在屏幕上"
--   就是搜索输入框没带标记、又被某条路径忘记关闭造成的。
-- 以**带标记的页面**为锚点就不存在"漏标一个弹窗"的问题 —— 弹窗只可能压在页面之上。
--
-- 注意锚点必须是最下面那层插件页面 (不是任意一层): 栈底之上可能还有别的插件/KOReader
-- 自己的窗口, 它们压在插件页面**下面**, 绝不能动 (见 test 里的 sweep_test_other)。
function M.closeAll()
    local stack = UIManager._window_stack
    if type(stack) ~= "table" then return 0 end

    -- 锚点: 栈里最下面那层带标记的插件页面
    local anchor
    for i, entry in ipairs(stack) do
        local w = entry and entry.widget
        if type(w) == "table" and w.is_picayomi_page then
            anchor = i
            break
        end
    end
    if not anchor then return 0 end

    -- 从栈顶往下收集 (关闭顺序与用户连按返回键一致, 免得底层控件先被 free)
    local doomed = {}
    for i = #stack, anchor, -1 do
        local w = stack[i] and stack[i].widget
        if type(w) == "table" then doomed[#doomed + 1] = w end
    end

    for _i, w in ipairs(doomed) do
        w.sweeping = true
        -- 控件处于半关闭状态是常有的事, 出错不能影响退出流程
        local ok, err = pcall(function() UIManager:close(w, "ui") end)
        if not ok then
            if logger.enabled then logger.dbg("Picayomi: 清扫页面失败: " .. tostring(err)) end
        end
    end
    if #doomed > 0 then
        if logger.enabled then logger.info("Picayomi: 清扫遗留页面 " .. #doomed .. " 个") end
    end
    return #doomed
end

return M
