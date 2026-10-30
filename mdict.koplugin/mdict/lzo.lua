--[[--
LZO1X decompressor (the format used by MDict 1.2 compressed blocks), written
from the format description of lzo1x_decompress_safe. Bounds are checked on
every copy, so corrupt input raises an error instead of reading out of range.
]]

local bit = require("bit")
local ffi = require("ffi")
local band, rshift, lshift = bit.band, bit.rshift, bit.lshift

local M = {}

--- Decompress `clen` bytes at `src` into a buffer of exactly `dlen` bytes.
-- Returns the uint8_t buffer and the number of bytes produced.
function M.decompress(src, clen, dlen)
    local ip = ffi.cast("const uint8_t *", src)
    local op = ffi.new("uint8_t[?]", math.max(dlen, 1))
    local i, o = 0, 0 -- input / output positions
    local t, m

    local function need_in(n)
        if i + n > clen then error("lzo: input overrun") end
    end
    local function need_out(n)
        if o + n > dlen then error("lzo: output overrun") end
    end
    local function literals(n)
        need_in(n); need_out(n)
        ffi.copy(op + o, ip + i, n)
        i, o = i + n, o + n
    end
    local function copy_match(pos, n)
        if pos < 0 then error("lzo: lookbehind overrun") end
        need_out(n)
        for k = 0, n - 1 do
            op[o + k] = op[pos + k] -- byte-wise: matches may overlap the output
        end
        o = o + n
    end
    local function long_length(base)
        local n = 0
        need_in(1)
        while ip[i] == 0 do
            n = n + 255
            i = i + 1
            need_in(1)
        end
        n = n + base + ip[i]
        i = i + 1
        return n
    end

    -- state: "start" decides between a literal run and a match on the next opcode
    local state = "loop"
    need_in(1)
    if ip[0] > 17 then
        t = ip[0] - 17
        i = 1
        if t < 4 then
            state = "match_next"
        else
            literals(t)
            state = "first_literal_run"
        end
    end

    while true do
        if state == "loop" then
            need_in(1)
            t = ip[i]; i = i + 1
            if t >= 16 then
                state = "match"
            else
                if t == 0 then t = long_length(15) end
                literals(t + 3)
                state = "first_literal_run"
            end
        elseif state == "first_literal_run" then
            need_in(1)
            t = ip[i]; i = i + 1
            if t >= 16 then
                state = "match"
            else
                need_in(1)
                m = o - (1 + 0x0800) - rshift(t, 2) - lshift(ip[i], 2)
                i = i + 1
                copy_match(m, 3)
                state = "match_done"
            end
        elseif state == "match" then
            if t >= 64 then
                need_in(1)
                m = o - 1 - band(rshift(t, 2), 7) - lshift(ip[i], 3)
                i = i + 1
                copy_match(m, rshift(t, 5) + 1)
            elseif t >= 32 then
                t = band(t, 31)
                if t == 0 then t = long_length(31) end
                need_in(2)
                m = o - 1 - rshift(ip[i], 2) - lshift(ip[i + 1], 6)
                i = i + 2
                copy_match(m, t + 2)
            elseif t >= 16 then
                m = o - lshift(band(t, 8), 11)
                t = band(t, 7)
                if t == 0 then t = long_length(7) end
                need_in(2)
                m = m - rshift(ip[i], 2) - lshift(ip[i + 1], 6)
                i = i + 2
                if m == o then
                    break -- end of stream marker
                end
                copy_match(m - 0x4000, t + 2)
            else
                need_in(1)
                m = o - 1 - rshift(t, 2) - lshift(ip[i], 2)
                i = i + 1
                copy_match(m, 2)
            end
            state = "match_done"
        elseif state == "match_done" then
            t = band(ip[i - 2], 3)
            if t == 0 then
                state = "loop"
            else
                state = "match_next"
            end
        else -- "match_next": 1 to 3 trailing literals, then the next match
            literals(t)
            need_in(1)
            t = ip[i]; i = i + 1
            state = "match"
        end
    end
    return op, o
end

return M
