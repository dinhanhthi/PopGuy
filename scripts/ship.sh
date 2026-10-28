#!/usr/bin/env bash
#
# ship.sh — End-to-end local release of macOS + Windows as ONE version and ONE GitHub
# Release: tag → Windows build on CI ∥ macOS build → sign → notarize → release → appcast.
#
# Run this AFTER the version-bump commit (scripts/bump-version.sh X.Y.Z writes both
# apps' versions) and the `## [X.Y.Z]` sections of macos/CHANGELOG.md and
# windows/CHANGELOG.md are pushed to main. No interactive prompts:
#   1. Checks: clean tree, pbxproj MARKETING_VERSION == App csproj <Version>, both
#      changelog sections, branch main, tag vX.Y.Z not on this Mac or origin.
#   2. Creates the annotated tag vX.Y.Z at HEAD and pushes it, which starts
#      .github/workflows/windows-release.yml (Windows builds only on GitHub Actions).
#   3. Builds, signs and notarizes the macOS zip + DMG (build-and-notarize.sh).
#   4. Waits for the Windows run and downloads its packages (windows/scripts/fetch-release.sh).
#   5. Publishes one release, Latest, with both platforms' assets and notes
#      (publish-release.sh --windows), then the Sparkle appcast (publish-appcast.sh).
# Any failure after step 2 prints how to undo the tag (and the release, once made).
#
# Prereqs (one-time — RELEASING.md §0):
#   - "Developer ID Application" cert in the login Keychain
#   - notarytool credential profile (default "popguy-notary")
#   - Xcode 26+ selected (required for Icon Composer .icon)
#   - Metal Toolchain installed (Xcode → Settings → Components)
#   - gh CLI authenticated
#
# Usage:
#   scripts/ship.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Everything that goes into either app or its release.
RELEASE_PATHS=(macos windows scripts appcast.xml LICENSE .github/workflows/windows-release.yml)

if [[ -n "$(git status --porcelain -- "${RELEASE_PATHS[@]}")" ]]; then
  echo "error: commit or remove working-tree changes before building a release" >&2
  exit 1
fi
release_sha="$(git rev-parse HEAD)"

# Derive version from the committed pbxproj
PBXPROJ="macos/PopGuy.xcodeproj/project.pbxproj"
VERSION="$(grep -Eo 'MARKETING_VERSION = [^;]+;' "$PBXPROJ" \
  | sed -E 's/MARKETING_VERSION = (.+);/\1/' | sort -u)"
[[ -n "$VERSION" ]] || { echo "error: no MARKETING_VERSION found in pbxproj" >&2; exit 1; }

# One product version: the Windows App csproj must carry the same one (bump-version.sh writes both).
CSPROJ="windows/src/PopGuy.App/PopGuy.App.csproj"
CSPROJ_VERSION="$(sed -n 's:.*<Version>\(.*\)</Version>.*:\1:p' "$CSPROJ" | head -1)"
if [[ "$CSPROJ_VERSION" != "$VERSION" ]]; then
  echo "error: $CSPROJ <Version> is '$CSPROJ_VERSION', pbxproj MARKETING_VERSION is '$VERSION'." >&2
  echo "       run scripts/bump-version.sh $VERSION (or the new version) and commit." >&2
  exit 1
fi

# Both changelogs need the version's section (publish-release.sh composes the notes from them).
for changelog in macos/CHANGELOG.md windows/CHANGELOG.md; do
  if ! awk -v h="## [$VERSION]" 'index($0, h) == 1 { found = 1; exit } END { exit !found }' "$changelog"; then
    echo "error: $changelog has no '## [$VERSION]' section." >&2
    exit 1
  fi
done

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != "main" ]]; then
  echo "error: releases ship from 'main' (you are on '$BRANCH')." >&2
  exit 1
fi

TAG="v$VERSION"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
  || git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1; then
  echo "error: tag $TAG already exists. Bump the version." >&2
  exit 1
fi

gh auth status >/dev/null 2>&1 || { echo "error: gh is not authenticated — run 'gh auth login'." >&2; exit 1; }

ZIP="build/export/PopGuy-$VERSION.zip"
WINDOWS_DIR="build/windows-release/$VERSION"

echo "========================================"
echo "  Shipping PopGuy v$VERSION (macOS + Windows)"
echo "========================================"
echo

# After the tag push, any failure prints the undo. stage: tagged → published (the GitHub release exists).
stage=""
on_exit() {
  local status=$?
  [[ "$status" != 0 && -n "$stage" ]] || return 0
  echo >&2
  if [[ "$stage" == published ]]; then
    echo "error: $TAG is published, but the appcast was not. Fix the issue, then re-run:" >&2
    echo "         scripts/publish-appcast.sh $ZIP" >&2
    echo "       or undo the whole release:" >&2
    echo "         gh release delete $TAG --yes && git push origin :refs/tags/$TAG && git tag -d $TAG" >&2
  else
    echo "error: release of $TAG failed after the tag was pushed. Undo the tag:" >&2
    echo "         git push origin :refs/tags/$TAG && git tag -d $TAG" >&2
    echo "       (first 'gh release delete $TAG --yes' if publish-release.sh had created the release)" >&2
  fi
}
trap on_exit EXIT

# Step 1 — Tag HEAD and push the tag: windows-release.yml builds Windows while this Mac builds macOS
git tag -a "$TAG" -m "PopGuy $VERSION"
if ! git push origin "$TAG"; then
  git tag -d "$TAG" >/dev/null
  echo "error: could not push $TAG; the local tag was deleted." >&2
  exit 1
fi
stage=tagged

# Step 2 — Build, sign, notarize, DMG (~15-25 min; Keychain prompt → Always Allow)
scripts/build-and-notarize.sh

if [[ "$(git rev-parse HEAD)" != "$release_sha" || -n "$(git status --porcelain -- "${RELEASE_PATHS[@]}")" ]]; then
  echo "error: source changed during build; release was not published" >&2
  exit 1
fi

# Step 3 — Wait for the Windows run and download its packages
windows/scripts/fetch-release.sh "$TAG" "$WINDOWS_DIR"

# Step 4 — GitHub Release on the pushed tag (zip + DMG + Windows packages, both platforms' notes)
scripts/publish-release.sh --yes --windows "$WINDOWS_DIR" "$ZIP"
stage=published

# Step 5 — Generate + commit + push appcast
scripts/publish-appcast.sh "$ZIP"
stage=""

echo
echo "========================================"
echo "  PopGuy v$VERSION shipped!"
echo "  GitHub : https://github.com/dinhanhthi/PopGuy/releases/tag/v$VERSION"
echo "  Appcast: https://dinhanhthi.github.io/PopGuy/appcast.xml (live in ~1 min)"
echo "========================================"
