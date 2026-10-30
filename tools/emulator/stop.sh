#!/bin/bash
# Shut the running emulator down cleanly.
. "$(dirname "$0")/env.sh"
adb emu kill 2>/dev/null || true
for _ in $(seq 1 30); do
  adb devices | grep -q '^emulator-' || { echo "stopped"; exit 0; }
  sleep 1
done
pkill -f "qemu-system.*-avd $AVD_NAME" && echo "killed"
