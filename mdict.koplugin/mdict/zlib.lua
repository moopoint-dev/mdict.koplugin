--[[--
Minimal zlib binding: uses KOReader's declarations and library when available
(monolibtic builds), plain `libz` otherwise (tests, desktop tools).
]]

local ffi = require("ffi")

if not pcall(require, "ffi/zlib_h") then
    ffi.cdef[[
int uncompress(unsigned char *dest, unsigned long *destLen, const unsigned char *source, unsigned long sourceLen);
]]
end
-- KOReader's zlib_h leaves adler32 out, and its monolibtic library may not export it (nor crc32)
pcall(ffi.cdef, "unsigned long adler32(unsigned long adler, const unsigned char *buf, unsigned int len);")
pcall(ffi.cdef, "unsigned long crc32(unsigned long crc, const unsigned char *buf, unsigned int len);")

local libz
if ffi.loadlib then
    libz = ffi.loadlib("z", 1)
else
    local ok
    ok, libz = pcall(ffi.load, os.getenv("MDICT_LIBZ") or "z")
    if not ok then
        libz = ffi.load("libz.so.1")
    end
end

local has_adler32 = pcall(function() return libz.adler32 end)
local has_crc32 = pcall(function() return libz.crc32 end)

local M = {}

local NMAX = 5552 -- most bytes before the sums must be reduced (as in zlib)

local function lua_adler32(p, len)
    local a, b = 1, 0
    local i = 0
    while i < len do
        local n = math.min(NMAX, len - i)
        for j = i, i + n - 1 do
            a = a + p[j]
            b = b + a
        end
        a, b = a % 65521, b % 65521
        i = i + n
    end
    return b * 65536 + a
end
M._lua_adler32 = lua_adler32

--- Adler-32 of `len` bytes at pointer `p` (or of a Lua string).
function M.adler32(p, len)
    if type(p) == "string" then
        len = #p
    end
    local buf = ffi.cast("const unsigned char *", p) -- p keeps a string argument alive
    if has_adler32 then
        return tonumber(libz.adler32(1, buf, len))
    end
    return lua_adler32(buf, len)
end

local crc_table

local function lua_crc32(crc, p, len)
    local bit = require("bit")
    local band, bxor, rshift = bit.band, bit.bxor, bit.rshift
    if not crc_table then
        crc_table = ffi.new("uint32_t[256]")
        for i = 0, 255 do
            local c = i
            for _ = 1, 8 do
                if band(c, 1) ~= 0 then c = bxor(0xEDB88320, rshift(c, 1)) else c = rshift(c, 1) end
            end
            crc_table[i] = c
        end
    end
    local t = crc_table
    local c = bit.bnot(crc)
    for i = 0, len - 1 do
        c = bxor(t[band(bxor(c, p[i]), 255)], rshift(c, 8))
    end
    return bit.bnot(c) % 4294967296
end
M._lua_crc32 = function(crc, s) return lua_crc32(crc, ffi.cast("const unsigned char *", s), #s) end

--- CRC-32 (zlib's, as Python's zlib.crc32) of `len` bytes at pointer `p` (or of a Lua string),
-- continuing from `crc` (0 to start).
function M.crc32(crc, p, len)
    if type(p) == "string" then
        len = #p
    end
    local buf = ffi.cast("const unsigned char *", p) -- p keeps a string argument alive
    if has_crc32 then
        return tonumber(libz.crc32(crc, buf, len))
    end
    return lua_crc32(crc, buf, len)
end

--- Inflate a zlib stream of `clen` bytes at `src` into a new buffer of `dlen` bytes.
-- Returns the uint8_t buffer and the number of bytes written.
function M.inflate(src, clen, dlen)
    local buf = ffi.new("uint8_t[?]", math.max(dlen, 1))
    local outlen = ffi.new("unsigned long[1]", dlen)
    local rc = libz.uncompress(buf, outlen, ffi.cast("const unsigned char *", src), clen)
    if rc ~= 0 then
        error("zlib error " .. rc)
    end
    return buf, tonumber(outlen[0])
end

return M
