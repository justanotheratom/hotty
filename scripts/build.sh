#!/bin/zsh
# Builds HoTTy.app into ./build and signs it.
# Signing with a stable identity keeps the Accessibility grant across rebuilds.
# Override with: SIGN_IDENTITY="Developer ID Application: ..." scripts/build.sh
# UNIVERSAL=1 builds for Apple silicon and Intel (used by scripts/release.sh).
# RELEASE=1 keeps the shipping identity (used by scripts/release.sh). Otherwise the build is
# "HoTTy Dev" (llc.fungee.hotty.dev): macOS ties privacy grants like Accessibility to the bundle
# id and signature, so a dev build sharing the release's id would keep invalidating its grant.
# The dev build also has its own settings.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${CONFIG:-release}
ARCH_FLAGS=()
[[ -n "${UNIVERSAL:-}" ]] && ARCH_FLAGS=(--arch arm64 --arch x86_64)
swift build -c "$CONFIG" "${ARCH_FLAGS[@]}"
BIN="$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path)/HoTty"

APP=build/HoTTy.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/HoTty"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -n "${RELEASE:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier llc.fungee.hotty" "$APP/Contents/Info.plist"
else
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier llc.fungee.hotty.dev" \
    -c "Set :CFBundleName HoTTy Dev" -c "Set :CFBundleDisplayName HoTTy Dev" "$APP/Contents/Info.plist"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Pick by SHA-1 (names can be ambiguous) and skip revoked certificates.
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/ && !/REVOKED/ {print $2; exit}')}
IDENTITY=${IDENTITY:--}
# Developer ID builds are notarized, and notarization requires a secure timestamp.
TIMESTAMP=()
[[ "$IDENTITY" != "-" ]] && security find-identity -v -p codesigning | grep "$IDENTITY" | grep -q "Developer ID" && TIMESTAMP=(--timestamp)
codesign --force --options runtime "${TIMESTAMP[@]}" --entitlements Resources/HoTty.entitlements --sign "$IDENTITY" "$APP"
echo "Built $APP (signed: $IDENTITY)"

if [[ "${1:-}" == "--run" ]]; then
  pkill -x HoTty 2>/dev/null || true
  open "$APP"
fi
