# PicaYomi

面向 Kindle 等设备的 [KOReader](https://github.com/koreader/koreader) 漫画阅读插件。支持浏览、搜索、流式阅读、章节下载、收藏、阅读历史与墨水屏设置；可用功能由独立漫画源决定。

## 安装

将插件安装 ZIP 中的 `picayomi.koplugin` 目录复制到 KOReader 的 `plugins/` 下，重启 KOReader，从工具菜单打开 PicaYomi。源码 ZIP 需解压后将含 `main.lua` 的目录改名为 `picayomi.koplugin`；不要把仓库外层目录套进插件目录。

插件不附带漫画源或在线订阅。前往 [PicaYomi_MangaSources](https://github.com/UFOAlastor/PicaYomi_MangaSources) 获取独立 `.pysource`，进入设置 → 源管理 → 导入源包，长按选文件，确认发布者并重启 KOReader。源是可执行代码，仅安装可信来源。首次导入历史源时会另外提示其账号和阅读数据的访问权限。

## 阅读与数据

按源要求登录，浏览作品并选择章节。图片模式默认跟随 KOReader，也可在阅读设置中选择始终黑白以节省内存。在线缓存与主动下载分开；离线阅读请先下载完整章节。超大图片在设备内存不足时仍可能无法打开。

更新时退出 KOReader，替换插件目录并重启。设置、账号、收藏、历史和下载保存在 KOReader 数据目录；保留数据目录，重要数据先备份。源更新独立于插件，安装或切换版本后重启生效。

## 反馈与技术资料

反馈请提供插件版本、KOReader 版本、设备、源版本、复现步骤与脱敏报错。当前以 Kindle 为主要适配目标；完整账号场景和新版 Kindle 长时间阅读验证仍待完成。

- [诊断开关](docs/DEBUG.md)
- [低内存图片阅读设计](docs/IMAGE_MEMORY.md)
- [源 SDK、模板与制作资料](https://github.com/UFOAlastor/PicaYomi_MangaSources)
- [第三方来源与许可证状态](THIRD_PARTY.md)

此仓库仅接收经过筛选的发布快照，使用独立历史，不携带私有开发仓库历史。当前为私有发布流程预演；仓库开放和正式发行由维护者另行决定。

感谢 [PicaComic](https://github.com/Pacalini/PicaComic)、[rakuyomi](https://github.com/hanatsumi/rakuyomi) 和 KOReader 提供的设计参考。
