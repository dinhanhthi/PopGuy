## Before

This is a **version bump + changelog + ship** workflow for PopGuy. The release runs
**entirely on this machine** (the local flow, `docs/RELEASING.md`): build → sign → notarize
→ DMG → GitHub Release → appcast → Pages. There is no CI release workflow; the only
workflow is `deploy-pages.yml`, which publishes the website and `appcast.xml` to Pages. The local archive
uses a warm SPM/Metal cache, so it is far faster than an always-clean CI runner.

This **Before** section handles prep (commits → version → changelogs → file updates). The
**After** section runs the actual local release.

**Two platforms, two independent releases.** The macOS app (`macos/`, tags `vX.Y.Z`, the
repository's *latest* release) ships through Before + Step A1. PopGuy for Windows (`windows/`,
its own `<Version>`, `windows/CHANGELOG.md` and `windows-vX.Y.Z` tags, never *latest*) ships
in **Step A2**, after the macOS release is fully done: its packages are built by GitHub Actions
(`windows-release.yml`, never on this Mac) and published by `windows/scripts/release.sh --yes`
— the installer **and** the portable zip, for **x64 and ARM64**. Which parts run:

| Current branch | macOS (Before, A1) | Windows (A2) |
|---|---|---|
| `main` | yes, when it has user-facing commits | yes, when `windows/` exists and has user-facing commits |
| any other branch (e.g. `windows` before its first merge) | **never** (macOS releases from `main` only) | yes, as on `main` |

**Fully autonomous — never ask the user anything.** Running `/cf-ship` is the approval for
the whole flow: version bump, changelog, commit, push to `main`, and `scripts/ship.sh`
(public GitHub Release + appcast). Do not ask to confirm the version, do not ask to review
the changelog, do not ask before pushing or before `ship.sh`. Decide with the rules below and
keep going. These overrides beat the generic cf-ship rules:

- Pushing the `release: vX.Y.Z` commit straight to `main` is expected (this repo releases
  from `main`); skip cf-ship's "never push to main" warning.
- **Never create a PR, on any branch** — skip cf-ship's PR step everywhere. On a branch other
  than `main` (e.g. `windows` before its first merge) the flow only releases Windows; merging
  that branch is the user's call.
- On a branch other than `main`, cf-ship's own commit/push steps have nothing to do before
  Step A2 (the tree is clean, the branch already pushed): the branch is pushed in W6, after the
  Windows release is public.
- A version in the hint (e.g. `/cf-ship 1.4.0`) is used as-is, skipping Step B2's classification.
- The only stops are hard failures you cannot fix: a test that still fails after one re-run,
  a build/notarize/publish script exiting non-zero, or no user-facing commits (Step B1).
  A test that fails once and passes on re-run is flaky: record it with `capture-later.sh`
  and continue.

### Step B1: Collect unreleased commits

```bash
# Get last tag
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
echo "Last tag: $LAST_TAG"

# Commits since last tag — exclude website/, appcast, version bump, and meta commits
if [ -n "$LAST_TAG" ]; then
  git log "$LAST_TAG..HEAD" --oneline --no-merges \
    -- ':!website/' ':!appcast.xml' ':!windows/' ':!.github/workflows/windows*.yml'
else
  git log --oneline --no-merges -- ':!website/' ':!appcast.xml' ':!windows/' ':!.github/workflows/windows*.yml'
fi
```

Read the output. Ignore commits that are **not app-facing**:

- Message starts with `release:`, `chore: bump`, or `release: appcast` (infrastructure).
- Conventional-commit scope is `website` — `feat(website):`, `fix(website):`, `chore(website):`, etc.
- After excluding `website/`, the leftover files are only incidental non-app paths (e.g. `.gitignore`).
  The `:!website/` pathspec is not enough on its own: a website commit that also touches
  `.gitignore` still appears in the log.

**Website work never counts as a reason to bump or as changelog material.**
`website/` deploys independently via Pages. It does not belong in `CHANGELOG.md`
(Sparkle / GitHub Release notes) — the app's only changelog since the website's
changelog modal (`ChangelogModal.jsx` + `changelog.js`) was removed in `5d522f3`
("simplify landing, actions, and docs pages"). The website has no release-notes
UI to update; `CHANGELOG.md` is the sole source of truth now.

If there are **no user-facing app commits** after filtering (or the branch is not `main`), skip
the macOS part (B2–B5 and A1) and go straight to Step A2. Stop with
`"No user-facing changes since $LAST_TAG / $LAST_WIN — nothing to ship."` only when Step A2's
W1 finds nothing for Windows either.

### Step B2: Determine version bump level

Classify the filtered commits using conventional commit prefixes:

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
  one feature each, not many.
- 1 or 2 new features with no breaking change → **PATCH** (e.g. v1.1.1 shipped one new option
  as a patch).
