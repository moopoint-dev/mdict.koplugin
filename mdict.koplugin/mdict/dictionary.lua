--[[--
One MDict dictionary: its .mdx file, its .mdd resource files, their indexes
and the extracted-resource cache.

Index choice, per file (see Dictionary:_openIndex):
  1. a valid sidecar index (built for this size/mtime/spec)
  2. the file's own order, when a full check found it sorted under the spec
  3. an in-memory index, for small files
  4. the file's own order, when the header promises it (KOReaderKeyOrder) and
     the key-block boundaries agree; a full check is queued
  5. otherwise nothing yet: a sidecar build is queued, and lookups in this
     dictionary report that it is being indexed
]]

local Html = require("mdict/html")
local Index = require("mdict/index")
local Reader = require("mdict/reader")
local fs = require("mdict/fs")
local json = require("mdict/json")

local Dictionary = {}
Dictionary.__index = Dictionary

Dictionary.MEMORY_INDEX_MAX = 30000 -- files with fewer keys are indexed in memory when opened
Dictionary.MAX_LINK_HOPS = 3
Dictionary.MAX_RESULTS = 12 -- records per lookup word
Dictionary.FUZZY_RESULTS = 5
Dictionary.KEY_ORDER_ATTR = "KOReaderKeyOrder"

local function fnv1a(s)
    local bit = require("bit")
    local h = 0x811C9DC5
    for i = 1, #s do
        h = bit.bxor(h, s:byte(i))
        h = bit.tobit(h * 0x01000193)
    end
    return bit.tohex(h)
end

--- Stable id for a dictionary path, usable as a host name label.
function Dictionary.idFor(path)
    local base = fs.basename(path):gsub("%.mdx$", ""):lower():gsub("[^%w]+", "-"):gsub("^-+", ""):gsub("-+$", "")
    if #base > 24 then base = base:sub(1, 24):gsub("-+$", "") end
    if base == "" then base = "dict" end
    return base .. "-" .. fnv1a(path)
end

