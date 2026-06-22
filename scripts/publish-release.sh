#!/usr/bin/env bash
#
# publish-release.sh — Tag + publish a PopGuy release (RELEASING.md §5).
#
# Runs at the END of a release, after the notarized + stapled .zip exists (§2).
# Ties four things to ONE source of truth so they can never drift:
#   - version   : derived from MARKETING_VERSION in project.pbxproj (= the app's
#                 CFBundleShortVersionString, so the tag always matches the app)
#   - tag       : vX.Y.Z, created at HEAD and pushed
#   - notes     : the `## [X.Y.Z]` section of CHANGELOG.md, reused for BOTH
#                 the GitHub release body AND the Sparkle appcast (emitted as a
#                 sibling PopGuy-X.Y.Z.md next to the zip for generate_appcast, §4)
#   - release   : `gh release create` with that tag, zip asset, and notes
#
# This does NOT build/sign/notarize (§2), run generate_appcast (§4), or commit
# anything — the user commits in parallel. It only creates+pushes the tag and the
# GitHub release.
#
# Usage:
#   scripts/publish-release.sh build/export/PopGuy-1.1.0.zip
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PBXPROJ="$REPO_ROOT/PopGuy.xcodeproj/project.pbxproj"
CHANGELOG="$REPO_ROOT/CHANGELOG.md"
ZIP="${1:-}"

cd "$REPO_ROOT"

# --- 0. Args & tools -------------------------------------------------------
[[ -n "$ZIP" ]]        || { echo "usage: scripts/publish-release.sh <signed-zip>" >&2; exit 1; }
[[ -f "$ZIP" ]]        || { echo "error: zip not found: $ZIP" >&2; exit 1; }
[[ -f "$PBXPROJ" ]]    || { echo "error: $PBXPROJ not found" >&2; exit 1; }
[[ -f "$CHANGELOG" ]]  || { echo "error: $CHANGELOG not found" >&2; exit 1; }
command -v gh  >/dev/null || { echo "error: gh CLI not installed (https://cli.github.com)" >&2; exit 1; }
command -v git >/dev/null || { echo "error: git not installed" >&2; exit 1; }

# --- 1. Derive the version from the project --------------------------------
# Read from the COMMITTED pbxproj at HEAD (the tag is created at HEAD), so the tag,
# the version, and the source can never drift from an uncommitted working-tree bump.
# A version bump that wasn't committed yields a stale VERSION here and then trips the
# zip-name check in §2. All targets share one MARKETING_VERSION after bump-version.sh;
# require it to be unambiguous so the tag can't silently pick the wrong number.
VERSION="$(git show "HEAD:PopGuy.xcodeproj/project.pbxproj" \
  | grep -Eo 'MARKETING_VERSION = [^;]+;' \
  | sed -E 's/MARKETING_VERSION = (.+);/\1/' | sort -u)"
if [[ -z "$VERSION" ]]; then
  echo "error: no MARKETING_VERSION found in pbxproj" >&2; exit 1
fi
if [[ "$(printf '%s\n' "$VERSION" | wc -l | tr -d ' ')" != "1" ]]; then
  echo "error: MARKETING_VERSION is not consistent across targets:" >&2
  printf '  %s\n' $VERSION >&2
  echo "       run scripts/bump-version.sh to normalize them." >&2
  exit 1
fi
TAG="v$VERSION"

# --- 2. Zip filename must match the version --------------------------------
ZIP_BASE="$(basename "$ZIP")"
if [[ "$ZIP_BASE" != *"$VERSION"* ]]; then
  echo "error: zip name \"$ZIP_BASE\" does not contain version \"$VERSION\" (from HEAD)." >&2
  echo "       did you forget to commit the version bump, bump-version, or pass the wrong zip?" >&2
  exit 1
fi

# --- 3. Extract the CHANGELOG section for this version ----------------------
# Capture lines between `## [X.Y.Z]` and the next `## ` header, then trim leading
# and trailing blank lines in the END block (portable to BSD/macOS awk).
NOTES_BODY="$(awk -v ver="$VERSION" '
  BEGIN { gsub(/\./, "\\.", ver) }          # escape dots so 1.0.0 is literal, not wildcard
  capture && /^## / { exit }                # stop at the next section (or a duplicate header)
  $0 ~ ("^## \\[" ver "\\]") { capture=1; next }
  capture { buf[n++]=$0 }
  END {
    start=0;   while (start < n   && buf[start] ~ /^[[:space:]]*$/) start++
    end=n-1;   while (end >= start && buf[end]  ~ /^[[:space:]]*$/) end--
    for (i = start; i <= end; i++) print buf[i]
  }
' "$CHANGELOG")"
if [[ -z "$(printf '%s' "$NOTES_BODY" | tr -d '[:space:]')" ]]; then
  echo "error: no '## [$VERSION] - …' section with content found in CHANGELOG.md." >&2
  echo "       add the release notes for $VERSION before publishing." >&2
  exit 1
fi

# Sibling notes file for generate_appcast (§4) — same notes feed the Sparkle appcast.
# Path is fixed here (for the confirmation echo); written only after the confirm in §6
# so an aborted run leaves no stray file behind.
NOTES_FILE="$(dirname "$ZIP")/PopGuy-${VERSION}.md"

# --- 4. Pre-flight checks --------------------------------------------------
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != "main" ]]; then
  echo "error: releases must be tagged from 'main' (you are on '$BRANCH')." >&2
  echo "       merge your release commit to main, check it out, then re-run." >&2
  exit 1
fi

gh auth status >/dev/null 2>&1 || { echo "error: gh is not authenticated — run 'gh auth login'." >&2; exit 1; }

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "error: tag $TAG already exists locally. Delete it (git tag -d $TAG) or bump the version." >&2
  exit 1
fi
if git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1; then
  echo "error: tag $TAG already exists on origin. Bump the version." >&2
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "warning: working tree has uncommitted changes — the tag will point at HEAD, not your working copy." >&2
fi

# --- 5. Confirm ------------------------------------------------------------
echo "About to publish:"
echo "  version : $VERSION"
echo "  tag     : $TAG  (at $(git rev-parse --short HEAD) on branch $BRANCH)"
echo "  zip     : $ZIP"
echo "  notes   : $NOTES_FILE"
echo
read -r -p "Proceed? [y/N] " reply
[[ "$reply" =~ ^[Yy]$ ]] || { echo "aborted."; exit 1; }

# --- 6. Tag + GitHub release ----------------------------------------------
# Write the Sparkle notes file now that the publish is confirmed.
printf '%s\n' "$NOTES_BODY" > "$NOTES_FILE"

git tag -a "$TAG" -m "PopGuy $VERSION"
git push origin "$TAG"

if ! gh release create "$TAG" "$ZIP" \
  --title "PopGuy $VERSION" \
  --notes-file "$NOTES_FILE"; then
  echo "error: gh release create failed. The tag $TAG was already pushed." >&2
  echo "       fix the issue, then re-run gh release create, or delete the tag:" >&2
  echo "         git push origin :refs/tags/$TAG && git tag -d $TAG" >&2
  exit 1
fi

echo
echo "Done. Published $TAG → https://github.com/dinhanhthi/PopGuy/releases/tag/$TAG"
echo "Sparkle notes written to $NOTES_FILE (generate_appcast, §4, will embed them)."
