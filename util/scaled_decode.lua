-- util/scaled_decode.lua
-- 缩放解码后端: 让解码器**直接输出一张小图**, 而不是"先整图解出来再缩"。
--
-- 为什么需要它 (根因):
--   KOReader 解码一张图 = 一次分配 `w * h * 每像素字节数` 的 BlitBuffer
--   (base/ffi/pic.lua:341)。4000x3000 就是 34~48MB, 而 Kindle 只有 ~130MB 可用。
--   overcommit 下大块 calloc 会"成功", 等解码器写像素时内核才发现没内存 ->
--   OOM killer 直接 SIGKILL (crash.log 只有 Killed、没有 traceback, pcall 接不住)。
--   util/image_guard.lua 负责"发现图太大", 本模块负责"把它缩小着解出来"。
--
-- 关键点: 这里的缩小发生在**解码器内部** —— libjpeg-turbo 丢 DCT 系数、
--   libwebp 按目标尺寸分配输出缓冲。全程不存在"整图那么大的中间缓冲",
--   所以峰值内存直接降到缩放后的尺寸。
--
-- 覆盖的格式 (都有实测依据, 见 docs/07_性能优化指南.md):
--   JPEG -> TurboJPEG `tj3SetScalingFactor`  (1/2, 1/4, 1/8)
--   WEBP -> libwebp `WebPDecoderOptions.use_scaling` (任意目标尺寸)
-- **不覆盖** PNG/GIF/BMP: 没有可用的缩放接口 (lodepng 无缩放; libpng 行流式 API
--   的错误处理是 setjmp/longjmp, LuaJIT FFI 调不了; giflib 完全没有)。
--   这些格式由上层走"拒绝 + 提示"。
--
-- 安全契约 (最重要的一条):
--   **任何失败都必须返回 `nil, err`, 绝不抛异常、绝不退回整图解码。**
--   符号缺失 / 库加载失败 / 因子都放不下 / 解码出错 —— 一律 nil。
--   上层据此退化成"拒绝", 否则等于把 OOM 又请回来。
--   所以本模块的每个入口都用 pcall 包住 ffi 调用, 且对句柄/缓冲的释放
--   收在唯一的出口上。

local ffi = require("ffi")
local BB = require("ffi/blitbuffer")
local logger = require("util.logger")
local ImageGuard = require("util.image_guard")

local ScaledDecode = {}

--- 只考虑这些分母的因子 (1/2, 1/4, 1/8)。
--
-- **实测依据** (4000x3000 JPEG, 模拟器, 中位耗时):
--     1/1 -> 7.9ms     7/8 -> 21.6ms    3/4 -> 15.9ms    5/8 -> 12.6ms
--     1/2 ->  4.8ms    3/8 ->  6.9ms    1/4 ->  4.1ms    1/8 ->  3.5ms
--   只有 `1/2^n` 走 libjpeg-turbo 的快速缩放路径; 其余分数 (7/8, 3/4, 5/8, 3/8)
--   **比不缩放还慢**, 而且省的内存更少 —— 两头都亏, 没有理由选它们。
--   代价是分辨率粒度粗 (1/2 而不是 3/4), 但这些图本来就远超屏幕宽度
--   (Kindle PW5 宽 1236px, 而 4000px 的图缩到 1/2 仍有 2000px), 看不出来。
ScaledDecode.FAST_DENOMS = { [2] = true, [4] = true, [8] = true }

----------------------------------------------------------------------------
-- 库加载 (懒加载 + 失败缓存; 缺符号不能拖垮模块加载)
----------------------------------------------------------------------------

local turbojpeg_state        -- nil = 还没试; false = 试过不可用; 否则 = 库
local turbojpeg_err
local webp_state
local webp_err

