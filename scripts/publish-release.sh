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
#   - release   : `gh release create` with that tag, zip asset, and notes (a draft
#                 published last with --windows, see below)
#
# --windows <dir> (the scripts/ship.sh flow) makes it the shared macOS + Windows
# release: it also needs the `## [X.Y.Z]` section of windows/CHANGELOG.md, the
# GitHub release body becomes `## macOS` + the macOS section, `## Windows` + the
# Windows section + windows/scripts/install-notes.md (the Sparkle sibling file
# keeps the macOS section only), and every file in <dir> (the Windows packages
# from windows/scripts/fetch-release.sh) is uploaded after the zip and DMG. The
# release is created as a draft and published as Latest only once every asset
# is uploaded, so Latest never lacks its Windows packages (a feed without its nupkg
# breaks updates) and a failed upload leaves a draft, not a broken public release.
# The tag vX.Y.Z may already exist then (ship.sh pushes it first to start the
# Windows build): it is reused only if it points at HEAD, locally and on origin.
#
# This does NOT build/sign/notarize (§2), run generate_appcast (§4), or commit
# anything — the user commits in parallel. It only creates+pushes the tag and the
# GitHub release.
#
# Usage:
#   scripts/publish-release.sh build/export/PopGuy-1.1.0.zip
#   scripts/publish-release.sh --windows build/windows-release/1.4.0 build/export/PopGuy-1.4.0.zip
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PBXPROJ="$REPO_ROOT/macos/PopGuy.xcodeproj/project.pbxproj"
CHANGELOG="$REPO_ROOT/macos/CHANGELOG.md"
WINDOWS_CHANGELOG="$REPO_ROOT/windows/CHANGELOG.md"
INSTALL_NOTES="$REPO_ROOT/windows/scripts/install-notes.md"
USAGE="usage: scripts/publish-release.sh [--yes] [--windows <dir>] <signed-zip>"

# The `## [X.Y.Z]` section of changelog $1 for version $2, without its heading.
# Captures lines between `## [X.Y.Z]` and the next `## ` header, then trims leading
# and trailing blank lines in the END block (portable to BSD/macOS awk).
changelog_section() {
  awk -v ver="$2" '
    BEGIN { gsub(/\./, "\\.", ver) }          # escape dots so 1.0.0 is literal, not wildcard
    capture && /^## / { exit }                # stop at the next section (or a duplicate header)
    $0 ~ ("^## \\[" ver "\\]") { capture=1; next }
    capture { buf[n++]=$0 }
    END {
      start=0;   while (start < n   && buf[start] ~ /^[[:space:]]*$/) start++
      end=n-1;   while (end >= start && buf[end]  ~ /^[[:space:]]*$/) end--
      for (i = start; i <= end; i++) print buf[i]
    }
  ' "$1"
}

# The GitHub release body of a macOS + Windows release: macOS section $1, Windows
# section $2, then how to install on Windows (file $3).
release_notes() {
  printf '## macOS\n\n%s\n\n## Windows\n\n%s\n\n' "$1" "$2"
  cat "$3"
}

cd "$REPO_ROOT"

