-- util/image_guard.lua
-- 大图守卫: 在**解码之前**决定一张图该怎么处理。
--
-- 为什么必须有这个模块 (根因):
--   KOReader 解码一张图 = 一次分配 `w * h * 每像素字节数` 的 BlitBuffer
--   (base/ffi/pic.lua:341 `BB.new(re.width, re.height, bbtype, re.data)`,
--    BBRGB32 的 getBytesPerPixel()==4)。**内存只跟像素数有关, 跟文件大小无关**:
--
--       2000x2400  -> 19.2 MB
--       4000x3000  -> 48.0 MB
--       8000x8000  -> 256  MB
--
--   而 Kindle PW5 可用内存只有 ~130MB。更糟的是 Linux 默认 overcommit: 大块
--   calloc **会返回成功**, 等解码器真去写像素时内核才发现没内存 —— 于是
--   OOM killer 直接 SIGKILL。真机 crash.log 里"只有 Killed、没有 traceback"
--   就是这个签名, pcall 接不住 (blitbuffer.lua:2611 的 assert 在 overcommit
--   下根本不会触发)。KOReader 与本插件此前都没有任何尺寸守卫。
--
-- 第二条内存通道 (独立于像素数): base/ffi/jpeg.lua:31 会 `fh:read("*a")` 把
--   **整个压缩文件**读成一个 Lua 字符串。所以"几百 MB 的文件"光压缩数据就
--   几百 MB —— 即使它的像素数并不大。
--
-- 职责边界: **纯决策 —— 无 ffi、无 IO、不解码**。输入是"已经知道的事实"
-- (宽高 / 格式 / 文件大小), 输出是"下一步该干什么"。真正的缩放解码在
-- util/scaled_decode.lua, 接入渲染链在 ui/stream_reader.lua。
-- 分开的好处: 阈值与策略可以离线、确定性地测试 (见 test/image_guard.lua),
-- 不需要模拟器也不需要真实大图。

local ImageGuard = {}

----------------------------------------------------------------------------
-- 阈值 (模块字段, 测试可改小)
----------------------------------------------------------------------------

--- 默认工作预算, 不是 Kindle 的最大图片尺寸或硬件上限。
--
-- 32MB 的来历: Kindle PW5 可用内存 ~130MB, 而一页解码图之外还要留出
-- KOReader 自身的控件树 / 前后页缓存 / fork 子进程。32MB 约为可用量的 1/4,
-- 留足余量。超过就缩放解码 (能缩的格式) 或拒绝。
ImageGuard.DECODE_BUDGET = 32 * 1024 * 1024

--- 文件上限: 压缩数据本身的字节数上限。
--
-- 与 DECODE_BUDGET 是**两个独立维度**: 前者管"解出来的像素缓冲", 后者管
-- "读进来的压缩字节"。一张 40000x40000 的图可能只压缩到几 MB (像素数炸),
-- 一张噪声图则可能压缩后仍很大 (压缩数据炸) —— 两道闸都要有。
ImageGuard.FILE_LIMIT = 32 * 1024 * 1024

--- 每像素字节数。与 pic.lua 解出的 BB.TYPE_BBRGB32 一致
-- (base/ffi/blitbuffer.lua:756 `getBytesPerPixel() return 4`)。
ImageGuard.BYTES_PER_PIXEL = 4

-- libpng simplified API 直接写入最终的灰度/RGB 缓冲, 从文件流式读取。
-- 除输出外给行转换、zlib、色彩转换表预留空间; 这是工作预算而非设备硬上限。
function ImageGuard.png_peak_bytes(w, h, color)
    return w * h * (color and 3 or 1) + w * 32 + 1024 * 1024
end

----------------------------------------------------------------------------
-- 格式能力
----------------------------------------------------------------------------

