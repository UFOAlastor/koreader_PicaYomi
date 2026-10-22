-- util/comment_time.lua
-- 评论时间的展示格式化 (纯函数, 无 IO / 无网络)。
--
-- 为什么单独成模块: 这段逻辑原来在 model/comment.lua 里, 而那个模块的其余部分
-- (缓存/查找) 从未被调用过 —— 属于死代码。格式化是纯函数, 放 util 层更合适,
-- 也便于离线穷举测试。
--
-- 输入形态:
--   * 字符串 "2022-01-01T12:00:00.000Z" (源 A 的 created_at)
--   * 数字 epoch 秒 (部分源直接给时间戳, 与 comic_detail 里 update_time 的两种形态一致)
--   * nil / 其它类型 (含 KOReader rapidjson 把 JSON null 解出来的 userdata) → "未知时间"

local _ = require("gettext")
local T = require("ffi/util").template

local CommentTime = {}

--- 把时间戳格式化成相对时间
-- @param timestamp 字符串 / 数字 / nil
-- @return 展示用字符串 (永不返回 nil)
function CommentTime.format(timestamp)
    if timestamp == nil then
        return _("未知时间")
    end

    local comment_time
    if type(timestamp) == "number" then
        comment_time = timestamp
    elseif type(timestamp) == "string" then
        -- 时间格式: "2022-01-01T12:00:00.000Z"
        local year, month, day, hour, min, sec = timestamp:match(
            "(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
        if not year then
            -- 不是已知格式: 原样返回, 别编一个假时间
            return timestamp
        end
        -- 计算时间差（简化处理，不考虑时区）
        -- os.time 对越界字段会抛错, 所以 pcall 兜住 —— 脏数据不该打崩评论页
        local pok, t = pcall(os.time, {
            year = tonumber(year),
            month = tonumber(month),
            day = tonumber(day),
            hour = tonumber(hour),
            min = tonumber(min),
            sec = tonumber(sec),
        })
        if not pok or not t then
            return timestamp
        end
        comment_time = t
    else
        -- userdata (JSON null) 等
        return _("未知时间")
    end

    local diff = os.time() - comment_time

    -- 根据时间差显示不同的格式
    if diff < 60 then
        return _("刚刚")
    elseif diff < 3600 then
        return T(_("%1分钟前"), math.floor(diff / 60))
    elseif diff < 86400 then
        return T(_("%1小时前"), math.floor(diff / 3600))
    elseif diff < 2592000 then
        return T(_("%1天前"), math.floor(diff / 86400))
    elseif diff < 31536000 then
        return T(_("%1个月前"), math.floor(diff / 2592000))
    else
        return T(_("%1年前"), math.floor(diff / 31536000))
    end
end

return CommentTime
