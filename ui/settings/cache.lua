local BaseSettingsModule = require("ui.settings.base")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

-- 注意: SettingsManager 直接对模块表调用 :show()，并不会调用 init()，
-- 因此所有依赖必须在构造时就注入，否则 show() 里会取到 nil 并闪退。
-- (旧代码把 self.cache 放在 init() 里，且调用了不存在的 BaseSettingsModule.init)
local CacheSettings = BaseSettingsModule:new{
    name = "cache_settings",
    cache = require("util.cache"),
}

--- 兼容保留: 若被显式调用则重新注入依赖
function CacheSettings:init()
    self.cache = require("util.cache")
end

local function to_mb(bytes)
    return math.floor((bytes or 0) / 1024 / 1024 * 100) / 100
end

function CacheSettings:show()
    local Screen=require("device").screen
    local Geom=require("ui/geometry")
    local Input=require("ui/widget/container/inputcontainer")
    local Frame=require("ui/widget/container/framecontainer")
    local Vertical=require("ui/widget/verticalgroup")
    local Horizontal=require("ui/widget/horizontalgroup")
    local Text=require("ui/widget/textboxwidget")
    local Theme=require("ui.common.theme")
    local pad=Screen:scaleBySize(12)
    local width=Screen:getWidth()-pad*2
    local page=Input:new{title=_("存储管理"),is_picayomi_page=true,covers_fullscreen=true,is_popout=false,
        _settings_module=self,dimen=Geom:new{x=0,y=0,w=Screen:getWidth(),h=Screen:getHeight()}}
    local body=Vertical:new{align="left"}
    body[#body+1]=require("ui.common.menu_style").titleBar{title=_("存储管理"),width=width}
    page.summary=Text:new{text=_("正在统计存储占用…"),width=width,height=Screen:scaleBySize(132),
        face=Theme.face("info"),height_overflow_show_ellipsis=true}
    body[#body+1]=page.summary
    body[#body+1]=require("ui/widget/verticalspan"):new{width=pad}
    local rows={
        {{text=T(_("缓存上限：%1 MB（不含下载）"),self:safeConfigGet("max_cache_size",500)),callback=function()self:setMaxCacheSize()end}},
        {{text=_("清漫画与封面缓存"),callback=function()self:clearImageCache()end},
         {text=_("清小说缓存"),callback=function()self:clearNovelCache()end}},
        {{text=_("删除漫画下载"),callback=function()self:clearDownloads("comic")end},
         {text=_("删除小说下载"),callback=function()self:clearDownloads("novel")end}},
        {{text=_("清除全部缓存"),callback=function()self:clearAllCache()end},
         {text=_("清空全部下载"),callback=function()self:clearDownloads()end}},
        {{text=_("重新统计"),callback=function()page:startScan()end},
         {text=_("返回"),callback=function()self:goBack()end}},
    }
    local footer,footer_buttons=require("ui.common.action_style").footer(Screen:getWidth(),rows[#rows])
    rows[#rows]=footer_buttons
    page.action_rows=rows
    for row_index=1,#rows-1 do
        local row=rows[row_index]
        local group=Horizontal:new{}
        for column,action in ipairs(row)do
            group[#group+1]=require("ui.common.action_style").Button:new{
                text=action.text,callback=action.callback,width=math.floor(width/#row),
                height=Screen:scaleBySize(48),show_parent=page,
            }
            row[column]=group[#group]
        end
        body[#body+1]=group
    end
    local content=Frame:new{padding=pad,margin=0,bordersize=0,body}
    local gap=math.max(0,Screen:getHeight()-content:getSize().h-footer:getSize().h)
    page.content_height=content:getSize().h+gap+footer:getSize().h
    page.footer_widget=footer
    page.footer_buttons=footer_buttons
    page[1]=Frame:new{padding=0,margin=0,bordersize=0,
        background=require("ffi/blitbuffer").COLOR_WHITE,
        Vertical:new{align="left",content,require("ui/widget/verticalspan"):new{width=gap},footer}}
    page.close_callback=function()self:goBack()end
    page.onClose=page.close_callback
    page.key_events={Close={{"Back"}}}
    page.updateItems=function()self:refresh()end
    require("ui.common.tap_guard").install(page,page.dimen)
    require("ui.common.menu_swipe").attach(page,function()self:goBack()end)
    local owner=self
    local function cleanupScan()
        if page._scan_cleanup then page._scan_cleanup();page._scan_cleanup=nil end
    end
    function page:onCloseWidget()
        self._closed=true
        if self._scan_task then self._scan_task:cancel();self._scan_task=nil end
        cleanupScan()
    end
    function page:startScan()
        if self._closed then return end
        if self._scan_task then self._scan_task:cancel();self._scan_task=nil end
        cleanupScan()
        local function alive()return not self._closed end
        local function paint(text)
            if not alive()or self.summary.text==text then return end
            local bounds=self.summary.dimen and self.summary.dimen:copy()
            self.summary:setText(text)
            local stack=UIManager._window_stack
            if stack and stack[#stack]and stack[#stack].widget==self and bounds and bounds.w>0 and bounds.h>0 then
                Screen.bb:paintRect(bounds.x,bounds.y,bounds.w,bounds.h,require("ffi/blitbuffer").COLOR_WHITE)
                UIManager:widgetRepaint(self.summary,bounds.x,bounds.y)
                UIManager:setDirty(nil,"ui",bounds)
            end
        end
        paint(_("正在统计存储占用…"))
        self._scan_task=require("ui.common.loading_task").background(nil,function()
            local Async=require("network.async_task");local socket=require("socket")
            local yielded=socket.gettime()
            local updated=yielded
            local sizes=assert(owner.cache:getSizeBreakdown(function(count)
                local now=socket.gettime()
                if now-updated>=1 then paint(T(_("正在统计存储占用…\n已检查 %1 个项目"),count));updated=socket.gettime()end
                if count%256==0 or now-yielded>=.025 then Async.wait(.001);yielded=socket.gettime()end
            end,function(cleanup)self._scan_cleanup=cleanup end),"存储统计结果为空")
            if not alive()then return end
            local total,downloads=sizes.total or 0,sizes.downloads or 0
            paint(table.concat({
                T(_("总占用 %1 MB · 缓存 %2 MB"),to_mb(total),to_mb(total-downloads)),
                T(_("漫画阅读 %1 MB · 小说阅读 %2 MB"),to_mb((sizes.reading or 0)+(sizes.images or 0)),to_mb(sizes.novel_reading)),
                T(_("共享封面 %1 MB · 数据及其他 %2 MB"),to_mb(sizes.covers),to_mb((sizes.data or 0)+(sizes.temp or 0)+(sizes.others or 0))),
                T(_("漫画下载 %1 MB · 小说下载 %2 MB"),to_mb(downloads-(sizes.novel_downloads or 0)),to_mb(sizes.novel_downloads)),
            },"\n"))
            cleanupScan();self._scan_task=nil
        end,{delay=.05,timeout=600,is_cancelled=function()return not alive()end,
            on_cancel=cleanupScan,on_error=function()cleanupScan();self._scan_task=nil;paint(_("存储统计失败，请点击重新统计。"))end})
    end
    self:showMenu(page)
    UIManager:forceRePaint()
    page:startScan()
end

function CacheSettings:setMaxCacheSize()
    local current_max_size = self:safeConfigGet("max_cache_size", 500)

    local widget = self:createSpinWidget{
        title = _("设置最大缓存容量"),
        value = current_max_size,
        min = 100,
        max = 5000,
        step = 100,
        unit = _("MB"),
        callback = function(new_size)
            self:safeConfigSet(
                "max_cache_size",
                new_size,
                T(_("最大缓存容量已设置为 %1 MB"), new_size)
            )
        end,
    }

    UIManager:show(widget, "ui")
end

function CacheSettings:clearImageCache()
    local confirm_box = self:createConfirmBox{
        text = _("确定要清除所有图片缓存吗？"),
        ok_callback = function()
            local success, cleared = pcall(function()
                return self.cache:clearImageCache()
            end)

            if success then
                self:showInfo(T(_("已清除 %1 MB 图片缓存"),
                    math.floor(cleared / 1024 / 1024 * 100) / 100))
                -- 原地刷新缓存大小显示 (不能直接 show: 会叠出第二层缓存页)
                self:refresh()
            else
                self:showError(_("清除图片缓存失败"))
            end
        end,
    }

    UIManager:show(confirm_box, "ui")
end

function CacheSettings:clearAllCache()
    local confirm_box = self:createConfirmBox{
        text = _("确定要清除所有缓存吗？将清除封面、正文、插图和章节目录等缓存。阅读历史、进度、收藏、账号和已下载内容会保留。"),
        ok_callback = function()
            local success, cleared = pcall(function()
                return self.cache:clearAllCache()
            end)

            if success then
                self:showInfo(T(_("已清除 %1 MB 缓存"),
                    math.floor(cleared / 1024 / 1024 * 100) / 100))
                -- 原地刷新缓存大小显示 (不能直接 show: 会叠出第二层缓存页)
                self:refresh()
            else
                self:showError(_("清除缓存失败"))
            end
        end,
    }

    UIManager:show(confirm_box, "ui")
end

function CacheSettings:clearNovelCache()
    UIManager:show(self:createConfirmBox{text=_("清除小说正文与插图缓存？已下载小说、阅读进度、收藏和账号会保留。"),ok_callback=function()
        local ok,bytes=pcall(self.cache.clearNovelCache,self.cache)
        if not ok then self:showError(bytes);return end
        self:showInfo(T(_("已清除 %1 MB 小说缓存"),to_mb(bytes)));self:refresh()
    end},"ui")
end

function CacheSettings:clearDownloads(kind)
    UIManager:show(self:createConfirmBox{
        text=kind and T(_("确定删除全部%1下载吗？包括未完成任务，无法恢复。另一类下载、历史、进度、收藏和账号会保留。"),kind=="novel" and _("小说") or _("漫画"))
            or _("确定清空所有已下载吗？\n所有源的下载文件和未完成下载都会删除，无法恢复。阅读历史、进度、收藏和账号会保留。"),
        ok_text=_("清空"),cancel_text=_("取消"),
        ok_callback=function()
            local Loading=require("ui.common.loading_task")
            local notice=require("ui/widget/infomessage"):new{text=kind and _("正在删除所选类型的下载…") or _("正在停止任务并清空所有已下载…")}
            UIManager:show(notice,"ui");UIManager:forceRePaint()
            local ok,result,err=Loading.call(notice,function()
                local Library=require("util.offline_library")
                if kind then return true,Library.clearType(kind) end
                require("util.download_queue").instance():cancel("清空所有已下载")
                return true,Library.clearAll()
            end)
            if not ok then self:showError(err);return end
            self:showInfo(T(_("已清空 %1 部下载，释放 %2 MB"),result.comics,to_mb(result.bytes)))
            self:refresh()
        end,
    },"ui")
end

return CacheSettings