--- Companion resource files of an .mdx: X.mdd, X.1.mdd, X.2.mdd, ...
function Dictionary.findMdds(mdx_path)
    local stem = mdx_path:gsub("%.[Mm][Dd][Xx]$", "")
    local found = {}
    if fs.isFile(stem .. ".mdd") then found[#found + 1] = stem .. ".mdd" end
    for n = 1, 99 do
        local p = stem .. "." .. n .. ".mdd"
        if not fs.isFile(p) then break end
        found[#found + 1] = p
    end
    return found
end

--- o: path, id, title, cache_dir, mdd_paths (optional), builder (optional, see requestIndex)
function Dictionary.new(o)
    local self = setmetatable(o, Dictionary)
    self.id = self.id or Dictionary.idFor(self.path)
    self.mdd_paths = self.mdd_paths or Dictionary.findMdds(self.path)
    self.dir = fs.dirname(self.path)
    self.res_dir = self.cache_dir .. "/res/" .. self.id
    self.idx_dir = self.cache_dir .. "/idx"
    self.files = nil -- opened lazily: { {reader=, path=, kind=, index=, state=} ... }
    return self
end

function Dictionary:open()
    if self.files then return true end
    local mdx, err = Reader.open(self.path)
    if not mdx then
        self.error = err
        return nil, err
    end
    self.mdx = mdx
    self.title = self.title or mdx.title or fs.basename(self.path):gsub("%.mdx$", "")
    self.styles = Html.parseStyleSheet(mdx.header.StyleSheet)
    self.files = { { reader = mdx, path = self.path, kind = "mdx" } }
    for i, p in ipairs(self.mdd_paths) do
        local r = Reader.open(p)
        if r then
            self.files[#self.files + 1] = { reader = r, path = p, kind = "mdd" .. i }
        end
    end
    return true
end

function Dictionary:close()
    if not self.files then return end
    for _, f in ipairs(self.files) do
        if f.index then f.index:close() end
        f.reader:close()
    end
    self.files, self.mdx = nil, nil
end

-- index bookkeeping ------------------------------------------------------------

function Dictionary:_paths(f)
    local base = string.format("%s/%s.%s", self.idx_dir, self.id, f.kind)
    return base .. ".idx", base .. ".verdict"
end

local function spec_of(reader)
    return reader.is_mdd and "res-1" or "kosort-1"
end

local function read_verdict(path)
    local data = fs.readAll(path)
    if not data then return nil end
    local ok, v = pcall(json.decode, data)
    return ok and type(v) == "table" and v or nil
end

function Dictionary.writeVerdict(path, v)
    return fs.writeAtomic(path, json.encode(v))
end

function Dictionary:_openIndex(f)
    if f.index then return f.index end
    local reader, spec = f.reader, spec_of(f.reader)
    local size, mtime = fs.stat(f.path)
    local sidecar, verdict_path = self:_paths(f)
    f.size, f.mtime = size, mtime
    local idx = Index.openSidecar(sidecar, spec, { size = size, mtime = mtime, keys = reader.num_entries })
    if idx then
        f.index, f.state = idx, "sidecar"
        return idx
    end
    local v = read_verdict(verdict_path)
    if v and v.spec == spec and v.size == size and v.mtime == mtime and v.keys == reader.num_entries then
        if v.sorted then
            f.index, f.state = Index.openFileOrder(reader, spec), "file-order"
            return f.index
        end
    end
    if reader.num_entries <= Dictionary.MEMORY_INDEX_MAX then
        local idx = Index.buildMemory(reader, spec)
        f.index, f.state = idx, "memory"
        -- An .mdx is indexed in memory again in every session, normalising every key (up to a
        -- second each on an e-reader): what this pass found spares the next ones. A sorted file
        -- is then searched in its own order; another gets a sidecar, built in the background.
        if not reader.is_mdd and not (v and v.spec == spec and v.size == size and v.mtime == mtime
                and v.keys == reader.num_entries) then
            if idx.inversions == 0 then
                Dictionary.writeVerdict(verdict_path, { spec = spec, size = size, mtime = mtime,
                    keys = reader.num_entries, sorted = true, inversions = 0 })
            elseif not f.build_failed then
                self:_requestBuild(f, spec)
                f.state = "memory"
            end
        end
        return f.index
    end
    if reader.header[Dictionary.KEY_ORDER_ATTR] == spec and Index.boundariesOrdered(reader, spec) then
        -- trust the exporter for now; a full check runs in the background
        f.index, f.state = Index.openFileOrder(reader, spec), "file-order (unverified)"
        if not (v and v.size == size and v.mtime == mtime) then self:_requestBuild(f, spec) end
        return f.index
    end
    self:_requestBuild(f, spec)
    return nil, "indexing"
end

function Dictionary:_requestBuild(f, spec)
    if f.building then return end
    local sidecar, verdict_path = self:_paths(f)
    local job = {
        dict = self, title = self.title, path = f.path, spec = spec, sidecar = sidecar, verdict = verdict_path,
        size = f.size, mtime = f.mtime, keys = f.reader.num_entries,
    }
    f.building = true
    f.state = "indexing"
    if self.builder then
        self.builder(job, function(ok)
            f.building = false
            f.index = nil
            if not ok then f.state, f.build_failed = "index failed", true end
        end)
    else
        local ok = pcall(Dictionary.buildIndexJob, job)
        f.building = false
        if not ok then f.state, f.build_failed = "index failed", true end
    end
end

--- Builds the index for a job (runs in a subprocess inside KOReader). Writes the verdict;
-- a sidecar is kept only when the file is not already in spec order.
function Dictionary.buildIndexJob(job, progress)
    fs.mkdirp(fs.dirname(job.sidecar))
    local reader = assert(Reader.open(job.path))
    local stats = Index.buildSidecar(reader, job.sidecar, job.spec, {
        source_size = job.size, source_mtime = job.mtime, progress = progress,
    })
    reader:close()
    if stats.sorted then os.remove(job.sidecar) end
    Dictionary.writeVerdict(job.verdict, {
        spec = job.spec, size = job.size, mtime = job.mtime, keys = stats.keys,
        sorted = stats.sorted, inversions = stats.inversions,
    })
    return stats
end

--- Index state of every file: { {path=, kind=, state=} }.
--- The state of a closed dictionary's .mdx index, from the files left by an earlier build:
-- "sidecar" or "file-order" when it is ready, else nil.
function Dictionary:storedIndexState()
    local size, mtime = fs.stat(self.path)
    local sidecar, verdict_path = self:_paths({ kind = "mdx" })
    local idx = Index.openSidecar(sidecar, "kosort-1", { size = size, mtime = mtime })
    if idx then
        idx:close()
        return "sidecar"
    end
    local v = read_verdict(verdict_path)
    if v and v.sorted and v.spec == "kosort-1" and v.size == size and v.mtime == mtime then
        return "file-order"
    end
end

function Dictionary:indexStates()
    local out = {}
    if not self.files then return out end
    for _, f in ipairs(self.files) do
        out[#out + 1] = { path = f.path, kind = f.kind, state = f.state or "not loaded" }
    end
    return out
end

--- Opens (or queues) the indexes of all files. Returns true when the .mdx index is usable.
function Dictionary:prepareIndexes()
    local ok, err = self:open()
    if not ok then return nil, err end
    local usable = self:_openIndex(self.files[1]) ~= nil
    for i = 2, #self.files do self:_openIndex(self.files[i]) end
    return usable
end

-- lookups ----------------------------------------------------------------------

local function normalize(spec, word)
    local n = Index.normalizer(spec)(word)
    if #n > Index.MAX_KEY then n = n:sub(1, Index.MAX_KEY) end
    return n
end

local function is_link(record)
    return record:sub(1, 8) == "@@@LINK="
end

--- Resolves an ordinal to its final record, following @@@LINK= redirects.
-- Returns the final key, ord, record and anchor, and whether a link led there
-- (or nil when the chain is broken or loops).
function Dictionary:_resolve(idx, ord)
    local mdx = self.mdx
    local key = mdx:keyAt(ord)
    local anchor
    local seen = {}
    for hop = 0, Dictionary.MAX_LINK_HOPS do
        if seen[ord] then return nil end
        seen[ord] = true
        local record = mdx:record(ord)
        if not is_link(record) then return key, ord, record, anchor, hop > 0 end
        local target = record:sub(9):match("^%s*(.-)%s*$")
        local word, a = Html.splitAnchor(target)
        anchor = anchor or a
        local cands = idx:find(normalize("kosort-1", word))
        if #cands == 0 then return nil end
        -- prefer the exact spelling
        local best = cands[1]
        for _, c in ipairs(cands) do
            if mdx:keyAt(c) == word then
                best = c
                break
            end
        end
        ord = best
        key = mdx:keyAt(ord)
    end
    return nil
end

--- Likely base forms of an inflected English word (for fuzzy lookups): "apples" -> "apple".
function Dictionary.baseForms(word)
    local w = word:lower()
    if not w:find("^[a-z][a-z'-]+$") then return {} end
    local out, seen = {}, { [w] = true }
    local function add(b)
        if #b >= 2 and not seen[b] then
            seen[b] = true
            out[#out + 1] = b
        end
    end
    local function undouble(b) -- "running" -> "runn" -> "run"
        if #b >= 3 and b:sub(-1) == b:sub(-2, -2) and b:sub(-1):find("[bdgklmnprt]") then add(b:sub(1, -2)) end
    end
    if w:sub(-2) == "'s" then add(w:sub(1, -3)) end
    if w:sub(-3) == "ies" then add(w:sub(1, -4) .. "y") end
    if w:sub(-2) == "es" then add(w:sub(1, -3)) end
    if w:sub(-1) == "s" and w:sub(-2) ~= "ss" then add(w:sub(1, -2)) end
    if w:sub(-3) == "ied" then add(w:sub(1, -4) .. "y") end
    if w:sub(-2) == "ed" then
        local b = w:sub(1, -3)
        add(b); add(w:sub(1, -2)); undouble(b)
    end
    if w:sub(-3) == "ing" then
        local b = w:sub(1, -4)
        add(b); add(b .. "e"); undouble(b)
        if b:sub(-1) == "y" then add(b:sub(1, -2) .. "ie") end
    end
    if w:sub(-4) == "iest" then add(w:sub(1, -5) .. "y") end
    if w:sub(-3) == "ier" then add(w:sub(1, -4) .. "y") end
    if w:sub(-3) == "est" then local b = w:sub(1, -4); add(b); add(b .. "e"); undouble(b) end
    if w:sub(-2) == "er" then local b = w:sub(1, -3); add(b); add(b .. "e"); undouble(b) end
    if w:sub(-3) == "ily" then add(w:sub(1, -4) .. "y") end
    if w:sub(-2) == "ly" then add(w:sub(1, -3)) end
    return out
end

--- Looks up one word. Returns a list of { key, ord, record, anchor }, or nil and "indexing"/error.
-- opts: fuzzy (base forms, then prefix matches, when nothing matches exactly), limit,
--       seen (records already returned, shared across candidate words)
function Dictionary:lookup(word, opts)
    opts = opts or {}
    local ok, err = self:open()
    if not ok then return nil, err end
    local idx, state = self:_openIndex(self.files[1])
    if not idx then return nil, state end
    local w, anchor = Html.splitAnchor(word)
    local nkey = normalize("kosort-1", w)
    if nkey == "" then return {} end
    local ords = idx:find(nkey)
    local fuzzy = false
    local bases = {}
    if #ords == 0 and opts.fuzzy then
        fuzzy = true
        for _, base in ipairs(Dictionary.baseForms(w)) do
            bases[base] = true
            for _, o in ipairs(idx:find(normalize("kosort-1", base))) do ords[#ords + 1] = o end
        end
        if #ords == 0 then
            for _, p in ipairs(idx:prefix(nkey, Dictionary.FUZZY_RESULTS * 4)) do ords[#ords + 1] = p[2] end
        end
    end
    -- exact spelling first, then same lowercase, then a base form as spelled, then file order
    local mdx = self.mdx
    local lw = w:lower()
    local ranked = {}
    for _, o in ipairs(ords) do
        local k = mdx:keyAt(o)
        local rank = k == w and 0 or (k:lower() == lw and 1 or (bases[k] and 2 or 3))
        ranked[#ranked + 1] = { o = o, rank = rank }
    end
    table.sort(ranked, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.o < b.o
    end)
    -- Some exporters store one copy of an entry per key, so compare contents, not offsets.
    local out, seen = {}, opts.seen or {}
    local limit = opts.limit or (fuzzy and Dictionary.FUZZY_RESULTS or Dictionary.MAX_RESULTS)
    for _, r in ipairs(ranked) do
        local key, ord, record, link_anchor, linked = self:_resolve(idx, r.o)
        if key then
            if not seen[record] then
                seen[record] = true
                out[#out + 1] = { key = key, ord = ord, record = record, anchor = anchor or link_anchor, fuzzy = fuzzy,
                                  linked = linked }
                if #out >= limit then break end
            end
        end
    end
    return out
end

--- Entry HTML ready for display: compact styles expanded, overrides applied, link schemes rewritten.
function Dictionary:entryHtml(record)
    local html = Html.applyStyleSheet(record, self.styles)
    for _, path in ipairs(self:_overrideFiles(".lua")) do
        local fix = self:_loadFixer(path)
        if fix then
            local ok, fixed = pcall(fix, html)
            if ok and type(fixed) == "string" then
                html = fixed
            elseif not self._fixers[path].failed then
                self._fixers[path].failed = true
                require("logger").warn("MDict: " .. path .. " failed:", fixed)
            end
        end
    end
    return Html.rewriteLinks(html)
end

function Dictionary:_stem()
    return (self.path:gsub("%.[Mm][Dd][Xx]$", ""))
end

--- Name of the override files shared by every dictionary in a folder and its subfolders.
Dictionary.SHARED_OVERRIDES = "mdict.koreader"

--- Override files for this dictionary, in the order they apply: the shared ones
-- (mdict.koreader<ext>) from the library folder it was found in down to its own
-- folder, then its own <name>.koreader<ext>. Missing files are listed too.
function Dictionary:_overrideFiles(ext)
    if not self._override_dirs then
        local dirs, dir = {}, self.dir
        local root = self.root and self.root:gsub("/+$", "")
        while dir and dir ~= "" do
            table.insert(dirs, 1, dir)
            if not root or dir == root or #dir <= #root or dir:sub(1, #root + 1) ~= root .. "/" then break end
            dir = dir:match("^(.*)/[^/]+$")
        end
        self._override_dirs = dirs
    end
    local out = {}
    for _, dir in ipairs(self._override_dirs) do out[#out + 1] = dir .. "/" .. Dictionary.SHARED_OVERRIDES .. ext end
    out[#out + 1] = self:_stem() .. ".koreader" .. ext
    return out
end

-- What an override .lua file may use: text functions, nothing that reaches files or the system.
local FIXER_ENV = {
    string = string, table = table, math = math, utf8 = rawget(_G, "utf8"),
    pairs = pairs, ipairs = ipairs, next = next, select = select, type = type,
    tostring = tostring, tonumber = tonumber, pcall = pcall, error = error,
}

--- The entry fixer in an override .lua file, if it exists: the file returns a function
-- taking an entry's HTML and returning it changed. Reloaded when the file changes.
function Dictionary:_loadFixer(path)
    self._fixers = self._fixers or {}
    local _, mtime = fs.stat(path)
    local c = self._fixers[path]
    if c and c.mtime == mtime then return c.fn end
    c = { mtime = mtime }
    self._fixers[path] = c
    if not mtime then return nil end
    local env = setmetatable({}, { __index = FIXER_ENV })
    local chunk, err = loadfile(path, "t", env)
    if chunk and setfenv then setfenv(chunk, env) end
    local ok, fn = false, err
    if chunk then ok, fn = pcall(chunk) end
    if ok and type(fn) == "function" then
        c.fn = fn
    else
        require("logger").warn("MDict: cannot load", path, fn)
    end
    return c.fn
end

-- resources --------------------------------------------------------------------

--- Bytes of a resource (path relative to the dictionary root, "/" separators), or nil.
-- Files next to the .mdx win over the .mdd (dictionaries often ship an updated CSS that way).
function Dictionary:resourceData(path)
    local loose = self.dir .. "/" .. path
    if fs.isFile(loose) then return fs.readAll(loose) end
    local ok = self:open()
    if not ok then return nil end
    local key = normalize("res-1", Html.mddKey(path))
    for i = 2, #self.files do
        local f = self.files[i]
        local idx = self:_openIndex(f)
        if idx then
            local ords = idx:find(key)
            if ords[1] then return f.reader:record(ords[1]) end
        end
    end
    return nil
end

--- Path of a resource extracted into the cache (extracting it if needed), or nil.
function Dictionary:resource(path)
    -- decoded already: "#" and "?" are part of the name here
    path = Html.cleanPath(path)
    if not path or path == "" then return nil end
    local target = self.res_dir .. "/" .. path
    if fs.isFile(target) then return target end
    local data = self:resourceData(path)
    if not data then return nil end
    if not fs.writeAtomic(target, data) then return nil end
    return target
end

--- Extracts what a static renderer (MuPDF) needs up front: the entry's stylesheets,
-- what they reference, and the entry's own images. Returns the resource directory.
-- Extracts a stylesheet and what it refers to, following @import chains.
function Dictionary:_prefetchCss(p, depth)
    if self._prefetched[p] or depth > 4 then return end
    self._prefetched[p] = true
    local file = self:resource(p)
    if not file then return end
    local base = p:match("^(.*)/[^/]*$") or ""
    for _, ref in ipairs(Html.cssRefs(fs.readAll(file) or "")) do
        local rp = Html.resourcePath(ref, base)
        if rp:lower():match("%.css$") then self:_prefetchCss(rp, depth + 1) else self:resource(rp) end
    end
end

function Dictionary:prefetch(html)
    local _, hrefs = Html.extractStylesheets(html)
    self._prefetched = self._prefetched or {}
    for _, href in ipairs(hrefs) do self:_prefetchCss(Html.resourcePath(href, ""), 0) end
    for _, ref in ipairs(Html.resourceRefs(html)) do self:resource(Html.resourcePath(ref, "")) end
    return self.res_dir
end

-- A stylesheet's text made ready for the page itself: comments dropped, local @imports
-- replaced by the sheets they name (MuPDF does not follow @import), and local url()s made
-- relative to the dictionary root, where the page resolves them, with what they name extracted.
-- base: the stylesheet's folder, relative to the root; stack: the sheets being inlined.
function Dictionary:_inlineCss(css, base, stack)
    css = css:gsub("^\239\187\191", ""):gsub("/%*.-%*/", ""):gsub("^%s*<!%-%-", ""):gsub("%-%->%s*$", "")
    -- imported sheets go in once this one's url()s are rewritten: theirs are relative to the root already
    local imported = {}
    local function import(ref)
        if not Html.isLocalRef(ref) then return nil end
        local p = Html.resourcePath(ref, base)
        local sheet = ""
        if not stack[p] and #stack < 4 then sheet = self:_staticSheet(p, stack) end
        imported[#imported + 1] = sheet
        return "\0" .. #imported .. "\0"
    end
    css = css:gsub("@[Ii][Mm][Pp][Oo][Rr][Tt]%s*[Uu][Rr][Ll]%(%s*['\"]?([^'\")]*)['\"]?%s*%)[^;]*;", import)
    css = css:gsub("@[Ii][Mm][Pp][Oo][Rr][Tt]%s*['\"]([^'\"]*)['\"][^;]*;", import)
    css = css:gsub("([Uu][Rr][Ll]%(%s*)['\"]?([^'\")]*)['\"]?%s*%)", function(pre, ref)
        if not Html.isLocalRef(ref) then return nil end
        local p = Html.resourcePath(ref, base)
        self:resource(p)
        return pre .. '"' .. p:gsub('[\\"]', "\\%0") .. '")'
    end)
    if #imported == 0 then return css end
    return (css:gsub("%z(%d+)%z", function(n) return imported[tonumber(n)] end))
end

function Dictionary:_staticSheet(p, stack)
    self._static_sheets = self._static_sheets or {}
    local css = self._static_sheets[p]
    if css then return css end
    local file = self:resource(p)
    css = file and fs.readAll(file) or ""
    stack[p] = true
    stack[#stack + 1] = p
    css = self:_inlineCss(css, p:match("^(.*)/[^/]*$") or "", stack)
    stack[p] = nil
    stack[#stack] = nil
    self._static_sheets[p] = css
    return css
end

--- CSS for KOReader's own renderer (MuPDF) to show an entry with: the entry's stylesheets and
-- <style> elements, then the override files' CSS (see userCss), or nil when there is none.
-- MuPDF reads stylesheets only from a page's <head>, and KOReader puts the entry in the
-- <body>, so they have to come this way. KOReader writes this CSS into one <style> element
-- after its own; each stylesheet gets an element of its own instead, because MuPDF drops the
-- whole element when it cannot parse something in it.
-- px: screen pixels for a CSS px (see Html.scaleLengths); 1 leaves lengths as they are.
function Dictionary:staticCss(html, px)
    px = px or 1
    local function scaled(css)
        if px == 1 then return css end
        return Html.scaleLengths(css, px)
    end
    self._scaled_sheets = self._scaled_sheets or {}
    local parts = {}
    for _, src in ipairs(Html.styleSources(html)) do
        local css = ""
        if not src.href then
            css = scaled(self:_inlineCss(src.text, "", {}))
        elseif Html.isLocalRef(src.href) then
            local p = Html.resourcePath(src.href, "")
            local c = self._scaled_sheets[p]
            if not (c and c.px == px) then
                c = { px = px, css = scaled(self:_staticSheet(p, {})) }
                self._scaled_sheets[p] = c
            end
            css = c.css
        end
        if css:find("%S") then parts[#parts + 1] = css end
    end
    local user = self:userCss()
    if user then parts[#parts + 1] = scaled(user) end
    if #parts == 0 then return nil end
    for i, css in ipairs(parts) do parts[i] = css:gsub("</", "<\\/") end
    return "\n</style><style>\n" .. table.concat(parts, "\n</style><style>\n") .. "\n"
end

--- Extra CSS for this dictionary from its override files (shared mdict.koreader.css files,
-- then <name>.koreader.css next to the .mdx), or nil when there is none.
function Dictionary:userCss()
    self._css_files = self._css_files or {}
    local parts = {}
    for _, path in ipairs(self:_overrideFiles(".css")) do
        local _, mtime = fs.stat(path)
        local c = self._css_files[path]
        if not c or c.mtime ~= mtime then
            c = { mtime = mtime, css = mtime and fs.readAll(path) or nil }
            self._css_files[path] = c
        end
        if c.css then parts[#parts + 1] = c.css end
    end
    return #parts > 0 and table.concat(parts, "\n") or nil
end

--- Stylesheet paths an entry links to.
function Dictionary:stylesheetsOf(html)
    local stripped, hrefs = Html.extractStylesheets(html)
    for i, h in ipairs(hrefs) do hrefs[i] = Html.resourcePath(h, "") end
    return hrefs, stripped
end

return Dictionary
