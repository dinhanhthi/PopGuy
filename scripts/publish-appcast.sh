#!/usr/bin/env bash
#
# publish-appcast.sh — Generate + commit + push the Sparkle appcast (RELEASING.md §5).
#
# Finds generate_appcast in DerivedData, runs it over the release zip, copies appcast.xml
# to the repo root, commits, and pushes. The zip must already be notarized + stapled
# (build-and-notarize.sh) and the GitHub release must exist (publish-release.sh).
#
# Usage:
#   scripts/publish-appcast.sh build/export/PopGuy-0.4.1.zip
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ZIP="${1:-}"
[[ -n "$ZIP" ]] || { echo "usage: scripts/publish-appcast.sh <notarized-zip>" >&2; exit 1; }
[[ -f "$ZIP" ]] || { echo "error: zip not found: $ZIP" >&2; exit 1; }

# Derive version from zip filename (PopGuy-X.Y.Z.zip)
VERSION="$(basename "$ZIP" .zip | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
[[ -n "$VERSION" ]] || { echo "error: cannot derive version from zip name: $ZIP" >&2; exit 1; }

# Find generate_appcast in DerivedData (built as part of the Sparkle SPM package)
GA="$(find ~/Library/Developer/Xcode/DerivedData/PopGuy-*/SourcePackages/artifacts \
  -name generate_appcast 2>/dev/null | head -1)"
[[ -n "$GA" ]] || {
  echo "error: generate_appcast not found in DerivedData." >&2
  echo "       Build the project first (build-and-notarize.sh runs a full archive)." >&2
  exit 1
}

echo "==> Generating appcast for v$VERSION"
echo "    generate_appcast: $GA"

mkdir -p build/appcast-archives
# Copy zip only — no .md notes file (keeps the in-app update prompt compact;
# full release notes live on GitHub via --full-release-notes-url).
cp "$ZIP" build/appcast-archives/
"$GA" build/appcast-archives/ \
  --full-release-notes-url "https://github.com/dinhanhthi/PopGuy/releases" \
  --download-url-prefix "https://github.com/dinhanhthi/PopGuy/releases/download/v$VERSION/"
cp build/appcast-archives/appcast.xml appcast.xml

echo "==> Committing and pushing appcast.xml"
git add appcast.xml
git commit -m "release: appcast v$VERSION"
git push

echo
echo "Done. appcast.xml pushed — Pages deploy triggered (~1 min to go live)."
echo "  Verify: curl -fsSL https://dinhanhthi.github.io/PopGuy/appcast.xml | grep shortVersionString"
