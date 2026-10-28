-- Shared pressure policy for rendering, DocCache and network workers.
-- /proc is an observation, never an allocation guarantee. After eviction we
-- sample again: freed cache bytes must not be added to a decode/fork grant.
local logger = require("util.logger")
local MemoryGuard = {}
MemoryGuard.__index = MemoryGuard
local MB = 1024 * 1024
-- Defaults apply only when the corresponding metrics cannot be read.
MemoryGuard.CAP_BYTES = 24 * MB
MemoryGuard.DECODE_FALLBACK = 32 * MB
MemoryGuard.RESERVE_FALLBACK = 16 * MB
MemoryGuard.RESERVE_FRACTION = 1 / 32
MemoryGuard.CAP_FRACTION = 0.20
-- Measured Kindle worker incremental RSS was 10--25 MiB. Reserve its upper
-- observed working set in addition to the device-sized UI/system reserve.
MemoryGuard.WORKER_BYTES = 25 * MB
MemoryGuard.RELIEVE_INTERVAL = 15

local function number(v)
    v = tonumber(v)
    if v and v == v and v >= 0 and v < math.huge then return v end
end
local function doc_cache()
    local ok, cache = pcall(require, "document/doccache")
    return ok and type(cache) == "table" and cache or nil
end
local function used_bytes(cache)
    local ok, used = pcall(function() return cache.cache:used_size() end)
    return ok and number(used) or 0
end
local function resize(cache, size)
    size = math.max(1, math.floor(size)) -- LRU requires a positive byte limit.
    local ok = pcall(function() cache.cache:resize_bytes(size) end)
    if ok then cache.size = size end -- keep host and LRU limits consistent
    return ok
end

function MemoryGuard.read_meminfo()
    local f = io.open("/proc/meminfo", "r")
    if not f then return nil end
    local info = {}
    for line in f:lines() do
        local k, v = line:match("^(%w+):%s+(%d+)")
        if k == "MemAvailable" then info.avail = tonumber(v)
        elseif k == "MemFree" then info.free = tonumber(v)
        elseif k == "MemTotal" then info.total = tonumber(v)
        elseif k == "SwapFree" then info.swap = tonumber(v) end
    end
    f:close()
    if not info.avail then return nil end
    return info
end
function MemoryGuard.available_mb()
    local m = MemoryGuard.read_meminfo()
    return m and m.avail and m.avail / 1024 or nil
end
function MemoryGuard.new(opts)
    opts = opts or {}
    return setmetatable({
        read_available_mb = opts.read_available_mb or function() return MemoryGuard.available_mb() end,
        read_meminfo = opts.read_meminfo or function() return MemoryGuard.read_meminfo() end,
        clock = opts.clock or os.time, _refs = 0,
    }, MemoryGuard)
end
local default_instance
function MemoryGuard.instance()
    if not default_instance then default_instance = MemoryGuard.new{} end
    return default_instance
end
function MemoryGuard.reset() default_instance = nil end

function MemoryGuard:snapshot()
    local ok, avail = pcall(self.read_available_mb)
    avail = ok and number(avail) or nil
    local ok_info, info = pcall(self.read_meminfo)
    local total = ok_info and type(info) == "table" and number(info.total) or nil
    local reserve = total and total > 0 and total * 1024 * MemoryGuard.RESERVE_FRACTION
        or MemoryGuard.RESERVE_FALLBACK
    local available = avail and avail * MB or nil
    -- Inconsistent metrics are unavailable, but a measured zero stays zero.
    if total and total > 0 and available and available > total * 1024 then available = nil end
    return {available = available, reserve = reserve,
        worker = reserve + MemoryGuard.WORKER_BYTES}
end
function MemoryGuard:decode_budget(reserved, snapshot)
    local s = snapshot or self:snapshot()
    if not s.available then return MemoryGuard.DECODE_FALLBACK end
    local available = math.max(0, s.available - (reserved or 0))
    return math.floor(math.max(0, math.min(available / 3, available - s.reserve)))
end
-- Emergency grants are only for region rendering into an existing screen
-- buffer. Keep the ordinary full-image and worker policies unchanged. The
-- Keep at least 4 MiB and half of observed availability outside the grant.
-- The caller caps PNG at 3 MiB; native JPEG/WebP may use up to 8 MiB to avoid
-- repeatedly restarting the codec for unnecessarily tiny strips.
function MemoryGuard:region_budget(maximum)
    local regular = self:decode_budget()
    local s = self:snapshot()
    if not s.available then return regular end
    return math.max(regular, math.floor(math.max(0,
        math.min(maximum or 3 * MB, s.available / 2, s.available - 4 * MB))))
end
function MemoryGuard:under_pressure()
    local s = self:snapshot()
    return s.available ~= nil and s.available < s.worker
