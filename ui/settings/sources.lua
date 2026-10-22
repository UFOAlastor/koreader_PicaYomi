local Base = require("ui.settings.base")
local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local Manager = require("source.extensions.manager")
local Sources = Base:new{ name = "source_settings" }

function Sources:page(title, items, redraw)
    local menu = self:createMenu(title, items)
    local close = menu.close_callback
    menu.close_callback = function(...)
        if self.task then self.task:cancel(); self.task = nil end
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
    local task
    hint.dismiss_callback = function() if task then task:cancel() end end
    task = require("network.async_task").run(function()
        local result, reason = fn()
        assert(result, reason or "操作失败")
        Loading.close(hint)
        if not self.manager or self.manager.current_menu == owner then
            local redraw = self.next_view or (owner and owner._extensions_redraw)
            self.next_view = nil
            self:reload(redraw)
            if message ~= false then self:showInfo(message or reason or "已保存，重启 KOReader 后生效") end
        end
    end, {
        is_cancelled = function() return self.manager and self.manager.current_menu ~= owner end,
        on_cancel = function() Loading.close(hint) end,
        on_error = function(err) Loading.close(hint); self:showError(tostring(err)) end,
    })
    self.task = task
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
        { text = "导入源包", callback = function()
            UIManager:show(require("ui/widget/pathchooser"):new{
                title = "长按选择 .pysource 源包", select_directory = false,
                path = require("datastorage"):getDataDir(),
                file_filter = function(path) return path:match("%.pysource$") ~= nil end,
                onConfirm = function(path)
                    local ok,preview=pcall(m.previewImport,m,path)
                    if not ok then self:showError(tostring(preview)); return end
                    local manifest=preview.manifest
                    local text="安装源包："..manifest.name.." "..manifest.version
                        .."\n发布者："..tostring(manifest.publisher_id or manifest.author)
                    if preview.needs_legacy_trust then
                        text=text.."\n此源将使用 "..manifest.id.." 的历史账号、收藏与阅读数据。请确认来自可信源仓库。"
                    end
                    self:trust(text, function()
                        self:perform(function()
                            return m:install(preview.raw,nil,nil,preview.needs_legacy_trust)
                        end)
                    end)
                end,
            }, "ui")
        end },
        { text = "订阅管理", callback = function() self:repositories() end },
    }
    if m.state_error then items[#items + 1] = { text = m.state_error, enabled = false } end
    if m.errors.bundled then items[#items+1]={text="附带包错误："..m.errors.bundled,enabled=false} end
    for id,err in pairs(m.errors) do
        if id~="bundled" and not m.state.sources[id] then
            items[#items+1]={text=id.." 加载失败："..tostring(err),enabled=false}
        end
    end
    local ids = {}
    for id in pairs(m.state.sources) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local rec = m.state.sources[id]
        local label = rec.manifest.name .. " " .. rec.manifest.version .. (rec.bundled and " · 附带" or "") .. " · "
            .. (rec.enabled and "已启用" or "已禁用")
        if m:pending(id) then label = label .. " · 待重启"
        elseif m.errors[id] then label = label .. " · 加载失败"
        elseif m.state.repositories[rec.origin] then
            local status=m:candidate(rec.origin,id)
            if status.code~="latest" then label=label.." · "..status.label end
        end
        items[#items + 1] = { text = label, callback = function() self:source(id) end }
    end
    for id in pairs(m.bundles or {}) do
        if not m.state.sources[id] then
            items[#items+1]={text="恢复附带源："..id,callback=function()
                self:trust("恢复附带源 "..id,function() self:perform(function() return m:restoreBundled(id) end) end)
            end}
        end
    end
    items[#items + 1] = self:createBackButton()
    self:page("源管理", items, function() self:show() end)
end

function Sources:source(id)
    local m = Manager.instance()
    local rec = m.state.sources[id]
    if not rec then return self:show() end
    local items = {
        { text = "版本：" .. rec.manifest.version .. " · 作者：" .. rec.manifest.author, enabled = false },
        { text = "来源：" .. rec.origin, enabled = false },
        { text = "变更在重启 KOReader 后生效", enabled = false },
    }
    local running = m.loaded[id]
    items[#items + 1] = { text = "运行版本：" .. (running and running.version or "未加载"), enabled = false }
    items[#items + 1] = { text = "发布者：" .. (rec.publisher_id or rec.manifest.publisher_id or "本地导入"), enabled = false }
    items[#items + 1] = { text = "更新来源：" .. (m.state.repositories[rec.origin] and rec.origin or "未配置更新来源"), enabled = false }
    local caps = running and running.capabilities or {}
    local names = { search="搜索", recommendations="推荐", latest="最新", categories="分类", rankings="排行", login="登录", comments="评论", download="下载" }
    local features = {}; for k,label in pairs(names) do if caps[k] then features[#features+1]=label end end; table.sort(features)
    items[#items + 1] = { text = "支持：" .. table.concat(features, "、"), enabled = false }
    items[#items + 1] = { text = rec.pinned and "取消固定版本" or "固定当前版本", callback = function()
        self:perform(function() return m:pin(id, not rec.pinned) end, "版本策略已保存")
    end }
    if m.state.repositories[rec.origin] then
        local status=m:candidate(rec.origin,id)
        items[#items+1]={text=status.label, enabled=status.code=="update", callback=function()
            self:perform(function() return m:installFromRepository(rec.origin,id) end)
        end}
        items[#items+1]={text="检查更新", callback=function() self:refresh(rec.origin) end}
    end
    for url,repo in pairs(m.state.repositories) do
        if repo.public_key and (not rec.publisher_id or rec.publisher_id==repo.publisher_id) and rec.origin~=url then
            items[#items+1]={text="绑定订阅："..repo.name, callback=function()
                self:trust("绑定发布者 "..repo.publisher_id.."\n指纹："..require("source.extensions.signature").fingerprint(repo.public_key),function()
                    self:perform(function() return m:bind(id,url) end,"更新来源已绑定")
                end)
            end}
        end
    end
    if m.errors[id] then
        items[#items + 1] = { text = "加载失败：" .. m.errors[id], enabled = false }
        items[#items + 1] = { text = "重试失败版本", callback = function() self:perform(function() return m:retry(id) end) end }
    end
    items[#items + 1] = { text = rec.enabled and "禁用" or "启用", callback = function()
        self:perform(function() return m:enable(id, not rec.enabled) end)
    end }
    items[#items + 1] = { text = "回滚上一版本", enabled = rec.last_good ~= nil or rec.previous ~= nil, callback = function()
        self:perform(function() return m:rollback(id) end)
    end }
    for _, field in ipairs(rec.manifest.settings or {}) do
        items[#items + 1] = { text = field.title, callback = function()
            local key = "extensions_settings." .. id .. "." .. field.key
            self:input(field.title, self.config:get(key) or field.default, function(value)
                self:perform(function()
                    if value ~= "" and field.key:match("base_url$") then
                        assert(require("source.extensions.https").validURL(value), "请输入 HTTPS 网站地址")
                    end
                    self.config:set(key, value)
                    return true
                end, "源设置已保存")
            end)
        end }
    end
    if m.bundles[id] then items[#items+1]={text="恢复附带版本",callback=function()
        self:trust("恢复随主程序附带的版本，现有阅读数据保留，版本将固定。",function()
            self:perform(function() return m:restoreBundled(id) end)
        end)
    end} end
    items[#items + 1] = { text = "卸载（保留收藏、历史和下载）", callback = function()
        UIManager:show(self:createConfirmBox{
            text = "卸载此源？重启后生效，阅读数据保留。", ok_callback = function()
                self:perform(function()
                    m:uninstall(id)
                    self.next_view = function() self:show() end
                    return true
                end)
            end,
        }, "ui")
    end }
    items[#items + 1] = self:createBackButton()
    self:page(rec.manifest.name, items, function() self:source(id) end)
end

function Sources:repositories()
    local m = Manager.instance()
    local items = { { text = "自动检查更新：" .. (m.state.auto_check and "开启" or "关闭"), callback = function()
        self:perform(function() return m:setPolicy(nil, "auto_check", not m.state.auto_check) end, "检查策略已保存")
    end }, { text = "添加订阅", callback = function()
        self:input("HTTPS 订阅地址", "", function(url)
            self:trust("信任订阅及其后续更新：\n" .. url, function()
                self:perform(function() return m:addRepository(url) end, "订阅已添加，请手动刷新目录")
            end)
        end)
    end } }
    local urls = {}
    for url in pairs(m.state.repositories) do urls[#urls + 1] = url end
    table.sort(urls)
    for _, url in ipairs(urls) do
        items[#items + 1] = { text = m.state.repositories[url].name,
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
        { text = "刷新目录", callback = function()
            self:refresh(url)
        end },
        { text = "移除订阅（保留已安装源）", callback = function()
            self:perform(function()
                m:removeRepository(url)
                self.next_view = function() self:repositories() end
                return true
            end, "订阅已移除")
        end },
    }
    items[#items+1]={text="最后成功检查："..(repo.last_success and os.date("%Y-%m-%d %H:%M",repo.last_success) or "尚未检查"),enabled=false}
    if repo.error then items[#items+1]={text="检查失败："..repo.error,enabled=false} end
    items[#items+1]={text=repo.public_key and ("发布者："..repo.publisher_id.." · 指纹："..require("source.extensions.signature").fingerprint(repo.public_key)) or "旧订阅：未签名，仅手动安装",enabled=false}
    items[#items+1]={text="自动安装："..(repo.auto_install and "开启" or "关闭"),enabled=repo.public_key~=nil,callback=function()
        self:trust("允许发布者 "..(repo.publisher_id or "").." 自动准备源更新；重启后启用。",function()
            self:perform(function() return m:setPolicy(url,"auto_install",not repo.auto_install) end,"更新策略已保存")
        end)
    end}
    items[#items+1]={text="一键更新可用源",callback=function()
        self:perform(function()
            local result=m:updateAll(url); local good,bad=0,0
            for _,r in ipairs(result) do if r.ok then good=good+1 else bad=bad+1 end end
            return true,"更新成功 "..good.."，失败 "..bad.."；成功项重启后生效"
        end)
    end}
    if repo.public_key then items[#items+1]={text="更换订阅地址",callback=function()
        self:input("新的 HTTPS 订阅地址",url,function(target)
            self:trust("更换订阅地址；发布者和密钥必须相同。",function()
                self:perform(function()
                    m:moveRepository(url,target,m:previewRepository(target))
                    self.next_view=function() self:repository(target) end
                    return true
                end,"订阅地址已更新")
            end)
        end)
    end} end
    local seen={}
    for _, entry in ipairs(repo.sources or {}) do
        if not seen[entry.id] then
            seen[entry.id]=true
            local id=entry.id
            local status=m:candidate(url,id)
            local chosen=status.entry or entry
            items[#items+1]={text=chosen.name.." "..chosen.version.." · "..status.label,
                enabled=status.code=="update",callback=function()
                    self:trust("安装或更新 "..chosen.name.." "..chosen.version.."\n"..(chosen.notes or ""),function()
                        self:perform(function() return m:installFromRepository(url,id) end)
                    end)
                end}
        end
    end
    items[#items + 1] = self:createBackButton()
    self:page(repo.name, items, function() self:repository(url) end)
end

function Sources:refresh(url)
    local m=Manager.instance()
    self:perform(function()
        local preview=m:previewRepository(url)
        local repo=m.state.repositories[url]
        if preview.key and preview.key~=repo.public_key then
            self.next_view=function() self:confirmIdentity(url,preview) end
        else m:acceptRepository(url,preview) end
        return true
    end,false)
end
function Sources:confirmIdentity(url,preview)
    local m=Manager.instance()
    local repo=m.state.repositories[url]
    local key=preview.key
    local text="发布者："..preview.data.publisher_id.."\n密钥指纹："..require("source.extensions.signature").fingerprint(key)
    if repo.public_key then text=text.."\n发布者密钥已改变，请核对身份。" end
    self:page("确认订阅身份",{
        {text=text,enabled=false},
        {text="信任此发布身份",callback=function()
            self:trust(text,function()
                self:perform(function()
                    m:acceptRepository(url,preview,repo.public_key and not preview.envelope.rotation and "reset" or true)
                    self.next_view=function() self:repository(url) end
                    return true
                end,"发布身份已确认，目录已刷新")
            end)
        end}, self:createBackButton(),
    },function() self:confirmIdentity(url,preview) end)
end

return Sources
