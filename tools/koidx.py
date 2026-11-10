#!/usr/bin/env python3
"""Prebuilt indexes (.koidx) for the KOReader MDict plugin.

The plugin looks keys up through an index sorted by its own key order
(kosort-1 for .mdx, res-1 for .mdd). Most MDict files are sorted another way,
so the plugin builds that index on the e-reader, which takes minutes for large
dictionaries. A dictionary maker can build it once on a computer instead and
ship it beside the volume:

    Foo.mdx  Foo.mdx.koidx  Foo.mdd  Foo.mdd.koidx  Foo.1.mdd  ...

The plugin uses a .koidx only when it matches the volume beside it (key count,
the length and CRC-32 of the volume's header and key section, sampled keys);
otherwise it builds its own index as before. An old .koidx left next to a new
volume is therefore harmless, just not used.

    python3 koidx.py build Foo.mdx [Foo.mdd ...]   # writes Foo.mdx.koidx beside each
    python3 koidx.py check Foo.mdx [--deep]         # does Foo.mdx.koidx fit Foo.mdx?
    python3 koidx.py info Foo.mdx.koidx             # its header

Needs Python 3.8+ and, next to this file, kosort.py and kosort1_tables.json.
Only the header and key section of a volume are read, never its records.

As a module: build_index(volume) -> stats, check_index(volume) -> (ok, reason).

File format (all integers big-endian): a 128-byte header

    0  magic "KOMDXIX" + byte 2      56 dir_off (8)
    8  header_len (128)              64 dir_len
    12 flags (bits 16-31: a reader   68 source_len (8): length of the volume's
       rejects unknown ones)            header and key section
    16 spec, NUL-padded (16)         76 source_crc32: CRC-32 of those bytes
    32 max_key (1000)                80 source_size (8), for messages
    36 page_size (4096)              88 body_crc32: CRC-32 of pages + directory
    40 count (keys)                  92 builder, NUL-padded ASCII (32)
    44 pages                         124 header_crc32: CRC-32 of bytes 0-123
    48 pages_off (8)

then `pages` pages of `page_size` bytes and the directory. A record is the
normalised key (cut to max_key bytes), a zero byte and the key's 4-byte
ordinal (its position in the volume); records are sorted as bytes. A page
holds a 2-byte record count, then varint(len) key ordinal per record, zero
padding. The directory is varint(len) key for each page's first key. A varint
is one byte below 128, otherwise (128 + n % 128, n // 128).
"""
import os
import re
import struct
import sys
import tempfile
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kosort import SPEC as KOSORT_SPEC, normalize_bytes  # noqa: E402

FORMAT = 2
MAGIC = b"KOMDXIX" + bytes([FORMAT])
HEADER_LEN = 128
MAX_KEY = 1000
PAGE_SIZE = 4096
EXT = ".koidx"
BUILDER = "koidx.py 1"
RES_SPEC = "res-1"


class MDictError(Exception):
    """A volume this tool (like the plugin) cannot read."""


# ------------------------------------------------------------------ MDict key section reader
# A port of the plugin's mdict/reader.lua, limited to what an index needs.

