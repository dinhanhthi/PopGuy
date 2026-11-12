<div align="center">

<img src="assets/logo_nobg.png" width="128" alt="PopGuy logo">

# PopGuy

Select text in any app, get a floating toolbar to improve, translate or transform it with AI.

[![Download macOS](https://img.shields.io/badge/Download-macOS-black?style=for-the-badge&logo=apple)](https://github.com/dinhanhthi/PopGuy/releases/latest)
[![Download Windows](https://img.shields.io/badge/Download-Windows-0078D4?style=for-the-badge&logo=windows11)](https://github.com/dinhanhthi/PopGuy/releases/latest)
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL%20v3-blue?style=for-the-badge)](LICENSE)

[Website](https://pg.dinhanhthi.com) · [Demo video](https://www.youtube.com/watch?v=-ctYYSC4bWM)

</div>

![PopGuy](assets/poster.png)

## Features

- **Improve**: rewrite the selection with AI and review an inline diff before applying it. Your text never changes until you accept.
- **Translate** and **Dictionary** for the selected text.
- **Custom AI actions** with your own system prompt, plus a library of ready-made ones.
- **Plugins and PopClip extensions** (partial support for PopClip).
- **Providers**: OpenAI, Anthropic (Claude), Ollama / LM Studio (local), DeepL, Google Translate.
- **Global hotkeys**, and a Cmd+C+C chord to improve the current selection.
- **OCR** to capture text from any screen region.
- **Terminal Composer** and **Emoji picker** (both off by default).
- Menu-bar app, no Dock icon. API keys stay in the system Keychain (Windows Credential Manager on Windows).

## Requirements

- **macOS 13 or later**, Apple silicon and Intel. Grant **Accessibility** in System Settings > Privacy & Security to read the selection and detect Cmd+C+C.
- **Windows 11**, x64 and ARM64. Apps running as administrator are out of reach. The build is not code-signed yet, so SmartScreen warns on first run: click **More info > Run anyway**.

## Install

Download the latest build from the [Releases page](https://github.com/dinhanhthi/PopGuy/releases/latest). macOS builds are signed, notarized and update themselves. On Windows, use `PopGuy-win-<arch>-Setup.exe` (installs for your user only, updates itself) or the `Portable.zip`.

## Build

macOS needs Xcode 26:

```sh
open macos/PopGuy.xcodeproj
xcodebuild test -project macos/PopGuy.xcodeproj -scheme PopGuy -destination 'platform=macOS'
```

The Windows app is built on GitHub Actions only, see [windows/README.md](windows/README.md). More in [CONTRIBUTING.md](CONTRIBUTING.md).

## License

AGPL-3.0, see [LICENSE](LICENSE).
