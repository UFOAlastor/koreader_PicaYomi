-- source/base.lua
-- 漫画源基类定义
-- 对齐 PicaComic 的 ComicSource 抽象设计

local logger = require("util.logger")

local ComicSource = {}
ComicSource.__index = ComicSource

-- 能力声明
ComicSource.capabilities = {
    login = false,
    -- 是否"不登录就用不了" (首页会拦一道登录框)。
    -- 与 login 分开: 源 C 支持登录, 但浏览/阅读不需要 —— 不该被拦。
    requires_login = false,
    search = true,
    categories = true,
    rankings = false,
    random = false,
    favorites = false,    -- 网络收藏
    comments = false,
    download = true,
    local_favorites = true, -- 本地收藏 (所有源都支持)
}

-- 元信息 (子类必须覆盖)
ComicSource.name = ""
ComicSource.identifier = ""
ComicSource.version = "1.0"

--- 继承创建子类
function ComicSource:extend(child)
    child = child or {}
    -- 设置元表继承
    local mt = { __index = self }
    setmetatable(child, mt)
    child.__index = child
    return child
end

--- 初始化源
function ComicSource:init()
end

--- 登录
function ComicSource:login(username, password)
    return false, "not implemented"
end

--- 获取 Token
function ComicSource:getToken()
    return nil
end

--- 是否已登录
function ComicSource:isLoggedIn()
    return self:getToken() ~= nil
end

--- 退出登录
function ComicSource:logout()
end

--- 获取分类列表
--
-- 契约: (ok, categories, err), 其中每个条目是
--   { _id = <源内取值>, title = <显示名>, isWeb = <可选, 外部链接>, link = <可选> }
--
-- `_id` 是**唯一**的标识字段名, 各源必须用它 (不要再引入 `id`) —— 界面用它调
-- getCategoryComics。曾经源 C 用 `id`、源 B/源 A 用 `_id`, 而两个界面一个读
-- `_id` 一个读 `id`, 结果是"点源 C 的分类变成了按分类名搜索"。
--
-- `isWeb = true` 的条目是站外链接 (源 A 有一批), 界面会过滤掉, 但 `_id` 仍须给。
-- 没有 `_id` 的条目按"特殊分类"处理: 界面退化成按标题搜索 (源 A 的「大家都在看」)。
function ComicSource:getCategories()
    return {}
end

--- 获取分类下的漫画
function ComicSource:getCategoryComics(category, page, sort)
    return nil, "not implemented"
end

--- 搜索漫画
function ComicSource:search(keyword, page, sort, categories)
    return nil, "not implemented"
end

--- 获取漫画详情
function ComicSource:getComicDetail(comic_id)
    return nil, "not implemented"
end

--- 获取章节列表
function ComicSource:getChapters(comic_id, page)
    return nil, "not implemented"
end

--- 获取章节图片
function ComicSource:getChapterImages(comic_id, chapter_order, page)
    return nil, "not implemented"
end

--- 获取排行榜
function ComicSource:getRankings(rank_type, page)
    return nil, "not implemented"
end

--- 获取随机漫画
--- 某类列表可用的排序方式
--
-- 各源的排序取值完全不同 (源 A 用 s=ua/dd/ld/vd, 源 B 用 o=mr/mv/mp/tf),
-- 而且**不是每类列表都能排序**(源 B 的 最新列表接口 就没有排序参数), 所以由源自己声明。
--
-- @param list_kind "recommend" | "category" | "search"
-- @return { { value = <接口取值>, text = <界面文案> }, ... }; 空表表示该列表不支持排序
function ComicSource:getSortOptions(_list_kind)
    return {}
end

function ComicSource:getRandom(page)
    return nil, "not implemented"
end

--- 获取网络收藏
function ComicSource:getFavorites(page, sort)
    return nil, "not implemented"
end

--- 切换收藏状态
function ComicSource:toggleFavorite(comic_id)
    return nil, "not implemented"
end

--- 加入收藏 / 取消收藏 (契约 (ok, err), 与其余收藏方法一致)
--
-- 为什么要有这一对, 而不是让调用方自己去 toggle:
-- 有些源的收藏端点是**切换**语义 (源 B 的 收藏接口), 有些是明确的增/删 (源 A)。
-- 界面上按下的「收藏」/「取消收藏」是**设定**语义 —— 调用方只知道自己想要哪个
-- 状态, 不该关心源的端点是哪种。由源自己保证"结果 = 请求的状态" (幂等),
-- 否则会出现"取消收藏按下去又加了一次"。
function ComicSource:addFavorite(comic_id)
    return false, "not implemented"
end