- `*(website):` commits do **not** count as `feat:` (or any other prefix) for the bump.
  A website-only `feat(website):` must never trigger a MINOR.
- **Never bump MAJOR on your own** — even for a redesign; use MINOR and mention in the final
  summary that it might deserve a MAJOR. MAJOR only when the user passes it in the hint.
- When in doubt between PATCH and MINOR → choose **PATCH**.

Get current version from project:
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

### Step B3: Synthesize the changelog

**One output:** `CHANGELOG.md` (for GitHub Release body + Sparkle appcast notes).

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

Only include sections that have entries. Omit empty sections.

**Never mention `website/` changes in the changelog.** Only macOS-app behavior
the user sees after they download or Sparkle-update. A landing-page redesign, docs
restyle, or provider-logo tweak on the site is not a release-note item — even when
the same git range includes those commits.

If `## [Unreleased]` already has entries, they belong to this release: move them into the new
section and add any missing commits. Print the final changelog section in the chat for the
record, then continue — do not wait for review.

### Step B4: Update files


**1. Update macos/CHANGELOG.md** — prepend the new `## [X.Y.Z]` section after `## [Unreleased]`.
Keep existing entries intact.

**2. Bump version** using the project script:
```bash
scripts/bump-version.sh X.Y.Z
```
This edits `MARKETING_VERSION` and increments `CURRENT_PROJECT_VERSION` in
`project.pbxproj`. Verify the diff:
```bash
git diff macos/PopGuy.xcodeproj/project.pbxproj
```

### Step B5: Hand off to cf-ship

Proceed with the **standard cf-ship workflow** (verify → commit → push).
Use `release: vX.Y.Z` as the commit hint/message.

**Files to stage:**
- `macos/CHANGELOG.md`
- `macos/PopGuy.xcodeproj/project.pbxproj`

---

## After

Run the local release **after** the version-bump commit is on `main` (Step B5 pushed it).
Prereqs (one-time, `docs/RELEASING.md §0`): Developer ID cert in the login Keychain, the
`popguy-notary` notarytool profile, Xcode 26+, Metal Toolchain, `gh` CLI authenticated.

### Step A1: Ship (one command)

```bash
scripts/ship.sh
```

This chains all three release scripts automatically:
1. `build-and-notarize.sh` — archive → Developer ID sign → notarize + staple → DMG (~15-25 min)
2. `publish-release.sh --yes` — tag + GitHub Release, uploads both zip and DMG
3. `publish-appcast.sh` — generates appcast, commits + pushes `appcast.xml`

If Keychain prompts appear during notarization or appcast signing, click **Always Allow**.
Pages deploys within ~1 min after push. No manual steps needed.

### Step A2: Windows release

Runs after A1 has finished (or right away when the macOS part was skipped). Never earlier:
`publish-appcast.sh` pushes the current branch, which would push the Windows version bump
before its release is public. Skip this step entirely when `windows/` does not exist on the
current branch.

**W1 — Collect unreleased Windows commits.**

```bash
LAST_WIN=$(git tag --list 'windows-v*' --sort=-v:refname | grep -v -- '-dev' | head -1)
echo "Last Windows tag: ${LAST_WIN:-none}"
if [ -n "$LAST_WIN" ]; then
  git log "$LAST_WIN..HEAD" --oneline --no-merges -- windows/ .github/workflows/windows*.yml
fi
```

User-facing = changes Windows users get: the app (`windows/src/`) and its packaging
(`windows-release.yml`). Not user-facing: `release(windows):` commits, tests, `windows/scripts/`,
`windows/tools/`, `windows/README.md`, and every `website/` change. Nothing user-facing → skip
the rest of A2 (say so in the summary).

**First release** (no `windows-v*` tag yet): ship the csproj `<Version>` as it is — no bump, no
changelog synthesis; its `## [<version>]` section in `windows/CHANGELOG.md` must already exist
(the first one, 0.1.0, does). Skip W2–W4 and go to W5. Per `docs/RELEASING.md`, the first
release runs from the `windows` branch, before `windows` is merged into `main` (the merge
deploys the site's Windows download buttons; merging is the user's call, never part of this flow).

**W2 — Version.** Same classification as Step B2 (PATCH by default, MINOR only for 3+ distinct
features or a breaking change, never MAJOR on your own), applied to the Windows commits only.

```bash
sed -n 's:.*<Version>\(.*\)</Version>.*:\1:p' windows/src/PopGuy.App/PopGuy.App.csproj | head -1
```

**W3 — Changelog.** Prepend `## [A.B.C] - YYYY-MM-DD` to `windows/CHANGELOG.md` (above the
previous version), same format and rules as Step B3: Windows-app behavior only, no website
items. Do **not** write install or SmartScreen notes there: `release.sh` appends them to the
GitHub release notes itself. Print the section in the chat.

