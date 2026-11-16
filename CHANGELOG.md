# 更新记录

## 1.6.0 — 2026-11-16

### 中文

- 首次进入可一键安装内置订阅的漫画和小说源，也可选择稍后安装。
- 插件包不再附带源；订阅更新支持补齐未安装源及新增源。
- 新用户默认开启插件和源更新检查，保留已有设置。
- 安装结果区分新增与更新，改善更新提示在中断后的恢复。
- 减少源更新检查的重复计算，避免失效弹窗继续触发下载。
- 加快聚合搜索排序，改善主页收藏刷新与详情简介布局。

### English

- Install manga and novel sources from the built-in subscription on first entry, or choose Later.
- Source-free plugin packages; subscription updates include missing and newly added sources.
- Automatic update checks default to on for new users; existing settings are preserved.
- Installation results distinguish added sources from updates; interrupted update prompts can be offered again.
- Fewer repeated subscription checks, with stale dialogs prevented from starting downloads.
- Faster aggregate search ranking and improved favorites refresh and detail layout.

## 1.5.12 — 2026-11-14

### 中文

- 封面加载遇到暂时网络错误时自动补试，改善多个来源的偶发缺图。
- 修复自动恢复登录遇到响应异常后丢失保存凭据的问题。

### English

- Retry temporary cover-loading failures to reduce intermittent missing covers across sources.
- Keep saved credentials when automatic sign-in recovery encounters an unexpected response.

## 1.5.11 — 2026-11-13

### 中文

- 改善漫画增强预处理连续失败时的恢复，减少重复后台处理。
- 修复漫画图片获取失败时丢失具体原因的问题，提供更明确的网络错误提示。

### English

- Improve recovery after repeated comic enhancement preprocessing failures and reduce repeated background processing.
- Preserve the specific cause of comic image retrieval failures and show clearer network errors.

## 1.5.10 — 2026-11-11

### 中文

- 精简阅读设置中的重复说明，保留图片和小说的阅读选项。

### English

- Remove duplicate explanations from reading settings while retaining image and novel reading options.

## 1.5.9 — 2026-11-07

### 中文

- 补齐列表、评论、分类、下载选择和设置等页面的打开与返回等待提示。
- 下载过程中明确显示正在下载，避免未完成章节的“待重试”状态掩盖当前进度。

### English

- Add waiting feedback when opening and returning from lists, comments, categories, download selection and settings.
- Show active downloading explicitly so that pending retries for unfinished chapters do not obscure current progress.

## 1.5.8 — 2026-11-07

### 中文

- 修复漫画与小说收藏跳页及反向翻页失败。
- 减少进入阅读时缓存清理造成的操作停顿，避免重复扫描。
- 完善翻页、返回及打开阅读器时的等待提示。

### English

- Fix page jumps and backward paging in manga and novel favorites.
- Reduce pauses caused by cache cleanup when entering the reader and avoid repeated scans.
- Improve waiting feedback for page turns, return navigation and opening the reader.

## 1.5.7 — 2026-11-07

### 中文

- 减少长时间阅读返回详情、详情返回列表时的重复加载。
- 修复跳到较后页再向前翻页时，封面等待或停留在占位图的问题。
- 优化列表封面复用和快速翻页时的加载调度。

### English

- Reduce repeated loading when returning from long reading sessions to details and from details to lists.
- Fix covers remaining pending or showing placeholders when jumping forward and then paging backward.
- Improve list cover reuse and loading coordination during rapid page turns.

## 1.5.6 — 2026-11-07

### 中文

- 安装包从约 5.93 MB 缩小至 0.74 MB，项目主页的展示截图保持可用。
- 改善网络重定向兼容性，补充异常响应的接收限制。
- 保留各源登录、Cookie 与重试规则，清理不再使用的下载辅助实现。
- 下载 `picayomi.koplugin-1.5.6.zip` 安装，或通过插件内检查更新升级。

### English

- Reduce the installation package from about 5.93 MB to 0.74 MB while keeping showcase screenshots available on the project page.
- Improve network redirect compatibility and limit the reception of abnormal responses.
- Preserve source login, Cookie and retry behavior while removing unused download helpers.
- Install `picayomi.koplugin-1.5.6.zip` or upgrade using the plugin's update checker.

## 1.5.5 — 2026-11-06

### 中文

- 改善阅读返回提示的响应，减少返回详情与主页时的重复加载。
- 优化在线收藏、历史条目打开和漫画续读准备，保留取消与重试。
- 调整关于页更新选项布局，并更新主要功能介绍。
- 下载删除选项改为“删除整本”，明确只删除当前作品。

### English

- Improve reading-return feedback and reduce repeated work when restoring details and home.
- Improve online favorites, history entry loading and comic resume preparation while preserving cancellation and retry.
- Refine About-page update controls and refresh the feature overview.
- Clarify that the download deletion action removes the current book.

## 1.5.4 — 2026-11-06

### 中文

- 修复主页封面续读取消后详情信息和章节停留在加载占位的问题。
- 小说详情与目录同时加载，减少首次打开时的串行等待，并改善详情刷新效率。
- 取消目录加载后明确显示取消状态，支持手动重试；关闭页面后不再补载。
- 详情封面区仅保留底部分隔线，信息行去掉灰线，章节标题上下使用黑色细线。

### English

- Restore title information and chapters after cancelling a home-cover reading shortcut.
- Load novel details and chapters concurrently and reduce repeated request setup during metadata refresh.
- Show cancelled directory loading clearly, allow retries, and discard work after leaving the page.
- Simplify detail separators and frame the chapter heading with black horizontal rules.

## 1.5.3 — 2026-11-06

### 中文

- 七个源统一支持保存登录凭据和会话过期恢复，退出账号时清除；更新源后重新登录一次启用。
- 修复聚合搜索中不同来源的封面互相取消下载。
- 分类标签优先显示缓存，提供手动刷新，失败时保留已有内容。
- 小说阅读缓存纳入缓存限额，已下载小说和漫画仍独立保存，不受缓存限额影响。
- 新版成功启动后清理过期更新包，取消待更新版本也会清理对应文件。
- 改善低内存下的下一页图像预处理，增加翻页缓存诊断。

