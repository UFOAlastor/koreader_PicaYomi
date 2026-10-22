local CenterContainer = require("ui/widget/container/centercontainer")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local KeyValuePage = require("ui/widget/keyvaluepage")
local Menu = require("ui/widget/menu")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local LoadingTask = require("ui.common.loading_task")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local WidgetSweep = require("util.widget_sweep")
local logger = require("util.logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Login = WidgetContainer:extend{
    name = "picayomi_login",
    title = _("账号登录"),
    width = Screen:getWidth(),
    height = Screen:getHeight(),
}

function Login:init()
    -- 初始化API模块
    self.auth_api = require("api.auth")

    -- 初始化用户模型
    self.user_model = require("model.user")
end

function Login:show()
    -- 检查是否已登录
    if self.user_model:isLoggedIn() then
        self:showUserInfo()
        return
    end

    -- 显示登录表单
    self:showLoginForm()
end

--- 当前源名称 (用于界面标题)
function Login:getSourceName()
    local ok, SourceRegistry = pcall(require, "source.registry")
    if ok and SourceRegistry then
        local s = SourceRegistry:getCurrent()
        if s and s.name then return s.name end
    end
    return "Picayomi"
end

function Login:showLoginForm()
    -- 部分源 (如 旧源) 使用 Cookie 登录而非账号密码
    if self.auth_api.getLoginMethod and self.auth_api:getLoginMethod() == "cookie" then
        return self:showCookieLoginForm()
    end

    -- 文案必须跟着当前源走, 不能写死"源 A" (切到源 B 后仍显示源 A 是明显的串源)
    local source_name = self:getSourceName()

    -- 创建登录表单字段
    local fields = {
        {
            text = "",
            hint = T(_("输入%1账号"), source_name),
        },
        {
            text = "",
            hint = _("输入账号密码"),
            text_type = "password",
        },
    }

    -- 捕获self变量
    local this = self

    -- 创建登录对话框
    self.login_dialog = MultiInputDialog:new{
        -- 账号页只弹对话框, 自己不压栈 —— 它就是本次会话的**第一层**插件控件,
        -- 必须自带清扫标记, 否则退出时会留在 KOReader 界面上
        is_picayomi_page = true,
        title = T(_("%1 登录"), source_name),
        fields = fields,
        buttons = {
            {
                {
                    text = _("登录"),
                    is_enter_default = true,
                    callback = function()
                        -- 确保login_dialog存在
                        if not this.login_dialog then
                            return
                        end

                        -- 获取输入字段的值
                        local input_fields = this.login_dialog:getFields()
                        local email = input_fields[1]
                        local password = input_fields[2]

                        -- 检查输入
                        if not email or email == "" or not password or password == "" then
                            UIManager:show(InfoMessage:new{
                                text = _("请输入完整的登录信息"),
                            }, "ui")
                            return
                        end

                        -- 关闭登录对话框
                        UIManager:close(this.login_dialog, "ui")
                        this.login_dialog = nil

                        -- 处理登录
                        this:login(email, password)
                    end,
                },
                {
                    text = _("取消"),
                    callback = function()
                        -- 关闭登录对话框
                        if this.login_dialog then
                            UIManager:close(this.login_dialog, "ui")
                            this.login_dialog = nil
                        end
                        -- 返回父界面
                        UIManager:close(this, "ui")
                    end,
                },
            },
        },
    }

    -- 显示对话框
    UIManager:show(self.login_dialog, "ui")
end

