-- Process-family observations, separate from MemoryGuard's allocation policy.
-- Values are KiB. RSS is per-process and must never be summed as physical RAM.
local ffi = require("ffi")
local ProcessMemory = {}

local function read(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local data = f:read("*a"); f:close()
    return data
end

local function fields(data)
    local result = {}
    for key, value in (data or ""):gmatch("([%w_]+):%s*(%d+)") do
        result[key] = tonumber(value)
    end
    return result
end

local function linux(opts)
    local root = opts.root or "/proc"
    local pid = opts.pid or tonumber(ffi.C.getpid())
    local lfs = require("libs/libkoreader-lfs")
    local tree, statuses = {}, {}
    -- Old Kindle kernels may have neither task/*/children nor smaps_rollup.
    -- Reading status also finds children created by non-main threads.
    local ok = pcall(function()
        for name in lfs.dir(root) do
            if name:match("^%d+$") then
                local data = read(root .. "/" .. name .. "/status")
                if data then
                    local info = fields(data)
                    local id = tonumber(name)
                    statuses[id] = {pid=id, ppid=info.PPid, rss=info.VmRSS,
                        name=data:match("Name:%s*([^\n]+)")}
                    if info.PPid then
                        tree[info.PPid] = tree[info.PPid] or {}
                        table.insert(tree[info.PPid], id)
                    end
                end
            end
        end
    end)
    if not ok or not statuses[pid] then return nil end
    local result = {platform="Linux", processes={}, pss=0, private=0}
    local seen = {}
    local function visit(id)
        if seen[id] then return end
        seen[id] = true
        if #result.processes >= 64 then result.partial=true; return end
        local entry = statuses[id]
        if not entry then result.partial=true; return end
        if opts.detailed then
            -- Stream old-kernel smaps: diagnostics must not allocate another
            -- multi-megabyte string on the very device running out of memory.
            local f = io.open(root .. "/" .. id .. "/smaps_rollup", "r")
                or io.open(root .. "/" .. id .. "/smaps", "r")
            local pss, private, found = 0, 0, false
            if f then
                for line in f:lines() do
                    local key, value = line:match("^([%w_]+):%s*(%d+) kB")
                    if key == "Pss" then pss=pss+tonumber(value); found=true end
                    if key == "Private_Clean" or key == "Private_Dirty" then
                        private=private+tonumber(value)
                    end
                end
                f:close()
            end
            if found then entry.pss=pss; entry.private=private end
        end
        if entry.pss then
            if result.pss then result.pss=result.pss+entry.pss; result.private=result.private+entry.private end
        else result.pss=nil; result.private=nil end
        table.insert(result.processes, entry)
        table.sort(tree[id] or {})
        for _, child in ipairs(tree[id] or {}) do visit(child) end
    end
    visit(pid)
    if result.partial then result.pss=nil; result.private=nil end
    if opts.detailed then
        -- Already read above: expose large processes outside this family so
        -- system pressure can be compared with reader growth. No cmdline/env.
        local others={}
        for id,entry in pairs(statuses) do
            if not seen[id] and entry.rss then others[#others+1]=entry end
        end
        table.sort(others,function(a,b) return a.rss>b.rss end)
        result.others={}
        for i=1,math.min(5,#others) do result.others[i]=others[i] end
    end
    return result
end

local darwin_ready
local function darwin(opts)
    if not darwin_ready then
        ffi.cdef[[
            int proc_pid_rusage(int pid, int flavor, void *buffer);
            int proc_listchildpids(int ppid, void *buffer, int buffersize);
        ]]
        darwin_ready = true
    end
    local result = {platform="OSX", processes={}}
    local seen = {}
    local function visit(pid, ppid)
        if seen[pid] then return end
        seen[pid] = true
        if #result.processes >= 64 then result.partial=true; return end
        -- rusage_info_v0: uuid[16], six counters, resident_size, phys_footprint,
        -- start/exit times. Do not add footprints across forked processes:
        -- Darwin's accounting of inherited COW pages differs from Linux PSS.
        local usage = ffi.new("uint64_t[12]")
        if ffi.C.proc_pid_rusage(pid, 0, usage) ~= 0 then result.partial=true; return end
        table.insert(result.processes, {pid=pid, ppid=ppid,
            rss=tonumber(usage[8])/1024, footprint=tonumber(usage[9])/1024})
        local children = ffi.new("int[65]")
        -- Unlike proc_listpids, this wrapper returns a PID count, not bytes.
        ffi.errno(0)
        local count = ffi.C.proc_listchildpids(pid, children, ffi.sizeof(children))
        if count < 0 or (count==0 and ffi.errno()~=0) then result.partial=true; return end
        if count >= 65 then result.partial=true; count=65 end
        for i=0,count-1 do if children[i]>0 then visit(tonumber(children[i]), pid) end end
    end
    visit(opts.pid or tonumber(ffi.C.getpid()))
    return #result.processes > 0 and result or nil
end

function ProcessMemory.snapshot(opts)
    opts = opts or {}
    local platform = opts.platform or ffi.os
    local ok, result = pcall(function()
        if platform == "Linux" then return linux(opts) end
        if platform == "OSX" then return darwin(opts) end
    end)
    return ok and result or nil
end

return ProcessMemory
