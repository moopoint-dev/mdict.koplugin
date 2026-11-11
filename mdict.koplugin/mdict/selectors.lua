--[[--
Selectors for WebViews before Chromium 88, which have no :is(), :where() or :not() with a list or
more than one simple selector. Such a browser drops every rule whose selector list holds one of
them, and so it drops a rule for :has() (Chromium 105) in any of its selectors: dictionaries made
for current browsers lost most of their styles on Kindles (Chromium 75).

flatten() writes each such selector out as the selectors it stands for:
  .a :is(img, .b).c          ->  .a img.c, .a .b.c
  .a:where(:not(.b, .c))     ->  .a:not(.b):not(.c)
  :not(.a.b)                 ->  :not(.a), :not(.b)
  :where(.root sup) .x       ->  .root sup .x
and leaves out the selectors of a list that the browser still cannot read (:has(), and what
cannot be written out), so that the others apply. The pager does the same in the page
(flattenSelectors in pager.js): keep the two alike.

An argument with ancestors (or earlier siblings), under a compound that has some of its own, is
joined with them in each order they can take, up to Selectors.MAX selectors.

Limit: :where() takes the weight (specificity) of its arguments, which can change which of two
rules wins.
]]

local Selectors = {}

-- More selectors than this from one selector: it is left as it was.
Selectors.MAX = 256

local function is_ident_byte(b)
    return b and (b >= 48 and b <= 57 or b >= 65 and b <= 90 or b >= 97 and b <= 122 or b == 45 or b == 95
        or b >= 128)
end

-- Index of the quote that closes the string starting at i, or nil.
local function string_end(s, i)
    local q = s:byte(i)
    local j = i + 1
    while j <= #s do
        local b = s:byte(j)
        if b == 92 then
            j = j + 2
        elseif b == q then
            return j
        else
            j = j + 1
        end
    end
end

