#!/usr/bin/env python3
"""Reference implementation of the kosort-1 key order, for dictionary exporters.

An exporter that writes MDX keys in this order (and adds the header attribute
KOReaderKeyOrder="kosort-1") lets the KOReader MDict plugin search the file
without building its own index:

    from kosort import normalize
    items.sort(key=lambda kv: normalize(kv[0]).encode("utf-8"))

The tables come from kosort1_tables.json (pinned Unicode version), not from
the running Python's unicodedata, so results do not drift between Python
releases. Check an exporter against the shared vectors with:

    python3 tools/kosort.py --check spec/data/kosort-1.tsv
"""
import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(_HERE, "kosort1_tables.json")) as _f:
    _T = json.load(_f)

SPEC = _T["spec"]
UNICODE_VERSION = _T["unicode"]
_DECOMP = {int(k): v for k, v in _T["decomp"].items()}
_CCC = {int(k): v for k, v in _T["ccc"].items()}
_COMP = {int(a): {int(b): c for b, c in m.items()} for a, m in _T["comp"].items()}
_LOWER = {int(k): v for k, v in _T["lower"].items()}
_DROP = set()
for _a, _b in _T["drop"]:
    _DROP.update(range(_a, _b + 1))
_CHANGES = set()
for _a, _b in _T["changes"]:
    _CHANGES.update(range(_a, _b + 1))

_SBASE, _LBASE, _VBASE, _TBASE = 0xAC00, 0x1100, 0x1161, 0x11A7
_LCOUNT, _VCOUNT, _TCOUNT = 19, 21, 28
_NCOUNT = _VCOUNT * _TCOUNT
_SCOUNT = _LCOUNT * _NCOUNT


def _compose_pair(a, b):
    if _LBASE <= a < _LBASE + _LCOUNT and _VBASE <= b < _VBASE + _VCOUNT:
        return _SBASE + ((a - _LBASE) * _VCOUNT + (b - _VBASE)) * _TCOUNT
    if _SBASE <= a < _SBASE + _SCOUNT and (a - _SBASE) % _TCOUNT == 0 and _TBASE < b < _TBASE + _TCOUNT:
        return a + (b - _TBASE)
    return _COMP.get(a, {}).get(b)


