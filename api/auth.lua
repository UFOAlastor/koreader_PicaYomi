-- api/auth.lua (兼容层)
-- 代理到"当前漫画源"的认证实现
--
-- 注意: 旧版本这里硬编码走 picacg，导致切换到其它源后登录会串源。
-- 现改为统一委托给 SourceRegistry:getCurrent()。
-- 各源自行决定登录方式:
--   picacg / jm -> login(账号, 密码)
--   htcomic     -> login(账号, 密码) (可选, 不登录也能浏览)

local logger = require("util.logger")
local SourceRegistry = require("source.registry")

local AuthAPI = {}

--- 取得当前源 (必要时初始化)
local function currentSource()
    local source = SourceRegistry:getCurrent()
    if source and not source._source_runtime and not source._http_client then
        pcall(function() source:init() end)
    end
    return source
end

--- 当前源的登录方式: "password" 或 "cookie"
function AuthAPI:getLoginMethod()
    local source = currentSource()
    if source and source.login_method then
        return source.login_method
    end
    return "password"
end

function AuthAPI:getToken()
    local source = currentSource()
    return source and source:getToken() or nil
end

--- 仅源 A 支持直接写入 token
function AuthAPI:setToken(token)
    local source = currentSource()
    if source and source.setToken then
        source:setToken(token)
    end
end

function AuthAPI:isLoggedIn()
    local source = currentSource()
    return source and source:isLoggedIn() or false
end

--- 登录
-- @param a: 账号 (picacg 为用户名/邮箱)
-- @param b: 密码
-- @return: true 或 false, nil, err
function AuthAPI:login(a, b)
    local source = currentSource()
    if not source then
        return false, nil, "没有可用的源"
    end

    local ok, err = source:login(a, b)
    if ok then
        return true
    end
    return false, nil, err
end

function AuthAPI:logout()
    local source = currentSource()
    if source then
        source:logout()
    end
end

--- 获取用户信息 (兼容旧接口: 返回 success, profile, error_msg)
-- 缓存与持久化均按"源"隔离, 避免切换到其它源后拿到上一个源的账号
function AuthAPI:getProfile()
    local cache = require("util.cache")
    local SecretStore = require("util.secret_store")

    local source = currentSource()
    if not source then
        return false, nil, "没有可用的源"
    end
    if not source:isLoggedIn() then
        return false, nil, "未登录"
    end

    local profile_key = "source_profile." .. source.identifier
    local cache_key = "source_profile_" .. source.identifier .. "_" ..
        math.floor(os.time() / 3600)

    -- 命中缓存
    local cached = cache:getData(cache_key)
    if cached then
        return true, cached
    end

    local profile, err = source:getUserProfile()
    if not profile then
        return false, nil, err or "获取用户信息失败"
    end

    -- 补齐 UI 需要的字段
    profile.name = profile.name or "未知用户"
    profile.id = profile.id or "unknown_id"

    cache:cacheData(cache_key, profile, os.time() + 3600)
    -- 资料里有邮箱/昵称等 PII, 同样不写明文
    SecretStore.set_json(profile_key, profile)

    return true, profile
end

--- 兼容接口: 直接返回源原始资料
function AuthAPI:getUserProfile()
    local source = currentSource()
    if not source then return nil, "没有可用的源" end
    return source:getUserProfile()
end

function AuthAPI:punchIn()
    local source = currentSource()
    if not source then return false, "没有可用的源" end
    return source:punchIn()
end

return AuthAPI
