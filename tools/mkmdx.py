#!/usr/bin/env python3
"""Writer for small MDict files, used to build test fixtures for the plugin.

Supports MDict 1.2 and 2.0, UTF-8 and UTF-16 text, zlib, LZO (needs the
python-lzo module) or uncompressed blocks, the scrambled key index
(Encrypted="2"), and keys in any order, so that the reader and index can be
tested on the same quirks real files have.

    python3 tools/mkmdx.py fixtures <outdir>   # the files the specs use
    python3 tools/mkmdx.py big <outdir>        # 200k-entry file for timing
"""
import os
import random
import struct
import sys
import zlib


def _rol(x, n):
    return ((x << n) | (x >> (32 - n))) & 0xffffffff


def ripemd128(msg):
    h = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476]
    ml = len(msg) * 8
    msg = msg + b"\x80" + b"\x00" * ((55 - len(msg)) % 64) + struct.pack("<Q", ml)
    R = [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15, 7,4,13,1,10,6,15,3,12,0,9,5,2,14,11,8,
         3,10,14,4,9,15,8,1,2,7,0,6,13,11,5,12, 1,9,11,10,0,8,12,4,13,3,7,15,14,5,6,2]
    Rp = [5,14,7,0,9,2,11,4,13,6,15,8,1,10,3,12, 6,11,3,7,0,13,5,10,14,15,8,12,4,9,1,2,
          15,5,1,3,7,14,6,9,11,8,12,2,10,0,4,13, 8,6,4,1,3,11,15,0,5,12,2,13,9,7,10,14]
    S = [11,14,15,12,5,8,7,9,11,13,14,15,6,7,9,8, 7,6,8,13,11,9,7,15,7,12,15,9,11,7,13,12,
         11,13,6,7,14,9,13,15,14,8,13,6,5,12,7,5, 11,12,14,15,14,15,9,8,9,14,5,6,8,6,5,12]
    Sp = [8,9,9,11,13,15,15,5,7,7,8,11,14,14,12,6, 9,13,15,7,12,8,9,11,7,7,12,7,6,15,13,11,
          9,7,15,11,8,6,6,14,12,13,5,14,13,13,7,5, 15,5,8,11,14,14,6,14,6,9,12,9,12,5,15,8]
    K = [0, 0x5A827999, 0x6ED9EBA1, 0x8F1BBCDC]
    Kp = [0x50A28BE6, 0x5C4DD124, 0x6D703EF3, 0]

    def f(j, x, y, z):
        if j < 16:
            return x ^ y ^ z
        if j < 32:
            return (x & y) | (~x & z & 0xffffffff)
        if j < 48:
            return (x | (~y & 0xffffffff)) ^ z
        return (x & z) | (y & ~z & 0xffffffff)

    for off in range(0, len(msg), 64):
        X = struct.unpack("<16I", msg[off:off + 64])
        a, b, c, d = h
        ap, bp, cp, dp = h
        for j in range(64):
            t = _rol((a + f(j, b, c, d) + X[R[j]] + K[j // 16]) & 0xffffffff, S[j])
            a, d, c, b = d, c, b, t
            t = _rol((ap + f(63 - j, bp, cp, dp) + X[Rp[j]] + Kp[j // 16]) & 0xffffffff, Sp[j])
            ap, dp, cp, bp = dp, cp, bp, t
        t = (h[1] + c + dp) & 0xffffffff
        h[1] = (h[2] + d + ap) & 0xffffffff
        h[2] = (h[3] + a + bp) & 0xffffffff
        h[3] = (h[0] + b + cp) & 0xffffffff
        h[0] = t
    return struct.pack("<4I", *h)


assert ripemd128(b"abc").hex() == "c14a12199c66e4ba84636b0f69144c77"


def fast_encrypt(data, key):
    out = bytearray(len(data))
    prev = 0x36
    for i, p in enumerate(data):
        v = p ^ prev ^ (i & 0xff) ^ key[i % len(key)]
        c = ((v >> 4) | (v << 4)) & 0xff
        out[i] = c
        prev = c
    return bytes(out)


def block(data, compression="zlib", encrypt_payload=False):
    if compression == "zlib":
        comp, payload = 2, zlib.compress(data)
    elif compression == "lzo":
        import lzo
        comp, payload = 1, lzo.compress(data, 1, False)  # raw LZO1X-1 stream, no header
    else:
        comp, payload = 0, data
    checksum = struct.pack(">I", zlib.adler32(data) & 0xffffffff)
    info = comp
    if encrypt_payload:
        n = min(len(payload), 255)
        info |= (1 << 4) | (n << 8)
        payload = fast_encrypt(payload[:n], ripemd128(checksum)) + payload[n:]
    return struct.pack("<I", info) + checksum + payload


def write(path, entries, is_mdd=False, version="2.0", encoding="UTF-8", encrypt_index=True,
          compression="zlib", title="Test", header_extra=None, key_block_bytes=16384,
          record_block_bytes=65536, sort=True, encrypt_record_blocks=False, record_order=None):
    """entries: dict or list of (key, value); value is str (MDX) or bytes (MDD).
    record_order: indexes into the (sorted) entries, the order their records are stored in."""
    items = list(entries.items()) if isinstance(entries, dict) else list(entries)
    if sort:
        items.sort(key=lambda kv: kv[0].lower())
    v2 = float(version) >= 2.0
    utf16 = is_mdd or encoding.upper().startswith("UTF-16")
    enc = "utf-16-le" if utf16 else "utf-8"
    term = b"\x00\x00" if utf16 else b"\x00"
    nw = ">Q" if v2 else ">I"
    attrs = {
        "GeneratedByEngineVersion": version, "RequiredEngineVersion": version,
        "Encrypted": "2" if (encrypt_index and v2) else "0",
        "Format": "" if is_mdd else "Html", "CreationDate": "2026-10-30", "Compact": "No",
        "Compat": "No", "KeyCaseSensitive": "No", "Description": "test", "Title": title,
        "DataSourceFormat": "106", "StyleSheet": "",
    }
    if not is_mdd:
        attrs["Encoding"] = encoding
    attrs.update(header_extra or {})
    esc = lambda v: str(v).replace("&", "&amp;").replace('"', "&quot;").replace("<", "&lt;").replace(">", "&gt;")
    hdr = "<%s %s/>\r\n" % ("Library_Data" if is_mdd else "Dictionary",
                            " ".join('%s="%s"' % (k, esc(v)) for k, v in attrs.items()))
    hb = hdr.encode("utf-16-le") + b"\x00\x00"

    recs, offsets, pos = [], [0] * len(items), 0
    for i in (record_order if record_order is not None else range(len(items))):
        v = items[i][1]
        rb = v if is_mdd else v.encode(enc) + term
        offsets[i] = pos
        recs.append(rb)
        pos += len(rb)
    rblocks, cur = [], b""
    for rb in recs:
        cur += rb
        if len(cur) >= record_block_bytes:
            rblocks.append(cur)
            cur = b""
    if cur or not rblocks:
        rblocks.append(cur)

    kblocks, kinfo, cur, curkeys = [], b"", b"", []
    units = (lambda b: len(b) // 2) if utf16 else len

    def flush():
        nonlocal cur, curkeys, kinfo
        if not curkeys:
            return
        cb = block(cur, compression)
        kblocks.append(cb)
        first, last = curkeys[0].encode(enc), curkeys[-1].encode(enc)
        if v2:
            kinfo += (struct.pack(">Q", len(curkeys)) + struct.pack(">H", units(first)) + first + term
                      + struct.pack(">H", units(last)) + last + term + struct.pack(">QQ", len(cb), len(cur)))
        else:
            kinfo += (struct.pack(">I", len(curkeys)) + struct.pack(">B", units(first)) + first
                      + struct.pack(">B", units(last)) + last + struct.pack(">II", len(cb), len(cur)))
        cur, curkeys = b"", []

    for (k, _), off in zip(items, offsets):
        cur += struct.pack(nw, off) + k.encode(enc) + term
        curkeys.append(k)
        if len(cur) >= key_block_bytes:
            flush()
    flush()
    kb = b"".join(kblocks)
    rbc = [block(b, compression, encrypt_record_blocks) for b in rblocks]
    with open(path, "wb") as f:
        f.write(struct.pack(">I", len(hb)) + hb + struct.pack("<I", zlib.adler32(hb) & 0xffffffff))
        if v2:
            ki = block(kinfo, "zlib")
            if encrypt_index:
                ki = ki[:8] + fast_encrypt(ki[8:], ripemd128(ki[4:8] + struct.pack("<L", 0x3695)))
            pre = struct.pack(">5Q", len(kblocks), len(items), len(kinfo), len(ki), len(kb))
            f.write(pre + struct.pack(">I", zlib.adler32(pre) & 0xffffffff) + ki + kb)
            f.write(struct.pack(">4Q", len(rbc), len(items), 16 * len(rbc), sum(map(len, rbc))))
            for c, d in zip(rbc, rblocks):
                f.write(struct.pack(">QQ", len(c), len(d)))
        else:
            f.write(struct.pack(">4I", len(kblocks), len(items), len(kinfo), len(kb)) + kinfo + kb)
            f.write(struct.pack(">4I", len(rbc), len(items), 8 * len(rbc), sum(map(len, rbc))))
            for c, d in zip(rbc, rblocks):
                f.write(struct.pack(">II", len(c), len(d)))
        for c in rbc:
            f.write(c)


PNG_1PX = bytes.fromhex("89504e470d0a1a0a0000000d4948445200000001000000010806000000"
                        "1f15c4890000000d49444154789c6360000002000154a24f5d0000000049454e44ae426082")


def basic_entries(n=3000, seed=1):
    random.seed(seed)
    syll = ["ka", "lo", "mi", "ren", "to", "sa", "vel", "qu", "ar", "in", "on", "eth", "ul", "zy", "pra"]
    words = set()
    while len(words) < n:
        words.add("".join(random.choice(syll) for _ in range(random.randint(2, 5))))
    d = {}
    for w in sorted(words):
        d[w] = ('<link rel="stylesheet" type="text/css" href="basic.css"><div class="hw">%s</div>'
                '<div class="def">definition of %s. See <a href="entry://%s">%s</a>. <img src="img/icon.png"> '
                '<a href="sound://audio/%s.mp3">play</a></div>' % (w, w, w[::-1], w[::-1], w))
    d["Apple"] = '<link rel="stylesheet" href="basic.css"><div class="hw">Apple</div><div class="def">a round fruit. Plural: <a href="entry://apples">apples<span style="border:1px solid;font-size:60%">A</span></a></div>'
    d["apples"] = "@@@LINK=Apple"
    # some dictionaries keep entries under record numbers and link the words to them
    d["banana"] = "@@@LINK=FRT0001234"
    d["FRT0001234"] = '<div class="hw">ba·nana</div><div class="def">a long fruit</div>'
    d["look up"] = '<div class="hw">look up</div><div class="def">to search for something</div>'
    d["lookup"] = '<div class="hw">lookup</div><div class="def">the act of looking something up</div>'
    d["café"] = '<div class="hw">café</div>'
    d["日本語"] = '<div class="hw">日本語</div><div class="def">にほんご</div>'
    d["ラーメン"] = '<div class="hw">ラーメン</div>'
    d["split"] = '<div class="hw"><b>spl</b>it</div><p>one</p><p>word</p>'
    d["long"] = '<div class="hw">long</div>' + "<p>%s</p>" % ("lorem ipsum dolor sit amet " * 4000)
    return d


def fixtures(out):
    os.makedirs(out, exist_ok=True)
    d = basic_entries()
    write(os.path.join(out, "basic.mdx"), d, title="Basic Test")
    m = {"\\basic.css": b".hw{font-weight:bold}\n.def{margin-left:1em}\n@font-face{font-family:T;src:url(fonts/t.ttf)}",
         "\\img\\icon.png": PNG_1PX, "\\fonts\\t.ttf": b"\x00\x01\x00\x00fakefont",
         "\\chain\\a.css": b'@import "b.css";', "\\chain\\b.css": b".x{background:url(../img/icon.png)}",
         "\\audio\\run#_gb_1.aac": b"\xff\xf1fake-adts"}
    random.seed(2)
    for i, w in enumerate(sorted(d)[:500]):
        m["\\audio\\%s.mp3" % w] = random.randbytes(200 + i % 50)
    write(os.path.join(out, "basic.mdd"), m, is_mdd=True)
    # same content in other container variants
    small = dict(list(sorted(d.items()))[:600] + [("Apple", d["Apple"]), ("apples", d["apples"])])
    try:
        import lzo  # noqa: F401
        comp = "lzo"
    except ImportError:
        comp = "zlib"
    write(os.path.join(out, "v12.mdx"), small, version="1.2", encrypt_index=False, compression=comp,
          title="Version 1.2 (%s)" % comp, key_block_bytes=2048, record_block_bytes=8192)
    write(os.path.join(out, "utf16.mdx"), small, encoding="UTF-16", title="UTF-16 Test", key_block_bytes=2048)
    write(os.path.join(out, "raw.mdx"), small, compression="none", encrypt_index=False,
          encrypt_record_blocks=True, title="Uncompressed")
    # keys in arbitrary order, as many real exports have them
    items = list(d.items())
    random.seed(3)
    random.shuffle(items)
    write(os.path.join(out, "unsorted.mdx"), items, sort=False, title="Unsorted Test", key_block_bytes=4096)
    # several entries for one key, and a record spanning block boundaries
    multi = [("bank", "<b>bank</b> (river)"), ("bank", "<b>bank</b> (money)"), ("Bank", "<b>Bank</b> (name)"),
             ("zz", "x" * 70000)]
    write(os.path.join(out, "multi.mdx"), multi, sort=False, title="Multi", record_block_bytes=1000)
    # records stored in another order than their keys: the next key's record is not the next record
    order = [("pitch", "<p>tar</p>"), ("pitch", "<p>field</p>"), ("pitcher", "<p>jug</p>")]
    for enc in ("UTF-8", "UTF-16"):
        write(os.path.join(out, "order-%s.mdx" % enc.lower()), order, sort=False, encoding=enc,
              title="Record Order " + enc, record_order=[1, 0, 2], record_block_bytes=8)
    # a page with every entry for a word under its plain key, and each entry again under its own
    link = '<link rel="stylesheet" type="text/css" href="repeats.css">'
    def unit(name, sense):
        return ('<div class="entry"><span class="hw">%s</span><span class="sense">%s</span></div>'
                % (name, (" " + sense) * 30))
    season, coil = unit("spring", "the season after winter"), unit("spring", "a coil of metal")
    repeats = [("spring", link + season + "<hr>" + link + coil + "\r\n"), ("\u3010spring\u3011", link + coil + "\r\n"),
               ("sprint", link + unit("sprint", "a short fast race") + "\r\n")]
    write(os.path.join(out, "repeats.mdx"), repeats, title="Repeats")
    print("fixtures written to", out)


def big(out):
    os.makedirs(out, exist_ok=True)
    random.seed(1)
    syll = ["ka", "lo", "mi", "ren", "to", "sa", "vel", "qu", "ar", "in", "on", "eth", "ul", "zy", "pra"]
    words = set()
    while len(words) < 200000:
        words.add("".join(random.choice(syll) for _ in range(random.randint(2, 6))))
    d = {w: '<div class="hw">%s</div><div class="def">%s</div>' % (w, "lorem ipsum " * random.randint(5, 80))
         for w in words}
    write(os.path.join(out, "big.mdx"), d, title="Big")


if __name__ == "__main__":
    cmd, out = sys.argv[1], sys.argv[2]
    {"fixtures": fixtures, "big": big}[cmd](out)
