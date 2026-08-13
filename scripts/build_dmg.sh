#!/bin/zsh
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
rehash

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script must run on macOS 14+ with Xcode 15.3+." >&2
  exit 1
fi
if [[ "$(uname -m)" != "arm64" ]]; then
  echo "This script must run on Apple Silicon to build the arm64 package." >&2
  exit 1
fi
if [[ ! -x /usr/bin/swift || ! -x /usr/bin/hdiutil ]]; then
  echo "Install Xcode Command Line Tools first." >&2
  exit 1
fi

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="$PROJECT_ROOT/.build/release"
APP_NAME="One IMAGE Compare"
APP_PATH="$PROJECT_ROOT/dist/$APP_NAME.app"
DMG_PATH="$PROJECT_ROOT/dist/One-IMAGE-Compare-1.0.0-arm64.dmg"

cd "$PROJECT_ROOT"
/usr/bin/swift build -c release --arch arm64
BUILD_ROOT="$(/usr/bin/swift build -c release --arch arm64 --show-bin-path)"
[[ -x "$BUILD_ROOT/OneImageCompare" ]] || { echo "Missing release executable at $BUILD_ROOT" >&2; exit 1; }
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BUILD_ROOT/OneImageCompare" "$APP_PATH/Contents/MacOS/OneImageCompare"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"

/usr/bin/codesign --force --deep --sign - "$APP_PATH"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG_PATH"
/usr/bin/hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH"
/usr/bin/hdiutil verify "$DMG_PATH"
echo "$DMG_PATH"
