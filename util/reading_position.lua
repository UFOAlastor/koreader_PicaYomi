-- util/reading_position.lua
-- 清掉 KOReader 为某一话记住的"读到第几页"
--
-- 为什么需要: 「开始」的语义是**固定从第一章第一页**, 禁止加载任何阅读进度;
-- 只有「继续」才读进度 (见 ui/common/comic_detail.lua 的按钮)。但 KOReader 自己会把
-- 页码记在文档的 sidecar 设置里, 打开文档时自动恢复:
--     ReaderPaging:onReadSettings -> self:_gotoPage(config:readSetting("last_page") or 1)
-- 不清掉的话就会"点「开始」却接着上次读"。
--
-- 同一话可能有两种文档, 各自的 sidecar 都要清:
--   * 流式阅读的占位文件  <cache>/reading/<漫画>_<章节>.stream
--   * 离线打包的 CBZ      <cache>/downloads/<漫画>_<章节>.cbz (prepareComic 的快路径优先用它)
-- 只清其中一个的话, 从另一条路径打开时进度照样会被恢复。
--
-- 时机: 必须在**文档被打开之前**清 (打开时 KOReader 才去读 sidecar), 所以调用点是
-- api/comic.lua:prepareComic 的最前面 —— 那是所有打开路径 (首次/换章/续读) 的必经之路。

local logger = require("util.logger")
local lfs = require("libs/libkoreader-lfs")

local ReadingPosition = {}

--- 清掉某个文档路径对应的阅读进度
--
-- 只在这个文档**真实存在**时才动: 否则 DocSettings:flush 会为它凭空建出
-- 一个空的 sidecar 目录, 白占缓存。文档不存在 = 本来就没有进度可清。
function ReadingPosition.clearPath(path)
    if not path or path == "" then return false end
    if lfs.attributes(path, "mode") ~= "file" then return false end

    local ok_ds, DocSettings = pcall(require, "docsettings")
    if not ok_ds or not DocSettings then return false end

    return pcall(function()
        local ds = DocSettings:open(path)
        if not ds then return end
        ds:delSetting("last_page")
        ds:delSetting("page_positions")
        ds:delSetting("percent_finished")
        ds:flush()
    end)
end

--- 清掉某一话的阅读进度 (流式 + CBZ 两条路径都清)
-- @return 至少清掉了一处则返回 true
function ReadingPosition.clear(comic_id, order, source_id)
    if not (comic_id and order) then return false end

    local ok_dm, DownloadManager = pcall(require, "network.download_manager")
    if not ok_dm or not DownloadManager then return false end

    local a = ReadingPosition.clearPath(DownloadManager.getStreamPath(comic_id, order, source_id))
    local b = ReadingPosition.clearPath(DownloadManager.getCBZPath(comic_id, order, source_id))

    if a or b then
        if logger.enabled then logger.info(string.format(
            "Picayomi: 已清掉 %s 第 %s 话的阅读进度 (「开始」固定从头读)",
            tostring(comic_id), tostring(order))) end
    end
    return a or b
end

return ReadingPosition
