--[[--
HtmlBoxWidget whose pages come from the WebView pager instead of MuPDF.

It keeps HtmlBoxWidget's interface (page_number, page_count, setPageNumber,
_render, freeBb, getLinkByPosition, updateHighlight, findText...), so
ScrollHtmlWidget and DictQuickLookup drive it unchanged. Coordinates from the
pager are device pixels relative to the box, as KOReader's are.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local HtmlBoxWidget = require("ui/widget/htmlboxwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local WebHtmlBoxWidget = HtmlBoxWidget:extend{
    renderer = nil, -- WebRenderer
    slot = nil, -- renderer slot holding this dictionary's document
    vertical = false,
    anchor_page = nil,
    page_cache_size = 3,
    avoid_slots = nil, -- renderer slot ids not to use (the shown entry's, when laying out ahead)
    label = nil, -- for the timing log
    background = false, -- laid out ahead, by a background job
    grey_pages = false, -- pages kept in 8-bit grey (a grey e-ink screen): a quarter of the memory
}

function WebHtmlBoxWidget:init()
    HtmlBoxWidget.init(self)
    self.page_cache = {}
    self.page_order = {}
    self.page_stale = {}
    self.links_cache = {}
end

--- Lays out an entry. doc: renderer document options; entry: { html, anchor, zoom, eink, writing }.
-- Returns true, or nil and an error (the caller then falls back to MuPDF).
function WebHtmlBoxWidget:loadEntry(doc, entry)
    self.doc, self.entry = doc, entry
    local ok, err = self:_layout()
    if not ok then return nil, err end
    self.page_number = self.anchor_page or 1
    self.shown_page, self.turn_step = nil, nil
    self:_dropPages()
    return true
end

-- Slots other popups still show are left alone when there is another: a nested popup
-- taking one would make the popup under it lay its entry out again (seconds for a long
-- entry) when the reader goes back to it and taps a link.
function WebHtmlBoxWidget:_avoid()
    local avoid = {}
    for id in pairs(self.avoid_slots or {}) do avoid[id] = true end
    for id, s in pairs(self.renderer.slots or {}) do
        local o = s.owner
        if o and o ~= self and not o.freed and not o.background then avoid[id] = true end
    end
    return avoid
end

function WebHtmlBoxWidget:_layout()
    local slot, err = self.renderer:document(self.doc, self.dimen.w, self.dimen.h, self:_avoid())
    if not slot then return nil, err end
    local info
    info, err = self.renderer:setEntry(slot, self.entry)
    if not info then
        -- (the pager may still be busy with it: the next use loads the document again)
        slot.key, slot.ready = nil, false
        return nil, err
    end
    self.trace = self.trace or slot.trace
    slot.owner = self
    self.slot, self.slot_key = slot, slot.key
    self.page_count = math.max(1, info.pages or 1)
    self.vertical = info.vertical and true or false
    self.mode = info.mode -- "columns" or "slices"
    self.anchor_page = info.anchorPage and info.anchorPage >= 0 and info.anchorPage + 1 or nil
    self.scripts = info.scripts -- the entry's scripts may want taps on links
    return true
end

-- The pager is shared: another popup (a nested lookup) may have laid out
-- another entry since, or the slot may hold another dictionary now.
function WebHtmlBoxWidget:_ensure()
    -- the next page may be being drawn in the background: let it finish first
    local job = self.page_job
    if job and not job.done and self.renderer:_job() ~= job then self.renderer:finishJob(job) end
    if self.slot and self.slot.owner == self and self.slot.key == self.slot_key then return true end
    local ok, err = self:_layout()
    if not ok then logger.warn("MDict: cannot restore entry:", err) end
    return ok
end

function WebHtmlBoxWidget:_dropPages()
    for _, bb in pairs(self.page_cache) do bb:free() end
    self.page_cache, self.page_order, self.page_stale = {}, {}, {}
    self.links_cache = {}
    self.find_index = nil
end

-- Pages are kept by last use: turning back and forth stays on cached pages.
local function touch(order, n)
    for i = #order, 1, -1 do
        if order[i] == n then
            table.remove(order, i)
            break
        end
    end
    order[#order + 1] = n
end

function WebHtmlBoxWidget:_pageBb(n)
    local bb = self.page_cache[n]
    if bb and not self.page_stale[n] then
        touch(self.page_order, n)
        return bb
    end
    local ok, err = self:_ensure()
    -- (the background job _ensure let finish may have drawn it)
    bb = self.page_cache[n]
    if bb and not self.page_stale[n] then return bb end
    local cached = bb ~= nil
    if cached then logger.info("MDict: drawing page", n, "again: it was captured before the WebView had drawn it") end
    bb = bb or Blitbuffer.new(self.dimen.w, self.dimen.h, self.grey_pages and Blitbuffer.TYPE_BB8 or Blitbuffer.TYPE_BBRGB32)
    local timing
    if ok then
        -- renderers draw RGBA; a grey page gets it through a buffer of its own while drawn
        local target = bb
        if self.grey_pages then
            target = Blitbuffer.new(self.dimen.w, self.dimen.h, Blitbuffer.TYPE_BBRGB32)
        end
        ok, err, timing = self.renderer:renderPage(self.slot, n - 1, target.data)
        if target ~= bb then
            if ok then bb:blitFrom(target, 0, 0, 0, 0, self.dimen.w, self.dimen.h) end
            target:free()
        end
    end
    if not ok then
        logger.warn("MDict: page render failed:", err)
        bb:fill(Blitbuffer.COLOR_WHITE)
    elseif self.trace and not self.trace.logged then
        self.trace.logged = true
        logger.info(self:_timingText(timing))
        -- the Kindle's: what the kernel said about the screen since the last entry (a moment
        -- later, so that the page is not held up)
        local bridge = self.renderer and self.renderer.bridge
        if bridge and bridge.screenNote then
            UIManager:scheduleIn(2, function()
                local screen = bridge.screenNote()
                if screen then logger.info("MDict: kernel e-ink messages: " .. screen) end
            end)
        end
    end
    -- captured before the WebView had drawn the page (after a picture viewer closes, that
    -- can take seconds on e-readers): shown if it is wanted now, and drawn again
    self.page_stale[n] = ok and timing and timing.via == "timeout" or nil
    touch(self.page_order, n)
    if cached then return bb end
    self.page_cache[n] = bb
    while #self.page_order > self.page_cache_size do
        local old = table.remove(self.page_order, 1)
        if old ~= n and self.page_cache[old] then
            self.page_cache[old]:free()
            self.page_cache[old], self.page_stale[old] = nil, nil
        end
    end
    return bb
end

function WebHtmlBoxWidget:_render()
    if self.bb then return end
    local n = self.page_number
    -- the way the reader turns pages
    if self.shown_page and n ~= self.shown_page then self.turn_step = n < self.shown_page and -1 or 1 end
    self.shown_page = n
    local page = self:_pageBb(n)
    -- the cached page stays clean; highlights go on a copy
    self.bb = page:copy()
    if self.highlight_text_selection and self.highlight_rects then
        for _, rect in ipairs(self.highlight_rects) do
            self.bb:darkenRect(rect.x, rect.y, rect.w, rect.h, self.highlight_lighten_factor)
        end
    end
    -- render the next page (in the way the reader turns) while the reader looks at this one
    local function next_page()
        local nxt = self.page_number + (self.turn_step or 1)
        if not self.freed and nxt >= 1 and nxt <= self.page_count and (not self.page_cache[nxt] or self.page_stale[nxt])
                and self.slot and self.slot.owner == self then
            self:_pageBb(nxt)
        end
    end
    if self.renderer.schedule then
        -- in the background, so taps meanwhile are not held up; a page shown before the
        -- WebView had drawn it is drawn again first
        if not (self.page_job and not self.page_job.done) then
            local stale, shown = self.page_stale[n], self.bb
            local job
            job = self.renderer:startJob(function()
                if stale then return self:_redraw(n) end
                next_page()
            end, function()
                if self.page_job == job then self.page_job = nil end
                if not (stale and job.ok and job.result) then return end
                -- shown after whatever let the job finish is done
                UIManager:nextTick(function()
                    if self.freed or self.bb ~= shown or self.page_number ~= n then return end
                    self:freeBb()
                    self:_render()
                    UIManager:setDirty(self.dialog, function() return "partial", self.dimen end)
                end)
            end, stale and 0.5 or 0.3)
            self.page_job = job
        end
    elseif not self._prefetch then
        self._prefetch = function()
            self._prefetch = nil
            next_page()
        end
        UIManager:scheduleIn(0.3, self._prefetch)
    end
end

-- Draws shown page n again after it was captured too early. True once it is right.
function WebHtmlBoxWidget:_redraw(n)
    for _ = 1, 2 do
        if self.freed or self.page_number ~= n or not self.page_stale[n] then return false end
        self:_pageBb(n)
        if not self.page_stale[n] then return true end
    end
    return false
end

local function marks(t)
    if type(t) ~= "table" then return "" end
    local keys = {}
    for k, v in pairs(t) do
        if k ~= "total" and type(v) == "number" and v > 0 then keys[#keys + 1] = k end
    end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = k .. " " .. t[k] end
    return #parts > 0 and " [" .. table.concat(parts, ", ") .. "]" or ""
end

-- One log line on where the time to show an entry went (milliseconds).
function WebHtmlBoxWidget:_timingText(page)
    local t = self.trace
    local doc = {}
    for _, k in ipairs({ "open", "load", "ping" }) do
        if t[k] then doc[#doc + 1] = k .. " " .. t[k] end
    end
    -- (the pager's own total for the entry: the rest of `entry` is the WebView's other work,
    -- such as styling a new document, before the pager gets to run)
    local js = type(t.entry_js) == "table" and tonumber(t.entry_js.total)
    local inner = {}
    if js then inner[#inner + 1] = "pager " .. js end
    if t.entry_queued then inner[#inner + 1] = "queued " .. t.entry_queued end
    local text = string.format("MDict: %s laid out in %d ms%s: document %d%s, entry %d%s%s",
        self.label or "entry", t.total or 0, self.background and " (ahead)" or "",
        t.doc or 0, #doc > 0 and " (" .. table.concat(doc, ", ") .. ")" or "",
        t.entry or 0, #inner > 0 and " (" .. table.concat(inner, ", ") .. ")" or "", marks(t.entry_js))
    if t.needs then
        text = text .. string.format(", %d resources in %.0f", t.needs, t.need_ms or 0)
    end
    if (t.layouts or 1) > 1 then text = text .. ", laid out twice" end
    if page then
        text = text .. string.format("; page 1 in %d (show %d, capture %d: waited %s %s, drew %s)",
            page.show + page.capture, page.show, page.capture, tostring(page.wait), tostring(page.via),
            tostring(page.draw))
    end
    -- the Kindle's: how much memory is left
    local bridge = self.renderer and self.renderer.bridge
    local note = bridge and bridge.memoryNote and bridge.memoryNote()
    if note then text = text .. "; memory " .. note end
    return text
end

function WebHtmlBoxWidget:getSinglePageHeight()
    return nil
end

--- Stops drawing pages ahead (the widget is put aside, its pages kept).
function WebHtmlBoxWidget:stopWork()
    self:freeBb()
    if self._prefetch then
        UIManager:unschedule(self._prefetch)
        self._prefetch = nil
    end
    if self.page_job then
        self.renderer:cancelJob(self.page_job)
        self.page_job = nil
    end
end

function WebHtmlBoxWidget:free()
    self:_unscheduleSound()
    self.sound = nil
    self:stopWork()
    self:_dropPages()
    self.freed = true
end

-- links ------------------------------------------------------------------------

function WebHtmlBoxWidget:_links()
    local n = self.page_number
    if not self.links_cache[n] then
        if not self:_ensure() then return {} end
        local ok = self.renderer:op(self.slot.id, "showPage", { page = n - 1 })
        self.slot.page = ok and ok.page or nil
        local links, err = self.renderer:links(self.slot)
        if not links then
            -- not kept: a page whose links could not be read once would ignore taps on them
            logger.warn("MDict: cannot read the links of page", n, err)
            return {}
        end
        self.links_cache[n] = links
    end
    return self.links_cache[n]
end

function WebHtmlBoxWidget:getLinkByPosition(pos)
    for _, link in ipairs(self:_links()) do
        if pos.x >= link.x0 and pos.x < link.x1 and pos.y >= link.y0 and pos.y < link.y1 then
            return link
        end
    end
end

function WebHtmlBoxWidget:onTapText(arg, ges)
    local pos = self:getPosFromAbsPos(ges.pos)
    if not pos then
        logger.info("MDict: tap outside the entry at", ges.pos.x, ges.pos.y)
        return
    end
    if not G_reader_settings:isFalse("tap_to_follow_links") then
        local link = self:getLinkByPosition(pos)
        -- (for reports of taps that missed: where it was, and what the page's links are)
        logger.info(string.format("MDict: tap at %d,%d on page %d: %s", math.floor(pos.x), math.floor(pos.y), self.page_number,
            link and ("link " .. tostring(link.uri))
            or ("no link (" .. #(self.links_cache[self.page_number] or {}) .. " on the page)")))
        if link then
            -- a place in the same entry (bword://#x: one written as entry://#x elsewhere)
            local anchor = link.uri and (link.uri:match("^#(.+)$") or link.uri:match("^bword://#(.+)$"))
            if anchor then
                -- a script of the entry may take the link over (a button that also opens its section)
                if self.scripts and self:_tapEntry(pos, true) then return true end
                local r = self:_ensure() and self.renderer:pageOfAnchor(self.slot, anchor)
                if r and r.page and r.page >= 0 and self.on_page_jump then
                    self.on_page_jump(r.page + 1)
                end
                return true
            end
            -- a script of the entry may take the link over (a picture that opens a viewer)
            if self.scripts and self:_tapEntry(pos, true) then return true end
            if self.html_link_tapped_callback then
                self.html_link_tapped_callback(link)
                return true
            end
        end
    end
    return self:_tapEntry(pos)
end

-- A tap on something interactive in the entry (an expandable section): the
-- pager activates it and lays the entry out again. Other taps turn pages.
-- With link, the tap is on a link, and only taken when a script of the entry wants it.
function WebHtmlBoxWidget:_tapEntry(pos, link)
    if not self:_ensure() then return end
    if self.slot.page ~= self.page_number - 1 then
        local r = self.renderer:op(self.slot.id, "showPage", { page = self.page_number - 1 })
        self.slot.page = r and r.page or nil
    end
    local res = self.renderer:tap(self.slot, math.floor(pos.x), math.floor(pos.y), link)
    if not (res and res.handled) then return end
    if res.stop then
        -- the player drawn playing: its sound stops
        local bridge = self.renderer.bridge
        if bridge.stopAudio then bridge:stopAudio() end
        self:_endSound(true, res.box)
        return true
    end
    local sounds = type(res.sounds) == "table" and res.sounds or {}
    if sounds[1] and self.html_link_tapped_callback then
        -- a sound the entry plays (an audio player, or a button whose script plays one): played
        -- as a sound:// link is, from the first of its sources there is
        local before = self:_audioState()
        self.html_link_tapped_callback({ uri = "mdict-sound://" .. sounds[1], sources = sounds })
        if res.player then self:_soundStarted(before and before.serial or 0, res.box) end
    end
    if res.same then return true end
    if res.jump then
        -- a script jumped to another part of the entry: the pages stay as they are
        if res.page and res.page >= 0 and self.on_page_jump then self.on_page_jump(res.page + 1) end
        return true
    end
    if res.path then
        self.entry.clicks = self.entry.clicks or {}
        table.insert(self.entry.clicks, res.path)
    end
    self:_dropPages()
    self.page_count = math.max(1, res.pages or 1)
    self.anchor_page = nil
    self:clearHighlight()
    self.page_number = (res.page or 0) + 1
    if self.on_relayout then
        self.on_relayout()
    else
        self:freeBb()
        self:_render()
        UIManager:setDirty(self.dialog, function() return "partial", self.dimen end)
    end
    return true
end

-- sounds -------------------------------------------------------------------------
-- An audio player of the entry plays its sound through KOReader (see Manager.playSound).
-- Meanwhile the pager draws it playing, with a stop button and the progress, and the page is
-- drawn again every SOUND_TICK seconds, the screen refreshing the player's box only.

WebHtmlBoxWidget.SOUND_TICK = 1
-- ticks to wait for a sound to start (it may be downloaded first, or wait for Wi-Fi)
WebHtmlBoxWidget.SOUND_START_TICKS = 15

function WebHtmlBoxWidget:_audioState()
    local bridge = self.renderer and self.renderer.bridge
    if not (bridge and bridge.audioState) then return nil end
    local ok, st = pcall(bridge.audioState, bridge)
    return ok and st or nil
end

-- Whether the popup shows this widget.
function WebHtmlBoxWidget:_shown()
    local shw = not self.freed and self.dialog and self.dialog.shw_widget
    return shw and shw.htmlbox_widget == self or false
end

-- The pager holds this widget's entry, showing its current page.
function WebHtmlBoxWidget:_holdsEntry()
    if not (self.slot and self.slot.owner == self and self.slot.key == self.slot_key) then return false end
    if not self:_ensure() then return false end
    if self.slot.page ~= self.page_number - 1 then
        local r = self.renderer:op(self.slot.id, "showPage", { page = self.page_number - 1 })
        self.slot.page = r and r.page or nil
    end
    return true
end

-- Draws the shown page again and refreshes box (device pixels in the page), or all of it.
function WebHtmlBoxWidget:_redrawShown(box)
    local n = self.page_number
    if self.page_cache[n] then
        self.page_cache[n]:free()
        self.page_cache[n], self.page_stale[n] = nil, nil
    end
    self:freeBb()
    self:_render()
    local d = self.dimen
    local region = d
    if box and d.x and d.y then
        local pad = 4
        local x0, y0 = math.max(0, box.x0 - pad), math.max(0, box.y0 - pad)
        local x1, y1 = math.min(d.w, box.x1 + pad), math.min(d.h, box.y1 + pad)
        if x1 > x0 and y1 > y0 then region = Geom:new{ x = d.x + x0, y = d.y + y0, w = x1 - x0, h = y1 - y0 } end
    end
    UIManager:setDirty(self.dialog, function() return "ui", region end)
end

function WebHtmlBoxWidget:_soundStarted(after, box)
    self:_unscheduleSound()
    self.sound = { after = after, ticks = 0, box = box }
    -- the player drawn playing at once
    if self:_shown() then self:_redrawShown(box) end
    self:_scheduleSound()
end

function WebHtmlBoxWidget:_scheduleSound()
    self._sound_tick = function() self:_soundTick() end
    UIManager:scheduleIn(WebHtmlBoxWidget.SOUND_TICK, self._sound_tick)
end

function WebHtmlBoxWidget:_unscheduleSound()
    if self._sound_tick then
        UIManager:unschedule(self._sound_tick)
        self._sound_tick = nil
    end
end

function WebHtmlBoxWidget:_soundTick()
    self._sound_tick = nil
    local s = self.sound
    if not s or self.freed then return end
    -- the reader went to another result or closed the popup (which stopped the sound)
    if not self:_shown() then return self:_endSound(false) end
    local st = self:_audioState()
    if st and not s.serial and st.serial > s.after then s.serial = st.serial end
    s.ticks = s.ticks + 1
    local on
    if s.serial then
        on = st.serial == s.serial and st.status ~= 0
    else
        on = s.ticks <= WebHtmlBoxWidget.SOUND_START_TICKS
    end
    if not on then return self:_endSound(true, s.box) end
    if self:_holdsEntry() then
        local playing = s.serial and st.status == 2
        local r = self.renderer:op(self.slot.id, "player",
            { playing = true, pos = playing and st.pos or 0, dur = playing and st.dur or 0 })
        if r and r.box then s.box = r.box end
        self:_redrawShown(r and r.box)
    end
    self:_scheduleSound()
end

--- The player is no longer drawn playing (its sound ended or was stopped). Pages captured with
-- it drawn are dropped; the shown one is drawn again when redraw is true.
function WebHtmlBoxWidget:_endSound(redraw, box)
    self:_unscheduleSound()
    self.sound = nil
    local holds = self:_holdsEntry()
    if holds then
        local r = self.renderer:op(self.slot.id, "player", { playing = false })
        box = box or (r and r.box)
    end
    redraw = redraw and holds and self:_shown()
    for n, bb in pairs(self.page_cache) do
        if not (redraw and n == self.page_number) then
            bb:free()
            self.page_cache[n], self.page_stale[n] = nil, nil
        end
    end
    self.links_cache = {}
    if redraw then
        self:_redrawShown(box)
    else
        self:freeBb()
    end
end

-- text selection -----------------------------------------------------------------

local function to_rects(list)
    local rects = {}
    for _, r in ipairs(list or {}) do
        rects[#rects + 1] = Geom:new{ x = r.x0, y = r.y0, w = r.x1 - r.x0, h = r.y1 - r.y0 }
    end
    return rects
end

function WebHtmlBoxWidget:updateHighlight()
    if self.hold_start_pos and self.hold_end_pos and self:_ensure() then
        if self.slot.page ~= self.page_number - 1 then
            local r = self.renderer:op(self.slot.id, "showPage", { page = self.page_number - 1 })
            self.slot.page = r and r.page or nil
        end
        local s, e = self.hold_start_pos, self.hold_end_pos
        local res = self.renderer:textAt(self.slot, math.floor(s.x), math.floor(s.y), math.floor(e.x), math.floor(e.y))
        local text = res and res.text or ""
        if text == "" then text = nil end
        local rects = text and to_rects(res.rects) or nil
        local changed = text ~= self.highlight_text or #(rects or {}) ~= #(self.highlight_rects or {})
        self.highlight_rects, self.highlight_text = rects, text
        return changed
    end
    local changed = self.highlight_rects ~= nil
    self.highlight_rects, self.highlight_text = nil, nil
    return changed
end

-- find in definition ----------------------------------------------------------------

function WebHtmlBoxWidget:findText(text)
    if not text or text == "" then return false end
    self.search_term = text
    local res = self:_ensure() and self.renderer:find(self.slot, text) or {}
    self._search_index = {}
    for page, rects in pairs(res) do
        self._search_index[tonumber(page) + 1] = to_rects(rects)
    end
    self._match_page_list = {}
    for p in pairs(self._search_index) do table.insert(self._match_page_list, p) end
    table.sort(self._match_page_list)
    local first
    for _, p in ipairs(self._match_page_list) do
        if p >= self.page_number then first = p break end
    end
    first = first or self._match_page_list[1]
    if first then
        self:setPageNumber(first)
        return true
    end
    return false
end

function WebHtmlBoxWidget:_findMatchesOnPage(page_idx)
    return self._search_index and self._search_index[page_idx] or nil
end

-- HtmlBoxWidget's version needs a MuPDF document. It is also what repaints the
-- page when DictQuickLookup steps to the next match, so without it the page
-- number changes and the screen does not.
function WebHtmlBoxWidget:_highlightSearchOnCurrentPage()
    if not self.search_term then return false end
    self.highlight_rects = self:_findMatchesOnPage(self.page_number)
    self:freeBb()
    UIManager:setDirty(self.dialog, function() return "partial", self.dimen end)
    return self.highlight_rects ~= nil
end

return WebHtmlBoxWidget
