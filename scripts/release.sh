#!/bin/zsh
# Builds a release of HoTTy that anyone can install with Homebrew:
#   1. sets the version, builds for Apple silicon and Intel, signs with Developer ID
#   2. sends it to Apple for notarization and staples the ticket
#   3. zips it into dist/ and writes the Homebrew cask with the new version and checksum
#   4. (with --publish) uploads the zip to GitHub Releases and pushes the cask to the tap
#
# Usage: scripts/release.sh 0.2.0 [--publish] [--no-notarize]
#   --publish      upload the release and update the tap; without it nothing leaves this Mac
#   --no-notarize  test run: skip Apple's check and sign with a development certificate.
#                  The result only opens on Macs that already trust your certificate.
#
# Normally run by .github/workflows/release.yml when a v* tag is pushed. To run it locally
# (see README, "Releasing"):
#   - a "Developer ID Application" certificate in the keychain
#   - xcrun notarytool store-credentials hotty-notary --apple-id <email> --team-id 58MYNHGN72
#   - gh auth login, with write access to $RELEASE_REPO and $TAP_REPO
# In CI, notarization uses an App Store Connect API key instead (NOTARY_KEY_PATH,
# NOTARY_KEY_ID, NOTARY_ISSUER), BUILD_NUMBER sets CFBundleVersion, and the tap is pushed with
# the deploy key at TAP_SSH_KEY.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:-}
shift || true
PUBLISH=0 NOTARIZE=1
for arg in "$@"; do
  case $arg in
    --publish) PUBLISH=1 ;;
    --no-notarize) NOTARIZE=0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done
if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  echo "Usage: scripts/release.sh <version like 0.2.0> [--publish] [--no-notarize]" >&2
  exit 2
fi
if (( PUBLISH && !NOTARIZE )); then
  echo "Refusing to publish a build that Apple hasn't notarized: macOS would block it for everyone." >&2
  exit 2
fi

TAP_REPO=${TAP_REPO:-justanotheratom/homebrew-tap}
RELEASE_REPO=${RELEASE_REPO:-justanotheratom/hotty}
NOTARY_PROFILE=${NOTARY_PROFILE:-hotty-notary}
TAG="v$VERSION"
DIST=dist
ZIP="$DIST/HoTTy-$VERSION.zip"
CASK="packaging/homebrew/hotty.rb"
URL="https://github.com/$RELEASE_REPO/releases/download/$TAG/HoTTy-$VERSION.zip"

step() { print -P "\n%F{blue}==>%f %B$1%b" }

step "Version $VERSION"
PLIST=Resources/Info.plist
BUILD=${BUILD_NUMBER:-$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST") + 1 ))}
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$PLIST"
sed -i '' -E "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $VERSION;/; s/CURRENT_PROJECT_VERSION = [^;]+;/CURRENT_PROJECT_VERSION = $BUILD;/" \
  HoTty.xcodeproj/project.pbxproj
echo "HoTTy $VERSION (build $BUILD)"

step "Signing identity"
pick() { security find-identity -v -p codesigning | awk -v k="$1" '$0 ~ k && !/REVOKED/ {print $2; exit}' }
IDENTITY=$(pick "Developer ID Application")
if [[ -z "$IDENTITY" ]]; then
  if (( NOTARIZE )); then
    echo "No \"Developer ID Application\" certificate found. Create one in Xcode › Settings › Accounts ›" >&2
    echo "Manage Certificates › + › Developer ID Application, or test with --no-notarize." >&2
    exit 1
  fi
  IDENTITY=$(pick "Apple Development")
  echo "Test build: signing with a development certificate."
fi
security find-identity -v -p codesigning | grep "$IDENTITY" | sed 's/^ *[0-9]*) //'

step "Build (Apple silicon + Intel)"
RELEASE=1 UNIVERSAL=1 SIGN_IDENTITY="$IDENTITY" ./scripts/build.sh
APP=build/HoTTy.app
codesign --verify --deep --strict "$APP"
echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/HoTty")"

mkdir -p "$DIST"
rm -f "$ZIP"
if (( NOTARIZE )); then
  step "Notarize (Apple checks the app; usually a few minutes)"
  ditto -c -k --keepParent "$APP" "$DIST/notarize.zip"
  if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
    NOTARY_AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
  else
    NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
  fi
  xcrun notarytool submit "$DIST/notarize.zip" "${NOTARY_AUTH[@]}" --wait
  rm "$DIST/notarize.zip"
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
fi

step "Package"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
echo "$ZIP  $(du -h "$ZIP" | cut -f1)  sha256 $SHA"

sed -e "/^# /d" -e "s|@VERSION@|$VERSION|" -e "s|@SHA256@|$SHA|" -e "s|@RELEASE_REPO@|$RELEASE_REPO|" \
  packaging/homebrew/hotty.rb.in > "$CASK"
echo "Wrote $CASK"

if (( ! PUBLISH )); then
  step "Done. Nothing was uploaded."
  echo "To publish: scripts/release.sh $VERSION --publish"
  exit 0
fi

step "Publish $TAG to $RELEASE_REPO"
gh release create "$TAG" "$ZIP" --repo "$RELEASE_REPO" --title "HoTTy $VERSION" \
  --notes "Install or update with: brew install ${TAP_REPO%%/*}/tap/hotty"
curl -fsIL "$URL" >/dev/null && echo "Download is live: $URL"

step "Update the tap ($TAP_REPO)"
TAP_DIR=$(mktemp -d)
if [[ -n "${TAP_SSH_KEY:-}" ]]; then
  export GIT_SSH_COMMAND="ssh -i $TAP_SSH_KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
  git clone --quiet "git@github.com:$TAP_REPO.git" "$TAP_DIR"
else
  gh repo clone "$TAP_REPO" "$TAP_DIR" -- --quiet
fi
mkdir -p "$TAP_DIR/Casks"
cp "$CASK" "$TAP_DIR/Casks/hotty.rb"
git -C "$TAP_DIR" add Casks/hotty.rb
if git -C "$TAP_DIR" diff --cached --quiet; then
  echo "Cask unchanged"
else
  git -C "$TAP_DIR" commit --quiet -m "hotty $VERSION"
  git -C "$TAP_DIR" push --quiet
fi
rm -rf "$TAP_DIR"

step "Released HoTTy $VERSION"
echo "Users install it with:  brew install ${TAP_REPO%%/*}/tap/hotty"
echo "and update with:        brew upgrade hotty"