end
function MemoryGuard:doc_cache_budget(snapshot, used)
    local s = snapshot or self:snapshot()
    if not s.available then return MemoryGuard.CAP_BYTES end
    -- Include resident cache only when calculating its target capacity. This
    -- avoids repeated shrinkage solely because the cache has filled its budget.
    return math.floor(math.max(0, (s.available + (used or 0) - s.reserve) * MemoryGuard.CAP_FRACTION))
end
function MemoryGuard:cap_doc_cache()
    self._refs = self._refs + 1
    local cache = doc_cache()
    if not cache or not cache.size then return false end
    if self._saved_size == nil then self._saved_size = cache.size end
    if self._capped then return false end
    self._capped = true
    local cap = math.max(1, math.min(self._saved_size, self:doc_cache_budget(nil, used_bytes(cache))))
    if cap >= cache.size then return false end
    return resize(cache, cap)
end
function MemoryGuard:restore_doc_cache()
    if self._refs > 0 then self._refs = self._refs - 1 end
    if self._refs > 0 or not self._capped then return false end
    local saved = self._saved_size
    self._capped, self._saved_size, self._last_growth = false, nil, nil
    local cache = doc_cache()
    return saved and cache and resize(cache, saved) or false
end

-- Shrink immediately when pressure rises; recover capacity gradually and no
-- more often than once per interval. No minimum number of cached pages is kept.
function MemoryGuard:rebalance(s, force)
    local cache = doc_cache()
    if not cache or not cache.size or not s.available then return false end
    local used = used_bytes(cache)
    local target = math.max(1, self:doc_cache_budget(s, used))
    if force then target = math.min(target, math.max(1, used - math.max(0, s.worker - s.available))) end
    local ceiling = self._saved_size or cache.size
    target = math.min(ceiling, target)
    local now = self.clock()
    local before = cache.size
    if target > before then
        if not self._capped or (self._last_growth and now - self._last_growth < MemoryGuard.RELIEVE_INTERVAL) then return false end
        target = math.min(target, before + math.max(before / 4, target / 10))
        self._last_growth = now
    end
    if target == before and used <= target then return false end
    if not resize(cache, target) then return false end
    if target < before then self._last_growth = now end
    -- Outside a reading session only evict; preserve the host's cache policy.
    if not self._capped then resize(cache, before) end
    self.last_reclaimed = math.max(0, used - used_bytes(cache))
    if self.last_reclaimed > 0 then
        if logger.enabled then logger.dbg("Picayomi MemoryGuard: reclaimed bytes", self.last_reclaimed) end
    end
    return self.last_reclaimed > 0 or (self._capped == true and cache.size ~= before)
end
function MemoryGuard:relieve(force)
    local s=self:snapshot()
    local now=self.clock()
    if not force and s.available and s.available>=s.reserve and self._last_relieve
        and now-self._last_relieve<MemoryGuard.RELIEVE_INTERVAL
        and self._last_available and s.available>=self._last_available then return false end
    local changed=self:rebalance(s,force)
    if changed then self._last_relieve=now;self._last_available=s.available end
    return changed
end
function MemoryGuard:relieve_critical()
    local s = self:snapshot()
    if not s.available or s.available >= s.reserve then return false end
    local cache = doc_cache()
    if not cache or used_bytes(cache) == 0 then return false end
    return self:rebalance(s, true)
end
function MemoryGuard:prepare_decode()
    self:relieve()
    self:relieve_critical()
    return self:decode_budget() -- fresh observation, even if eviction failed
end
-- Called after painting has returned, never while a cached tile is in use.
-- A failed decoder needs an explicit recovery path even above worker pressure.
function MemoryGuard:reclaim_for_decode()
    local cache=doc_cache()
    local before=cache and used_bytes(cache) or 0
    if before>0 then
        pcall(function()
            if cache.clear then cache:clear() else cache.cache:clear() end
        end)
    end
    collectgarbage("collect")
    return self:decode_budget()
end
function MemoryGuard:make_room_for_fork()
    local s = self:snapshot()
    if not s.available then return nil, s.worker / MB end
    if s.available < s.worker then self:rebalance(s, true); s = self:snapshot() end
    return s.available and s.available / MB or nil, s.worker / MB
end
function MemoryGuard:fork_allowed()
    local available, minimum = self:make_room_for_fork()
    -- Unknown metrics retain the pre-existing non-Linux behavior.
    return available == nil or available >= minimum, available
end
function MemoryGuard:release_doc_cache()
    if self._refs > 0 then return 0 end
    local cache = doc_cache()
    if not cache then return 0 end
    local used = used_bytes(cache)
    if used <= 0 then return 0 end
    local ok = pcall(function()
        if cache.clear then cache:clear() else cache.cache:clear() end
    end)
    return ok and math.max(0, used - used_bytes(cache)) or 0
end
return MemoryGuard
