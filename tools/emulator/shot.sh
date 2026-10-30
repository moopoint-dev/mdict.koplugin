#!/bin/bash
# Save a screenshot to .devtools/emulator/<name>.png and print its path.
. "$(dirname "$0")/env.sh"
name="${1:-shot-$(date +%H%M%S)}"
adb exec-out screencap -p > "$OUT_DIR/$name.png"
echo "$OUT_DIR/$name.png"
