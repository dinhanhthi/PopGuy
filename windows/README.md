# PopGuy for Windows

The Windows port of PopGuy: C# on .NET 10 with WinUI 3 (Windows App SDK), for Windows 11 (22000+) on x64 and ARM64. The macOS app lives in [`../macos`](../macos); both read and write the same custom-action JSON.

## Layout

| Path | What |
|---|---|
| `PopGuy.slnx` | The solution. |
| `global.json` | Pins the .NET 10 SDK (`10.0.100`, `latestFeature`). |
| `Directory.Build.props` | Shared settings: nullable on, warnings are errors. |
| `Directory.Packages.props` | Central package versions. |
| `src/PopGuy.Core` | `net10.0`, no Windows APIs: settings, actions and the action engine, providers, scripts, plugins and the action library, Speak and dictionaries, history, the update release selector. Builds and tests on macOS. |
| `src/PopGuy.Platform` | `net10.0-windows10.0.26100.0`, AnyCPU: Win32 / UI Automation / clipboard / input through CsWin32. CsWin32-generated types are `internal`; App uses Platform's public wrappers. |
| `src/PopGuy.LocalLLM` | `net10.0`: local models through LLamaSharp (llama.cpp CPU backend): the GGUF catalog, the downloader and the provider. |
| `src/PopGuy.App` | The WinUI 3 app (assembly `PopGuy`, root namespace `PopGuy`, so App code uses `namespace PopGuy.<Folder>`). |
| `tests/PopGuy.Tests` | xUnit v3 tests for Core and LocalLLM. |
| `tests/PopGuy.Platform.Tests` | xUnit v3 tests for Platform (Windows only, run on CI). |
| `CHANGELOG.md` | The Windows release notes (Keep a Changelog), one section per shared version; `../scripts/publish-release.sh` puts it in the release body. |
| `scripts/vm-install.ps1` | Installs a CI build (`-Folder`) or a release installer (`-Setup`) in the QA VM. |
| `scripts/fetch-release.sh` | Waits for a tag's `windows-release.yml` run and downloads and checks its packages (`../scripts/ship.sh` runs it; see Releasing). |
| `scripts/install-notes.md` | How to install, and why SmartScreen warns, appended to every release's notes. |
| `scripts/serve-update.sh` | Serves a local update feed to the QA VM (update tests only). |
| `tools/make-icon.py` | Regenerates `src/PopGuy.App/Assets/PopGuy.ico`. |

Project graph: `App → Platform → Core`, `App → LocalLLM`, `Tests → Core, LocalLLM`, `Platform.Tests → Platform`.

## Prerequisites and local checks (macOS)

The Windows app is built only on GitHub Actions. On a Mac you can run the Core and LocalLLM tests and type-check Platform with the .NET 10 SDK installed in `~/.dotnet`:

```sh
~/.dotnet/dotnet test windows/tests/PopGuy.Tests/PopGuy.Tests.csproj
cd windows && ~/.dotnet/dotnet build src/PopGuy.Platform/PopGuy.Platform.csproj -p:EnableWindowsTargeting=true
```

The App project (WinUI XAML compiler) does not build on macOS.

## Cross-platform action fixtures

`tests/PopGuy.Tests/Fixtures/` holds one export from each app; each side's tests read the other side's file through its import path:

- `macos-exported-actions.json`: written by the Swift suite `CrossPlatformActionsFixtureTests` (`macos/PopGuyTests/Unit/CrossPlatformActionsFixtureTests.swift`), read by `CustomActionJsonTests`.
- `windows-exported-actions.json`: written by `CustomActionJsonTests.WriteWindowsExportedActionsFixture`, read by the Swift suite.

The writers run only with `POPGUY_WRITE_FIXTURES=1`. Regenerate both on the Mac after changing the action format, then run both suites without the variable:

```sh
POPGUY_WRITE_FIXTURES=1 ~/.dotnet/dotnet test windows/tests/PopGuy.Tests/PopGuy.Tests.csproj
TEST_RUNNER_POPGUY_WRITE_FIXTURES=1 xcodebuild -project macos/PopGuy.xcodeproj -scheme PopGuy \
  -destination 'platform=macOS' -skipMacroValidation test \
  -only-testing:PopGuyTests/CrossPlatformActionsFixtureTests
```

