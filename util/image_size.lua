-- util/image_size.lua
-- 只读**文件头**拿图片宽高, 不做解码。
--
-- 为什么需要它 (根因):
--   KOReader 取图片尺寸的唯一现成办法是 `ffi/pic.lua` 的 `pic.openDocument(path)`,
--   而它是**急切解码**的 —— 会把整张图解进 `image_bb`
--   (base/ffi/pic.lua:140 `BB.new(width, height, BB.TYPE_BBRGB32)`, 漫画页实测 ~19MB)。
--   于是"只想知道这一页多大"要付一次全图解码的代价, 造成两个后果:
--
--     1. **排版链里不敢量尺寸**。排版 (getNativePageDimensions) 早于渲染, 而
--        ReaderZooming:getZoom 在 zoom_mode="page" 时**只**用 getNativePageDimensions
--        (readerzooming.lua:526/537)。尺寸未知时它按占位页尺寸 (屏幕大小) 算 zoom,
--        于是整页的显示尺寸不对 —— 而这条链上没有"尺寸到齐后再算一次"的机会。
--     2. **每页下载完都要卡一下**。ui/stream_reader.lua 的 measure_page 在下载完成
--        回调里量尺寸, 一次全图解码在主线程上就是几十到几百毫秒的卡顿。
--
--   而 JPEG / PNG / GIF / BMP / WEBP 的宽高都在文件头的前几十字节里。
--
-- 职责边界: 只做"读宽高 (附带魔数里的格式名)"。**不做格式嗅探/有效性校验** ——
-- 那是 network/download_manager 的 detect_image_ext / is_valid_image_file 的职责。
-- 解析不出来就返回 nil, 退路由调用方决定 (绝不在这里解码)。
--
-- 覆盖的格式与 ffi/pic.lua 支持的完全一致: JPEG / PNG / GIF / BMP / WEBP。

local bit = require("bit")

local ImageSize = {}

-- 一次最多读多少字节去扫文件头。
--
-- JPEG 的 SOF 段可能排在 EXIF / ICC 之后, 所以给得比"够用"宽一些。128KB 对任何
-- 真实图片都远超实际需要 (SOF 基本都在头几 KB 内), 而一次 read 也只有 128KB。
ImageSize.MAX_PROBE = 128 * 1024

----------------------------------------------------------------------------
-- 字节序小工具 (全部返回 nil 表示"越界", 由调用方当解析失败)
----------------------------------------------------------------------------

local function u16be(d, i)
    local a, b = d:byte(i, i + 1)
    if not b then return nil end
    return a * 256 + b
end

local function u32be(d, i)
    local a, b, c, e = d:byte(i, i + 3)
    if not e then return nil end
    return ((a * 256 + b) * 256 + c) * 256 + e
end

local function u16le(d, i)
    local a, b = d:byte(i, i + 1)
    if not b then return nil end
    return b * 256 + a
end

local function u32le(d, i)
    local a, b, c, e = d:byte(i, i + 3)
    if not e then return nil end
    return a + b * 256 + c * 65536 + e * 16777216
end

local function u24le(d, i)
    local a, b, c = d:byte(i, i + 2)
    if not c then return nil end
    return a + b * 256 + c * 65536
end

----------------------------------------------------------------------------
-- 各格式解析
----------------------------------------------------------------------------

--- JPEG: 顺着 marker 链找 SOF 段 (只有它带宽高)
--
-- 每个带载荷的段都自带 2 字节长度 (含长度字段自身), 所以可以逐段跳过 ——
-- 不必理解 EXIF / ICC / 缩略图这些段的内容。
-- SOF 是 0xC0~0xCF 里的 13 个: 0xC4(DHT) / 0xC8(JPG) / 0xCC(DAC) 不是。
local function parse_jpeg(d)
    local len = #d
    local pos = 3                      -- 1-based; 前 2 字节是 SOI(FFD8)

    while pos + 1 <= len do
        if d:byte(pos) ~= 0xFF then return nil end
        local marker = d:byte(pos + 1)
        -- 允许 marker 前有填充的 0xFF
        while marker == 0xFF and pos + 2 <= len do
            pos = pos + 1
            marker = d:byte(pos + 1)
        end

        if marker == 0xD9 or marker == 0xDA then
            return nil                 -- EOI / 扫描开始: 不会有 SOF 了
        elseif marker == 0x01 or (marker >= 0xD0 and marker <= 0xD8) then
            pos = pos + 2              -- TEM / RSTn / SOI: 没有长度字段
        else
            local seg = u16be(d, pos + 2)
            if not seg or seg < 2 then return nil end

            local is_sof = marker >= 0xC0 and marker <= 0xCF
                and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC
            if is_sof then
                -- SOF 载荷: 精度(1) 高(2) 宽(2)
                local h = u16be(d, pos + 5)
                local w = u16be(d, pos + 7)
                if w and h and w > 0 and h > 0 then return w, h end
                return nil
            end

            pos = pos + 2 + seg
        end
    end
    return nil
