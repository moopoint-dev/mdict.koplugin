--[[--
RIPEMD-128, used by MDict to derive the key that scrambles the key index.
]]

local bit = require("bit")
local band, bor, bxor, rshift, lshift, rol, tobit = bit.band, bit.bor, bit.bxor, bit.rshift, bit.lshift, bit.rol, bit.tobit

local R  = { 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15, 7,4,13,1,10,6,15,3,12,0,9,5,2,14,11,8,
             3,10,14,4,9,15,8,1,2,7,0,6,13,11,5,12, 1,9,11,10,0,8,12,4,13,3,7,15,14,5,6,2 }
local Rp = { 5,14,7,0,9,2,11,4,13,6,15,8,1,10,3,12, 6,11,3,7,0,13,5,10,14,15,8,12,4,9,1,2,
             15,5,1,3,7,14,6,9,11,8,12,2,10,0,4,13, 8,6,4,1,3,11,15,0,5,12,2,13,9,7,10,14 }
local S  = { 11,14,15,12,5,8,7,9,11,13,14,15,6,7,9,8, 7,6,8,13,11,9,7,15,7,12,15,9,11,7,13,12,
             11,13,6,7,14,9,13,15,14,8,13,6,5,12,7,5, 11,12,14,15,14,15,9,8,9,14,5,6,8,6,5,12 }
local Sp = { 8,9,9,11,13,15,15,5,7,7,8,11,14,14,12,6, 9,13,15,7,12,8,9,11,7,7,12,7,6,15,13,11,
             9,7,15,11,8,6,6,14,12,13,5,14,13,13,7,5, 15,5,8,11,14,14,6,14,6,9,12,9,12,5,15,8 }
local K  = { 0, 0x5A827999, 0x6ED9EBA1, tobit(0x8F1BBCDC) }
local Kp = { 0x50A28BE6, 0x5C4DD124, 0x6D703EF3, 0 }

local function F(j, x, y, z)
    if j < 16 then return bxor(x, y, z)
    elseif j < 32 then return bor(band(x, y), band(bit.bnot(x), z))
    elseif j < 48 then return bxor(bor(x, bit.bnot(y)), z)
    else return bor(band(x, z), band(y, bit.bnot(z))) end
end

local function le32(n)
    return string.char(band(n, 255), band(rshift(n, 8), 255), band(rshift(n, 16), 255), band(rshift(n, 24), 255))
end

--- Returns the 16-byte digest of `msg` as a binary string.
return function(msg)
    local h0, h1, h2, h3 = 0x67452301, tobit(0xEFCDAB89), tobit(0x98BADCFE), 0x10325476
    local ml = #msg * 8
    msg = msg .. "\128" .. string.rep("\0", (55 - #msg) % 64) .. le32(ml % 2^32) .. le32(math.floor(ml / 2^32))
    local X = {}
    for off = 1, #msg, 64 do
        for i = 0, 15 do
            local a, b, c, d = msg:byte(off + i * 4, off + i * 4 + 3)
            X[i] = bor(a, lshift(b, 8), lshift(c, 16), lshift(d, 24))
        end
        local a, b, c, d, ap, bp, cp, dp = h0, h1, h2, h3, h0, h1, h2, h3
        for j = 0, 63 do
            local q = rshift(j, 4) + 1
            local t = rol(tobit(a + F(j, b, c, d) + X[R[j + 1]] + K[q]), S[j + 1])
            a, d, c, b = d, c, b, t
            t = rol(tobit(ap + F(63 - j, bp, cp, dp) + X[Rp[j + 1]] + Kp[q]), Sp[j + 1])
            ap, dp, cp, bp = dp, cp, bp, t
        end
        local t = tobit(h1 + c + dp)
        h1 = tobit(h2 + d + ap)
        h2 = tobit(h3 + a + bp)
        h3 = tobit(h0 + b + cp)
        h0 = t
    end
    return le32(h0) .. le32(h1) .. le32(h2) .. le32(h3)
end
