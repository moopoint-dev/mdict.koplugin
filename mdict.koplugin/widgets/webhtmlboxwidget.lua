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
}

function WebHtmlBoxWidget:init()
    HtmlBoxWidget.init(self)
    self.page_cache = {}
    self.links_cache = {}
end

--- Lays out an entry. doc: renderer document options; entry: { html, anchor, zoom, eink, writing }.
-- Returns true, or nil and an error (the caller then falls back to MuPDF).
function WebHtmlBoxWidget:loadEntry(doc, entry)
    self.doc, self.entry = doc, entry
    local ok, err = self:_layout()
    if not ok then return nil, err end
    self.page_number = self.anchor_page or 1
    self:_dropPages()
    return true
end

function WebHtmlBoxWidget:_layout()
    local slot, err = self.renderer:document(self.doc, self.dimen.w, self.dimen.h, self.avoid_slots)
    if not slot then return nil, err end
    local info
    info, err = self.renderer:setEntry(slot, self.entry)
    if not info then return nil, err end
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
    if self.slot and self.slot.owner == self and self.slot.key == self.slot_key then return true end
    local ok, err = self:_layout()
    if not ok then logger.warn("MDict: cannot restore entry:", err) end
    return ok
end

function WebHtmlBoxWidget:_dropPages()
    for _, bb in pairs(self.page_cache) do bb:free() end
    self.page_cache, self.page_order = {}, {}
    self.links_cache = {}
    self.find_index = nil
end

function WebHtmlBoxWidget:_pageBb(n)
    local bb = self.page_cache[n]
    if bb then return bb end
    bb = Blitbuffer.new(self.dimen.w, self.dimen.h, Blitbuffer.TYPE_BBRGB32)
    local ok, err = self:_ensure()
    local timing
    if ok then ok, err, timing = self.renderer:renderPage(self.slot, n - 1, bb.data) end
    if not ok then
        logger.warn("MDict: page render failed:", err)
        bb:fill(Blitbuffer.COLOR_WHITE)
    elseif self.trace and not self.trace.logged then
        self.trace.logged = true
        logger.info(self:_timingText(timing))
    end
    self.page_cache[n] = bb
    self.page_order = self.page_order or {}
    table.insert(self.page_order, n)
    while #self.page_order > self.page_cache_size do
        local old = table.remove(self.page_order, 1)
        if old ~= n and self.page_cache[old] then
            self.page_cache[old]:free()
            self.page_cache[old] = nil
        end
    end
    return bb
end

function WebHtmlBoxWidget:_render()
    if self.bb then return end
    local page = self:_pageBb(self.page_number)
    -- the cached page stays clean; highlights go on a copy
    self.bb = page:copy()
    if self.highlight_text_selection and self.highlight_rects then
        for _, rect in ipairs(self.highlight_rects) do
            self.bb:darkenRect(rect.x, rect.y, rect.w, rect.h, self.highlight_lighten_factor)
        end
    end
    -- render the next page while the reader looks at this one
    if not self._prefetch then
        self._prefetch = function()
            self._prefetch = nil
            local nxt = self.page_number + 1
            if not self.freed and nxt <= self.page_count and not self.page_cache[nxt]
                    and self.slot and self.slot.owner == self then
                self:_pageBb(nxt)
            end
        end
        UIManager:scheduleIn(0.3, self._prefetch)
    end
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
    local text = string.format("MDict: %s laid out in %d ms%s: document %d%s, entry %d%s",
        self.label or "entry", t.total or 0, self.background and " (ahead)" or "",
        t.doc or 0, #doc > 0 and " (" .. table.concat(doc, ", ") .. ")" or "",
        t.entry or 0, marks(t.entry_js))
    if t.needs then
        text = text .. string.format(", %d resources in %.0f", t.needs, t.need_ms or 0)
    end
    if (t.layouts or 1) > 1 then text = text .. ", laid out twice" end
    if page then
        text = text .. string.format("; page 1 in %d (show %d, capture %d: waited %s %s, drew %s)",
            page.show + page.capture, page.show, page.capture, tostring(page.wait), tostring(page.via),
            tostring(page.draw))
    end
    return text
end

function WebHtmlBoxWidget:getSinglePageHeight()
    return nil
end

function WebHtmlBoxWidget:free()
    self:freeBb()
    if self._prefetch then
        UIManager:unschedule(self._prefetch)
        self._prefetch = nil
    end
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
        self.links_cache[n] = self.renderer:links(self.slot) or {}
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
    if not pos then return end
    if not G_reader_settings:isFalse("tap_to_follow_links") then
        local link = self:getLinkByPosition(pos)
        if link then
            local anchor = link.uri and link.uri:match("^#(.+)$")
            if anchor then
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
    if res.same then return true end
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
