#!/usr/bin/env python3 -I
"""Time a dictionary lookup in KOReader on the eink7 emulator (1264x1680).

Opens Search > Dictionary lookup from the reader (no popup or menu open), types an
ASCII word, taps "Search dictionary" and polls raw screencaps until the popup's close
button appears and the frame stops changing. Prints both times, in seconds from the tap.

Usage: lookup_timer.py WORD [--shot out.png] [--settle 0.8] [--timeout 30]
"""
import argparse
import hashlib
import os
import subprocess
import time

# as in env.sh: keeps adb on the emulator when a real device is plugged in too
os.environ.setdefault("ANDROID_SERIAL", "emulator-5554")


def adb(*args):
    return subprocess.run(["adb", *args], capture_output=True, check=True).stdout


def tap(x, y):
    adb("shell", "input", "tap", str(x), str(y))


def frame():
    raw = adb("exec-out", "screencap")
    w = int.from_bytes(raw[0:4], "little")
    h = int.from_bytes(raw[4:8], "little")
    return w, h, len(raw) - w * h * 4, raw


def dark_pixels(fr, x0, y0, x1, y1):
    w, _, hdr, raw = fr
    n = 0
    for y in range(y0, y1):
        row = hdr + (y * w) * 4
        for x in range(x0, x1):
            p = row + x * 4
            if raw[p] + raw[p + 1] + raw[p + 2] < 200:
                n += 1
    return n


# close "X" of a centred dictionary popup on this screen size
CLOSE_BOX = (1104, 302, 1146, 344)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("word")
    ap.add_argument("--shot")
    ap.add_argument("--settle", type=float, default=0.8)
    ap.add_argument("--timeout", type=float, default=30)
    a = ap.parse_args()

    tap(630, 60)        # top menu
    time.sleep(1.2)
    tap(708, 57)        # search tab
    time.sleep(1.0)
    tap(270, 273)       # Dictionary lookup
    time.sleep(1.2)
    adb("shell", "input", "text", a.word)
    time.sleep(0.3)
    t0 = time.time()
    tap(880, 962)       # Search dictionary

    t_popup = None
    last_hash, last_change = None, time.time()
    while time.time() - t0 < a.timeout:
        fr = frame()
        now = time.time()
        h = hashlib.md5(fr[3]).digest()
        if h != last_hash:
            last_hash, last_change = h, now
        if t_popup is None and dark_pixels(fr, *CLOSE_BOX) > 40:
            t_popup = now - t0
        if t_popup is not None and now - last_change >= a.settle:
            break
    settled = last_change - t0
    print(f"{a.word}: popup {t_popup if t_popup is None else round(t_popup, 2)} s, "
          f"settled {settled:.2f} s (screencap granularity ~0.1-0.3 s)")
    if a.shot:
        with open(a.shot, "wb") as f:
            f.write(adb("exec-out", "screencap", "-p"))


if __name__ == "__main__":
    main()
