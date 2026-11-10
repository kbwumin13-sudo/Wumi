#!/bin/zsh
# Builds Wumi.app into build/ (the executable remains DirDesk).
# Usage: scripts/build-app.sh [debug|release] (default: release)
#   SIGN_IDENTITY env selects a signing identity; default "DirDesk Local Signing" when present, else ad-hoc.
set -euo pipefail
cd "${0:A:h}/.."

CONFIG="${1:-release}"
VERSION="${DIRDESK_VERSION:-1.2.7}"
BUILD_NUMBER="${DIRDESK_BUILD:-$(date +%Y%m%d%H%M)}"

swift build -c "$CONFIG" --product DirDesk
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
swift build --package-path Vendor/Miji -c "$CONFIG" --product miji-extract
MIJI_BIN_DIR="$(swift build --package-path Vendor/Miji -c "$CONFIG" --show-bin-path)"

APP="${DIRDESK_APP_PATH:-build/Wumi.app}"
[[ "$APP" == *.app && "$APP" != ".app" && "$APP" != "/.app" ]] || { print -u2 "DIRDESK_APP_PATH must name an .app bundle"; exit 1; }
mkdir -p build
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers" "$APP/Contents/Resources/Licenses"
cp "$BIN_DIR/DirDesk" "$APP/Contents/MacOS/DirDesk"
cp "$MIJI_BIN_DIR/miji-extract" "$APP/Contents/Helpers/miji-extract"
cp Vendor/Miji/LICENSE "$APP/Contents/Resources/Licenses/Miji-MIT.txt"
cp Vendor/Miji/Vendor/OilFind/LICENSE "$APP/Contents/Resources/Licenses/OilFind-MIT.txt"
cp Vendor/Miji/UPSTREAM.md "$APP/Contents/Resources/Licenses/Miji-UPSTREAM.md"
cp Vendor/Miji/Vendor/OilFind/UPSTREAM.md "$APP/Contents/Resources/Licenses/OilFind-UPSTREAM.md"
# SwiftPM records the deployment target as the SDK version (sdk 15.0), which makes macOS 26 and later draw every
# window in the older control style. Record the SDK the app was really built with, like an Xcode build does.
SDK_VERSION="$(xcrun --show-sdk-version)"
vtool -set-build-version macos 15.0 "$SDK_VERSION" -replace -output "$APP/Contents/MacOS/DirDesk" "$APP/Contents/MacOS/DirDesk" 2>/dev/null
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
for bundle in "$BIN_DIR"/*.bundle(N); do
  # Test fixtures are development data, not application resources.
  [[ "${bundle:t}" == *_DirDeskCoreTests.bundle ]] && continue
  cp -R "$bundle" "$APP/Contents/Resources/"
done

if [[ ! -f build/AppIcon.icns || scripts/make_icon.swift -nt build/AppIcon.icns ]]; then
  ICON_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wumi-icon.XXXXXX")"
  trap 'rm -rf "$ICON_TEMP_DIR"' EXIT
  swift scripts/make_icon.swift "$ICON_TEMP_DIR/AppIcon.iconset" >/dev/null
  iconutil -c icns "$ICON_TEMP_DIR/AppIcon.iconset" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Prefer the local identity from scripts/make-signing-cert.sh: its designated requirement stays the same across builds,
# so privacy grants persist. Fall back to ad-hoc signing when it is absent.
if [[ -z "${SIGN_IDENTITY:-}" ]] && security find-identity -p codesigning 2>/dev/null | grep -qF '"DirDesk Local Signing"'; then
  SIGN_IDENTITY="DirDesk Local Signing"
fi
codesign --force --sign "${SIGN_IDENTITY:--}" --timestamp=none "$APP/Contents/Helpers/miji-extract"
codesign --force --sign "${SIGN_IDENTITY:--}" --timestamp=none "$APP"
echo "built $APP ($CONFIG, $VERSION/$BUILD_NUMBER, signed: ${SIGN_IDENTITY:-ad-hoc})"
