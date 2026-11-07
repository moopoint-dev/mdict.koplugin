#!/usr/bin/env luajit
--[[
Prepares a pager document and an entry the way the plugin does, for the
Chromium test harness. Prints JSON: { doc, entry, stylesheets }.

    luajit tools/pager-test/prepare.lua <entry.html> [--font kind=LocalName] [--css file]
        [--user-font file:scope] [--res dir]   (scope: all, latin or cjk)
]]
local here = arg[0]:match("^(.*)/tools/pager%-test/[^/]+$") or "."
package.path = here .. "/mdict.koplugin/?.lua;" .. package.path

local Html = require("mdict/html")
local Document = require("renderers/document")

local entry_path
local fonts, user_css, user_font, res = {}, nil, nil, nil
local i = 1
while i <= #arg do
    if arg[i] == "--font" then
        local kind, name = arg[i + 1]:match("^([^=]+)=(.+)$")
        fonts[kind] = fonts[kind] or { names = {} }
        if name:find("/") then fonts[kind].file = name else table.insert(fonts[kind].names, name) end
        i = i + 2
    elseif arg[i] == "--user-font" then
        local file, scope = arg[i + 1]:match("^(.-):(%a+)$")
        user_font = { file = file or arg[i + 1], scope = scope or "all" }
        i = i + 2
    elseif arg[i] == "--res" then
        res = arg[i + 1]
        i = i + 2
    elseif arg[i] == "--css" then
        local f = assert(io.open(arg[i + 1], "rb")); user_css = f:read("*a"); f:close()
        i = i + 2
    else
        entry_path = arg[i]
        i = i + 1
    end
end

local f = assert(io.open(entry_path, "rb"))
local html = f:read("*a")
f:close()
local stylesheets
html, stylesheets = Html.extractStylesheets(html)
for k, href in ipairs(stylesheets) do stylesheets[k] = Html.resourcePath(href, "") end
html = Html.rewriteLinks(html)
local families, round_sheets = nil, {}
if res then
    for _, href in ipairs(stylesheets) do
        local cf = io.open(res .. "/" .. href, "rb")
        if cf then
            local css = cf:read("*a")
            cf:close()
            if user_font then families = Document.cssFamilies(css, families) end
            if Document.usesRound(css) then round_sheets[href] = true end
        end
    end
end
local doc, _, files = Document.build({
    stylesheets = stylesheets, round_sheets = round_sheets, fonts = fonts, user_css = user_css,
    user_font = user_font, css_families = families, plugin_dir = here .. "/mdict.koplugin",
})

local function json_string(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' elseif c == "\\" then return "\\\\"
        elseif c == "\n" then return "\\n" elseif c == "\t" then return "\\t" end
        return string.format("\\u%04x", c:byte())
    end) .. '"'
end
local fl = {}
for token, path in pairs(files) do fl[#fl + 1] = json_string(token) .. ":" .. json_string(path) end
local ss = {}
for _, s in ipairs(stylesheets) do ss[#ss + 1] = json_string(s) end
io.write("{\"doc\":", json_string(doc), ",\"entry\":", json_string(html),
    ",\"stylesheets\":[", table.concat(ss, ","), "],\"files\":{", table.concat(fl, ","), "}}")
