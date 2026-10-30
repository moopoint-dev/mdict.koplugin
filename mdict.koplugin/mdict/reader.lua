--[[--
Reader for MDict dictionaries (.mdx) and resource archives (.mdd).

Supports format versions 1.2 and 2.0, UTF-8 and UTF-16 text, zlib, LZO and
uncompressed blocks, and the scrambled key index (Encrypted="2"). Block tables
are stored in FFI arrays: the largest files have hundreds of thousands of
record blocks, which would cost far too much memory as Lua tables.

Keys are addressed by their 0-based ordinal in file order. The file's own key
order is not trusted for searching (see mdict/index.lua).
]]

local bit = require("bit")
local ffi = require("ffi")
local fileio = require("mdict/fileio")
local lzo = require("mdict/lzo")
local ripemd128 = require("mdict/ripemd128")
local zlib = require("mdict/zlib")

local band, bor, bxor, rshift, lshift = bit.band, bit.bor, bit.bxor, bit.rshift, bit.lshift

pcall(ffi.cdef, "size_t strlen(const char *s);")
local C = ffi.C

local Reader = {}

---------------------------------------------------------------- helpers

-- Big-endian unsigned integer of `n` bytes at 0-based offset `i` of pointer `p`.
local function be(p, i, n)
    local v = 0
    for k = i, i + n - 1 do
        v = v * 256 + p[k]
    end
    return v
end

local function le32(p, i)
    return p[i] + p[i + 1] * 256 + p[i + 2] * 65536 + p[i + 3] * 16777216
end

--- UTF-16LE bytes (pointer + byte length) to a UTF-8 Lua string.
local utf16_out = ffi.new("uint8_t[?]", 4096)
local utf16_out_size = 4096
local function utf16le_to_utf8(p, nbytes)
    local need = nbytes * 2 + 4 -- each code unit becomes at most 3 bytes; pairs become 4
    if need > utf16_out_size then
        utf16_out_size = need
        utf16_out = ffi.new("uint8_t[?]", need)
    end
    local out = utf16_out
    local o, i = 0, 0
    while i + 1 < nbytes do
        local c = p[i] + p[i + 1] * 256
        i = i + 2
        if c >= 0xD800 and c <= 0xDBFF and i + 1 < nbytes then
            local c2 = p[i] + p[i + 1] * 256
            if c2 >= 0xDC00 and c2 <= 0xDFFF then
                i = i + 2
                c = 0x10000 + (c - 0xD800) * 0x400 + (c2 - 0xDC00)
            end
        end
        if c < 0x80 then
            out[o] = c; o = o + 1
        elseif c < 0x800 then
            out[o] = bor(0xC0, rshift(c, 6)); out[o + 1] = bor(0x80, band(c, 0x3F)); o = o + 2
        elseif c < 0x10000 then
            out[o] = bor(0xE0, rshift(c, 12)); out[o + 1] = bor(0x80, band(rshift(c, 6), 0x3F))
            out[o + 2] = bor(0x80, band(c, 0x3F)); o = o + 3
        else
            out[o] = bor(0xF0, rshift(c, 18)); out[o + 1] = bor(0x80, band(rshift(c, 12), 0x3F))
            out[o + 2] = bor(0x80, band(rshift(c, 6), 0x3F)); out[o + 3] = bor(0x80, band(c, 0x3F)); o = o + 4
        end
    end
    return ffi.string(out, o)
