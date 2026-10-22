# PicaYomi

面向 Kindle 等设备的 [KOReader](https://github.com/koreader/koreader) 漫画阅读插件。支持多源浏览、搜索、流式阅读、章节下载、收藏和阅读历史，针对墨水屏提供刷新、版式与内存管理设置。

当前插件版本：**0.11.2**。漫画源独立分发，可用功能及最低插件版本由各源决定。

## 安装

设备需已安装并能正常运行 KOReader。

1. 通过仓库的 **Code → Download ZIP** 下载源码，解压后找到直接包含 `main.lua` 和 `_meta.lua` 的目录。
2. 将该目录重命名为 `picayomi.koplugin`，复制到 KOReader 的 `plugins/` 目录。若使用已提供的插件安装包，直接复制其中的同名目录即可。
3. 确认目录结构为 `koreader/plugins/picayomi.koplugin/main.lua`，避免额外套一层文件夹。
4. 重启 KOReader，从“工具”菜单打开 PicaYomi。插件为 Lua 代码，无需编译。

Kindle 上请复制真实文件夹，不使用符号链接。

## 安装漫画源

插件不附带漫画源或默认在线订阅。前往 [PicaYomi MangaSources](https://github.com/UFOAlastor/PicaYomi_MangaSources) 下载所需的 `.pysource` 文件，然后进入 **设置 → 源管理 → 导入源包**，长按选中文件，核对发布者并确认信任，最后重启 KOReader。

首次导入哔咔、禁漫或绅士漫画源时，会提示该源可以使用对应的历史账号、收藏和阅读数据。源包可以执行设备代码，请只安装可信来源的文件。

## 使用

- **浏览与登录**：切换漫画源，按其要求登录，再通过推荐、最新、分类、排行或搜索查找作品。页面只显示当前源支持的入口。
- **在线阅读**：打开作品详情并选择章节。页面按需下载，翻页、缩放及条漫滚动沿用 KOReader 的操作。
- **离线阅读**：在详情页选择章节下载，完成后从“已下载”打开。在线阅读缓存可能被清理，请使用主动下载保存离线内容。
- **图片模式**：默认跟随 KOReader 和设备屏幕能力；可在“设置 → 阅读设置 → 图片模式”选择“始终黑白”以减少内存占用。修改后重新打开章节生效。
- **收藏与历史**：按源能力使用源站收藏或本地收藏，通过阅读历史继续上次进度。

## 更新与卸载

更新插件时退出 KOReader，用新版 `picayomi.koplugin` 替换旧插件目录，再启动 KOReader。设置、账号、收藏、历史和下载保存在 KOReader 数据目录中；替换插件时保留该数据目录，重要数据建议先备份。

源版本独立于插件，在源管理中安装或更新后重启生效。历史三源已有安装的更新需要绑定签名订阅；目前没有预置的签名订阅地址，详见[源仓库说明](https://github.com/UFOAlastor/PicaYomi_MangaSources)。

卸载时退出 KOReader，移除 `plugins/picayomi.koplugin` 后重启。移除插件目录不会自动清除保存在 KOReader 数据目录中的阅读数据。

## 常见问题与限制

- **首页没有漫画源**：先安装独立源包并重启 KOReader。
- **Wi-Fi 已连接但加载失败**：检查源站可访问性、源版本及登录状态；网络连接不等于源站可用。
- **彩色设备仍为黑白**：检查 KOReader 的彩色设置及插件图片模式，退出章节后重新打开。
- **大图无法打开**：超长图和设备内存不足仍可能导致加载失败；较大的渐进式 JPEG 存在低内存限制。
- **设备与账号兼容**：主要适配 Kindle，其他设备需要实际验证；部分账号功能尚缺完整验证，具体限制以对应源的说明为准。

## 问题反馈与文档

请通过 [Issues](https://github.com/UFOAlastor/koreader_PicaYomi/issues) 提供插件版本、KOReader 版本、设备型号、源名称与版本、复现步骤及报错信息。发布版本默认关闭诊断日志，需要排查时按下面的说明临时开启；分享日志前删除账号、会话和个人阅读内容。

- [诊断日志](docs/DEBUG.md)
- [低内存图片阅读设计](docs/IMAGE_MEMORY.md)
- [漫画源 SDK、模板与制作指南](https://github.com/UFOAlastor/PicaYomi_MangaSources)
- [代码来源与许可证状态](THIRD_PARTY.md)

感谢 [PicaComic](https://github.com/Pacalini/PicaComic)、[rakuyomi](https://github.com/hanatsumi/rakuyomi) 和 KOReader 提供的设计参考。

## 免责声明

本项目仅供学习、研究与技术交流，不内置漫画内容，也不提供内容托管服务。作品版权归原作者及相关权利人所有，请支持正版，勿下载、传播或分享未经授权的资源；误获取的盗版资源请立即删除，临时测试文件请于下载后 24 小时内清理。该时限不构成版权授权或免责依据。使用者应遵守所在地法律法规及内容平台的使用规则，并自行承担使用行为产生的责任。
