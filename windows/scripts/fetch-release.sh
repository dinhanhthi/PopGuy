#!/usr/bin/env bash
# Downloads the PopGuy for Windows release packages that GitHub Actions built for a tag (builds run only there).
#
#   windows/scripts/fetch-release.sh <tag> <out-dir>
#
# 1. Finds the .github/workflows/windows-release.yml push run of <tag> (pushed by scripts/ship.sh) built from the
#    tag's commit, and waits for it. An older run of a deleted tag of the same name (ship.sh's undo) never matches.
# 2. Downloads both architectures' packages to <out-dir> (emptied first).
# 3. Checks that each architecture has its Setup.exe, Portable.zip, full nupkg and releases.win-<arch>.json, and that
#    the feed names this version's nupkg.
#
# scripts/ship.sh runs it, then uploads the files with the macOS assets (scripts/publish-release.sh --windows).
set -euo pipefail

if [[ $# -ne 2 || -z "$1" || -z "$2" ]]; then
  echo "Usage: windows/scripts/fetch-release.sh <tag> <out-dir>" >&2
  exit 2
fi
tag="$1"
out="$2"

# v1.4.0 → 1.4.0 (windows-v… for QA tags), as windows-release.yml reads it.
version="${tag#windows-}"
version="${version#v}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
  echo "Tag $tag is not [windows-]v<major>.<minor>.<patch>[-suffix]." >&2
  exit 2
fi

# The commit the tag points at: the local tag, else the one on origin (the peeled ^{} line of an annotated tag).
sha="$(git rev-parse -q --verify "refs/tags/$tag^{commit}" || true)"
if [[ -z "$sha" ]]; then
  remote="$(git ls-remote origin "refs/tags/$tag" "refs/tags/$tag^{}" || true)"
  sha="$(awk -v ref="refs/tags/$tag^{}" '$2 == ref { print $1 }' <<<"$remote")"
  [[ -n "$sha" ]] || sha="$(awk -v ref="refs/tags/$tag" '$2 == ref { print $1 }' <<<"$remote")"
fi
if [[ -z "$sha" ]]; then
  echo "Tag $tag not found locally or on origin." >&2
  exit 1
fi

echo "Waiting for the Windows release run of $tag at ${sha:0:7}…"
match=""
for _ in $(seq 1 30); do
  # Newest first; the first run built from the tag's commit wins (id, then status).
  runs="$(gh run list --workflow windows-release.yml --branch "$tag" --event push --limit 20 \
    --json databaseId,headSha,status --jq '.[] | [.databaseId, .headSha, .status] | @tsv' 2>/dev/null || true)"
  match="$(awk -F '\t' -v sha="$sha" '$2 == sha { print $1 " " $3; exit }' <<<"$runs")"
  [[ -n "$match" ]] && break
  sleep 5
done
if [[ -z "$match" ]]; then
  echo "No windows-release run of $tag at $sha found (older runs of a deleted $tag do not count)." >&2
  exit 1
fi
run="${match%% *}"
echo "Run $run (${match#* })."
gh run watch "$run" --exit-status

rm -rf "$out"
mkdir -p "$out"
for arch in x64 arm64; do
  gh run download "$run" -n "PopGuy-release-win-$arch" -D "$out"
done

missing=0
for arch in x64 arm64; do
  for pattern in "PopGuy-win-$arch-Setup.exe" "PopGuy-win-$arch-Portable.zip" "PopGuy-$version-win-$arch-full.nupkg" \
    "releases.win-$arch.json"; do
    if [[ ! -f "$out/$pattern" ]]; then
      echo "Missing $pattern in $out." >&2
      missing=1
    fi
  done
  feed="$out/releases.win-$arch.json"
  if [[ -f "$feed" ]] && ! grep -qF "PopGuy-$version-win-$arch-full.nupkg" "$feed"; then
    echo "$feed does not name PopGuy-$version-win-$arch-full.nupkg." >&2
    missing=1
  fi
done
[[ "$missing" == 0 ]] || exit 1
ls -l "$out"
