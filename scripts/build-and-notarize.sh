#!/usr/bin/env bash
#
# build-and-notarize.sh — Build → sign → notarize → staple a release locally (RELEASING.md §2).
#
# The local equivalent of the heavy build steps in .github/workflows/release.yml. On your
# Mac the SPM + DerivedData cache persists, so the MLX/Metal compile is only slow the FIRST
# time — far faster than CI's always-clean runner (which recompiles MLX + Metal every run).
#
# Produces, under build/export/:
#   - PopGuy-<version>.zip   notarized + stapled  → Sparkle auto-update asset
#   - PopGuy-<version>.dmg    notarized + stapled  → manual-download asset
# Then hand the .zip to scripts/publish-release.sh (§4) to tag + create the GitHub Release.
#
# Prereqs (one-time — see RELEASING.md §0):
#   - "Developer ID Application" cert in the login Keychain                  (§0.1)
#   - notarytool credential profile (default "popguy-notary")               (§0.1 step 6)
#   - Xcode 26+ selected — REQUIRED to compile the Icon Composer .icon icon  (release.yml note)
#   - Metal Toolchain installed (already present if you build MLX locally; otherwise run
#     `xcodebuild -downloadComponent MetalToolchain` once — it links the PopGuyMLXHelper).
#
# Notarization talks to Apple, so this needs network — "local" means your machine, not offline.
#
# Usage:
#   scripts/build-and-notarize.sh
#   POPGUY_NOTARY_PROFILE=my-profile scripts/build-and-notarize.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PBXPROJ="PopGuy.xcodeproj/project.pbxproj"
INFO_PLIST="PopGuy/Info.plist"
ARCHIVE="build/PopGuy.xcarchive"
EXPORT_DIR="build/export"
APP="$EXPORT_DIR/PopGuy.app"
NOTARY_PROFILE="${POPGUY_NOTARY_PROFILE:-popguy-notary}"

# Submit to Apple and FAIL the script on anything other than "Accepted". notarytool exits 0
# even when the status is Invalid, so without this an Invalid result sails on into stapler and
# surfaces as a confusing "Error 65" instead of a clear stop. On failure, print the log command.
notarize() {  # $1 = file to submit (zip or dmg)
  local out sid
  out="$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"
  echo "$out"
  grep -q "status: Accepted" <<<"$out" && return 0
  sid="$(grep -m1 '  id:' <<<"$out" | awk '{print $2}')"
  echo "error: notarization not Accepted for $1 — pull the log to see which binary failed:" >&2
  echo "       xcrun notarytool log $sid --keychain-profile $NOTARY_PROFILE" >&2
  exit 1
}

# --- 0. Tools & prereqs ----------------------------------------------------
command -v xcodebuild >/dev/null || { echo "error: xcodebuild not found" >&2; exit 1; }
[[ -f "$PBXPROJ" ]] || { echo "error: $PBXPROJ not found — run from the PopGuy repo" >&2; exit 1; }

# Xcode 26+ is REQUIRED to compile the Icon Composer .icon app icon; older toolchains
# silently ship a blank icon (the v0.1.1 regression). Fail loudly if not on 26+.
XCODE_VER="$(xcodebuild -version | sed -n '1s/^Xcode //p')"
case "$XCODE_VER" in
  26.*|2[7-9].*|[3-9][0-9].*) : ;;
  *) echo "error: Xcode 26+ required to compile the .icon app icon (have ${XCODE_VER:-unknown})." >&2
     echo "       sudo xcode-select -s /Applications/Xcode_26.app" >&2; exit 1 ;;
esac

security find-identity -v -p codesigning | grep -q "Developer ID Application" \
  || { echo "error: no 'Developer ID Application' identity in the keychain (RELEASING.md §0.1)." >&2; exit 1; }

# --- 1. Derive the version from the working tree ---------------------------
# The built app's CFBundleShortVersionString comes from MARKETING_VERSION on disk, so name
# the artifacts from the SAME value. bump-version.sh keeps all targets in sync; require it to
# be unambiguous so the artifact name can't silently pick the wrong number. publish-release.sh
# (§4) later re-checks the zip name against the COMMITTED version — commit the bump first.
VERSION="$(grep -Eo 'MARKETING_VERSION = [^;]+;' "$PBXPROJ" \
  | sed -E 's/MARKETING_VERSION = (.+);/\1/' | sort -u)"