--- Cookie 登录表单 (旧源 等无账号密码接口的源)
function Login:showCookieLoginForm()
    local this = self
    local source_name = self:getSourceName()

    self.login_dialog = InputDialog:new{
        is_picayomi_page = true, -- 同 showLoginForm: 它是本次会话的第一层插件控件
        title = T(_("%1 Cookie 登录"), source_name),
        description = _("请从浏览器复制本站 Cookie 后粘贴到下方。\n需要包含 ipb_member_id 与 ipb_pass_hash 两项。"),
        input = "",
        input_hint = "ipb_member_id=...; ipb_pass_hash=...",
        buttons = {
            {
                {
                    text = _("登录"),
                    is_enter_default = true,
                    callback = function()
                        if not this.login_dialog then return end
                        local value = this.login_dialog:getInputText()
                        if not value or value:match("^%s*$") then
                            UIManager:show(InfoMessage:new{
                                text = _("请输入 Cookie"),
                                timeout = 2,
                            }, "ui")
                            return
                        end
                        UIManager:close(this.login_dialog, "ui")
                        this.login_dialog = nil
                        this:login(value, nil)
                    end,
                },
                {
                    text = _("取消"),
                    callback = function()
                        if this.login_dialog then
                            UIManager:close(this.login_dialog, "ui")
                            this.login_dialog = nil
                        end
                        UIManager:close(this, "ui")
                    end,
                },
            },
        },
    }
    UIManager:show(self.login_dialog, "ui")
end

function Login:login(email, password)
    -- 记录登录输入（不包含密码）
    if logger.enabled then logger.info("Login: 开始登录") end

    -- 显示登录中消息
    local loading = InfoMessage:new{
        text = _("登录中..."),
    }
    UIManager:show(loading, "ui")
    -- 同步刷一次: show 只是把刷新入队, 而这里马上要阻塞做网络请求,
    -- 不等这一下的话事件循环没机会重绘, 提示等于没显示
    UIManager:forceRePaint()

    -- 调用登录API
    -- 抛异常时也关掉提示: 这条"登录中..."**没有 timeout**, 关不掉就永久盖屏
    local success, token, error_msg = LoadingTask.call(loading, function()
        return self.auth_api:login(email, password)
    end)

    -- 处理登录结果
    if success then
        -- 登录成功
        if logger.enabled then logger.info("Login: 登录成功") end

        -- 获取用户信息
        local profile_success, profile = self.auth_api:getProfile()

        if profile_success and profile then
            -- 显示欢迎消息
            UIManager:show(InfoMessage:new{
                text = _("登录成功，欢迎 ") .. (profile.name or _("未知用户")),
                timeout = 2,
            }, "ui")
        else
            -- 显示登录成功但无法获取用户信息的消息
            UIManager:show(InfoMessage:new{
                text = _("登录成功，但无法获取用户信息"),
                timeout = 2,
            }, "ui")
        end

        -- 打开主界面
        UIManager:scheduleIn(1, function()
            -- 复用已在窗口栈里的主页菜单, 不要再 new 一个 (会堆叠出重复菜单)
            -- 延迟任务: 任务队列不兜异常, 抛出来 = 整个 KOReader 退出 (用户刚点了登录)。
            -- 回主页失败时用户仍停在原页面, 可以手动返回。
            local ok, err = pcall(function() require("ui.home").returnToHome() end)
            if not ok then
                logger.warn("Login: 登录后回主页失败: " .. tostring(err))
            end
        end)
    else
        -- 登录失败
        UIManager:show(InfoMessage:new{
            text = T(_("登录失败: %1"), error_msg or _("未知错误")),
            timeout = 3,
        }, "ui")

        -- 重新显示登录表单
        self:showLoginForm()
    end
end

