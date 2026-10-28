## Before

This is a **version bump + changelog + ship** workflow for PopGuy. macOS and Windows share
**one version and one GitHub release**: tag `vX.Y.Z`, marked *Latest*, holding the macOS zip +
DMG and the Windows packages (Setup.exe, Portable.zip, full nupkg and Velopack feed, for **x64
and ARM64**). The release is driven **from this machine** by `scripts/ship.sh`
(`docs/RELEASING.md`): the macOS app is built, signed and notarized here (the local archive uses
a warm SPM/Metal cache, far faster than an always-clean CI runner), while the Windows app is
built by GitHub Actions (`windows-release.yml`, started by the tag push), never on this Mac.
`deploy-pages.yml` then publishes the website and `appcast.xml` to Pages.

This **Before** section handles prep (commits → version → changelogs → file updates). The
**After** section runs the release.

**Fully autonomous — never ask the user anything.** Running `/cf-ship` is the approval for
the whole flow: version bump, both changelogs, commit, push to `main`, and `scripts/ship.sh`
(public GitHub Release + appcast). Do not ask to confirm the version, do not ask to review
the changelogs, do not ask before pushing or before `ship.sh`. Decide with the rules below and
keep going. These overrides beat the generic cf-ship rules:

- Releases run from `main` only. On any other branch, stop with
  `"Releases ship from main only (current branch: <branch>)."`; merging is the user's call.
- Pushing the `release: vX.Y.Z` commit straight to `main` is expected (this repo releases
  from `main`); skip cf-ship's "never push to main" warning.
- **Never create a PR** — skip cf-ship's PR step.
- A version in the hint (e.g. `/cf-ship 1.5.0`) is used as-is, skipping Step B2's classification.
- The only stops are hard failures you cannot fix: a test that still fails after one re-run,
  a build/notarize/publish script exiting non-zero, a failed Windows CI run, the branch is not
  `main`, or no user-facing commits on either platform (Step B1).
  A test that fails once and passes on re-run is flaky: record it with `capture-later.sh`
  and continue.

**One-time transition (the first shared release, 1.4.0).** This paragraph applies **only while
`git tag -l v1.4.0` and `git ls-remote --tags origin v1.4.0` both print nothing**. Once
`v1.4.0` exists (here or on origin), ignore it entirely and use Steps B1 and B2 as written; the
user may delete it from this guide in a separate docs commit. Until then macOS shipped
`vX.Y.Z` releases (last `v1.3.2`) and Windows its own `windows-vX.Y.Z` releases (only
`windows-v0.1.0`, not *Latest*). For this one release:

- The version is **1.4.0** for both apps (`bump-version.sh 1.4.0` moves the csproj from 0.1.0),
  whatever Step B2's classification says.
- The Windows commits of Step B1 start at `windows-v0.1.0`, not at `v1.3.2` (that range holds
  the whole port): `git log windows-v0.1.0..HEAD --oneline --no-merges -- windows/ .github/workflows/windows*.yml`.
- Installs of `windows-v0.1.0` do not auto-update to it (their updater reads only `windows-v`
  releases): say in the summary that 0.1.0 users reinstall once from the Latest release.
- The website's Windows buttons point at `/releases/latest/download/…` and 404 until this
  release is published (Latest is `v1.3.2`, without Windows assets), so ship it right away.

Drop this paragraph once 1.4.0 is published (the user does it; the tag check above already
turns it off).

### Step B1: Collect unreleased commits

```bash
git rev-parse --abbrev-ref HEAD   # must be main (see above)

# Last product release (vX.Y.Z only; plain `git describe` can return another tag shape)
LAST_TAG=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || echo "")
echo "Last tag: $LAST_TAG"

# macOS commits — exclude website/, appcast, the Windows app, and meta commits
git log ${LAST_TAG:+"$LAST_TAG..HEAD"} --oneline --no-merges \
  -- ':!website/' ':!appcast.xml' ':!windows/' ':!.github/workflows/windows*.yml'

# Windows commits — the Windows app and its packaging
git log ${LAST_TAG:+"$LAST_TAG..HEAD"} --oneline --no-merges \
  -- windows/ .github/workflows/windows*.yml
```

Read both outputs. Ignore commits that are **not app-facing**:

