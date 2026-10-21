#!/bin/zsh
# Renders DirDesk windows offscreen from a hidden copy with its own bundle ID, settings and Application Support,
# so the DirDesk in use is not disturbed. Usage: scripts/review/harness.sh <action> [folder] [extra args…]
# Actions are listed in docs/构建与运行.md （离屏截图）. PNGs land in $H/out.
root=${0:A:h:h:h}
H=${DIRDESK_HARNESS_DIR:-/tmp/dirdesk-harness}
mkdir -p $H
if [[ ! -d $H/DirDeskMenuHarness.app || $root/build/Wumi.app/Contents/MacOS/DirDesk -nt $H/DirDeskMenuHarness.app/Contents/MacOS/DirDesk ]]; then
  rm -rf $H/DirDeskMenuHarness.app && cp -R $root/build/Wumi.app $H/DirDeskMenuHarness.app
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.kbwumin13.dirdesk.menuharness" -c "Set :CFBundleName DirDeskMenuHarness" $H/DirDeskMenuHarness.app/Contents/Info.plist
  codesign --force --sign - $H/DirDeskMenuHarness.app >/dev/null 2>&1
fi
pkill -f "DirDeskMenuHarness.app/Contents/MacOS"; sleep 0.5
rm -rf $H/out && mkdir -p $H/out
args=(-DirDeskSnapshotDir $H/out -DirDeskSnapshotHidden YES -DirDeskApplicationSupport $H/support -DirDeskSnapshotAction "$1")
[[ -n "$2" ]] && args+=(-DirDeskSnapshotFolder "$2")
open -g -j -n --env HOME=$H/home -a $H/DirDeskMenuHarness.app --args $args "${@:3}"
marker=done.txt; [[ "$1" == selfTest ]] && marker=selftest-done
for i in {1..120}; do [[ -f $H/out/$marker ]] && break; sleep 0.5; done
sleep 0.3
pkill -f "DirDeskMenuHarness.app/Contents/MacOS"
ls $H/out