Regenerate on macOS, not Windows, so the files keep LF line endings.

## CI

`.github/workflows/windows.yml` runs on pushes to `windows` and `main` and on pull requests that touch `windows/` or the workflow:

- `test` (windows-latest, x64) and `test-arm64` (windows-11-arm): `dotnet test` of `tests/PopGuy.Tests`, both without the native llama.cpp tests (`native-smoke` runs those).
- `test-platform` (windows-latest): `dotnet test` of `tests/PopGuy.Platform.Tests` (Platform's Windows-only tests).
- `native-smoke` (windows-latest and windows-11-arm): loads a small GGUF model through LLamaSharp and streams an answer (the model is cached by its SHA-256).
- `package` (matrix `x64`, `arm64`): `dotnet publish` of the App (Debug, self-contained, version `0.0.<run number>`), then checks the PE machine type (the llama.cpp natives too), the PRI resources and the embedded manifest's WinRT activatable classes. Uploads the artifact `PopGuy-win-<arch>`.

`.github/workflows/windows-release.yml` runs on `v*` tags (the shared macOS + Windows release that `../scripts/ship.sh` pushes) and on every `windows-v*` tag (QA builds use `windows-v*-dev` ones): a Release publish per architecture, packed by Velopack (`vpk pack`, with the VC++ runtime as a framework the installer adds) into `PopGuy-win-<arch>-Setup.exe`, `PopGuy-win-<arch>-Portable.zip`, `PopGuy-<version>-win-<arch>-full.nupkg` and the feed `releases.win-<arch>.json`. A tag with `-dev` builds with `UPDATE_URL_OVERRIDE`, so that build reads its update feed from `POPGUY_UPDATE_URL` (QA only; never publish a `-dev` release).

Download a build:

```sh
gh run list --branch windows --limit 5
gh run download <run id> -n PopGuy-win-arm64 -D ~/Downloads/PopGuy-win/<run id>
```

## VM testing

QA runs in the VMPal VM "Windows VM 2" (Windows 11, ARM64). Never build in the VM. The Mac's `~/Downloads` is `Z:\Downloads` there.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File Z:\Downloads\PopGuy-win\<run id>\vm-install.ps1 -Folder Z:\Downloads\PopGuy-win\<run id> -Launch
```

`vm-install.ps1` copies the app to `C:\PopGuyQA\builds\<run id>`, unblocks it and, with `-Launch`, starts it through `explorer.exe` (the VM tool kills child processes when its command returns). Arguments for the app need `-Wait`. Test fixtures live in `C:\PopGuyQA`. See the script's help for every parameter.

DEBUG builds accept harness arguments instead of the usual tray start; they write to `%APPDATA%\PopGuy\Probes` and never write selected text, only its length (API keys never):

- `--spike <seconds>`: resident run of global input, clipboard cache, hotkey, chord and the test toolbar; logs `spike-<ts>.jsonl`.
- `--probe-uia <delaySeconds>`: one UI Automation read of the focused selection into `probe-uia-<ts>.json`.
- `--import-key <provider|tts:raw> <path>`: saves the key in a UTF-8 text file to Credential Manager, then exits (QA key files).
- `--seed-settings <provider> <model> [baseUrl] [--on-select] [--double-click <action>]`: maps the built-in actions to that provider and model, optionally turns on Show on Text Selection and the double-click trigger, then exits.
- `--selftest-toolbar`: starts as usual and shows the toolbar with a canned result.

Every DEBUG launch also writes `hello.json` (process architecture, OS, version) and logs Speak to `speak-<ts>.jsonl`.

Update tests: push two temporary `windows-v0.0.9xx-dev` tags (deleting each after its run), install the older one's `Setup.exe` with `vm-install.ps1 -Setup`, serve the newer one's packages with `scripts/serve-update.sh <folder>` and start PopGuy with `POPGUY_UPDATE_URL=http://<Mac address>:8765`.

## Releasing

macOS and Windows ship as one version and one GitHub release (`vX.Y.Z`, Latest); `/cf-ship` runs these steps (`.coding-friend/skills/cf-ship-custom/SKILL.md`).

1. `../scripts/bump-version.sh X.Y.Z` sets `<Version>` in `src/PopGuy.App/PopGuy.App.csproj` and the macOS version together. Add a `## [X.Y.Z] - YYYY-MM-DD` section to `CHANGELOG.md` and the same one to `../macos/CHANGELOG.md` (a platform without changes gets "No changes on <platform>; this version ships with the <other> update."), commit them as `release: vX.Y.Z` and push `main`.
2. Run `../scripts/ship.sh` on the Mac: it pushes the tag `vX.Y.Z` first, so `windows-release.yml` builds both architectures while the Mac builds and notarizes macOS, then `scripts/fetch-release.sh` waits for that run and downloads and checks both architectures' Setup.exe, Portable.zip, full nupkg and feed, and `../scripts/publish-release.sh --windows` creates the release as a draft (both changelog sections plus `scripts/install-notes.md`), uploads the macOS and Windows files and publishes it as Latest.
3. Installed copies find the release within a day (or at once with Check for Updates): the update check reads the published releases that carry a `releases.win-<arch>.json` feed. Installs of `windows-v0.1.0` (before the shared version) do not update by themselves; reinstall once. See `docs/RELEASING.md` for rollback.

## Constraints

- **Unpackaged, self-contained:** `WindowsPackageType=None`, `SelfContained` and `WindowsAppSDKSelfContained`. Distribution is a direct download (Velopack's Setup.exe, per user, no administrator rights) with Velopack updates, unsigned. Velopack installs into `%LOCALAPPDATA%\PopGuy`; PopGuy's own data lives in `%APPDATA%\PopGuy` (settings, history) and `%LOCALAPPDATA%\PopGuyData` (log, models), which an uninstall keeps.
- **Windows App SDK component packages** (Base, Foundation, WinUI, InteractiveExperiences, DWrite) with central versions, not the metapackage.
- **No trimming and no Native AOT:** CsWin32's classic COM interop breaks under both.
- **CsWin32:** generated types stay `internal`. List enum types in `NativeMethods.txt`, never enum members. APIs whose signature differs per architecture (`Shell_NotifyIcon`, `SHGetFileInfo`, `*Ptr` functions) are hand-declared, because Platform is AnyCPU.
- **API keys** go only in Windows Credential Manager, never in settings files.
- **Clipboard:** a synthetic copy (Ctrl+Insert) is used only when UI Automation can't read the selection and the target allows it; the user's clipboard is always restored.
- **Fluent UI:** English-only strings; WinUI default controls, `{ThemeResource}` brushes and the type ramp, Segoe Fluent Icons, no hex colours in views. Settings and Onboarding use the solid base background of Windows 11 apps (no Mica, which tints with the wallpaper), the toolbar DesktopAcrylic. Light/Dark and accent follow Windows. Tooltips only through the custom fast hover tooltip, never `ToolTipService`'s default delay; controls that attach default tooltips by themselves (AppBarButton, CommandBar, compact NavigationView) are not used or have them removed.

## Toolbar host

Decided by the Phase 3 spike gate (VM QA, 2026-10-25): the toolbar is a **WinUI 3 window** made non-activating; the XAML Islands host was not needed.

- Window styles `WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST`; every HWND of the window is subclassed to answer `MA_NOACTIVATE`; buttons have `AllowFocusOnInteraction=False`; the foreground window is handed back if it moves. Clicking the toolbar never takes focus from the app the text came from.
- Text input (the Prompt box) uses an activation region that answers `MA_ACTIVATE` plus `SetForegroundWindow`, and hands focus back on Escape or when input ends.
- The backdrop is a `DesktopAcrylicController` kept always active: a window that never activates would otherwise show the inactive fallback colour instead of acrylic.

## Build cache

The machine's shared Cargo target dir and Xcode DerivedData don't apply here. .NET builds into each project's `bin/` and `obj/` (gitignored). NuGet packages are cached in `~/.nuget/packages` (on Windows CI `%USERPROFILE%\.nuget\packages`). There is no repo `nuget.config`; packages come from nuget.org.
