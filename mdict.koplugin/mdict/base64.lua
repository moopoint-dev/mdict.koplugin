--[[--
Base64, as the DevTools protocol carries binary data (response bodies, screenshots).
]]

local ffi = require("ffi")

local M = {}

local CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local ENC = ffi.new("uint8_t[64]", CHARS)
local DEC = ffi.new("int16_t[256]")
for i = 0, 255 do DEC[i] = -1 end
for i = 1, 64 do DEC[CHARS:byte(i)] = i - 1 end

local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift

--- Encodes a string, or n bytes at a pointer.
function M.encode(s, n)
    n = n or #s
    local src = ffi.cast("const uint8_t *", s)
    local out_len = math.ceil(n / 3) * 4
    local out = ffi.new("uint8_t[?]", out_len + 1)
    local full = n - n % 3
    local o = 0
    for i = 0, full - 1, 3 do
        local v = bor(lshift(src[i], 16), lshift(src[i + 1], 8), src[i + 2])
        out[o] = ENC[rshift(v, 18)]
        out[o + 1] = ENC[band(rshift(v, 12), 63)]
        out[o + 2] = ENC[band(rshift(v, 6), 63)]
        out[o + 3] = ENC[band(v, 63)]
        o = o + 4
    end
    local rest = n - full
    if rest > 0 then
        local v = lshift(src[full], 16)
        if rest == 2 then v = bor(v, lshift(src[full + 1], 8)) end
        out[o] = ENC[rshift(v, 18)]
        out[o + 1] = ENC[band(rshift(v, 12), 63)]
        out[o + 2] = rest == 2 and ENC[band(rshift(v, 6), 63)] or 61 -- "="
        out[o + 3] = 61
    end
    return ffi.string(out, out_len)
end

--- Decodes base64 (characters outside the alphabet, such as line ends, are skipped).
-- Returns a string; with into = true, a uint8_t buffer and its length instead.
function M.decode(s, into)
    local n = #s
    local src = ffi.cast("const uint8_t *", s)
    local out = ffi.new("uint8_t[?]", math.floor(n / 4) * 3 + 3)
    local o, acc, bits = 0, 0, 0
    for i = 0, n - 1 do
        local d = DEC[src[i]]
        if d >= 0 then
            acc = bor(lshift(band(acc, 0xFFFF), 6), d)
            bits = bits + 6
            if bits >= 8 then
                bits = bits - 8
                out[o] = band(rshift(acc, bits), 255)
                o = o + 1
            end
        end
    end
    if into then return out, o end
    return ffi.string(out, o)
end

return M
