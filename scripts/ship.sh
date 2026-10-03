#!/usr/bin/env bash
#
# ship.sh — End-to-end local release: build → sign → notarize → GitHub Release → appcast.
#
# Run this AFTER the version-bump commit is pushed to main. It chains all three
# release scripts in sequence with no interactive prompts.
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

if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: commit or remove working-tree changes before building a release" >&2
  exit 1
fi
release_sha="$(git rev-parse HEAD)"

# Derive version from the committed pbxproj
PBXPROJ="PopGuy.xcodeproj/project.pbxproj"
VERSION="$(grep -Eo 'MARKETING_VERSION = [^;]+;' "$PBXPROJ" \
  | sed -E 's/MARKETING_VERSION = (.+);/\1/' | sort -u)"
[[ -n "$VERSION" ]] || { echo "error: no MARKETING_VERSION found in pbxproj" >&2; exit 1; }

ZIP="build/export/PopGuy-$VERSION.zip"

echo "========================================"
echo "  Shipping PopGuy v$VERSION"
echo "========================================"
echo

# Step 1 — Build, sign, notarize, DMG (~15-25 min; Keychain prompt → Always Allow)
scripts/build-and-notarize.sh

if [[ "$(git rev-parse HEAD)" != "$release_sha" || -n "$(git status --porcelain)" ]]; then
  echo "error: source changed during build; release was not published" >&2
  exit 1
fi

# Step 2 — Tag + GitHub Release (zip + DMG auto-uploaded)
scripts/publish-release.sh --yes "$ZIP"

# Step 3 — Generate + commit + push appcast
scripts/publish-appcast.sh "$ZIP"

echo
echo "========================================"
echo "  PopGuy v$VERSION shipped!"
echo "  GitHub : https://github.com/dinhanhthi/PopGuy/releases/tag/v$VERSION"
echo "  Appcast: https://dinhanhthi.github.io/PopGuy/appcast.xml (live in ~1 min)"
echo "========================================"
