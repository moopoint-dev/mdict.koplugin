#!/bin/sh
# Packs the plugin for installation: dist/mdict.koplugin-<version>.zip, which
# unzips to mdict.koplugin/ (copy it into koreader/plugins/).
#
#   tools/release.sh [version]
#
# The version comes from mdict.koplugin/_meta.lua, the only place it is set: the
# plugin's updater compares it with the latest GitHub release, whose tag must be
# v<version>. A given version must match _meta.lua, and so must a tag on HEAD.
# Builds of other commits are named <version>-<git describe>.
set -eu
cd "$(dirname "$0")/.."

meta_version=$(sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' mdict.koplugin/_meta.lua)
[ -n "$meta_version" ] || { echo "no version in mdict.koplugin/_meta.lua" >&2; exit 1; }
tag=$(git describe --tags --exact-match HEAD 2>/dev/null || true)
if [ -n "$tag" ] && [ "$tag" != "v$meta_version" ]; then
    echo "HEAD is tagged $tag but _meta.lua says $meta_version" >&2
    exit 1
fi
if [ $# -gt 0 ]; then
    version=$1
    if [ "$version" != "$meta_version" ]; then
        echo "version $version differs from _meta.lua ($meta_version): change it there first" >&2
        exit 1
    fi
elif [ "$tag" = "v$meta_version" ] && git diff --quiet HEAD -- mdict.koplugin; then
    version=$meta_version
else
    version="$meta_version-$(git describe --always --dirty --exclude "*" 2>/dev/null || date +%Y.%m.%d)"
fi

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
