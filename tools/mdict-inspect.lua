#!/usr/bin/env luajit
--[[
Inspect an MDict file with the plugin's reader, outside KOReader.

    luajit tools/mdict-inspect.lua <file.mdx|file.mdd> [--sample w1,w2] [--out dir]

Prints header facts, timings, block counts and whether record offsets grow with
key order. With --sample, writes the named entries (after @@@LINK redirects)
and every resource they reference from the companion .mdd files into --out,
for use as rendering fixtures.
]]

local here = arg[0]:match("^(.*)/tools/[^/]+$") or "."
package.path = here .. "/mdict.koplugin/?.lua;" .. package.path

local Reader = require("mdict/reader")
-- the plugin's clock (see tools/mdict-lookup.lua)
local now = require("mdict/clock")

local path = arg[1]
local opts = {}
local i = 2
while arg[i] do
    if arg[i] == "--sample" then opts.sample = arg[i + 1]; i = i + 2
    elseif arg[i] == "--out" then opts.out = arg[i + 1]; i = i + 2
    else i = i + 1 end
end

local t0 = now()
local d, err = Reader.open(path)
if not d then
    print("ERROR", path, err)
    os.exit(1)
end
local t_open = now() - t0
print(string.format("%s\n  version %s, %s, %s entries, %d key blocks, %d record blocks, %.0f MB records, open %.1f ms",
    path, d.version, d.encoding, d.num_entries, d.num_key_blocks, d.num_record_blocks,
    d.record_data_size / 1048576, t_open * 1000))
print("  title: " .. tostring(d.title))
for _, k in ipairs({ "Encrypted", "Compact", "Compat", "KeyCaseSensitive", "StripKey", "Stripkey", "Format",
                     "KOReaderKeyOrder", "Left2Right" }) do
    if d.header[k] then io.write(string.format("  %s=%s", k, d.header[k])) end
end
print()
if d.header.StyleSheet and d.header.StyleSheet ~= "" then
    print("  StyleSheet header: " .. #d.header.StyleSheet .. " bytes")
end

-- full key scan: timing, offset monotonicity
t0 = now()
local n, nonmono, prev_off = 0, 0, -1
local wanted = {}
if opts.sample then
    for w in opts.sample:gmatch("[^,]+") do wanted[w] = {} end
end
d:eachKey(function(k, ord, off)
    n = n + 1
    if off < prev_off then nonmono = nonmono + 1 end
    prev_off = off
    if wanted[k] then table.insert(wanted[k], ord) end
end)
print(string.format("  key scan: %d keys in %.0f ms; record offsets decreasing %d times", n, (now() - t0) * 1000, nonmono))

-- timed random record reads
t0 = now()
local reads = 0
for _ = 1, 200 do
    local ord = math.random(0, d.num_entries - 1)
    local r = d:record(ord)
    if r then reads = reads + 1 end
end
print(string.format("  200 random records: %.2f ms each", (now() - t0) * 1000 / 200))

if not opts.sample then
    d:close()
    return
end

---------------------------------------------------------------- samples
local out = assert(opts.out, "--out is required with --sample")
os.execute("mkdir -p '" .. out .. "/res'")

local mdds = {}
local base = path:gsub("%.mdx$", "")
for _, suffix in ipairs({ ".mdd", ".1.mdd", ".2.mdd", ".3.mdd" }) do
    local m = Reader.open(base .. suffix)
    if m then
        local map = {}
        m:eachKey(function(k, ord) map[k:lower():gsub("/", "\\")] = map[k:lower():gsub("/", "\\")] or ord end)
        table.insert(mdds, { dict = m, map = map, name = base .. suffix })
        print(string.format("  resources: %s (%d files)", base .. suffix, m.num_entries))
    end
end

local function resource(p)
    p = p:gsub("^file://", ""):gsub("[?#].*$", ""):gsub("/", "\\")
    if p:sub(1, 1) ~= "\\" then p = "\\" .. p end
    local key = p:lower()
    for _, m in ipairs(mdds) do
        local ord = m.map[key]
        if ord then return m.dict:record(ord), p end
    end
end

local written = {}
local function save_resource(ref)
    if ref:find("^%a[%w+.-]*:") and not ref:find("^file:") then return end -- http:, data:, entry:, sound:
    local data, p = resource(ref)
    if not data then
        print("    missing resource: " .. ref)
        return
    end
    local rel = p:gsub("^\\", ""):gsub("\\", "/")
    if written[rel] then return written[rel] end
    local dir = rel:match("^(.*)/[^/]+$")
    if dir then os.execute("mkdir -p '" .. out .. "/res/" .. dir .. "'") end
    local f = assert(io.open(out .. "/res/" .. rel, "wb"))
    f:write(data)
    f:close()
    written[rel] = data
    return data
end

local function scan_css(css)
    for ref in css:gmatch("url%(%s*['\"]?([^'\")]+)['\"]?%s*%)") do save_resource(ref) end
    for ref in css:gmatch("@import%s+['\"]([^'\"]+)['\"]") do
        local sub = save_resource(ref)
        if sub then scan_css(sub) end
    end
end

for w, ords in pairs(wanted) do
    for j, ord in ipairs(ords) do
        local rec = d:record(ord)
        local hops = 0
        while rec:find("^@@@LINK=") and hops < 4 do
            local target = rec:match("^@@@LINK=([^\r\n]*)")
            local found
            d:eachKey(function(k, o)
                if k == target then found = o; return true end
            end)
            if not found then break end
            rec = d:record(found)
            hops = hops + 1
        end
        local fname = string.format("%s/%s%s.html", out, w:gsub("[/\\%s]", "_"), j > 1 and ("-" .. j) or "")
        local f = assert(io.open(fname, "wb"))
        f:write(rec)
        f:close()
        print(string.format("    %s -> %s (%d bytes, %d redirects)", w, fname, #rec, hops))
        for tag in rec:gmatch("<[^>]+>") do
            local href = tag:match("^<link[^>]-href%s*=%s*[\"']([^\"']+)") or tag:match("^<script[^>]-src%s*=%s*[\"']([^\"']+)")
                or tag:match("^<img[^>]-src%s*=%s*[\"']([^\"']+)")
            if href then
                local data = save_resource(href)
                if data and href:lower():find("%.css") then scan_css(data) end
            end
        end
        for ref in rec:gmatch("url%(%s*['\"]?([^'\")]+)['\"]?%s*%)") do save_resource(ref) end
    end
end
d:close()
