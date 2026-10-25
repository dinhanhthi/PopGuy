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

## [1.3.2] - 2026-10-15

### Added

- Settings → Providers → Dictionary: a switch next to "Load" turns all Babylon dictionaries on or off at once.

### Changed

- Imported Babylon dictionaries are now stored as a small on-disk database per dictionary and read only when you look up a word. With eight large dictionaries loaded, PopGuy's memory use drops from about 560 MB to about 20 MB, and the first lookup is no longer slow. Existing dictionaries are converted once in the background right after the first launch of this version; your original `.bgl` files are never modified.

## [1.3.1] - 2026-10-14

### Added

- Humanize action in the Action Library (new AI Writing category): rewrites AI-sounding text so it reads like a person wrote it. Works with every AI provider.
- Local AI: Humanizer 12B, an on-device model built for the Humanize action. It is selectable only for Humanize, and its Local Models entry explains how to set the action up.

## [1.3.0] - 2026-10-14

### Added

- Local AI: three new on-device models, Qwen3.5 2B, Qwen3.5 9B and Llama 3.2 3B.

### Changed

- Model pickers now list the latest models: GPT-6.1 Sol, GPT-6 Astra and GPT-6 Luna (OpenAI and Codex CLI), Claude Opus 5.5, Sonnet 5.5, Haiku 5.5 and Fable 5.1, Gemini 4 Argon and Gemini 3.8 Flash, GLM-5.3, plus updated OpenRouter and Gemini CLI suggestions. The default OpenAI model is now GPT-6.1 Sol.

### Fixed

- Actions saved with a deprecated or retired model are switched automatically to the provider's recommended replacement, at launch and when you import an action. This also fixes a few model ids PopGuy used to suggest that providers never accepted, such as "gemini-3.1-pro" and "anthropic/claude-opus-4-8".
- OpenAI speech: "tts-1" and "tts-1-hd" (deprecated) now switch to "gpt-4o-mini-tts".
- The custom model field now appears automatically after you switch provider.

## [1.2.1] - 2026-10-13

### Added

- "Remove gap before system buttons" switch in Settings → Appearance (off by default). When on, the Ignore and Settings buttons sit right after the actions like any other action, with a vertical divider before each, instead of after a gap. The preview in Settings updates as you toggle it.

## [1.2.0] - 2026-10-13

### Added

- The toolbar preview in Settings → Actions now shows your real toolbar at its true size and look (zoom, logo, labels, system buttons and the gap included). Drag actions to reorder them, or between the toolbar and a separate "More actions" row. The preview scrolls sideways when the toolbar is wide, and a warning appears when it gets very wide.
- Show label: each action now has its own "Show label" switch to display its name next to its icon on the toolbar (off by default).
- Action cards have a second row of switches: Activate, In More actions and Show label.
- "Enable Ignored Apps" switch in Settings → Apps. When off, the ignored-apps list is not applied and the "Ignore this app" button leaves the toolbar; your list is kept.
- "Show Settings button on toolbar" switch in Settings → Actions.

### Changed

- There is no longer a limit on how many actions the toolbar or the More actions menu can hold (it used to be 6 and 5). If the toolbar gets too wide, that is up to you.
- Toolbar buttons are icon-only by default. Names no longer appear automatically when few actions are shown; turn on Show label per action to get them back.
- The gap between the action buttons and the Ignore / Settings buttons only appears when at least one of those buttons is visible.
- The "Toolbar" checkbox on action cards is now an "In More actions" switch (the opposite meaning).
- "Add Action" is now a "+" button in the row with Export, Import and Library.
- At least one action always stays active: the last active action's switch and delete button are locked, with a tooltip explaining why.

### Fixed

- Moving every action into More actions no longer resets the toolbar layout the next time PopGuy starts.

## [1.1.2] - 2026-10-13

### Fixed

- The toolbar now fits the number of actions it shows. With only one action left, it no longer stretches wide with an empty gap before the Ignore and Settings buttons.
- The tooltip of the leftmost toolbar button is no longer cut off when the logo is hidden; it now aligns to the left edge.

## [1.1.1] - 2026-10-12

### Added

- "Only in editable text" option for Show toolbar when text is selected (off by default). When on, selecting read-only text, such as web page content or chat messages, no longer pops up the toolbar; Cmd+C+C and hotkeys still work on any text. Turn it on in Settings → Triggers.

## [1.1.0] - 2026-10-08

### Added

