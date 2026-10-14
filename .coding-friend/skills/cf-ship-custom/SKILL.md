## Before

This is a **version bump + changelog + ship** workflow for PopGuy. The release runs
**entirely on this machine** (the local flow, `docs/RELEASING.md`): build → sign → notarize
→ DMG → GitHub Release → appcast → Pages. There is no CI release workflow; the only
workflow is `deploy-pages.yml`, which publishes the website and `appcast.xml` to Pages. The local archive
uses a warm SPM/Metal cache, so it is far faster than an always-clean CI runner.

This **Before** section handles prep (commits → version → changelogs → file updates). The
**After** section runs the actual local release.

**Fully autonomous — never ask the user anything.** Running `/cf-ship` is the approval for
the whole flow: version bump, changelog, commit, push to `main`, and `scripts/ship.sh`
(public GitHub Release + appcast). Do not ask to confirm the version, do not ask to review
the changelog, do not ask before pushing or before `ship.sh`. Decide with the rules below and
keep going. These overrides beat the generic cf-ship rules:

- Pushing the `release: vX.Y.Z` commit straight to `main` is expected (this repo releases
  from `main`); skip cf-ship's "never push to main" warning and its PR step.
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
grep "MARKETING_VERSION" PopGuy.xcodeproj/project.pbxproj | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'
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
- **Only commit these files per release:** `CHANGELOG.md`, `PopGuy.xcodeproj/project.pbxproj`
  (and `appcast.xml` in Step A3). Never stage build artifacts, secrets, or `ExportOptions.plist`.