function ComicSource:removeFavorite(comic_id)
    return false, "not implemented"
end

--- 获取评论列表
-- 契约与其余取数方法一致: (ok, data, err)
--   ok=true 时 data = { comments = <docs 数组>, total, page, pages }
function ComicSource:getComments(comic_id, page)
    return false, nil, "not implemented"
end

--- 获取某条评论的回复
-- 契约同上: ok=true 时 data = { replies = <docs 数组>, total, page, pages }
function ComicSource:getCommentReplies(comic_id, comment_id, page)
    return false, nil, "not implemented"
end

--- 打卡
function ComicSource:punchIn()
    return nil, "not implemented"
end

function ComicSource:capability(name)
    return require("source.capabilities").query(self, name)
end

--- 检查能力
function ComicSource:hasCapability(name)
    return self.capabilities[name] == true
end

--- 已缓存的图片是否已失效 (需要丢弃重下)
-- 默认不失效。给"图片处理方式升级过"的源用 —— 但那必须是一条**可靠**的判据:
-- 用扩展名/文件大小猜"这是不是旧实现的产物"很脆 (源 B 就踩过: 解扰从"写回 PNG"
-- 改成"渲染期内存重排"之后, 缓存里合法地变成了 webp/jpg, 旧的判据把每一页都
-- 判成失效, 表现成"一张图都不出 + 每页每秒重下一次")。整体作废旧缓存的正确做法
-- 是给缓存目录/版本号加一层, 见 source/jm/init.lua 的 SCRAMBLE_CACHE_VERSION。
-- @param path 已缓存的图片路径
-- @param url  对应的图片地址
function ComicSource:isCachedImageStale(_path, _url)
    return false
end

--- 图片请求头 (可选约定; 供 fork 出来的下载 worker 使用)
--
-- 为什么把"请求头"从 downloadImage 里单独抽出来:
--   真正的下载在**子进程**里做 (只有那里才不怕 DNS/TLS 阻塞)。子进程是 fork 出来的
--   快照 —— 里面的 token / 登录态可能已经过期。所以请求头一律由**父进程在发起那一刻
--   现算**, 随任务一起下发, 从结构上消除"子进程拿着旧 token"的问题。
--
-- 返回 nil 表示"本源不支持 worker 下载": 该任务会退回到同步的
-- network/transport_blocking.lua (行为与改造前完全一致), 不会静默失败。
--
-- @param url 图片地址 (签名通常与 URL 里的 path 相关, 所以必须传进来)
-- @return headers 表 或 nil, err
function ComicSource:imageHeaders(_url)
    return nil, "本源未实现 imageHeaders"
end

--- 图片下载后处理 (可选约定; 也在子进程里执行)
--
-- 例如源 B 的正文图做了分带混淆, 下完必须解扰。返回"模块 + 函数"而不是直接调用,
-- 是因为父进程只负责告诉子进程"下完之后怎么处理" —— 它自己不碰文件。
-- 子进程会以 `require(module)[fn](dest_path, url)` 调用。
--
-- @return { module = "source.xx.yy", fn = "funcName" } 或 nil (无需后处理)
function ComicSource:imagePost(_url)
    return nil
end

--- 渲染期变换描述符 (可选): "解码之后、绘制之前"要在内存里做的处理
--
-- 与 imagePost 的分工:
--   imagePost      在**下载子进程**里对**文件**做, 结果落盘 (缓存里存处理后的图);
--   imageRenderPost 在**渲染路径**里对**已解码的位图**做, 不落盘 (缓存里存原图)。
--
-- 什么时候用后者: 处理本身只是内存搬运 (例如源 B 的分带重排), 而落盘需要
-- 重新编码一张图 —— 那一步在 Kindle 上要几秒, 比处理本身贵两个数量级。
-- 代价是每次重绘都要做一遍 (DocCache 会缓存渲染结果, 实际每页一次)。
--
-- 渲染链会以 `require(module)[fn](bb, url)` 调用; 返回**新的** BlitBuffer,
-- 或 nil + 原因 (nil 表示"这页不用处理/处理失败", 调用方继续用原图)。
-- 注意: 内存归调用方 —— 返回新图时调用方负责释放输入。
--
-- @return { module = "source.xx.yy", fn = "funcName" } 或 nil (无需处理)
function ComicSource:imageRenderPost(_url)
    return nil
end

--- 构造图片 URL
function ComicSource:buildImageUrl(file_server, path)
    if not file_server or not path then
        return nil
    end
    -- 修复路径: 确保不重复 /static/
    if path:match("^static/") then
        return file_server .. "/" .. path
    end
    return file_server .. "/static/" .. path
end

return ComicSource
