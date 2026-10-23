local Base = require("ui.settings.base")
local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local Manager = require("source.extensions.manager")
local Sources = Base:new{ name = "source_settings" }

function Sources:page(title, items, redraw, route)
    for _, item in ipairs(items) do
        local clickable = item.callback ~= nil and item.enabled ~= false
        item.select_enabled = clickable
    end
    route = route or title
    if self.manager then
        self.manager:trimToRoute(route)
    end
    local menu = self:createMenu(title, items)
    menu._settings_route = route
    local close = menu.close_callback
    menu.close_callback = function(...)
        -- Menu invokes close_callback after item selection, even when the
        -- callback has just started a yielding network task.
        if menu._picayomi_in_select then return end
        if self.task then self.task:cancel(); self.task = nil end
        if self.manager and self.manager.current_menu == menu then return self:goBack() end
        return close(...)
    end
    menu._extensions_redraw = redraw
    self:showMenu(menu)
end

function Sources:reload(redraw)
    redraw = redraw or function() self:show() end
    if self.manager then self.manager:closeCurrentMenu() end
    redraw()
end

function Sources:perform(fn, message)
    require("source.extensions.updater").cancel()
    if self.task and not self.task.done then return end
    local owner = self.manager and self.manager.current_menu
    local Loading = require("ui.common.loading_task")
    local hint = require("ui/widget/infomessage"):new{ text = "正在处理…点击取消" }
    UIManager:show(hint, "ui")
    UIManager:forceRePaint()
    local task
    hint.dismiss_callback = function() if task then task:cancel() end end
    task = require("network.async_task").run(function()
        local result, reason, restart = fn()
        assert(result, reason or "操作失败")
        Loading.close(hint)
        if not self.manager or self.manager.current_menu == owner then
            local redraw = self.next_view or (owner and owner._extensions_redraw)
            self.next_view = nil
            -- Refreshing the menu must not cancel the completed operation.
            self.task = nil
            self:reload(redraw)
            if restart then self:offerRestart(message or reason)
            elseif message ~= false then self:showInfo(message or reason or "已保存，重启 KOReader 后生效") end
        end
    end, {
        is_cancelled = function() return self.manager and self.manager.current_menu ~= owner end,
        on_cancel = function() Loading.close(hint) end,
        on_error = function(err) Loading.close(hint); self:showError(tostring(err)) end,
    })
    self.task = task
end

function Sources:changeSource(fn)
    self:perform(function()
        local ok,reason=fn()
        return ok,reason,true
    end)
end

function Sources:offerRestart(message)
    local text=message or "源变更将在重启 KOReader 后生效"
    if not require("device"):canRestart() then return self:showInfo(text) end
    UIManager:show(self:createConfirmBox{
        text=text,ok_text="立即重启 KOReader",cancel_text="稍后",
        ok_callback=function()
            UIManager:show(require("ui/widget/infomessage"):new{ text="正在重启 KOReader…" },"ui")
            UIManager:forceRePaint()
            UIManager:nextTick(function()
                UIManager:broadcastEvent(require("ui/event"):new("Restart"))
            end)
        end,
    },"ui")
end

function Sources:input(title, value, callback)
    local dialog
    dialog = InputDialog:new{
        title = title, input = value or "",
        buttons = { {
            { text = "取消", callback = function() UIManager:close(dialog, "ui") end },
            { text = "确定", callback = function()
                local text = dialog:getInputText():gsub("^%s+", ""):gsub("%s+$", "")
                UIManager:close(dialog, "ui")
                callback(text)
            end },
        } },
    }
    UIManager:show(dialog, "ui")
    dialog:onShowKeyboard()
end

function Sources:trust(text, fn)
    UIManager:show(self:createConfirmBox{
        text = text .. "\n扩展代码可访问设备和网络。仅安装您信任的发布者提供的源。",
        ok_text = "信任并继续", ok_callback = fn,
    }, "ui")
end

