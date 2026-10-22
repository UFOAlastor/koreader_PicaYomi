-- Legacy Lua import names resolve to the process snapshot, never to live files.
local C={}
function C.module(id,name)
    return require("source.extensions.manager").instance():module(id,name)
end
return C
