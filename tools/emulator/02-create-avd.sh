#!/bin/bash
# Create the eink7 AVD: 1264x1680 at 300 dpi (7" Boox Page class), 3 GB RAM, 16 GB data, hw keyboard.
set -euo pipefail
. "$(dirname "$0")/env.sh"

if avdmanager list avd -c | grep -qx "$AVD_NAME"; then
  echo "AVD $AVD_NAME exists; pass --force to recreate"
  [ "${1:-}" = "--force" ] || exit 0
fi
echo no | avdmanager create avd -n "$AVD_NAME" -k "$SYS_IMAGE" --force

cfg="$HOME/.android/avd/$AVD_NAME.avd/config.ini"
set_cfg() {
  if grep -q "^$1[ ]*=" "$cfg"; then
    sed -i '' "s|^$1[ ]*=.*|$1=$2|" "$cfg"
  else
    echo "$1=$2" >> "$cfg"
  fi
}
set_cfg hw.lcd.width 1264
set_cfg hw.lcd.height 1680
set_cfg hw.lcd.density 300
set_cfg hw.ramSize 3072
set_cfg disk.dataPartition.size 16G
set_cfg hw.keyboard yes
set_cfg hw.gpu.enabled yes
set_cfg hw.gpu.mode swiftshader_indirect
set_cfg showDeviceFrame no
grep -E '^(hw\.lcd|hw\.ramSize|disk\.data|hw\.keyboard|hw\.gpu|image\.sysdir)' "$cfg"
