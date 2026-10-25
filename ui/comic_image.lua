local UIManager = require("ui/uimanager")
local ReaderUI = require("apps/reader/readerui")
local InfoMessage = require("ui/widget/infomessage")
local Config = require("util.config")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local T = require("ffi/util").template
local M = {}

function M.available(ui)
    local doc = ui and ui.document
    return doc and doc.isComic and doc:isComic() == true or false
end

function M.chooseAndSave(ui)
    if not M.available(ui) then return end
    -- Capture the page before opening any menus. Scrolled comics may show more
    -- than one page; getCurrentPage uses the host's current reading position.
    local doc, page = ui.document, ui:getCurrentPage()
    local info, err = doc:getPageImageInfo(page)
    if not info then
        UIManager:show(InfoMessage:new{ text = err }, "ui")
        return
    end
    local path = Config:get("comic_image_save_dir")
    if type(path) ~= "string" or lfs.attributes(path, "mode") ~= "directory" then
        path = require("apps/filemanager/filemanagerutil").getHomeFolder()
    end
    local function current()
        return ReaderUI.instance == ui and ui.document == doc and M.available(ui)
    end
    local chooser = require("ui/widget/pathchooser"):new{
        title = T(_("保存第 %1 页原图：长按选择文件夹"), page),
        path = path,
        select_directory = true,
        select_file = false,
        show_files = false,
        onConfirm = function(directory)
            if not current() then return end
            require("ui.common.loading_task").run{
                message = _("正在保存原图…"),
                delay = 0.1,
                is_cancelled = function() return not current() end,
                fetch = function()
                    local target, failure = require("util.comic_image").save(doc, page, directory)
                    return target ~= nil, target, failure
                end,
                on_done = function(ok, target, failure)
                    if not current() then return end
                    if ok then
                        local remembered = Config:set("comic_image_save_dir", directory)
                        local text = _("原图已保存到：") .. "\n" .. target
                        if not remembered then text = text .. "\n\n" .. _("保存目录未能记住，下次请重新选择。") end
                        UIManager:show(InfoMessage:new{ text = text }, "ui")
                    elseif failure then
                        UIManager:show(InfoMessage:new{ text = _("保存原图失败：") .. "\n" .. failure }, "ui")
                    end
                end,
            }
        end,
    }
    UIManager:show(chooser, "ui")
end

return M
