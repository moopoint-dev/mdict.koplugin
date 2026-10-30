#!/bin/sh
# Builds mdict.koplugin/android/mdict-bridge.dex, the Java side of the WebView
# renderer, which the plugin loads at runtime (no custom APK needed).
#
#   ANDROID_JAR=/path/to/android.jar android/build.sh
#
# Needs a JDK (javac) and dx or d8 from the Android build tools.
set -e
here=$(cd "$(dirname "$0")" && pwd)
jar=${ANDROID_JAR:-$here/../.devtools/android-30.jar}
out=$here/../mdict.koplugin/android
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/classes" "$out"
javac -nowarn -Xlint:-options -source 8 -target 8 -encoding UTF-8 -bootclasspath "$jar" -classpath "$jar" \
    -d "$tmp/classes" $(find "$here/src" -name '*.java')
if command -v d8 >/dev/null 2>&1; then
    d8 --release --min-api 21 --lib "$jar" --output "$tmp" $(find "$tmp/classes" -name '*.class')
    mv "$tmp/classes.dex" "$out/mdict-bridge.dex"
else
    dx=$(command -v dx || command -v dalvik-exchange)
    "$dx" --dex --min-sdk-version=21 --output="$out/mdict-bridge.dex" "$tmp/classes"
fi
# release.sh checks the dex against this (file times do not survive git checkouts)
. "$here/source-hash.sh"
source_hash "$here/.." > "$here/dex-source.sha256"
ls -l "$out/mdict-bridge.dex"
