--[[--
Turns MDict lookups into KOReader dictionary results.

A result looks like sdcv's ({ dict, word, definition }) plus:
  is_html = true
  dictionary_resource_directory = the dictionary's extracted-resource cache (for MuPDF)
  mdict = { id, html, anchor, key }: the entry with its scripts, for the WebView renderer
`definition` is the same entry without scripts, which MuPDF can render as a fallback.
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
function Lookup.headwordOf(html)
    for _, token in ipairs(HEAD_TOKENS) do
        local pos = 1
        while true do
            local s, e = html:find("<%a[^>]*>", pos)
            if not s then break end
            local tag = html:sub(s, e)
            for value in tag:gmatch('[%w_-]+%s*=%s*"([^"]*)"') do
                for t in value:gmatch("[^%s]+") do
                    if t == token or (#token > 3 and t:find(token, 1, true)) then
                        local text = element_text(html, s)
                        if text ~= "" then
                            if #text > 60 then text = text:sub(1, 60):gsub("[\128-\191]*$", ""):gsub("[\192-\255]$", "") end
                            return text
                        end
                    end
                end
            end
            pos = e + 1
            if pos > 20000 then break end
        end
    end
end

--- True for keys that are internal identifiers rather than words (e.g. "EXPORT:83:49022",
-- or link targets named by a hash such as "LINKe578507222d7199d1963...").
function Lookup.isInternalKey(key)
    return key:find("^[%u%d_]+:[%w_]+:") ~= nil or key:find("^%d+$") ~= nil
        or (key:find("%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x") ~= nil and not key:find("%s"))
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
                local html = d:entryHtml(e.record)
                local display = e.key
                if Lookup.isInternalKey(display) then
                    display = opts.display_word or Lookup.headwordOf(html) or w
                end
                results[#results + 1] = {
                    dict = d.title,
                    word = display,
                    definition = Html.stripScripts(html),
                    is_html = true,
                    dictionary_resource_directory = d.res_dir,
                    mdict = { id = d.id, html = html, anchor = e.anchor, key = e.key, fuzzy = e.fuzzy },
                }
            end
        end
        if failed then problems[#problems + 1] = { dict = d, state = failed } end
    end
    return results, problems
end

return Lookup