function Sources:show()
    local m = Manager.instance()
    local items = {
        { text = "订阅管理", callback = function() self:repositories() end },
    }
    local Error=require("ui.common.error_message")
    if m.state_error then items[#items + 1] = { text = Error.describe(m.state_error), enabled = false } end
    if m.errors.bundled then items[#items+1]={text="附带包错误："..Error.describe(m.errors.bundled),enabled=false} end
    for id,err in pairs(m.errors) do
        if id~="bundled" and not m.state.sources[id] then
            items[#items+1]={text=id.." 加载失败："..Error.describe(err),enabled=false}
        end
    end
    local ids = {}
    for id in pairs(m.state.sources) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local rec = m.state.sources[id]
        local label = "漫画源：" .. rec.manifest.name .. " " .. rec.manifest.version .. " · "
            .. (rec.enabled and "已启用" or "已禁用")
        if m:pending(id) then label = label .. " · 待重启"
        elseif m.errors[id] then label = label .. " · 加载失败"
        elseif m.state.repositories[rec.origin] then
            local status=m:candidate(rec.origin,id)
            if status.code=="update" then label=label.." · "..status.label end
        end
        items[#items + 1] = { text = label, callback = function() self:source(id) end }
    end
    for id in pairs(m.bundles or {}) do
        if not m.state.sources[id] then
            items[#items+1]={text="恢复附带源："..id,callback=function()
                self:trust("恢复附带源 "..id,function() self:changeSource(function() return m:restoreBundled(id) end) end)
            end}
        end
    end
    local pending=false
    for id in pairs(m.initial or {}) do if m:pending(id) then pending=true end end
    for id in pairs(m.state.sources) do if m:pending(id) then pending=true end end
    if pending then items[#items+1]={text="重启 KOReader 应用源变更",callback=function() self:offerRestart() end} end
    items[#items + 1] = self:createBackButton()
    self:page("源管理", items, function() self:show() end)
end

function Sources:source(id)
    local m = Manager.instance()
    local rec = m.state.sources[id]
    if not rec then return self:show() end
    local items = {
        { text = "版本：" .. rec.manifest.version .. " · 作者：" .. rec.manifest.author, enabled = false },
    }
    local running = m.loaded[id]
    local caps = running and running.capabilities or {}
    local names = { search="搜索", recommendations="推荐", latest="最新", categories="分类", rankings="排行", login="登录", comments="评论", download="下载" }
    local features = {}; for k,label in pairs(names) do if caps[k] then features[#features+1]=label end end; table.sort(features)
    items[#items + 1] = { text = "支持：" .. table.concat(features, "、"), enabled = false }
    if m.errors[id] then
        items[#items + 1] = { text = "加载失败：" .. require("ui.common.error_message").describe(m.errors[id]), enabled = false }
        items[#items + 1] = { text = "重试失败版本", callback = function() self:changeSource(function() return m:retry(id) end) end }
    end
    items[#items + 1] = { text = rec.enabled and "禁用" or "启用", callback = function()
        self:changeSource(function() return m:enable(id, not rec.enabled) end)
    end }
    for _, field in ipairs(rec.manifest.settings or {}) do
        items[#items + 1] = { text = field.title, callback = function()
            local key = "extensions_settings." .. id .. "." .. field.key
            self:input(field.title, self.config:get(key) or field.default, function(value)
                self:perform(function()
                    if value ~= "" and field.key:match("base_url$") then
                        assert(require("source.extensions.https").validURL(value), "请输入 HTTPS 网站地址")
                    end
                    assert(self.config:set(key, value)~=false, "保存设置失败")
                    return true
                end, "源设置已保存")
            end)
        end }
    end
    items[#items + 1] = { text = "卸载（保留收藏、历史和下载）", callback = function()
        UIManager:show(self:createConfirmBox{
            text = "卸载此源？重启后生效，阅读数据保留。", ok_callback = function()
                self:changeSource(function()
                    m:uninstall(id)
                    self.next_view = function() self:show() end
                    return true
                end)
            end,
        }, "ui")
    end }
    items[#items + 1] = self:createBackButton()
    self:page(rec.manifest.name, items, function() self:source(id) end, "source:"..id)
end

function Sources:repositories()
    local m = Manager.instance()
    local items = { { text = "自动检查更新：" .. (m.state.auto_check and "开启" or "关闭"), callback = function()
        self:perform(function() return m:setPolicy(nil, "auto_check", not m.state.auto_check) end, "检查策略已保存")
    end }, { text = "添加订阅", callback = function()
        self:input("HTTPS 订阅地址", "", function(url)
            self:perform(function()
                m:addRepository(url)
                m:acceptRepository(url,m:previewRepository(url),true)
                return true
            end, "订阅已添加，请点击更新漫画源")
        end)
    end } }
    if not next(m.state.repositories) then
        items[#items+1]={text="恢复默认订阅",callback=function()
            self:perform(function() return m:restoreDefaultRepository() end,"默认订阅已恢复")
        end}
    end
    local urls = {}
    for url in pairs(m.state.repositories) do urls[#urls + 1] = url end
    table.sort(urls)
    for _, url in ipairs(urls) do
        items[#items + 1] = { text = "订阅：" .. m.state.repositories[url].name,
            callback = function() self:repository(url) end }
    end
    items[#items + 1] = self:createBackButton()
    self:page("订阅管理", items, function() self:repositories() end)
end

function Sources:repository(url)
    local m = Manager.instance()
    local repo = m.state.repositories[url]
    if not repo then return self:repositories() end
    local items = {
        { text = url, enabled = false },
    }
    if repo.error then items[#items+1]={text="检查失败："..require("ui.common.error_message").describe(repo.error),enabled=false} end
    items[#items+1]={text="更新漫画源（含新源）",callback=function()
        self:perform(function() return self:updateRepository(url) end)
    end}
    local seen={}
    for _, entry in ipairs(repo.sources or {}) do
        if not seen[entry.id] then
            seen[entry.id]=true
            local id=entry.id
            local status=m:candidate(url,id)
            local chosen=status.entry or entry
            items[#items+1]={text="漫画源："..chosen.name.." "..chosen.version.." · "..status.label,
                enabled=status.code=="update",callback=function()
                    self:perform(function()
                        local ok,err=m:installFromRepository(url,id)
                        return ok,err,true
                    end,
                        "更新成功："..chosen.name.." "..chosen.version.."，重启 KOReader 后生效")
                end}
        end
    end
    items[#items + 1] = { text = "移除订阅（保留已安装源）", callback = function()
        self:perform(function()
            m:removeRepository(url)
            self.next_view = function() self:repositories() end
            return true
        end, "订阅已移除")
    end }
    items[#items + 1] = self:createBackButton()
    self:page(repo.name, items, function() self:repository(url) end, "repository:"..url)
end

function Sources:updateRepository(url)
    local m=Manager.instance()
    local preview=m:previewRepository(url)
    local repo=m.state.repositories[url]
    -- Entering the subscription URL authorizes its initial identity. Existing
    -- pins still reject an unexpected publisher/key change.
    m:acceptRepository(url,preview,not repo.public_key and true or nil)
    local results=m:updateAll(url,false,true)
    local lines={}
    for _,r in ipairs(results) do
        local rec=m.state.sources[r.id]
        if r.ok then
            lines[#lines+1]="更新成功："..(rec and rec.manifest.name or r.id).." "..(rec and rec.manifest.version or "")
        else
            lines[#lines+1]="更新失败："..r.id.." — "..require("ui.common.error_message").describe(r.error)
        end
    end
    if #results==0 then
        local seen={}
        for _,entry in ipairs(m.state.repositories[url].sources or {}) do
            if not seen[entry.id] then
                seen[entry.id]=true
                local status=m:candidate(url,entry.id)
                if status.code~="latest" then
                    lines[#lines+1]=(entry.name or entry.id).."："..status.label
                end
            end
        end
        return true,#lines>0 and ("本次未安装或更新漫画源\n"..table.concat(lines,"\n")) or "漫画源已是最新，无需更新"
    end
    local restart=false
    for _,r in ipairs(results) do
        if r.ok then restart=true;lines[#lines+1]="成功更新的漫画源将在重启 KOReader 后生效"; break end
    end
    return true,table.concat(lines,"\n"),restart
end

return Sources