- Regenerate and Refine for AI results. Two new buttons under a result re-run the action on your original text, or revise the result with an instruction such as "shorter" or "more formal". Refine can be chained, and the diff always compares against your original text. Available for Improve, Shorten, Proofread, Prompt, Translate (when using an AI model) and custom AI actions; DeepL and Google Translate offer Regenerate only.
- Click a highlighted change in the Improve or Proofread diff to revert or restore it. Copy and Paste back use the text with your choices applied.
- Prompts now support {{app}}, {{date}}, {{language}} and {{domain}} placeholders alongside {{text}}. {{domain}} is only filled when Ignored Domains is turned on in Settings → Apps.

### Fixed

- The menu bar menu shows its icons again on macOS 27.
- The diff view no longer scrolls inside a scroll area.

## [1.0.5] - 2026-10-03

### Added

- New "Hide logo" option in Settings → Appearance removes the PopGuy logo from the toolbar to save space. With the logo hidden, the toolbar row can hold up to 7 actions instead of 6. Showing the logo again moves any extra action to the More menu, or is blocked if the More menu is full.

## [1.0.4] - 2026-09-26

### Fixed

- Quitting PopGuy during a local model download now stops the download instead of letting it finish silently in the background.
- Model files left over from interrupted or cancelled downloads are now cleaned up automatically when you open Local models, freeing the disk space they used.

## [1.0.3] - 2026-09-25

### Added

- A Stop button appears below the spinner while an AI action is running, letting you cancel it mid-stream.

### Fixed

- The AI action result sometimes came back wrapped in double quotes ("like this") even when the selected text wasn't. Quotes are now stripped unless your own selection was quoted.
- A rare crash could occur from the toolbar's global mouse monitor.

## [1.0.2] - 2026-09-22

### Fixed

- On-device Gemma 4 models failed to run with a "Key … self_attn.v_proj.weight not found" error. Gemma 4 2B and 4B share attention keys/values across their upper layers, so those layers ship no `k_proj`/`v_proj` weights — the bundled MLX runtime still expected them. Gemma 4 12B failed for a related reason: its architecture was not recognised at all. Updated the MLX runtime (mlx-swift-lm 3.31.3 → 3.31.4), which fixes both.
- The Local Models catalog showed the wrong on-disk size for each model.
- Long local-model downloads could fail because the MLX helper process exited before the download finished.

## [1.0.1] - 2026-09-22

### Removed

- The one-time “PopGuy is now free” announcement shown to users who updated from a paid build.

## [1.0.0] - 2026-09-21

### Changed

- PopGuy is now completely free. Every former Pro feature is unlocked — no license key, no trial, and no usage nag. Existing users see a one-time announcement on first launch of this version.

### Removed

- License tab, Get Pro / upgrade prompts, and the Lemon Squeezy client. The app no longer talks to Lemon Squeezy. Already-shipped versions can still activate a previously purchased key.
- Website pricing and checkout. Download is the only call to action.

## [0.5.3] - 2026-08-25

### Added

- A first-run setup guide that walks through Accessibility permission, provider setup (Local AI or Cloud API key), trigger configuration (Cmd+C+C chord and show-on-select), and which toolbar actions to enable.
- "Setup Guide…" item in the menu bar and in Settings → General to reopen the first-run walkthrough anytime.

## [0.5.2] - 2026-07-20

### Fixed

- The "Get Pro" checkout link now points to the live Lemon Squeezy product. v0.5.1 shipped with a test-mode checkout URL by mistake, so purchases made through that version were not processed as real orders.

## [0.5.1] - 2026-07-18

### Changed

- PopGuy is now open source under the GNU Affero General Public License v3.0 (previously source-available under the PolyForm Noncommercial License).

## [0.5.0] - 2026-07-11

### Added

- Screen Capture OCR (Pro): select any region of the screen and extract its text using Vision, triggered by a configurable global hotkey, a Settings toggle, or a menu bar item. Extracted text is copied to the clipboard. Press Esc to cancel capture at any time.
- Diff/Text toggle for Improve results, to switch between the diff view and plain text.

### Fixed

- Improve diff view no longer triggers a SwiftUI view-update warning when opened.

## [0.4.1] - 2026-06-29

### Fixed

- Dragging to select text in Chrome, Edge, Brave, or other marker-readable browsers no longer causes a system beep. The synthetic ⌘C fallback is now restricted to Monaco editors (VSCode and Cursor), which cannot expose large drag-selections through the Accessibility API.

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