--- 能缩放解码的格式 (依据见 util/scaled_decode.lua 的实测记录):
--   JPEG -> TurboJPEG `tj3SetScalingFactor` (1/1 .. 1/8 的离散因子)
--   WEBP -> 核心 libwebp `WebPDecoderOptions.use_scaling` (任意目标尺寸)
--
-- **不能缩放的**:
--   PNG -> lodepng 无缩放接口; libpng 的行流式 API 其错误处理是
--          setjmp/longjmp, LuaJIT FFI 调不了 (要加 C shim, 本插件是纯 Lua)
--   GIF -> giflib 完全没有缩放接口
--   BMP -> 无
--   MuPDF 万能路径也不成立: image.c:598-601 明确 l2factor 只对 JPEG 生效。
-- PNG 若 libpng simplified API 可用, 则按灰度/RGB 输出与行缓冲单独预算。
-- 这仍是全分辨率输出, 不是缩放接口; 真正超出该预算时保留拒绝保护。
local SCALABLE = { jpeg = true, webp = true }

--- 把各种写法的格式名归一化到 "jpeg"/"png"/"webp"/"gif"/"bmp"
-- 接受 "jpg" / "JPEG" / ".png" 等; 无法识别返回 nil。
local function normalize_format(fmt)
    if type(fmt) ~= "string" or fmt == "" then return nil end
    local f = fmt:lower()
    if f:sub(1, 1) == "." then f = f:sub(2) end
    if f == "jpg" or f == "jpe" then f = "jpeg" end
    return f
end

ImageGuard.normalize_format = normalize_format

--- 该格式能否缩放解码 (供上层/测试查询)
function ImageGuard.can_scale(format)
    local f = normalize_format(format)
    return (f ~= nil and SCALABLE[f] == true)
end

----------------------------------------------------------------------------
-- 缩放尺寸计算
----------------------------------------------------------------------------

--- 在保持宽高比的前提下, 把 w*h 压进预算, 返回目标宽高。
--
-- 用**线性**缩放因子 sqrt(allowed_area / (w*h)) —— 因为字节数随面积增长,
-- 而面积随线性因子的平方增长。取 floor 保证结果**不超过**预算
-- (宁可多缩一个像素, 也绝不能超)。下限 1x1: 畸形文件头声称十亿像素时
-- 也不能算出 0 (0 会被上层当成"尺寸无效")。
--
-- 注意: 这是**通用**目标尺寸, 不代表后端一定能精确做到。
-- JPEG 只能取离散因子, 由 scaled_decode 挑"输出不超过本目标"的最大因子;
-- 若连最小因子都超 (例如 1/8 仍超预算), 后端返回失败, 上层退化成拒绝。
-- @param budget: 字节预算 (默认 DECODE_BUDGET)
-- @return target_w, target_h
function ImageGuard.fit_dimensions(w, h, budget)
    local target_bytes = budget or ImageGuard.DECODE_BUDGET
    local allowed_area = target_bytes / ImageGuard.BYTES_PER_PIXEL
    local area = w * h
    if area <= allowed_area then return w, h end

    local scale = math.sqrt(allowed_area / area)
    local tw = math.max(1, math.floor(w * scale))
    local th = math.max(1, math.floor(h * scale))
    -- floor 在数学上已保证 tw*th <= allowed_area, 这里只兜浮点误差
    while tw * th > allowed_area and (tw > 1 or th > 1) do
        if tw >= th then tw = tw - 1 else th = th - 1 end
    end
    return tw, th
end

----------------------------------------------------------------------------
-- 屏幕够用尺寸 (画质/耗时)
----------------------------------------------------------------------------

--- 解码结果至少要覆盖屏幕的百分之多少 (允许 5% 的轻微放大)
--
-- 为什么允许略小于屏幕: JPEG 的缩放因子是离散的 (1/2, 1/4, 1/8)。
-- 2400x3200 的图在 1236x1648 的屏上, 1/2 出来 1200x1600 —— 差 3%,
-- 画的时候放大 3% 肉眼看不出来, 但解码量只有原来的 1/4。
-- 要求 100% 覆盖会把这一档直接排除掉, 等于白丢一半收益。
ImageGuard.DISPLAY_COVERAGE = 0.95

