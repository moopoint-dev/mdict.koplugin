--[[--
Turns MDict lookups into KOReader dictionary results.

A result looks like sdcv's ({ dict, word, definition }) plus:
  is_html = true
  dictionary_resource_directory = the dictionary's extracted-resource cache (for MuPDF)
  mdict = { id, html, anchor, key }: the entry with its scripts, for the WebView renderer
`definition` is the same entry without scripts, which MuPDF can render as a fallback.
These two, and a `word` taken from the entry's markup, are made when first read.
]]

local Html = require("mdict/html")

local Lookup = {}

local HEAD_TOKENS = { "headword", "hwd", "hw", "見出仮名", "見出語", "見出し", "見出", "title" }
local VOID = { br = true, img = true, hr = true, input = true, meta = true, link = true, wbr = true, source = true }

local function strip_tags(s)
    s = s:gsub("<[Ss][Cc][Rr][Ii][Pp][Tt].-</[Ss][Cc][Rr][Ii][Pp][Tt]%s*>", "")
    s = s:gsub("<[Ss][Tt][Yy][Ll][Ee].-</[Ss][Tt][Yy][Ll][Ee]%s*>", "")
    s = s:gsub("<[^>]*>", "")
    s = s:gsub("&nbsp;", " "):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&amp;", "&")
    return (s:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

-- Text of the element starting at `pos` (an opening tag), up to its matching close.
local function element_text(html, pos)
    local depth, i, n = 0, pos, #html
    local stop = math.min(n, pos + 4000)
    while i <= stop do
        local s, e, close, name, selfclose = html:find("<(/?)([%w:-]+)[^>]-(/?)>", i)
        if not s or s > stop then break end
        local void = VOID[name:lower()]
        if close == "/" then
            depth = depth - 1
            if depth <= 0 then return strip_tags(html:sub(pos, e)) end
        elseif selfclose ~= "/" and not void then
            depth = depth + 1
        end
        i = e + 1
    end
    return strip_tags(html:sub(pos, stop))
end

--- A readable headword for an entry, from markup that names it (class or data-*-tag).
-- The earliest token in HEAD_TOKENS wins, then the first element that has it.
function Lookup.headwordOf(html)
    local best, best_rank = nil, #HEAD_TOKENS + 1
    local pos = 1
    while best_rank > 1 do
        local s, e = html:find("<%a[^>]*>", pos)
        if not s then break end
        local rank = best_rank
        for value in html:sub(s, e):gmatch('[%w_-]+%s*=%s*"([^"]*)"') do
            for t in value:gmatch("[^%s]+") do
                for i = 1, rank - 1 do
                    local token = HEAD_TOKENS[i]
                    if t == token or (#token > 3 and t:find(token, 1, true)) then
                        rank = i
                        break
                    end
                end
            end
        end
        if rank < best_rank then
            local text = element_text(html, s)
            if text ~= "" then
                if #text > 60 then text = text:sub(1, 60):gsub("[\128-\191]*$", ""):gsub("[\192-\255]$", "") end
                best, best_rank = text, rank
            end
        end
        pos = e + 1
        if pos > 20000 then break end
    end
    return best
end

--- True for keys that are internal identifiers rather than words (e.g. "EXPORT:83:49022",
-- or link targets named by a hash such as "LINKe578507222d7199d1963...").
function Lookup.isInternalKey(key)
    return key:find("^[%u%d_]+:[%w_]+:") ~= nil or key:find("^%d+$") ~= nil
        or (key:find("%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x") ~= nil and not key:find("%s"))
end

-- A popup shows one result at a time, and a lookup can return dozens of large entries
-- (40 for "run" in ten dictionaries), so a result's HTML is prepared when it is first
-- read: `definition`, `mdict.html`, and a `word` that has to be taken from the entry.
local function lazy(t, fields)
    return setmetatable(t, { __index = function(self, k)
        local make = fields[k]
        if make then
            local v = make()
            rawset(self, k, v)
            return v
        end
    end })
end

local function is_space(b) return b == 32 or b == 10 or b == 13 or b == 9 or b == 12 or b == 0 end

-- End of the element "<name ...>...</name>" that starts at i, or nil.
local function close_of(r, i, name)
    local s = i
    while true do
        s = r:find("</", s + 1, true)
        if not s then return nil end
        if r:sub(s + 2, s + 1 + #name):lower() == name then return r:find(">", s, true) end
    end
end

-- Top-level items that only separate entries.
local SEPARATOR = { hr = true, br = true, link = true, meta = true, wbr = true }

--- Splits a record into its entries: the items at the top level of its markup, each with
-- the scripts and styles right after it. Rules, line breaks, stylesheet links, comments and
-- spaces are not entries. Returns a list of { from, to } byte ranges.
function Lookup.entriesOf(r)
    local units = {}
    local depth, i, n = 0, 1, #r
    local open, last -- the entry being read, and the last one while only scripts follow it
    local function text(from, to)
        while from <= to and is_space(r:byte(from)) do from = from + 1 end
        while to >= from and is_space(r:byte(to)) do to = to - 1 end
        if from <= to then
            last = { from = from, to = to }
            units[#units + 1] = last
        end
    end
    while i <= n do
        local lt = r:find("<", i, true)
        if depth == 0 then text(i, (lt or n + 1) - 1) end
        if not lt then break end
        local c = r:byte(lt + 1)
        local gt = r:find(">", lt, true) or n
        if c == 33 then -- <! comment or doctype
            if r:sub(lt + 2, lt + 3) == "--" then gt = select(2, r:find("-->", lt + 4, true)) or n end
            if depth == 0 then last = nil end
        elseif c == 47 then -- </
            if depth > 0 then
                depth = depth - 1
                if depth == 0 then
                    open.to = gt
                    units[#units + 1], last, open = open, open, nil
                end
            end
        else
            local name = r:match("^%a%w*", lt + 1)
            if not name then
                gt = lt -- a "<" in text
                if depth == 0 then text(lt, lt) end
            else
                name = name:lower()
                if name == "script" or name == "style" then
                    gt = close_of(r, lt, name) or n
                    if depth == 0 and last then last.to = gt end
                elseif VOID[name] or r:byte(gt - 1) == 47 then
                    if depth == 0 then
                        if SEPARATOR[name] then
                            last = nil
                        else
                            last = { from = lt, to = gt }
                            units[#units + 1] = last
                        end
                    end
                else
                    if depth == 0 then open = { from = lt } end
                    depth = depth + 1
                end
            end
        end
        i = gt + 1
    end
    if open then
        open.to = n
        units[#units + 1] = open
    end
    return units
end

--- Some exporters store every entry for a word on one page under its plain key, and each
-- entry again under a key of its own ("spring" and "【spring】"), and a lookup finds both, so the
-- same entry would be shown twice. An entry found in several records of one dictionary's
-- results is kept only in the record with the fewest entries (the first of those), and
-- cut out of the others with the separator before it; a record left without entries is
-- dropped. The order of the results is kept.
Lookup.MIN_REPEAT = 200 -- bytes; shorter entries (headers, notes) may repeat on purpose
function Lookup.trimRepeats(entries)
    local count = #entries
    if count < 2 then return entries end
    -- Quick check: does a piece of one record's text appear in another as long? The piece
    -- starts where text starts, so it is not just markup that every entry has, and so the
    -- search stops less often on its first byte.
    local suspect = false
    for i = 1, count do
        local b = entries[i].record
        if #b >= Lookup.MIN_REPEAT then
            local last = #b
            while last > 0 and is_space(b:byte(last)) do last = last - 1 end
            local from = select(2, b:find(">[^<%s]", math.floor(#b / 2))) or select(2, b:find(">[^<%s]"))
            local probe = from and b:sub(from, math.min(from + 63, last))
            for j = 1, count do
                local a = entries[j].record
                if probe and j ~= i and #a >= #b and a:find(probe, 1, true) then suspect = true; break end
            end
        end
        if suspect then break end
    end
    if not suspect then return entries end
    local split, owner = {}, {}
    for i, e in ipairs(entries) do
        local r = e.record
        local list, n = {}, 0
        for k, u in ipairs(Lookup.entriesOf(r)) do
            local s = r:sub(u.from, u.to)
            list[k] = { from = u.from, to = u.to, s = #s >= Lookup.MIN_REPEAT and s or nil }
            if list[k].s then n = n + 1 end
        end
        split[i] = { units = list, n = n }
        for _, u in ipairs(list) do
            if u.s then
                local o = owner[u.s]
                if not o or n < split[o].n then owner[u.s] = i end
            end
        end
    end
    local out = {}
    for i, e in ipairs(entries) do
        local r, units = e.record, split[i].units
        local kept, cut = {}, false
        for _, u in ipairs(units) do
            if u.s and owner[u.s] ~= i then cut = true else kept[#kept + 1] = u end
        end
        local left = false
        for _, u in ipairs(kept) do left = left or u.s ~= nil end
        if not cut then
            out[#out + 1] = e
        elseif left then
            -- what came before the first entry, each kept entry with the separator that came
            -- before it, and what came after the last entry
            local parts, prev = { r:sub(1, units[1].from - 1) }, {}
            for k, u in ipairs(units) do prev[u] = units[k - 1] end
            for k, u in ipairs(kept) do
                if k > 1 then parts[#parts + 1] = r:sub(prev[u].to + 1, u.from - 1) end
                parts[#parts + 1] = r:sub(u.from, u.to)
            end
            parts[#parts + 1] = r:sub(units[#units].to + 1)
            local trimmed = table.concat(parts)
            local anchor = e.anchor ~= "" and e.anchor
            if not (anchor and r:find(anchor, 1, true) and not trimmed:find(anchor, 1, true)) then
                e.record = trimmed -- unless a link points into what was cut
            end
            out[#out + 1] = e
        end
    end
    return out
end

--- Runs the lookups. dicts: Dictionary objects in display order; words: candidate words.
-- opts: fuzzy, display_word (shown instead of internal keys).
-- Returns results, and a list of { dict, state } for dictionaries that could not answer.
function Lookup.run(dicts, words, opts)
    opts = opts or {}
    local results, problems = {}, {}
    for _, d in ipairs(dicts) do
        local seen, found = {}, {}
        local failed
        for _, w in ipairs(words) do
            local entries, err = d:lookup(w, { fuzzy = opts.fuzzy, seen = seen })
            if not entries then
                failed = err
                break
            end
            for _, e in ipairs(entries) do
                e.lookup_word = w
                found[#found + 1] = e
            end
        end
        for _, e in ipairs(Lookup.trimRepeats(found)) do
            local html
            local function entry_html()
                html = html or d:entryHtml(e.record)
                return html
            end
            local word = e.key
            if Lookup.isInternalKey(word) then word = opts.display_word end
            results[#results + 1] = lazy({
                dict = d.title,
                word = word,
                is_html = true,
                dictionary_resource_directory = d.res_dir,
                mdict = lazy({ id = d.id, anchor = e.anchor, key = e.key, fuzzy = e.fuzzy }, { html = entry_html }),
            }, {
                definition = function() return Html.stripScripts(entry_html()) end,
                word = function() return Lookup.headwordOf(entry_html()) or e.lookup_word end,
            })
        end
        if failed then problems[#problems + 1] = { dict = d, state = failed } end
    end
    return results, problems
end

return Lookup