# --- 0. Args & tools -------------------------------------------------------
YES=false
ZIP=""
WINDOWS_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) YES=true ;;
    --windows)
      [[ $# -ge 2 && -n "$2" ]] || { echo "$USAGE" >&2; exit 1; }
      WINDOWS_DIR="$2"; shift ;;
    *) ZIP="$1" ;;
  esac
  shift
done

[[ -n "$ZIP" ]]        || { echo "$USAGE" >&2; exit 1; }
[[ -f "$ZIP" ]]        || { echo "error: zip not found: $ZIP" >&2; exit 1; }
[[ -f "$PBXPROJ" ]]    || { echo "error: $PBXPROJ not found" >&2; exit 1; }
[[ -f "$CHANGELOG" ]]  || { echo "error: $CHANGELOG not found" >&2; exit 1; }
if [[ -n "$WINDOWS_DIR" ]]; then
  [[ -d "$WINDOWS_DIR" ]]         || { echo "error: Windows packages folder not found: $WINDOWS_DIR" >&2; exit 1; }
  compgen -G "$WINDOWS_DIR/*" >/dev/null || { echo "error: $WINDOWS_DIR is empty" >&2; exit 1; }
  [[ -f "$WINDOWS_CHANGELOG" ]]   || { echo "error: $WINDOWS_CHANGELOG not found" >&2; exit 1; }
  [[ -f "$INSTALL_NOTES" ]]       || { echo "error: $INSTALL_NOTES not found" >&2; exit 1; }
fi
command -v gh  >/dev/null || { echo "error: gh CLI not installed (https://cli.github.com)" >&2; exit 1; }
command -v git >/dev/null || { echo "error: git not installed" >&2; exit 1; }

# --- 1. Derive the version from the project --------------------------------
# Read from the COMMITTED pbxproj at HEAD (the tag is created at HEAD), so the tag,
# the version, and the source can never drift from an uncommitted working-tree bump.
# A version bump that wasn't committed yields a stale VERSION here and then trips the
# zip-name check in §2. All targets share one MARKETING_VERSION after bump-version.sh;
# require it to be unambiguous so the tag can't silently pick the wrong number.
VERSION="$(git show "HEAD:macos/PopGuy.xcodeproj/project.pbxproj" \
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
NOTES_BODY="$(changelog_section "$CHANGELOG" "$VERSION")"
if [[ -z "$(printf '%s' "$NOTES_BODY" | tr -d '[:space:]')" ]]; then
  echo "error: no '## [$VERSION] - …' section with content found in CHANGELOG.md." >&2
  echo "       add the release notes for $VERSION before publishing." >&2
  exit 1
fi
if [[ -n "$WINDOWS_DIR" ]]; then
  WINDOWS_NOTES_BODY="$(changelog_section "$WINDOWS_CHANGELOG" "$VERSION")"
  if [[ -z "$(printf '%s' "$WINDOWS_NOTES_BODY" | tr -d '[:space:]')" ]]; then
    echo "error: no '## [$VERSION]' section with content found in windows/CHANGELOG.md." >&2
    echo "       add the Windows release notes for $VERSION before publishing." >&2
    exit 1
  fi
fi

# Sibling notes file for generate_appcast (§4) — same notes feed the Sparkle appcast.
# Path is fixed here (for the confirmation echo); written only after the confirm in §6
# so an aborted run leaves no stray file behind.
NOTES_FILE="$(dirname "$ZIP")/PopGuy-${VERSION}.md"
# The GitHub release body: the Sparkle notes, or both platforms' notes with --windows.
RELEASE_NOTES_FILE="$NOTES_FILE"
if [[ -n "$WINDOWS_DIR" ]]; then
  RELEASE_NOTES_FILE="$(mktemp)"
  trap 'rm -f "$RELEASE_NOTES_FILE"' EXIT
fi

# --- 4. Pre-flight checks --------------------------------------------------
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != "main" ]]; then
  echo "error: releases must be tagged from 'main' (you are on '$BRANCH')." >&2
  echo "       merge your release commit to main, check it out, then re-run." >&2
  exit 1
fi

gh auth status >/dev/null 2>&1 || { echo "error: gh is not authenticated — run 'gh auth login'." >&2; exit 1; }

# With --windows, ship.sh has already pushed the tag (it starts the Windows build):
# reuse it only if it is the very tag of HEAD, locally and on origin.
TAG_EXISTS=false
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  if [[ -z "$WINDOWS_DIR" ]]; then
    echo "error: tag $TAG already exists locally. Delete it (git tag -d $TAG) or bump the version." >&2
    exit 1
  fi
  if [[ "$(git rev-parse "$TAG^{commit}")" != "$(git rev-parse HEAD)" ]]; then
    echo "error: tag $TAG exists but does not point at HEAD ($(git rev-parse --short HEAD))." >&2
    exit 1
  fi
  REMOTE_TAG="$(git ls-remote --tags origin "refs/tags/$TAG" | awk -v ref="refs/tags/$TAG" '$2 == ref { print $1 }')"
  if [[ "$REMOTE_TAG" != "$(git rev-parse "refs/tags/$TAG")" ]]; then
    echo "error: tag $TAG on origin is missing or differs from the local one; push it first:" >&2
    echo "         git push origin $TAG" >&2
    exit 1
  fi
  TAG_EXISTS=true
elif git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1; then
  echo "error: tag $TAG already exists on origin. Bump the version." >&2
  exit 1
fi
if [[ -n "$(git status --porcelain -- macos scripts appcast.xml LICENSE)" ]]; then
  echo "warning: working tree has uncommitted changes — the tag will point at HEAD, not your working copy." >&2
fi