end
Reader.utf16le_to_utf8 = function(s)
    return utf16le_to_utf8(ffi.cast("const uint8_t *", s), #s)
end

--- UTF-8 Lua string to UTF-16LE bytes.
function Reader.utf8_to_utf16le(s)
    local out = {}
    local i, n = 1, #s
    while i <= n do
        local b = s:byte(i)
        local c, len
        if b < 0x80 then c, len = b, 1
        elseif b < 0xE0 then c, len = band(b, 0x1F), 2
        elseif b < 0xF0 then c, len = band(b, 0x0F), 3
        else c, len = band(b, 0x07), 4 end
        for k = 1, len - 1 do
            c = c * 64 + band(s:byte(i + k) or 0x80, 0x3F)
        end
        i = i + len
        if c >= 0x10000 then
            c = c - 0x10000
            local hi, lo = 0xD800 + rshift(c, 10), 0xDC00 + band(c, 0x3FF)
            out[#out + 1] = string.char(band(hi, 255), rshift(hi, 8), band(lo, 255), rshift(lo, 8))
        else
            out[#out + 1] = string.char(band(c, 255), rshift(c, 8))
        end
    end
    return table.concat(out)
end

local function unescape_attr(v)
    return (v:gsub("&(#?x?%w+);", function(e)
        if e == "quot" then return '"'
        elseif e == "amp" then return "&"
        elseif e == "lt" then return "<"
        elseif e == "gt" then return ">"
        elseif e == "apos" then return "'"
        end
        local n = e:match("^#x(%x+)$")
        n = n and tonumber(n, 16) or tonumber(e:match("^#(%d+)$") or "")
        if n and n < 0x80 then return string.char(n) end
    end))
end

-- MDict's "fast" decryption of the key index and of encrypted block payloads.
local function fast_decrypt(p, n, key)
    local out = ffi.new("uint8_t[?]", math.max(n, 1))
    local klen = #key
    local kb = ffi.cast("const uint8_t *", key)
    local prev = 0x36
    for i = 0, n - 1 do
        local b = p[i]
        local t = band(bor(rshift(b, 4), lshift(b, 4)), 0xff)
        out[i] = bxor(t, prev, band(i, 0xff), kb[i % klen])
        prev = b
    end
    return out
end

--- Decode one compressed block (4-byte info, 4-byte Adler-32, payload).
-- `p` points at the block, `len` is its total size, `dlen` its decompressed size.
-- Returns a uint8_t buffer and its length.
local function decode_block(p, len, dlen)
    if len < 8 then error("truncated block") end
    local info = le32(p, 0)
    local comp, encm, encsize = band(info, 0xf), band(rshift(info, 4), 0xf), band(rshift(info, 8), 0xff)
    local checksum = be(p, 4, 4)
    local data, n = p + 8, len - 8
    local anchor -- keeps a decrypted copy alive while `data` points into it
    if encm == 1 then
        local key = ripemd128(ffi.string(p + 4, 4))
        local m = math.min(encsize, n)
        anchor = ffi.new("uint8_t[?]", math.max(n, 1))
        ffi.copy(anchor, fast_decrypt(data, m, key), m)
        ffi.copy(anchor + m, data + m, n - m)
        data = anchor
    elseif encm ~= 0 then
        error("unsupported block encryption " .. encm)
    end
    local out, olen
    if comp == 2 then
        out, olen = zlib.inflate(data, n, dlen)
    elseif comp == 1 then
        out, olen = lzo.decompress(data, n, dlen)
    elseif comp == 0 then
        out = ffi.new("uint8_t[?]", math.max(n, 1))
        ffi.copy(out, data, n)
        olen = n
    else
        error("unknown block compression " .. comp)
    end
    if zlib.adler32(out, olen) ~= checksum then
        error("block checksum mismatch")
    end
    return out, olen
end
Reader._decode_block = decode_block

---------------------------------------------------------------- LRU

local LRU = {}
LRU.__index = LRU

local function new_lru(max_items, max_bytes)
    return setmetatable({ max_items = max_items, max_bytes = max_bytes or math.huge,
                          map = {}, order = {}, bytes = 0 }, LRU)
end

function LRU:get(k)
    local v = self.map[k]
    if v then
        for i = #self.order, 1, -1 do
            if self.order[i] == k then
                table.remove(self.order, i)
                break
            end
        end
        self.order[#self.order + 1] = k
        return v.value
    end
end

function LRU:put(k, value, size)
    size = size or 0
    if self.map[k] then return end
    self.map[k] = { value = value, size = size }
    self.order[#self.order + 1] = k
    self.bytes = self.bytes + size
    while #self.order > 1 and (#self.order > self.max_items or self.bytes > self.max_bytes) do
        local old = table.remove(self.order, 1)
        self.bytes = self.bytes - self.map[old].size
        self.map[old] = nil
    end
end

function LRU:clear()
    self.map, self.order, self.bytes = {}, {}, 0
end

---------------------------------------------------------------- open

local Dict = {}
Dict.__index = Dict

--- Opens a .mdx or .mdd file. Returns the dictionary object, or nil and an error message.
function Reader.open(path)
    local ok, res = pcall(Reader._open, path)
    if not ok then
        return nil, tostring(res):gsub("^.-:%d+: ", "")
    end
    return res
end

function Reader._open(path)
    local f = assert(fileio.open(path))
    local self = setmetatable({ file = f, path = path }, Dict)
    local ok, err = pcall(self._parse, self)
    if not ok then
        f:close()
        error(err, 0)
    end
    return self
end

local function read_header(f)
    local hlen = be(f:read(0, 4), 0, 4)
    if hlen <= 0 or hlen > 1048576 then error("not an MDict file") end
    local hb = f:read(4, hlen)
    local hsum = f:read(4 + hlen, 4)
    if zlib.adler32(hb, hlen) ~= le32(hsum, 0) then error("header checksum mismatch") end
    local htext
    if hlen >= 2 and hb[1] == 0 then -- UTF-16LE (all real files)
        htext = utf16le_to_utf8(hb, hlen)
    else
        htext = ffi.string(hb, hlen)
    end
    htext = htext:gsub("%z+$", "")
    local header = {}
    for k, v in htext:gmatch('([%w_]+)%s*=%s*"(.-)"') do
        header[k] = unescape_attr(v)
    end
    return htext, header, 8 + hlen
end

local function header_title(header)
    local t = header.Title and header.Title:match("^%s*(.-)%s*$")
    if not t or t == "" or t:find("^Title %(No HTML code allowed%)") then return nil end
    return t
end

--- Reads only the header of a file: { header = {attr = value}, title = string|nil, is_mdd = bool }.
function Reader.peekHeader(path)
    local f, err = fileio.open(path)
    if not f then return nil, err end
    local ok, htext, header = pcall(read_header, f)
    f:close()
    if not ok then return nil, tostring(htext):gsub("^.-:%d+: ", "") end
    return { header = header, title = header_title(header), is_mdd = htext:find("^%s*<Library_Data") ~= nil }
end

function Dict:_parse()
    local f = self.file
    local htext, header, pos = read_header(f)
    self.header_text = htext
    self.header = header
    self.is_mdd = htext:find("^%s*<Library_Data") ~= nil
    local version = tonumber(self.header.GeneratedByEngineVersion) or 0
    self.version = version
    if version >= 3 then error("MDict 3.0 files are not supported yet") end

    local e = self.header.Encrypted
    local encrypt = (e == nil or e == "" or e == "No") and 0 or (e == "Yes" and 1 or tonumber(e) or 0)
    if band(encrypt, 1) ~= 0 then
        error("this dictionary's records are encrypted (registered MDict file)")
    end

    local enc = (self.header.Encoding or ""):upper():gsub("%s", "")
    if self.is_mdd then
        enc = "UTF-16"
    elseif enc == "" then
        enc = "UTF-8"
    end
    if enc == "UTF-16" or enc == "UTF-16LE" then
        self.utf16 = true
    elseif enc == "UTF-8" then
        self.utf16 = false
    else
        error("unsupported text encoding " .. enc)
    end
    self.encoding = enc
    self.title = header_title(self.header)

    local v2 = version >= 2
    local nw = v2 and 8 or 4
    self.nw = nw

    -- key section preamble
    local prelen = v2 and 40 or 16
    local pre = f:read(pos, prelen)
    local nkb, nentries = be(pre, 0, nw), be(pre, nw, nw)
    local ki_dlen, ki_len, kb_len
    if v2 then
        ki_dlen, ki_len, kb_len = be(pre, 16, 8), be(pre, 24, 8), be(pre, 32, 8)
        if zlib.adler32(pre, prelen) ~= be(f:read(pos + prelen, 4), 0, 4) then
            error("key section checksum mismatch")
        end
        pos = pos + prelen + 4
    else
        ki_len, kb_len = be(pre, 8, 4), be(pre, 12, 4)
        pos = pos + prelen
    end
    self.num_entries = nentries
    self.num_key_blocks = nkb

    -- key block info
    local ki = f:read(pos, ki_len)
    pos = pos + ki_len
    local kilen = ki_len
    if v2 then
        if band(encrypt, 2) ~= 0 then
            local key = ripemd128(ffi.string(ki + 4, 4) .. "\149\54\0\0")
            local dec = fast_decrypt(ki + 8, ki_len - 8, key)
            ffi.copy(ki + 8, dec, ki_len - 8)
        end
        ki, kilen = decode_block(ki, ki_len, ki_dlen)
    end
    self:_parseKeyBlockInfo(ki, kilen, pos)

    -- record section
    pos = pos + kb_len
    local rp = f:read(pos, nw * 4)
    local nrb = be(rp, 0, nw)
    local ri_len = be(rp, nw * 2, nw)
    self.num_record_entries = be(rp, nw, nw)
    pos = pos + nw * 4
    local ri = f:read(pos, ri_len)
    pos = pos + ri_len
    if ri_len < nrb * nw * 2 then error("truncated record index") end
    self.num_record_blocks = nrb
    self.rb_fpos = ffi.new("double[?]", nrb + 1)
    self.rb_doff = ffi.new("double[?]", nrb + 1)
    local fpos, doff = pos, 0
    for i = 0, nrb - 1 do
        local c = be(ri, i * nw * 2, nw)
        local d = be(ri, i * nw * 2 + nw, nw)
        self.rb_fpos[i], self.rb_doff[i] = fpos, doff
        fpos, doff = fpos + c, doff + d
    end
    self.rb_fpos[nrb], self.rb_doff[nrb] = fpos, doff
    self.record_data_size = doff

    self.kb_cache = new_lru(16)
    self.rb_cache = new_lru(8, 24 * 1024 * 1024)
end

function Dict:_parseKeyBlockInfo(ki, kilen, kb_start)
    local nkb, nw = self.num_key_blocks, self.nw
    local v2 = self.version >= 2
    local sw = v2 and 2 or 1          -- width of the first/last key length fields
    local term = v2 and 1 or 0        -- v2 stores a terminator after first/last keys
    local cw = self.utf16 and 2 or 1  -- bytes per code unit
    self.kb_fpos = ffi.new("double[?]", nkb + 1)
    self.kb_clen = ffi.new("double[?]", nkb)
    self.kb_dlen = ffi.new("double[?]", nkb)
    self.kb_ord0 = ffi.new("double[?]", nkb + 1)
    self.kb_first, self.kb_last = {}, {}
    local p, fpos, ord = 0, kb_start, 0
    local function key_at(at, units)
        local nbytes = units * cw
        if at + nbytes > kilen then error("truncated key block info") end
        if self.utf16 then
            return utf16le_to_utf8(ki + at, nbytes)
        end
        return ffi.string(ki + at, nbytes)
    end
    for b = 0, nkb - 1 do
        local n = be(ki, p, nw); p = p + nw
        local l = be(ki, p, sw); p = p + sw
        self.kb_first[b] = key_at(p, l); p = p + (l + term) * cw
        l = be(ki, p, sw); p = p + sw
        self.kb_last[b] = key_at(p, l); p = p + (l + term) * cw
        local clen = be(ki, p, nw); p = p + nw
        local dlen = be(ki, p, nw); p = p + nw
        self.kb_fpos[b], self.kb_clen[b], self.kb_dlen[b], self.kb_ord0[b] = fpos, clen, dlen, ord
        fpos, ord = fpos + clen, ord + n
    end
    self.kb_fpos[nkb], self.kb_ord0[nkb] = fpos, ord
    if ord ~= self.num_entries then
        error(string.format("key count mismatch (%d listed, %d in blocks)", self.num_entries, ord))
    end
end

---------------------------------------------------------------- keys

--- Decodes key block `b` (0-based) without caching.
-- Returns { n = count, keys = { [0..n-1] = UTF-8 key }, offs = double[n], ord0 = first ordinal }.
function Dict:_decodeKeyBlock(b)
    local raw = self.file:read(self.kb_fpos[b], self.kb_clen[b])
    local data, dlen = decode_block(raw, self.kb_clen[b], self.kb_dlen[b])
    local nw = self.nw
    local n = self.kb_ord0[b + 1] - self.kb_ord0[b]
    local keys, offs = {}, ffi.new("double[?]", math.max(n, 1))
    local p, i = 0, 0
    local utf16 = self.utf16
    while p < dlen and i < n do
        offs[i] = be(data, p, nw)
        p = p + nw
        local e
        if utf16 then
            e = p
            while e + 1 < dlen and (data[e] ~= 0 or data[e + 1] ~= 0) do e = e + 2 end
            keys[i] = utf16le_to_utf8(data + p, e - p)
            p = e + 2
        else
            local l = tonumber(C.strlen(ffi.cast("const char *", data + p)))
            if p + l > dlen then l = dlen - p end
            keys[i] = ffi.string(data + p, l)
            p = p + l + 1
        end
        i = i + 1
    end
    if i ~= n then
        error(string.format("key block %d holds %d keys, expected %d", b, i, n))
    end
    return { n = n, keys = keys, offs = offs, ord0 = self.kb_ord0[b] }
end

function Dict:keyBlock(b)
    local kb = self.kb_cache:get(b)
    if not kb then
        kb = self:_decodeKeyBlock(b)
        self.kb_cache:put(b, kb)
    end
    return kb
end

--- Index of the key block holding ordinal `ord`.
function Dict:keyBlockOf(ord)
    local lo, hi = 0, self.num_key_blocks - 1
    while lo < hi do
        local mid = rshift(lo + hi + 1, 1)
        if self.kb_ord0[mid] <= ord then lo = mid else hi = mid - 1 end
    end
    return lo
end

--- Key text and record offset of ordinal `ord`.
function Dict:keyAt(ord)
    if ord < 0 or ord >= self.num_entries then return nil end
    local b = self:keyBlockOf(ord)
    local kb = self:keyBlock(b)
    local i = ord - kb.ord0
    return kb.keys[i], kb.offs[i]
end

--- Calls fn(key, ordinal, record_offset) for every key in file order.
-- Stops early if fn returns true. Key blocks are not cached.
function Dict:eachKey(fn, first_block, last_block)
    for b = first_block or 0, last_block or self.num_key_blocks - 1 do
        local kb = self:_decodeKeyBlock(b)
        local keys, offs, ord0 = kb.keys, kb.offs, kb.ord0
        for i = 0, kb.n - 1 do
            if fn(keys[i], ord0 + i, offs[i]) then return end
        end
    end
end

---------------------------------------------------------------- records

function Dict:_recordBlockOf(off)
    local lo, hi = 0, self.num_record_blocks - 1
    while lo < hi do
        local mid = rshift(lo + hi + 1, 1)
        if self.rb_doff[mid] <= off then lo = mid else hi = mid - 1 end
    end
    return lo
end

function Dict:_recordBlock(r)
    local blk = self.rb_cache:get(r)
    if not blk then
        local clen = self.rb_fpos[r + 1] - self.rb_fpos[r]
        local dlen = self.rb_doff[r + 1] - self.rb_doff[r]
        local raw = self.file:read(self.rb_fpos[r], clen)
        local data, n = decode_block(raw, clen, dlen)
        blk = { data = data, n = n }
        self.rb_cache:put(r, blk, n)
    end
    return blk
end

--- Raw bytes of the record data between decompressed offsets [off, off + size).
-- A nil size reads to the record's terminator (text dictionaries) or block end.
function Dict:readRecordAt(off, size)
    if off < 0 or off >= self.record_data_size then
        error("record offset out of range")
    end
    local parts = {}
    local remaining = size or math.huge
    local r = self:_recordBlockOf(off)
    while remaining > 0 and r < self.num_record_blocks do
        local blk = self:_recordBlock(r)
        local start = off - self.rb_doff[r]
        local avail = blk.n - start
        if not size then
            -- scan for the terminator inside this block
            local term = self.utf16 and 2 or 1
            local e = start
            if term == 1 then
                while e < blk.n and blk.data[e] ~= 0 do e = e + 1 end
            else
                while e + 1 < blk.n and (blk.data[e] ~= 0 or blk.data[e + 1] ~= 0) do e = e + 2 end
            end
            parts[#parts + 1] = ffi.string(blk.data + start, e - start)
            if e < blk.n then break end
            off = self.rb_doff[r + 1]
        else
            local take = math.min(avail, remaining)
            parts[#parts + 1] = ffi.string(blk.data + start, take)
            remaining = remaining - take
            off = off + take
        end
        r = r + 1
    end
    return table.concat(parts)
end

--- Decompressed offset range of the record for ordinal `ord`: offset, size (size may be nil).
function Dict:recordRange(ord)
    local key, off = self:keyAt(ord)
    if not key then return nil end
    local nxt
    if ord + 1 < self.num_entries then
        local _, noff = self:keyAt(ord + 1)
        nxt = noff
    else
        nxt = self.record_data_size
    end
    if nxt and nxt > off then
        return off, nxt - off
    end
    return off, nil
end

--- Record for ordinal `ord`. Text dictionaries return UTF-8 with trailing NULs
-- removed; resource archives return the raw bytes.
function Dict:record(ord)
    local off, size = self:recordRange(ord)
    if not off then return nil end
    local data = self:readRecordAt(off, size)
    if self.is_mdd then
        return data
    end
    if self.utf16 then
        data = utf16le_to_utf8(ffi.cast("const uint8_t *", data), #data)
    end
    return (data:gsub("%z+$", ""))
end

function Dict:clearCaches()
    self.kb_cache:clear()
    self.rb_cache:clear()
end

function Dict:close()
    if self.file then
        self.file:close()
        self.file = nil
    end
    self.kb_cache:clear()
    self.rb_cache:clear()
end

return Reader
