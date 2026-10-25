# Changelog

All notable changes to Quill. This project follows [Semantic Versioning](https://semver.org/).

## [0.1.2] - 2026-10-24

- Fix: release binaries are built for a baseline CPU. 0.1.1's Windows build
  targeted the CI runner's CPU and crashed with an illegal instruction on
  older hardware.

## [0.1.1] - 2026-10-24

- Fix: modified state is derived from the buffer instead of an event flag, so a
  freshly opened document no longer shows the unsaved marker.
- Docs: refreshed the README screenshot.

## [0.1.0] - 2026-10-24

First release.

- Native window via the OS webview (WebView2, WebKit, WebKitGTK); app logic in Zig.
- Markdown rendering through md4c: CommonMark 0.31.2 plus GFM tables, task lists,
  strikethrough and bare-URL autolinks.
- Split view with draggable divider and live preview.
- Relative images resolved next to the document and inlined as `data:` URIs.
- Raw HTML escaped; links handed to the system browser.
- Save writes back to the file given on the command line; Export writes a copy.
- Theme follows the system, with light/dark override and zoom.
- Cross-compiles to Windows and Linux from any host; macOS builds on macOS.

[0.1.2]: https://github.com/epicshawty/quill/releases/tag/v0.1.2
[0.1.1]: https://github.com/epicshawty/quill/releases/tag/v0.1.1
[0.1.0]: https://github.com/epicshawty/quill/releases/tag/v0.1.0