[[ -n "$VERSION" ]] || { echo "error: no MARKETING_VERSION found in pbxproj" >&2; exit 1; }
if [[ "$(printf '%s\n' "$VERSION" | wc -l | tr -d ' ')" != "1" ]]; then
  echo "error: MARKETING_VERSION is not consistent across targets:" >&2
  printf '  %s\n' $VERSION >&2
  echo "       run scripts/bump-version.sh to normalize them." >&2
  exit 1
fi

echo "==> Building PopGuy $VERSION (notary profile: $NOTARY_PROFILE)"

# --- 2. Stamp today's release date into Info.plist (ephemeral) -------------
# PGReleaseDate is a manual Info.plist key (not derived from build settings), so without
# this it goes stale and the About tab shows the previous release's date. Bake it into the
# build, then restore the file on exit so the working tree is never left dirty (the stamp is
# never committed — matches release.yml's ephemeral edit on the clean runner).
if /usr/libexec/PlistBuddy -c "Print :PGReleaseDate" "$INFO_PLIST" >/dev/null 2>&1; then
  INFO_BACKUP="$(mktemp)"
  cp "$INFO_PLIST" "$INFO_BACKUP"
  trap 'cp "$INFO_BACKUP" "$INFO_PLIST"; rm -f "$INFO_BACKUP"' EXIT
  /usr/libexec/PlistBuddy -c "Set :PGReleaseDate $(date -u +%Y-%m-%d)" "$INFO_PLIST"
  echo "==> Stamped PGReleaseDate = $(date -u +%Y-%m-%d) (will be restored on exit)"
fi

# --- 3. Archive (the heavy MLX/Metal build) --------------------------------
# -skipMacroValidation: mlx-swift-lm's MLXHuggingFace uses a Swift macro that otherwise needs
# a one-time GUI "Trust & Enable"; skip the fingerprint check so the build never blocks.
rm -rf "$ARCHIVE" "$EXPORT_DIR"
xcodebuild -project PopGuy.xcodeproj -scheme PopGuy \
  -configuration Release \
  -skipMacroValidation \
  -archivePath "$ARCHIVE" archive

# --- 4. Extract the Developer-ID-signed app from the archive ---------------
# The Release archive already signs PopGuy.app with Developer ID + hardened runtime + a secure
# timestamp (the project's Release config signs directly — RELEASING.md §0.1), so it is already
# distribution-ready. We deliberately do NOT run `xcodebuild -exportArchive`: on Xcode 26 it
# fails for this app because IDEDistribution cannot enumerate a distribution method for a bundle
# with an embedded helper executable (the MLX helper) and errors `expected one {}` (empty set).
# Copy the app out with ditto (preserves bundle structure + signatures; never cp -R, which would
# copy nested symlinks verbatim and dangle — the bug that broke the embed script).
mkdir -p "$EXPORT_DIR"
ditto "$ARCHIVE/Products/Applications/PopGuy.app" "$APP"
# Sanity-gate the extracted app before the (slow) notarization round-trip. Capture codesign
# output into a var first: piping `codesign | grep -q` trips `set -o pipefail` — grep -q exits
# on first match, SIGPIPEs codesign (exit 141), and the pipeline is wrongly seen as failed.
SIGN_INFO="$(codesign -dvvv "$APP" 2>&1)"
grep -q "Authority=Developer ID Application" <<<"$SIGN_INFO" \
  || { echo "error: extracted app is not Developer ID signed" >&2; exit 1; }
grep -q "flags=.*runtime" <<<"$SIGN_INFO" \
  || { echo "error: extracted app lacks the hardened runtime — notarization will reject it" >&2; exit 1; }
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "get-task-allow"; then
  echo "error: app carries get-task-allow (Debug entitlement) — instant notarization reject" >&2; exit 1
fi
echo "==> Extracted Developer-ID-signed app from archive"