### English

- Unify expired-session recovery across all seven sources; sign in once after updating sources to enable it. Signing out removes saved credentials.
- Keep mixed-source cover downloads from cancelling each other.
- Cache category labels with manual refresh and retain existing labels on failure.
- Include novel reading caches in the cache quota while keeping downloaded books separate.
- Clean obsolete update payloads after a successful startup and remove cancelled updates.
- Reclaim idle reading workers before bounded next-page preprocessing and improve cache diagnostics.

## 1.5.2 — 2026-11-06

### 中文

- 作品详情加入缓存，返回时优先显示已有信息，后台按需更新。
- “刷新章节”改为“刷新信息”，同时更新详情与目录；刷新失败保留原有内容。
- 哔咔支持加密保存登录凭据，在会话过期时自动尝试恢复，并改善搜索失败提示。
- 更新插件后，请在源管理中将哔咔更新至 **1.1.5**，再重新登录一次以启用自动恢复。

### English

- Cache book details, show existing information first on return and refresh in the background as needed.
- Rename Refresh chapters to Refresh information, updating both details and the directory while retaining existing content on failure.
- Save Picacg login credentials encrypted, attempt recovery after session expiry and improve search failure messages.
- After updating the plugin, update Picacg to **1.1.5** in source management and sign in again to enable automatic recovery.

## 1.5.1 — 2026-11-05

### 中文

- 列表分隔线适当加深，仅用于内容列表；设置、菜单与按钮恢复原有样式。
- 修正启动日志中的版本标识，便于确认更新是否启用。

### English

- Darken content-list separators and restore the original styling of settings, menus and buttons.
- Log the active plugin version at startup for update verification.

## 1.5.0 — 2026-11-05

### 中文

- 支持同类全部源搜索，进度条等待结束后按相关性统一展示，超时保留已有结果并可重试未完成来源。
- 跨源打开作品保持阅读、收藏和下载的来源，返回原搜索结果，主页源不变。
- 所有列表统一白底与浅灰细线，聚合结果以方括号标明来源。
- 修复点击下载更新后的界面显示残缺，将恢复上一版入口移到自动检查开关下方。

### English

- Search all sources of the current content type with progress, ranked results, partial results on timeout, and retries for unfinished sources.
- Keep each book's source throughout reading, favorites and downloads while preserving the original home source and search return path.
- Use white list rows with subtle separators and bracketed source labels in search results.
- Fix incomplete display after confirming an update download and place rollback below automatic update checking.

## 1.4.5 — 2026-11-05

### 中文

- 更新准备完成后可选择立即重启 KOReader。
- 减少短时间内重复检查更新的请求。
- 改善更新提示重复打开和关闭后的处理。

### English

- Offer an immediate KOReader restart after an update has been prepared.
- Reduce repeated update requests within a short period.
- Improve handling of repeatedly opened and closed update prompts.

## 1.4.4 — 2026-11-05

### 中文

- 修复评论文字区域与行背景色不一致的问题。
- 补齐漫画及无正文目录的小说章节标题，支持状态栏显示。
- 调整缓存上限时保留当前存储页面，改善调低上限和清理失败时的处理。

### English

- Fix mismatched background colors between comment text areas and their rows.
- Supply chapter titles for comics and novels without an in-text directory so they can appear in the status bar.
- Keep the current storage page when adjusting the cache limit and improve handling of lower limits and cleanup failures.

## 1.4.3 — 2026-11-05

### 中文

- 修复部分 KOReader 版本在线更新误报存储空间不足的问题。
- 旧版若已被此提示阻挡，需要先手动安装本版一次。

### English

- Fix incorrect insufficient-storage errors during online updates on some KOReader versions.
- If this error has blocked an older version, install this version manually once.

## 1.4.2 — 2026-11-05

### 中文

- 将自动检查插件更新开关移到“关于”页，集中显示更新操作。
- 调整版本号与检查更新按钮布局，优化访问受限时的提示。

### English

- Move the automatic plugin update switch to About, keeping update actions together.
- Adjust the version and update-check button layout and improve access-restriction messages.

## 1.4.1 — 2026-11-05

### 中文

- 改善内存紧张时的漫画翻页与回翻，减少已有页面的重复处理。
- 详情页封面和作品信息区域改为白色背景。

### English

- Improve forward and backward comic paging under memory pressure and reduce repeated processing of existing pages.
- Use white backgrounds for the cover and book information areas on the detail page.

## 1.4.0 — 2026-11-04

### 中文

- 设置首页新增自动检查插件更新，默认关闭；关于页版本号旁可手动检查。
- 确认后下载更新，支持取消和失败重试，正常重启 KOReader 后启用。
- 新版首次启动未完成时尝试恢复上一版，关于页提供可用的上一版恢复入口。
- 首次使用插件自更新，需要先手动安装本版。源更新保持独立。

### English

- Add automatic plugin update checks to the settings home page, off by default; manual checks are available beside the version on About.
- Download updates after confirmation, with cancellation and retry support, and activate them after a normal KOReader restart.
- Attempt to restore the previous version if the new version's first startup does not complete, and provide an available rollback entry on About.
- Install this version manually before using plugin self-updates for the first time. Source updates remain separate.

## 1.3.4 — 2026-11-04

### 中文

- 阅读设置新增“自动下一章”，默认关闭；开启后漫画和小说可在章节结束时直接加载下一章。
- 改善下一页图像增强的预加载；灰度模式下，更多漫画可以提前准备下一页的增强效果。
- 优化大图阅读的性能与内存使用，减少内存不足时的不必要处理。
- 修复部分 WebP 图片因内存判断不准确而无法正常处理的问题。

### English

- Add Automatically open next chapter to reading settings, off by default; when enabled, comics and novels can load the next chapter at the end of the current one.
- Improve next-page enhancement preloading, allowing more comic pages to be prepared ahead in grayscale mode.
- Improve large-image reading performance and memory use, avoiding unnecessary work when memory is low.
- Fix some WebP images failing to process because of inaccurate memory estimates.

