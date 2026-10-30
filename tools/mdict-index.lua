#!/usr/bin/env luajit
--[[
Build (or reuse) the sidecar index for one dictionary and run lookups, outside KOReader.

    luajit tools/mdict-index.lua <file.mdx> <out.idx> [word ...]
]]

local here = arg[0]:match("^(.*)/tools/[^/]+$") or "."
package.path = here .. "/mdict.koplugin/?.lua;" .. package.path

local ffi = require("ffi")
local Index = require("mdict/index")
local Reader = require("mdict/reader")

pcall(ffi.cdef, "typedef struct { long tv_sec; long tv_nsec; } mdict_timespec; int clock_gettime(int, mdict_timespec *);")
local ts = ffi.new("mdict_timespec")
local function now()
    ffi.C.clock_gettime(1, ts)
    return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) / 1e9
end

local d = assert(Reader.open(arg[1]))
local out = arg[2]
local spec = d.is_mdd and "res-1" or "kosort-1"
local t0 = now()
print("boundaries ordered:", Index.boundariesOrdered(d, spec), string.format("(%.1f ms)", (now() - t0) * 1000))
local idx = Index.openSidecar(out, spec, { keys = d.num_entries })
if not idx then
    t0 = now()
    local stats = Index.buildSidecar(d, out, spec, { keys = d.num_entries })
    local f = io.open(out, "rb"); local size = f:seek("end"); f:close()
    print(string.format("built %s: %d keys, %d pages, %.1f MB, sorted=%s, inversions=%d, %.1f s",
        out, stats.keys, stats.pages, size / 1048576, tostring(stats.sorted), stats.inversions, now() - t0))
    idx = assert(Index.openSidecar(out, spec))
end
local norm = Index.normalizer(spec)
for i = 3, #arg do
    t0 = now()
    local ords = idx:find(norm(arg[i]))
    local dt = now() - t0
    local keys = {}
    for _, o in ipairs(ords) do keys[#keys + 1] = d:keyAt(o) end
    local t1 = now()
    local rec = ords[1] and d:record(ords[1]) or ""
    print(string.format("%s -> %d hits [%s] index %.2f ms, first record %.2f ms (%d bytes)",
        arg[i], #ords, table.concat(keys, " | "):sub(1, 120), dt * 1000, (now() - t1) * 1000, #rec))
end