local function load_turbojpeg()
    if turbojpeg_state ~= nil then
        return turbojpeg_state or nil, turbojpeg_err
    end
    turbojpeg_state = false

    -- 基础声明 (tjhandle / tj3Init / TJPARAM_* / TJPF_*) 由 KOReader 提供。
    -- 拿不到它, 下面的 cdef 会因为 tjhandle 未定义而失败 -> 我们安全地判定"不可用"。
    pcall(require, "ffi/turbojpeg_h")

    -- KOReader 的 turbojpeg_h.lua **没有**声明缩放相关的类型与函数 (只到 3.2 的基础 API),
    -- 所以自己补。类型名加前缀, 避免将来上游补上同名声明时 ffi.cdef 冲突。
    pcall(ffi.cdef, [[
        typedef struct { int num; int denom; } picayomi_tjscalingfactor;
        picayomi_tjscalingfactor *tj3GetScalingFactors(int *numScalingFactors);
        int tj3SetScalingFactor(tjhandle h, picayomi_tjscalingfactor sf);
    ]])

    local ok, lib = pcall(ffi.loadlib, "turbojpeg",
        "0.5.0", "turbojpeg", "0.4.0", "turbojpeg", "0.3.0", "turbojpeg")
    if not ok or lib == nil then
        turbojpeg_err = "libturbojpeg 不可用: " .. tostring(lib)
        return nil, turbojpeg_err
    end
    if lib.tj3GetScalingFactors == nil or lib.tj3SetScalingFactor == nil then
        turbojpeg_err = "libturbojpeg 缺少缩放解码符号 (tj3GetScalingFactors/tj3SetScalingFactor)"
        return nil, turbojpeg_err
    end
    turbojpeg_state = lib
    return lib
end

local function load_webp()
    if webp_state ~= nil then
        return webp_state or nil, webp_err
    end
    webp_state = false

    -- 核心 libwebp (不是 demux)。KOReader 只用 demux, 但 demux 依赖 core,
    -- 所以设备上一定存在 libwebp.7。
    -- 这里的结构体按 libwebp 的 `decode.h` 逐字声明。**注意 WebPDecBuffer 里的
    -- 匿名 union 必须带上 WebPYUVABuffer** —— 它比 WebPRGBABuffer 大得多
    -- (80 字节 vs 24 字节)。只声明 RGB 那个会让 `options` 落到错误的偏移上,
    -- 结果是"缩放参数被忽略" + 堆越界写 (实测直接崩溃)。这是踩过的坑。
    pcall(ffi.cdef, [[
        typedef struct {
            int width; int height; int has_alpha; int has_animation; int format;
            uint32_t pad[5];
        } picayomi_webp_features;
        typedef struct { uint8_t *rgba; int stride; size_t size; } picayomi_webp_rgba_buffer;
        typedef struct {
            uint8_t *y, *u, *v, *a;
            int y_stride; int u_stride, v_stride; int a_stride;
            size_t y_size; size_t u_size, v_size; size_t a_size;
        } picayomi_webp_yuva_buffer;
        typedef union {
            picayomi_webp_rgba_buffer RGBA;
            picayomi_webp_yuva_buffer YUVA;
        } picayomi_webp_dec_buffer_union;
        typedef struct {
            int colorspace; int width, height; int is_external_memory;
            picayomi_webp_dec_buffer_union u;
            uint32_t pad[4];
            uint8_t *private_memory;
        } picayomi_webp_dec_buffer;
        typedef struct {
            int bypass_filtering; int no_fancy_upsampling;
            int use_cropping; int crop_left, crop_top; int crop_width, crop_height;
            int use_scaling; int scaled_width, scaled_height;
            int use_threads; int dithering_strength; int flip; int alpha_dithering_strength;
            uint32_t pad[5];
        } picayomi_webp_decoder_options;
        typedef struct {
            picayomi_webp_features input;
            picayomi_webp_dec_buffer output;
            picayomi_webp_decoder_options options;
        } picayomi_webp_decoder_config;
        int WebPGetDecoderVersion(void);
        int WebPGetInfo(const uint8_t *data, size_t data_size, int *width, int *height);
        int WebPInitDecoderConfigInternal(picayomi_webp_decoder_config *, int);
        int WebPDecode(const uint8_t *data, size_t data_size, picayomi_webp_decoder_config *config);
        void WebPFreeDecBuffer(picayomi_webp_dec_buffer *buffer);
    ]])

    local ok, lib = pcall(ffi.loadlib, "webp", "7")
    if not ok or lib == nil then
        webp_err = "libwebp 不可用: " .. tostring(lib)
        return nil, webp_err
    end
    if lib.WebPDecode == nil or lib.WebPFreeDecBuffer == nil then
        webp_err = "libwebp 缺少核心解码符号 (WebPDecode/WebPFreeDecBuffer)"
        return nil, webp_err
    end
    webp_state = lib
    return lib