# --- 5. Confirm ------------------------------------------------------------
echo "About to publish:"
echo "  version : $VERSION"
echo "  tag     : $TAG  (at $(git rev-parse --short HEAD) on branch $BRANCH)"
echo "  zip     : $ZIP"
echo "  notes   : $NOTES_FILE"
if [[ -n "$WINDOWS_DIR" ]]; then
  echo "  windows : $WINDOWS_DIR ($(find "$WINDOWS_DIR" -maxdepth 1 -type f | wc -l | tr -d ' ') files)"
  if [[ "$TAG_EXISTS" == true ]]; then
    echo "  (tag $TAG already pushed; reused)"
  fi
fi
echo
if [[ "$YES" == false ]]; then
  read -r -p "Proceed? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || { echo "aborted."; exit 1; }
fi

# --- 6. Tag + GitHub release ----------------------------------------------
# Write the Sparkle notes file now that the publish is confirmed.
printf '%s\n' "$NOTES_BODY" > "$NOTES_FILE"
if [[ -n "$WINDOWS_DIR" ]]; then
  release_notes "$NOTES_BODY" "$WINDOWS_NOTES_BODY" "$INSTALL_NOTES" > "$RELEASE_NOTES_FILE"
fi

if [[ "$TAG_EXISTS" == false ]]; then
  git tag -a "$TAG" -m "PopGuy $VERSION"
  git push origin "$TAG"
fi

# With --windows the release stays a draft (not public) until every asset is uploaded.
CREATE_ARGS=(--title "PopGuy $VERSION" --notes-file "$RELEASE_NOTES_FILE")
[[ -z "$WINDOWS_DIR" ]] || CREATE_ARGS+=(--draft)
if ! gh release create "$TAG" "$ZIP" "${CREATE_ARGS[@]}"; then
  echo "error: gh release create failed. The tag $TAG was already pushed." >&2
  echo "       fix the issue, then re-run gh release create, or delete the tag:" >&2
  echo "         git push origin :refs/tags/$TAG && git tag -d $TAG" >&2
  if [[ -n "$WINDOWS_DIR" ]]; then
    echo "       (re-run it with --draft, then upload the DMG and $WINDOWS_DIR/* and publish it with" >&2
    echo "       gh release edit $TAG --draft=false --latest; first 'gh release delete $TAG --yes' if a draft" >&2
    echo "       release $TAG was left behind)" >&2
  fi
  exit 1
fi

# --windows only: a step after the draft was created failed ($1). Nothing is public yet.
draft_failed() {
  local dmg_arg=""
  [[ ! -f "$DMG" ]] || dmg_arg="$DMG "
  echo "error: $1 The release $TAG is still an unpublished draft; the tag $TAG was already pushed." >&2
  echo "       fix the issue, then upload the assets and publish it:" >&2
  echo "         gh release upload $TAG $dmg_arg$WINDOWS_DIR/* --clobber &&" >&2
  echo "           gh release edit $TAG --draft=false --latest" >&2
  echo "       or delete the draft and the tag:" >&2
  echo "         gh release delete $TAG --yes && git push origin :refs/tags/$TAG && git tag -d $TAG" >&2
  exit 1
}

# Upload the DMG as the manual-download asset if it exists next to the zip.
# A raw .zip breaks when extracted with third-party unarchivers (._* files pollute
# Sparkle.framework's seal → Gatekeeper warning); the DMG is always drag-to-install.
DMG="$(dirname "$ZIP")/PopGuy-${VERSION}.dmg"
if [[ -f "$DMG" ]]; then
  echo "==> Uploading DMG: $DMG"
  if [[ -n "$WINDOWS_DIR" ]]; then
    gh release upload "$TAG" "$DMG" || draft_failed "DMG upload failed."
  else
    gh release upload "$TAG" "$DMG"
  fi
else
  echo "warning: DMG not found at $DMG — attach it manually:" >&2
  echo "         gh release upload \"$TAG\" <path-to-dmg>" >&2
fi

# The Windows packages (Setup.exe, Portable.zip, full nupkg and Velopack feed per
# architecture): the feed and its nupkg must be in the same release for updates.
# Then publish the draft as Latest, with every asset already in place.
if [[ -n "$WINDOWS_DIR" ]]; then
  echo "==> Uploading Windows packages: $WINDOWS_DIR"
  gh release upload "$TAG" "$WINDOWS_DIR"/* || draft_failed "Windows packages upload failed."
  echo "==> Publishing $TAG as Latest"
  gh release edit "$TAG" --draft=false --latest || draft_failed "publishing the draft failed."
fi

echo
echo "Done. Published $TAG → https://github.com/dinhanhthi/PopGuy/releases/tag/$TAG"
echo "Sparkle notes written to $NOTES_FILE (generate_appcast, §4, will embed them)."
