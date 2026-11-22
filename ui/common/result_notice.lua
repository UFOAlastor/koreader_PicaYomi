local _ = require("gettext")

local ResultNotice = {}

function ResultNotice:new(options)
    if not options.timeout then
        options.text = options.text .. "\n\n" .. _("点击关闭")
    end
    return require("ui/widget/infomessage"):new(options)
end

return ResultNotice
