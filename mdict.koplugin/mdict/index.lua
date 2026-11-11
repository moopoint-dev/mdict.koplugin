--[[--
Key indexes for MDict files.

A file's own key order cannot be trusted (builders sort with their own,
undocumented rules), so lookups go through one of two indexes, both keyed by
a normalised form of each key:

* FileOrderIndex searches the file's key blocks directly. It is only used once
  the whole file has been verified to be in normalised order (for example
  files written by an exporter that sorts with kosort-1).
* SidecarIndex is a compact sorted file built once per dictionary: normalised
  key bytes plus a 4-byte key ordinal, packed into fixed-size pages, with the
  first key of every page kept in memory.

Sidecars come in two formats with the same pages. Format 1 (64-byte header) is
built by the plugin into its cache and tied to the file's size and mtime.
Format 2 (128-byte header) is a ".koidx" file a dictionary maker ships beside
the volume (tools/koidx.py writes it). It is tied to the volume's content: the
length and CRC-32 of the volume's header and key section, which is all an index
depends on. Its header:

    0  magic "KOMDXIX" 2     32 max_key      48 pages_off (8)   76 source_crc32
    8  header_len            36 page_size    56 dir_off (8)     80 source_size (8)
    12 flags                 40 count        64 dir_len         88 body_crc32
    16 spec (16, NUL-padded) 44 pages        68 source_len (8)  92 builder (32)
                                                                124 header_crc32

All big-endian. Flag bits 16-31 must be understood: a file with an unknown one
set is ignored. body_crc32 covers the pages and the directory.

Verification never trusts the header hint KOReaderKeyOrder: a cheap check of
the key-block boundaries rejects most unsorted files without decompressing
anything, and the full check streams every key, sharing the pass with the
sidecar build.
]]

local bit = require("bit")
local ffi = require("ffi")
local fileio = require("mdict/fileio")
local kosort = require("mdict/kosort")
local zlib = require("mdict/zlib")

local band, rshift = bit.band, bit.rshift
local byte, char, sub = string.byte, string.char, string.sub

local Index = {}

Index.FORMAT = 1
Index.PAGE_SIZE = 4096
Index.MAX_KEY = 1000 -- normalised keys are truncated to this many bytes, for both indexing and queries
Index.CHUNK = 200000 -- keys sorted in memory per run of the external sort
local MAGIC = "KOMDXIX" .. char(Index.FORMAT)

Index.SHIPPED_FORMAT = 2
Index.SHIPPED_EXT = ".koidx" -- beside the volume: X.mdx.koidx, X.1.mdd.koidx
Index.SHIPPED_HEADER = 128
Index.SHIPPED_SAMPLES = 8 -- keys compared with the volume when a shipped index is opened
Index.VERIFY_SAMPLES = 128 -- and when it is verified in the background
Index.KNOWN_FLAGS = 0xFFFF -- optional bits are ignored; none of the must-understand bits is known yet
local MAGIC2 = "KOMDXIX" .. char(Index.SHIPPED_FORMAT)

--- Resource paths in .mdd files: case-insensitive ASCII, either slash.
local function res_normalize(s)
    s = s:gsub("/", "\\"):lower()
    if byte(s, 1) ~= 92 then s = "\\" .. s end
    return s
end

local NORMALIZERS = {
    [kosort.spec] = kosort.normalize,
    ["res-1"] = res_normalize,
}

function Index.normalizer(spec)
    local f = assert(NORMALIZERS[spec], "unknown key order spec " .. tostring(spec))
    return function(s)
        local n = f(s)
        if #n > Index.MAX_KEY then n = sub(n, 1, Index.MAX_KEY) end
        return n
    end
end

---------------------------------------------------------------- order checks

--- Fast reject: are the key-block boundary keys in non-decreasing normalised order?
function Index.boundariesOrdered(reader, spec)
    local norm = Index.normalizer(spec)
    local prev = ""
    for b = 0, reader.num_key_blocks - 1 do
        local f, l = norm(reader.kb_first[b]), norm(reader.kb_last[b])
        if f < prev or l < f then return false end
        prev = l
    end
    return true
