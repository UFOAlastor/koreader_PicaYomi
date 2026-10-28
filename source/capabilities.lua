-- Source contract shared by loaders and UI. Missing optional capabilities are off.
local C = {}
local booleans = { recommendations=true, latest=true, login=true, requires_login=true, search=true, categories=true,
    rankings=true, random=true, favorites=true, comments=true, comment_details=true, download=true, local_favorites=true }
local methods = {
    recommendations={"getRecommendations"}, latest={"getLatest"},
    search={"search"}, categories={"getCategories","getCategoryComics"},
    rankings={"getRankingTypes","getRankings"}, login={"login","logout","isLoggedIn","getUserProfile"},
    favorites={"getFavorites","addFavorite","removeFavorite"}, comments={"getComments"}, comment_details={"getCommentDetails"},
    download={"getAllChapterImages","imageHeaders"},
}
function C.needsLogin(source, name)
    if not source or source._offline then return false end
    local caps = source.capabilities or {}
    local required = caps.requires_login == true or (source.access or {})[name] == "login"
    if not required then return false end
    local ok, logged = pcall(function() return source:isLoggedIn() end)
    return not ok or logged ~= true
end
function C.query(source, name)
    local caps = source and source.capabilities or {}
    local supported = caps[name] == true
    if source and not source.capabilities and source.hasCapability then supported=source:hasCapability(name)==true end
    local requires = supported and ((source.access or {})[name] == "login"
        or name ~= "login" and name ~= "local_favorites" and caps.requires_login == true)
    local available = supported and not source._offline
    local reason
    if requires and (not source.isLoggedIn or not source:isLoggedIn()) then
        available, reason = false, "请先登录"
    elseif not supported then reason = "当前源不支持此功能"
    elseif source._offline then reason = "当前源仅可离线访问" end
    return { supported=supported, available=available, requires_login=requires == true, reason=reason }
end
function C.replies(source, comment)
    local mode = source and source.capabilities and source.capabilities.replies
    if mode then return mode end
    -- v1 adapters already shipped embedded replies without a separate flag.
    if comment and type(comment.replies) == "table" then return "embedded" end
    local ComicSource = require("source.base")
    if source and source.getCommentReplies and source.getCommentReplies ~= ComicSource.getCommentReplies then return "paged" end
    return "none"
end
function C.validate(source, api)
    local ComicSource = require("source.base")
    local caps = assert(source.capabilities, "缺少能力声明")
    assert(type(caps)=="table", "能力声明必须为对象")
    if api==1 and caps==ComicSource.capabilities then caps={}; source.capabilities=caps end
    if api==1 and caps.latest==nil then
        caps.latest=true; source.getLatest=source.getLatest or source.getComics
    end
    for name, value in pairs(caps) do
        if booleans[name] then assert(type(value)=="boolean", "能力必须为布尔值: "..name)
        elseif name=="replies" then assert(value=="none" or value=="embedded" or value=="paged", "回复模式无效")
        else assert(api==1, "未知能力: "..tostring(name)) end
    end
    assert(not caps.requires_login or caps.login, "要求登录但不支持登录")
    assert(not caps.replies or caps.replies=="none" or caps.comments, "回复能力要求评论能力")
    assert(not caps.comment_details or caps.comments, "评论全文要求评论能力")
    for name, required in pairs(methods) do
        if caps[name] then
            if api==3 and name=="login" then required={"login","logout","getSession","getUserProfile"} end
            if api==3 and name=="download" then required={"getPages","getImageRequest"} end
            if api==3 and name=="download" and source.content_type=="novel" then required={"getChapterContent","getImageRequest"} end
            for _, method in ipairs(required) do
                assert(type(source[method])=="function" and source[method]~=ComicSource[method], "能力缺少实现: "..method)
            end
        end
    end
    if caps.replies=="paged" then
        assert(type(source.getCommentReplies)=="function" and source.getCommentReplies~=ComicSource.getCommentReplies,
            "分页回复缺少实现")
    end
    if api==3 and caps.random then assert(type(source.getRandom)=="function","随机能力缺少实现") end
    for name, condition in pairs(source.access or {}) do
        assert(booleans[name] and caps[name]==true and condition=="login" and caps.login,
            "功能使用条件无效: "..tostring(name))
    end
    return source
end
return C
