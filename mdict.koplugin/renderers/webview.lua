--[[--
Drives the pager in a WebView-like backend (the Android bridge, or the
Chromium bridge used on desktops and in tests) and turns it into pages.

A backend ("bridge") has: open(slot, w, h), load(slot, base, html, cache_root, files_json),
call(slot, id, op, args_json), poll(timeout_ms) -> json|nil, provide(rid, path),
capture(slot, id, ptr, w, h), close(slot), closeAll(), drain(), session(fn).

Each slot keeps one pager document loaded, so switching between the last few
dictionaries does not re-parse their stylesheets.

Work can also run as a background job (startJob): a coroutine whose waits for the
WebView yield instead of blocking, resumed by KOReader's scheduler, so the next
dictionary result can be laid out while the reader looks at the current one.
]]

local json = require("mdict/json")
local Document = require("renderers/document")

local WebRenderer = {}
WebRenderer.__index = WebRenderer

WebRenderer.MAX_SLOTS = 3
WebRenderer.JOB_STEP = 0.02 -- seconds between the steps of a background job
WebRenderer.CANCELLED = "cancelled"
WebRenderer.LOAD_TIMEOUT = 8
WebRenderer.OP_TIMEOUT = 8
WebRenderer.CAPTURE_TIMEOUT = 6 -- more than the Java side waits (3 s): the page memory must outlive it

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
--        logger (optional, with :dbg/:warn), max_slots,
--        schedule(seconds, fn) and unschedule(fn) for background jobs
function WebRenderer.new(opts)
    local self = setmetatable({
        bridge = assert(opts.bridge, "bridge required"),
        resolve = opts.resolve or function() return nil end,
        logger = opts.logger,
        max_slots = opts.max_slots or WebRenderer.MAX_SLOTS,
        schedule = opts.schedule,
        unschedule = opts.unschedule,
        slots = {},
        next_id = 0,
        events = {},
        jobs = {}, -- coroutine -> job
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
        local t0 = monotonic()
        if slot and slot.dict_id then
            local rok, res = pcall(self.resolve, slot.dict_id, ev.path)
            if rok then file = res else self:_log("warn", "resolve failed", ev.path, res) end
        end
        self.bridge:provide(ev.rid, file or "")
        if slot and slot.trace then
            slot.trace.needs = (slot.trace.needs or 0) + 1
            slot.trace.need_ms = (slot.trace.need_ms or 0) + (monotonic() - t0) * 1000
        end
        return nil
    end
    if ev.ev == "error" then
        self:_log("warn", "renderer error", ev.msg)
    end
    return ev
end

-- An event that arrived while waiting for another one.
function WebRenderer:_stored(pred)
    for i, ev in ipairs(self.events) do
        if pred(ev) then
            table.remove(self.events, i)
            return ev
        end
    end
end

-- Handles one raw event for _wait: returns it when it is the awaited one,
-- or nil and an error for a fatal one. Others are kept for whoever waits for them.
function WebRenderer:_offer(raw, pred)
    local ev = self:_dispatch(raw)
    if not ev then return nil end
    if pred(ev) then return ev end
    if ev.ev == "error" and ev.fatal then return nil, ev.msg end
    if #self.events < 64 then self.events[#self.events + 1] = ev end
    return nil
end

--- The background job running this code, if any.
function WebRenderer:_job()
    local co = coroutine.running()
    return co and self.jobs[co] or nil
end

--- Waits for an event matching pred(ev), serving resource requests meanwhile.
-- Returns the event, or nil and "timeout". In a background job, it yields between
-- polls (and raises CANCELLED once the job is cancelled and nothing is pending).
function WebRenderer:_wait(pred, timeout)
    local deadline = monotonic() + timeout
    local job = self:_job()
    local function result(ev, err)
        if job and job.cancelled then error(WebRenderer.CANCELLED, 0) end
        return ev, err
    end
    local stored = self:_stored(pred)
    if stored then return result(stored) end
    while job and not job.sync do
        local ev, err = self.bridge:session(function()
            while true do
                local raw = self.bridge:poll(0)
                if not raw then return nil end
                local e, fatal = self:_offer(raw, pred)
                if e or fatal then return e, fatal end
            end
        end)
        if ev or err then return result(ev, err) end
        if monotonic() >= deadline then return result(nil, "timeout") end
        coroutine.yield()
        stored = self:_stored(pred)
        if stored then return result(stored) end
    end
    return result(self.bridge:session(function()
        while true do
            local left = deadline - monotonic()
            if left <= 0 then return nil, "timeout" end
            local raw = self.bridge:poll(math.max(1, math.min(100, math.floor(left * 1000))))
            if raw then
                local ev, err = self:_offer(raw, pred)
                if ev or err then return ev, err end
            end
        end
    end))
end

--- Runs fn(job) as a background job, first after `delay` seconds. on_done(job) is called
-- when it ends, with job.ok and job.result (fn's first result) or job.err.
function WebRenderer:startJob(fn, on_done, delay)
    assert(self.schedule, "no scheduler for background jobs")
    local job = { on_done = on_done }
    job.co = coroutine.create(function() return fn(job) end)
    self.jobs[job.co] = job
    job.step = function()
        job.scheduled = false
        self:_resume(job)
        if not job.done then
            job.scheduled = true
            self.schedule(WebRenderer.JOB_STEP, job.step)
        end
    end
    job.scheduled = true
    self.schedule(delay or 0, job.step)
    return job
end

function WebRenderer:_resume(job)
    local ok, res, err = coroutine.resume(job.co)
    if coroutine.status(job.co) ~= "dead" then return end
    job.done = true
    self.jobs[job.co] = nil
    for _, s in pairs(self.slots) do
        if s.job == job then s.job = nil end
    end
    if ok then
        job.ok, job.result, job.err = true, res, err
    else
        job.ok, job.err = false, res
        if res ~= WebRenderer.CANCELLED then self:_log("warn", "background job failed:", res) end
    end
    if job.on_done then job.on_done(job) end
end

--- Runs a job to its end now (blocking), e.g. when its result is wanted. Returns the job.
function WebRenderer:finishJob(job)
    if job.done then return job end
    if job.scheduled and self.unschedule then
        self.unschedule(job.step)
        job.scheduled = false
    end
    job.sync = true
    while not job.done do self:_resume(job) end
    return job
end

--- Stops a job at its next step: it raises CANCELLED once nothing it asked for is pending.
function WebRenderer:cancelJob(job)
    if not job.done then job.cancelled = true end
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

-- How readily a slot is reused: the least recently used first, a slot holding a page
-- laid out ahead (a prefetched result) last.
local function age(s) return s.used + (s.held and 1e9 or 0) end

-- Picks a slot for a document key: the one holding it, a free one, or the least recently used.
-- Slots in `avoid` (ids) and slots another job is using are left alone.
function WebRenderer:_slotFor(key, avoid)
    self.clock = self.clock + 1
    local job = self:_job()
    local free, lru, any
    for id = 1, self.max_slots do
        local s = self.slots[id]
        if not (s and s.job and s.job ~= job) and not (avoid and avoid[id]) then
            if s and s.key == key then
                s.used = self.clock
                s.job = job
                return s, true
            end
            if not s then
                free = free or id
            elseif not lru or age(s) < age(lru) then
                lru = s
            end
        elseif s and (not any or age(s) < age(any)) and not (s.job and s.job ~= job) then
            any = s
        end
    end
    local s
    if free then
        s = { id = free }
        self.slots[free] = s
    else
        s = lru or any
        if not s then return nil end
    end
    s.key, s.used, s.ready, s.held = key, self.clock, false, nil
    s.job = job
    return s, false
end

-- Milliseconds since t0 (from monotonic()).
local function ms(t0) return math.floor((monotonic() - t0) * 1000 + 0.5) end

--- Makes sure a slot of size w x h (device pixels) holds the document for this dictionary.
-- doc: { dict_id, cache_root, stylesheets, fonts, user_css, lang, font_aliases }
-- avoid: slot ids not to use (the one a shown entry is in).
-- Returns the slot, or nil and an error. slot.trace collects timings until the entry is shown.
function WebRenderer:document(doc, w, h, avoid)
    local t0 = monotonic()
    local html, key, files = Document.build(doc)
    key = doc.dict_id .. "\0" .. key
    local slot, cached = self:_slotFor(key, avoid)
    if not slot then return nil, "no free slot" end
    slot.trace = { doc = 0 }
    if not slot.w or slot.w ~= w or slot.h ~= h then
        local t = monotonic()
        self.bridge:open(slot.id, w, h)
        local ev, err = self:_wait(function(e) return e.ev == "opened" and e.slot == slot.id end, WebRenderer.LOAD_TIMEOUT)
        if not ev then
            self.slots[slot.id] = nil
            return nil, "open: " .. tostring(err)
        end
        slot.w, slot.h = w, h
        slot.trace.open = ms(t)
    end
    if not (cached and slot.ready) then
        local t = monotonic()
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
        slot.trace.load = ms(t)
    end
    -- the viewport must have the requested size before laying out an entry
    local t = monotonic()
    for _ = 1, 20 do
        local r = self:op(slot.id, "ping", {}, 2)
        if r and math.abs(r.w * r.dpr - w) <= 2 and math.abs(r.h * r.dpr - h) <= 2 then
            slot.dpr = r.dpr
            slot.trace.ping = ms(t)
            slot.trace.doc = ms(t0)
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
    local t0 = monotonic()
    local r, err = self:op(slot.id, "setEntry", {
        html = entry.html,
        writing = entry.writing or "auto",
        pagination = entry.pagination or "auto",
        clicks = json.array(entry.clicks),
        anchor = entry.anchor,
        zoom = entry.zoom or 1,
        eink = entry.eink and true or false,
        runScripts = entry.run_scripts ~= false,
        skipScripts = json.array(entry.skip_scripts),
    }, WebRenderer.OP_TIMEOUT)
    if r then slot.pages, slot.page = r.pages, nil end
    if slot.trace then
        slot.trace.entry = (slot.trace.entry or 0) + ms(t0)
        slot.trace.entry_js = r and r.ms
        slot.trace.layouts = (slot.trace.layouts or 0) + 1
    end
    return r, err
end

--- Shows page n (0-based) and draws it into ptr (w*h RGBA). Returns true or nil, err.
-- Returns true or nil, err; with timings, a third result: { show, capture, wait, draw } in ms.
function WebRenderer:renderPage(slot, n, ptr)
    local t0 = monotonic()
    local timing = {}
    if slot.page ~= n then
        local r, err = self:op(slot.id, "showPage", { page = n })
        if not r then return nil, err end
        slot.page = r.page
    end
    timing.show = ms(t0)
    local t = monotonic()
    local id = self:_nextId()
    self.bridge:capture(slot.id, id, ptr, slot.w, slot.h)
    local ev, err = self:_wait(function(e) return e.ev == "captured" and e.id == id end, WebRenderer.CAPTURE_TIMEOUT)
    if not ev then return nil, err end
    if not ev.ok then return nil, "capture failed" end
    timing.capture, timing.wait, timing.draw, timing.via = ms(t), ev.wait, ev.draw, ev.via
    return true, nil, timing
end

function WebRenderer:links(slot) return self:op(slot.id, "links") end
function WebRenderer:textAt(slot, x0, y0, x1, y1) return self:op(slot.id, "textAt", { x0 = x0, y0 = y0, x1 = x1, y1 = y1 }) end
function WebRenderer:find(slot, term) return self:op(slot.id, "find", { term = term }) end
function WebRenderer:pageOfAnchor(slot, id) return self:op(slot.id, "pageOfAnchor", { id = id }) end

--- A tap at (x, y) on the shown page. Returns { handled = false } when it did nothing,
-- { handled, same = true } when it was taken but changed nothing, or { handled, path, pages,
-- page } when it changed the entry (which is laid out again). With link, the tap is on a link
-- and is handled only when one of the entry's scripts takes it over.
function WebRenderer:tap(slot, x, y, link)
    local r, err = self:op(slot.id, "tap", { x = x, y = y, link = link or nil })
    if r and r.handled and not r.same then slot.pages, slot.page = r.pages, r.page end
    if r and r.ms then self:_log("dbg", "tap", json.encode(r.ms)) end
    return r, err
end

--- Forgets cached documents (e.g. after settings changed).
function WebRenderer:invalidate()
    for _, s in pairs(self.slots) do s.key, s.ready, s.held = nil, false, nil end
end

function WebRenderer:close()
    for _, job in pairs(self.jobs) do
        job.cancelled = true
        if job.scheduled and self.unschedule then self.unschedule(job.step) end
    end
    self.jobs = {}
    pcall(function() self.bridge:closeAll() end)
    self.slots = {}
    self.events = {}
end

return WebRenderer
