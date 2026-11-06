local BaseSettingsModule = require("ui.settings.base")
local ButtonDialog = require("ui.common.action_style").ButtonDialog
local QrInfo = require("ui.common.qr_info")
local MenuStyle = require("ui.common.menu_style")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local AboutSettings = BaseSettingsModule:new{
    name = "about_settings",
}

--- 本插件自己的 _meta.lua
--
-- **不能用 require("_meta")。** KOReader 的 PluginLoader 在加载完所有插件之后会把
-- **每一个**已加载插件的目录都追加进 package.path (pluginloader.lua:283-286), 而且是
-- 按插件路径排序后依次追加 —— 于是 `require("_meta")` 命中的是排在**最前面**的那个
-- 插件的 _meta.lua。真机上那个是 `archiveviewer.koplugin`, 它的 _meta 只有
-- fullname / description, 没有 version 字段, 关于页就永远显示 "unknown"。
--
-- (模拟器里 package.path 的第一项就是本插件目录, 所以测试一直是绿的 —— 典型的
--  "用替身测出来的通过": 依赖的形态和真机不一样。)
--
-- 按本文件自己的路径去定位, 与 package.path 无关; 与 main.lua 的
-- BasePath:getPluginDirectory() 同一个办法。
local own_meta = nil
local function load_own_meta()
    local src = debug.getinfo(1, "S").source
    local dir = src and src:match("^@(.*)/[^/]+$")
    if not dir then return nil end
    local ok, meta = pcall(dofile, dir .. "/../../_meta.lua")
    if ok and type(meta) == "table" and type(meta.version) == "string" then
        return meta
    end
    return nil
end

--- 版本号 (来自本插件的 _meta.lua, 不写死)
function AboutSettings:getVersion()
    if not own_meta then own_meta = load_own_meta() end
    return tostring((own_meta and own_meta.version) or "unknown")
end

--- 丢弃已加载的 _meta 缓存 (测试用)
--
-- 没有这个钩子, "package.path 被别的插件污染"那条用例根本没法测: 前面的用例
-- 已经把正确的 meta 缓存住了, 后面的污染对它无效 —— 负向对照会假绿。
function AboutSettings.resetMetaCache()
    own_meta = nil
end

--- 关于页
--
-- **必须用菜单，不能用弹窗 (ButtonDialog)**：
-- 菜单经 manager:showMenu() 会进入菜单栈，"返回"才能正确退一层；
-- 弹窗不会入栈 —— 点"返回"时 goBack() 发现栈是空的，就把整个设置关掉，
-- 而弹窗自己还留在屏幕上，表现就是"点返回没反应"。(实测踩到)
--- 参考项目 (点击后显示二维码; 二维码内容就是仓库地址)
AboutSettings.LINKS = {
    plugin = "https://github.com/UFOAlastor/koreader_PicaYomi",
    sources = "https://github.com/UFOAlastor/PicaYomi_Sources",
    rakuyomi = "https://github.com/hanatsumi/rakuyomi",
    picacomic = "https://github.com/Pacalini/PicaComic",
    koreader = "https://github.com/koreader/koreader",
}

--- 全屏二维码: 顶部写明这是什么仓库, 下面给出 URL; 点一下或按任意键关闭
function AboutSettings:showQr(url, title)
    self.qr_message = QrInfo.show{
        url = url,
        title_text = title,
        hint = _("扫码可打开上面的仓库链接 · 点屏幕关闭"),
    }
end

--- 参考项目有两个, 先让用户选一个再显示对应二维码
function AboutSettings:showReferenceProjects()
    local dialog
    dialog = ButtonDialog:new{
        is_picayomi_page = true,
        title = _("参考项目（点按钮显示二维码）"),
        buttons = {
            {
                {
                    text = "Rakuyomi",
                    callback = function()
                        UIManager:close(dialog, "ui")
                        self.reference_dialog = nil
                        self:showQr(AboutSettings.LINKS.rakuyomi,
                            _("Rakuyomi GitHub 仓库链接"))
                    end,
                },
            },
            {
                {
                    text = "PicaComic",
                    callback = function()
                        UIManager:close(dialog, "ui")
                        self.reference_dialog = nil
                        self:showQr(AboutSettings.LINKS.picacomic,
                            _("PicaComic GitHub 仓库链接"))
                    end,
                },
            },
            {
                {
                    text = _("取消"),
                    callback = function()
                        UIManager:close(dialog, "ui")
                        self.reference_dialog = nil
                    end,
                },
            },
        },
    }
    self.reference_dialog = dialog
    UIManager:show(dialog, "ui")