## 1.3.3 — 2026-11-04

### 中文

- 优化低内存下大WebP漫画的重复解码；后续预下载完成时重新评估下一页增强。
- 主页收藏、历史、已下载封面直接进入漫画或小说阅读，返回时再显示作品详情，减少进入前的额外等待。
- 图像增强选项备注补充“可能影响耗时”。
- 修复内存轻微波动导致下一页增强被提前取消或结果被丢弃的问题，改善顺序阅读时的提前准备。
- 减少息屏下载等待与离线页面的后台检查，暂停不可见的大图恢复运算和预加载；源更新保留6小时冷却，断网时不循环探测。修复跳到评论等列表的未完整缓存页时先出现半屏的问题。
- 阅读设置新增“息屏继续下载”，默认开启，也可选择息屏暂停。
- 断网时保留下载任务与已完成内容，联网或唤醒后继续；连续连接失败停止自动重试。
- 改善阅读及评论加载在息屏、断网后的恢复，修复小说预加载取消后切章一直等待的问题。

### English

- Reduce repeated decoding of large WebP comics under low memory and reconsider next-page enhancement after later predownloads complete.
- Open manga or novel reading directly from home favorites, history and downloaded covers, showing details on return to reduce initial waiting.
- Add a note that image enhancement may increase processing time.
- Prevent minor memory fluctuations from cancelling next-page enhancement too early or discarding its results, improving advance preparation during sequential reading.
- Reduce background checks while downloads wait with the screen off and on offline pages; pause invisible large-image recovery and preloading. Keep the six-hour source-update cooldown without repeated offline probes, and fix half-screen rendering when jumping to incompletely cached comment or other list pages.
- Add Continue downloading with screen off to reading settings, enabled by default, with the option to pause instead.
- Keep download tasks and completed content while offline and resume after reconnection or wake; stop automatic retries after repeated connection failures.
- Improve reading and comment-loading recovery after screen-off or network loss, and fix indefinite waiting when changing chapters after cancelling novel preloading.

## 1.3.2 — 2026-11-03

### 中文

- 漫画顺序阅读时可提前准备下一页增强效果，减少翻页等待。
- 加快大PNG图片及降噪、锐化、色调处理，降低小图放大的内存占用，保持增强效果。
- 改善部分特殊JPEG图片的显示兼容性；设备资源不足时自动跳过可选增强。
- 下载遇到图片地址失效时尝试恢复，保留已完成页面；修复下载通道异常后封面或图片一直等待的问题。
- 阅读设置补充小图放大与细节增强的关系说明。
- 更新后请正常退出并重新打开 KOReader。增强预处理受设备资源和阅读方式限制，不保证所有页面提前就绪。

### English

- Prepare next-page enhancement ahead during sequential comic reading to reduce page-turn waiting.
- Speed up large PNG processing, denoising, sharpening and tone adjustments, and reduce small-image upscaling memory use while preserving enhancement effects.
- Improve compatibility with some unusual JPEG images and automatically skip optional enhancements when device resources are insufficient.
- Attempt recovery from expired download image URLs while retaining completed pages; fix covers or images waiting indefinitely after download-channel errors.
- Explain the relationship between small-image upscaling and detail enhancement in reading settings.
- Exit and reopen KOReader normally after updating. Enhancement preprocessing depends on device resources and reading patterns; not every page is guaranteed to be ready in advance.

## 1.3.1 — 2026-11-03

### 中文

- 大图缩小显示时自动在显示尺寸上进行轻量保边降噪、锐化，减少等待；保留所选色调效果。
- 减少PNG大图重复处理，改善首次显示与连续翻页速度。
- 阅读设置的细节增强菜单新增“大图自适应加速”开关，默认开启，可关闭对照；更改后重新打开章节生效。
- 小图放大时更好地保留文字笔画与线条边缘，减少柔化与锐化光晕。
- 修复部分缩放与低内存局部绘制时的图像边缘不一致。
- 增强本身仍默认关闭，下载原图不变。更新后请正常退出并重新打开 KOReader。性能较弱的设备处理彩色图片时仍可能等待较久，可关闭细节增强。

### English

- Apply lightweight edge-preserving denoising and sharpening at display size when reducing large images, retaining the selected tone effect with less waiting.
- Reduce repeated processing of large PNG images to improve initial display and continuous paging.
- Add Adaptive acceleration for large images to detail enhancement settings, enabled by default and switchable for comparison; reopen the chapter after changing it.
- Preserve text strokes and line edges better when upscaling small images, with less softening and sharpening halo.
- Fix inconsistent image edges in some scaling and low-memory partial-rendering cases.
- Enhancement itself remains off by default and downloaded originals remain unchanged. Exit and reopen KOReader normally after updating. Color-image processing may still take longer on slower devices; detail enhancement can be disabled.

## 1.3.0 — 2026-11-02

### 中文

- 阅读设置新增漫画细节增强：锐化、降噪＋锐化，可与轻度加深、标准加深或柔和对比度叠加，保留下载原图。
- 增强选项内提供小字效果说明，切换后留在当前页面并立即更新勾选。
- 修复评论、漫画和小说列表跨批次翻页时出现半屏空白的问题，改善连续翻页与加载失败后的重试体验。
- 增强默认关闭；更改设置后重新打开章节生效。更新插件后请正常退出并重新打开 KOReader。

### English

- Add comic detail enhancement with sharpening or denoising plus sharpening, combinable with light darkening, standard darkening or soft contrast while preserving downloaded originals.
- Explain small-text effects in enhancement options and update selection marks immediately without leaving the page.
- Fix half-screen blanks when paging across batches in comment, manga and novel lists, improving continuous paging and retries after loading failures.
- Enhancement is off by default; reopen the chapter after changing settings. Exit and reopen KOReader normally after updating the plugin.

## 1.2.16 — 2026-11-01

### 中文

