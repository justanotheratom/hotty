#!/bin/zsh
# Builds HoTty.app into ./build and signs it.
# Signing with a stable identity keeps the Accessibility grant across rebuilds.
# Override with: SIGN_IDENTITY="Developer ID Application: ..." scripts/build.sh
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${CONFIG:-release}
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/HoTty"

APP=build/HoTty.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/HoTty"
cp Resources/Info.plist "$APP/Contents/Info.plist"

IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}
IDENTITY=${IDENTITY:--}
codesign --force --options runtime --entitlements Resources/HoTty.entitlements --sign "$IDENTITY" "$APP"
echo "Built $APP (signed: $IDENTITY)"

if [[ "${1:-}" == "--run" ]]; then
  pkill -x HoTty 2>/dev/null || true
  open "$APP"
fi
