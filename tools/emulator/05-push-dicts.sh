#!/bin/bash
# Push the test dictionaries to data/dict. Files already on the device
# with the same size are skipped.
# The files are the arguments, else the lines of tools/emulator/dicts.local (one path per
# line, # comments, ~ for $HOME; untracked, see dicts.local.example).
set -euo pipefail
. "$(dirname "$0")/env.sh"

DICT_DIR="$KO_ROOT/data/dict"
LIST="$(dirname "$0")/dicts.local"
FILES=()
if [ $# -gt 0 ]; then
  FILES=("$@")
elif [ -f "$LIST" ]; then
  while read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in '~'|'~/'*) line="$HOME${line#"~"}" ;; esac
    FILES+=("$line")
  done < "$LIST"
fi
if [ ${#FILES[@]} -eq 0 ]; then
  echo "List the .mdx/.mdd files to push in tools/emulator/dicts.local (one per line), or pass them as arguments." >&2
  exit 1
fi

adb shell mkdir -p "$DICT_DIR"
for f in "${FILES[@]}"; do
  name=$(basename "$f")
  local_size=$(stat -f %z "$f")
  remote_size=$(adb shell "stat -c %s '$DICT_DIR/$name' 2>/dev/null" | tr -d '\r' || true)
  if [ "$local_size" = "$remote_size" ]; then
    echo "same size, skipped: $name"
  else
    adb push "$f" "$DICT_DIR/$name" | tail -1
  fi
done
adb shell ls -l "$DICT_DIR"
