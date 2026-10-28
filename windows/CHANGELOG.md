# Changelog

All notable changes to PopGuy for Windows are documented in this file. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). From 1.4.0, macOS and Windows share one version and one
GitHub release: each version has a section here and one with the same `## [X.Y.Z] - YYYY-MM-DD` heading in
`macos/CHANGELOG.md`, and `scripts/publish-release.sh` puts both in the release body (this one under `## Windows`).
Before 1.4.0 Windows had its own versions (0.1.0).

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