def nfkc_codepoints(cps):
    d = []
    for c in cps:
        if _SBASE <= c < _SBASE + _SCOUNT:
            si = c - _SBASE
            d.append(_LBASE + si // _NCOUNT)
            d.append(_VBASE + (si % _NCOUNT) // _TCOUNT)
            if si % _TCOUNT:
                d.append(_TBASE + si % _TCOUNT)
        else:
            d.extend(_DECOMP.get(c, [c]))
    i = 0
    while i < len(d):
        if _CCC.get(d[i], 0):
            j = i
            while j + 1 < len(d) and _CCC.get(d[j + 1], 0):
                j += 1
            d[i:j + 1] = sorted(d[i:j + 1], key=lambda c: _CCC[c])  # stable
            i = j + 1
        else:
            i += 1
    out, starter, last = [], None, None
    for c in d:
        cc = _CCC.get(c, 0)
        if starter is not None and (last is None or last < cc):
            comp = _compose_pair(out[starter], c)
            if comp is not None:
                out[starter] = comp
                continue
        if cc == 0:
            starter, last = len(out), None
        else:
            last = cc
        out.append(c)
    return out


def _fold(c):
    if 0x30A1 <= c <= 0x30F6 or c in (0x30FD, 0x30FE):
        return c - 0x60
    return c


def _decode_lenient(b):
    """Code points of bytes `b` exactly as the plugin's kosort.lua decodes them: invalid
    sequences become U+FFFD the way it does, surrogates and overlong forms pass through."""
    cps, i, n = [], 0, len(b)
    while i < n:
        c0 = b[i]
        if c0 < 0x80:
            c, extra = c0, 0
        elif 0xF0 <= c0 < 0xF8:
            c, extra = c0 & 0x07, 3
        elif c0 >= 0xE0:
            c, extra = c0 & 0x0F, 2
        elif c0 >= 0xC2:
            c, extra = c0 & 0x1F, 1
        else:
            c, extra = 0xFFFD, 0
        for k in range(1, extra + 1):
            if i + k >= n or (b[i + k] & 0xC0) != 0x80:
                c, extra = 0xFFFD, k - 1
                break
            c = c * 64 + (b[i + k] & 0x3F)
        cps.append(c)
        i += extra + 1
    return cps


def _encode_lenient(cps):
    """UTF-8 bytes of code points as kosort.lua writes them (surrogates included)."""
    out = bytearray()
    for c in cps:
        if c < 0x80:
            out.append(c)
        elif c < 0x800:
            out += bytes((0xC0 | (c >> 6), 0x80 | (c & 0x3F)))
        elif c < 0x10000:
            out += bytes((0xE0 | (c >> 12), 0x80 | ((c >> 6) & 0x3F), 0x80 | (c & 0x3F)))
        else:
            out += bytes((0xF0 | (c >> 18), 0x80 | ((c >> 12) & 0x3F), 0x80 | ((c >> 6) & 0x3F), 0x80 | (c & 0x3F)))
    return bytes(out)


_ASCII_DROP = bytes(c for c in range(128) if c in _DROP)


def normalize_bytes(key):
    """kosort-1 normalised bytes of the key bytes `key`, identical to the plugin's
    kosort.normalize for any input, including invalid UTF-8. Indexes (tools/koidx.py)
    are built with this."""
    if key.isascii():
        return key.translate(None, _ASCII_DROP).lower()
    try:
        cps = [ord(ch) for ch in key.decode("utf-8")]
        strict = True
    except UnicodeDecodeError:
        cps = _decode_lenient(key)
        strict = False
    if any(c in _CHANGES for c in cps):
        cps = nfkc_codepoints(cps)
    out = []
    for c in cps:
        for m in _LOWER.get(c, (c,)):
            m = _fold(m)
            if m not in _DROP:
                out.append(m)
    if strict:
        return "".join(map(chr, out)).encode("utf-8")
    return _encode_lenient(out)


def normalize(key):
    """kosort-1 normalised form of `key` (str or UTF-8 bytes), as str. For bytes that may not
    be valid UTF-8, use normalize_bytes, which matches the plugin byte for byte."""
    if isinstance(key, bytes):
        key = key.decode("utf-8", "replace")
    cps = [ord(ch) for ch in key]
    if any(c in _CHANGES for c in cps):
        cps = nfkc_codepoints(cps)
    out = []
    for c in cps:
        for m in _LOWER.get(c, (c,)):
            m = _fold(m)
            if m not in _DROP:
                out.append(chr(m))
    return "".join(out)


def sort_key(key):
    """Sort key for exporters: the normalised UTF-8 bytes."""
    if isinstance(key, str):
        key = key.encode("utf-8", "surrogatepass")
    return normalize_bytes(key)


VECTORS = [
    "apple", "Apple", "APPLE", "look up", "look-up", "lookup", "don't", "rock 'n' roll", "U.S.A.",
    "café", "café", "CAFÉ", "naïve", "Æsir", "straße", "STRASSE", "İstanbul", "ǅemal", "Ⅻ", "ﬁne",
    "①②", "x²", "H₂O", "½", "ｱｲｳ", "ＡＢＣ", "ｶﾞｷﾞ", "カタカナ", "かたかな", "ラーメン", "らーめん", "ヴァイオリン",
    "ゔぁいおりん", "ヵヶ", "ヽヾ", "ヷ", "日本語", "にほんご", "藤原 道長", "ふじわらの みちとし", "アイ・エス・オー",
    "「ことば」", "〔名〕", "【愛】", "あい【愛】", "한국어", "한", "가", "가",
    "Ελληνικά", "ΣΊΣΥΦΟΣ", "русский", "ПРИВЕТ", "ạ́", "ạ́", "ệ", "ệ",
    "EXPORT:80:68725", "EXPORT:83:File:appendix/usage/04.html", "\\audio\\x.mp3", "a+b=c", "$100", "~tilde",
    "tab\there", "nbsp here", "zero​width", "emoji😀", "𠮷野家", "ｷｬﾝﾌﾟ", "㍿", "㌔", "℃", "№",
    "", "!!!", "・・・", "a  b", "ﾞ", "が", "ぱ", "ﬀ", "ǈ", "ǉ", "Å", "Å", "K",
]


# Byte strings that are not valid UTF-8 (hex), normalised as the plugin decodes them.
BYTE_VECTORS = [
    "ff", "c0af", "e0", "e381", "e381ff", "eda080", "f4908080", "f8888080", "41ff42", "e382a2c3",
    "efbca1fe", "80", "c2", "ed9fbf", "f09f9880",
]


def write_vectors(path):
    with open(path, "w", encoding="utf-8") as f:
        f.write("# %s test vectors (Unicode %s): input<TAB>normalised, both as escaped UTF-8 hex\n"
                % (SPEC, UNICODE_VERSION))
        for v in VECTORS:
            f.write("%s\t%s\n" % (v.encode("utf-8").hex(), normalize(v).encode("utf-8").hex()))
        for h in BYTE_VECTORS:
            f.write("%s\t%s\n" % (h, normalize_bytes(bytes.fromhex(h)).hex()))


def check_vectors(path):
    bad = 0
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            src, want = line.rstrip("\n").split("\t")
            got = normalize_bytes(bytes.fromhex(src)).hex()
            if got != want:
                bad += 1
                print("MISMATCH", bytes.fromhex(src).decode("utf-8"), got, want)
    print("ok" if not bad else "%d mismatches" % bad)
    return bad == 0


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--write":
        write_vectors(sys.argv[2])
    elif len(sys.argv) == 3 and sys.argv[1] == "--check":
        sys.exit(0 if check_vectors(sys.argv[2]) else 1)
    else:
        for arg in sys.argv[1:]:
            print(normalize(arg))
