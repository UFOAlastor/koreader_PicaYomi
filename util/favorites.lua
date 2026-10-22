-- util/favorites.lua
-- 收藏列表的公共处理
local _ = require("gettext")
local LocalFavorites = require("util.local_favorites")

local M = {}

--- 把收藏列表里的一批漫画标记为"已收藏"
--
-- 为什么需要: 两个源的收藏列表接口都**不返回**单条的收藏状态
-- (实测 picacg / jm 的 data.comics[i].isFavourite 全是 nil), 但这一页
-- 语义上全都是已收藏的。不补这一笔会出两个问题:
--   1. 从收藏进详情页时, 按钮显示"收藏"而不是"取消收藏";
--   2. 阅读后返回详情页时 (main.lua 用 session.context.comic 重建详情页,
--      走的是按 isFavourite 推导文案的那条路径), 状态也恢复不了 ——
--      用户看到的就是"收藏过的漫画, 读完后按钮又变回收藏"。
--
-- @param data 源接口返回的 { comics = {...}, page = , pages = , total = }
-- @return 原表 (便于链式书写)
function M.markAll(data)
    if type(data) ~= "table" or type(data.comics) ~= "table" then
        return data
    end
    for _i, comic in ipairs(data.comics) do
        if type(comic) == "table" then
            comic.isFavourite = true
        end
    end
    return data
end

--- 当前是否已登录 (拿不到 user 模块时按"未登录"处理, 走本地兜底)
function M.isLoggedIn()
    local ok, UserModel = pcall(require, "model.user")
    if not ok or not UserModel then return false end
    local pok, logged = pcall(function() return UserModel:isLoggedIn() end)
    return pok and logged == true
end

--- 该用哪个后端存收藏
--
-- 规则 (与用户确认过): **登录了用账号, 没登录用本地**。
-- 源不支持网络收藏 (如源 C) 时同样走本地。
-- @return "online" | "local" | nil (两者都不行)
function M.backend(source)
    if source and source.hasCapability and source:hasCapability("favorites")
            and M.isLoggedIn() then
        return "online"
    end
    if not source or not source.hasCapability
            or source:hasCapability("local_favorites") then
        return "local"
    end
    return nil
end

--- 构造详情页"收藏"按钮的动作
--
-- 首页 / 搜索 / 分类 / 历史 / 收藏页曾经各抄一份, 逻辑还不一致: 有的只实现"加"
-- (于是"取消收藏"按下去又加一次), 有的把文案写死成"收藏" (于是永远显示不出
-- 已收藏状态)。这里统一成一份:
--   * 后端由 M.backend() 决定 (登录走账号, 否则本地兜底);
--   * 文案交给 ComicDetail:syncFavoriteLabel 按状态推导, 需要固定文案时用 pinned_label;
--   * run 按**当前状态**增或删, 不会再出现"取消又加一次"。
--
-- @param opts.source       当前源对象 (可 nil)
-- @param opts.source_id    源标识; 缺省取 source.identifier
-- @param opts.comic_api    api.comic 实例 (网络收藏用; 缺省自己 require)
-- @param opts.pinned_label 固定文案 (收藏列表页要固定成"取消收藏")
-- @param opts.confirm_text 删除前的确认文案 (不传则直接执行)
-- @param opts.after_success 额外回调, 在状态翻转之后调用 (如收藏页要 goBack)
-- @return table|nil (nil = 该源既不支持网络收藏也不支持本地收藏)
function M.buildAction(opts)
    opts = opts or {}
    local source = opts.source
    local source_id = opts.source_id or (source and source.identifier) or "unknown"
    local backend = M.backend(source)
    if not backend then return nil end
    local online = backend == "online"
    local comic_api = opts.comic_api
    if online and not comic_api then
        local ok, api = pcall(require, "api.comic")
        comic_api = ok and api or nil
        if not comic_api then return nil end
    end

    local action = {
        pinned_label = opts.pinned_label,
        loading_text = _("处理中..."),
        success_text = _("操作成功"),
        confirm_text = opts.confirm_text,
        backend = backend,
    }

    --- 本地兜底时状态在本地就有, 不必去问源 (未登录问源只会拿到 401)。
    -- **只在本地后端上挂这个字段**: ComicDetail 看到它有值就会跳过"问源补状态",
    -- 账号后端挂上空函数会把那条路径整段掐掉 (已收藏的漫画就永远显示成"收藏")。
    if not online then
        action.local_state = function(comic)
            if type(comic) ~= "table" then return false end
            return LocalFavorites.isFavorite(source_id, comic._id)
        end
    end

    action.run = function(item)
        if type(item) ~= "table" then return false, _("无效的漫画数据") end
        local is_fav = item.isFavourite == true
        if online then
            if is_fav then return comic_api:removeFavorite(item._id) end
            return comic_api:addFavorite(item._id)
        end
        if is_fav then return LocalFavorites.remove(source_id, item._id) end
        return LocalFavorites.add(source_id, item)
    end

    action.after_success = function(view)
        -- 只翻转状态; **不要**顺手改 fa.label —— ComicDetail:runFavoriteAction 之后会调
        -- syncFavoriteLabel(), 它靠"label 变了"来决定是否 refresh()。这里先改了,
        -- 那边就会以为文案没变而跳过刷新, 屏幕上的按钮文字就停在旧文案上。
        if view and type(view.comic) == "table" then
            view.comic.isFavourite = not (view.comic.isFavourite == true)
        end
        if opts.after_success then opts.after_success(view) end
    end

    return action
end

return M