- 拷贝漫画支持在作品详情查看作品评论、翻页和长评论全文。
- 从漫画或小说阅读返回时复用已加载的作品详情，减少重复联网和加载提示。
- 快捷续读返回后，作品信息和章节目录在后台补齐，详情页保持可操作。
- 后台作品信息加载失败时提供页面内重试，保留已有目录、阅读进度和当前页码。
- 更新插件后，在“设置 → 源管理”更新拷贝源，并正常重启 KOReader。

### English

- Add Copymanga work comments on book details, with pagination and full text for long comments.
- Reuse loaded book details on return from manga or novel reading to reduce repeated requests and loading prompts.
- Complete book information and chapter lists in the background after returning from quick resume, keeping the detail page usable.
- Offer an in-page retry when background book information fails to load, retaining the existing directory, reading progress and current page.
- After updating the plugin, update the Copymanga source in Settings → Source management and restart KOReader normally.

## 1.2.15 — 2026-11-01

### 中文

- 减少联网加载与批量下载等待期间的后台检查，日常安装包默认关闭详细排障采样。
- 网络未连接或域名解析失败时，给出明确的检查提示。
- 减少挂起或取消后台加载时的界面等待。
- 改善部分大插图的加载与下载，内存或转码文件受限时尝试安全恢复；超出设备处理能力的图片仍可能失败。
- 轻之国度源升级为1.0.0，保留已有书架、下载和阅读进度。
- 升级插件后，在“设置 → 源管理”更新源并正常重启KOReader。

### English

- Reduce background checks during network loading and batch-download waits, and disable detailed troubleshooting sampling by default in regular installation packages.
- Show clear troubleshooting messages when disconnected or when domain-name resolution fails.
- Reduce interface waiting when suspending or cancelling background loading.
- Improve loading and downloading of some large illustrations, attempting safe recovery when memory or conversion-file limits are reached; images exceeding device capabilities may still fail.
- Upgrade the LightNovel source to 1.0.0 while retaining existing bookshelves, downloads and reading progress.
- After updating the plugin, update sources in Settings → Source management and restart KOReader normally.

## 1.2.14 — 2026-10-31

### 中文

- 本次发行包含自1.2.10以来的改动。
- 新增轻之国度小说源，支持图文阅读、在线书架、只读评论及站点授权范围内的下载。
- 修复哔哩轻小说搜索、目录和正文加载失败。
- 改善轻之国度长目录加载速度，收藏遇到断线时核对实际结果，减少误报失败。
- 轻小说文库收藏按最新收藏优先排列；评论缺少时间时省略时间显示。
- 缺少封面的作品显示标题文字。
- 修复漫画从历史续读后返回详情时作者、分类和简介缺失。
- 改善阅读进度同步期间的界面响应，减少打开与返回时的等待。
- 改善小说插图处理及下载重试，复用已完成文件并保留已有下载。少数大插图仍可能因设备内存不足无法处理。
- 升级插件后，在“设置 → 源管理”更新源并正常重启KOReader；轻之国度可通过“更新源（含新源）”安装。

### English

- This release includes changes since 1.2.10.
- Add the LightNovel source with illustrated reading, online bookshelves, read-only comments and downloads within the site's authorization limits.
- Fix Bilinovel search, directory and text loading failures.
- Speed up long LightNovel directories and verify the actual result after connection loss during favorites changes to reduce false failure reports.
- Show Wenku8 favorites newest first and omit comment timestamps when unavailable.
- Show title text for works without covers.
- Restore missing author, category and description information after resuming a comic from history and returning to details.
- Improve responsiveness during reading-progress synchronization and reduce waiting when opening or returning from pages.
- Improve novel illustration processing and download retries, reusing completed files and preserving existing downloads. Some large illustrations may still exceed device memory.
- After updating the plugin, update sources in Settings → Source management and restart KOReader normally; install LightNovel through Update sources (including new sources).

## 1.2.10 — 2026-10-30

### 中文

- 本次包含自 1.2.8 以来的改动。
- 小说阅读长按插图后，在大图页点击“保存插图”，选择目录即可另存；同名文件自动另存。退出阅读会取消未执行的保存。
- 图片等待内存自动恢复时显示“加载中…”，避免提前显示无法加载。
- 已知问题：刚进入章节后返回可能短暂停顿，后续版本继续优化。
- 下载下方 `picayomi.koplugin-1.2.10.zip`，解压到 KOReader 的 `plugins` 目录，正常重启 KOReader 后生效。

### English

- This release includes changes since 1.2.8.
- Long-press a novel illustration, then select Save illustration in the large-image view and choose a directory; existing filenames are preserved by saving a separate file. Leaving the reader cancels saves that have not started.
- Show Loading while an image waits for automatic memory recovery instead of reporting a display failure prematurely.
- Known issue: returning immediately after entering a chapter may briefly pause; later versions will continue improving this.
- Download `picayomi.koplugin-1.2.10.zip` below, extract it into KOReader's `plugins` directory and restart KOReader normally to activate it.

## 1.2.8 — 2026-10-29

### 中文

- 本次正式发行包含自 1.2.5 以来的下列改动；1.2.6、1.2.7 为中间开发版本，随本版合并发行。
- 修复从小说阅读返回 PicaYomi 后，KOReader 熄屏壁纸可能不显示的问题；恢复必要的原生底层界面，保留当前页面和 KOReader 原有壁纸设置。
- 1.2.7：小说大图处理在内存预算不足时复用已下载的数据，尝试更小尺寸；减少转码后的重复图片处理，WebP 转码也遵守内存预算。
- 1.2.7：无法处理的插图明确提示内存不足，不再只提示加载失败；保留已完成章节，不按限频反复重试。
- 1.2.7：“删除已读”和“删除全部”在同一行显示，取消单独一行。
- 1.2.7：修复主页直接续读后返回详情时作者、分类和简介缺失；返回后补齐信息，仍保留直接续读不等待完整目录的速度。
- 1.2.6：下载选择统一为“全选章节”，与“全选未读章节”并排显示，减少操作区高度。
- 1.2.6：删除下载弹窗提供“删除全部”和“删除已读”，保留未读与半读章节。
- 1.2.6：按源、作品和章节记录阅读完成状态，不根据章节先后推断已读；旧历史仅采用可确认的完成记录。
- 1.2.6：页面预览更新为当前主页。
- 升级前退出 KOReader，解压安装包并替换插件目录后重新打开。安装包请选择下方 `picayomi.koplugin-1.2.8.zip`，不要使用自动生成的 Source code 压缩包。