end

--- PNG: 签名之后紧跟的 IHDR 就带宽高 (固定位置, 不必遍历 chunk)
local function parse_png(d)
    -- 8 字节签名 + 4 字节长度 + "IHDR" + 宽(4) + 高(4) => 需要 24 字节
    if #d < 24 or d:sub(13, 16) ~= "IHDR" then return nil end
    local w, h = u32be(d, 17), u32be(d, 21)
    if w and h and w > 0 and h > 0 then return w, h end
    return nil
end

--- GIF: 逻辑屏幕描述符里的宽高 (小端)
local function parse_gif(d)
    local w, h = u16le(d, 7), u16le(d, 9)
    if w and h and w > 0 and h > 0 then return w, h end
    return nil
end

--- BMP: DIB 头里的宽高 (小端; 高可以为负, 表示自上而下)
local function parse_bmp(d)
    local w = u32le(d, 19)
    local h = u32le(d, 23)
    if not w or not h then return nil end
    if h > 0x7FFFFFFF then h = 0x100000000 - h end   -- 负高: 取绝对值
    if w > 0 and h > 0 then return w, h end
    return nil
end

--- WEBP: 三种子格式的宽高位置各不相同
local function parse_webp(d)
    local fourcc = d:sub(13, 16)

    if fourcc == "VP8 " then
        -- 帧标签(3) + 起始码 9D 01 2A(3) + 宽(2, 14 位) + 高(2, 14 位)
        if d:byte(24) ~= 0x9D or d:byte(25) ~= 0x01 or d:byte(26) ~= 0x2A then
            return nil
        end
        local w, h = u16le(d, 27), u16le(d, 29)
        if not w or not h then return nil end
        w, h = bit.band(w, 0x3FFF), bit.band(h, 0x3FFF)
        if w > 0 and h > 0 then return w, h end
        return nil
    elseif fourcc == "VP8L" then
        -- 签名 0x2F(1) + 打包位(4): 宽-1 占低 14 位, 高-1 占接下来的 14 位
        if d:byte(21) ~= 0x2F then return nil end
        local v = u32le(d, 22)
        if not v then return nil end
        local w = bit.band(v, 0x3FFF) + 1
        local h = bit.band(bit.rshift(v, 14), 0x3FFF) + 1
        if w > 1 and h > 1 then return w, h end
        return nil
    elseif fourcc == "VP8X" then
        -- 标志(1) + 保留(3) + 画布宽-1(3, 小端) + 画布高-1(3, 小端)
        local w, h = u24le(d, 25), u24le(d, 28)
        if w and h and w + 1 > 1 and h + 1 > 1 then return w + 1, h + 1 end
        return nil
    end
    return nil
end

----------------------------------------------------------------------------
-- 入口
----------------------------------------------------------------------------

--- 从已读入的一段字节里解析宽高 (测试用; 也便于复用已读缓冲)
--
-- 第三个返回值是**格式名** ("jpeg"/"png"/"gif"/"bmp"/"webp")。
-- 大图守卫要用它决定"这张图能不能缩放解码" (JPEG/WEBP 能, 其余不能),
-- 而格式本来就写在魔数里 —— 顺手带出来, 免得调用方为了知道格式再读一次文件。
-- 解析不出宽高时整体返回 nil (格式也就没有意义了)。
-- @return w, h, format 或 nil
function ImageSize.from_data(d)
    if not d or #d < 8 then return nil end

    local fmt, w, h
    local b1, b2 = d:byte(1, 2)
    if b1 == 0xFF and b2 == 0xD8 then
        fmt, w, h = "jpeg", parse_jpeg(d)
    elseif d:sub(1, 8) == "\137PNG\r\n\26\n" then
        fmt, w, h = "png", parse_png(d)
    elseif d:sub(1, 4) == "GIF8" then
        fmt, w, h = "gif", parse_gif(d)
    elseif d:sub(1, 2) == "BM" then
        fmt, w, h = "bmp", parse_bmp(d)
    elseif d:sub(1, 4) == "RIFF" and d:sub(9, 12) == "WEBP" then
        fmt, w, h = "webp", parse_webp(d)
    else
        return nil
    end
    if w and h then return w, h, fmt end
    return nil
end

--- 读文件头拿宽高
-- @return w, h, format 或 nil (打不开 / 不是已知格式 / 头被截断)
function ImageSize.from_file(path)
    if not path then return nil end
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read(ImageSize.MAX_PROBE)
    f:close()
    return ImageSize.from_data(data)
end

return ImageSize
