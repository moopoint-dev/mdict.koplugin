--[[--
kosort-1: the key normalisation and order used by the plugin's indexes.

    kosort1(key) =
      1. NFKC, using the Unicode tables pinned in mdict/kosort1_tables.lua
         (this also folds full-width and half-width forms)
      2. per code point: full lowercase mapping (no locale rules)
      3. katakana to hiragana (U+30A1..U+30F6 -> U+3041..U+3096, U+30FD/E -> U+309D/E)
      4. drop separators, controls, format characters and punctuation
         (general categories Z*, Cc, Cf, P*)
      5. encode as UTF-8
    Keys compare by their normalised bytes (memcmp order); equal keys are allowed.

tools/kosort.py is the reference implementation for exporters, built from the
same tables; spec/data/kosort-1.tsv holds shared test vectors.
]]

local bit = require("bit")
local T = require("mdict/kosort1_tables")

local band, bor, rshift = bit.band, bit.bor, bit.rshift
local byte, char, concat = string.byte, string.char, table.concat

local M = {
    spec = T.spec,
    unicode = T.unicode,
}

local DECOMP, CCC, COMP, LOWER = T.decomp, T.ccc, T.comp, T.lower
local DROP, CHANGES = {}, {}
for _, r in ipairs(T.drop) do
    for c = r[1], r[2] do DROP[c] = true end
end
for _, r in ipairs(T.changes) do
    for c = r[1], r[2] do CHANGES[c] = true end
end

-- ASCII fast path: a pattern matching every ASCII code point that kosort drops
local ascii_class = {}
for c = 0, 127 do
    if DROP[c] then
        ascii_class[#ascii_class + 1] = c == 0 and "%z" or ("%" .. char(c))
    end
end
local ASCII_DROP = "[" .. concat(ascii_class) .. "]"

local SBASE, LBASE, VBASE, TBASE = 0xAC00, 0x1100, 0x1161, 0x11A7
local LCOUNT, VCOUNT, TCOUNT = 19, 21, 28
local NCOUNT = VCOUNT * TCOUNT
local SCOUNT = LCOUNT * NCOUNT

local function decode(s)
    local cps, n, i, len = {}, 0, 1, #s
    while i <= len do
        local b = byte(s, i)
        local c, extra
        if b < 0x80 then c, extra = b, 0
        elseif b >= 0xF0 and b < 0xF8 then c, extra = band(b, 0x07), 3
        elseif b >= 0xE0 then c, extra = band(b, 0x0F), 2
        elseif b >= 0xC2 then c, extra = band(b, 0x1F), 1
        else c, extra = 0xFFFD, 0 end
        for k = 1, extra do
            local b2 = byte(s, i + k)
            if not b2 or band(b2, 0xC0) ~= 0x80 then
                c, extra = 0xFFFD, k - 1
                break
            end
            c = c * 64 + band(b2, 0x3F)
        end
        n = n + 1
        cps[n] = c
        i = i + extra + 1
    end
    return cps, n
end

local function compose_pair(a, b)
    if a >= LBASE and a < LBASE + LCOUNT and b >= VBASE and b < VBASE + VCOUNT then
        return SBASE + ((a - LBASE) * VCOUNT + (b - VBASE)) * TCOUNT
    end
    if a >= SBASE and a < SBASE + SCOUNT and (a - SBASE) % TCOUNT == 0 and b > TBASE and b < TBASE + TCOUNT then
        return a + (b - TBASE)
    end
    local m = COMP[a]
    return m and m[b]
end

--- NFKC of an array of code points (Unicode version of the pinned tables).
local function nfkc(cps, n)
    -- 1. full compatibility decomposition
    local d, dn = {}, 0
    for i = 1, n do
        local c = cps[i]
        if c >= SBASE and c < SBASE + SCOUNT then
            local si = c - SBASE
            dn = dn + 1; d[dn] = LBASE + math.floor(si / NCOUNT)
            dn = dn + 1; d[dn] = VBASE + math.floor((si % NCOUNT) / TCOUNT)
            local t = si % TCOUNT
            if t ~= 0 then dn = dn + 1; d[dn] = TBASE + t end
        else
            local dec = DECOMP[c]
            if dec then
                for k = 1, #dec do dn = dn + 1; d[dn] = dec[k] end
            else
                dn = dn + 1; d[dn] = c
            end
        end
    end
    -- 2. canonical ordering (stable sort of each run of non-starters)
    local i = 1
    while i <= dn do
        if (CCC[d[i]] or 0) ~= 0 then
            local j = i
            while j < dn and (CCC[d[j + 1]] or 0) ~= 0 do j = j + 1 end
            for a = i + 1, j do
                local v, cv = d[a], CCC[d[a]]
                local b = a - 1
                while b >= i and CCC[d[b]] > cv do
                    d[b + 1] = d[b]
                    b = b - 1
                end
                d[b + 1] = v
            end
            i = j + 1
        else
            i = i + 1
        end
    end
    -- 3. canonical composition
    local out, on = {}, 0
    local starter, last_class = nil, nil
    for k = 1, dn do
        local c = d[k]
        local cc = CCC[c] or 0
        local composed = false
        if starter and (last_class == nil or last_class < cc) then
            local comp = compose_pair(out[starter], c)
            if comp then
                out[starter] = comp
                composed = true
            end
        end
        if not composed then
            if cc == 0 then
                starter, last_class = on + 1, nil
            else
                last_class = cc
            end
            on = on + 1
            out[on] = c
        end
    end
    return out, on
end
M.nfkc_codepoints = nfkc

local function encode(c, buf, bn)
    if c < 0x80 then
        bn = bn + 1; buf[bn] = char(c)
    elseif c < 0x800 then
        bn = bn + 1; buf[bn] = char(bor(0xC0, rshift(c, 6)), bor(0x80, band(c, 0x3F)))
    elseif c < 0x10000 then
        bn = bn + 1; buf[bn] = char(bor(0xE0, rshift(c, 12)), bor(0x80, band(rshift(c, 6), 0x3F)), bor(0x80, band(c, 0x3F)))
    else
        bn = bn + 1; buf[bn] = char(bor(0xF0, rshift(c, 18)), bor(0x80, band(rshift(c, 12), 0x3F)),
                                    bor(0x80, band(rshift(c, 6), 0x3F)), bor(0x80, band(c, 0x3F)))
    end
    return bn
end

local function fold_append(c, buf, bn)
    if c >= 0x30A1 and c <= 0x30F6 then
        c = c - 0x60
    elseif c == 0x30FD or c == 0x30FE then
        c = c - 0x60
    end
    if DROP[c] then return bn end
    return encode(c, buf, bn)
end

--- Normalised key bytes under kosort-1.
function M.normalize(s)
    if not s:find("[\128-\255]") then
        return (s:gsub(ASCII_DROP, ""):lower())
    end
    local cps, n = decode(s)
    for i = 1, n do
        if CHANGES[cps[i]] then
            cps, n = nfkc(cps, n)
            break
        end
    end
    local buf, bn = {}, 0
    for i = 1, n do
        local c = cps[i]
        local lo = LOWER[c]
        if lo then
            for k = 1, #lo do bn = fold_append(lo[k], buf, bn) end
        else
            bn = fold_append(c, buf, bn)
        end
    end
    return concat(buf, "", 1, bn)
end

--- NFKC of a UTF-8 string (exposed for tests).
function M.nfkc(s)
    local cps, n = decode(s)
    cps, n = nfkc(cps, n)
    local buf, bn = {}, 0
    for i = 1, n do bn = encode(cps[i], buf, bn) end
    return concat(buf, "", 1, bn)
end

return M
