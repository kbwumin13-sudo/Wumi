#!/bin/zsh
# Package a Release app without changing the local app's signing identity.
# Usage: scripts/package-dmg.sh [path/to/Wumi.app] [output-directory]
set -euo pipefail
cd "${0:A:h}/.."

APP_PATH="${1:-build/Wumi.app}"
OUTPUT_DIR="${2:-build/releases}"
APP_PATH="${APP_PATH:A}"
OUTPUT_DIR="${OUTPUT_DIR:A}"
PLIST="$APP_PATH/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
ARCHS="$(lipo -archs "$APP_PATH/Contents/MacOS/DirDesk")"
case "$ARCHS" in
  arm64) ASSET_ARCH="arm64" ;;
  x86_64) ASSET_ARCH="x86_64" ;;
  "arm64 x86_64"|"x86_64 arm64") ASSET_ARCH="universal" ;;
  *) print -u2 "Unsupported app architectures: $ARCHS"; exit 1 ;;
esac

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wumi-dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
mkdir -p "$OUTPUT_DIR"
DMG="$OUTPUT_DIR/Wumi-$VERSION-$ASSET_ARCH.dmg"

ditto --norsrc --noextattr "$APP_PATH" "$STAGING_DIR/Wumi.app"
# The public build is ad-hoc signed; Developer ID notarization is not configured.
codesign --force --sign - --timestamp=none "$STAGING_DIR/Wumi.app"
codesign --verify --deep --strict "$STAGING_DIR/Wumi.app"
ln -s /Applications "$STAGING_DIR/Applications"
cat > "$STAGING_DIR/安装说明 - Install.txt" <<'EOF'
Wumi for macOS

1. 将 Wumi.app 拖到 Applications（应用程序）。
2. 推出此磁盘映像，从“应用程序”打开 Wumi。
3. 此版本使用 ad-hoc 签名，未经过 Apple 公证。如果 macOS 阻止首次打开，
   请确认文件来自官方 GitHub Release，再到“系统设置 > 隐私与安全性”点按“仍要打开”。

Drag Wumi.app to Applications, eject this disk image, then open Wumi from Applications.
This build is ad-hoc signed and is not notarized by Apple. If macOS blocks the first
launch, verify the download source and allow it in System Settings > Privacy & Security.

Downloads and source: https://github.com/kbwumin13-sudo/Wumi
Apple help: https://support.apple.com/102445
EOF

hdiutil create -volname "Wumi $VERSION" -srcfolder "$STAGING_DIR" \
  -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG"
hdiutil verify "$DMG"
(
  cd "$OUTPUT_DIR"
  shasum -a 256 "${DMG:t}" > "${DMG:t}.sha256"
)
print "Packaged $DMG"