# --- 4b. Re-sign Sparkle's nested helpers with Developer ID + secure timestamp ----
# The archive signs the app, frameworks, and MLX helper, but leaves Sparkle's deeply nested code
# (Updater.app, Autoupdate, the two XPC services) ADHOC-signed with no secure timestamp —
# notarization rejects exactly those 4. `xcodebuild -exportArchive` would have deep-re-signed
# them, but it is broken on Xcode 26 (see §4), so do it explicitly. Sign inside-out (nested code
# first → framework → outer app; touching nested code breaks every seal above it).
# --preserve-metadata=entitlements keeps each helper's entitlements while adding Developer ID +
# secure timestamp + hardened runtime. Resolve the version letter (Current → e.g. B) so a future
# Sparkle bump that changes it does not silently skip these paths.
SPK="$APP/Contents/Frameworks/Sparkle.framework"
SPKV="$SPK/Versions/$(readlink "$SPK/Versions/Current" 2>/dev/null || echo B)"
resign() { codesign --force --options runtime --timestamp --preserve-metadata=entitlements \
  --sign "Developer ID Application" "$1"; }
resign "$SPKV/XPCServices/Downloader.xpc"
resign "$SPKV/XPCServices/Installer.xpc"
resign "$SPKV/Updater.app"
resign "$SPKV/Autoupdate"
resign "$SPK"        # re-seal the framework over the re-signed helpers
resign "$APP"        # re-seal the outer app over the re-signed framework
codesign --verify --deep --strict "$APP" \
  || { echo "error: deep signature verification failed after re-signing Sparkle" >&2; exit 1; }
echo "==> Re-signed Sparkle nested helpers (Developer ID + timestamp)"

# --- 5. Guard against a blank-icon build (the v0.1.1 regression) -----------
# If the .icon did not compile, actool ships the raw logo.icon folder instead of an app icon.
test -f "$APP/Contents/Resources/logo.icns" \
  || { echo "error: logo.icns missing — the .icon app icon did not compile (need Xcode 26+)." >&2; exit 1; }
/usr/libexec/PlistBuddy -c "Print :CFBundleIconName" "$APP/Contents/Info.plist" >/dev/null \
  || { echo "error: CFBundleIconName missing from Info.plist." >&2; exit 1; }
[[ ! -e "$APP/Contents/Resources/logo.icon" ]] \
  || { echo "error: raw logo.icon copied unprocessed into Resources." >&2; exit 1; }
echo "==> App icon compiled OK"

# --- 6. Notarize + staple the app, then ship-zip it ------------------------
# The first zip is a THROWAWAY upload for notarytool; the file we ship is the re-zip AFTER
# stapling (the staple writes the ticket into the .app, not the zip).
( cd "$EXPORT_DIR" && ditto -c -k --keepParent PopGuy.app "PopGuy-$VERSION.zip" )
notarize "$EXPORT_DIR/PopGuy-$VERSION.zip"
( cd "$EXPORT_DIR" \
  && xcrun stapler staple PopGuy.app \
  && ditto -c -k --keepParent PopGuy.app "PopGuy-$VERSION.zip" )
spctl -a -vv -t exec "$APP"

# --- 7. Build the notarized DMG (manual-download asset) --------------------
# A raw .zip breaks when users extract it with a third-party unarchiver (._* files pollute
# Sparkle.framework's seal → Gatekeeper malware warning). A DMG is drag-to-install: Finder
# copies the bundle verbatim, so the seal always survives. Built from the already-stapled app.
( cd "$EXPORT_DIR"
  rm -rf dmg-stage && mkdir dmg-stage
  cp -R PopGuy.app dmg-stage/
  ln -s /Applications dmg-stage/Applications
  hdiutil create -volname "PopGuy" -srcfolder dmg-stage -ov -format UDZO "PopGuy-$VERSION.dmg"
  # A DMG is a container, not an executable: --timestamp, no hardened runtime.
  codesign --force --timestamp --sign "Developer ID Application" "PopGuy-$VERSION.dmg"
  notarize "PopGuy-$VERSION.dmg"
  xcrun stapler staple "PopGuy-$VERSION.dmg"
  spctl -a -t open --context context:primary-signature -v "PopGuy-$VERSION.dmg"
  xcrun stapler validate "PopGuy-$VERSION.dmg" )

# --- 8. Done ---------------------------------------------------------------
echo
echo "Done. Notarized + stapled artifacts:"
echo "  zip : $EXPORT_DIR/PopGuy-$VERSION.zip"
echo "  dmg : $EXPORT_DIR/PopGuy-$VERSION.dmg"
echo
echo "Next: publish the GitHub Release (RELEASING.md §4):"
echo "  scripts/publish-release.sh $EXPORT_DIR/PopGuy-$VERSION.zip"
echo "Then regenerate + commit the appcast (RELEASING.md §5)."
