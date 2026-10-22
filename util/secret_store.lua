-- util/secret_store.lua
-- 敏感信息落盘: AES-256-CBC 加密 + HMAC-SHA256 完整性校验。
--
-- 要解决的问题
--   config.json 是**明文 JSON**, 以前里面直接写着源 B 的账号密码、会话 Cookie、
--   哔咔的登录 token、用户资料 (含邮箱)。设备被翻看 / 配置被拷走 / 用户把
--   crash.log 和配置一起发出来时, 这些就是可直接使用的凭据。
--
-- 加密的边界 (必须说清, 不能宣称"绝对安全")
--   电子书阅读器没有系统级 keychain。主密钥只能放在同一个数据目录的
--   secret.key (chmod 600) 里, 因此本模块挡的是:
--     * 直接读/拷 config.json 的人 (看不到明文);
--     * 把配置贴到 issue / 日志里的人;
--     * 仓库误提交 (加密串不是可复用凭据)。
--   它**不挡**已经拿到整个数据目录 (含 secret.key) 的攻击者 —— 那等价于
--   拿到了设备上的所有权限。密钥里混入设备序列号, 使"只拷 config.json +
--   secret.key 到另一台设备"也无法解密。
--
-- 存储格式
--   config.json 里写 "<key>_enc": "enc:v1:<base64(iv || ciphertext || tag)>"
--   旧明文键在迁移成功后立即删除; 加密失败时**不会**退回写明文。

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("util.logger")
local json = require("rapidjson")
local basexx = require("basexx")
local bit = require("bit")
local AES = require("util.aes")
local SHA256 = require("util.sha256")

local SecretStore = {}

SecretStore.PREFIX = "enc:v1:"
SecretStore.KEY_BYTES = 32
SecretStore.IV_BYTES = 16
SecretStore.TAG_BYTES = 16

local DATA_DIR = DataStorage:getDataDir() .. "/picayomi"
local KEY_FILE = DATA_DIR .. "/secret.key"

-- 需要在启动时从明文迁移到密文的键 (不含 profile: 那些是表, 单独处理)
SecretStore.LEGACY_KEYS = {
    "jm_account",
    "jm_password",
    "jm_cookies",
    "source.picacg.token",
    "token",                    -- 源 A 的旧格式
    "source.picacg.username",
    "source.htcomic.cookies",
    "source.htcomic.account",
}

-- 解密结果缓存: blob -> plaintext。
-- 加密落盘的键数量很少, 但 get 在 UI 渲染/请求路径上会被反复调用 (例如用户名),
-- 每帧做一次 AES 是浪费。按密文缓存是安全的: 同一个 blob 的明文不会变。
local plain_cache = {}
local plain_cache_count = 0

local function cached_plain(blob)
    local v = plain_cache[blob]
    if v then return v end
    return nil
end

local function remember_plain(blob, plain)
    if plain_cache_count > 64 then
        plain_cache = {}
        plain_cache_count = 0
    end
    if plain_cache[blob] == nil then
        plain_cache_count = plain_cache_count + 1
    end
    plain_cache[blob] = plain
end

local function ensure_dir()
    if not lfs.attributes(DATA_DIR, "mode") then
        pcall(lfs.mkdir, DATA_DIR)
    end
end

--- 读设备序列号 (只用于密钥绑定; 读不到就用常量)
-- Kindle: /proc/usid; 其它 Linux: /proc/cpuinfo 的 Serial 行
local function device_salt()
    local f = io.open("/proc/usid", "rb")
    if f then
        local s = f:read(128)
        f:close()
        if s and s ~= "" then return (s:gsub("%s+$", "")) end
    end

    f = io.open("/proc/cpuinfo", "rb")
    if f then
        local s = f:read(16384)
        f:close()
        if s then
            local serial = s:match("[Ss]erial%s*:%s*(%S+)")
            if serial and serial ~= "" then return serial end
        end
    end

    return "picayomi-no-device-id"
end

local DEVICE_SALT = device_salt()

