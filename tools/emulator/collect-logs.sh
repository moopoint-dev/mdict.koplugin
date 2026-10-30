#!/bin/bash
# Show MDict-related lines from a logcat capture and pull KOReader's crash.log.
# Usage: collect-logs.sh <logcat file>
. "$(dirname "$0")/env.sh"
log="${1:?logcat file}"
grep -a -E 'MDict|mdict|chromium|WebView|cr_|AndroidRuntime|FATAL|lua.*error' "$log" | grep -v -E 'BufferQueue|EGL_emulation' | tail -200
adb pull "$KO_ROOT/crash.log" "$OUT_DIR/crash.log" >/dev/null 2>&1 && echo "crash.log -> $OUT_DIR/crash.log"