--- 只用这几档分母 (与 util/scaled_decode 的 FAST_DENOMS 一致)。
-- 注意是 2/4/8, **不是** 2/4/6/8 —— 只有 1/2^n 走 libjpeg-turbo 的快速路径,
-- 1/6 这种既慢又省不了多少 (见 util/scaled_decode.lua 的实测记录)。
ImageGuard.DENOMS = { 2, 4, 8 }

--- 按"最终要画到多大"算一个够用的解码尺寸
--
-- 一页最终只会被画到屏幕上, 所以解码分辨率只要不低于"画出来的尺寸",
-- 多出来的像素就是白解的 (2400x3200 的图在 1236x1648 的屏上, 1/2 就够)。
--
-- **宽度是硬约束**: 用户可能把缩放模式从"整页"切成"适配宽度", 那时显示宽度
-- 就是屏宽。所以要求解码后的宽度 >= min(原图宽, 屏宽) * 0.95 —— 高度按比例
-- 跟着走, 不用单独判 (两者同比例缩放)。
-- 反过来, 长条图 (720x3200) 在"整页"下只画 371 宽, 但切到"适配宽度"要 1236 宽,
-- 这种就不缩 (1/2 = 360 差太远), 宁可多解一点。
--
-- 在 1/2, 1/4, 1/8 里取**还能覆盖屏宽的最小一档**; 一档都不够 (图本来就不大,
-- 或者屏幕比图还大) 就返回 nil, 由调用方按原图解码。
--
-- 这条与"解码预算"是**两条独立的理由**: 预算是"解不下会 OOM", 这里是
-- "解得下但没必要"。两者都只是上界, 上层取更严的那个。
--
-- @return { w=, h=, denom= } 或 nil
function ImageGuard.display_target(w, h, display_w, display_h, coverage)
    if type(w) ~= "number" or type(h) ~= "number" or w <= 0 or h <= 0 then return nil end
    if type(display_w) ~= "number" or type(display_h) ~= "number"
        or display_w <= 0 or display_h <= 0 then
        return nil
    end

    -- 图本来就装得进屏幕 (宽高都不超) -> 没有可省的
    if w <= display_w and h <= display_h then return nil end

    coverage = coverage or ImageGuard.DISPLAY_COVERAGE
    -- 宽度是硬约束 (见上面的说明); 高度同比例, 不必单独判
    local need_w = math.min(w, display_w) * coverage

    local best
    for _i, denom in ipairs(ImageGuard.DENOMS) do
        local tw, th = math.ceil(w / denom), math.ceil(h / denom)
        if tw >= need_w then
            best = { w = tw, h = th, denom = denom }
        end
    end
    return best
end

----------------------------------------------------------------------------
-- 入口
----------------------------------------------------------------------------

----------------------------------------------------------------------------
-- 超长图识别 (埋点用)
----------------------------------------------------------------------------

--- "超长图"判据: 一张图比屏幕高好几倍, 或高宽比极端
--
-- 为什么单独判: 这类图**不会崩** (JPEG/WEBP 会缩放解码, PNG/GIF 会拒绝),
-- 但按宽度铺满后等于把 400x6000 拉到 1236 宽 —— 明显糊。它很罕见
-- (源 A 有些韩漫一话就是一张 800x12000), 用户"主动找很难", 所以命中时留一行
-- 日志 + Diag, 事后能从日志里定位到具体哪一话哪一页。
--
-- 阈值: 条漫切片 720x3008 (h/w=4.18, 屏幕 1648 高) 不该命中; 单张整话
-- 800x12000 (h/w=15, 屏幕 7.3 倍) 命中。
ImageGuard.ULTRA_LONG_RATIO = 10          -- h/w >= 10
ImageGuard.ULTRA_LONG_SCREEN_MULT = 4     -- h >= 屏幕高 x4

