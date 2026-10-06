## Before

This is a **version bump + changelog + ship** workflow for PopGuy. The release runs
**entirely on this machine** (the local flow, `docs/RELEASING.md`): build → sign → notarize
→ DMG → GitHub Release → appcast → Pages. CI no longer releases — `.github/workflows/release.yml`
is `workflow_dispatch`-only (a manual emergency fallback). The local archive uses a warm
SPM/Metal cache, so it is far faster than the always-clean CI runner.

This **Before** section handles prep (commits → version → changelogs → file updates). The
**After** section runs the actual local release.

### Step B1: Collect unreleased commits

```bash
# Get last tag
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
echo "Last tag: $LAST_TAG"

# Commits since last tag — exclude website/, appcast, version bump, and meta commits
if [ -n "$LAST_TAG" ]; then
  git log "$LAST_TAG..HEAD" --oneline --no-merges \
    -- ':!website/' ':!appcast.xml'
else
  git log --oneline --no-merges -- ':!website/' ':!appcast.xml'
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

If there are **no user-facing app commits** after filtering, stop and tell the user:
`"No user-facing changes since $LAST_TAG — nothing to ship."` Do NOT proceed.

### Step B2: Determine version bump level

Classify the filtered commits using conventional commit prefixes:

| Prefix | Level |
|---|---|
| `feat:` | MINOR (x.Y.0) |
| `fix:`, `perf:`, `refactor:`, `docs:`, `chore:`, `style:`, `test:` | PATCH (x.x.Z) |

Rules:
- `*(website):` commits do **not** count as `feat:` (or any other prefix) for the bump.
  A website-only `feat(website):` must never trigger a MINOR.
- If **any** remaining `feat:` commit exists → proposed level is **MINOR**.
- If only non-feat commits remain → proposed level is **PATCH**.
- If the changes look large enough to warrant a **MAJOR** bump (breaking change, complete
  redesign, removal of core feature) → **STOP. Do NOT auto-bump. Ask the user:**
  `"Some changes look like they could justify a MAJOR version bump. Can you clarify
  whether this is breaking or backward-compatible?"`
- When in doubt between PATCH and MINOR → choose **PATCH**.

Get current version from project:
```bash
grep "MARKETING_VERSION" PopGuy.xcodeproj/project.pbxproj | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'
```

Compute the new version from current + bump level. **Show the user:**
```
Current version : X.Y.Z (build N)
Proposed bump   : MINOR / PATCH
New version     : X.Y+1.0 / X.Y.Z+1
```

**Ask for explicit confirmation before continuing:**
`"Proceed with vX.Y.Z? (yes / no / different version)"`

If the user specifies a different version, use that.

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

Write the changelog out in the chat for review **before modifying any files**.
Ask: `"Does this look right? (yes to proceed, or paste corrections)"`

### Step B4: Update files

Only after Step B3 confirmation:

**1. Update CHANGELOG.md** — prepend the new `## [X.Y.Z]` section after `## [Unreleased]`.
Keep existing entries intact.

**2. Bump version** using the project script:
```bash
scripts/bump-version.sh X.Y.Z
```
This edits `MARKETING_VERSION` and increments `CURRENT_PROJECT_VERSION` in
`project.pbxproj`. Verify the diff:
```bash
git diff PopGuy.xcodeproj/project.pbxproj
```

### Step B5: Hand off to cf-ship

Proceed with the **standard cf-ship workflow** (verify → commit → push).
Use `release: vX.Y.Z` as the commit hint/message.

**Files to stage:**
- `CHANGELOG.md`
- `PopGuy.xcodeproj/project.pbxproj`

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

### Step A2: Print summary

```
Shipped (local flow):
  PopGuy vX.Y.Z — notarized zip + dmg on the GitHub Release
  GitHub Release: https://github.com/dinhanhthi/PopGuy/releases/tag/vX.Y.Z
  Appcast: live at https://dinhanhthi.github.io/PopGuy/appcast.xml
```

---

## Rules

- **Never auto-bump MAJOR** — always ask the user to confirm before a MAJOR bump.
- **Release locally, not via CI** — run `build-and-notarize.sh` + `publish-release.sh` on this
  machine. Do **not** push tags expecting CI to release; `release.yml` is `workflow_dispatch`-only.
- **Never push tags before committing** — the tag must point to the version-bumped commit.
  `publish-release.sh` creates + pushes the tag itself, so do not pre-create it.
- **DMG is auto-uploaded** — `publish-release.sh --yes` uploads both zip and DMG. If DMG is
  missing it prints a warning with the manual command.
- **Website changes never go in release notes** — ignore `website/` and
  `*(website):` commits for bump classification and the changelog. The website
  has had no release-notes UI since `5d522f3` removed its changelog modal.
- **Always show the changelog for review before writing files** — Step B3 is mandatory.
- **Verify the archive after pbxproj changes** — a normal build can pass while `archive` fails
  (e.g. the MLX bundle symlink → `cp -RL` fix). Only `xcodebuild archive` catches it.
- **If a step is unclear, stop and ask** — do not guess. Then update this SKILL.md to
  encode the answer so the same question is never asked again.
- **Only commit these files per release:** `CHANGELOG.md`, `PopGuy.xcodeproj/project.pbxproj`
  (and `appcast.xml` in Step A3). Never stage build artifacts, secrets, or `ExportOptions.plist`.