end

--- 本设备上缩放解码能力 (供上层/测试/诊断查询)
-- @return { jpeg = bool, webp = bool }
function ScaledDecode.available()
    return {
        jpeg = (select(1, load_turbojpeg()) ~= nil),
        webp = (select(1, load_webp()) ~= nil),
    }
end

--- 测试注入缝: 清掉"库已加载"的缓存, 让下次 decode 重新走加载流程。
--
-- 生产代码不调用它。存在的唯一理由: "动态库/符号缺失时必须退化成拒绝"是本模块
-- 最重要的安全契约, 而这条路径只在**首次加载**时走到 —— 不重置缓存就没法测
-- (见 test/scaled_decode.lua 里"把 ffi.loadlib 换成会失败的桩"那一节)。
function ScaledDecode._reset_backends()
    turbojpeg_state, turbojpeg_err = nil, nil
    webp_state, webp_err = nil, nil
end

----------------------------------------------------------------------------
-- JPEG: 因子选择 (纯逻辑, 可离线测试)
----------------------------------------------------------------------------

--- TurboJPEG 的输出尺寸公式 (与库里的 tjscaled 一致: 向上取整)
local function tjscaled(dim, num, denom)
    return math.floor((dim * num + denom - 1) / denom)
end
ScaledDecode.tjscaled = tjscaled

--- 从因子列表里挑一个"输出不超过目标、且走快速路径"的因子。
--
-- 规则: 只看 `1/2^n` (见 FAST_DENOMS 的实测依据), 在其中取**输出面积最大**的
-- (即缩放最少的那个 —— 不要把图缩得比需要的更小)。
-- 一个都放不下就返回 nil (上层退化成拒绝)。
--
-- 特例: 目标本身就装得下原图时返回 1/1 (不缩放)。正常情况下守卫只会对
-- "超预算"的图调到这里 (target 一定小于原图), 但把这条兜住能让本函数成为
-- 全函数 —— 免得"目标比原图大"时莫名其妙地把图缩一半。
--
-- @param factors 列表: { {num=, denom=}, ... } (顺序无关)
-- @param jw, jh  原图尺寸
-- @param target_w, target_h  目标上界 (来自 util/image_guard 的 plan)
-- @return {num=, denom=, ow=, oh=} 或 nil
function ScaledDecode.pick_factor(factors, jw, jh, target_w, target_h)
    if not factors or not jw or not jh or not target_w or not target_h then return nil end
    if jw <= target_w and jh <= target_h then
        return { num = 1, denom = 1, ow = jw, oh = jh }
    end
    local best
    for i = 1, #factors do
        local f = factors[i]
        if f and f.num == 1 and ScaledDecode.FAST_DENOMS[f.denom] then
            local ow = tjscaled(jw, f.num, f.denom)
            local oh = tjscaled(jh, f.num, f.denom)
            if ow >= 1 and oh >= 1 and ow <= target_w and oh <= target_h then
                if not best or ow * oh > best.ow * best.oh then
                    best = { num = f.num, denom = f.denom, ow = ow, oh = oh }
                end
            end
        end
    end
    return best
end

----------------------------------------------------------------------------
-- 文件读取 (两个后端都需要"整块压缩数据")
----------------------------------------------------------------------------

