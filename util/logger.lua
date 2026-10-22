-- Plugin-local gate. Never change KOReader's global logging level.
local config = require("util.log_config")
local backend = require("logger")
local enabled = config.debug == true
    or config.allow_env == true and os.getenv("PICAYOMI_DEBUG") == "1"
local function noop() end
local M = { enabled = enabled }
M.dbg = enabled and backend.dbg or noop
M.info = enabled and backend.info or noop
M.warn = backend.warn
M.err = backend.err
return M
