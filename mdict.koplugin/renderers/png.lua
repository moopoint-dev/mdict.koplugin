--[[--
A small PNG decoder for the browser's screenshots (8-bit grey, RGB or RGBA, not interlaced),
for when KOReader's own image decoders are not there (the specs, desktop tools).
]]

local ffi = require("ffi")
local zlib = require("mdict/zlib")

local M = {}

local function u32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
end

--- Draws a PNG into w*h RGBA pixels at ptr. Returns true, or nil and an error.
-- A screenshot can be a pixel or two off the page size (a CSS size times a fractional pixel
-- ratio): the page then gets what overlaps, and white for the rest.
function M.decodeInto(data, ptr, w, h)
    if data:sub(1, 8) ~= "\137PNG\r\n\26\n" then return nil, "not a PNG" end
    local pos, iw, ih, depth, ctype, interlace = 9, 0, 0, 0, 0, 0
    local idat = {}
    while pos + 8 <= #data do
        local len, typ = u32(data, pos), data:sub(pos + 4, pos + 7)
        local body = data:sub(pos + 8, pos + 7 + len)
        if typ == "IHDR" then
            iw, ih = u32(body, 1), u32(body, 5)
            depth, ctype, interlace = body:byte(9), body:byte(10), body:byte(13)
        elseif typ == "IDAT" then
            idat[#idat + 1] = body
        elseif typ == "IEND" then
            break
        end
        pos = pos + 12 + len
    end
    if math.abs(iw - w) > 2 or math.abs(ih - h) > 2 then
        return nil, string.format("PNG is %dx%d, not %dx%d", iw, ih, w, h)
    end
    local bpp = ({ [0] = 1, [2] = 3, [4] = 2, [6] = 4 })[ctype]
    if depth ~= 8 or not bpp or interlace ~= 0 then return nil, "unsupported PNG" end
    local z = table.concat(idat)
    local stride = iw * bpp
    local raw, n = zlib.inflate(z, #z, (stride + 1) * ih)
    if n ~= (stride + 1) * ih then return nil, "short PNG data" end
    local out = ffi.cast("uint8_t *", ptr)
    local cw = math.min(w, iw)
    if iw ~= w or ih ~= h then ffi.fill(out, w * h * 4, 255) end
    local prev = ffi.new("uint8_t[?]", stride)
    local cur = ffi.new("uint8_t[?]", stride)
    for y = 0, math.min(h, ih) - 1 do
        local line = raw + y * (stride + 1)
        local f = line[0]
        line = line + 1
        for x = 0, stride - 1 do
            local a = x >= bpp and cur[x - bpp] or 0
            local b = prev[x]
            local v = line[x]
            if f == 1 then
                v = v + a
            elseif f == 2 then
                v = v + b
            elseif f == 3 then
                v = v + bit.rshift(a + b, 1)
            elseif f == 4 then
                local c = x >= bpp and prev[x - bpp] or 0
                local p = a + b - c
                local pa, pb, pc = math.abs(p - a), math.abs(p - b), math.abs(p - c)
                v = v + ((pa <= pb and pa <= pc) and a or (pb <= pc and b or c))
            end
            cur[x] = bit.band(v, 255)
        end
        local o = out + y * w * 4
        if bpp >= 3 then
            for x = 0, cw - 1 do
                local s = x * bpp
                o[x * 4], o[x * 4 + 1], o[x * 4 + 2] = cur[s], cur[s + 1], cur[s + 2]
                o[x * 4 + 3] = bpp == 4 and cur[s + 3] or 255
            end
        else
            for x = 0, cw - 1 do
                local g = cur[x * bpp]
                o[x * 4], o[x * 4 + 1], o[x * 4 + 2] = g, g, g
                o[x * 4 + 3] = bpp == 2 and cur[x * bpp + 1] or 255
            end
        end
        prev, cur = cur, prev
    end
    return true
end

return M