end

--- Full check: streams every key. Returns sorted, number of inversions.
function Index.verifyOrder(reader, spec, should_stop)
    local norm = Index.normalizer(spec)
    local prev, inversions = nil, 0
    local stopped = false
    reader:eachKey(function(key)
        local n = norm(key)
        if prev and n < prev then
            inversions = inversions + 1
            if should_stop and should_stop(inversions) then
                stopped = true
                return true
            end
        end
        prev = n
    end)
    return inversions == 0 and not stopped, inversions
end

---------------------------------------------------------------- encoding helpers

local function be32(n)
    return char(band(rshift(n, 24), 255), band(rshift(n, 16), 255), band(rshift(n, 8), 255), band(n, 255))
end
local function rd32(s, i)
    local a, b, c, d = byte(s, i, i + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
end
local function be64(n)
    return be32(math.floor(n / 4294967296)) .. be32(n % 4294967296)
end
local function rd64(s, i)
    return rd32(s, i) * 4294967296 + rd32(s, i + 4)
end
local function varint(n)
    if n < 128 then return char(n) end
    return char(128 + band(n, 127), rshift(n, 7))
end
-- returns value, next position (1-based)
local function rd_varint_ptr(p, i)
    local b = p[i]
    if b < 128 then return b, i + 1 end
    return (b - 128) + p[i + 1] * 128, i + 2
end
local function rd_varint_str(s, i)
    local b = byte(s, i)
    if b < 128 then return b, i + 1 end
    return (b - 128) + byte(s, i + 1) * 128, i + 2
end

---------------------------------------------------------------- sidecar build

-- Minimal binary heap of run cursors ordered by their current record.
local function heap_push(h, item)
    h[#h + 1] = item
    local i = #h
    while i > 1 do
        local p = rshift(i, 1)
        if h[p].rec <= item.rec then break end
        h[p], h[i] = h[i], h[p]
        i = p
    end
end
local function heap_pop(h)
    local top = h[1]
    local last = table.remove(h)
    if #h > 0 then
        h[1] = last
        local i, n = 1, #h
        while true do
            local l, r, m = i * 2, i * 2 + 1, i
            if l <= n and h[l].rec < h[m].rec then m = l end
            if r <= n and h[r].rec < h[m].rec then m = r end
            if m == i then break end
            h[m], h[i] = h[i], h[m]
            i = m
        end
    end
    return top
end

local function write_run(path, chunk)
    table.sort(chunk)
    local f = assert(io.open(path, "wb"))
    local buf, bn = {}, 0
    for i = 1, #chunk do
        local r = chunk[i]
        bn = bn + 1
        buf[bn] = char(rshift(#r, 8), band(#r, 255)) .. r
        if bn >= 4096 then
            f:write(table.concat(buf, "", 1, bn))
            bn = 0
        end
    end
    f:write(table.concat(buf, "", 1, bn))
    f:close()
end

-- Sequential reader over a run file.
local function open_run(path)
    local f = assert(io.open(path, "rb"))
    local cur = { f = f, buf = "", pos = 1 }
    function cur:next()
        if self.pos + 1 > #self.buf then
            local more = self.f:read(65536)
            if not more then return nil end
            self.buf = sub(self.buf, self.pos) .. more
            self.pos = 1
        end
        local hi, lo = byte(self.buf, self.pos, self.pos + 1)
        local n = hi * 256 + lo
        while self.pos + 1 + n > #self.buf do
            local more = self.f:read(65536)
            if not more then error("truncated run file") end
            self.buf = sub(self.buf, self.pos) .. more
            self.pos = 1
        end
        local rec = sub(self.buf, self.pos + 2, self.pos + 1 + n)
        self.pos = self.pos + 2 + n
        return rec
    end
    return cur
end

--- Builds a sidecar index for `reader` at `path`, checking the file's own order on the way.
-- opts: tmpdir, progress(fraction), source_size, source_mtime.
-- Returns { keys = n, sorted = bool, inversions = n, pages = n }.
function Index.buildSidecar(reader, path, spec, opts)
    opts = opts or {}
    local norm = Index.normalizer(spec)
    local tmp = path .. ".tmp"
    local runs, chunk, cn = {}, {}, 0
    local prev, inversions, count = nil, 0, 0
    local nblocks = reader.num_key_blocks
    local block_done = -1
    reader:eachKey(function(key, ord)
        local n = norm(key)
        if prev and n < prev then inversions = inversions + 1 end
        prev = n
        cn = cn + 1
        chunk[cn] = n .. "\0" .. be32(ord)
        count = count + 1
        if cn >= Index.CHUNK then
            local rp = string.format("%s.run%d", tmp, #runs)
            write_run(rp, chunk)
            runs[#runs + 1] = rp
            chunk, cn = {}, 0
        end
        if opts.progress then
            local b = reader:keyBlockOf(ord)
            if b ~= block_done then
                block_done = b
                opts.progress(0.8 * (b + 1) / nblocks)
            end
        end
    end)

    -- merge into pages
    local out = assert(io.open(tmp, "wb"))
    out:write(string.rep("\0", 64)) -- header placeholder
    local page_size = Index.PAGE_SIZE
    local dir = {}
    local page, plen, pcount = {}, 2, 0
    local pages = 0
    local function flush_page()
        if pcount == 0 then return end
        local body = table.concat(page)
        out:write(char(rshift(pcount, 8), band(pcount, 255)), body, string.rep("\0", page_size - 2 - #body))
        pages = pages + 1
        page, plen, pcount = {}, 2, 0
    end
    local function emit(rec)
        -- rec = norm .. "\0" .. ord4
        local n = sub(rec, 1, #rec - 5)
        local item = varint(#n) .. n .. sub(rec, -4)
        if plen + #item > page_size or pcount >= 65535 then flush_page() end
        if pcount == 0 then dir[#dir + 1] = n end
        page[#page + 1] = item
        plen = plen + #item
        pcount = pcount + 1
    end

    if #runs == 0 then
        table.sort(chunk)
        for i = 1, cn do emit(chunk[i]) end
    else
        if cn > 0 then
            local rp = string.format("%s.run%d", tmp, #runs)
            write_run(rp, chunk)
            runs[#runs + 1] = rp
        end
        chunk = nil
        collectgarbage()
        local heap = {}
        for _, rp in ipairs(runs) do
            local cur = open_run(rp)
            cur.rec = cur:next()
            if cur.rec then heap_push(heap, cur) end
        end
        local emitted = 0
        while #heap > 0 do
            local cur = heap_pop(heap)
            emit(cur.rec)
            emitted = emitted + 1
            if opts.progress and emitted % 50000 == 0 then
                opts.progress(0.8 + 0.2 * emitted / count)
            end
            cur.rec = cur:next()
            if cur.rec then heap_push(heap, cur) else cur.f:close() end
        end
        for _, rp in ipairs(runs) do os.remove(rp) end
    end
    flush_page()

    -- directory
    local dir_off = 64 + pages * page_size
    local dparts = {}
    for i = 1, #dir do dparts[i] = varint(#dir[i]) .. dir[i] end
    local dblob = table.concat(dparts)
    out:write(dblob)
    local specname = spec .. string.rep("\0", 16 - #spec)
    local header = MAGIC .. specname .. be64(opts.source_size or 0) .. be64(opts.source_mtime or 0)
        .. be32(count) .. be32(pages) .. be64(dir_off) .. be32(#dblob) .. be32(page_size)
    header = header .. string.rep("\0", 64 - #header)
    out:seek("set", 0)
    out:write(header)
    out:close()
    os.remove(path)
    assert(os.rename(tmp, path))
    if opts.progress then opts.progress(1) end
    return { keys = count, sorted = inversions == 0, inversions = inversions, pages = pages }
end

---------------------------------------------------------------- sidecar lookup

local SidecarIndex = {}
SidecarIndex.__index = SidecarIndex

--- Fields of a format 2 header (a 128-byte string), or nil and a reason.
function Index.parseShippedHeader(h)
    if not h or #h < Index.SHIPPED_HEADER then return nil, "too short for an index" end
    if sub(h, 1, 8) ~= MAGIC2 then return nil, "not a .koidx index" end
    if zlib.crc32(0, sub(h, 1, 124)) ~= rd32(h, 125) then return nil, "header checksum mismatch" end
    local t = {
        header_len = rd32(h, 9), flags = rd32(h, 13), spec = (sub(h, 17, 32):gsub("%z+$", "")),
        max_key = rd32(h, 33), page_size = rd32(h, 37), count = rd32(h, 41), pages = rd32(h, 45),
        pages_off = rd64(h, 49), dir_off = rd64(h, 57), dir_len = rd32(h, 65),
        source_len = rd64(h, 69), source_crc32 = rd32(h, 77), source_size = rd64(h, 81),
        body_crc32 = rd32(h, 89), builder = (sub(h, 93, 124):gsub("%z+$", "")), header_crc32 = rd32(h, 125),
    }
    if band(t.flags, bit.bnot(Index.KNOWN_FLAGS)) ~= 0 then
        return nil, string.format("needs a newer plugin (flags %08x)", t.flags)
    end
    if t.header_len < Index.SHIPPED_HEADER or t.pages_off < t.header_len then return nil, "bad header length" end
    if t.max_key ~= Index.MAX_KEY then
        return nil, string.format("keys cut at %d bytes, the plugin cuts at %d", t.max_key, Index.MAX_KEY)
    end
    if t.page_size < 512 or t.page_size > 65536 then return nil, "bad page size " .. t.page_size end
    if t.dir_off ~= t.pages_off + t.pages * t.page_size then return nil, "bad page directory offset" end
    return t
end

--- Fields of the format 2 header at `path` (128 bytes read), or nil and a reason.
function Index.readShippedHeader(path)
    local f = io.open(path, "rb")
    if not f then return nil, "missing" end
    local h = f:read(Index.SHIPPED_HEADER)
    f:close()
    return Index.parseShippedHeader(h)
end

--- Opens a sidecar of either format. Returns the index, or nil and a reason (stale, corrupt...).
-- expect: size, mtime (format 1: the source file's), keys, format (1 or 2: only that one).
function Index.openSidecar(path, spec, expect)
    expect = expect or {}
    local f = io.open(path, "rb")
    if not f then return nil, "missing" end
    local magic = f:read(8)
    local h, format, hspec, count, pages, dir_off, dir_len, page_size, pages_off
    if magic == MAGIC then
        format = 1
        local header = magic .. (f:read(56) or "")
        if #header < 64 then
            f:close()
            return nil, "truncated header"
        end
        hspec = sub(header, 9, 24):gsub("%z+$", "")
        local size, mtime = rd64(header, 25), rd64(header, 33)
        count, pages = rd32(header, 41), rd32(header, 45)
        dir_off, dir_len, page_size = rd64(header, 49), rd32(header, 57), rd32(header, 61)
        pages_off = 64
        if (expect.size and expect.size ~= size) or (expect.mtime and expect.mtime ~= mtime) then
            f:close()
            return nil, "stale"
        end
    elseif magic == MAGIC2 then
        format = 2
        local err
        h, err = Index.parseShippedHeader(magic .. (f:read(Index.SHIPPED_HEADER - 8) or ""))
        if not h then
            f:close()
            return nil, err
        end
        hspec, count, pages, dir_off, dir_len = h.spec, h.count, h.pages, h.dir_off, h.dir_len
        page_size, pages_off = h.page_size, h.pages_off
    else
        f:close()
        return nil, "not a sidecar index (or older format)"
    end
    if expect.format and expect.format ~= format then
        f:close()
        return nil, "format " .. format .. ", expected " .. expect.format
    end
    if hspec ~= spec then
        f:close()
        return nil, "built for " .. hspec
    end
    if expect.keys and expect.keys ~= count then
        f:close()
        return nil, format == 1 and "stale" or string.format("built for %d keys, the file has %d", count, expect.keys)
    end
    f:seek("set", dir_off)
    local dblob = f:read(dir_len) or ""
    f:close()
    local dir, i = {}, 1
    while i <= #dblob do
        local n
        n, i = rd_varint_str(dblob, i)
        dir[#dir + 1] = sub(dblob, i, i + n - 1)
        i = i + n
    end
    if #dir ~= pages or i ~= #dblob + 1 then return nil, "corrupt directory" end
    local file = assert(fileio.open(path))
    return setmetatable({
        path = path, file = file, spec = spec, count = count, pages = pages, dir = dir, format = format,
        header = h, page_size = page_size, pages_off = pages_off, page_cache = {}, page_order = {},
        norm = Index.normalizer(spec),
    }, SidecarIndex)
end

function SidecarIndex:_page(p)
    local recs = self.page_cache[p]
    if recs then return recs end
    local size = self.page_size
    local buf = self.file:read(self.pages_off + (p - 1) * size, size)
    local n = buf[0] * 256 + buf[1]
    recs = {}
    local i = 2
    for k = 1, n do
        if i + 2 > size then error("corrupt index page " .. p, 0) end
        local len
        len, i = rd_varint_ptr(buf, i)
        if i + len + 4 > size then error("corrupt index page " .. p, 0) end
        local key = ffi.string(buf + i, len)
        i = i + len
        local ord = ((buf[i] * 256 + buf[i + 1]) * 256 + buf[i + 2]) * 256 + buf[i + 3]
        i = i + 4
        recs[k] = { key, ord }
    end
    self.page_cache[p] = recs
    table.insert(self.page_order, p)
    if #self.page_order > 16 then
        self.page_cache[table.remove(self.page_order, 1)] = nil
    end
    return recs
end

-- Last page whose first key is strictly below `key` (records equal to `key` may start on the previous page).
function SidecarIndex:_startPage(key)
    local lo, hi = 1, self.pages
    local best = 1
    while lo <= hi do
        local mid = rshift(lo + hi, 1)
        if self.dir[mid] < key then
            best = mid
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return best
end

--- Ordinals of all keys whose normalised form equals `nkey` (already normalised).
function SidecarIndex:find(nkey)
    local out = {}
    if self.pages == 0 then return out end
    for p = self:_startPage(nkey), self.pages do
        if p > 1 and self.dir[p] > nkey then break end
        local recs = self:_page(p)
        for k = 1, #recs do
            local r = recs[k]
            if r[1] == nkey then
                out[#out + 1] = r[2]
            elseif r[1] > nkey then
                return out
            end
        end
    end
    return out
end

--- Up to `limit` {key, ord} pairs whose normalised key starts with `nprefix`.
function SidecarIndex:prefix(nprefix, limit)
    local out = {}
    if self.pages == 0 or nprefix == "" then return out end
    local plen = #nprefix
    for p = self:_startPage(nprefix), self.pages do
        if p > 1 and sub(self.dir[p], 1, plen) > nprefix then break end
        local recs = self:_page(p)
        for k = 1, #recs do
            local r = recs[k]
            local head = sub(r[1], 1, plen)
            if head == nprefix then
                out[#out + 1] = r
                if #out >= limit then return out end
            elseif head > nprefix then
                return out
            end
        end
    end
    return out
end

function SidecarIndex:close()
    if self.file then self.file:close() end
    self.file = nil
end

---------------------------------------------------------------- shipped indexes

--- Where the volume's records start: what a shipped index's source_len must be.
local function keys_end(reader)
    return reader.kb_fpos[reader.num_key_blocks]
end
Index.keysEnd = keys_end

--- The checks that cost nothing once the volume is open: does the format 2 index `idx` have the
-- volume's key count and header-and-key-section length? Returns true, or nil and a reason.
function Index.fitsShipped(idx, reader)
    local h = idx.header
    if not h then return nil, "not a shipped index" end
    if idx.count ~= reader.num_entries then
        return nil, string.format("built for %d keys, the file has %d", idx.count, reader.num_entries)
    end
    if h.source_len ~= keys_end(reader) then return nil, "built for another file" end
    return true
end

--- Cheap checks that an opened format 2 index belongs to `reader`'s volume: Index.fitsShipped,
-- and `samples` keys spread over the pages, normalised here and compared with the index.
-- Returns true, or nil and a reason.
function Index.checkShipped(idx, reader, samples)
    local fits, why_not = Index.fitsShipped(idx, reader)
    if not fits then return nil, why_not end
    if idx.pages == 0 then
        return idx.count == 0 or nil, "no pages"
    end
    local n = math.min(samples or Index.SHIPPED_SAMPLES, idx.pages)
    local ok, why = pcall(function()
        for k = 0, n - 1 do
            local p = n == 1 and 1 or 1 + math.floor(k * (idx.pages - 1) / (n - 1))
            local recs = idx:_page(p)
            if #recs == 0 then error("empty index page " .. p, 0) end
            local r = recs[math.floor((#recs + 1) / 2)]
            if r[2] >= idx.count then error("key number out of range", 0) end
            if idx.norm(reader:keyAt(r[2]) or "") ~= r[1] then
                error(string.format("key %d is not the one indexed", r[2]), 0)
            end
        end
    end)
    if not ok then return nil, tostring(why) end
    return true
end

-- CRC-32 of `len` bytes of an open file from `pos`; calls each_chunk(s) when given.
local function crc_range(f, pos, len, each_chunk, chunk)
    f:seek("set", pos)
    local crc, left = 0, len
    while left > 0 do
        local s = f:read(math.min(left, chunk or 1048576))
        if not s or #s == 0 then return nil end
        crc = zlib.crc32(crc, s)
        if each_chunk then each_chunk(s) end
        left = left - #s
    end
    return crc
end

--- The full check of a shipped index, for a background job: the CRC-32 of the volume's header
-- and key section and of the index body, the page counts, the directory order and
-- Index.VERIFY_SAMPLES keys. Returns true, or nil and a reason.
function Index.verifyShipped(path, volume, spec, progress)
    local Reader = require("mdict/reader")
    local idx, err = Index.openSidecar(path, spec, { format = 2 })
    if not idx then return nil, err end
    local h = idx.header
    local ok, why = pcall(function()
        local f = assert(io.open(volume, "rb"))
        local crc = crc_range(f, 0, h.source_len)
        f:close()
        if crc ~= h.source_crc32 then error("built for another version of the file", 0) end
        if progress then progress(0.3) end
        f = assert(io.open(path, "rb"))
        local total = 0
        local size = h.page_size
        crc = crc_range(f, h.pages_off, h.pages * size, function(s)
            for at = 1, #s - 1, size do
                total = total + byte(s, at) * 256 + byte(s, at + 1)
            end
        end, size * 256)
        if crc then crc = zlib.crc32(crc, f:read(h.dir_len) or "") end
        f:close()
        if crc ~= h.body_crc32 then error("the index file is damaged", 0) end
        if total ~= idx.count then error("the index holds " .. total .. " keys, its header says " .. idx.count, 0) end
        for p = 2, idx.pages do
            if idx.dir[p] < idx.dir[p - 1] then error("index pages out of order", 0) end
        end
        if progress then progress(0.6) end
        local reader = assert(Reader.open(volume))
        local sok, swhy = Index.checkShipped(idx, reader, Index.VERIFY_SAMPLES)
        reader:close()
        if not sok then error(swhy, 0) end
    end)
    idx:close()
    if progress then progress(1) end
    if not ok then return nil, tostring(why) end
    return true
end

---------------------------------------------------------------- file-order lookup

local FileOrderIndex = {}
FileOrderIndex.__index = FileOrderIndex

--- Index over a file whose keys are already in normalised order (verified by the caller).
-- Keys are normalised only when a search looks at them: normalising is several times the
-- cost of decoding a block, and a search looks at about a dozen keys of the block it reads,
-- while lookups in dozens of dictionaries read a block or two in each.
function Index.openFileOrder(reader, spec)
    return setmetatable({ reader = reader, spec = spec, norm = Index.normalizer(spec), first = {}, last = {},
                          count = reader.num_entries, cache = {}, order = {} }, FileOrderIndex)
end

-- Normalised first and last keys of key block b.
function FileOrderIndex:_first(b)
    local v = self.first[b]
    if not v then
        v = self.norm(self.reader.kb_first[b])
        self.first[b] = v
    end
    return v
end

function FileOrderIndex:_last(b)
    local v = self.last[b]
    if not v then
        v = self.norm(self.reader.kb_last[b])
        self.last[b] = v
    end
    return v
end

-- Key block b, with its keys normalised as they are asked for (see _key).
function FileOrderIndex:_block(b)
    local blk = self.cache[b]
    if blk then return blk end
    local kb = self.reader:keyBlock(b)
    blk = { keys = kb.keys, n = kb.n, ord0 = kb.ord0, norm = {} }
    self.cache[b] = blk
    table.insert(self.order, b)
    if #self.order > 8 then self.cache[table.remove(self.order, 1)] = nil end
    return blk
end

function FileOrderIndex:_key(blk, i)
    local v = blk.norm[i]
    if not v then
        v = self.norm(blk.keys[i])
        blk.norm[i] = v
    end
    return v
end

function FileOrderIndex:_firstBlock(nkey)
    local lo, hi = 0, self.reader.num_key_blocks - 1
    local best = hi + 1
    while lo <= hi do
        local mid = rshift(lo + hi, 1)
        if self:_last(mid) >= nkey then
            best = mid
            hi = mid - 1
        else
            lo = mid + 1
        end
    end
    return best
end

function FileOrderIndex:_scan(nkey, match, limit)
    local out = {}
    local nb = self.reader.num_key_blocks
    for b = self:_firstBlock(nkey), nb - 1 do
        local first = self:_first(b)
        if first > nkey and not match(first) then break end
        local blk = self:_block(b)
        -- binary search for the first key >= nkey inside the block
        local lo, hi = 0, blk.n
        while lo < hi do
            local mid = rshift(lo + hi, 1)
            if self:_key(blk, mid) < nkey then lo = mid + 1 else hi = mid end
        end
        for i = lo, blk.n - 1 do
            local k = self:_key(blk, i)
            if match(k) then
                out[#out + 1] = { k, blk.ord0 + i }
                if limit and #out >= limit then return out end
            elseif k > nkey then
                return out
            end
        end
    end
    return out
end

function FileOrderIndex:find(nkey)
    local res = self:_scan(nkey, function(k) return k == nkey end)
    for i = 1, #res do res[i] = res[i][2] end
    return res
end

function FileOrderIndex:prefix(nprefix, limit)
    if nprefix == "" then return {} end
    local plen = #nprefix
    return self:_scan(nprefix, function(k) return sub(k, 1, plen) == nprefix end, limit)
end

function FileOrderIndex:close() end

---------------------------------------------------------------- simple in-memory index

local MemoryIndex = {}
MemoryIndex.__index = MemoryIndex

--- Hash index held in memory; used for small files and in tests. Its `inversions` say whether
-- the file was in normalised order (0: sorted), as Index.verifyOrder would.
function Index.buildMemory(reader, spec)
    local norm = Index.normalizer(spec)
    local map = {}
    local prev, inversions = nil, 0
    reader:eachKey(function(key, ord)
        local n = norm(key)
        if prev and n < prev then inversions = inversions + 1 end
        prev = n
        local e = map[n]
        if e then e[#e + 1] = ord else map[n] = { ord } end
    end)
    return setmetatable({ map = map, spec = spec, norm = norm, count = reader.num_entries,
                          inversions = inversions }, MemoryIndex)
end

function MemoryIndex:find(nkey)
    local e = self.map[nkey]
    if not e then return {} end
    local out = {}
    for i = 1, #e do out[i] = e[i] end
    return out
end

function MemoryIndex:prefix(nprefix, limit)
    local out = {}
    for k, ords in pairs(self.map) do
        if sub(k, 1, #nprefix) == nprefix then
            for _, o in ipairs(ords) do out[#out + 1] = { k, o } end
        end
    end
    table.sort(out, function(a, b) return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2]) end)
    while #out > limit do table.remove(out) end
    return out
end

function MemoryIndex:close() end

return Index