### English

- This release includes the following changes since 1.2.5; 1.2.6 and 1.2.7 were intermediate development versions included in this release.
- Fix KOReader's sleep wallpaper sometimes failing to appear after returning from novel reading to PicaYomi; restore the necessary native underlying interface while preserving the current page and wallpaper settings.
- Version 1.2.7: Reuse downloaded data and try smaller sizes when large novel illustrations exceed the memory budget; reduce repeated processing after conversion and apply the memory budget to WebP conversion as well.
- Version 1.2.7: Report insufficient memory explicitly for illustrations that cannot be processed, retain completed chapters and avoid repeatedly retrying these failures as rate-limit errors.
- Version 1.2.7: Put Delete read and Delete all on the same row, with Cancel on its own row.
- Version 1.2.7: Restore missing author, category and description information after home quick-resume returns to details, while retaining quick entry without waiting for the complete directory.
- Version 1.2.6: Use Select all chapters alongside Select all unread chapters to reduce the height of download controls.
- Version 1.2.6: Offer Delete all and Delete read in the download deletion dialog, preserving unread and partially read chapters when deleting read items.
- Version 1.2.6: Track completion by source, work and chapter rather than inferring it from chapter order; use only confirmed completion records from older history.
- Version 1.2.6: Update the page preview to show the current home page.
- Exit KOReader before upgrading, extract the package and replace the plugin directory before reopening it. Choose `picayomi.koplugin-1.2.8.zip` below, not the automatically generated Source code archive.

## 1.2.5 — 2026-10-29

### 中文

- 本次发布相对上一正式版 **1.2.0**，合并 **1.2.1～1.2.5** 的改动。各中间版本的变化如下。
- 1.2.5：原生 KOReader 阅读可在“操作与手势”中开启独立的边缘返回开关，默认关闭；开启后返回文件浏览器，支持快滑、慢拖和边缘范围设置。
- 1.2.5：存储检查计数每秒最多更新一次，仅刷新统计文字区域，避免按钮栏频闪；减少过细分段造成的调度开销，扫描中可点击返回或边缘滑动退出。
- 1.2.5：小说历史封面续读优先使用经过身份校验的章节记录直接打开正文，完整目录随后在后台补充；目录失败不打断当前阅读。缺少可靠章节身份的旧历史首次仍需核对目录。
- 1.2.5：修复详情关闭与主页返回同时触发时的重复关闭问题。
- 1.2.4：存储管理先展示页面再后台统计，支持重新统计和失败重试，返回后停止扫描。
- 1.2.4：阅读设置完整展示漫画和小说选项，不再随当前源隐藏内容。
- 1.2.4：固定文案过滤从阅读设置移除，具体规则在小说源内配置。
- 1.2.3：移除小说阅读工具页中与返回功能重复的“章节目录”按钮。
- 1.2.2：未完成的漫画和小说始终显示下载进度，包括刚开始、准备内容、等待和中断后的状态；完成后显示作品信息。
- 1.2.2：下载页“重试失败”改为“继续下载”。
- 1.2.2：统一列表页码和总项数格式，未知总量直接省略，页数上限明确标示。
- 1.2.1：修复切换内容源后搜索仍沿用旧源排序的问题。
- 1.2.1：下载清单保存失败时明确提示并允许重试，避免显示已完成却无法在重启后恢复；保留已下载文件。
- 1.2.1：降低小说批量下载频率；反复限频时逐步延长等待并放慢请求，稳定下载一段时间后再逐步恢复，避免短暂成功后立即恢复原速度。
- 1.2.1：主页收藏先显示账号隔离的缓存，并提示后台刷新；刷新失败保留原内容。
- 1.2.1：改善大量下载删除时的卡顿，先显示可取消的实际章节进度，移除删除页重复的返回按钮。
- 1.2.1：统一详情页封面与文字区域底色，修复透明封面周围的色块。
- 1.2.1：退出时取消延迟任务和下载页刷新，释放主页引用及内存缓存，保留已完成下载与用户数据。
- 升级后请正常退出并重新打开 KOReader；保留数据目录以继续使用已有账号、设置、收藏、历史和下载。下载下方 `picayomi.koplugin-1.2.5.zip`，解压后复制 `picayomi.koplugin` 到 `koreader/plugins/`。

### English

- This release combines changes from **1.2.1–1.2.5** since the previous formal release, **1.2.0**. The intermediate version changes are listed below.
- Version 1.2.5: Add an independent edge-return switch under native KOReader Actions and gestures, off by default; when enabled, return to the file browser with support for quick swipes, slow drags and edge-range settings.
- Version 1.2.5: Update storage scan counts at most once per second and refresh only the count text to avoid button-bar flicker; reduce overly fine scheduling and allow return or edge-swipe exit during scanning.
- Version 1.2.5: Resume novels from history covers using verified chapter identities before completing the directory in the background; directory failures do not interrupt reading, while older history without reliable chapter identities still requires an initial directory check.
- Version 1.2.5: Fix duplicate close operations when closing details and returning home are triggered together.
- Version 1.2.4: Show storage management before scanning in the background, support rescanning and retry after failure, and stop scanning on return.
- Version 1.2.4: Show all manga and novel reading options regardless of the current source.
- Version 1.2.4: Remove fixed-text filtering from reading settings; configure specific rules within novel sources.
- Version 1.2.3: Remove the redundant Chapter directory button from novel reading tools.
- Version 1.2.2: Always show download progress for unfinished manga and novels, including starting, preparing, waiting and interrupted states; show work information after completion.
- Version 1.2.2: Rename Retry failed to Continue downloading.
- Version 1.2.2: Standardize list page and total-item formats, omit unknown totals and label page-count upper bounds explicitly.
- Version 1.2.1: Fix searches retaining the previous source's sorting after switching sources.
- Version 1.2.1: Report download-manifest save failures and allow retries rather than showing completion that cannot survive a restart; retain downloaded files.
- Version 1.2.1: Slow novel batch downloads and progressively extend waits after repeated rate limits; recover speed gradually after sustained success rather than immediately after a brief success.
- Version 1.2.1: Show account-isolated cached favorites on home first with a background-refresh notice, retaining content on refresh failure.
- Version 1.2.1: Reduce pauses during bulk download deletion, show cancellable progress based on actual chapters first and remove the duplicate Back button.
- Version 1.2.1: Unify detail cover and text backgrounds and fix color blocks around transparent covers.
- Version 1.2.1: Cancel delayed tasks and download-page refreshes on exit, releasing home references and memory caches while retaining completed downloads and user data.
- Exit and reopen KOReader normally after upgrading, preserving the data directory for existing accounts, settings, favorites, history and downloads. Download `picayomi.koplugin-1.2.5.zip` below and copy the extracted `picayomi.koplugin` into `koreader/plugins/`.

