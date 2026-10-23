-- ui/common/page_jump.lua
-- 统一的"跳页"弹窗: 输入页号 → 校验 → 跳过去。
--
-- 为什么要收敛: 同一个动作原先在四处各写了一份, 而且交互还是三种不同的东西 ——
--   visual_comic_list / comic_detail  用 InputDialog (能跳任意页),
--   favorites                         用 ButtonDialog, 只给 1 / 1/3 / 1/2 / 2/3 / 末页
--                                     五个固定页号,
--   search                            用 SpinWidget (总页数上千时要按几百下)。
-- 前两者的交互才是对的: 用户想跳的是**任意**一页。这里统一成 InputDialog,
-- 调用方只负责"写清范围的说明文案 + 校验 + 真正跳过去"。
--
-- 校验为什么留给调用方: "什么算合法页号"只有调用方知道 —— 列表页的上限可能是
-- 服务端总页数 (可信时), 也可能压根未知; 详情页则是内存里的章节屏数。所以这里
-- 只做最基本的"是 >=1 的整数", 其余由 on_jump 返回 (ok, err) 表达。

local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local PageJump = {}

--- 弹出跳页输入框
-- @param opts.title       弹窗标题 (默认「跳转到指定页」)
-- @param opts.description 输入框下方的说明, 由调用方写清可用范围
-- @param opts.current     当前页号, 作为输入框初值
-- @param opts.on_jump     function(n) -> ok, err
--                         校验并跳转; 返回 false + err 时弹提示 (err 为 nil 则静默)
-- @return dialog 控件 (便于测试与调用方持有)
function PageJump.show(opts)
    opts = opts or {}

    -- 必须分两行声明: 若写成 `local dialog = InputDialog:new{ ... callback 里引用
    -- dialog ... }`, 闭包看到的 `dialog` **不是**这个局部变量 —— Lua 的局部变量
    -- 作用域从声明语句**之后**才开始, 于是闭包里的 dialog 是全局 nil,
    -- `UIManager:close(nil)` 是空操作 => 弹窗永远关不掉。
    local dialog
    dialog = InputDialog:new{
        title = opts.title or _("跳转到指定页"),
        description = opts.description,
        input = tostring(opts.current or 1),
        input_type = "number",
        buttons = {
            {
                {
                    text = _("取消"),
                    id = "close",
                    callback = function() UIManager:close(dialog, "ui") end,
                },
                {
                    text = _("跳转"),
                    is_enter_default = true,
                    callback = function()
                        local value = dialog:getInputText()
                        UIManager:close(dialog, "ui")

                        local n = tonumber(value)
                        if not n or n ~= math.floor(n) or n < 1 then
                            UIManager:show(InfoMessage:new{
                                text = _("请输入 1 以上的整数页码"),
                                timeout = 3,
                            }, "ui")
                            return
                        end

                        if not opts.on_jump then return end
                        local ok, err = opts.on_jump(n)
                        if not ok and err then
                            UIManager:show(InfoMessage:new{
                                text = require("ui.common.error_message").describe(err),
                                timeout = 3,
                            }, "ui")
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog, "ui")
    dialog:onShowKeyboard()
    return dialog
end

return PageJump
