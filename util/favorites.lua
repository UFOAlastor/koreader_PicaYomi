-- util/favorites.lua
-- 收藏列表的公共处理
local _ = require("gettext")
local LocalFavorites = require("util.local_favorites")
local logger = require("util.logger")

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
        if type(item) ~= "table" then return false, _("无效的作品数据") end
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

function M.canSyncLocal(source)
    return source and source.hasCapability and source:hasCapability("favorites")
        and source.isLoggedIn and source:isLoggedIn()
        and LocalFavorites.count(source.identifier)>0 or false
end

-- Fetch the complete remote set before adding anything: some source adapters
-- implement favorite writes as a toggle, so blindly replaying IDs is unsafe.
function M.syncLocal(source,context)
    context=context or {}
    local stats={uploaded=0,skipped=0,failed=0}
    local function cancelled() return context.isCancelled and context.isCancelled() end
    local online,seen_pages={},{}
    local complete=false
    for page=1,200 do
        if cancelled() then return false,stats,"同步已取消" end
        local ok,data,err=source:getFavorites(page)
        if not ok then return false,stats,err or "无法读取线上收藏" end
        if type(data)~="table" or type(data.comics)~="table" then return false,stats,"线上收藏返回值无效" end
        local ids={}
        for _,comic in ipairs(data.comics) do
            if comic._id~=nil then local id=tostring(comic._id);online[id]=true;ids[#ids+1]=id end
        end
        local more=data.has_more
        if more==nil then
            if not tonumber(data.pages) then return false,stats,"无法确认线上收藏是否完整，未执行同步" end
            more=page<tonumber(data.pages)
        end
        if not more then complete=true;break end
        table.sort(ids)
        local key=table.concat(ids,"\0")
        if seen_pages[key] then return false,stats,"线上收藏续页重复，请重试" end
        seen_pages[key]=true
    end
    if not complete then return false,stats,"线上收藏超过分页限额，未执行同步" end
    local attempted={}
    for _,comic in ipairs(LocalFavorites.list(source.identifier)) do
        if cancelled() then return false,stats,"同步已取消" end
        local id=tostring(comic._id)
        if online[id] or attempted[id] then stats.skipped=stats.skipped+1
        else
            attempted[id]=true
            local ok,err=source:addFavorite(id)
            if ok then online[id]=true;stats.uploaded=stats.uploaded+1
            else stats.failed=stats.failed+1;stats.error=err end
        end
    end
    return true,stats
end

function M.promptLocalSync(source)
    if not M.canSyncLocal(source) then return false end
    if M.sync_prompt or M.syncing then return false end
    local UI=require("ui/uimanager")
    local generation=source.sessionGeneration and source:sessionGeneration()
    local function same_session()
        return source:isLoggedIn() and (not generation or source:sessionGeneration()==generation)
            and require("source.registry"):getCurrent()==source
    end
    local Info=require("ui/widget/infomessage")
    local function full_refresh() UI:setDirty(nil,"full") end
    local function start_sync()
        if not same_session() then M.syncing=false;return end
        if logger.enabled then logger.info("Picayomi FavoritesSync: start",source.identifier,"local",LocalFavorites.count(source.identifier)) end
        full_refresh()
        require("ui.common.loading_task").run{
            message=_("正在同步本地收藏…\n点击取消，本地收藏会保留"),async=true,delay=.1,timeout=120,
            is_cancelled=function() return not same_session() end,
            fetch=function() return M.syncLocal(source,{isCancelled=function() return not same_session() end}) end,
            set_busy=function(value) M.syncing=value end,
            on_cancel=function()
                if logger.enabled then logger.info("Picayomi FavoritesSync: cancelled",source.identifier) end
                full_refresh()
            end,
            on_done=function(ok,stats,err)
                if logger.enabled then logger.info("Picayomi FavoritesSync: result",source.identifier,"ok",ok,"uploaded",stats and stats.uploaded or "unknown","skipped",stats and stats.skipped or "unknown","failed",stats and stats.failed or "unknown") end
                if not same_session() then return end
                local text
                if ok then
                    text=string.format("同步完成：新增 %d 本，跳过 %d 本，失败 %d 本。\n本地收藏已保留。",stats.uploaded,stats.skipped,stats.failed)
                    if stats.failed>0 then text=text.."\n可在账号管理中重试同步。" end
                else text="同步未完成："..require("ui.common.error_message").describe(err).."\n本地收藏已保留，可在账号管理中重试。" end
                UI:show(Info:new{text=text,timeout=5},"full")
                full_refresh()
            end,
        }
    end
    local prompt=require("ui.common.action_style").ConfirmBox:new{
        is_picayomi_page=true,
        text=require("ffi/util").template(_("发现当前源有 %1 本本地收藏，是否同步到当前登录账号？\n已在线上收藏的作品会跳过，本地收藏始终保留。"),LocalFavorites.count(source.identifier)),
        ok_text=_("同步"),cancel_text=_("暂不"),
        ok_callback=function()
            if not same_session() then UI:show(Info:new{text=_("账号或源已变化，请重新发起同步。"),timeout=3},"ui");return end
            if M.syncing then UI:show(Info:new{text=_("正在同步本地收藏，请稍候。"),timeout=2},"ui");return end
            M.syncing=true
            -- Native ConfirmBox closes itself after this callback. Start only
            -- after it has left the stack, so its close cannot repaint over loading.
            UI:nextTick(function()
                local ok,err=pcall(start_sync)
                if not ok then M.syncing=false;require("ui.common.loading_task").showFailure(err) end
            end)
        end,
    }
    local close=prompt.onCloseWidget
    prompt.onCloseWidget=function(self)
        if M.sync_prompt==self then M.sync_prompt=nil end
        close(self)
        full_refresh()
    end
    M.sync_prompt=prompt
    if logger.enabled then logger.info("Picayomi FavoritesSync: prompt",source.identifier,"local",LocalFavorites.count(source.identifier)) end
    UI:show(prompt,"full")
    full_refresh()
    UI:nextTick(function()
        if UI:isWidgetShown(prompt) then full_refresh();UI:forceRePaint() end
    end)
    return true
end

return M
