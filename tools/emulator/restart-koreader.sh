#!/bin/bash
# Restart KOReader with a fresh logcat capture in .devtools/emulator/logcat-<tag>.txt
# and open a document (default: the MDict test page, pushed if missing).
# Usage: restart-koreader.sh [tag] [document path on device | -]   ("-" opens nothing)
set -euo pipefail
. "$(dirname "$0")/env.sh"

tag="${1:-$(date +%H%M%S)}"
doc="${2:-$KO_ROOT/mdict-test.html}"
adb shell am force-stop "$KO_PKG"
pkill -f "adb logcat -v time" 2>/dev/null || true
adb logcat -c
nohup adb logcat -v time > "$OUT_DIR/logcat-$tag.txt" 2>&1 &
if [ "$doc" = "-" ]; then
  adb shell monkey -p "$KO_PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
else
  if [ "$doc" = "$KO_ROOT/mdict-test.html" ]; then
    adb push "$(dirname "$0")/mdict-test.html" "$doc" >/dev/null
  fi
  adb shell am start -a android.intent.action.VIEW -d "file://$doc" -t text/html \
    -n "$KO_PKG/.MainActivity" >/dev/null
fi
echo "$OUT_DIR/logcat-$tag.txt"
