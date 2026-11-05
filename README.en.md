# PicaYomi

[简体中文](README.md)

A manga and novel reader plugin for [KOReader](https://github.com/koreader/koreader), designed primarily for Kindle and other e-ink devices. It supports multiple sources, search, streaming, manga image enhancement, chapter downloads, favorites, and reading history.

**The plugin interface currently supports Chinese only.** This page is an introduction; the [Chinese README](README.md) contains the full user guide. Compatibility with devices other than Kindle needs testing.

**Sources: [PicaYomi Sources](https://github.com/UFOAlastor/PicaYomi_Sources)** · [Default subscription](https://raw.githubusercontent.com/UFOAlastor/PicaYomi_Sources/main/packages/index.json)

## Preview

| Home | Manga details | Novel details | Novel reading |
|---|---|---|---|
| ![Home](docs/screenshots/home.png) | ![Manga details](docs/screenshots/detail.png) | ![Novel details](docs/screenshots/novel-detail.png) | ![Novel reading](docs/screenshots/novel-reader.png) |


## Installation

1. Install and verify KOReader on your device.
2. Download **`picayomi.koplugin-<version>.zip`** from the [latest release](https://github.com/UFOAlastor/koreader_PicaYomi/releases/latest).
3. Extract it and copy the **`picayomi.koplugin`** folder into **`koreader/plugins/`**.
4. Restart KOReader, tap the top of the screen to open the menu, select the **crossed wrench and screwdriver icon (Tools / 工具)**, then tap **Picayomi**.

The screenshot below shows the plugin entry. Other menu items may vary by device and installed plugins.

<img src="docs/screenshots/koreader-tools.png" alt="Picayomi entry in the KOReader Tools menu" width="360">

Use the plugin ZIP attached to the release. GitHub's automatically generated “Source code” archives are source snapshots.

## Getting started

Select a source on the home page and sign in if the source requires it. Supported sources remember your login and try to recover expired sessions; signing out removes saved credentials. Sign in once after updating sources to enable recovery. Open a title to read online or use 下载章节 (Download chapters) to save chapters for offline reading. Offline chapters are available from 已下载 (Downloaded) on the home page. Downloads pause while reading and resume when you leave the reader. Settings → Reading settings → 息屏继续下载 (Continue downloading with the screen off) is enabled by default and controls explicitly requested chapter downloads; disable it to pause until the screen wakes and the network is available. OS deep sleep may still pause downloads. Disconnection preserves queued tasks for reconnection or wake; repeated connection failures stop automatic retries and can be retried from Downloaded. Exiting PicaYomi stops all downloads and keeps saved chapters; retry incomplete chapters from Downloaded.

The home page places source selection and account access at the top, with Settings, Search, and Exit at the bottom. Favorites, History, and Downloaded show cover previews: tap a heading to open its list, or a cover to start or resume reading. Leaving the reader shows details, then returns to the original home page. Continue Reading in a list opens the reader directly; leaving it shows details, then returns to that list. Landscape layouts reuse available space. On smaller screens, download, history, and favorite previews are hidden in that order while text actions remain visible, without scrolling or pagination.

Sources are managed under 设置 → 源管理 (Settings → Source management). The default subscription is already configured. Automatic source update checks are disabled by default; when enabled, downloading an update still requires confirmation. A successful check prevents another automatic check for six hours; manual checks remain available. Source changes take effect after restarting KOReader.

Check for plugin updates beside the version number in Settings → About. After confirming the download, restart KOReader normally to activate it. Enable automatic plugin update checks below the version row on the same page; they are off by default, and downloads still require confirmation. Failed or cancelled downloads leave the running version intact. An incomplete first startup triggers recovery, and About offers a previous-version recovery option when available. Manual installation remains available if your KOReader version does not support online installation.

Choose the current source or all sources of the current manga or novel type. Results appear together, ranked by relevance, after the search finishes. Timeouts preserve collected results; unfinished sources can be retried. Each result shows its source, and reading from another source keeps your home source and search return path. Search, History, and Cancel close the search input. Returning from search history or results goes back to the calling page. Every nonempty submitted keyword is saved to search history, including failed requests, timeouts, and searches with no results.

Long-press an illustration, tap **保存插图 (Save illustration)** in the image viewer, and choose a folder to save it.

**Manga display enhancement**: choose sharpening or denoise + sharpening in Settings → Reading settings to reduce noise and emphasize text and line edges; combine it with darkening or gentle contrast. Detail enhancement and tone adjustment are off by default. Small images can be upscaled to fit the screen while preserving edges, independently of detail enhancement; large images support adaptive acceleration. With preloading enabled, PicaYomi also tries to prepare enhancement for the next page before you turn to it. Enhancement may still add waiting time, and some images may skip it when resources are limited. Gentle contrast changes grays and shadows, so you may prefer to leave it off. Downloaded originals are preserved; reopen the chapter after changing these settings.

Novels support illustrated novel reading, chapter navigation, typography settings, resume, offline downloads, and configurable chapter preloading (0–5 chapters, default 1). Install **Wenku8**, **BiliNovel**, or **轻之国度 (LightNovel)** from Settings → Source Management → Update Sources (all subscriptions), then restart KOReader. You can also choose Update Sources (including new sources) in the default subscription. If the plugin version is incompatible, update the plugin from [Releases](https://github.com/UFOAlastor/koreader_PicaYomi/releases/latest) first. Wenku8 browsing requires a personal account; BiliNovel search may be blocked by site verification and its online bookshelf is unavailable. LightNovel supports a personal online bookshelf and read-only comments; use your own site account and follow its download access requirements. Local favorites remain available.

**Automatic next chapter**: enable **设置 → 阅读设置 → 自动下一章** (Settings → Reading settings → Automatic next chapter) to continue to the next chapter without the end-of-chapter prompt. It works for manga and novels and is off by default. If loading fails, retry using manual chapter navigation.

**Manga preloading**: **提前加载页数** (Pages to preload) defaults to 3 pages and supports 0–9; 0 turns it off. It downloads upcoming images and, when detail enhancement is enabled, tries to prepare the next page's enhanced image too.

**Title comments**: supported sources show comments on the details page. Tap to read the full text; access to full text and replies depends on the source and login status. Copymanga supports title comments. Posting comments and chapter comments are not available.

**Storage management**: **设置 → 存储管理** shows manga and novel cache and download usage. Clear caches or delete downloads separately; clearing caches keeps explicitly downloaded chapters and reading progress. Novel fixed-text filters can be edited in reading settings or the source settings and apply when you reopen a chapter.

See [Releases](https://github.com/UFOAlastor/koreader_PicaYomi/releases) and the [Chinese changelog](CHANGELOG.md) for version changes and upgrade notes.

To update the plugin, exit KOReader, replace the plugin folder with the new release, and restart. Keep the KOReader data directory to preserve accounts, settings, favorites, history, and downloads; back up important data first.

For ordinary KOReader books, enable **设置 → 操作与手势 → 原生 Reader 边缘返回** (Native Reader edge back, off by default). Swipe inward from an allowed edge to save your reading position and return to the file browser. This switch is independent; reading inside PicaYomi still returns to the work details.

Chapter selection offers **Select all chapters** and **Select unread chapters** on the same row. The download deletion dialog offers **Delete all** and **Delete read**. Partially read chapters and older history without confirmed completion are preserved by Delete read.

## Help and contribution

- [Report a bug or request a feature](https://github.com/UFOAlastor/koreader_PicaYomi/issues): include plugin/source versions, KOReader version, device model, and steps to reproduce. Reports in Chinese or English are welcome.
- [Contributing](https://github.com/UFOAlastor/koreader_PicaYomi/blob/main/.github/CONTRIBUTING.md) · [Security policy](https://github.com/UFOAlastor/koreader_PicaYomi/blob/main/.github/SECURITY.md)
- [Diagnostic logging (Chinese)](docs/DEBUG.md): release builds disable debug logging by default. Remove credentials, session data, and personal reading information before sharing logs or screenshots.
- [Source SDK and authoring guides (Chinese)](https://github.com/UFOAlastor/PicaYomi_Sources)

## License and disclaimer

Project code is licensed under the [MIT License](LICENSE). See [third-party notices](THIRD_PARTY.md) for bundled components. Thanks to [PicaComic](https://github.com/Pacalini/PicaComic), [rakuyomi](https://github.com/hanatsumi/rakuyomi), and KOReader for design references.

This project is for learning and technical exchange. It does not provide or host manga or novel content; copyrights belong to their respective owners. Follow local laws and platform rules, support authorized releases, and use the project at your own responsibility.
