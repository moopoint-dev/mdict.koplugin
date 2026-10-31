--[[--
Monotonic clock in seconds, for timings in the log.
]]

local ffi = require("ffi")
-- KOReader's posix_h declares clock_gettime already; elsewhere declare it here
if not pcall(require, "ffi/posix_h") then
    pcall(ffi.cdef, "struct timespec { long tv_sec; long tv_nsec; };")
    pcall(ffi.cdef, "int clock_gettime(int clk_id, struct timespec *tp);")
end
local ts = ffi.new("struct timespec")

return function()
    ffi.C.clock_gettime(1, ts) -- CLOCK_MONOTONIC
    return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) / 1e9
end
