#!/usr/bin/env bash
#
# sign-and-share.sh — Produce a PopGuy .app signed with the local self-signed
# certificate and zipped for sharing to another Mac, WITHOUT Apple Developer
# enrollment / notarization.
#
# This is the DEV / personal-test distribution path. For the official
# Developer ID + notarized + Sparkle release path, see docs/RELEASING.md.
# Full explanation: docs/DEV_DISTRIBUTION.md
#
# Usage:
#   scripts/sign-and-share.sh                  # archive from source, then sign + zip
#   scripts/sign-and-share.sh /path/PopGuy.app # sign + zip an already-exported .app
#
# Override the signing identity:
#   POPGUY_SIGN_IDENTITY="My Cert" scripts/sign-and-share.sh
#
# Output: dist/PopGuy-<version>-<build>.zip
#
set -euo pipefail

SCHEME="PopGuy"
IDENTITY="${POPGUY_SIGN_IDENTITY:-PopGuy Self Sign}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$REPO_ROOT/dist"
ARCHIVE="$DIST/PopGuy.xcarchive"

cd "$REPO_ROOT"
mkdir -p "$DIST"

# --- 1. Verify the signing identity exists --------------------------------
# A self-signed cert shows as CSSMERR_TP_NOT_TRUSTED here; that is fine for
# codesign (it only needs the cert + private key, not a trusted chain).
if ! security find-identity -p codesigning | grep -q "$IDENTITY"; then
  echo "error: code-signing identity \"$IDENTITY\" not found in keychain." >&2
  echo "       Create it once in Keychain Access -> Certificate Assistant ->" >&2
  echo "       Create a Certificate (Identity: Self Signed Root, Type: Code Signing)." >&2
  exit 1
fi

# --- 2. Obtain the .app ---------------------------------------------------
APP="${1:-}"
if [[ -n "$APP" ]]; then
  echo "==> Using existing app: $APP"
  [[ -d "$APP" ]] || { echo "error: $APP not found" >&2; exit 1; }
else
  echo "==> Archiving $SCHEME (Release, unsigned, DEV_MOCK_PRO)..."
  # CODE_SIGNING_ALLOWED=NO: archive without Apple signing so this never
  # depends on the Apple Development cert / personal-team provisioning
  # (which expires after ~7 days). We apply our own signature in step 3.
  #
  # SWIFT_ACTIVE_COMPILATION_CONDITIONS += DEV_MOCK_PRO: compiles in the mock
  # license validator so testers unlock Pro with any key. This flag is set ONLY
  # here — never in the project — so official Release builds stay license-gated.
  rm -rf "$ARCHIVE"
  xcodebuild -scheme "$SCHEME" -configuration Release \
    -archivePath "$ARCHIVE" \
    CODE_SIGNING_ALLOWED=NO \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) DEV_MOCK_PRO' \
    archive >/dev/null
  APP="$DIST/PopGuy.app"
  rm -rf "$APP"
  cp -R "$ARCHIVE/Products/Applications/PopGuy.app" "$APP"
  echo "==> Extracted app to $APP"
fi

# --- 3. Re-sign with the self-signed identity -----------------------------
# --options runtime keeps Hardened Runtime on. --timestamp=none skips the
# Apple secure-timestamp server (which a self-signed cert cannot use).
#
# Nested code (Sparkle.framework and its XPC services / helper tools) MUST be
# signed inside-out, deepest first, BEFORE the outer app. Under Hardened
# Runtime, library validation requires every embedded Mach-O to carry our
# identity; an unsigned/ad-hoc nested framework makes the app fail to launch
# on another Mac with no UI shown.
# A self-signed cert has no Team ID, so under Hardened Runtime library
# validation refuses to load the embedded Sparkle.framework ("different Team
# IDs") and the app aborts on launch. The dev-only entitlements file disables
# library validation for this self-signed path; the official Developer ID build
# keeps it on (real shared Team ID) and never uses this file.
ENTITLEMENTS="$REPO_ROOT/scripts/dev-entitlements.plist"
echo "==> Signing with \"$IDENTITY\"..."
sign() { codesign --force --options runtime --timestamp=none --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$@"; }

FRAMEWORKS_DIR="$APP/Contents/Frameworks"
if [[ -d "$FRAMEWORKS_DIR" ]]; then
  # 3a. Helpers/services nested inside frameworks (e.g. Sparkle's Installer.xpc,
  #     Downloader.xpc, Autoupdate, Updater.app) — sign these first.
  while IFS= read -r -d '' nested; do
    echo "    signing nested: ${nested#$APP/}"
    sign "$nested"
  done < <(find "$FRAMEWORKS_DIR" \
    \( -name '*.xpc' -o -name '*.app' -o -name 'Autoupdate' \) -print0 2>/dev/null)

  # 3b. The frameworks themselves.
  while IFS= read -r -d '' fw; do
    echo "    signing framework: ${fw#$APP/}"
    sign "$fw"
  done < <(find "$FRAMEWORKS_DIR" -name '*.framework' -print0 2>/dev/null)
fi

# 3c. Finally the outer app bundle.
sign "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# --- 4. Zip (preserving the bundle) ---------------------------------------
VERSION="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo unknown)"
BUILD="$(defaults read "$APP/Contents/Info.plist" CFBundleVersion 2>/dev/null || echo 0)"
ZIP="$DIST/PopGuy-${VERSION}-${BUILD}.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "Done."
echo "  Signed app: $APP"
echo "  Share this: $ZIP"
echo
echo "On the receiving Mac, after unzipping:"
echo "  xattr -dr com.apple.quarantine /path/to/PopGuy.app"
echo "  open /path/to/PopGuy.app"
echo "Then grant Accessibility: System Settings -> Privacy & Security -> Accessibility."
