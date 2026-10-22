-- Declarative source fields rendered in the existing two metadata rows.
local _=require("gettext")
local T=require("ffi/util").template
local Stats=require("ui.common.comic_stats")
local M={}
local units={chapters="%1话",pages="%1页",likes="%1喜欢",views="%1阅读",comments="%1评论"}
local projected={chapters="epsCount",pages="pagesCount",likes="likesCount",views="viewsCount",comments="commentsCount"}
local function field(comic,name)
    if name=="author" or name=="subtitle" then
        local value=comic[name];return type(value)=="string" and value~="" and value or nil
    elseif name=="categories" or name=="tags" then
        local values={}
        for _,v in ipairs(type(comic[name])=="table" and comic[name] or {}) do
            if type(v)=="string" and v~="" then values[#values+1]=v end
        end
        return #values>0 and table.concat(values," / ") or nil
    elseif name=="finished" then
        if comic.finished~=nil then return comic.finished and _("完结") or _("连载") end
    elseif name=="updated_at" then
        local value=Stats.updated_text(comic)
        return value and T(_("更新 %1"),value) or nil
    else
        local stat=name:match("^stats%.(.+)$")
        if stat then
            local count=tonumber(comic[projected[stat]] or type(comic.stats)=="table" and comic.stats[stat])
            return count and count>0 and T(_(units[stat]),math.floor(count)) or nil
        end
        local extra=name:match("^metadata%.(.+)$")
        local value=extra and type(comic.metadata)=="table" and comic.metadata[extra]
        return type(value)=="string" and value~="" and value or nil
    end
end
function M.lines(comic)
    local spec=comic._list_display
    if not spec then return nil,nil end -- Existing packages keep their defaults.
    local function row(items)
        local parts={}
        for _,item in ipairs(items or {}) do
            local value=field(comic,item.field)
            if value then parts[#parts+1]=(item.label and (item.label.." ") or "")..value end
        end
        return table.concat(parts," · ")
    end
    return row(spec.subtitle),row(spec.details)
end
return M
