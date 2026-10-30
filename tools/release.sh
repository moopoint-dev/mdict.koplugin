#!/bin/sh
# Packs the plugin for installation: dist/mdict.koplugin-<version>.zip, which
# unzips to mdict.koplugin/ (copy it into koreader/plugins/).
#
#   tools/release.sh [version]     (default: git describe, else the date)
set -eu
cd "$(dirname "$0")/.."
version=${1:-$(git describe --tags --always --dirty 2>/dev/null || date +%Y.%m.%d)}

dex=mdict.koplugin/android/mdict-bridge.dex
[ -f "$dex" ] || { echo "missing $dex: run android/build.sh" >&2; exit 1; }
. android/source-hash.sh
if [ "$(source_hash .)" != "$(cat android/dex-source.sha256 2>/dev/null)" ]; then
    echo "the Java sources changed since $dex was built: run android/build.sh first" >&2
    exit 1
fi

mkdir -p dist
out="dist/mdict.koplugin-$version.zip"
rm -f "$out"
zip -qr -X "$out" mdict.koplugin -x '*/.*' -x '*.orig'
echo "$out"