--- 读入整个压缩文件。
--
-- 这是**独立于像素数的第二条内存通道**: TurboJPEG / libwebp 的整块 API 都需要
-- 一个连续缓冲, 没有流式入口。所以"几百 MB 的文件"光压缩数据就能打爆内存 ——
-- 这一条由 util/image_guard 的 FILE_LIMIT 在**调用本模块之前**拦下。
-- 这里再兜一次底, 防止有别的调用方绕过守卫。
local function read_all(path)
    if not path then return nil, "没有路径" end
    local fh = io.open(path, "rb")
    if not fh then return nil, "打不开文件: " .. tostring(path) end
    local data = fh:read("*a")
    fh:close()
    if not data or #data == 0 then return nil, "文件为空" end
    if #data > ImageGuard.FILE_LIMIT then
        return nil, string.format("文件过大 (%d 字节 > %d)", #data, ImageGuard.FILE_LIMIT)
    end
    return data
end

--- 输出尺寸的兜底检查: 缩放解码的结果也必须在解码预算内。
-- (正常情况下 image_guard 给的目标已经保证这一点; 这里防"上层传错目标"。)
local function output_within_budget(ow, oh, budget)
    return ow >= 1 and oh >= 1
        and ow * oh * ImageGuard.BYTES_PER_PIXEL <= (budget or ImageGuard.DECODE_BUDGET)
end

----------------------------------------------------------------------------
-- JPEG 后端
----------------------------------------------------------------------------

--- 缩放解码 JPEG
-- @param path      文件路径
-- @param target_w, target_h  目标尺寸上界 (来自 image_guard)
-- @param color     true = RGB24, 否则灰度 BB8 (与 ffi/jpeg.lua 的 color 语义一致)
-- @return bb, w, h 或 nil, err
function ScaledDecode.decode_jpeg(path, target_w, target_h, color, budget)
    local lib, lerr = load_turbojpeg()
    if not lib then return nil, lerr end

    local data, derr = read_all(path)
    if not data then return nil, derr end

    local handle = lib.tj3Init(lib.TJINIT_DECOMPRESS)
    if handle == nil then return nil, "tj3Init 失败 (TurboJPEG 解压器句柄)" end

    -- 捕获 4 个返回值: pcall 会把内层函数的返回值一并带出来, 只接 2 个会串位。
    local called_ok, a, b, c = pcall(function()
        if lib.tj3DecompressHeader(handle,
            ffi.cast("const unsigned char*", data), #data) < 0 then
            return nil, "读 JPEG 头失败"
        end
        local jw = lib.tj3Get(handle, lib.TJPARAM_JPEGWIDTH)
        local jh = lib.tj3Get(handle, lib.TJPARAM_JPEGHEIGHT)

        -- 取库里真实支持的因子列表 (不硬编码, 不同版本可能不同)
        local n = ffi.new("int[1]")
        local raw = lib.tj3GetScalingFactors(n)
        if raw == nil then return nil, "tj3GetScalingFactors 返回空" end
        local factors = {}
        for i = 0, n[0] - 1 do
            factors[#factors + 1] = { num = raw[i].num, denom = raw[i].denom }
        end

        local f = ScaledDecode.pick_factor(factors, jw, jh, target_w, target_h)
        if not f then
            return nil, string.format(
                "没有可用的缩放因子 (原图 %dx%d, 目标 %dx%d)", jw, jh, target_w, target_h)
        end
        if not output_within_budget(f.ow, f.oh, budget) then
            return nil, string.format("缩放结果 %dx%d 仍超出解码预算", f.ow, f.oh)
        end

        local sf = ffi.new("picayomi_tjscalingfactor")
        sf.num, sf.denom = f.num, f.denom
        if lib.tj3SetScalingFactor(handle, sf) < 0 then
            return nil, string.format("tj3SetScalingFactor 拒绝 %d/%d", f.num, f.denom)
        end

        -- 输出缓冲**按缩放后的尺寸**分配 —— 这就是省内存的地方。
        local bb = BB.new(f.ow, f.oh, color and BB.TYPE_BBRGB24 or BB.TYPE_BB8)
        local pixfmt = color and lib.TJPF_RGB or lib.TJPF_GRAY
        local rc = lib.tj3Decompress8(handle,
            ffi.cast("unsigned char*", data), #data,
            ffi.cast("unsigned char*", bb.data), bb.stride, pixfmt)
        if rc < 0 then
            bb:free()
            return nil, "缩放解码失败 (tj3Decompress8 < 0)"
        end
        return bb, f.ow, f.oh
    end)

    -- 句柄的释放在**唯一出口**上, 成功/失败都走到这
    pcall(function() lib.tj3Destroy(handle) end)

    if not called_ok then
        return nil, "JPEG 缩放解码异常: " .. tostring(a)
    end
    if a == nil then return nil, b end      -- 内层返回 nil, err
    return a, b, c                          -- bb, w, h
end

----------------------------------------------------------------------------
-- WEBP 后端
----------------------------------------------------------------------------

-- libwebp 的解码器 ABI 版本 (decode.h: `WEBP_DECODER_ABI_VERSION 0x0210`)。
-- 这个值自 libwebp 0.5 起就是 2.x, 而 `WebPInitDecoderConfigInternal` 的版本
-- 检查发生在 memset **之前**, 所以即使版本不符也只会返回 0、不会写坏内存 ——
-- 我们能安全地据此判定"不可用"。
local WEBP_DECODER_ABI_VERSION = 0x0210

--- 缩放解码 WEBP
--
-- color=false 时将 RGBA 直接合成到白底灰度输出, 不复制第二份 RGBA。
-- 像素缓冲峰值由 8 字节/像素降为 5; 最终保留 1 字节/像素。
-- 不传 color 保留历史彩色接口行为。
-- @return bb, w, h 或 nil, err
function ScaledDecode.decode_webp(path, target_w, target_h, color, budget)
    local lib, lerr = load_webp()
    if not lib then return nil, lerr end
    if not target_w or not target_h or target_w < 1 or target_h < 1 then
        return nil, "目标尺寸非法"
    end
    if not output_within_budget(target_w, target_h, budget) then
        return nil, string.format("目标 %dx%d 超出解码预算", target_w, target_h)
    end

    local data, derr = read_all(path)
    if not data then return nil, derr end

    local cfg = ffi.new("picayomi_webp_decoder_config")
    -- 版本检查失败会返回 0, 且**不会**碰 cfg 的内存 (检查在 memset 之前)。
    if lib.WebPInitDecoderConfigInternal(cfg, WEBP_DECODER_ABI_VERSION) == 0 then
        return nil, string.format("libwebp ABI 不兼容 (需要 0x%04x)", WEBP_DECODER_ABI_VERSION)
    end

    -- 关键: is_external_memory 保持 0 —— 让 libwebp 自己按**缩放后**的尺寸分配
    -- 输出缓冲 (buffer_dec.c:201-220)。设成非 0 就等于要我们提供整图缓冲,
    -- 那正是要避免的。
    cfg.output.colorspace = 1                  -- MODE_RGBA
    cfg.options.use_scaling = 1
    cfg.options.scaled_width = target_w
    cfg.options.scaled_height = target_h

    local output_bb
    local called_ok, a, b, c = pcall(function()
        local st = lib.WebPDecode(ffi.cast("const uint8_t*", data), #data, cfg)
        if st ~= 0 then
            -- 状态码非 0 也可能已经分配了缓冲 (libwebp 的约定: 无论如何都要释放)
            pcall(function() lib.WebPFreeDecBuffer(cfg.output) end)
            return nil, "WebPDecode 状态码 " .. tostring(st)
        end

        local ow, oh = cfg.output.width, cfg.output.height
        if not output_within_budget(ow, oh, budget) then
            pcall(function() lib.WebPFreeDecBuffer(cfg.output) end)
            return nil, string.format("解码结果 %dx%d 超出解码预算", ow, oh)
        end

        -- 拷贝进一个**自有**的 BlitBuffer, 然后立刻把 libwebp 的缓冲还回去。
        -- 这样页对象的生命周期与其它页完全一样 (releaseSub 里 bb:free() 就够了),
        -- 不必新增"谁负责调 WebPFreeDecBuffer"的释放路径。
        -- 彩色复制 RGBA; 黑白直接合成到 BB8, 两者均立即释放 libwebp 缓冲。
        local src = BB.new(ow, oh, BB.TYPE_BBRGB32,
            cfg.output.u.RGBA.rgba, tonumber(cfg.output.u.RGBA.stride))
        local bb
        if color == false then
            bb = BB.new(ow, oh, BB.TYPE_BB8)
            output_bb = bb
            bb:fill(BB.COLOR_WHITE)
            bb:alphablitFrom(src, 0, 0, 0, 0, ow, oh)
        else
            bb = src:copy()
            output_bb = bb
        end
        lib.WebPFreeDecBuffer(cfg.output)
        return bb, ow, oh
    end)

    if not called_ok then
        if output_bb then output_bb:free() end
        -- 异常路径也要把可能已分配的缓冲还回去 (再还一次是安全的)
        pcall(function() lib.WebPFreeDecBuffer(cfg.output) end)
        return nil, "WEBP 缩放解码异常: " .. tostring(a)
    end
    if a == nil then return nil, b end
    return a, b, c
end

----------------------------------------------------------------------------
-- Display-resolution strips. No memory-dependent scaling is permitted here.
-- JPEG uses a DCT factor at or above display resolution; WebP targets display
-- pixels directly. Without display_zoom these APIs retain original resolution.
-- JPEG starts at x=0 (valid for every MCU width); WebP top is even-aligned.
-- These APIs crop during decoding, before allocating the output image.
----------------------------------------------------------------------------

-- Progressive JPEG retains quantized 8x8 DCT blocks for every component.
-- Calculate padded MCU/component storage (16-bit coefficients), rather than
-- assuming eight bytes per pixel for grayscale and chroma-subsampled images.
-- Native MAXMEMORY remains the final limit even for unusual JPEG layouts.
-- libjpeg-turbo/src/jdcoefct.c: request_virt_barray in jinit_d_coef_controller.
function ScaledDecode.jpeg_workspace(width,height,subsampling,colorspace)
    local base=width*256+1024*1024
    local sampling=({[0]={1,1},[1]={2,1},[2]={2,2},[3]={1,1},
        [4]={1,2},[5]={4,1},[6]={1,4},[7]={4,2},[8]={2,4}})[subsampling]
    if not sampling then return base+math.ceil(width/16)*16*math.ceil(height/16)*16*8 end
    local horizontal,vertical=sampling[1],sampling[2]
    local blocks=horizontal*vertical
    if subsampling==3 then blocks=1
    elseif colorspace==3 or colorspace==4 then blocks=2*blocks+2
    else blocks=blocks+2 end
    local mcus=math.ceil(width/(8*horizontal))*math.ceil(height/(8*vertical))
    return base+mcus*blocks*64*2
end

function ScaledDecode.region_input(path, budget)
    local size=require("libs/libkoreader-lfs").attributes(path,"size")
    if not size then return nil,"read_failed" end
    if size>ImageGuard.FILE_LIMIT or size*2>=(budget or 0) then return nil,"memory_budget" end
    return read_all(path)
end

function ScaledDecode.decode_region(path, format, y, height, color, budget, display_zoom, input)
    local output, handle, lib, cfg, raw_height
    local ok, result, origin, source_height = pcall(function()
        budget = tonumber(budget) or 0
        local size = require("libs/libkoreader-lfs").attributes(path, "size")
        -- A retained input is already resident when the caller samples free
        -- memory. Only a new read needs room for its temporary input copies.
        local input_bytes = input and 0 or (size or 0) * 2
        if not size or size > ImageGuard.FILE_LIMIT or input_bytes >= budget then
            return nil, "memory_budget"
        end
        local data, err = input
        if data and #data~=size then return nil,"read_failed" end
        if not data then data,err=read_all(path) end
        if not data then return nil, err end
        local width, full_h, workspace
        if format == "jpeg" then
            lib, err = load_turbojpeg()
            if not lib then return nil, err end
            pcall(ffi.cdef, [[
                typedef struct { int x, y, w, h; } picayomi_tjregion;
                int tj3SetCroppingRegion(tjhandle, picayomi_tjregion);
            ]])
            -- Resolve before creating native resources; old libraries fail safely.
            local crop = lib.tj3SetCroppingRegion
            handle = lib.tj3Init(lib.TJINIT_DECOMPRESS)
            if handle == nil then handle=nil; return nil, "JPEG init failed" end
            if lib.tj3DecompressHeader(handle, data, #data) < 0 then return nil, "corrupt_image" end
            width, full_h = lib.tj3Get(handle, lib.TJPARAM_JPEGWIDTH), lib.tj3Get(handle, lib.TJPARAM_JPEGHEIGHT)
            if lib.tj3Get(handle, lib.TJPARAM_LOSSLESS) ~= 0 then return nil, "unsupported JPEG coding" end
            -- Progressive JPEG retains coefficients for the whole image even
            -- when cropped. Enforce the codec's own limit before decompressing.
            workspace = width * 256 + 1024 * 1024
            if lib.tj3Get(handle, lib.TJPARAM_PROGRESSIVE) ~= 0 then
                workspace = ScaledDecode.jpeg_workspace(width,full_h,lib.tj3Get(handle,lib.TJPARAM_SUBSAMP),
                    lib.tj3Get(handle,lib.TJPARAM_COLORSPACE))
            end
            y = math.max(0, math.floor(y))
            height = math.min(math.ceil(height), full_h-y)
            if height < 1 or width < 1 then return nil, "invalid region" end
            local denom=1
            for _,d in ipairs({2,4,8}) do
                if display_zoom and 1/d>=display_zoom then denom=d end
            end
            local bottom=math.min(full_h,y+height)
            y=math.floor(y/denom);height=math.ceil(bottom/denom)-y
            width=math.ceil(width/denom)
            if lib.tj3SetScalingFactor(handle,ffi.new("picayomi_tjscalingfactor",{1,denom}))<0 then
                return nil,"JPEG scale failed"
            end
            raw_height=height*denom
            local bytes = width * height * (color and 3 or 1)
            if input_bytes + bytes + workspace > budget then return nil, "memory_budget" end
            local limit = math.floor((budget-input_bytes-bytes)/1048576)
            if limit < 1 or lib.tj3Set(handle, lib.TJPARAM_MAXMEMORY, limit) < 0 then return nil, "memory_budget" end
            if crop(handle, ffi.new("picayomi_tjregion", {0,y,width,height})) < 0 then
                return nil, "JPEG crop failed"
            end
            output = BB.new(width,height,color and BB.TYPE_BBRGB24 or BB.TYPE_BB8)
            if lib.tj3Decompress8(handle,data,#data,ffi.cast("unsigned char*",output.data),output.stride,
                    color and lib.TJPF_RGB or lib.TJPF_GRAY) < 0 then
                local message=ffi.string(lib.tj3GetErrorStr(handle)):lower()
                return nil, message:find("memory",1,true) and "memory_budget" or "corrupt_image"
            end
            y=y*denom
        elseif format == "webp" then
            lib, err = load_webp()
            if not lib then return nil, err end
            cfg = ffi.new("picayomi_webp_decoder_config")
            if lib.WebPInitDecoderConfigInternal(cfg,WEBP_DECODER_ABI_VERSION)==0 then
                cfg=nil; return nil, "WebP ABI unavailable"
            end
            local dims=ffi.new("int[2]")
            if lib.WebPGetInfo(data,#data,dims,dims+1)==0 then return nil,"corrupt_image" end
            width,full_h=tonumber(dims[0]),tonumber(dims[1])
            local bottom=math.min(full_h,math.ceil(y+height))
            y=math.max(0,math.floor(y/2)*2);height=bottom-y
            if height<1 then return nil,"invalid region" end
            -- VP8L and alpha can retain a full-image intermediate. Budget that
            -- separately; cropping bounds output, not every internal allocation.
            local lossless=data:find("VP8L",1,true)~=nil
            local alpha=lossless or data:find("ALPH",1,true)~=nil
            workspace=width*256+1024*1024
            if lossless then workspace=workspace+width*full_h*8 end
            if alpha then workspace=workspace+width*full_h*2 end
            raw_height=height
            local zoom=math.min(1,display_zoom or 1)
            local ow,oh=math.ceil(width*zoom),math.ceil(height*zoom)
            local bytes=ow*oh*(color and (alpha and 8 or 3) or (alpha and 5 or 4))
            if input_bytes+bytes+workspace>budget then return nil,"memory_budget" end
            cfg.output.colorspace=alpha and 1 or 0 -- RGBA only when compositing is needed
            if color and not alpha then
                -- Decode directly into the owned result, avoiding a second
                -- native output allocation and a full strip copy.
                output=BB.new(ow,oh,BB.TYPE_BBRGB24)
                cfg.output.is_external_memory=1
                cfg.output.u.RGBA.rgba=ffi.cast("uint8_t*",output.data)
                cfg.output.u.RGBA.stride=output.stride
                cfg.output.u.RGBA.size=output.stride*oh
            end
            cfg.options.use_cropping=1
            cfg.options.crop_left=0;cfg.options.crop_top=y
            cfg.options.crop_width=width;cfg.options.crop_height=height
            if zoom<1 then
                cfg.options.use_scaling=1
                cfg.options.scaled_width=ow;cfg.options.scaled_height=oh
            end
            local status=lib.WebPDecode(data,#data,cfg)
            if status~=0 then return nil,status==1 and "memory_budget" or "corrupt_image" end
            width,height=ow,oh
            if not output then
                local src=BB.new(width,height,alpha and BB.TYPE_BBRGB32 or BB.TYPE_BBRGB24,
                    cfg.output.u.RGBA.rgba,tonumber(cfg.output.u.RGBA.stride))
                output=BB.new(width,height,color and BB.TYPE_BBRGB32 or BB.TYPE_BB8)
                output:fill(BB.COLOR_WHITE)
                output:alphablitFrom(src,0,0,0,0,width,height)
                src:free()
            end
        else
            return nil,"unsupported region format"
        end
        return output,y,raw_height or height
    end)
    if handle then pcall(function() lib.tj3Destroy(handle) end) end
    if cfg then pcall(function() lib.WebPFreeDecBuffer(cfg.output) end) end
    if not ok or not result then
        if output then output:free() end
        return nil, not ok and tostring(result):lower():find("allocat",1,true) and "memory_budget" or (ok and origin or tostring(result))
    end
    return result,origin,source_height
end

----------------------------------------------------------------------------
-- 统一入口
----------------------------------------------------------------------------

--- 按格式缩放解码
-- @param path  文件路径
-- @param format "jpeg" / "webp" (大小写与点号都容忍)
-- @param target_w, target_h  目标尺寸上界
-- @param color  false = 灰度; true = JPEG RGB24 / WebP RGBA
-- @return bb, w, h 或 nil, err
function ScaledDecode.decode(path, format, target_w, target_h, color, budget)
    local fmt = ImageGuard.normalize_format(format)
    if fmt == "jpeg" then
        return ScaledDecode.decode_jpeg(path, target_w, target_h, color, budget)
    elseif fmt == "webp" then
        return ScaledDecode.decode_webp(path, target_w, target_h, color, budget)
    end
    return nil, "不支持缩放解码的格式: " .. tostring(format)
end

--- 记一条日志 (供上层在退化时说明原因, 避免"静默降级")
function ScaledDecode.log_unavailable(path, err)
    logger.warn("Picayomi ScaledDecode: " .. tostring(path) .. " 缩放解码不可用: " .. tostring(err))
end

return ScaledDecode