def _ripemd128(msg):
    def rol(x, n):
        return ((x << n) | (x >> (32 - n))) & 0xffffffff
    h = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476]
    ml = len(msg) * 8
    msg = msg + b"\x80" + b"\x00" * ((55 - len(msg)) % 64) + struct.pack("<Q", ml)
    R = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 7, 4, 13, 1, 10, 6, 15, 3, 12, 0, 9, 5, 2, 14, 11, 8,
         3, 10, 14, 4, 9, 15, 8, 1, 2, 7, 0, 6, 13, 11, 5, 12, 1, 9, 11, 10, 0, 8, 12, 4, 13, 3, 7, 15, 14, 5, 6, 2]
    Rp = [5, 14, 7, 0, 9, 2, 11, 4, 13, 6, 15, 8, 1, 10, 3, 12, 6, 11, 3, 7, 0, 13, 5, 10, 14, 15, 8, 12, 4, 9, 1, 2,
          15, 5, 1, 3, 7, 14, 6, 9, 11, 8, 12, 2, 10, 0, 4, 13, 8, 6, 4, 1, 3, 11, 15, 0, 5, 12, 2, 13, 9, 7, 10, 14]
    S = [11, 14, 15, 12, 5, 8, 7, 9, 11, 13, 14, 15, 6, 7, 9, 8, 7, 6, 8, 13, 11, 9, 7, 15, 7, 12, 15, 9, 11, 7, 13, 12,
         11, 13, 6, 7, 14, 9, 13, 15, 14, 8, 13, 6, 5, 12, 7, 5, 11, 12, 14, 15, 14, 15, 9, 8, 9, 14, 5, 6, 8, 6, 5, 12]
    Sp = [8, 9, 9, 11, 13, 15, 15, 5, 7, 7, 8, 11, 14, 14, 12, 6, 9, 13, 15, 7, 12, 8, 9, 11, 7, 7, 12, 7, 6, 15, 13, 11,
          9, 7, 15, 11, 8, 6, 6, 14, 12, 13, 5, 14, 13, 13, 7, 5, 15, 5, 8, 11, 14, 14, 6, 14, 6, 9, 12, 9, 12, 5, 15, 8]
    K = [0, 0x5A827999, 0x6ED9EBA1, 0x8F1BBCDC]
    Kp = [0x50A28BE6, 0x5C4DD124, 0x6D703EF3, 0]

    def f(j, x, y, z):
        if j < 16:
            return x ^ y ^ z
        if j < 32:
            return (x & y) | (~x & z)
        if j < 48:
            return (x | ~y) ^ z
        return (x & z) | (y & ~z)

    for off in range(0, len(msg), 64):
        X = struct.unpack("<16L", msg[off:off + 64])
        A, B, C, D = h
        Ap, Bp, Cp, Dp = h
        for j in range(64):
            T = rol((A + (f(j, B, C, D) & 0xffffffff) + X[R[j]] + K[j // 16]) & 0xffffffff, S[j])
            A, D, C, B = D, C, B, T
            T = rol((Ap + (f(63 - j, Bp, Cp, Dp) & 0xffffffff) + X[Rp[j]] + Kp[j // 16]) & 0xffffffff, Sp[j])
            Ap, Dp, Cp, Bp = Dp, Cp, Bp, T
        T = (h[1] + C + Dp) & 0xffffffff
        h[1] = (h[2] + D + Ap) & 0xffffffff
        h[2] = (h[3] + A + Bp) & 0xffffffff
        h[3] = (h[0] + B + Cp) & 0xffffffff
        h[0] = T
    return struct.pack("<4L", *h)


def _fast_decrypt(data, key):
    out = bytearray(data)
    prev = 0x36
    kl = len(key)
    for i, b in enumerate(data):
        t = ((b >> 4) | (b << 4)) & 0xff
        out[i] = t ^ prev ^ (i & 0xff) ^ key[i % kl]
        prev = b
    return bytes(out)


def _lzo_decompress(src, dlen):
    """LZO1X decompression, ported from the plugin's mdict/lzo.lua."""
    out = bytearray()
    i = 0
    n = len(src)

    def need(k):
        if i + k > n:
            raise MDictError("LZO input overrun")

    def copy_match(pos, length):
        if pos < 0:
            raise MDictError("LZO lookbehind overrun")
        for k in range(length):
            out.append(out[pos + k])

    def long_length(base):
        nonlocal i
        total = 0
        need(1)
        while src[i] == 0:
            total += 255
            i += 1
            need(1)
        total += base + src[i]
        i += 1
        return total

    state = "loop"
    need(1)
    t = 0
    if src[0] > 17:
        t = src[0] - 17
        i = 1
        if t < 4:
            state = "match_next"
        else:
            need(t)
            out += src[i:i + t]
            i += t
            state = "first_literal_run"
    while True:
        if state == "loop":
            need(1)
            t = src[i]
            i += 1
            if t >= 16:
                state = "match"
            else:
                if t == 0:
                    t = long_length(15)
                need(t + 3)
                out += src[i:i + t + 3]
                i += t + 3
                state = "first_literal_run"
        elif state == "first_literal_run":
            need(1)
            t = src[i]
            i += 1
            if t >= 16:
                state = "match"
            else:
                need(1)
                m = len(out) - (1 + 0x0800) - (t >> 2) - (src[i] << 2)
                i += 1
                copy_match(m, 3)
                state = "match_done"
        elif state == "match":
            o = len(out)
            if t >= 64:
                need(1)
                m = o - 1 - ((t >> 2) & 7) - (src[i] << 3)
                i += 1
                copy_match(m, (t >> 5) + 1)
            elif t >= 32:
                t &= 31
                if t == 0:
                    t = long_length(31)
                need(2)
                m = o - 1 - (src[i] >> 2) - (src[i + 1] << 6)
                i += 2
                copy_match(m, t + 2)
            elif t >= 16:
                m = o - ((t & 8) << 11)
                t &= 7
                if t == 0:
                    t = long_length(7)
                need(2)
                m = m - (src[i] >> 2) - (src[i + 1] << 6)
                i += 2
                if m == o:
                    break
                copy_match(m - 0x4000, t + 2)
            else:
                need(1)
                m = o - 1 - (t >> 2) - (src[i] << 2)
                i += 1
                copy_match(m, 2)
            state = "match_done"
        elif state == "match_done":
            t = src[i - 2] & 3
            state = "loop" if t == 0 else "match_next"
        else:  # match_next
            need(t)
            out += src[i:i + t]
            i += t
            need(1)
            t = src[i]
            i += 1
            state = "match"
        if len(out) > dlen:
            raise MDictError("LZO output overrun")
    return bytes(out)


def _decode_block(blk, dlen):
    if len(blk) < 8:
        raise MDictError("truncated block")
    info = struct.unpack("<I", blk[:4])[0]
    comp, encm, encsize = info & 0xf, (info >> 4) & 0xf, (info >> 8) & 0xff
    checksum = struct.unpack(">I", blk[4:8])[0]
    data = blk[8:]
    if encm == 1:
        m = min(encsize, len(data))
        data = _fast_decrypt(data[:m], _ripemd128(blk[4:8])) + data[m:]
    elif encm != 0:
        raise MDictError("unsupported block encryption %d" % encm)
    if comp == 2:
        out = zlib.decompress(data)
    elif comp == 1:
        out = _lzo_decompress(data, dlen)
    elif comp == 0:
        out = data
    else:
        raise MDictError("unknown block compression %d" % comp)
    if comp != 2 and zlib.adler32(out) & 0xffffffff != checksum:
        raise MDictError("block checksum mismatch")
    return out


def _utf16_to_utf8(b):
    """UTF-16LE to UTF-8 as the plugin converts it: an odd last byte is dropped, unpaired
    surrogates are kept (as 3-byte sequences)."""
    if len(b) % 2:
        b = b[:-1]
    return b.decode("utf-16-le", "surrogatepass").encode("utf-8", "surrogatepass")


def _unescape(v):
    def ent(m):
        e = m.group(1)
        named = {"quot": '"', "amp": "&", "lt": "<", "gt": ">", "apos": "'"}
        if e in named:
            return named[e]
        mm = re.match(r"^#x([0-9A-Fa-f]+)$", e) or re.match(r"^#(\d+)$", e)
        if mm:
            n = int(mm.group(1), 16 if e.startswith("#x") else 10)
            if n < 0x80:
                return chr(n)
        return m.group(0)
    return re.sub(r"&(#?x?[A-Za-z0-9]+);", ent, v)


class Volume:
    """The header and key section of an .mdx or .mdd file."""

    def __init__(self, path):
        self.path = path
        with open(path, "rb") as f:
            raw = f.read(4)
            if len(raw) < 4:
                raise MDictError("not an MDict file")
            hlen = struct.unpack(">I", raw)[0]
            if hlen <= 0 or hlen > 1048576:
                raise MDictError("not an MDict file")
            hb = f.read(hlen)
            hsum = f.read(4)
            if len(hb) != hlen or len(hsum) != 4 or zlib.adler32(hb) & 0xffffffff != struct.unpack("<I", hsum)[0]:
                raise MDictError("header checksum mismatch")
            if hlen >= 2 and hb[1] == 0:
                htext = _utf16_to_utf8(hb).decode("utf-8", "replace")
            else:
                htext = hb.decode("utf-8", "replace")
            htext = htext.rstrip("\0")
            self.header = {k: _unescape(v) for k, v in re.findall(r'([A-Za-z0-9_]+)\s*=\s*"(.*?)"', htext, re.S)}
            self.is_mdd = re.match(r"\s*<Library_Data", htext) is not None
            try:
                version = float(self.header.get("GeneratedByEngineVersion") or 0)
            except ValueError:
                version = 0
            if version >= 3:
                raise MDictError("MDict 3.0 files are not supported yet")
            e = self.header.get("Encrypted")
            if e in (None, "", "No"):
                encrypt = 0
            elif e == "Yes":
                encrypt = 1
            else:
                try:
                    encrypt = int(e)
                except ValueError:
                    encrypt = 0
            if encrypt & 1:
                raise MDictError("this dictionary's records are encrypted (registered MDict file)")
            enc = re.sub(r"\s", "", self.header.get("Encoding") or "").upper()
            if self.is_mdd:
                enc = "UTF-16"
            elif enc == "":
                enc = "UTF-8"
            if enc in ("UTF-16", "UTF-16LE"):
                self.utf16 = True
            elif enc == "UTF-8":
                self.utf16 = False
            else:
                raise MDictError("unsupported text encoding " + enc)
            v2 = version >= 2
            nw = 8 if v2 else 4
            pos = 8 + hlen
            if v2:
                pre = f.read(40)
                nkb, nent, ki_dlen, ki_len, kb_len = struct.unpack(">5Q", pre)
                if zlib.adler32(pre) & 0xffffffff != struct.unpack(">I", f.read(4))[0]:
                    raise MDictError("key section checksum mismatch")
                pos += 44
            else:
                nkb, nent, ki_len, kb_len = struct.unpack(">4I", f.read(16))
                ki_dlen = None
                pos += 16
            ki = f.read(ki_len)
            if len(ki) != ki_len:
                raise MDictError("truncated key block info")
            if v2:
                if encrypt & 2:
                    ki = ki[:8] + _fast_decrypt(ki[8:], _ripemd128(ki[4:8] + b"\x95\x36\x00\x00"))
                ki = _decode_block(ki, ki_dlen)
            sw, term = (2, 1) if v2 else (1, 0)
            cw = 2 if self.utf16 else 1
            p = 0
            blocks = []
            total = 0
            for _ in range(nkb):
                n = int.from_bytes(ki[p:p + nw], "big")
                p += nw
                ln = int.from_bytes(ki[p:p + sw], "big")
                p += sw + (ln + term) * cw
                ln = int.from_bytes(ki[p:p + sw], "big")
                p += sw + (ln + term) * cw
                clen = int.from_bytes(ki[p:p + nw], "big")
                dlen = int.from_bytes(ki[p + nw:p + 2 * nw], "big")
                p += 2 * nw
                if p > len(ki):
                    raise MDictError("truncated key block info")
                blocks.append((n, clen, dlen))
                total += n
            if total != nent:
                raise MDictError("key count mismatch (%d listed, %d in blocks)" % (nent, total))
            self.num_entries = nent
            self.nw = nw
            self.blocks = blocks
            self.kb_start = pos + ki_len
            self.keys_end = self.kb_start + sum(c for _, c, _ in blocks)
            self.version = version
        self.size = os.path.getsize(path)
        if self.keys_end > self.size:
            raise MDictError("the file is shorter than its key section")

    @property
    def spec(self):
        return RES_SPEC if self.is_mdd else KOSORT_SPEC

    def keys(self):
        """Every key in file order, as the plugin's reader yields them (UTF-8 bytes)."""
        nw, utf16 = self.nw, self.utf16
        with open(self.path, "rb") as f:
            f.seek(self.kb_start)
            for b, (n, clen, dlen) in enumerate(self.blocks):
                data = _decode_block(f.read(clen), dlen)
                p, i, dl = 0, 0, len(data)
                while p < dl and i < n:
                    p += nw
                    if utf16:
                        e = p
                        while e + 1 < dl and (data[e] or data[e + 1]):
                            e += 2
                        yield _utf16_to_utf8(data[p:e])
                        p = e + 2
                    else:
                        e = data.find(b"\0", p)
                        if e < 0:
                            e = dl
                        yield data[p:e]
                        p = e + 1
                    i += 1
                if i != n:
                    raise MDictError("key block %d holds %d keys, expected %d" % (b, i, n))

    def source_crc32(self):
        crc, left = 0, self.keys_end
        with open(self.path, "rb") as f:
            while left > 0:
                s = f.read(min(left, 1 << 20))
                if not s:
                    raise MDictError("the file is shorter than its key section")
                crc = zlib.crc32(s, crc)
                left -= len(s)
        return crc & 0xffffffff


# ------------------------------------------------------------------ index building

def _res_normalize(key):
    s = key.replace(b"/", b"\\").lower()
    return s if s.startswith(b"\\") else b"\\" + s


def _varint(n):
    return bytes((n,)) if n < 128 else bytes((128 + (n & 127), n >> 7))


def index_body(volume):
    """Pages and directory for a Volume, byte-identical to the plugin's Index.buildSidecar.
    Returns (pages bytes, directory bytes, page count, key count, inversions)."""
    norm = _res_normalize if volume.is_mdd else normalize_bytes
    recs = []
    prev, inversions = None, 0
    for o, k in enumerate(volume.keys()):
        n = norm(k)[:MAX_KEY]
        if prev is not None and n < prev:
            inversions += 1
        prev = n
        recs.append(n + b"\0" + o.to_bytes(4, "big"))
    recs.sort()
    pages, dirk = [], []
    page, plen, pcount = [], 2, 0

    def flush():
        body = b"".join(page)
        pages.append(pcount.to_bytes(2, "big") + body + bytes(PAGE_SIZE - 2 - len(body)))

    for r in recs:
        n = r[:-5]
        item = _varint(len(n)) + n + r[-4:]
        if plen + len(item) > PAGE_SIZE or pcount >= 65535:
            flush()
            page, plen, pcount = [], 2, 0
        if pcount == 0:
            dirk.append(n)
        page.append(item)
        plen += len(item)
        pcount += 1
    if pcount:
        flush()
    directory = b"".join(_varint(len(k)) + k for k in dirk)
    return b"".join(pages), directory, len(pages), len(recs), inversions


def _header(spec, count, pages, dir_len, source_len, source_crc, source_size, body_crc, flags=0):
    pages_off = HEADER_LEN
    dir_off = pages_off + pages * PAGE_SIZE
    h = (MAGIC + struct.pack(">II", HEADER_LEN, flags) + spec.encode("ascii").ljust(16, b"\0")
         + struct.pack(">IIIIQQIQIQI", MAX_KEY, PAGE_SIZE, count, pages, pages_off, dir_off, dir_len,
                       source_len, source_crc, source_size, body_crc)
         + BUILDER.encode("ascii").ljust(32, b"\0"))
    assert len(h) == 124
    return h + struct.pack(">I", zlib.crc32(h) & 0xffffffff)


def index_path(volume_path):
    return volume_path + EXT


def build_bytes(volume_path):
    """The whole .koidx for a volume, and stats."""
    v = Volume(volume_path)
    body, directory, pages, count, inversions = index_body(v)
    body_crc = zlib.crc32(directory, zlib.crc32(body)) & 0xffffffff
    head = _header(v.spec, count, pages, len(directory), v.keys_end, v.source_crc32(), v.size, body_crc)
    stats = {"volume": volume_path, "spec": v.spec, "keys": count, "pages": pages, "inversions": inversions,
             "source_len": v.keys_end}
    return head + body + directory, stats


def build_index(volume_path, out=None):
    """Writes the .koidx for a volume (beside it unless `out` is given). Returns stats."""
    data, stats = build_bytes(volume_path)
    out = out or index_path(volume_path)
    folder = os.path.dirname(os.path.abspath(out))
    fd, tmp = tempfile.mkstemp(prefix=".koidx-", dir=folder)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        umask = os.umask(0)
        os.umask(umask)
        os.chmod(tmp, 0o666 & ~umask)  # mkstemp makes it private; an index is as public as its volume
        os.replace(tmp, out)
    except BaseException:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise
    stats["path"] = out
    stats["bytes"] = len(data)
    return stats


# ------------------------------------------------------------------ reading and checking

def read_header(path):
    """Header fields of a .koidx file (dict). Raises ValueError when it is not one."""
    with open(path, "rb") as f:
        h = f.read(HEADER_LEN)
    if len(h) < HEADER_LEN or h[:8] != MAGIC:
        raise ValueError("not a .koidx index (format %d)" % FORMAT)
    if zlib.crc32(h[:124]) & 0xffffffff != struct.unpack(">I", h[124:128])[0]:
        raise ValueError("header checksum mismatch")
    header_len, flags = struct.unpack(">II", h[8:16])
    (max_key, page_size, count, pages, pages_off, dir_off, dir_len, source_len, source_crc, source_size,
     body_crc) = struct.unpack(">IIIIQQIQIQI", h[32:92])
    return {
        "format": FORMAT, "header_len": header_len, "flags": flags, "spec": h[16:32].rstrip(b"\0").decode("ascii"),
        "max_key": max_key, "page_size": page_size, "count": count, "pages": pages, "pages_off": pages_off,
        "dir_off": dir_off, "dir_len": dir_len, "source_len": source_len, "source_crc32": source_crc,
        "source_size": source_size, "body_crc32": body_crc,
        "builder": h[92:124].rstrip(b"\0").decode("ascii", "replace"),
    }


def check_index(volume_path, koidx_path=None, deep=False):
    """Does the .koidx fit the volume as the plugin will check it? Returns (ok, reason).
    deep: also rebuild the index and compare it byte for byte."""
    koidx_path = koidx_path or index_path(volume_path)
    try:
        h = read_header(koidx_path)
        v = Volume(volume_path)
    except (OSError, ValueError, MDictError) as e:
        return False, str(e)
    if h["flags"] >> 16:
        return False, "flags %08x need a newer plugin" % h["flags"]
    if h["spec"] != v.spec:
        return False, "built for %s, the volume needs %s" % (h["spec"], v.spec)
    if h["max_key"] != MAX_KEY:
        return False, "keys cut at %d bytes, the plugin cuts at %d" % (h["max_key"], MAX_KEY)
    if h["count"] != v.num_entries:
        return False, "built for %d keys, the volume has %d" % (h["count"], v.num_entries)
    if h["source_len"] != v.keys_end or h["source_crc32"] != v.source_crc32():
        return False, "built for another version of the volume"
    with open(koidx_path, "rb") as f:
        f.seek(h["pages_off"])
        body = f.read(h["dir_off"] + h["dir_len"] - h["pages_off"])
    if zlib.crc32(body) & 0xffffffff != h["body_crc32"]:
        return False, "the index file is damaged"
    if deep:
        data, _ = build_bytes(volume_path)
        if data[HEADER_LEN:] != body:
            return False, "the index differs from a fresh build"
    return True, "ok"


# ------------------------------------------------------------------ command line

def _main(argv):
    if len(argv) < 2 or argv[0] not in ("build", "check", "info"):
        print("usage: koidx.py build VOLUME ...        write VOLUME.koidx beside each .mdx/.mdd\n"
              "       koidx.py check [--deep] VOLUME ...  check VOLUME.koidx against its volume\n"
              "       koidx.py info FILE.koidx ...       show an index's header", file=sys.stderr)
        return 2
    cmd, args = argv[0], argv[1:]
    deep = "--deep" in args
    files = [a for a in args if a != "--deep"]
    status = 0
    for path in files:
        try:
            if cmd == "build":
                st = build_index(path)
                print("%s: %d keys, %d pages, %.1f MB (%s)" % (st["path"], st["keys"], st["pages"],
                                                               st["bytes"] / 1048576, st["spec"]))
            elif cmd == "check":
                ok, why = check_index(path, deep=deep)
                print("%s: %s" % (index_path(path), why))
                if not ok:
                    status = 1
            else:
                for k, val in read_header(path).items():
                    print("%-13s %s" % (k, ("%08x" % val) if k.endswith("crc32") else val))
        except (OSError, ValueError, MDictError) as e:
            print("%s: %s" % (path, e), file=sys.stderr)
            status = 1
    return status


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
