-- Compatibility import; platform implementation lives in an immutable source package.
local raw=require("source.extensions.compat").module("jm","scramble")
local Service=require("source.image_service")
local out={}
for name,fn in pairs(raw) do out[name]=fn end
-- Frozen host import compatibility. Source v3 processors use opaque handles.
for _,name in ipairs({"reorder","applyTo","applyContext"}) do
    out[name]=function(bb,arg)
        if not bb then return nil,"no_bitmap" end
        local ok,value=pcall(function()
            return Service.process(function(handle) return raw[name](handle,arg) end,bb,{})
        end)
        if not ok then return nil,"invalid_band_geometry" end
        return value
    end
end
return out
