-- Darwin's system frameworks are unsafe between fork and exec. Start a fresh
-- LuaJIT with two dedicated pipe descriptors instead of inheriting Lua state.
local ffi = require("ffi")
require("ffi/posix")
assert(ffi.os == "OSX", "spawn backend is Darwin-only")
ffi.cdef[[
int posix_spawn_file_actions_init(void **);
int posix_spawn_file_actions_destroy(void **);
int posix_spawn_file_actions_adddup2(void **, int, int);
int posix_spawnattr_init(void **);
int posix_spawnattr_destroy(void **);
int posix_spawnattr_setflags(void **, short);
int posix_spawnattr_setpgroup(void **, int);
int posix_spawn(int *, const char *, void **, void **, char *const[], char *const[]);
char ***_NSGetEnviron(void);
]]
local C = ffi.C
local Spawn = {}

function Spawn.spawn(kind, options)
    local read_pipe, write_pipe = ffi.new("int[2]"), ffi.new("int[2]")
    if C.pipe(read_pipe) ~= 0 then return nil, "无法创建后台响应管道" end
    if C.pipe(write_pipe) ~= 0 then
        C.close(read_pipe[0]); C.close(read_pipe[1])
        return nil, "无法创建后台请求管道"
    end
    local actions, attrs = ffi.new("void *[1]"), ffi.new("void *[1]")
    local actions_ready, attrs_ready, pid
    local child_read, child_write = -1, -1
    local ok, err = pcall(function()
        local function checked(code) assert(code == 0, "无法启动后台进程: " .. tostring(code)) end
        checked(C.posix_spawn_file_actions_init(actions)); actions_ready = true
        checked(C.posix_spawnattr_init(attrs)); attrs_ready = true
        -- Duplicate sources above the target descriptors to avoid dup2 ordering
        -- collisions. F_DUPFD=0, POSIX_SPAWN_SETPGROUP=2, CLOEXEC_DEFAULT=0x4000
        -- are Darwin SDK constants. No unrelated host sockets/files are inherited.
        child_read = C.fcntl(write_pipe[0], 0, ffi.cast("int", 10))
        child_write = C.fcntl(read_pipe[1], 0, ffi.cast("int", 10))
        assert(child_read >= 0 and child_write >= 0, "无法准备后台管道")
        checked(C.posix_spawn_file_actions_adddup2(actions, child_read, 3))
        checked(C.posix_spawn_file_actions_adddup2(actions, child_write, 4))
        checked(C.posix_spawn_file_actions_adddup2(actions, 2, 1))
        checked(C.posix_spawn_file_actions_adddup2(actions, 2, 2))
        checked(C.posix_spawnattr_setflags(attrs, 0x4002))
        checked(C.posix_spawnattr_setpgroup(attrs, 0))
        local plugin = assert(debug.getinfo(1, "S").source:match("^@(.*)/network/[^/]+$"))
        local runtime = require("libs/libkoreader-lfs").currentdir()
        local args = { runtime .. "/luajit", plugin .. "/network/worker_entry.lua", plugin }
        local argv = ffi.new("char *[?]", #args + 1)
        for i, value in ipairs(args) do argv[i - 1] = ffi.cast("char *", value) end
        local child_pid = ffi.new("int[1]")
        checked(C.posix_spawn(child_pid, args[1], actions, attrs, argv, C._NSGetEnviron()[0]))
        pid = tonumber(child_pid[0])
    end)
    if actions_ready then C.posix_spawn_file_actions_destroy(actions) end
    if attrs_ready then C.posix_spawnattr_destroy(attrs) end
    if child_read >= 0 then C.close(child_read) end
    if child_write >= 0 then C.close(child_write) end
    C.close(write_pipe[0]); C.close(read_pipe[1])
    if not ok then
        C.close(read_pipe[0]); C.close(write_pipe[1])
        return nil, tostring(err)
    end
    local session = require("network.subprocess_fork").from_fds(read_pipe[0], write_pipe[1], pid)
    -- Headers and bodies travel only through the pipe, never command arguments
    -- or temporary files. The initial descriptor uses the existing frame limit.
    local encoded, sent, why = pcall(session.send, session, { kind = kind, options = options })
    if not encoded or not sent then session:close(); return nil, tostring(encoded and why or sent) end
    return session
end

return Spawn