local function random_bytes(n)
    local f = io.open("/dev/urandom", "rb")
    if f then
        local s = f:read(n)
        f:close()
        if s and #s == n then return s end
    end
    -- 退化路径 (没有 /dev/urandom 的平台): 时间 + 地址 + math.random 混合后
    -- 过一遍 SHA-256。安全性弱于 urandom, 但比"固定常量"强得多。
    local parts = {}
    for _i = 1, 4 do
        parts[#parts + 1] = table.concat({
            tostring(os.time()),
            tostring(os.clock()),
            tostring({}),
            tostring(math.random(0, 0x7fffffff)),
        }, ":")
    end
    return SHA256.sha256_binary(table.concat(parts, "|")):sub(1, n)
end

local master_key = nil

local function load_master_key()
    if master_key then return master_key end

    local f = io.open(KEY_FILE, "rb")
    if f then
        local data = f:read(SecretStore.KEY_BYTES)
        f:close()
        if data and #data == SecretStore.KEY_BYTES then
            master_key = data
            return master_key
        end
        -- 长度不对: 不能拿残缺数据当密钥。重新生成会让旧密文失效 (用户需重登),
        -- 但总比"用错误密钥解出垃圾"或静默写明文安全。
        logger.warn("Picayomi Secret: secret.key 长度异常, 将重新生成 (旧凭据需重新登录)")
    end

    local data = random_bytes(SecretStore.KEY_BYTES)
    if not data or #data ~= SecretStore.KEY_BYTES then
        logger.err("Picayomi Secret: 无法生成加密密钥")
        return nil
    end

    ensure_dir()
    local out = io.open(KEY_FILE, "wb")
    if not out then
        logger.err("Picayomi Secret: 无法写入 secret.key, 敏感信息将不会落盘")
        return nil
    end
    out:write(data)
    out:close()
    -- 只给当前用户读写 (Kindle 上 KOReader 通常以 root 运行; 这仍是纵深的
    -- 一层, 主要挡同机其它进程误读)
    pcall(os.execute, "chmod 600 '" .. KEY_FILE:gsub("'", "'\\''") .. "' 2>/dev/null")

    master_key = data
    return master_key
end

local function derive_keys(master)
    local material = SHA256.sha256_binary(
        master .. "|picayomi-secret-v1|" .. DEVICE_SALT)
    return material,
        SHA256.sha256_binary(material .. "|enc"),
        SHA256.sha256_binary(material .. "|mac")
end

local function hex_to_bin(hex)
    local out = hex:gsub("..", function(cc)
        return string.char(tonumber(cc, 16))
    end)
    return out
end

local function xor_block(a, b, offset)
    local out = {}
    for i = 1, 16 do
        out[i] = string.char(bit.bxor(a:byte(i), b:byte(offset + i - 1)))
    end
    return table.concat(out)
end