**W4 — Bump and commit, do not push.**

```bash
sed -i '' 's:<Version>[^<]*</Version>:<Version>A.B.C</Version>:' windows/src/PopGuy.App/PopGuy.App.csproj
git diff windows/src/PopGuy.App/PopGuy.App.csproj   # exactly one line changed
git add windows/CHANGELOG.md windows/src/PopGuy.App/PopGuy.App.csproj
git commit -m "release(windows): vA.B.C"
```

The branch must not be pushed yet: on `main`, a csproj change redeploys the website, whose
Windows buttons would link to a release that does not exist yet (404).

**W5 — Publish (one command, ~10–15 min).**

```bash
bash windows/scripts/release.sh --yes
```

It pushes only the tag `windows-vA.B.C` (with the commit it points at), waits for
`windows-release.yml`, downloads and checks `PopGuy-win-{x64,arm64}-Setup.exe`,
`PopGuy-win-{x64,arm64}-Portable.zip`, the full nupkgs and both `releases.win-<arch>.json`
feeds, creates the release with the changelog section plus the install / "Windows protected
your PC" notes, and publishes it with `--latest=false` (the macOS release stays *latest*).

If the release run fails after the tag was pushed, it is a hard failure: delete the tag
(`git push origin :refs/tags/windows-vA.B.C && git tag -d windows-vA.B.C`), report the failing
job and stop. The unpushed `release(windows)` commit stays local for the next run.

**W6 — Push the branch.**

```bash
git push origin HEAD
gh run list --workflow deploy-pages.yml --limit 1   # on main: the csproj change redeploys the site
```

On `main` a `deploy-pages.yml` run must have started for this push; if not, run
`gh workflow run deploy-pages.yml --ref main`.

### Step A3: Print summary

```
Shipped:
  macOS   vX.Y.Z — notarized zip + dmg (or: skipped, <reason>)
          https://github.com/dinhanhthi/PopGuy/releases/tag/vX.Y.Z
          Appcast: https://dinhanhthi.github.io/PopGuy/appcast.xml
  Windows vA.B.C — Setup.exe + Portable.zip for x64 and ARM64, not latest (or: skipped, <reason>)
          https://github.com/dinhanhthi/PopGuy/releases/tag/windows-vA.B.C
```

---

## Rules

- **No questions** — the whole flow runs without asking the user (see the top of Before).
- **Never auto-bump MAJOR** — MAJOR only when the user passes it in the hint.
- **Prefer PATCH** — MINOR only for 3+ distinct new features or a breaking change.
- **Release locally, not via CI** — run `build-and-notarize.sh` + `publish-release.sh` on this
  machine. Do **not** push tags expecting CI to release; there is no release workflow.
- **Never push tags before committing** — the tag must point to the version-bumped commit.
  `publish-release.sh` creates + pushes the tag itself, so do not pre-create it.
- **DMG is auto-uploaded** — `publish-release.sh --yes` uploads both zip and DMG. If DMG is
  missing it prints a warning with the manual command.
- **Website changes never go in release notes** — ignore `website/` and
  `*(website):` commits for bump classification and the changelog. The website
  has had no release-notes UI since `5d522f3` removed its changelog modal.
- **Always print the changelog section** in the chat (Step B3) — for the record, not for review.
- **Verify the archive after pbxproj changes** — a normal build can pass while `archive` fails
  (e.g. the MLX bundle symlink → `cp -RL` fix). Only `xcodebuild archive` catches it.
- **If a step is unclear, pick the most conservative option and continue** (e.g. PATCH over
  MINOR). Mention the choice in the final summary, then update this SKILL.md to encode it so
  the same doubt never comes up again.
- **Only commit these files per release:** `macos/CHANGELOG.md`, `macos/PopGuy.xcodeproj/project.pbxproj`
  (and `appcast.xml`, which `publish-appcast.sh` commits); for Windows `windows/CHANGELOG.md` and
  `windows/src/PopGuy.App/PopGuy.App.csproj`. Never stage build artifacts (`build/windows-release/`
  included), secrets, or `ExportOptions.plist`.
- **Windows after macOS, tag before branch** — Step A2 starts only once A1 is done, and the
  `release(windows)` commit reaches the remote branch only after `release.sh` has published it.
- **The Windows release is never "latest"** — `release.sh` publishes with `--latest=false`; never
  change it in the web UI either. The README's and website's macOS links use `/releases/latest`.
- **Windows builds only on GitHub Actions** — never `dotnet publish`/`vpk` on this Mac or in a VM.
- **Windows is not code-signed** (no Azure Trusted Signing outside the US/Canada): every Windows
  release ships the SmartScreen note `release.sh` appends. Never remove it while unsigned.
