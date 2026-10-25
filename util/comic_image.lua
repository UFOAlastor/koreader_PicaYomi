-- Export source pixels, never the framebuffer or a screen-sized render cache.
local lfs = require("libs/libkoreader-lfs")
local M = {}

local function component(value)
    local text = tostring(value or ""):gsub('[%z\1-\31/\\:*?"<>|]', "_"):gsub("[%.%s]+$", "")
    local chars = {}
    for char in text:gmatch("[^\128-\191][\128-\191]*") do
        chars[#chars + 1] = char
        if #chars == 28 then break end
    end
    text = table.concat(chars)
    return text ~= "" and text ~= "." and text ~= ".." and text or "漫画"
end

local function copy(source, target)
    local input = assert(io.open(source, "rb"), "无法读取本页原图")
    local output
    local ok, err = pcall(function()
        output = assert(io.open(target, "wb"), "无法写入所选目录")
        while true do
            local bytes, read_err = input:read(65536)
            assert(not read_err, "读取原图失败")
            if not bytes then break end
            assert(output:write(bytes), "写入原图失败，存储空间可能不足")
        end
        local closed = output:close()
        output = nil
        assert(closed, "保存原图失败，存储空间可能不足")
    end)
    input:close()
    if output then output:close() end
    assert(ok, err)
end

local function processed(info, target)
    -- Full-resolution, full-color export may need decoding, a transformed copy
    -- and PNG encoder buffers. Refuse before allocating if that peak won't fit.
    local budget = require("util.memory_guard").instance():prepare_decode()
    local pixels = info.width * info.height
    local peak = pixels * 24 + (lfs.attributes(info.path, "size") or 0) * 2 + 4 * 1024 * 1024
    assert(peak <= budget, "可用内存不足以保存完整原图，请稍后重试")
    local bb
    local failure = "无法解码完整原图"
    local ok = pcall(function()
        local format = require("util.image_guard").normalize_format(info.format)
        if format == "jpeg" or format == "webp" then
            bb = require("util.scaled_decode").decode(info.path, format, info.width, info.height, true, budget)
        elseif format == "png" then
            bb = require("util.png_decode").decode(info.path, true, budget)
        else
            bb = require("ui/renderimage"):renderImageFile(info.path, false)
        end
        assert(bb and bb:getWidth() == info.width and bb:getHeight() == info.height, "无法解码完整原图")
        local desc = info.processing
        local out
        failure = "原图还原失败，未保存图片"
        if desc.digest then
            out = require("source.processors").render(desc, bb, info.url)
            -- processors.render frees the input on successful replacement.
            if out then bb = out end
        else
            local mod = require(desc.module)
            out = mod[desc.fn](bb, desc.context or info.url)
            if out and out ~= bb then bb:free(); bb = out end
        end
        assert(out, "原图还原失败，未保存图片")
        failure = "原图还原后的尺寸不符"
        assert(bb:getWidth() == info.width and bb:getHeight() == info.height, "原图还原后的尺寸不符")
        failure = "写入原图失败，存储空间可能不足"
        assert(bb:writePNG(target), "写入原图失败，存储空间可能不足")
    end)
    if bb then bb:free() end
    if not ok then error(failure, 0) end
end

function M.save(doc, page, directory)
    if not (doc and doc.isComic and doc:isComic()) then return nil, "当前不是漫画阅读" end
    if type(directory) ~= "string" or lfs.attributes(directory, "mode") ~= "directory" then
        return nil, "保存目录不存在或不可访问，请重新选择"
    end
    local info, err = doc:getPageImageInfo(page)
    if not info then return nil, err end
    local extensions = { ["jpeg"] = "jpg", ["jpg"] = "jpg", ["png"] = "png", ["webp"] = "webp", ["gif"] = "gif", ["bmp"] = "bmp" }
    local extension = info.processing and "png" or extensions[info.format]
    if not extension then return nil, "不支持保存此图片格式" end
    local session = doc.session
    local episode = session.context and session.context.episode
    local stem = component(session.title) .. "_" .. component(episode and episode.title or session.order)
        .. string.format("_p%04d", page)
    -- Reserve a staging directory atomically. Failed writes stay out of the
    -- final filename, and the page cache is never moved or modified.
    local staging
    for index = 1, 1000 do
        local candidate = directory .. "/.picayomi-save-" .. os.time() .. "-" .. index
        if lfs.mkdir(candidate) then staging = candidate; break end
        if not lfs.symlinkattributes(candidate) then break end
    end
    if not staging then return nil, "无法写入所选目录，请检查权限或存储空间" end
    local temp = staging .. "/image." .. extension
    local target
    local ok, failure = pcall(function()
        if info.processing then processed(info, temp) else copy(info.path, temp) end
        assert((lfs.attributes(temp, "size") or 0) > 0, "原图文件为空，未保存图片")
        for index = 0, 9999 do
            local suffix = index == 0 and "" or "_" .. index
            local candidate = directory .. "/" .. stem .. suffix .. "." .. extension
            if not lfs.symlinkattributes(candidate) then target = candidate; break end
        end
        assert(target, "同名图片过多，请选择其他目录")
        assert(os.rename(temp, target), "保存原图失败，请检查目录权限或存储空间")
    end)
    os.remove(temp)
    lfs.rmdir(staging)
    if not ok then
        local message = tostring(failure)
        while message:match("^.-:%d+: ") do message = message:gsub("^.-:%d+: ", "") end
        return nil, message
    end
    return target
end

return M