--- 这张图算不算"超长图"
-- @param display_w, display_h 屏幕尺寸 (可缺省: 只按长宽比判)
function ImageGuard.is_ultra_long(w, h, display_w, display_h)
    if type(w) ~= "number" or type(h) ~= "number" or w <= 0 or h <= 0 then
        return false
    end
    if h / w >= ImageGuard.ULTRA_LONG_RATIO then return true end
    if type(display_h) == "number" and display_h > 0
        and h >= display_h * ImageGuard.ULTRA_LONG_SCREEN_MULT then
        return true
    end
    return false
end

--- 决定一张图该怎么解码。
--
-- 判定顺序 (先便宜后昂贵, 且**每一道闸都不依赖解码**):
--   1. 文件超上限            -> refuse (file_too_large)
--   2. 宽高未知              -> full   (dim_unknown; 只靠文件大小闸, 已经过 1)
--   3. 解码字节 <= 预算      -> full   (ok)
--      但若给了屏幕尺寸且 1/2 解码就够显示 -> scaled (downscale_for_display)
--   4. 超预算 + 可缩放格式   -> scaled (ok, 带 target_w/target_h)
--   5. 超预算 + 不可缩放格式 -> refuse (format_unsupported)
--
-- @param w, h       图片像素尺寸 (文件头解析失败时可为 nil)
-- @param format     格式名 ("jpeg"/"png"/"webp"/"gif"/"bmp"; 大小写/带点都行; 可为 nil)
-- @param file_size  压缩文件字节数 (未知时可为 nil)
-- @param opts       可选; { display_w=, display_h= } 屏幕尺寸 (给了才会按"够显示"降分辨率)
--                   { budget=字节 } 本次可用预算 (缺省 DECODE_BUDGET; 上层按可用内存下调)
--                   { decode_factor=倍数 } 该解码路径的额外复制 (webp 的整帧 copy = 2)
-- opts.native_png 确认 libpng 可用; opts.color 决定该路径的输出通道数。
-- PNG 的 need_bytes 包含最终输出、行转换及工作缓冲预留。
-- @return table:
--   action   = "full" | "scaled" | "png" | "refuse"
--   reason   = "ok" | "file_too_large" | "dim_unknown" | "format_unsupported"
--   target_w, target_h  仅 action=="scaled" 时有 (缩放目标尺寸, 上界)
--   format   归一化后的格式名 ("jpeg"/"png"/... ; 识别不出为 nil)
--   bytes    整图解码的预估字节数 (w,h 已知时)
--   w, h, file_size      回显入参, 便于上层拼提示文案
function ImageGuard.plan(w, h, format, file_size, opts)
    local out = { w = w, h = h, file_size = file_size, format = normalize_format(format) }

    -- 入参可能来自"读文件头失败"的上层, 类型不保证是数字 —— 一律当未知处理,
    -- 绝不因为脏数据抛异常 (本方法在绘制链的调用路径上)。
    local has_dims = type(w) == "number" and type(h) == "number" and w > 0 and h > 0
    if has_dims then out.bytes = w * h * ImageGuard.BYTES_PER_PIXEL end

    -- 预算可以按"这台设备此刻还剩多少内存"下调 (见 ui/stream_reader.lua 的
    -- decode_budget)。固定 32MB 是健康设备的上限; 只剩 40MB 可用时再解一张
    -- 32MB 的图, 下一次分配就会失败 —— 而 blitbuffer 的分配失败是 **assert**,
    -- 直接带走整个 KOReader (crash.log 2026-10-18 03:57:09)。
    local budget = (opts and tonumber(opts.budget)) or ImageGuard.DECODE_BUDGET
    budget = math.max(0, budget)
    out.budget = budget

    -- 有些解码路径会**再复制一份**整帧 (webp 的 getFrameImage 默认 no_copy=false)。
    -- 这时真正的峰值是 2 倍, 不把它算进来就会在"看着够"的时候失败。
    local factor = (opts and tonumber(opts.decode_factor)) or 1
    if factor < 1 then factor = 1 end
    -- RGBA 解码输出与最终 BB8 同时存在, 至少需要 5 字节/像素。
    if out.format == "webp" and opts and opts.grayscale_webp then
        factor = math.max(factor, 1.25)
    end
    out.need_bytes = out.bytes and (out.bytes * factor) or nil

    -- 1. 文件大小闸: 独立于像素数的内存通道 (压缩数据本身)
    if type(file_size) == "number" and file_size > ImageGuard.FILE_LIMIT then
        out.action = "refuse"
        out.reason = "file_too_large"
        return out
    end

    -- 仅在调用方确认 libpng simplified API 可用时选择此路径。
    -- PNG 不再套用 RGB32 的面积估算, 也不需要先整图 RGB 解码再转灰度。
    if out.format == "png" and opts and opts.native_png then
        if not has_dims then
            out.action, out.reason = "refuse", "dim_unknown"
            return out
        end
        out.need_bytes = ImageGuard.png_peak_bytes(w, h, opts.color)
            + w * h * (opts.color and 3 or 1) * (factor - 1)
        out.action = out.need_bytes <= budget and "png" or "refuse"
        out.reason = out.action == "png" and "ok" or "memory_budget"
        return out
    end

    if budget < ImageGuard.BYTES_PER_PIXEL * factor then
        out.action, out.reason = "refuse", "memory_budget"
        return out
    end

    -- 2. 宽高未知: 算不出解码字节数, 无法判断该不该缩。已经过了文件大小闸,
    --    就按现状整图解码 (绝不因为"读不到尺寸"而拒绝正常图片)。
    --    真正危险的文件 (压缩数据就几百 MB) 已在第 1 步拦下。
    if not has_dims then
        out.action = "full"
        out.reason = "dim_unknown"
        return out
    end

    -- 3. 在预算内: 默认整图解码 —— 但如果这一页最终只画到屏幕上, 按 1/2 解码
    --    就已经够用, 再解全图只是白花时间与内存 (见 display_target 的说明)。
    if out.need_bytes <= budget then
        local display = opts and ImageGuard.display_target(w, h,
            opts.display_w, opts.display_h, opts.preserve_quality and 1 or nil)
        if display and ImageGuard.can_scale(format) then
            out.action = "scaled"
            out.reason = "downscale_for_display"
            out.target_w = display.w
            out.target_h = display.h
            out.scale_denom = display.denom
            return out
        end
        -- 黑白 WebP 统一走自有解码路径, 避免上游保留两份 RGBA。
        if out.format == "webp" and opts and opts.grayscale_webp then
            out.action, out.reason = "scaled", "grayscale"
            out.target_w, out.target_h = w, h
            return out
        end
        out.action = "full"
        out.reason = "ok"
        return out
    end

    -- Reading must never silently trade detail for a smaller allocation.
    if opts and opts.preserve_quality then
        out.action, out.reason = "refuse", "memory_budget"
        return out
    end

    -- 4/5. 超预算: 能缩就缩, 不能缩就拒绝
    if ImageGuard.can_scale(format) then
        local tw, th = ImageGuard.fit_dimensions(w, h, budget / factor)
        -- 预算之外还有一条更松的理由: "屏幕够用"。两者都只是上界, 取更严的那个。
        local display = opts and ImageGuard.display_target(w, h,
            opts.display_w, opts.display_h, opts.preserve_quality and 1 or nil)
        if display then
            tw = math.min(tw, display.w)
            th = math.min(th, display.h)
        end
        out.action = "scaled"
        out.reason = "ok"
        out.target_w = tw
        out.target_h = th
        return out
    end

    out.action = "refuse"
    out.reason = "format_unsupported"
    return out
end

return ImageGuard
