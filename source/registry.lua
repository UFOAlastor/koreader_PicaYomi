-- source/registry.lua
-- 漫画源注册表
-- 管理所有可用的漫画源，支持按名称获取和切换

local logger = require("util.logger")
local config = require("util.config")

local SourceRegistry = {}

-- 已注册的源
local registered_sources = {}

-- 当前活跃的源标识
local current_source_id = nil

local function local_sources()
    local ok, ids = pcall(function() return require("source.offline").knownIDs() end)
    return ok and ids or {}
end

--- 注册一个漫画源
function SourceRegistry:register(source)
    if not source or not source.identifier or source.identifier == "" then
        logger.err("Picayomi SourceRegistry: 注册失败，缺少 identifier")
        return false
    end

    if logger.enabled then logger.info("Picayomi SourceRegistry: 注册源 " .. source.identifier) end
    registered_sources[source.identifier] = source
    return true
end

--- 注销一个源
function SourceRegistry:unregister(identifier)
    registered_sources[identifier] = nil
    if current_source_id == identifier then
        current_source_id = nil
    end
end

--- 获取所有已注册的源
function SourceRegistry:getAll()
    return registered_sources
end

--- 获取源列表
function SourceRegistry:list(include_local)
    local result = {}
    for id, source in pairs(registered_sources) do
        if include_local or not source._offline then
            table.insert(result, {
                identifier = id,
                name = source.name or id,
                content_type = source.content_type or "comic",
                capabilities = source.capabilities or {},
            })
        end
    end
    if include_local then
        self._local_ids = local_sources()
        for id in pairs(self._local_ids) do
            if not registered_sources[id] then
                result[#result + 1] = { identifier = id, name = id .. "（源已删除）",
                    content_type = require("source.offline").new(id).content_type or "comic",
                    capabilities = { local_favorites = true }, offline = true }
            end
        end
    end
    local priority = {copymanga=10,htcomic=100,jm=101,picacg=102}
    table.sort(result, function(a, b)
        local a_novel,b_novel=a.content_type=="novel",b.content_type=="novel"
        if a_novel~=b_novel then return a_novel end
        local ap,bp=priority[a.identifier] or 20,priority[b.identifier] or 20
        if ap~=bp then return ap<bp end
        return a.identifier < b.identifier
    end)
    return result
end

--- 获取指定源
function SourceRegistry:get(identifier)
    return registered_sources[identifier]
end

--- 获取当前活跃的源
function SourceRegistry:getCurrent()
    if not current_source_id then
        current_source_id = config:get("current_source") or "picacg"
    end
    return registered_sources[current_source_id]
end

--- 切换当前源
function SourceRegistry:switch(identifier)
    if not registered_sources[identifier] and self._local_ids and self._local_ids[identifier] then
        self:register(require("source.offline").new(identifier))
    end
    if not registered_sources[identifier] then
        logger.err("Picayomi SourceRegistry: 源不存在: " .. tostring(identifier))
        return false
    end

    current_source_id = identifier
    config:set("current_source", identifier)
    if logger.enabled then logger.info("Picayomi SourceRegistry: 切换到源 " .. identifier) end
    return true
end

--- 获取当前源标识
function SourceRegistry:getCurrentId()
    if not current_source_id then
        current_source_id = config:get("current_source") or "picacg"
    end
    return current_source_id
end

--- 内置源清单 (新增源只需在此追加一项)
-- 当前范围: 源 A / 源 B / 源 C
-- 注: 旧源 已删除 (v0.9.44) —— 其登录依赖浏览器 Cookie, Kindle 上无法粘贴.
--     如需恢复, 从 git 历史取回 source/旧源/ 并在此加回一行.
local BUILTIN_SOURCES = {
    { id = "picacg",  module = "source.picacg.init" },
    { id = "jm",      module = "source.jm.init" },
    { id = "htcomic", module = "source.htcomic.init" },
}

--- 默认源 (首次启动时使用)
local DEFAULT_SOURCE = "picacg"

--- 配置里记着的源是不是内置源 (哪怕这次模块没加载成功)


--- 校正当前源: 只有"配置里的源根本不存在了"才回退到默认源
---
--- **不能**拿"不在注册表里"当回退条件: 某个源模块这次加载失败 (缺依赖 / 偶发错误)
--- 时它不在注册表里, 但用户上次选的正是它 —— 那样会拿兜底值**写回配置**,
--- 把用户的选择永久抹掉, 下次启动就"记不住上次选的源"了。
--- 内置源只要还在清单里就保留配置值; 真正被移除的源才回退。
local function fix_current_source(registry)
    local cur = config:get("current_source")
    if cur and not registered_sources[cur] and local_sources()[cur] then
        registry:register(require("source.offline").new(cur))
    end
    local external = package.loaded["source.extensions.manager"]
    local installed = type(external) == "table" and external.instance().state.sources[cur]
    if cur and (registered_sources[cur] or installed and installed.enabled) then
        current_source_id = cur
        return
    end

    local fallback = DEFAULT_SOURCE
    if not registered_sources[fallback] then
        local first = registry:list()[1]
        fallback = first and first.identifier
    end
    if fallback then
        current_source_id = fallback
        config:set("current_source", fallback)
    end
end

--- 初始化所有内置源
--
-- **幂等**: 每个 UI 实例 (FileManager / ReaderUI) 都会调一次, 而**打开阅读器**那次
-- 正好落在"点开始"的等待窗口里 (真机日志 00:51:46)。已注册的源直接跳过 —— 省掉的
-- 是每次 register 的赋值与一条 logger.info (写盘), 在 Kindle 上不白花。
--
-- 判据是**逐个源**的 (而不是"全都注册过就整批跳过"): 某个源模块加载失败时
-- (缺依赖/语法错), 整批式的守卫会永远不成立, 于是每次都重跑一遍全部注册 ——
-- 恰恰在降级状态下最费。逐个判还能保证: unregister 掉某个源之后它会被补回来。
function SourceRegistry:initBuiltinSources()
    -- Boot snapshot: never activate a just-installed package in this process.
    local ok, err = pcall(function()
        require("source.extensions.manager").instance():loadSources(self)
    end)
    if not ok then logger.err("Picayomi extensions: " .. tostring(err)) end
    fix_current_source(self)
end

--- 内置源清单 (供 UI 展示)
function SourceRegistry:getBuiltinList()
    local result={}
    local bundles=require("source.extensions.manager").instance().bundles or {}
    for _,entry in ipairs(BUILTIN_SOURCES) do if bundles[entry.id] then result[#result+1]=entry end end
    return result
end

return SourceRegistry
