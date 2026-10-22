-- model/user.lua
-- 用户信息模型 (兼容旧接口)
--
-- 关键: 用户信息必须按"当前漫画源"隔离。
-- 旧实现直接从全局 config 读取 token/user_profile，导致切换到其它源后
-- 仍显示源 A 的账号 (甚至会误判为"已登录")。现统一委托给 SourceRegistry。

local SecretStore = require("util.secret_store")
local logger = require("util.logger")

local UserModel = {}

--- 当前源 (必要时初始化)
local function currentSource()
    local ok, SourceRegistry = pcall(require, "source.registry")
    if not ok or not SourceRegistry then
        return nil
    end
    local source = SourceRegistry:getCurrent()
    if source and not source._source_runtime and not source._http_client then
        pcall(function() source:init() end)
    end
    return source
end

--- 当前源的用户资料在 config 中的键 (按源隔离)
-- 使用独立命名空间, 避免与旧的全局 user_profile 键冲突
local function profileKey(source_id)
    return "source_profile." .. (source_id or "unknown")
end

--- 读取当前源缓存的用户资料
function UserModel:getUserProfile()
    local source = currentSource()
    if not source then
        return nil
    end

    local profile = SecretStore.get_json(profileKey(source.identifier))
    if profile then
        return profile
    end

    -- 缓存为空时回源查询: 有些源(如源 B)的资料只在内存里, 从不主动落盘,
    -- 只看缓存会误判成"未登录/无资料"。
    if source.getUserProfile then
        local pok, live = pcall(function() return source:getUserProfile() end)
        if pok and live then
            SecretStore.set_json(profileKey(source.identifier), live)
            return live
        end
    end

    -- 兼容: 源 A 旧版本把资料存在全局 profile 键 (启动迁移会把它变成密文)
    if source.legacyProfile then
        return source:legacyProfile()
    end

    return nil
end

--- 缓存当前源的用户资料
function UserModel:saveUserProfile(profile)
    local source = currentSource()
    if source and profile then
        SecretStore.set_json(profileKey(source.identifier), profile)
    end
end

--- 清除当前源的用户资料
function UserModel:clearUserProfile()
    local source = currentSource()
    if source then
        SecretStore.clear(profileKey(source.identifier))
    end
end

-- 检查用户是否登录 (完全以当前源为准)
function UserModel:isLoggedIn()
    local source = currentSource()
    if not source then
        return false
    end
    local logged = source:isLoggedIn()
    if logged then
        if logger.enabled then logger.dbg("Picayomi UserModel: 当前源 " .. source.identifier .. " 已登录") end
    end
    return logged
end

-- 获取用户 Token
function UserModel:getToken()
    local source = currentSource()
    return source and source:getToken() or nil
end

-- 获取用户名
function UserModel:getUserName()
    local profile = self:getUserProfile()
    if not profile then
        return "未登录用户"
    end
    return profile.name or "未知用户"
end

-- 获取用户等级
function UserModel:getUserLevel()
    local profile = self:getUserProfile()
    if not profile then
        return 0
    end
    return profile.level or 0
end

-- 获取用户经验值
function UserModel:getUserExp()
    local profile = self:getUserProfile()
    if not profile then
        return 0
    end
    return profile.exp or 0
end

-- 获取用户标题
function UserModel:getUserTitle()
    local profile = self:getUserProfile()
    if not profile or not profile.title then
        return ""
    end
    return profile.title
end

-- 获取用户签名
function UserModel:getUserSlogan()
    local profile = self:getUserProfile()
    if not profile or not profile.slogan then
        return ""
    end
    return profile.slogan
end

-- 判断用户是否已签到
function UserModel:isPunched()
    local profile = self:getUserProfile()
    if not profile then
        return false
    end
    return profile.isPunched or false
end

-- 获取用户角色
function UserModel:getUserCharacter()
    local profile = self:getUserProfile()
    if not profile or not profile.character then
        return "knight"
    end
    return profile.character
end

-- 获取用户邮箱
function UserModel:getUserEmail()
    local profile = self:getUserProfile()
    if not profile or not profile.email then
        return ""
    end
    return profile.email
end

-- 获取用户ID
function UserModel:getUserId()
    local profile = self:getUserProfile()
    if not profile or not profile.id then
        return ""
    end
    return profile.id
end

-- 获取用户头像URL
function UserModel:getUserAvatarUrl()
    local profile = self:getUserProfile()
    if not profile or not profile.avatar then
        return nil
    end
    return profile.avatar
end

return UserModel