- Message starts with `release:`, `chore: bump`, or `release: appcast` (infrastructure).
- Conventional-commit scope is `website` — `feat(website):`, `fix(website):`, `chore(website):`, etc.
- After excluding `website/`, the leftover files are only incidental non-app paths (e.g. `.gitignore`).
  The `:!website/` pathspec is not enough on its own: a website commit that also touches
  `.gitignore` still appears in the log.
- macOS: only the macOS app (`macos/` app sources, resources and build config) is user-facing.
  Tests, `scripts/`, `docs/`, the root `README.md`/`CONTRIBUTING.md`, `.coding-friend/`,
  `.github/`, `website/`, and commits scoped `(windows)`, `(release)`, `(repo)` or `(website)`
  are not. With nothing user-facing for macOS, its section is the
  `No changes on macOS; this version ships with the Windows update.` entry (Step B3).
- Windows: only the app (`windows/src/`) and its packaging (`windows-release.yml`) are
  user-facing. Tests, `windows/scripts/`, `windows/tools/` and `windows/README.md` are not.

**Website work never counts as a reason to bump or as changelog material.**
`website/` deploys independently via Pages. It does not belong in either changelog
(GitHub Release notes, Sparkle appcast notes) — the app's only changelogs since the website's
changelog modal (`ChangelogModal.jsx` + `changelog.js`) was removed in `5d522f3`
("simplify landing, actions, and docs pages"). The website has no release-notes
UI to update; the two `CHANGELOG.md` files are the sole source of truth now.

If **neither platform** has user-facing app commits after filtering, stop with
`"No user-facing changes since $LAST_TAG — nothing to ship."`. If only one platform has them,
the release still ships both apps (every release carries both platforms' assets, so the
website's and the updaters' links to the Latest release never break).

### Step B2: Determine version bump level

Classify the filtered commits of **both platforms together** (one version, one bump level),
using conventional commit prefixes:

| Commits | Level |
|---|---|
| Many new features (3+ distinct app-facing features), or any breaking change | MINOR (x.Y.0) |
| Anything else: 1–2 features, `fix:`, `perf:`, `refactor:`, `docs:`, `chore:`, `style:`, `test:` | PATCH (x.x.Z) |

Rules:
- **PATCH is the default and strongly preferred.** Choose MINOR only for **many** new
  features (3 or more distinct app-facing features) or a **breaking change**
  (`feat!:`/`fix!:`, a `BREAKING CHANGE:` footer, or a change that removes/alters existing
  behavior users rely on).
- Count **features**, not commits: several `feat:` commits for the same feature (plan phases,
  follow-up `fix:` on it) count as one. Model-list refreshes and new catalog entries are
  one feature each, not many. The same feature shipped on both platforms counts once.
- 1 or 2 new features with no breaking change → **PATCH** (e.g. v1.1.1 shipped one new option
  as a patch).
- `*(website):` commits do **not** count as `feat:` (or any other prefix) for the bump.
  A website-only `feat(website):` must never trigger a MINOR.
- **Never bump MAJOR on your own** — even for a redesign; use MINOR and mention in the final
  summary that it might deserve a MAJOR. MAJOR only when the user passes it in the hint.
- When in doubt between PATCH and MINOR → choose **PATCH**.

Get current version from project (the pbxproj is the reference; `ship.sh` checks that the
App csproj carries the same one):
```bash
grep "MARKETING_VERSION" macos/PopGuy.xcodeproj/project.pbxproj | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'
```

Compute the new version from current + bump level and print it (no confirmation — continue
straight to Step B3):
```
Current version : X.Y.Z (build N)
Bump            : MINOR / PATCH
New version     : X.Y+1.0 / X.Y.Z+1
```

### Step B3: Synthesize the changelogs

**Two outputs, one heading:** a `## [X.Y.Z] - YYYY-MM-DD` section in `macos/CHANGELOG.md`
and one with the **same heading** in `windows/CHANGELOG.md`. `publish-release.sh` composes
the GitHub Release body from both (`## macOS` + the macOS section, `## Windows` + the Windows
section + the install notes); the Sparkle appcast notes get the macOS section only.

