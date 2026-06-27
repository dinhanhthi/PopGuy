# Changelog

All notable changes to PopGuy are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This file is the **single source of truth** for release notes: `scripts/publish-release.sh`
extracts the section matching the version being released and uses it for both the GitHub
release body and the Sparkle appcast notes. Each released version needs a section whose
header is exactly `## [X.Y.Z] - YYYY-MM-DD` (the script matches on that format).

## [Unreleased]

<!-- Add entries here as you work. On release, rename this to `## [X.Y.Z] - YYYY-MM-DD`
     and start a fresh [Unreleased] section above it. -->

## [0.4.0] - 2026-06-27

### Added

- On-device local AI: run models locally through a built-in MLX engine — no API key, fully offline.
- Local Models manager in Settings: download, remove, and manage on-device models with live download progress.
- Per-model memory controls to load and unload models on demand.
- PopGuy Pro is now available to purchase. Unlock unlimited custom actions, cloud TTS voices, unlimited history, import/export, and more.
- Free trial: every new install gets 1 month of Pro, free.
- Global prompt: add instructions that are prepended to every AI action.
- License management in Settings: activate a purchased key, view status, and deactivate a Mac to free an activation.

### Changed

- The menu bar now shows your trial status ("Free Trial — N days left") separately from an active paid Pro license.
- You can enter a license key at any time, including during the free trial.

### Fixed

- Confirmation dialog before deleting a downloaded local model.
- Floating toolbar uses an opaque background instead of a translucent material.
- Settings slide-over panels keep a fixed header gap when the window is resized.

## [0.3.0] - 2026-06-24

### Added

- New toolbar layout system: choose which actions sit on the main toolbar row and which tuck into a "More" overflow menu.
- Interactive toolbar layout editor in Settings — drag actions between the toolbar row and the More menu.
- A Toolbar toggle on each action card in the Actions tab to pin it to the main row.
- The toolbar can now hold up to 11 actions.

### Changed

- Dropdown menus across Settings (Actions filter, History filter, plugin import, toolbar More) now share one consistent style.
- Hover tooltips dismiss on click so they no longer linger over dropdowns.

### Fixed

- Disabled overflow actions no longer count against the toolbar capacity limits, so an enabled action can always move into a non-full More menu.

## [0.2.1] - 2026-06-24

### Fixed

- "Check for Updates" no longer renders the GitHub releases web page inside the update window; the dialog now shows a compact update prompt. The "Version History" button still opens the full release history in your browser.
- The About tab now shows the correct release date for each build.

## [0.2.0] - 2026-06-24

### Added

- General tab in Settings with options to enable/disable PopGuy, launch at login, hide the Dock icon, and configure toolbar-closing behavior.
- Master on/off switch in the menu bar to disable PopGuy globally without quitting.
- Per-action checkboxes in the plugin import dialog, with a Select All option.
- Error messages in the toolbar are now selectable text.

### Changed

- Settings sidebar item spacing increased for readability.
- Footer layout simplified.

### Fixed

- Cloud-unavailable warning now shown when a configured cloud provider cannot be reached; broken `.help()` tooltips removed.
- Google Chirp3-HD voices now work correctly.
- Speed and pitch settings now take effect for cloud TTS providers.
- Release notes links in the updater now point correctly to the GitHub releases page.

## [0.1.2] - 2026-06-23

### Fixed

- App icon showed blank in the Settings window and the update dialogs after updating; release builds now compile the app icon correctly.

## [0.1.1] - 2026-06-23

### Added

- DMG download alongside the existing zip archive.

## [0.1.0] - 2026-06-22

### Added

- First public release of PopGuy with all key features.
