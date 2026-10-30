# eink7 emulator

Android 11 emulator shaped like a 7" 300 ppi e-reader (1264x1680, 300 dpi, 3 GB RAM,
16 GB data, hardware keyboard), with KOReader and this plugin, for testing MDict lookups.
Screenshots, logs and APKs go to `.devtools/emulator/` (gitignored: dictionary content
is copyrighted).

    tools/emulator/01-setup-sdk.sh              # cmdline-tools, platform-tools, emulator, API 30 arm64 image
    tools/emulator/02-create-avd.sh             # AVD "eink7" (--force to recreate)
    tools/emulator/start.sh                     # boot headless, wait for boot
    tools/emulator/03-install-koreader.sh upstream   # or: tategumi (same package; switching uninstalls the other)
    tools/emulator/04-push-plugin.sh            # stages mdict.koplugin + plugin-fixes/*.patch, pushes it (NO_FIXES=1: as committed)
    tools/emulator/05-push-dicts.sh             # .mdx/.mdd files listed in dicts.local (see dicts.local.example) -> /sdcard/koreader/data/dict
    tools/emulator/restart-koreader.sh TAG      # fresh logcat-TAG.txt, opens mdict-test.html
    python3 -I tools/emulator/lookup_timer.py run    # Search > Dictionary lookup, times the popup
    tools/emulator/shot.sh NAME                 # screenshot -> .devtools/emulator/NAME.png
    tools/emulator/sheet.sh OUT.png IN...       # contact sheet of popup screenshots
    tools/emulator/collect-logs.sh LOGCAT       # MDict/WebView lines + crash.log
    tools/emulator/stop.sh

`plugin-fixes/` (not tracked) can hold fixes tried on the emulator before they are in the
code, as patches against the repo; 04-push-plugin.sh applies them to the pushed copy.
Delete each one once the fix is committed, or the push will fail to apply it.

Gestures without a touchscreen: long-press `adb shell input swipe X Y X Y 1200`; select
several CJK characters with `input motionevent DOWN/MOVE/UP`; `adb shell input text` types
ASCII only, so Japanese words are looked up from mdict-test.html.
