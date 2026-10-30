--[[--
Drives the pager in a WebView-like backend (the Android bridge, or the
Chromium bridge used on desktops and in tests) and turns it into pages.

A backend ("bridge") has: open(slot, w, h), load(slot, base, html, cache_root, files_json),
call(slot, id, op, args_json), poll(timeout_ms) -> json|nil, provide(rid, path),
capture(slot, id, ptr, w, h), close(slot), closeAll(), drain(), session(fn).

Each slot keeps one pager document loaded, so switching between the last few
dictionaries does not re-parse their stylesheets.
]]

local json = require("mdict/json")
local Document = require("renderers/document")

local WebRenderer = {}
WebRenderer.__index = WebRenderer

WebRenderer.MAX_SLOTS = 2
WebRenderer.LOAD_TIMEOUT = 8
WebRenderer.OP_TIMEOUT = 8
WebRenderer.CAPTURE_TIMEOUT = 4

local ffi = require("ffi")
-- KOReader's posix_h declares clock_gettime already; elsewhere declare it here
if not pcall(require, "ffi/posix_h") then
    pcall(ffi.cdef, "struct timespec { long tv_sec; long tv_nsec; };")
    pcall(ffi.cdef, "int clock_gettime(int clk_id, struct timespec *tp);")
end
local ts = ffi.new("struct timespec")
local function monotonic()
    ffi.C.clock_gettime(1, ts) -- CLOCK_MONOTONIC
    return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) / 1e9
end

WebRenderer.clock = monotonic

--- opts: bridge (required), resolve(dict_id, path) -> file path or nil,
--        logger (optional, with :dbg/:warn), max_slots
function WebRenderer.new(opts)
    local self = setmetatable({
        bridge = assert(opts.bridge, "bridge required"),
        resolve = opts.resolve or function() return nil end,
        logger = opts.logger,
        max_slots = opts.max_slots or WebRenderer.MAX_SLOTS,
        slots = {},
        next_id = 0,
        events = {},
        clock = 0,
    }, WebRenderer)
    return self
end

function WebRenderer:_log(level, ...)
    if self.logger and self.logger[level] then self.logger[level](self.logger, "MDict WebView:", ...) end
end

function WebRenderer:_nextId()
    self.next_id = self.next_id + 1
    return self.next_id
end

-- Handles one event; returns it when it is not a resource request.
function WebRenderer:_dispatch(raw)
    local ok, ev = pcall(json.decode, raw)
    if not ok or type(ev) ~= "table" then
        self:_log("warn", "bad event", raw)
        return nil
    end
    if ev.ev == "need" then
        local slot = self.slots[ev.slot]
        local file
        if slot and slot.dict_id then
            local rok, res = pcall(self.resolve, slot.dict_id, ev.path)
            if rok then file = res else self:_log("warn", "resolve failed", ev.path, res) end
        end
        self.bridge:provide(ev.rid, file or "")
        return nil
    end
    if ev.ev == "error" then
        self:_log("warn", "renderer error", ev.msg)
    end
    return ev
end

--- Waits for an event matching pred(ev), serving resource requests meanwhile.
-- Returns the event, or nil and "timeout".
function WebRenderer:_wait(pred, timeout)
    -- an event may already have arrived while waiting for another one
    for i, ev in ipairs(self.events) do
        if pred(ev) then
            table.remove(self.events, i)
            return ev
        end
    end
    local deadline = monotonic() + timeout
    return self.bridge:session(function()
        while true do
            local left = deadline - monotonic()
            if left <= 0 then return nil, "timeout" end
            local raw = self.bridge:poll(math.max(1, math.min(100, math.floor(left * 1000))))
            if raw then
                local ev = self:_dispatch(raw)
                if ev then
                    if pred(ev) then return ev end
                    if ev.ev == "error" and ev.fatal then return nil, ev.msg end
                    -- keep only events someone may still wait for
                    if #self.events < 32 then self.events[#self.events + 1] = ev end
                end
            end
        end
    end)
end

--- Runs a pager op on a slot and returns its result table (or nil, err).
function WebRenderer:op(slot_id, name, args, timeout)
    local id = self:_nextId()
    self.bridge:call(slot_id, id, name, json.encode(args or {}))
    local ev, err = self:_wait(function(e)
        return e.ev == "done" and e.id == id or e.ev == "error" and e.slot == slot_id and e.id == id
    end, timeout or WebRenderer.OP_TIMEOUT)
    if not ev then return nil, err end
    local r = ev.r
    if type(r) == "table" and r.error then return nil, r.error end
    if r == json.null then r = nil end
    return r
end

-- Picks a slot for a document key: the one holding it, a free one, or the least recently used.
function WebRenderer:_slotFor(key)
    self.clock = self.clock + 1
    local free, lru
    for id = 1, self.max_slots do
        local s = self.slots[id]
        if s and s.key == key then
            s.used = self.clock
            return s, true
        end
        if not s then
            free = free or id
        elseif not lru or s.used < lru.used then
            lru = s
        end
    end
    local s
    if free then
        s = { id = free }
        self.slots[free] = s
    else
        s = lru
    end
    s.key, s.used, s.ready = key, self.clock, false
    return s, false
