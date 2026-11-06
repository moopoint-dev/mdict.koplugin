--[[--
Entry HTML processing: compact stylesheet expansion, link rewriting,
stylesheet extraction, resource references and writing-mode detection.
]]

local Html = {}

--- Parses the MDict header StyleSheet attribute: groups of three lines
-- (number, opening markup, closing markup). Returns { [n] = { open, close } } or nil.
function Html.parseStyleSheet(text)
    if not text or text == "" then return nil end
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do lines[#lines + 1] = line end
    local styles, found = {}, false
    local i = 1
    while i <= #lines do
        local n = tonumber(lines[i])
        if n then
            styles[n] = { lines[i + 1] or "", lines[i + 2] or "" }
            found = true
            i = i + 3
        else
            i = i + 1
        end
    end
    return found and styles or nil
end

--- Expands `N` markers of the compact stylesheet: each marker closes the previous style and opens style N.
function Html.applyStyleSheet(record, styles)
    if not styles or not record:find("`%d+`") then return record end
    local out, last_close = {}, ""
    local pos = 1
    for s, n, e in record:gmatch("()`(%d+)`()") do
        out[#out + 1] = record:sub(pos, s - 1)
        out[#out + 1] = last_close
        local st = styles[tonumber(n)]
        if st then
            out[#out + 1] = st[1]
            last_close = st[2]
        else
            last_close = ""
        end
        pos = e
    end
    out[#out + 1] = record:sub(pos)
    out[#out + 1] = last_close
    return table.concat(out)
end

local function attr(tag, name)
    -- attribute names are case-insensitive; values keep their case
    local lt = tag:lower()
    local pre = "[%s\"'/]" .. name:lower() .. "%s*=%s*"
    local s, e = lt:match(pre .. '"()[^"]*()"')
    if not s then s, e = lt:match(pre .. "'()[^']*()'") end
    if not s then s, e = lt:match(pre .. "()[^%s>\"']+()") end
    if s then return tag:sub(s, e - 1) end
end
Html.attr = attr

--- Like html:gsub(pattern, fn), for a pattern that matches only where the lowercase text
-- `word` begins `back` bytes after the match. A pattern that may start anywhere costs a
-- match attempt at every byte, which adds up in entries of a few hundred KB.
local function gsub_at(html, word, back, pattern, fn)
    local lower = html:lower()
    local i = lower:find(word, back + 1, true)
    if not i then return html end
    local out, last = {}, 1
    pattern = "^" .. pattern
    while i do
        local s = i - back
        local caps = { html:find(pattern, s) }
        if caps[1] then
            local e = caps[2]
            local repl = fn(unpack(caps, 3))
            if repl then
                out[#out + 1] = html:sub(last, s - 1)
                out[#out + 1] = repl
                last = e + 1
            end
            i = lower:find(word, e + 1 + back, true)
        else
            i = lower:find(word, i + 1, true)
        end
    end
    if last == 1 then return html end
    out[#out + 1] = html:sub(last)
    return table.concat(out)
end
Html._gsub_at = gsub_at

--- Removes <link rel="stylesheet"> tags. Returns the HTML and the unique hrefs in order.
function Html.extractStylesheets(html)
    local hrefs, seen = {}, {}
    html = gsub_at(html, "<link", 0, "(<[Ll][Ii][Nn][Kk]%s[^>]*>)", function(tag)
        local rel = (attr(tag, "rel") or ""):lower()
        if rel:find("stylesheet", 1, true) then
            local href = attr(tag, "href")
            if href and href ~= "" and not seen[href] then
                seen[href] = true
                hrefs[#hrefs + 1] = href
            end
            return ""
        end
    end)
    return html, hrefs
end

--- The stylesheets an entry uses, in document order: { href = ... } for each
-- <link rel="stylesheet"> (each href once) and { text = ... } for each <style> element.
function Html.styleSources(html)
    local out, seen = {}, {}
    local lower = html:lower()
    local i = 1
    while true do
        local l = lower:find("<link", i, true)
        local s = lower:find("<style", i, true)
        if not (l or s) then break end
        if l and (not s or l < s) then
            local e = html:find(">", l, true) or #html
            local tag = html:sub(l, e)
            if html:sub(l + 5, l + 5):find("^[%s/>]") and (attr(tag, "rel") or ""):lower():find("stylesheet", 1, true) then
                local href = attr(tag, "href")
                if href and href ~= "" and not seen[href] then
                    seen[href] = true
                    out[#out + 1] = { href = href }
                end
            end
            i = e + 1
        else
            local e = html:find(">", s, true) or #html
            if html:sub(s + 6, s + 6):find("^[%s/>]") and html:byte(e - 1) ~= 47 then
                local close = lower:find("</style", e + 1, true)
                out[#out + 1] = { text = html:sub(e + 1, (close or #html + 1) - 1) }
                e = close and (html:find(">", close, true) or #html) or #html
            end
            i = e + 1
        end
    end
    return out
end

-- Absolute CSS lengths, in CSS px.
local CSS_PX = { px = 1, pt = 4 / 3, pc = 16, ["in"] = 96, cm = 96 / 2.54, mm = 96 / 25.4, q = 96 / 101.6, rem = 16 }

--- CSS (or a style attribute's value) with its absolute lengths turned into px and multiplied by
-- `px`. MuPDF takes a CSS px or pt for one screen pixel and a rem for 16, so on a dense screen
-- text sized that way comes out a fraction of the size of KOReader's.
function Html.scaleLengths(css, px)
    return (css:gsub("([%s:,(/])(%-?%d*%.?%d+)(%a+)()", function(pre, num, unit, after)
        local k = CSS_PX[unit:lower()]
        if not k or css:sub(after, after):find("^[%w_.-]") then return nil end
        local v = tonumber(num) * k * px
        return pre .. (string.format("%.2f", v):gsub("%.?0+$", "")) .. "px"
    end))
end

--- HTML with the absolute lengths in its style attributes scaled (see scaleLengths).
function Html.scaleStyleAttributes(html, px)
    local function scale(pre, q, value) return pre .. q .. Html.scaleLengths(value, px) .. q end
    html = gsub_at(html, "style", 1, '(%s[Ss][Tt][Yy][Ll][Ee]%s*=%s*)(")([^"]*)"', scale)
    return gsub_at(html, "style", 1, "(%s[Ss][Tt][Yy][Ll][Ee]%s*=%s*)(')([^']*)'", scale)
end

--- Rewrites MDict link schemes for KOReader:
--   entry://word#anchor -> bword://word#anchor (native nested lookup)
--   entry://#anchor     -> #anchor             (a place in the same entry)
--   sound://path        -> mdict-sound://path   (handled by the plugin)
--   file://path         -> path                 (relative resource)
function Html.rewriteLinks(html)
    local link = "(%s[Hh][Rr][Ee][Ff]%s*=%s*)([\"'])([%a][%w+.-]*):(/?/?)(#?)"
    html = gsub_at(html, "href", 1, link, function(pre, q, scheme, _, hash)
        local s = scheme:lower()
        if s == "entry" then
            return pre .. q .. (hash == "#" and "#" or "bword://")
        elseif s == "sound" then
            return pre .. q .. "mdict-sound://" .. hash
        elseif s == "file" then
            return pre .. q .. hash
        end
    end)
    html = gsub_at(html, "src", 1, "(%s[Ss][Rr][Cc]%s*=%s*)([\"'])[Ff][Ii][Ll][Ee]://", function(pre, q)
        return pre .. q
    end)
    return html
end

local function nothing() return "" end

function Html.stripScripts(html)
    html = gsub_at(html, "<script", 0, "(<[Ss][Cc][Rr][Ii][Pp][Tt][^>]*>.-</[Ss][Cc][Rr][Ii][Pp][Tt]%s*>)", nothing)
    html = gsub_at(html, "<script", 0, "(<[Ss][Cc][Rr][Ii][Pp][Tt][^>]*/>)", nothing)
    return html
end

local function is_local_ref(ref)
    if not ref or ref == "" or ref:sub(1, 1) == "#" then return false end
    local scheme = ref:match("^([%a][%w+.-]*):")
    return not scheme or scheme:lower() == "file"
end
Html.isLocalRef = is_local_ref

--- Local resources referenced by an entry: src= of images/scripts/media, url() in style attributes.
function Html.resourceRefs(html)
    local refs, seen = {}, {}
    local function add(r)
        if is_local_ref(r) and not seen[r] then
            seen[r] = true
            refs[#refs + 1] = r
        end
    end
    for tag in html:gmatch("<%a[^>]*>") do
        add(attr(tag, "src"))
        local style = attr(tag, "style")
        if style then
            for u in style:gmatch("url%(%s*['\"]?([^'\")]+)['\"]?%s*%)") do add(u) end
        end
    end
    return refs
end

--- url() and @import references in a stylesheet.
function Html.cssRefs(css)
    local refs, seen = {}, {}
    for u in css:gmatch("url%(%s*['\"]?([^'\")]+)['\"]?%s*%)") do
        if is_local_ref(u) and not seen[u] then seen[u] = true; refs[#refs + 1] = u end
    end
    for u in css:gmatch("@import%s+['\"]([^'\"]+)['\"]") do
        if is_local_ref(u) and not seen[u] then seen[u] = true; refs[#refs + 1] = u end
    end
    return refs
end

--- Resource path as the WebView requests it (relative to the dictionary root), from a reference.
function Html.resourcePath(ref, base_dir)
    local p = ref:gsub("^[Ff][Ii][Ll][Ee]://", ""):gsub("[?#].*$", ""):gsub("\\", "/")
    p = p:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    if p:sub(1, 1) ~= "/" and base_dir and base_dir ~= "" then
        p = base_dir .. "/" .. p
    end
    local parts = {}
    for seg in p:gmatch("[^/]+") do
        if seg == ".." then
            table.remove(parts)
        elseif seg ~= "." then
            parts[#parts + 1] = seg
        end
    end
    return table.concat(parts, "/")
end

--- A resource path that is already decoded (as the WebView requests it), tidied:
-- "/" separators, no leading slash or "." segments. nil when it leaves the root.
function Html.cleanPath(path)
    local parts = {}
    for seg in path:gsub("\\", "/"):gmatch("[^/]+") do
        if seg == ".." then return nil end
        if seg ~= "." then parts[#parts + 1] = seg end
    end
    return table.concat(parts, "/")
end

--- MDD key for a resource path ("img/a.png" -> "\img\a.png").
function Html.mddKey(path)
    return "\\" .. path:gsub("/", "\\")
end

--- True if CSS or inline styles set a vertical writing mode.
function Html.looksVertical(text)
    if not text then return false end
    local t = text:lower()
    return t:find("writing%-mode%s*:%s*vertical") ~= nil
        or t:find("writing%-mode%s*:%s*tb") ~= nil
        or t:find("%-webkit%-writing%-mode%s*:%s*vertical") ~= nil
        or t:find("%-epub%-writing%-mode%s*:%s*vertical") ~= nil
end

--- Decodes %XX escapes in a link target ("nucleic%20acid" -> "nucleic acid").
-- "%23" stays encoded: a "#" would start the anchor.
function Html.decodeLinkTarget(target)
    return (target:gsub("%%(%x%x)", function(h)
        if h == "23" then return nil end
        return string.char(tonumber(h, 16))
    end))
end

--- Splits "word#anchor".
function Html.splitAnchor(target)
    local w, a = target:match("^(.-)#(.*)$")
    if w then return w, a end
    return target, nil
end

return Html