## 1.2.0 — 2026-10-29

### 中文

- 重新设计主页：顶部切源与账号同行，收藏、历史和已下载提供可点击封面预览，底栏统一为设置、搜索、退出。
- 横屏预览分列，最新、推荐、排行和分类入口利用剩余空间自动排布；大屏按尺寸缩放，小屏依次收起下载、历史、收藏封面，保留全部文字入口。
- 封面之间保留间距，底部裁切及右侧溢出使用渐变；标题进入列表，封面直接开始或继续阅读。阅读返回详情，详情返回原主页；从列表进入时仍返回原列表。
- 顶部源入口左对齐，增加漫画源／小说源前缀和右箭头；支持登录的源未登录时显示“登录”。
- 主页先显示，再异步补充线上收藏与封面；切源、切账号或离开页面时停止旧任务。
- 列表“继续阅读”直接进入阅读器，不先展示详情；退出阅读后显示详情，再返回原列表。准备失败、取消或历史章节不可用时保留可操作的详情页。
- 点击搜索、历史或取消即释放搜索框；从历史、搜索结果或阅读返回时，不再重新弹出已关闭的输入框。
- 提交非空关键词立即保存历史，失败、超时、异常、取消请求或零结果也会保留；空白输入不保存。
- 修复新加载的主页封面未及时显示；清理图片或全部缓存后，源可访问时重新补齐封面，断网失败后再次进入主页可重试。
- 设置返回时刷新主页预览，避免删除下载后仍显示旧封面。缓存清理继续保留收藏、阅读进度及主动下载的内容。
- 减少已有封面的重复刷新；下载较多时只选取预览所需数据，不再为几张预览统计全库章节进度。
- 返回主页复用线上收藏预览和已缓存封面，登录变化或收藏变更后更新；打开其他源的下载不再改变主页选择的源。
- 只有服务端末页、尚无准确条数时，列表与跳页提示显示“最多”页数；获得准确总量后显示准确页数，避免短末页导致页数被夸大。
- 列表同一条目的标题、元信息、封面占位、透明区域、续读按钮与留白保持统一底色，保留隔行配色及封面原有不透明像素。
- 小说下载入口和列表保持小说分区，显示已完成章数、失败数及正文、插图、保存或等待阶段；只有所选章节全部完成才显示完成。
- 重试时区分已经完成、仍在队列中和真正失败的章节，及时刷新旧按钮；减少长篇离线小说进入目录和继续阅读的等待。
- 小说后台下载增加请求间隔与失败后的等待，连续失败时暂停对应源，保留已下载内容供稍后重试。
- 改善小说正文异常格式的兼容与插图下载恢复；阅读返回时立即显示等待提示，并直接回到详情页。
- 切回其他源时复用线上收藏列表，登录状态或收藏变更后更新；哔咔收藏登录失效时明确提示重新登录。
- 修复哔哩搜索仅命中一本书时的结果处理；合并多个订阅重复的“已是最新”提示。
- 退出 PicaYomi 时停止下载及封面任务，保留已完成内容；再次进入后可手动重试未完成章节。
- 升级后请正常退出并重新打开 KOReader；保留数据目录以继续使用已有账号、设置、收藏、历史和下载。

### English

- Redesign home with source and account controls on one top row, clickable cover previews for favorites, history and downloads, and Settings, Search and Exit along the bottom.
- Use columns for landscape previews and arrange latest, recommendations, rankings and categories in the remaining space; scale for larger screens and progressively hide download, history and favorites covers on smaller screens while retaining all text entries.
- Keep space between covers and fade clipped bottom or right edges; titles open lists and covers start or resume reading. Return from reading to details and then the original home or list.
- Left-align the source entry, adding a manga/novel prefix and right arrow; show Sign in for supported sources when signed out.
- Show home first and load online favorites and covers asynchronously, stopping old tasks when switching sources, accounts or leaving the page.
- Open Continue reading directly in the reader, then show details on exit and return to the original list; keep usable details if preparation fails, is cancelled or the historical chapter is unavailable.
- Release the search box on search, history selection or cancellation; do not reopen a closed input box when returning from history, results or reading.
- Save nonempty search terms immediately, including requests that fail, time out, throw errors, are cancelled or find no results; do not save blank input.
- Fix newly loaded home covers failing to appear promptly; restore covers after image or full-cache cleanup when the source is reachable, with another attempt on re-entry after offline failure.
- Refresh home previews on return from settings so deleted downloads do not leave stale covers; cache cleanup still preserves favorites, reading progress and explicitly downloaded content.
- Reduce repeated refreshes of existing covers and select only preview data when many downloads exist, avoiding full-library chapter counts for a few previews.
- Reuse online favorites previews and cached covers on return home, refreshing after login or favorite changes; opening another source's download no longer changes the home source.
- Show At most for page counts only on the server's final page when the exact item count is unknown; use accurate page counts when known and avoid overestimates from short final pages.
- Keep a consistent background across each item's title, metadata, cover placeholder, transparent areas, resume button and whitespace while retaining alternating row colors and opaque cover pixels.
- Keep novel download entries and lists in the novel section, showing completed chapters, failures and text, illustration, saving or waiting stages; mark complete only when every selected chapter finishes.
- Distinguish completed, queued and failed chapters when retrying, refresh stale buttons promptly and reduce waits when opening long offline novel directories or resuming reading.
- Space novel background-download requests and wait after failures; pause the affected source after repeated failures while retaining completed content for later retries.
- Improve compatibility with unusual novel text formatting and illustration download recovery; show waiting feedback immediately on return from reading and go directly to details.
- Reuse online favorites lists when switching back to a source and refresh after login or favorite changes; ask users to sign in again explicitly when Picacg favorites authentication expires.
- Fix Bilinovel searches with exactly one result and combine duplicate Already up to date notices from multiple subscriptions.
- Stop download and cover tasks when exiting PicaYomi while retaining completed content; allow manual retry of unfinished chapters after re-entry.
- Exit and reopen KOReader normally after upgrading; preserve the data directory to keep accounts, settings, favorites, history and downloads.

