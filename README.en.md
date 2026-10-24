# PicaYomi

[简体中文](README.md)

A manga reader plugin for [KOReader](https://github.com/koreader/koreader), designed primarily for Kindle and other e-ink devices. It supports multiple sources, search, streaming, chapter downloads, favorites, and reading history.

**The plugin interface currently supports Chinese only.** This page is an introduction; the [Chinese README](README.md) contains the full user guide. Compatibility with devices other than Kindle needs testing.

## Preview

| Home | Settings | Manga list | Categories | Details |
|---|---|---|---|---|
| ![Home](docs/screenshots/home.png) | ![Settings](docs/screenshots/settings.png) | ![Manga list](docs/screenshots/comic-list.png) | ![Categories](docs/screenshots/categories.png) | ![Details](docs/screenshots/detail.png) |

## Installation

1. Install and verify KOReader on your device.
2. Download **`picayomi.koplugin-<version>.zip`** from the [latest release](https://github.com/UFOAlastor/koreader_PicaYomi/releases/latest).
3. Extract it and copy the **`picayomi.koplugin`** folder into **`koreader/plugins/`**.
4. Restart KOReader and open PicaYomi from the Tools menu (工具).

Use the plugin ZIP attached to the release. GitHub's automatically generated “Source code” archives are source snapshots.

## Getting started

Select a source on the home page and sign in if the source requires it. Open a title to read online or use 下载章节 (Download chapters) to save chapters for offline reading. Offline chapters are available from 已下载 (Downloaded) on the home page.

Sources are managed under 设置 → 源管理 (Settings → Source management). The default subscription is already configured. Automatic source update checks are disabled by default; when enabled, downloading an update still requires confirmation. Source changes take effect after restarting KOReader.

To update the plugin, exit KOReader, replace the plugin folder with the new release, and restart. Keep the KOReader data directory to preserve accounts, settings, favorites, history, and downloads; back up important data first.

## Help and contribution

- [Report a bug or request a feature](https://github.com/UFOAlastor/koreader_PicaYomi/issues): include plugin/source versions, KOReader version, device model, and steps to reproduce. Reports in Chinese or English are welcome.
- [Contributing](https://github.com/UFOAlastor/koreader_PicaYomi/blob/main/.github/CONTRIBUTING.md) · [Security policy](https://github.com/UFOAlastor/koreader_PicaYomi/blob/main/.github/SECURITY.md)
- [Diagnostic logging (Chinese)](docs/DEBUG.md): release builds disable debug logging by default. Remove credentials, session data, and personal reading information before sharing logs or screenshots.
- [Source SDK and authoring guides (Chinese)](https://github.com/UFOAlastor/PicaYomi_MangaSources)

## License and disclaimer

Project code is licensed under the [MIT License](LICENSE). See [third-party notices](THIRD_PARTY.md) for bundled components. Thanks to [PicaComic](https://github.com/Pacalini/PicaComic), [rakuyomi](https://github.com/hanatsumi/rakuyomi), and KOReader for design references.

This project is for learning and technical exchange. It does not provide or host manga content; copyrights belong to their respective owners. Follow local laws and platform rules, support authorized releases, and use the project at your own responsibility.
