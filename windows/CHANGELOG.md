# Changelog

All notable changes to PopGuy for Windows are documented in this file. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). From 1.4.0, macOS and Windows share one version and one
GitHub release: each version has a section here and one with the same `## [X.Y.Z] - YYYY-MM-DD` heading in
`macos/CHANGELOG.md`, and `scripts/publish-release.sh` puts both in the release body (this one under `## Windows`).
Before 1.4.0 Windows had its own versions (0.1.0).

## [Unreleased]

## [1.4.10] - 2026-11-08

### Added
- Emoji picker: press Ctrl+; in any text field to open a small picker at the text cursor. Search emoji and symbols (English, Vietnamese, French and Spanish), browse by category, pick a skin tone and see your most used emoji first. Enter or a click types the emoji into the app you were in; if that isn't possible (an app running as administrator, or one that lost the focus) it is copied instead. It never opens in password fields and never types into remote sessions. Off by default: turn it on in Settings → Emoji or in the tray menu, where you can also change the shortcut. Country flags are hidden because Windows draws them as letters.
- An "Emoji picker" step in the Setup Guide.
- Composer: Enter continues a Markdown list and Backspace removes an empty bullet.
- A step in the Setup Guide that offers the Terminal Composer (off by default).

### Changed
- The tray menu no longer has "Setup Guide" (it is still in Settings → General) and has an "Emoji Picker" switch.

## [1.4.9] - 2026-11-07

### Added
- Terminal Composer: write long prompts for terminal tools in a PopGuy window. Claude Code (Ctrl+G), Codex, Gemini CLI, git and PowerShell open it as their editor through the new `popguy-edit` command. Done sends the text back to the terminal, Cancel or Esc keeps the original, and drafts are autosaved.
- Simple Markdown in the composer: headings are bold, including the `#`.
- Compose shortcut (default Ctrl+Alt+Shift+E): opens an empty composer from any app and pastes the result into the app you were in, or copies it when pasting isn't possible (elevated, remote or non-terminal targets).
- A "Composer" page in Settings with the on/off switch, the shortcut, the command install, the VISUAL editor variable and copyable snippets for PowerShell, Claude Code and git.
- A "More actions" connector between the toolbar and the More card in the Actions preview.

### Changed
- General, Triggers and Appearance now use tabs like the Ignore page.
- The Settings window opens smaller by default and has a larger minimum size.
- Settings captions and row buttons are larger, and each group's description now sits above its card.

## [1.4.8] - 2026-11-05

### Changed
- No changes on Windows; this version ships with the macOS update.

## [1.4.7] - 2026-11-05

### Added

- Settings → Providers → Local AI warns that small local models may answer the selected text instead of processing it.
- Settings → Actions notes that a custom prompt replaces the default prompt.

### Changed

- Settings → Providers → Local AI lists models from least to most RAM needed.
- The Settings window opens larger by default.
- "Preserve & render formatting" moved from Appearance to General.

### Fixed

- Small local models no longer answer a selected question instead of improving or translating it.

## [1.4.6] - 2026-11-04

### Added

- Press Enter on a result to paste it back into the source app. Choose what Enter does (and its fallback) in Settings → General.

### Changed

- The Edit button on a result is now icon-only, and Cancel is inset for a cleaner toolbar.

### Fixed

- Holding Enter now runs the action once, on key release, so the keystroke never reaches the source app.

## [1.4.5] - 2026-11-02

### Fixed

- The toolbar now appears when you select text with the keyboard (for example Shift+Arrow or Ctrl+A), closes when you press Esc, and closes when the keyboard selection is cleared.

## [1.4.4] - 2026-11-02

### Added

- New "Show logo only" option, in Settings → Appearance and in the tray menu. When it is on, selecting text or pressing the show-toolbar shortcut shows only the PopGuy logo next to the pointer, so the toolbar no longer pops up over every selection. Click the logo to open the full toolbar, which expands out of the logo (to the left when there is no room on the right); with the Menu toolbar style, the menu opens in place of the logo. Action shortcuts and screen text capture still open the full toolbar right away.

### Changed

- The tray menu items Settings, History, About PopGuy, Setup Guide and Check for Updates no longer end in "…".

## [1.4.3] - 2026-11-02

### Added

- Toolbar style: Menu. Settings → Appearance can show the toolbar as a list like a context menu, with an icon and a label for each action. Hovering "More actions" opens the extra actions beside it. The menu opens away from the screen edges, and picking an action shows the usual toolbar with the result. Action shortcuts and screen text capture still open the usual toolbar.

## [1.4.2] - 2026-11-02

### Changed

- No changes on Windows; this version ships with the macOS update.

## [1.4.1] - 2026-11-02

### Added

- Settings → Ignore has two new toggles, "Show "Ignore this app" button on toolbar" and "Show "Ignore this site" button on toolbar". Turning one off hides that button on the toolbar while its ignored list keeps working. Before, the only way to hide a button was to turn off Ignored Apps or Ignored Domains, which also stopped the feature.

## [1.4.0] - 2026-10-28

### Changed

- PopGuy for Windows now shares its version and its GitHub release with the macOS app, so each release carries the
  installer and the portable zip for x64 and ARM64. Update checks read these shared releases.
- Copies installed from 0.1.0 do not update to 1.4.0 by themselves: install 1.4.0 once from the latest release (your
  settings, history and API keys are kept); later versions update automatically.

## [0.1.0]

### Added

- First release of PopGuy for Windows 11 (x64 and ARM64): select text in any app and a floating toolbar offers AI
  actions (Improve, Shorten, Proofread, Translate, Prompt), Speak, Look up and your own custom actions.
- Triggers: Ctrl+C+C, show on text selection, double-click, global shortcuts, and Screen Text Capture (OCR).
- Providers: OpenAI, Anthropic, Gemini, GLM, OpenRouter, Ollama / LM Studio, custom OpenAI-compatible endpoints,
  DeepL, Google Translate, the Claude, Codex and Gemini CLIs, and local models that run on your PC.
- Settings for actions, providers, triggers, appearance, ignored apps and sites, history and the action library,
  plus a first-run setup guide.
- Updates through Velopack: PopGuy checks GitHub once a day and restarts into a new version when you choose.
- A portable zip for each architecture next to the installer: unzip it anywhere and run `PopGuy.exe`.