## 1.1.8 — 2026-10-28

### 中文

- 源仓库更名为 PicaYomi Sources，统一提供漫画与小说源。
- 更新默认订阅地址、源仓库入口和使用文档；小说源仍为 1.0.0。
- 升级后请正常重启 KOReader。如果源管理中仍有旧订阅，请移除旧项；保留新的 PicaYomi 漫画与小说源订阅。没有订阅时点击“恢复默认订阅”，再执行“更新源（全部订阅）”。本版不自动迁移旧订阅地址。

### English

- Rename the source repository to PicaYomi Sources, providing manga and novel sources together.
- Update the default subscription address, source repository entry and documentation; novel sources remain at 1.0.0.
- Restart KOReader normally after upgrading. Remove old subscriptions if still present and retain the new PicaYomi manga and novel subscription. If no subscription exists, select Restore default subscription, then Update sources (all subscriptions). This version does not migrate old subscription addresses automatically.

## 1.1.7 — 2026-10-28

### 中文

- 更新后请正常退出并重新打开 KOReader；在“设置 → 源管理 → 更新源（全部订阅）”安装小说源。
- 新增轻小说文库与哔哩轻小说，支持图文阅读、前后章切换、字体排版调整和阅读进度恢复。
- 支持小说离线下载和后续 0～5 章预加载（默认 1 章）。
- 小说分类优先展示题材，详情补充作者、标签、字数及更新信息。
- 统一页面操作与滑动返回，改善长目录加载、取消和退出阅读的等待提示。
- 改善漫画内存紧张后的恢复，以及小说短暂断线和插图超时后的重试。
- 修复清缓存后跨源下载封面无法加载、小说续读目录及分页问题。
- 改善下载删除与清单保存失败后的重试。
- 轻小说文库部分浏览与书架功能需要个人账号。哔哩轻小说搜索可能受站点验证限制，在线书架暂不支持；可使用分类浏览与本地收藏。评论仅供查阅，不支持发表。

### English

- Exit and reopen KOReader normally after updating; install novel sources through Settings → Source management → Update sources (all subscriptions).
- Add Wenku8 and Bilinovel with illustrated reading, previous/next chapter navigation, font and layout controls, and reading-progress restoration.
- Support offline novel downloads and preloading of zero to five following chapters, with one by default.
- Prioritize genres in novel categories and add author, tags, word count and update information to details.
- Unify page actions and swipe-to-return, improving waiting feedback for long directories, cancellation and leaving the reader.
- Improve comic recovery under memory pressure and retries after brief novel disconnections or illustration timeouts.
- Fix cross-source download covers failing after cache cleanup, novel resume directories and pagination issues.
- Improve retries after download deletion and manifest-save failures.
- Some Wenku8 browsing and bookshelf features require a personal account. Bilinovel search may encounter site verification and online bookshelves are unsupported; use categories and local favorites instead. Comments are read-only and cannot be posted.

## 1.0.2 — 2026-10-26

### 中文

- 本版新增漫画列表续读、当前页原图另存与顶部下拉菜单，并修复长按放大闪退和图片断线恢复。更新后需正常退出并重新打开 KOReader。
- PicaYomi 主页、漫画列表、详情、分类和设置等全屏页面支持从顶部向下拉出 KOReader 原生菜单，查看时间、电量并使用宿主设置与插件入口。关闭菜单保留当前页面和位置；此时工具栏原有“Picayomi”入口改为“退出 Picayomi”，退出后回到 KOReader 书籍页，三横线主菜单不额外增加插件返回项。切换到原生历史、书籍或其他插件时清理旧 PicaYomi 页面，避免返回时残留。输入及确认弹窗保留自身操作边界，插件外仍保留正常启动入口。
- 漫画阅读的“工具”菜单新增“保存当前页原图”，排列在上一话、下一话之后：选择保存目录并记住上次成功位置，保存源提供的完整图片，不带状态栏，不受阅读缩放、旋转或黑白显示影响；同名文件自动另存。需要显示时还原的图片会按原尺寸还原后无损保存为 PNG，内存不足或处理失败会提示且不留下半成品。该入口仅对明确标记为漫画的阅读会话显示，文本及未来轻小说阅读不显示。
- 漫画列表有阅读历史的条目右上角新增“继续阅读”。首页、搜索、分类/排行、收藏、历史、已下载和详情内检索结果共用该入口；点击后先保留漫画详情，再自动恢复历史章节与页码。退出阅读回到该详情页，再返回原列表；章节加载失败、取消或历史章节不可用时留在详情，不误从第一章开始。
- 收敛阅读返回入口：三横线菜单不再显示重复的“返回 xx 漫画/源”，工具栏“返回 Picayomi”统一负责退出阅读并回到原详情及列表，恢复详情页的继续阅读与章节操作状态。
- 修复主页向下滑动误触发通用菜单关闭、进而退出 PicaYomi 的问题。顶部下拉打开宿主菜单，页面中部竖划不再关闭主页；左右翻屏和边缘返回继续使用原有规则。
- 修复漫画阅读开启“分格放大”后，长按页面调用缺失的 `getPanelFromPage` 接口导致 KOReader 闪退的问题。流式漫画以整页图片视图回退，支持缩放和平移；暂不自动识别漫画分格，未下载页面不打开占位图。
- 改善息屏恢复或网络中断后的图片连接恢复：过期的空闲连接与 DNS 缓存会被清除，TLS 建连时遇到连接关闭或重置最多重新连接一次；并发图片下载也能恢复失效的复用连接。重试保留原任务计时，部分图片不会与重试响应拼接；证书或协议错误仍会报告，保持 HTTPS。
- 保存原图：在漫画阅读页打开顶部菜单，进入“工具 → 保存当前页原图”，位于上一话、下一话之后；选择目录并确认。保存源提供且已下载的当前页图片，不额外请求更高画质；文本和轻小说阅读不显示此项。
- 放大漫画：在阅读菜单“排版 → 面板缩放（漫画）”中开启“允许面板缩放”，再长按图片进入整页图片视图，用双指缩放、拖动平移。本版回退整页放大，不自动识别分格。
- 在 PicaYomi 全屏页面从顶部下拉打开 KOReader 菜单；“工具 → 退出 Picayomi”回到书籍页。漫画阅读中的“返回 Picayomi”仅退出阅读并回到原详情。
- 下载附件 `picayomi.koplugin-1.0.2.zip`，解压后将 `picayomi.koplugin` 复制到 `koreader/plugins/`，正常退出并重新打开 KOReader；更新时保留 KOReader 数据目录。`SHA256SUMS` 用于核对下载文件。正式安装包关闭高频诊断日志，保留关键运行与错误日志。