-- Index of the bracket that closes the one at i ("(" or "["), or nil.
local function closing(s, i)
    local depth, j = 0, i
    while j <= #s do
        local b = s:byte(j)
        if b == 92 then
            j = j + 1
        elseif b == 34 or b == 39 then
            j = string_end(s, j)
            if not j then return nil end
        elseif b == 40 or b == 91 then
            depth = depth + 1
        elseif b == 41 or b == 93 then
            depth = depth - 1
            if depth == 0 then return j end
        end
        j = j + 1
    end
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- The items of a comma-separated list, outside brackets and strings.
local function split_list(s)
    local out, start, j = {}, 1, 1
    while j <= #s do
        local b = s:byte(j)
        if b == 92 then
            j = j + 1
        elseif b == 34 or b == 39 then
            j = string_end(s, j) or #s
        elseif b == 40 or b == 91 then
            j = closing(s, j) or #s
        elseif b == 44 then
            out[#out + 1] = trim(s:sub(start, j - 1))
            start = j + 1
        end
        j = j + 1
    end
    out[#out + 1] = trim(s:sub(start))
    return out
end
Selectors.splitList = split_list

-- A complex selector as its compounds, each with the combinator to the next (" ", ">", "+", "~").
local function parse_complex(s)
    local nodes, start, j, n = {}, 1, 1, #s
    local function push(k)
        local raw = s:sub(start, j - 1)
        if raw == "" then return false end
        nodes[#nodes + 1] = { raw = raw, k = k }
        return true
    end
    while j <= n do
        local b = s:byte(j)
        if b == 92 then
            j = j + 2
        elseif b == 34 or b == 39 then
            j = (string_end(s, j) or n) + 1
        elseif b == 40 or b == 91 then
            local c = closing(s, j)
            if not c then return nil end
            j = c + 1
        elseif b == 32 or b == 9 or b == 10 or b == 12 or b == 13 or b == 62 or b == 43 or b == 126 then
            local stop = j
            local k = " "
            while j <= n do
                local c = s:byte(j)
                if c == 62 or c == 43 or c == 126 then
                    if k ~= " " then return nil end
                    k = string.char(c)
                elseif not (c == 32 or c == 9 or c == 10 or c == 12 or c == 13) then
                    break
                end
                j = j + 1
            end
            if j > n then
                if k ~= " " then return nil end
                j = stop
                break -- trailing space
            end
            local keep = j
            j = stop
            if not push(k) then return nil end
            j, start = keep, keep
        else
            j = j + 1
        end
    end
    if not push(nil) then return nil end
    return nodes
end

-- A compound's type selector (or nil) and its other simple selectors, as written.
local function parse_compound(s)
    local subs, j, n = {}, 1, #s
    local typ
    local function ident(from)
        local k = from
        while k <= n do
            local b = s:byte(k)
            if b == 92 then
                k = k + 2
            elseif is_ident_byte(b) then
                k = k + 1
            else
                break
            end
        end
        return k
    end
    local b = s:byte(1)
    if b == 42 or b == 124 or b == 92 or is_ident_byte(b) and not (b >= 48 and b <= 57) then
        local k = 1
        while k <= n do
            local c = s:byte(k)
            if c == 42 or c == 124 then
                k = k + 1
            elseif c == 92 or is_ident_byte(c) then
                k = ident(k)
                if k == 1 then break end
            else
                break
            end
        end
        typ = s:sub(1, k - 1)
        j = k
    end
    while j <= n do
        local c = s:byte(j)
        local stop
        if c == 46 or c == 35 then -- . #
            stop = ident(j + 1)
            if stop == j + 1 then return nil end
        elseif c == 91 then -- [
            local e = closing(s, j)
            if not e then return nil end
            stop = e + 1
        elseif c == 58 then -- :
            local k = j + 1
            if s:byte(k) == 58 then k = k + 1 end
            stop = ident(k)
            if stop == k then return nil end
            if s:byte(stop) == 40 then
                local e = closing(s, stop)
                if not e then return nil end
                stop = e + 1
            end
        else
            return nil
        end
        subs[#subs + 1] = s:sub(j, stop - 1)
        j = stop
    end
    return { type = typ, subs = subs }
end

local function render_compound(c)
    local s = (c.type or "") .. table.concat(c.subs)
    return s == "" and "*" or s
end

local function render(chain)
    local out = {}
    for i, node in ipairs(chain) do
        out[#out + 1] = render_compound(node.c)
        if node.k and i < #chain then out[#out + 1] = node.k == " " and " " or (" " .. node.k .. " ") end
    end
    return table.concat(out)
end

local function copy_compound(c)
    local subs = {}
    for i, v in ipairs(c.subs) do subs[i] = v end
    return { type = c.type, subs = subs }
end

-- One compound for an element that matches both, or nil when no element can (two types).
local function merge(a, b)
    local ta, tb = a.type, b.type
    local typ = ta
    if ta and ta ~= "*" and tb and tb ~= "*" then
        if ta:lower() ~= tb:lower() then return nil end
    elseif not ta or ta == "*" then
        typ = tb or ta
    end
    local c = copy_compound(a)
    c.type = typ
    for _, v in ipairs(b.subs) do c.subs[#c.subs + 1] = v end
    return c
end

local function slice(chain, from, to)
    local out = {}
    for i = from, to do out[#out + 1] = chain[i] end
    return out
end

local function ancestral(k) return k == " " or k == ">" end

-- Whether a node with combinator bk to the subject can come right before a node with combinator
-- ak to it, keeping bk (now to that node) and still standing as bk to the subject.
local function can_precede(bk, ak)
    if bk == " " then return true end
    if bk == "+" then return false end
    return not ancestral(ak) -- ">" or "~": before a sibling of the subject
end

-- The combinator to the subject of one element that two nodes stand for, or nil.
local function both(k1, k2)
    if ancestral(k1) ~= ancestral(k2) then return nil end
    if ancestral(k1) then return (k1 == ">" or k2 == ">") and ">" or " " end
    return (k1 == "+" or k2 == "+") and "+" or "~"
end

-- Two chains of nodes (each with its combinator to the next, the last one's to the subject) for
-- the same subject, joined in each order they can take: the node next to the subject is the last
-- of one chain, or the last of both on one element, and so on up. More than Selectors.MAX: cut.
local function join(p, x)
    if #x == 0 then return { slice(p, 1, #p) } end
    if #p == 0 then return { slice(x, 1, #x) } end
    local out = {}
    local function add(chains, node)
        for _, chain in ipairs(chains) do
            if #out > Selectors.MAX then return end
            chain[#chain + 1] = node
            out[#out + 1] = chain
        end
    end
    local pl, xl = p[#p], x[#x]
    if can_precede(xl.k, pl.k) then add(join(slice(p, 1, #p - 1), x), pl) end
    if can_precede(pl.k, xl.k) then add(join(p, slice(x, 1, #x - 1)), xl) end
    local k = both(pl.k, xl.k)
    local m = k and merge(pl.c, xl.c)
    if m then add(join(slice(p, 1, #p - 1), slice(x, 1, #x - 1)), { c = m, k = k }) end
    return out
end

local expand_complex

-- The ways a compound can be written without :is(), :where() and :not() lists: each with the
-- ancestors its arguments bring ({ chain, c }). Nil when it cannot be.
local function expand_compound(raw)
    local parsed = parse_compound(raw)
    if not parsed then return nil end
    local alts = { { chain = {}, c = { type = parsed.type, subs = {} } } }
    for _, sub in ipairs(parsed.subs) do
        local name = sub:match("^:([%w%-]+)%(")
        name = name and name:lower()
        if name == "is" or name == "where" or name == "matches" then
            local args = {}
            for _, item in ipairs(split_list(sub:sub(#name + 3, -2))) do
                -- (forgiving: an argument that cannot be written out is left out)
                for _, e in ipairs(item ~= "" and expand_complex(item) or {}) do args[#args + 1] = e end
            end
            local new = {}
            for _, alt in ipairs(alts) do
                for _, e in ipairs(args) do
                    local m = merge(alt.c, e[#e].c)
                    if m then
                        for _, chain in ipairs(join(alt.chain, slice(e, 1, #e - 1))) do
                            new[#new + 1] = { chain = chain, c = copy_compound(m) }
                        end
                    end
                end
            end
            alts = new
        elseif name == "not" then
            -- not (A or B) = not A and not B; not (a.b) = not a, or not b
            for _, item in ipairs(split_list(sub:sub(6, -2))) do
                local ex = item ~= "" and expand_complex(item)
                if not ex then return nil end
                for _, e in ipairs(ex) do
                    if #e > 1 then return nil end -- not with ancestors: no way to write it
                    local c = e[1].c
                    local choices = {}
                    if c.type and c.type ~= "*" then choices[1] = ":not(" .. c.type .. ")" end
                    for _, s in ipairs(c.subs) do choices[#choices + 1] = ":not(" .. s .. ")" end
                    local new = {}
                    for _, alt in ipairs(alts) do
                        for _, ch in ipairs(choices) do
                            local a = { chain = alt.chain, c = copy_compound(alt.c) }
                            a.c.subs[#a.c.subs + 1] = ch
                            new[#new + 1] = a
                        end
                    end
                    alts = new -- (none for :not(*): it matches nothing)
                end
            end
        else
            for _, alt in ipairs(alts) do alt.c.subs[#alt.c.subs + 1] = sub end
        end
        if #alts > Selectors.MAX then return nil end
    end
    return alts
end

-- The selectors a complex selector stands for, as chains of { c, k }; nil when it cannot be
-- written out.
expand_complex = function(s)
    local nodes = parse_complex(s)
    if not nodes then return nil end
    local alts = { {} }
    for _, node in ipairs(nodes) do
        local ecs = expand_compound(node.raw)
        if not ecs then return nil end
        local new = {}
        for _, alt in ipairs(alts) do
            for _, e in ipairs(ecs) do
                for _, chain in ipairs(join(alt, e.chain)) do
                    chain[#chain + 1] = { c = e.c, k = node.k }
                    new[#new + 1] = chain
                end
            end
        end
        if #new > Selectors.MAX then return nil end
        alts = new
    end
    return alts
end

local NEW = { ":is(", ":where(", ":matches(", ":has(" }

local function has_new(s)
    local low = s:lower()
    for _, f in ipairs(NEW) do
        if low:find(f, 1, true) then return true end
    end
    -- :not() with more than one simple selector
    local from = 1
    while true do
        local i = low:find(":not(", from, true)
        if not i then return false end
        local e = closing(s, i + 4)
        if not e then return true end
        local items = split_list(s:sub(i + 5, e - 1))
        if #items ~= 1 then return true end
        local c = parse_compound(items[1])
        if not c or #c.subs + (c.type and 1 or 0) ~= 1 then return true end
        from = e + 1
    end
end

-- A selector list written out, or nil when it needs nothing.
local function flatten_list(prelude)
    if not has_new(prelude) then return nil end
    local out, changed = {}, false
    for _, item in ipairs(split_list(prelude)) do
        if has_new(item) then
            changed = true
            local ex = expand_complex(item)
            for _, chain in ipairs(ex or {}) do
                local s = render(chain)
                if not has_new(s) then out[#out + 1] = s end
            end
        else
            out[#out + 1] = item
        end
    end
    if not changed or #out == 0 then return nil end -- (nothing left: the rule stays as it was)
    return table.concat(out, ", ")
end
Selectors.flattenList = flatten_list

local GROUPS = { media = true, supports = true, document = true, ["-moz-document"] = true, layer = true,
                 container = true, scope = true, ["starting-style"] = true }

-- Index of the "{" or ";" that ends the prelude starting at i (outside strings, brackets and
-- comments), or of the "}" that ends the block, or nil at the end.
local function prelude_end(css, i)
    local n = #css
    while i <= n do
        local b = css:byte(i)
        if b == 47 and css:byte(i + 1) == 42 then
            local e = css:find("*/", i + 2, true)
            if not e then return nil end
            i = e + 2
        else
            if b == 92 then
                i = i + 1
            elseif b == 34 or b == 39 then
                i = string_end(css, i) or n
            elseif b == 40 or b == 91 then
                i = closing(css, i) or n
            elseif b == 123 or b == 59 or b == 125 then
                return i
            end
            i = i + 1
        end
    end
end

-- Index of the "}" that closes the block opened at i.
local function block_end(css, i)
    local depth, n = 0, #css
    while i <= n do
        local b = css:byte(i)
        if b == 47 and css:byte(i + 1) == 42 then
            local e = css:find("*/", i + 2, true)
            if not e then return n end
            i = e + 1
        elseif b == 92 then
            i = i + 1
        elseif b == 34 or b == 39 then
            i = string_end(css, i) or n
        elseif b == 123 then
            depth = depth + 1
        elseif b == 125 then
            depth = depth - 1
            if depth == 0 then return i end
        end
        i = i + 1
    end
    return n
end

-- Rewrites the rules from i to the "}" that closes their block (or the end); returns the
-- index after it.
local function rules(css, i, out)
    local n = #css
    while i <= n do
        local e = prelude_end(css, i)
        if not e then
            out[#out + 1] = css:sub(i)
            return n + 1
        end
        local b = css:byte(e)
        if b == 125 then -- the enclosing block ends
            out[#out + 1] = css:sub(i, e)
            return e + 1
        end
        local prelude = css:sub(i, e - 1)
        local at = prelude:match("^%s*@([%w%-]+)")
        if b == 59 then
            out[#out + 1] = css:sub(i, e)
            i = e + 1
        elseif at and GROUPS[at:lower()] then
            out[#out + 1] = css:sub(i, e)
            i = rules(css, e + 1, out)
        elseif at then
            local stop = block_end(css, e)
            out[#out + 1] = css:sub(i, stop)
            i = stop + 1
        else
            local stop = block_end(css, e)
            local lead = prelude:match("^%s*")
            local sel = prelude:sub(#lead + 1)
            local flat = sel:find("[:%(]") and flatten_list((sel:gsub("/%*.-%*/", "")))
            out[#out + 1] = flat and (lead .. flat .. " ") or prelude
            out[#out + 1] = css:sub(e, stop)
            i = stop + 1
        end
    end
    return i
end

--- CSS with its selectors written for browsers before Chromium 88 (see above).
function Selectors.flatten(css)
    local out = {}
    rules(css, 1, out)
    return table.concat(out)
end

--- Whether CSS has selectors that browsers before Chromium 88 cannot read.
function Selectors.uses(css)
    local low = css:lower()
    for _, f in ipairs(NEW) do
        if low:find(f, 1, true) then return true end
    end
    local from = 1
    while true do
        local i = low:find(":not(", from, true)
        if not i then return false end
        local e = closing(css, i + 4)
        if e and has_new(css:sub(i, e)) then return true end
        from = (e or i + 4) + 1
    end
end

return Selectors
