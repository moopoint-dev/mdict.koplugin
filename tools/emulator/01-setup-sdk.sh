#!/bin/bash
# Install Android cmdline-tools (if missing) plus platform-tools, emulator and the API 30 arm64 image.
set -euo pipefail
. "$(dirname "$0")/env.sh"

df -g "$HOME" | awk 'NR==2 { if ($4 < 30) { print "Less than 30 GB free (" $4 " GB)"; exit 1 } }'

if [ ! -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ]; then
  tmp=$(mktemp -d)
  curl -sS -o "$tmp/repo.xml" https://dl.google.com/android/repository/repository2-3.xml
  zip=$(grep -o 'commandlinetools-mac-[0-9]*_latest.zip' "$tmp/repo.xml" | sort -t- -k3 -n | tail -1)
  sha=$(grep -B1 "<url>$zip</url>" "$tmp/repo.xml" | grep -o '[0-9a-f]\{40\}')
  curl -sS -fL -o "$tmp/clt.zip" "https://dl.google.com/android/repository/$zip"
  echo "$sha  $tmp/clt.zip" | shasum -a 1 -c -
  unzip -q "$tmp/clt.zip" -d "$tmp/x"
  mkdir -p "$ANDROID_HOME/cmdline-tools"
  mv "$tmp/x/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest"
  rm -rf "$tmp"
fi

yes | sdkmanager --sdk_root="$ANDROID_HOME" --licenses >/dev/null 2>&1 || true
sdkmanager --sdk_root="$ANDROID_HOME" "platform-tools" "emulator" "$SYS_IMAGE"
sdkmanager --sdk_root="$ANDROID_HOME" --list_installed | grep -E 'emulator|platform-tools|system-images'
