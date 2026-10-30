#!/bin/bash
# Push mdict.koplugin to the emulator (replacing the previous copy).
# Patches in tools/emulator/plugin-fixes/*.patch are applied to a staged copy first
# (the repo is never modified); set NO_FIXES=1 to push the plugin as committed.
set -euo pipefail
. "$(dirname "$0")/env.sh"

[ -f "$PLUGIN_DIR/android/mdict-bridge.dex" ] || { echo "missing $PLUGIN_DIR/android/mdict-bridge.dex"; exit 1; }
stage="$OUT_DIR/staging/push"
rm -rf "$stage"
mkdir -p "$stage"
cp -R "$PLUGIN_DIR" "$stage/"
if [ -z "${NO_FIXES:-}" ]; then
  for p in "$REPO_DIR"/tools/emulator/plugin-fixes/*.patch; do
    [ -f "$p" ] || continue
    echo "applying $(basename "$p")"
    patch -s -p1 -d "$stage" < "$p"
  done
fi
adb shell rm -rf "$KO_ROOT/plugins/mdict.koplugin"
adb push "$stage/mdict.koplugin" "$KO_ROOT/plugins/mdict.koplugin" | tail -1
adb shell ls -l "$KO_ROOT/plugins/mdict.koplugin/android"