### English

- Add comic-list resume, saving the current original page and top pull-down menus; fix long-press zoom crashes and recovery after image connection failures. Exit and reopen KOReader normally after updating.
- Pull down from the top of PicaYomi full-screen home, lists, details, categories and settings to open KOReader's native menu for time, battery, settings and plugins. Closing it preserves the page and position; the toolbar's Picayomi entry becomes Exit Picayomi and returns to the KOReader book, without another plugin-return item in the main menu. Switching to native history, books or other plugins clears old PicaYomi pages. Input and confirmation dialogs retain their own boundaries, and the normal launcher remains available outside the plugin.
- Add Save current original page after the chapter-navigation entries in comic reading tools. Choose a directory, remember the last successful location and save the complete source image without the status bar or reading zoom, rotation or grayscale effects; existing filenames are preserved by saving separately. Images requiring reconstruction are saved losslessly as PNG at their original size; memory or processing failures show an error without leaving partial files. This entry appears only in explicitly identified comic sessions, not text or future novel reading.
- Add Continue reading at the top right of comic-list entries with history, shared by home, search, categories/rankings, favorites, history, downloads and detail search. Keep details available, restore the historical chapter and page, and return through details to the original list. Failed, cancelled or unavailable historical chapters leave the user on details rather than incorrectly starting at chapter one.
- Consolidate reading return actions: remove duplicate source-return entries from the main menu and use toolbar Return to Picayomi to return to original details and lists, restoring resume and chapter controls.
- Fix downward swipes on home accidentally closing the general menu and exiting PicaYomi. Pulling from the top opens the native menu; vertical swipes in the middle no longer close home, while horizontal paging and edge-return retain their rules.
- Fix KOReader crashes when long-press panel zoom calls the missing `getPanelFromPage` interface. Streamed comics fall back to a whole-image view with zoom and pan; panels are not detected automatically and undownloaded pages do not open placeholders.
- Improve image connections after wake or network interruption by clearing stale idle connections and DNS caches; retry TLS establishment once after connection closure or reset and recover invalid reused connections in concurrent downloads. Keep the original task timing, do not combine partial images with retry responses, and continue reporting certificate or protocol errors while retaining HTTPS.
- Save originals through the comic reading top menu under Tools → Save current original page, after previous/next chapter. Choose and confirm a directory. Save only the source-provided, already downloaded current image without requesting higher quality; this action is absent in text and novel reading.
- Enable Allow panel zoom under the reading menu's Typesetting → Panel zoom (comics), then long-press an image for the whole-image view with pinch zoom and drag-to-pan. This version uses whole-page zoom without automatic panel detection.
- Pull down from the top of PicaYomi full-screen pages to open KOReader's menu; Tools → Exit Picayomi returns to the book. Return to Picayomi in comic reading leaves only the reader and returns to original details.
- Download `picayomi.koplugin-1.0.2.zip`, extract and copy `picayomi.koplugin` into `koreader/plugins/`, then exit and reopen KOReader normally; retain the KOReader data directory when updating. Use `SHA256SUMS` to verify downloads. The formal package disables frequent diagnostic logging while retaining key runtime and error logs.

## 1.0.1 — 2026-10-24

### 中文

- 修复绅士漫画搜索分页异常：搜索页按 24 条处理，末页保留正确总页数，零结果正常显示未找到提示。请在源管理更新绅士源至 1.1.5 后正常重启 KOReader。
- 搜索历史支持长按关键词删除。删除前弹出确认，取消保留记录；确认仅删除所选关键词。
- 下载附件 `picayomi.koplugin-1.0.1.zip`，解压后将 `picayomi.koplugin` 复制到 `koreader/plugins/`，正常重启 KOReader。升级前建议备份重要数据；校验值见 `SHA256SUMS`。GitHub 自动生成的 Source code ZIP 不是安装包。
- 特殊大图受设备内存和图像格式限制。

### English

- Fix Htcomic search pagination by using 24 results per page, retaining the correct final-page count and showing the no-results message correctly. Update the Htcomic source to 1.1.5 in source management and restart KOReader normally.
- Delete a search-history term by long-pressing it. Cancellation preserves the entry; confirmation removes only the selected term.
- Download `picayomi.koplugin-1.0.1.zip`, extract and copy `picayomi.koplugin` into `koreader/plugins/`, then restart KOReader normally. Back up important data before upgrading and use `SHA256SUMS` for verification. GitHub's automatically generated Source code ZIP is not an installation package.
- Some large images remain limited by device memory and image formats.
