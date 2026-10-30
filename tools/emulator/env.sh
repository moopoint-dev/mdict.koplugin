# Shared settings for the eink7 emulator scripts. Source this file.
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
if [ -z "${JAVA_HOME:-}" ] && [ -d "/Applications/Android Studio.app/Contents/jbr/Contents/Home" ]; then
  export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
fi
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"
# Keeps adb on the emulator when a real device is plugged in too.
export ANDROID_SERIAL="${ANDROID_SERIAL:-emulator-5554}"

AVD_NAME="${AVD_NAME:-eink7}"
SYS_IMAGE="system-images;android-30;google_apis;arm64-v8a"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
OUT_DIR="$REPO_DIR/.devtools/emulator"
PLUGIN_DIR="$REPO_DIR/mdict.koplugin"
KO_PKG="${KO_PKG:-org.koreader.launcher}"
KO_ROOT="/sdcard/koreader"
mkdir -p "$OUT_DIR"