function Login:showUserInfo()
    -- 获取用户信息
    local profile = self.user_model:getUserProfile()

    if not profile then
        -- 尝试重新获取用户信息
        local success, profile_data = self.auth_api:getProfile()
        if success then
            profile = profile_data
        else
            -- 无法获取用户信息，回到登录界面
            if self.user_dialog then
                UIManager:close(self.user_dialog, "ui")
                self.user_dialog = nil
            end
            UIManager:show(InfoMessage:new{
                text = _("无法获取用户信息，请重新登录"),
                timeout = 2,
            }, "ui")
            self:showLoginForm()
            return
        end
    end

    -- 构建用户信息按钮
    local this = self
    local old_dialog = self.user_dialog
    self.user_dialog = ButtonDialog:new{
        is_picayomi_page = true, -- 同 showLoginForm: 它是本次会话的第一层插件控件
        title = T(_("%1 的个人资料"), profile.name or _("用户")),
        buttons = {
            {
                {
                    text = _("刷新信息"),
                    callback = function()
                        -- **不要先关用户信息页**: 取数是同步的, 关掉之后那一两秒
                        -- 屏幕上露出的是登录页 (上一页), 取完才重新弹出来 ——
                        -- 就是"点了刷新先退回上一页"。showUserInfo 会先建新的再换旧的。
                        this:fetchUserProfile()
                    end,
                },
                {
                    text = _("退出登录"),
                    callback = function()
                        if this.user_dialog then
                            UIManager:close(this.user_dialog, "ui")
                            this.user_dialog = nil
                        end
                        this:confirmLogout()
                    end,
                },
            },
            {
                {
                    text = _("返回"),
                    callback = function()
                        if this.user_dialog then
                            -- 带刷新模式关闭, 会让本页下面的主页菜单重新画出来
                            UIManager:close(this.user_dialog, "ui")
                            this.user_dialog = nil
                        end
                        -- 关键: **不要**再 new 一个 Home。
                        -- 主页菜单本来就在窗口栈里 (只是被本页盖住), 关掉本页它自然重新可见。
                        -- 若在这里新建一个 Home 并 show(), 就会往栈里再压一个一模一样的菜单:
                        --   栈: [底层, 主页A] -> 进账号页 -> 返回 -> [底层, 主页A, 主页B]
                        -- 之后每次点「返回」只弹掉一层**相同**的菜单, 屏幕上看起来毫无变化,
                        -- 用户就会觉得"点了没反应/卡死" (实测要连点 4 次才退得出去)。
                        require("ui.home").returnToHome()
                    end,
                },
            },
        },
    }

    -- 先 show 新的再关旧的: 「刷新信息」时旧页面一直撑到新页面压上来,
    -- 中间不会露出下面的登录页 (见「刷新信息」按钮的注释)
    WidgetSweep.replace_page(old_dialog, self.user_dialog)
end

function Login:fetchUserProfile()
    -- 显示加载消息
    local loading = InfoMessage:new{
        text = _("获取用户信息..."),
        timeout = 30,
    }
    UIManager:show(loading, "ui")
    -- 同步刷一次: show 只是把刷新入队, 而这里马上要阻塞做网络请求,
    -- 不等这一下的话事件循环没机会重绘, 提示等于没显示
    UIManager:forceRePaint()

    -- 获取用户个人资料
    -- 抛异常时也关掉提示 (这条有 30s timeout, 但 30 秒的遮挡同样不能接受)
    local success, profile, error_msg = LoadingTask.call(loading, function()
        return self.auth_api:getProfile()
    end)

    if success and profile then
        -- 显示成功消息
        UIManager:show(InfoMessage:new{
            text = _("用户信息获取成功"),
            timeout = 2,
        }, "ui")
        -- 重新显示用户信息
        self:showUserInfo()
    else
        -- 显示错误消息
        UIManager:show(InfoMessage:new{
            text = T(_("获取用户信息失败: %1"), error_msg or _("未知错误")),
            timeout = 3,
        }, "ui")
    end
end

function Login:confirmLogout()
    -- 创建确认对话框
    local this = self
    self.confirm_dialog = ConfirmBox:new{
        is_picayomi_page = true, -- 压在 user_dialog 之上; 标记只保证它自己也能被单独扫到
        text = _("确定要退出登录吗？"),
        ok_text = _("退出登录"),
        ok_callback = function()
            -- 执行退出登录
            this.auth_api:logout()

            if this.confirm_dialog then
                UIManager:close(this.confirm_dialog, "ui")
                this.confirm_dialog = nil
            end

            UIManager:show(InfoMessage:new{
                text = _("已退出登录"),
                timeout = 2,
            }, "ui")

            -- 延迟返回主界面
            UIManager:scheduleIn(2, function()
                -- 同上: 复用已有的主页菜单; 延迟任务里抛异常会逃出任务队列
                local ok, err = pcall(function() require("ui.home").returnToHome() end)
                if not ok then
                    logger.warn("Login: 退出登录后回主页失败: " .. tostring(err))
                end
            end)
        end,
        cancel_text = _("取消"),
        cancel_callback = function()
            if this.confirm_dialog then
                UIManager:close(this.confirm_dialog, "ui")
                this.confirm_dialog = nil
            end
        end,
    }

    UIManager:show(self.confirm_dialog, "ui")
end

return Login