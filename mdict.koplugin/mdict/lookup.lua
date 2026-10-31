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

--- Runs the lookups. dicts: Dictionary objects in display order; words: candidate words.
-- opts: fuzzy, display_word (shown instead of internal keys).
-- Returns results, and a list of { dict, state } for dictionaries that could not answer.
function Lookup.run(dicts, words, opts)
    opts = opts or {}
    local results, problems = {}, {}
    for _, d in ipairs(dicts) do
        local seen = {}
        local failed
        for _, w in ipairs(words) do
            local entries, err = d:lookup(w, { fuzzy = opts.fuzzy, seen = seen })
            if not entries then
                failed = err
                break
            end
            for _, e in ipairs(entries) do
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
                    word = function() return Lookup.headwordOf(entry_html()) or w end,
                })
            end
        end
        if failed then problems[#problems + 1] = { dict = d, state = failed } end
    end
    return results, problems
end

return Lookup