end

--- Makes sure a slot of size w x h (device pixels) holds the document for this dictionary.
-- doc: { dict_id, cache_root, stylesheets, fonts, user_css, lang, font_aliases }
-- Returns the slot, or nil and an error.
function WebRenderer:document(doc, w, h)
    local html, key, files = Document.build(doc)
    key = doc.dict_id .. "\0" .. key
    local slot, cached = self:_slotFor(key)
    if not slot.w or slot.w ~= w or slot.h ~= h then
        self.bridge:open(slot.id, w, h)
        local ev, err = self:_wait(function(e) return e.ev == "opened" and e.slot == slot.id end, WebRenderer.LOAD_TIMEOUT)
        if not ev then
            self.slots[slot.id] = nil
            return nil, "open: " .. tostring(err)
        end
        slot.w, slot.h = w, h
    end
    if not (cached and slot.ready) then
        slot.dict_id = doc.dict_id
        slot.ready = false
        local file_map = {}
        for token, path in pairs(files) do file_map[token] = path end
        self.bridge:load(slot.id, "https://" .. doc.dict_id .. ".mdict.local/", html, doc.cache_root,
            json.encode(file_map))
        local ev, err = self:_wait(function(e) return e.ev == "loaded" and e.slot == slot.id end, WebRenderer.LOAD_TIMEOUT)
        if not ev then
            slot.key = nil
            return nil, "load: " .. tostring(err)
        end
        slot.ready = true
    end
    -- the viewport must have the requested size before laying out an entry
    for _ = 1, 20 do
        local r = self:op(slot.id, "ping", {}, 2)
        if r and math.abs(r.w * r.dpr - w) <= 2 and math.abs(r.h * r.dpr - h) <= 2 then
            slot.dpr = r.dpr
            return slot
        end
        local _, _ = self:_wait(function() return false end, 0.05)
    end
    return nil, "viewport size mismatch"
end

--- Lays out an entry. entry: { html, writing, pagination, anchor, zoom, eink, run_scripts, skip_scripts, clicks }
-- writing: "auto", "horizontal" or "vertical"; pagination: "auto", "columns" or "slices";
-- clicks: element paths from tap() to activate again (sections the reader opened).
-- Returns { pages, vertical, mode, anchorPage, width, height } or nil, err.
function WebRenderer:setEntry(slot, entry)
    local r, err = self:op(slot.id, "setEntry", {
        html = entry.html,
        writing = entry.writing or "auto",
        pagination = entry.pagination or "auto",
        clicks = json.array(entry.clicks),
        anchor = entry.anchor,
        zoom = entry.zoom or 1,
        eink = entry.eink and true or false,
        runScripts = entry.run_scripts ~= false,
        skipScripts = entry.skip_scripts or {},
    }, WebRenderer.OP_TIMEOUT)
    if r then slot.pages, slot.page = r.pages, nil end
    return r, err
end

--- Shows page n (0-based) and draws it into ptr (w*h RGBA). Returns true or nil, err.
function WebRenderer:renderPage(slot, n, ptr)
    if slot.page ~= n then
        local r, err = self:op(slot.id, "showPage", { page = n })
        if not r then return nil, err end
        slot.page = r.page
    end
    local id = self:_nextId()
    self.bridge:capture(slot.id, id, ptr, slot.w, slot.h)
    local ev, err = self:_wait(function(e) return e.ev == "captured" and e.id == id end, WebRenderer.CAPTURE_TIMEOUT)
    if not ev then return nil, err end
    if not ev.ok then return nil, "capture failed" end
    return true
end

function WebRenderer:links(slot) return self:op(slot.id, "links") end
function WebRenderer:textAt(slot, x0, y0, x1, y1) return self:op(slot.id, "textAt", { x0 = x0, y0 = y0, x1 = x1, y1 = y1 }) end
function WebRenderer:find(slot, term) return self:op(slot.id, "find", { term = term }) end
function WebRenderer:pageOfAnchor(slot, id) return self:op(slot.id, "pageOfAnchor", { id = id }) end

--- A tap at (x, y) on the shown page that is not on a link. Returns { handled = false } when it
-- did nothing, or { handled, path, pages, page } when it changed the entry (which is laid out again).
function WebRenderer:tap(slot, x, y)
    local r, err = self:op(slot.id, "tap", { x = x, y = y })
    if r and r.handled then slot.pages, slot.page = r.pages, r.page end
    return r, err
end

--- Forgets cached documents (e.g. after settings changed).
function WebRenderer:invalidate()
    for _, s in pairs(self.slots) do s.key, s.ready = nil, false end
end

function WebRenderer:close()
    pcall(function() self.bridge:closeAll() end)
    self.slots = {}
    self.events = {}
end

return WebRenderer
