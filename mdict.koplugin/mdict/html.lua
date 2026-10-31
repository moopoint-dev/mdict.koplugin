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

--- Rewrites MDict link schemes for KOReader:
--   entry://word#anchor -> bword://word#anchor (native nested lookup)
--   sound://path        -> mdict-sound://path   (handled by the plugin)
--   file://path         -> path                 (relative resource)
function Html.rewriteLinks(html)
    html = gsub_at(html, "href", 1, "(%s[Hh][Rr][Ee][Ff]%s*=%s*)([\"'])([%a][%w+.-]*):(/?/?)", function(pre, q, scheme)
        local s = scheme:lower()
        if s == "entry" then
            return pre .. q .. "bword://"
        elseif s == "sound" then
            return pre .. q .. "mdict-sound://"
        elseif s == "file" then
            return pre .. q
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
