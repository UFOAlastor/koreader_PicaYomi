-- Recheck at action time: an already open page may outlive its login session.
local Caps = require("source.capabilities")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")
local T = require("ffi/util").template
local Access = {}
function Access.check(source, feature, silent)
    if not Caps.needsLogin(source, feature) then return true end
    if not silent then
        UIManager:show(InfoMessage:new{
            text = T(_("请先登录%1账号"), source.name or ""), timeout = 3,
        }, "ui")
    end
    return false
end
return Access
