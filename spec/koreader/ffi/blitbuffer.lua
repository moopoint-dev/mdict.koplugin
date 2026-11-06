-- Stub of KOReader's Blitbuffer with real pixel memory (RGBA for TYPE_BBRGB32)
local ffi = require("ffi")
local BB = { TYPE_BB8 = 1, TYPE_BBRGB32 = 5, COLOR_WHITE = 0xFF, COLOR_BLACK = 0, live = 0 }
local mt = {}
mt.__index = mt
function BB.new(w, h, t)
    BB.live = BB.live + 1
    return setmetatable({ w = w, h = h, type = t, stride = w * 4, data = ffi.new("uint8_t[?]", w * h * 4) }, mt)
end
function BB.gray(v) return v end
function mt:free() if self.data then BB.live = BB.live - 1 end self.data = nil end
function mt:copy()
    local o = BB.new(self.w, self.h, self.type)
    ffi.copy(o.data, self.data, self.w * self.h * 4)
    return o
end
function mt:fill() ffi.fill(self.data, self.w * self.h * 4, 255) end
function mt:getWidth() return self.w end
function mt:getHeight() return self.h end
function mt:darkenRect(x, y, w, h)
    self.darkened = (self.darkened or 0) + 1
end
function mt:paintRect() end
function mt:getType() return self.type end
-- copies pixels; into TYPE_BB8, as grey (stored in all four bytes, as KOReader weighs the channels)
function mt:blitFrom(src, dx, dy, sx, sy, w, h)
    if not (src and src.data and self.data) then return end
    dx, dy, sx, sy = dx or 0, dy or 0, sx or 0, sy or 0
    w = math.min(w or src.w, src.w - sx, self.w - dx)
    h = math.min(h or src.h, src.h - sy, self.h - dy)
    local grey = self.type == BB.TYPE_BB8 and src.type ~= BB.TYPE_BB8
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local s, d = ((sy + y) * src.w + sx + x) * 4, ((dy + y) * self.w + dx + x) * 4
            if grey then
                local v = math.floor((src.data[s] * 4898 + src.data[s + 1] * 9618 + src.data[s + 2] * 1869) / 16384)
                self.data[d], self.data[d + 1], self.data[d + 2], self.data[d + 3] = v, v, v, 255
            else
                ffi.copy(self.data + d, src.data + s, 4)
            end
        end
    end
end
-- share of non-white pixels
function mt:inkRatio()
    local n, ink = self.w * self.h, 0
    for i = 0, n - 1, 7 do
        if self.data[i * 4] < 200 then ink = ink + 1 end
    end
    return ink / (n / 7)
end
function mt:digest()
    local h = 0
    for i = 0, self.w * self.h * 4 - 1, 97 do h = (h * 31 + self.data[i]) % 2147483647 end
    return h
end
return BB
