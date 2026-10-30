#!/bin/bash
# Boot eink7 headless and wait until Android has finished booting.
# Usage: start.sh [extra emulator args...]   (e.g. -gpu host)
set -euo pipefail
. "$(dirname "$0")/env.sh"

if adb devices | grep -q '^emulator-'; then
  echo "An emulator is already running"; adb devices; exit 0
fi
nohup emulator -avd "$AVD_NAME" -no-window -no-audio -no-boot-anim -no-snapshot-save \
  -gpu swiftshader_indirect "$@" > "$OUT_DIR/emulator.log" 2>&1 &
echo "emulator pid $!"
adb wait-for-device
until [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do sleep 2; done
adb shell settings put global window_animation_scale 0
adb shell settings put global transition_animation_scale 0
adb shell settings put global animator_duration_scale 0
adb shell wm size
adb shell wm density
echo "booted"
