#!/usr/bin/env luajit
--[[
Looks words up through the plugin's Dictionary and Lookup modules, building
indexes inline, and prints the results KOReader would get.

    luajit tools/mdict-lookup.lua <cache dir> <file.mdx> word...
]]
local here = arg[0]:match("^(.*)/tools/[^/]+$") or "."
package.path = here .. "/mdict.koplugin/?.lua;" .. package.path
local ffi = require("ffi")
local Dictionary = require("mdict/dictionary")
local Lookup = require("mdict/lookup")

pcall(ffi.cdef, "typedef struct { long tv_sec; long tv_nsec; } mdl_ts; int clock_gettime(int, mdl_ts *);")
local ts = ffi.new("mdl_ts")
local function now() ffi.C.clock_gettime(1, ts); return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) / 1e9 end

local cache, path = arg[1], arg[2]
local d = Dictionary.new({ path = path, cache_dir = cache })
local t0 = now()
local ok, err = d:prepareIndexes()
print(string.format("%s: %s (%.0f ms)", d.title or path, ok and "ready" or tostring(err), (now() - t0) * 1000))
for _, s in ipairs(d:indexStates()) do print("  " .. s.kind, s.state) end
if not ok then
    t0 = now()
    ok = d:prepareIndexes()
    print(string.format("after build: %s (%.1f s)", tostring(ok), now() - t0))
end
for i = 3, #arg do
    local fuzzy = arg[i]:sub(1, 1) == "~"
    local w = fuzzy and arg[i]:sub(2) or arg[i]
    t0 = now()
    local res, problems = Lookup.run({ d }, { w }, { fuzzy = fuzzy })
    local dt = (now() - t0) * 1000
    print(string.format("%s%s -> %d results (%.1f ms)%s", fuzzy and "~" or "", w, #res, dt,
        #problems > 0 and (" problem: " .. problems[1].state) or ""))
    for k, r in ipairs(res) do
        if k > 6 then break end
        print(string.format("   [%s] key=%s anchor=%s html=%d bytes",
            r.word, r.mdict.key, tostring(r.mdict.anchor), #r.mdict.html))
    end
end
d:close()
