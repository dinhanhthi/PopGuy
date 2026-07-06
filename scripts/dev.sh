#!/usr/bin/env bash
#
# dev.sh — Build & launch the local dev version WITHOUT keeping Xcode open.
#
# Xcode's Run (▶) attaches a debugger, so quitting Xcode kills the app. The built
# .app is a standalone binary — this script builds it and launches it directly,
# so you never need Xcode running.
#
# No re-approval of Accessibility on each rebuild:
#   - Fixed output path (build/dev) → stable app path, so macOS TCC keeps the grant.
#   - Project's own signing (Apple Development, Team 86H6CNLN4C, bundle
#     dinh.thi.PopGuy) → stable code-signature identity, which is what TCC keys
#     the Accessibility permission on. Same cert + same bundle id + same path
#     across rebuilds = no new prompt.
#
# Usage:
#   scripts/dev.sh              # incremental build + launch
#   scripts/dev.sh --clean      # clean build first (use if things get weird)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

DERIVED="build/dev"
APP="$DERIVED/Build/Products/Debug/PopGuy.app"

CLEAN_ACTION=""
[[ "${1:-}" == "--clean" ]] && CLEAN_ACTION="clean"

echo "==> Stopping any running PopGuy…"
killall PopGuy 2>/dev/null || true

echo "==> Building (Debug)…"
xcodebuild \
  -project PopGuy.xcodeproj \
  -scheme PopGuy \
  -configuration Debug \
  -derivedDataPath "$DERIVED" \
  $CLEAN_ACTION build

echo "==> Launching $APP"
open "$APP"

echo "Done. You can close this terminal and Xcode — PopGuy keeps running."
