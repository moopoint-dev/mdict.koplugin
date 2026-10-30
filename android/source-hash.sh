# Sourced by build.sh and tools/release.sh. source_hash <repo root>: SHA-256 of the
# Java sources the dex is built from.
source_hash() {
    (cd "$1" && find android/src -name '*.java' | LC_ALL=C sort | xargs cat) |
        if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | cut -d' ' -f1
}
