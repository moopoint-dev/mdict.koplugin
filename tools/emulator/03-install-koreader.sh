#!/bin/bash
# Download and install a KOReader arm64 APK, launch it once and grant all-files access.
# Usage: 03-install-koreader.sh [upstream|tategumi]   (default upstream)
# Both builds use package org.koreader.launcher with different signatures, so switching
# uninstalls the other one first (/sdcard/koreader is kept).
set -euo pipefail
. "$(dirname "$0")/env.sh"

flavor="${1:-upstream}"
case "$flavor" in
  upstream) repo=koreader/koreader ;;
  tategumi) repo=m-tky/koreader-tategumi ;;
  *) echo "unknown flavor $flavor"; exit 1 ;;
esac

apk_dir="$OUT_DIR/apk/$flavor"
mkdir -p "$apk_dir"
url=$(curl -sS "https://api.github.com/repos/$repo/releases/latest" | python3 -I -c '
import json, re, sys
r = json.load(sys.stdin)
for a in r["assets"]:
    if re.fullmatch(r"koreader-android-arm64-v[0-9.]+\.apk", a["name"]):
        print(a["browser_download_url"])
        break')
apk="$apk_dir/$(basename "$url")"
[ -f "$apk" ] || curl -sS -fL -o "$apk" "$url"
echo "APK: $apk"

installed=$(adb shell dumpsys package "$KO_PKG" | grep -m1 versionName | tr -d ' \r' || true)
want=$(basename "$apk" .apk | sed 's/.*-arm64-//')
if [ "$installed" != "versionName=$want" ]; then
  adb install -r "$apk" || { adb uninstall "$KO_PKG"; adb install "$apk"; }
fi
adb shell dumpsys package "$KO_PKG" | grep -m1 versionName

uid=$(adb shell dumpsys package "$KO_PKG" | grep -m1 -o 'userId=[0-9]*' | cut -d= -f2)
adb shell appops set --uid "$uid" MANAGE_EXTERNAL_STORAGE allow
adb shell pm grant "$KO_PKG" android.permission.READ_EXTERNAL_STORAGE 2>/dev/null || true
adb shell pm grant "$KO_PKG" android.permission.WRITE_EXTERNAL_STORAGE 2>/dev/null || true

# First launch creates /sdcard/koreader
adb shell monkey -p "$KO_PKG" -c android.intent.category.LAUNCHER 1 >/dev/null
for _ in $(seq 1 60); do
  adb shell "[ -d $KO_ROOT ]" && break
  sleep 1
done
adb shell ls "$KO_ROOT"