end

function AboutSettings:show()
    self._license_taps=0
    local menu
    local function automaticText()
        return T(_("自动检查更新：%1"),self:safeConfigGet("plugin_auto_update") and _("开启") or _("关闭"))
    end
    local items = {
        { text = T(_("版本 %1"), self:getVersion()), callback = function()
            self:showQr(self.LINKS.plugin, _("PicaYomi GitHub 仓库链接"))
        end, picayomi_compact_actions = true, picayomi_actions = {
            {text = T(_("版本 %1"), self:getVersion()), plain = true, callback = function()
                self:showQr(self.LINKS.plugin, _("PicaYomi GitHub 仓库链接"))
            end},
            {text = _("检查更新"), callback = function()require("ui.settings.plugin_update").check()end},
        } },
        {
            text = _("自动检查插件更新"),
            callback = function()
                if self:safeConfigSet("plugin_auto_update",not self:safeConfigGet("plugin_auto_update")) then
                    local automatic=menu.item_table[2]
                    automatic.picayomi_actions[1].text=automaticText()
                    menu:updateItems()
                end
            end,
        },
        {
            text = _("漫画与小说阅读插件 · 基于 KOReader"),
            callback = function()
                self:showQr(AboutSettings.LINKS.koreader,
                    _("KOReader GitHub 仓库链接"))
            end,
        },
        {
            text = _("主要功能"),
            callback = function()
                self:showFeatures()
            end,
        },
        {
            text = _("参考项目: Rakuyomi / PicaComic"),
            callback = function()
                self:showReferenceProjects()
            end,
        },
        { text = _("开源许可: MIT"), callback = function()
            local now=os.time()
            self._license_taps=(self._license_time and now-self._license_time<=3) and self._license_taps+1 or 1
            self._license_time=now
            if self._license_taps==3 then
                self._license_taps=0
                self:showQr(self.LINKS.sources, _("PicaYomi 源仓库"))
            end
        end, _license=true },
        self:createBackButton(),
    }
    local automatic=items[2]
    automatic.picayomi_compact_actions=true
    automatic.picayomi_actions={{text=automaticText(),plain=true,callback=function()automatic.callback()end}}
    local state_ok,state=pcall(require("util.plugin_update").state)
    if state_ok and state.previous and not state.pending then
        automatic.picayomi_actions[2]={text=_("恢复上一版插件"),bold=false,callback=function()
            self._license_taps=0
            require("ui.settings.plugin_update").rollback()
        end}
    end
    for _,item in ipairs(items) do
        if item.callback and not item._license then
            local callback=item.callback
            item.callback=function(...) self._license_taps=0;return callback(...) end
        end
    end
    menu = self:createMenu(_("关于"), items)
    -- 关于页的条目只是"打开二维码/子页", 点完不能把设置页退掉
    MenuStyle.disableSelectAutoClose(menu)
    self:showMenu(menu)
end

function AboutSettings:showFeatures()
    local items = {
        { text = _("多源阅读：漫画与小说分组，按需安装源"), enabled = false, select_enabled = false },
        { text = _("浏览作品：推荐、最新、分类与排行（依源支持）"), enabled = false, select_enabled = false },
        { text = _("多源搜索：当前源或全部同类型源，保留搜索历史"), enabled = false, select_enabled = false },
        { text = _("漫画阅读：按需加载，支持条漫与横屏"), enabled = false, select_enabled = false },
        { text = _("图像增强：锐化、降噪、色调与小图放大"), enabled = false, select_enabled = false },
        { text = _("小说阅读：正文与插图，原生字体和排版"), enabled = false, select_enabled = false },
        { text = _("提前加载：漫画页、小说章节，可选自动下一章"), enabled = false, select_enabled = false },
        { text = _("下载与续读：章节下载、离线阅读与阅读历史"), enabled = false, select_enabled = false },
        { text = _("作品收藏：线上或本地收藏（依源支持）"), enabled = false, select_enabled = false },
        { text = _("作品评论：查看全文与回复（依源支持）"), enabled = false, select_enabled = false },
        { text = _("手势与刷新：边缘返回、列表翻屏与刷新设置"), enabled = false, select_enabled = false },
        { text = _("存储管理：查看占用，分别清理缓存与下载"), enabled = false, select_enabled = false },
        { text = _("插件与源更新：检查、安装与插件版本恢复"), enabled = false, select_enabled = false },
        self:createBackButton(),
    }
    local menu = self:createMenu(_("主要功能"), items)
    MenuStyle.disableSelectAutoClose(menu)
    self:showMenu(menu)
end

return AboutSettings
