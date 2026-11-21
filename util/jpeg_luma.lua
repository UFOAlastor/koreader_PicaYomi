-- Project an 8-bit progressive YCbCr 4:4:4 image onto its first component.
-- The AC scans already belong to a single component. Interleaved DC scans
-- need their Huffman symbols separated, but never a decoded coefficient plane.
-- Everything else (IDCT, crop, scale and progressive reconstruction) stays
-- with TurboJPEG. Unsupported layouts use the normal bounded decoder.
local ffi = require("ffi")
local bit = require("bit")
local floor = math.floor
local M = {}
local scratch = 256 * 1024

local function u16(data, pos)
    local a, b = data:byte(pos, pos + 1)
    return a * 256 + b
end

local function read_tables(data, pos, stop, tables)
    while pos < stop do
        local selector = data:byte(pos)
        assert(selector <= 3 or selector >= 16 and selector <= 19)
        local counts = pos + 1
        pos = pos + 17
        local lut = {}
        local code = 0
        for length = 1, 16 do
            local count = data:byte(counts + length - 1)
            assert(pos + count <= stop and code + count < 2 ^ length)
            if selector < 4 then
                for i = 0, count - 1 do
                    local category = data:byte(pos + i)
                    assert(category <= 11)
                    lut[2 ^ length + code + i] = category
                end
            end
            pos = pos + count
            code = (code + count) * 2
        end
        if selector < 4 then tables[selector] = lut end
    end
    assert(pos == stop)
end

local function project(data, width, height, output, capacity)
    local blocks = math.ceil(width / 8) * math.ceil(height / 8)
    assert(blocks <= 512 * 1024 and data:sub(1, 2) == "\255\216")
    local source = ffi.cast("const uint8_t *", data)
    local used = 0
    local function copy(start, size)
        assert(used + size <= capacity)
        ffi.copy(output + used, source + start - 1, size)
        used = used + size
    end
    local function write(byte)
        assert(used < capacity)
        output[used] = byte
        used = used + 1
    end
    local tables = {}
    local function write_dc(first, stop, selectors, refinement, block_count)
        local pos, remaining, value = first, 0, 0
        local function read_bit()
            if remaining == 0 then
                assert(pos < stop)
                value = source[pos - 1]
                pos = pos + 1
                if value == 255 then
                    assert(pos < stop and source[pos - 1] == 0)
                    pos = pos + 1
                end
                remaining = 8
            end
            remaining = remaining - 1
            return bit.band(bit.rshift(value, remaining), 1)
        end
        local buffer, count = 0, 0
        local function put(bits, length)
            buffer = buffer * 2 ^ length + bits
            count = count + length
            while count >= 8 do
                count = count - 8
                local byte = floor(buffer / 2 ^ count)
                write(byte)
                if byte == 255 then write(0) end
                buffer = buffer % 2 ^ count
            end
        end
        for _ = 1, block_count do
            for component = 1, 3 do
                if refinement then
                    local b = read_bit()
                    if component == 1 then put(b, 1) end
                else
                    local lut = selectors[component]
                    local code, length = 1, 0
                    repeat
                        code = 2 * code + read_bit()
                        length = length + 1
                    until lut[code] or length == 16
                    local category = assert(lut[code])
                    local amplitude = 0
                    for _ = 1, category do amplitude = 2 * amplitude + read_bit() end
                    if component == 1 then
                        put(code - 2 ^ length, length)
                        put(amplitude, category)
                    end
                end
            end
        end
        assert(pos == stop)
        if count > 0 then put(2 ^ (8 - count) - 1, 8 - count) end
    end

    -- In 4:4:4 each MCU contains one block per participating component.
    -- Dropping chroma preserves MCU counts, restart positions and DC resets.
    local interval = 0
    local function scan_end(first, selectors, refine)
        local remaining, restart = blocks, 0
        while true do
            local last = assert(data:find("\255[^%z]", first))
            local count = interval > 0 and math.min(interval, remaining) or remaining
            if selectors then write_dc(first, last, selectors, refine, count) end
            remaining = remaining - count
            local marker = data:byte(last + 1)
            if remaining == 0 then
                assert(marker < 208 or marker > 215)
                return last
            end
            assert(marker == 208 + restart)
            if selectors then copy(last, 2) end
            first, restart = last + 2, (restart + 1) % 8
        end
    end

    copy(1, 2)
    local pos, frame, scans, dc_seen = 3, false, 0, false
    local interleaved_passes = 0
    for _ = 1, 256 do
        assert(data:byte(pos) == 255)
        local marker = data:byte(pos + 1)
        if marker == 217 then
            assert(frame and dc_seen)
            copy(pos, 2)
            return ffi.string(output, used)
        end
        local length = u16(data, pos + 2)
        local first, stop = pos + 4, pos + 2 + length
        assert(length >= 2 and stop <= #data + 1)
        if marker == 194 then
            assert(not frame and length == 17 and data:byte(first) == 8)
            assert(u16(data, first+1) == height and u16(data, first+3) == width and data:byte(first+5) == 3)
            for c = 1, 3 do
                local id, sampling = data:byte(first+6+(c-1)*3, first+7+(c-1)*3)
                assert(id == c and sampling == 17)
            end
            copy(pos, 2); write(0); write(11)
            copy(first, 5); write(1); copy(first+6, 3)
            frame = true
        elseif marker == 196 or marker == 219 then
            if marker == 196 then read_tables(data, first, stop, tables) end
            copy(pos, stop-pos)
        elseif marker == 221 then
            assert(length == 4)
            interval = u16(data, first)
            copy(pos, stop-pos)
        elseif marker == 218 then
            scans = scans + 1
            assert(frame and scans <= 32)
            local components = data:byte(first)
            assert((components == 1 or components == 3) and length == 6 + 2*components)
            local last
            if components == 1 then
                last = scan_end(stop)
                local id = data:byte(first+1)
                assert(id >= 1 and id <= 3)
                if id == 1 then
                    copy(pos, last-pos)
                    if data:byte(stop-3) == 0 then dc_seen = true end
                end
            else
                assert(data:byte(stop-3) == 0 and data:byte(stop-2) == 0)
                interleaved_passes = interleaved_passes + 1
                assert(interleaved_passes <= 4)
                local refine = data:byte(stop-1) >= 16
                local selectors = {}
                for c = 1, 3 do
                    local id, selector = data:byte(first+2*c-1, first+2*c)
                    assert(id == c)
                    if not refine then selectors[c] = assert(tables[floor(selector/16)]) end
                end
                copy(pos, 2); write(0); write(8); write(1)
                copy(first+1, 2); copy(stop-3, 3)
                last = scan_end(stop, selectors, refine)
                dc_seen = true
            end
            stop = last
        elseif marker ~= 254 and (marker < 224 or marker > 239) then
            return nil
        end
        pos = stop
    end
end

-- Caller verifies TurboJPEG's input colorspace and charges the retained buffer
-- across every subsequent native allocation. No file or global cache is used.
function M.prepare(data, width, height, available)
    -- At the handoff both the temporary output and its exact-sized Lua
    -- string can be live. The temporary allocation is released on every exit.
    local capacity = math.min(#data + 128, math.floor((available - scratch) / 2))
    if capacity < 128 then return nil end
    local buf = ffi.C.malloc(capacity)
    if buf == nil then return nil end
    local ok, result = pcall(project, data, width, height, ffi.cast("uint8_t *", buf), capacity)
    ffi.C.free(buf)
    if ok then return result end
end

return M
