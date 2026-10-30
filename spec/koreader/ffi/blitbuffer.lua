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
function mt:blitFrom() end
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
