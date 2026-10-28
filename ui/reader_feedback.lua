-- Reading failures are reported outside the paint chain. Never wake Wi-Fi or
-- open dialogs for speculative pages, stale chapters, or a recovered request.
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local Feedback = {}

local function failure_reason(session, page)
    local err = tostring(session.store.failed_reason and session.store.failed_reason[page] or "")
    if err:find("登录", 1, true) then return _("登录状态已失效或改变，请重新登录后打开章节。") end
    if err:find("timeout", 1, true) or err:find("超时", 1, true) then return _("本页加载超时，请检查网络或稍后重试。") end
    if err:find("图片损坏", 1, true) then return _("图片损坏，需要重新加载。") end
    return require("ui.common.error_message").describe(err, _("本页加载失败，请检查网络或稍后重试。"))
end

local function visible(session, page)
    if session.cancelled then return false end
    local reader = package.loaded["apps/reader/readerui"]
    local ui = reader and reader.instance
    if not ui or not ui.document or ui.document.session ~= session then return false end
    if ui.paging and ui.paging.current_page == page then return true end
    if ui.view and ui.view.page_scroll then
        for _, state in ipairs(ui.view.page_states or {}) do
            if state.page == page then return true end
        end
    end
    return false
end

function Feedback.clear(session)
    if session.feedback_task then UIManager:unschedule(session.feedback_task) end
    session.feedback_task, session.feedback_key = nil, nil
    if session.feedback_dialog then UIManager:close(session.feedback_dialog, "ui") end
    session.feedback_dialog = nil
end

function Feedback.queue(session, page, kind, detail)
    if session.cancelled then return end
    if kind == "connectivity" and session.feedback_key then return end
    -- One deferred task per session. A later foreground failure replaces a
    -- connectivity check; background failures never displace the foreground.
    if session.scheduler and session.scheduler.current_page ~= page and not visible(session, page) then return end
    if session.feedback_task then UIManager:unschedule(session.feedback_task) end
    session.feedback_task = function()
        session.feedback_task = nil
        if not visible(session, page) then return end
        if kind ~= "display" and session.store:has_local(page) then return end
        local offline = false
        if kind ~= "display" then
            local ok, connected = pcall(function()
                return require("ui/network/manager"):isConnected()
            end)
            offline = ok and connected == false
        end
        if kind == "connectivity" and not offline then return end
        local retrying = session.retry_pending and session.retry_pending[page] ~= nil
        local reason = kind == "display" and require("ui.common.error_message").describe(detail, _("图片暂时无法显示，请重试或关闭当前章节后重新打开。"))
            or (offline and _("网络未连接，本页尚未缓存。") or failure_reason(session, page))
        local suffix
        if retrying then
            suffix = _("已安排自动重试；也可以恢复网络后点击重试。")
        elseif kind == "connectivity" then
            suffix = _("需要网络才能继续加载，连接网络后可点击重试。")
        else
            suffix = kind == "download" and _("本次自动重试已停止。可以点击重试，或关闭提示继续翻页。")
                or _("可以点击重试，或关闭提示继续翻页。")
        end
        local key = tostring(page) .. ":" .. kind .. ":" .. tostring(offline) .. ":" .. tostring(retrying) .. ":" .. tostring(detail)
        if session.feedback_key == key then return end
        Feedback.clear(session)
        session.feedback_key = key
        local dialog
        dialog = require("ui.common.action_style").ConfirmBox:new{
            is_picayomi_page = true,
            text = string.format(_("第 %d 页：%s\n\n%s"), page, reason, suffix),
            ok_text = _("重试"), cancel_text = _("关闭"),
            ok_callback = function()
                session.feedback_dialog = nil
                if not visible(session, page) then return end
                session.feedback_key = nil
                session.retry_attempts[page] = nil
                session:clear_failure(page)
                session:request_page(page)
                session:refresh_failed_page(page)
            end,
            cancel_callback = function() session.feedback_dialog = nil end,
        }
        session.feedback_dialog = dialog
        UIManager:show(dialog, "ui")
    end
    UIManager:scheduleIn(0.1, session.feedback_task)
end

return Feedback