Format: [Keep a Changelog](https://keepachangelog.com/) — technical but clear.
Grouped by Added / Changed / Fixed. Use the actual commit messages as source material
but rewrite them in clear prose (no conventional-commit prefixes, no ticket numbers).

```markdown
## [X.Y.Z] - YYYY-MM-DD

### Added
- <feature described from user perspective>

### Changed
- <behavioral change>

### Fixed
- <bug fix>
```

Only include sections that have entries. Omit empty sections. Each file describes only its
own platform's app.

A platform with **no user-facing change** still gets its section, with one entry:

```markdown
## [X.Y.Z] - YYYY-MM-DD

### Changed
- No changes on Windows; this version ships with the macOS update.
```

(or `No changes on macOS; this version ships with the Windows update.` in `macos/CHANGELOG.md`).

**Never mention `website/` changes in the changelogs.** Only app behavior the user sees after
they download or update. A landing-page redesign, docs restyle, or provider-logo tweak on the
site is not a release-note item — even when the same git range includes those commits.

**Never write install or SmartScreen notes in `windows/CHANGELOG.md`:** `publish-release.sh`
appends `windows/scripts/install-notes.md` to the release body itself.

If `## [Unreleased]` in `macos/CHANGELOG.md` already has entries, they belong to this release:
move them into the new section and add any missing commits. Print both final sections in the
chat for the record, then continue — do not wait for review.

### Step B4: Update files

**1. Update the changelogs** — prepend the new `## [X.Y.Z]` section after `## [Unreleased]` in
`macos/CHANGELOG.md`, and above the previous version in `windows/CHANGELOG.md`. Keep existing
entries intact.

**2. Bump version** using the project script:
```bash
scripts/bump-version.sh X.Y.Z
```
This sets `MARKETING_VERSION` and increments `CURRENT_PROJECT_VERSION` in `project.pbxproj`,
and sets `<Version>` in the App csproj (both apps, one version). Verify the diff:
```bash
git diff macos/PopGuy.xcodeproj/project.pbxproj windows/src/PopGuy.App/PopGuy.App.csproj
```

### Step B5: Hand off to cf-ship

Proceed with the **standard cf-ship workflow** (verify → commit → push `main`).
Use `release: vX.Y.Z` as the commit message.

**Files to stage (by explicit path):**
- `macos/CHANGELOG.md`
- `windows/CHANGELOG.md`
- `macos/PopGuy.xcodeproj/project.pbxproj`
- `windows/src/PopGuy.App/PopGuy.App.csproj`

---

## After

Run the release **after** the `release: vX.Y.Z` commit is on `main` (Step B5 pushed it).
Prereqs (one-time, `docs/RELEASING.md §0`): Developer ID cert in the login Keychain, the
`popguy-notary` notarytool profile, Xcode 26+, Metal Toolchain, `gh` CLI authenticated.

### Step A1: Ship (one command)

```bash
scripts/ship.sh
```

No prompts. It runs, in order:
1. **Checks** — clean tree for every release path (`macos`, `windows`, `scripts`, `appcast.xml`,
   `LICENSE`, `windows-release.yml`), pbxproj `MARKETING_VERSION` == App csproj `<Version>`, both
   changelogs have `## [X.Y.Z]`, branch `main`, tag `vX.Y.Z` absent on this Mac and on origin,
   `gh` authenticated.
2. **Tag first** — creates the annotated tag `vX.Y.Z` at HEAD and pushes it. The push starts
   `windows-release.yml` on GitHub Actions (x64 and ARM64, in parallel with the Mac build).
3. `build-and-notarize.sh` — archive → Developer ID sign → notarize + staple → DMG
   (~15-25 min), then checks that HEAD and the release paths did not change meanwhile.
4. `windows/scripts/fetch-release.sh` — waits for the Windows run of the tag's commit, downloads
   both architectures' packages to `build/windows-release/X.Y.Z/` and checks each has its
   Setup.exe, Portable.zip, full nupkg and `releases.win-<arch>.json` naming this version.
5. `publish-release.sh --windows <dir> <zip>` (non-interactive) — reuses the pushed tag only if it
   points at HEAD locally and on origin, creates the release as a **draft** with the zip and the
   composed notes, uploads the DMG and the Windows packages, then publishes it as **Latest**.
   Nothing is public until every asset is in place. It also writes the Sparkle notes file
   (macOS section only).
6. `publish-appcast.sh` — generates the appcast, commits + pushes `appcast.xml` (the push
   redeploys Pages, with the new version in the website header).

If Keychain prompts appear during notarization or appcast signing, click **Always Allow**.
Pages deploys within ~1 min after the appcast push. No manual steps needed.

On a failure after the tag push, what to do depends on whether the release is already public:

- **Before `publish-release.sh` has published it** (a failed Windows CI run, notarization,
  `fetch-release.sh`, or the draft's upload or publish): report the failing job or step, run
  the printed undo so the tag does not dangle, and stop. Before any `gh release delete`, run
  `gh release view vX.Y.Z --json isDraft`: delete the release only when it is a draft
  (`"isDraft": true`); when no release exists, delete only the tag; when it says `false`, the
  release is public, so follow the next bullet instead. Do not resume the draft with the
  printed `--clobber` upload. The `release: vX.Y.Z` commit stays on `main`; a later `ship.sh`
  run tags it again.
- **After `publish-release.sh` has published it** (`ship.sh` says the release is published but
  the appcast was not): the macOS zip and DMG, the Windows installers and the Velopack feed are
  already public. The only automatic action is **one** re-run of
  `scripts/publish-appcast.sh build/export/PopGuy-X.Y.Z.zip`; if it fails again, stop and
  report. **Never delete a published release or its tag**, even though `ship.sh` also prints
  the full undo: that one is for a human deciding to pull a bad release (`docs/RELEASING.md`,
  Rollback).

### Step A2: Print summary

```
Shipped PopGuy vX.Y.Z — one release, Latest:
  https://github.com/dinhanhthi/PopGuy/releases/tag/vX.Y.Z
  macOS   — notarized zip + DMG (or: no changes, ships with the Windows update)
            Appcast: https://dinhanhthi.github.io/PopGuy/appcast.xml
  Windows — Setup.exe + Portable.zip for x64 and ARM64 (or: no changes, ships with the macOS update)
```

---

## Rules

- **No questions** — the whole flow runs without asking the user (see the top of Before).
- **Never create a PR** — releases go straight to `main`.
- **Never auto-bump MAJOR** — MAJOR only when the user passes it in the hint.
- **Prefer PATCH** — MINOR only for 3+ distinct new features or a breaking change.
- **One version, one release** — both apps always ship together under `vX.Y.Z`, published as
  *Latest* with both platforms' assets (the website's and README's `/releases/latest` links and
  the Windows updater depend on it). Never publish the draft without the Windows packages: a
  Velopack feed needs its nupkg in the same release.
- **Release from this Mac with `ship.sh`** — never pre-create or push the tag yourself; `ship.sh`
  tags the version-bumped commit at HEAD, and that tag push is what starts the Windows build.
- **Never push tags before committing** — the tag must point to the `release: vX.Y.Z` commit on `main`.
- **Never force past a failure** — no `--force`, no `--clobber`, and never re-tag another commit
  to get a release through. Stop and report instead (see Step A1 for the only undo allowed).
- **Never delete a published release or its tag** — an autonomous run may delete only an
  unpublished draft and the tag of a release that was never published (Step A1).
- **DMG is auto-uploaded** — `publish-release.sh` uploads both zip and DMG. If the DMG is
  missing it prints a warning with the manual command.
- **Website changes never go in release notes** — ignore `website/` and
  `*(website):` commits for bump classification and the changelogs. The website
  has had no release-notes UI since `5d522f3` removed its changelog modal.
- **Always print both changelog sections** in the chat (Step B3) — for the record, not for review.
- **Verify the archive after pbxproj changes** — a normal build can pass while `archive` fails
  (e.g. the MLX bundle symlink → `cp -RL` fix). Only `xcodebuild archive` catches it.
- **If a step is unclear, pick the most conservative option and continue** (e.g. PATCH over
  MINOR). Mention the choice in the final summary, then update this SKILL.md to encode it so
  the same doubt never comes up again.
- **Only commit these files per release:** `macos/CHANGELOG.md`, `windows/CHANGELOG.md`,
  `macos/PopGuy.xcodeproj/project.pbxproj`, `windows/src/PopGuy.App/PopGuy.App.csproj` (and
  `appcast.xml`, which `publish-appcast.sh` commits). Never stage build artifacts
  (`build/export/`, `build/windows-release/`), secrets, or `ExportOptions.plist`.
- **Windows builds only on GitHub Actions** — never `dotnet publish`/`vpk` on this Mac or in a VM.
- **Windows is not code-signed** (no Azure Trusted Signing outside the US/Canada): every release
  body carries the SmartScreen note from `windows/scripts/install-notes.md`, which
  `publish-release.sh --windows` appends. Never remove it while unsigned.
