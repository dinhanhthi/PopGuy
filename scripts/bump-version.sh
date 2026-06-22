#!/usr/bin/env bash
#
# bump-version.sh — Bump PopGuy's version for a release (RELEASING.md §1).
#
# Edits the two version build settings directly in project.pbxproj:
#   MARKETING_VERSION       -> CFBundleShortVersionString (user-facing)
#   CURRENT_PROJECT_VERSION -> CFBundleVersion (build number, Sparkle compare key)
#
# The build number ALWAYS increments by 1. Sparkle ships an update only when
# CFBundleVersion strictly increases — bump it every single release.
#
# agvtool is intentionally NOT used: this project has no
# VERSIONING_SYSTEM = apple-generic, so agvtool misreads the versions. A direct
# pbxproj edit is the reliable path. Info.plist needs no edit — the app target
# has GENERATE_INFOPLIST_FILE = YES, which derives both keys from these settings.
#
# All targets (app + test bundles) are set to the same numbers; test-bundle
# versions are cosmetic and never distributed.
#
# Usage:
#   scripts/bump-version.sh 1.1.0     # set marketing version 1.1.0, build +1
#   scripts/bump-version.sh           # keep marketing version, build +1 only
#
# Review the diff and commit the bump yourself.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PBXPROJ="$REPO_ROOT/PopGuy.xcodeproj/project.pbxproj"
NEW_MARKETING="${1:-}"

[[ -f "$PBXPROJ" ]] || { echo "error: $PBXPROJ not found" >&2; exit 1; }

if [[ -n "$NEW_MARKETING" && ! "$NEW_MARKETING" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
  echo "error: marketing version must look like 1.2 or 1.2.3 (got \"$NEW_MARKETING\")" >&2
  exit 1
fi

# --- Current build number = highest CURRENT_PROJECT_VERSION across targets ---
CURRENT_BUILD="$(grep -Eo 'CURRENT_PROJECT_VERSION = [0-9]+;' "$PBXPROJ" \
  | grep -Eo '[0-9]+' | sort -n | tail -1)"
[[ -n "$CURRENT_BUILD" ]] || { echo "error: no CURRENT_PROJECT_VERSION found in pbxproj" >&2; exit 1; }
NEXT_BUILD=$((CURRENT_BUILD + 1))

# --- Apply -----------------------------------------------------------------
perl -i -pe "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = ${NEXT_BUILD};/g" "$PBXPROJ"
if [[ -n "$NEW_MARKETING" ]]; then
  perl -i -pe "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = ${NEW_MARKETING};/g" "$PBXPROJ"
fi

# --- Confirm ---------------------------------------------------------------
echo "==> Build number (CFBundleVersion):  ${CURRENT_BUILD} -> ${NEXT_BUILD}"
if [[ -n "$NEW_MARKETING" ]]; then
  echo "==> Marketing version:               set to ${NEW_MARKETING}"
else
  echo "==> Marketing version:               unchanged"
fi
echo
grep -n "MARKETING_VERSION\|CURRENT_PROJECT_VERSION" "$PBXPROJ"
echo
echo "Review, then commit:  git diff PopGuy.xcodeproj/project.pbxproj"
