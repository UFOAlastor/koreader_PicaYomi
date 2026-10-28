-- Adapt the native source contract to the local HTML document builder.
local M={}
function M.session(source,book,chapter)
    return {
        metadata={id=source.identifier},
        invoke=function(self,method,_,call)
            assert(method=="parseChapter")
            local ok,data,err=source:invoke("getChapterContent",{book,chapter},call)
            if not ok then return false,nil,err end
            self.metadata.site=data.base_url
            return true,data.html,nil
        end,
        normalize=function(_,html) return require("novel.html").normalize(html) end,
        imageRequest=function(_,url,call)
            local ok,request,err=source:invoke("getImageRequest",{{url=url},{}},call)
            assert(ok,err and err.message);return request
        end,
    }
end
return M
