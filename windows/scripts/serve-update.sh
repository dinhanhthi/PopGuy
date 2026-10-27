#!/usr/bin/env bash
# Serves a local Velopack update feed to the QA VM (Phase 23 update test; never left running).
#
#   windows/scripts/serve-update.sh [folder]
#
# folder: the release packages of the version to update to (a downloaded PopGuy-release-win-<arch> artifact of a
# -dev tag, which holds releases.win-<arch>.json and the full nupkg). Default: ~/Downloads/PopGuy-update/current.
# A -dev build started in the VM with POPGUY_UPDATE_URL=http://<this Mac>:8765 reads its updates from here. Ctrl+C
# stops it.
set -euo pipefail

folder="${1:-$HOME/Downloads/PopGuy-update/current}"
port=8765
if ! ls "$folder"/releases.win-*.json >/dev/null 2>&1; then
  echo "No releases.win-<arch>.json in $folder." >&2
  exit 1
fi

echo "Serving $folder on port $port. From the VM, use one of:"
ifconfig | awk '/^[a-z]/ { iface = $1 } /inet / && $2 != "127.0.0.1" { print "  POPGUY_UPDATE_URL=http://" $2 ":'"$port"'   (" iface ")" }'
cd "$folder"
exec python3 -m http.server --bind 0.0.0.0 "$port"
