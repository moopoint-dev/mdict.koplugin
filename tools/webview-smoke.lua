#!/usr/bin/env luajit
--[[
Renders sample entries end to end through renderers/webview.lua and the
Chromium bridge, serving resources from an extracted res/ directory via the
"need" protocol. Writes raw RGBA pages for inspection.

    luajit tools/webview-smoke.lua <res dir> <out dir> entry.html...
]]
local here = arg[0]:match("^(.*)/tools/[^/]+$") or "."
package.path = here .. "/mdict.koplugin/?.lua;" .. package.path
local ffi = require("ffi")
local Html = require("mdict/html")
local WebRenderer = require("renderers/webview")
local ChromiumBridge = require("renderers/chromium_bridge")

local res, out = arg[1], arg[2]
os.execute("mkdir -p '" .. out .. "/cache'")
local bridge = assert(ChromiumBridge.new({ script = here .. "/tools/chromium-bridge/bridge.js",
    node_path = os.getenv("NODE_PATH") or "/opt/node-tools/node_modules", dpr = 2, tmpdir = out }))
local needs = {}
local wr = WebRenderer.new({
    bridge = bridge,
    resolve = function(dict_id, path)
        needs[#needs + 1] = path
        local src = res .. "/" .. path
        local f = io.open(src, "rb")
        if not f then return nil end
        local data = f:read("*a"); f:close()
        local dst = out .. "/cache/" .. path
        os.execute("mkdir -p '" .. dst:match("^(.*)/") .. "'")
        local o = assert(io.open(dst, "wb")); o:write(data); o:close()
        return dst
    end,
    logger = { warn = function(_, ...) print("WARN", ...) end },
})
local W, H = 1150, 1100
for i = 3, #arg do
    local f = assert(io.open(arg[i], "rb")); local html = f:read("*a"); f:close()
    local hrefs
    html, hrefs = Html.extractStylesheets(html)
    for k, h in ipairs(hrefs) do hrefs[k] = Html.resourcePath(h, "") end
    html = Html.rewriteLinks(html)
    local t0 = os.time()
    local slot, err = wr:document({ dict_id = "sample", cache_root = out .. "/cache", stylesheets = hrefs,
        fonts = { ["sans-cjk"] = { names = { "IPAGothic" } }, ["serif-cjk"] = { names = { "IPAGothic" } } } }, W, H)
    assert(slot, err)
    local r = assert(wr:setEntry(slot, { html = html }))
    print(arg[i], "pages", r.pages, "vertical", r.vertical, "slot", slot.id)
    local buf = ffi.new("uint8_t[?]", W * H * 4)
    for p = 0, math.min(r.pages, 2) - 1 do
        assert(wr:renderPage(slot, p, buf))
        local name = string.format("%s/%s-p%d.rgba", out, arg[i]:match("([^/]+)%.html$"), p)
        local o = io.open(name, "wb"); o:write(ffi.string(buf, W * H * 4)); o:close()
    end
    local links = assert(wr:links(slot))
    print("links on page", slot.page, #links, os.time() - t0, "s")
end
print("resources requested:", #needs, table.concat(needs, " "):sub(1, 200))
wr:close()
bridge:free()