--- 加密任意字符串 -> "enc:v1:..." ; 失败返回 nil, err (绝不返回明文)
function SecretStore.encrypt(plain)
    if type(plain) ~= "string" or plain == "" then
        return nil, "内容为空"
    end

    local master = load_master_key()
    if not master then return nil, "没有可用密钥" end
    local _, enc_key, mac_key = derive_keys(master)

    local pad = 16 - (#plain % 16)
    local data = plain .. string.rep(string.char(pad), pad)

    local iv = random_bytes(SecretStore.IV_BYTES)
    if not iv or #iv ~= 16 then return nil, "无法生成 IV" end

    local blocks = {}
    local prev = iv
    for i = 1, #data, 16 do
        local block = xor_block(data:sub(i, i + 15), prev, 1)
        local ct = AES.encrypt_block(enc_key, block)
        if not ct then return nil, "AES 加密失败" end
        blocks[#blocks + 1] = ct
        prev = ct
    end
    local ciphertext = table.concat(blocks)

    local tag_hex = SHA256.hmac_sha256(mac_key, iv .. ciphertext)
    local tag = hex_to_bin(tag_hex):sub(1, SecretStore.TAG_BYTES)

    return SecretStore.PREFIX .. basexx.to_base64(iv .. ciphertext .. tag)
end

--- 解密 "enc:v1:..." -> 明文; 失败返回 nil, err
function SecretStore.decrypt(blob)
    if type(blob) ~= "string" or blob:sub(1, #SecretStore.PREFIX) ~= SecretStore.PREFIX then
        return nil, "不是密文"
    end

    local cached = cached_plain(blob)
    if cached then return cached end

    local raw = basexx.from_base64(blob:sub(#SecretStore.PREFIX + 1))
    if type(raw) ~= "string" or #raw < SecretStore.IV_BYTES + SecretStore.TAG_BYTES + 16 then
        return nil, "密文长度非法"
    end
    if (#raw - SecretStore.IV_BYTES - SecretStore.TAG_BYTES) % 16 ~= 0 then
        return nil, "密文长度非法"
    end

    local master = load_master_key()
    if not master then return nil, "没有可用密钥" end
    local _, enc_key, mac_key = derive_keys(master)

    local iv = raw:sub(1, SecretStore.IV_BYTES)
    local tag = raw:sub(-SecretStore.TAG_BYTES)
    local ciphertext = raw:sub(SecretStore.IV_BYTES + 1, -SecretStore.TAG_BYTES - 1)

    local tag_hex = SHA256.hmac_sha256(mac_key, iv .. ciphertext)
    if hex_to_bin(tag_hex):sub(1, SecretStore.TAG_BYTES) ~= tag then
        return nil, "完整性校验失败"
    end

    local blocks = {}
    local prev = iv
    for i = 1, #ciphertext, 16 do
        local block = AES.decrypt_block(enc_key, ciphertext:sub(i, i + 15))
        if not block then return nil, "AES 解密失败" end
        blocks[#blocks + 1] = xor_block(block, prev, 1)
        prev = ciphertext:sub(i, i + 15)
    end

    local plain = table.concat(blocks)
    local pad = plain:byte(-1)
    if not pad or pad < 1 or pad > 16 or pad > #plain then
        return nil, "填充非法"
    end
    plain = plain:sub(1, #plain - pad)

    remember_plain(blob, plain)
    return plain
end

--- 读取一个敏感键 (优先密文; 发现旧明文会**就地迁移**)
-- @return string|nil   (读取失败 / 不存在 / 解密失败都返回 nil)
function SecretStore.get(key)
    if type(key) ~= "string" or key == "" then return nil end

    local config = require("util.config")
    local blob = config:get(key .. "_enc")
    if type(blob) == "string" and blob ~= "" then
        local plain, err = SecretStore.decrypt(blob)
        if plain then return plain end
        logger.warn("Picayomi Secret: 无法解密 " .. key .. " (" .. tostring(err)
            .. "), 需要重新登录")
        return nil
    end

    local legacy = config:get(key)
    if legacy == nil then return nil end
    if type(legacy) ~= "string" then
        -- profile 之类是表: 交给 get_json; 这里不猜
        return nil
    end
    if legacy == "" then return nil end

    -- 旧版本留下的明文: 立即加密并删除明文键
    SecretStore.set(key, legacy)
    return legacy
end

--- 写入敏感键; value == nil / "" 表示删除
-- 加密失败时返回 false, 且**不会**退回写明文。
function SecretStore.set(key, value)
    if type(key) ~= "string" or key == "" then return false end

    local config = require("util.config")
    if value == nil or value == "" then
        local cleared = config:setMany({
            { key .. "_enc", nil },
            { key, nil },
        })
        if not cleared then
            logger.err("Picayomi Secret: 清除 " .. key .. " 失败")
        end
        return cleared
    end

    local blob, err = SecretStore.encrypt(tostring(value))
    if not blob then
        logger.err("Picayomi Secret: 加密 " .. key .. " 失败: " .. tostring(err))
        return false
    end

    remember_plain(blob, tostring(value))
    local saved = config:setMany({
        { key .. "_enc", blob },
        { key, nil },       -- 清掉可能存在的明文键
    })
    if not saved then
        logger.err("Picayomi Secret: 写入 " .. key .. " 失败 (未退回明文)")
        return false
    end
    return true
end

function SecretStore.clear(key)
    return SecretStore.set(key, nil)
end

--- 读取 JSON 类敏感数据 (用户资料等)
function SecretStore.get_json(key)
    local raw = SecretStore.get(key)
    if type(raw) == "table" then
        -- 旧明文表: 迁移成密文。迁移失败就先用内存里的值, 但不能写回明文。
        SecretStore.set_json(key, raw)
        return raw
    end
    if type(raw) ~= "string" or raw == "" then return nil end
    local ok, decoded = pcall(json.decode, raw)
    if ok and decoded ~= nil then return decoded end
    logger.warn("Picayomi Secret: " .. key .. " 的 JSON 已损坏, 已忽略")
    return nil
end

function SecretStore.set_json(key, value)
    if value == nil then return SecretStore.clear(key) end
    local ok, encoded = pcall(json.encode, value)
    if not ok or not encoded then
        logger.err("Picayomi Secret: 序列化 " .. tostring(key) .. " 失败")
        return false
    end
    return SecretStore.set(key, encoded)
end

--- 启动迁移: 把旧明文键 (含 profile 表) 一次性加密, 并删除明文
-- @return migrated, failed
function SecretStore.migrate(keys)
    local config = require("util.config")
    keys = keys or SecretStore.LEGACY_KEYS

    local updates = {}
    local migrated, failed = 0, 0

    for _i, key in ipairs(keys) do
        local plain = config:get(key)
        if plain ~= nil then
            local enc = config:get(key .. "_enc")
            if type(plain) == "string" and plain ~= "" then
                if type(enc) == "string" and enc ~= "" then
                    -- 两种都有: 以密文为准, 只删明文
                    updates[#updates + 1] = { key, nil }
                else
                    local blob = SecretStore.encrypt(plain)
                    if blob then
                        remember_plain(blob, plain)
                        updates[#updates + 1] = { key .. "_enc", blob }
                        updates[#updates + 1] = { key, nil }
                        migrated = migrated + 1
                    else
                        failed = failed + 1
                    end
                end
            elseif type(plain) == "table" then
                -- profile 这类表由 migrate_profiles 处理; 这里只提示不误删
                failed = failed + 1
            end
        end
    end

    -- 用户资料 (source_profile.<id> 与旧全局 profile) 是表, 逐个加密
    local profiles = config:get("source_profile")
    if type(profiles) == "table" then
        for id, prof in pairs(profiles) do
            if type(id) == "string" and type(prof) == "table" then
                local key = "source_profile." .. id
                local enc = config:get(key .. "_enc")
                if not (type(enc) == "string" and enc ~= "") then
                    local ok, encoded = pcall(json.encode, prof)
                    local blob = ok and encoded and SecretStore.encrypt(encoded) or nil
                    if blob then
                        remember_plain(blob, encoded)
                        updates[#updates + 1] = { key .. "_enc", blob }
                        updates[#updates + 1] = { key, nil }
                        migrated = migrated + 1
                    else
                        failed = failed + 1
                    end
                else
                    updates[#updates + 1] = { key, nil }
                end
            end
        end
    end

    local old_profile = config:get("profile")
    if type(old_profile) == "table" then
        local enc = config:get("profile_enc")
        if not (type(enc) == "string" and enc ~= "") then
            local ok, encoded = pcall(json.encode, old_profile)
            local blob = ok and encoded and SecretStore.encrypt(encoded) or nil
            if blob then
                remember_plain(blob, encoded)
                updates[#updates + 1] = { "profile_enc", blob }
                updates[#updates + 1] = { "profile", nil }
                migrated = migrated + 1
            else
                failed = failed + 1
            end
        else
            updates[#updates + 1] = { "profile", nil }
        end
    end

    if #updates > 0 then
        local saved = config:setMany(updates)
        if not saved then
            logger.err("Picayomi Secret: 迁移结果写入失败, 明文可能仍在 config.json 中")
            failed = failed + 1
        end
    end

    if migrated > 0 or failed > 0 then
        if logger.enabled then logger.info(string.format(
            "Picayomi Secret: 凭据迁移完成 (加密 %d 项, 失败 %d 项)", migrated, failed)) end
    end
    return migrated, failed
end

--- 测试钩子: 丢掉进程内缓存 (密钥文件不动)
function SecretStore.reset_cache()
    master_key = nil
    plain_cache = {}
    plain_cache_count = 0
end

return SecretStore
