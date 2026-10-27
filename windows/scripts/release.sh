#!/usr/bin/env bash
# Releases PopGuy for Windows from this Mac (the Windows twin of scripts/ship.sh; builds run only on GitHub Actions).
#
#   windows/scripts/release.sh
#
# 1. Checks that windows/ has no uncommitted change and reads <Version> from the App csproj.
# 2. Asks, then pushes the tag windows-v<version>, which runs .github/workflows/windows-release.yml.
# 3. Waits for the run and downloads both architectures' packages to build/windows-release/<version>/.
# 4. Checks that each architecture has its Setup.exe, full nupkg and releases.win-<arch>.json.
# 5. Creates the GitHub release as a draft, with the version's section of windows/CHANGELOG.md as its notes.
# 6. Asks, then publishes it as not the latest release: GitHub decides "latest" at publish time, and the README's and
#    the website's macOS download links point at /releases/latest, so the macOS release must stay "latest". Answer no
#    to check the draft on GitHub first, then run the printed command (in the web UI, untick "Set as the latest
#    release" before Publish).
#
# Never publish a -dev tag's packages: QA builds read their update feed from an environment variable (the app's
# update check skips -dev tags too).
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
cd "$root"

if [[ -n "$(git status --porcelain -- windows)" ]]; then
  echo "windows/ has uncommitted changes; commit them first." >&2
  exit 1
fi

version="$(sed -n 's:.*<Version>\(.*\)</Version>.*:\1:p' windows/src/PopGuy.App/PopGuy.App.csproj | head -1)"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Could not read a <major>.<minor>.<patch> <Version> from the App csproj (got '$version')." >&2
  exit 1
fi
tag="windows-v$version"

notes="$(mktemp)"
trap 'rm -f "$notes"' EXIT
# The "## [<version>]" section of the changelog, without its heading.
awk -v v="$version" '
  /^## \[/ { if (found) exit; if (index($0, "## [" v "]") == 1) { found = 1; next } }
  found { print }
' windows/CHANGELOG.md > "$notes"
if [[ ! -s "$notes" ]]; then
  echo "windows/CHANGELOG.md has no '## [$version]' section." >&2
  exit 1
fi

if git rev-parse -q --verify "refs/tags/$tag" >/dev/null || git ls-remote --exit-code --tags origin "$tag" >/dev/null 2>&1; then
  echo "Tag $tag already exists." >&2
  exit 1
fi

echo "Release PopGuy for Windows $version from $(git rev-parse --short HEAD) ($(git branch --show-current))."
read -r -p "Push tag $tag? [y/N] " answer
[[ "$answer" == [yY] ]] || { echo "Cancelled."; exit 1; }

git tag "$tag"
git push origin "$tag"

echo "Waiting for the release run…"
run=""
for _ in $(seq 1 30); do
  run="$(gh run list --workflow windows-release.yml --branch "$tag" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || true)"
  [[ -n "$run" ]] && break
  sleep 5
done
if [[ -z "$run" ]]; then
  echo "No windows-release run found for $tag." >&2
  exit 1
fi
gh run watch "$run" --exit-status

out="build/windows-release/$version"
rm -rf "$out"
mkdir -p "$out"
for arch in x64 arm64; do
  gh run download "$run" -n "PopGuy-release-win-$arch" -D "$out"
done

missing=0
for arch in x64 arm64; do
  for pattern in "PopGuy-win-$arch-Setup.exe" "PopGuy-$version-win-$arch-full.nupkg" "releases.win-$arch.json"; do
    if [[ ! -f "$out/$pattern" ]]; then
      echo "Missing $pattern in $out." >&2
      missing=1
    fi
  done
done
[[ "$missing" == 0 ]] || exit 1
ls -l "$out"

gh release create "$tag" "$out"/* \
  --draft \
  --title "PopGuy for Windows $version" \
  --notes-file "$notes"
echo "Draft release $tag created."

publish=(gh release edit "$tag" --draft=false --latest=false)
read -r -p "Publish $tag now (not as the latest release)? [y/N] " answer
if [[ "$answer" == [yY] ]]; then
  "${publish[@]}"
  echo "Published $tag; the macOS release stays the latest."
else
  echo "Not published. Check the draft on GitHub, then run:"
  echo "  ${publish[*]}"
  echo "(In the web UI, untick \"Set as the latest release\" before Publish.)"
fi
