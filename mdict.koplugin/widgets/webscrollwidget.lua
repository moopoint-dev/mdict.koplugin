--[[--
ScrollHtmlWidget for MDict entries rendered by the WebView pager.

Horizontal entries page like KOReader's HTML dictionaries (swipe up/down, tap
the left/right half). Vertical (vertical-rl) entries read right to left, so
their pages turn with horizontal swipes: east (left to right) goes forward,
west goes back, and up/down swipes change dictionary instead. Taps follow the
same direction: the left half goes forward, past the last page to the next
result. Their scroll bar runs along the bottom and fills from the right.
]]

local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalScrollBar = require("ui/widget/horizontalscrollbar")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalScrollBar = require("ui/widget/verticalscrollbar")
local VerticalSpan = require("ui/widget/verticalspan")
local WebHtmlBoxWidget = require("widgets/webhtmlboxwidget")

-- Horizontal scroll bar for right-to-left page order.
local RtlScrollBar = HorizontalScrollBar:extend{}

function RtlScrollBar:paintTo(bb, x, y)
    if not self.enable then return end
    self.touch_dimen = Geom:new{
        x = x,
        y = y - self.extra_touch_on_side,
        w = self.width,
        h = self.height + 2 * self.extra_touch_on_side,
    }
    bb:paintBorder(x, y, self.width, self.height, self.bordersize, self.bordercolor, self.radius)
    local inner = self.width - 2 * self.bordersize
    bb:paintRect(x + self.bordersize + (1 - self.high) * inner, y + self.bordersize,
                 math.max(inner * (self.high - self.low), self.min_thumb_size),
                 self.height - 2 * self.bordersize, self.rectcolor)
end

function RtlScrollBar:onTapScroll(arg, ges)
    if self.scroll_callback and self.touch_dimen then
        self.scroll_callback(1 - (ges.pos.x - self.touch_dimen.x) / self.width)
        return true
    end
end
RtlScrollBar.onHoldScroll = RtlScrollBar.onTapScroll
RtlScrollBar.onHoldPanScroll = RtlScrollBar.onTapScroll
RtlScrollBar.onHoldReleaseScroll = RtlScrollBar.onTapScroll
RtlScrollBar.onPanScroll = RtlScrollBar.onTapScroll
RtlScrollBar.onPanScrollRelease = RtlScrollBar.onTapScroll

local WebScrollWidget = ScrollHtmlWidget:extend{
    renderer = nil,
    doc = nil, -- document options for the renderer
    entry = nil, -- entry options for the renderer
    invert_vertical_swipes = false,
    vertical_hint = false, -- lay out for vertical text first (the dictionary's last entry was vertical)
    on_layout = nil, -- called with the box once the entry is laid out
    avoid_slots = nil, -- renderer slots not to use (see WebHtmlBoxWidget)
    label = nil, -- names the entry in the timing log
    background = false, -- laid out ahead by a background job
}

local function new_box(o, vertical)
    local bar = (o.scroll_bar_width or ScrollHtmlWidget.scroll_bar_width)
        + (o.text_scroll_span or ScrollHtmlWidget.text_scroll_span)
    return WebHtmlBoxWidget:new{
        renderer = o.renderer,
        dimen = Geom:new{
            w = vertical and o.width or o.width - bar,
            h = vertical and o.height - bar or o.height,
        },
        dialog = o.dialog,
        highlight_text_selection = o.highlight_text_selection,
        html_link_tapped_callback = o.html_link_tapped_callback,
        on_clear_search = o.on_clear_search,
        avoid_slots = o.avoid_slots,
        label = o.label,
        background = o.background,
    }
end

--- Builds the widget, or returns nil and an error when the renderer cannot lay out the entry.
-- The scroll bar sits beside horizontal text and below vertical text, so the page size depends
-- on the writing mode: the entry is laid out for vertical_hint, and again when that was wrong.
function WebScrollWidget.create(o)
    local clock = require("renderers/webview").clock
    local t0 = clock()
    local hint = o.vertical_hint and true or false
    local box = new_box(o, hint)
    local ok, err = box:loadEntry(o.doc, o.entry)
    local twice = false
    if ok and box.vertical ~= hint then
        box:free()
        local entry = {}
        for k, v in pairs(o.entry) do entry[k] = v end
        entry.writing = hint and "horizontal" or "vertical"
        box = new_box(o, not hint)
        ok, err = box:loadEntry(o.doc, entry)
        twice = true
    end
    if not ok then
        box:free()
        return nil, err
    end
    box.trace = box.trace or {}
    box.trace.total = math.floor((clock() - t0) * 1000 + 0.5)
    if twice then box.trace.layouts = 2 end
    if o.on_layout then o.on_layout(box) end
    o.htmlbox_widget = box
    return WebScrollWidget:new(o)
end

function WebScrollWidget:init()
    -- htmlbox_widget is already laid out by create()
    local box = self.htmlbox_widget
    box.on_page_jump = function(page) self:jumpToPage(page) end
    box.on_relayout = function() self:_relayout() end
    local scroll_callback = function(ratio) self:scrollToRatio(ratio) end
    if box.vertical then
        self.v_scroll_bar = RtlScrollBar:new{
            enable = box.page_count > 1,
            width = self.width,
            height = self.scroll_bar_width,
            scroll_callback = scroll_callback,
        }
        self[1] = VerticalGroup:new{
            box,
            VerticalSpan:new{ width = self.text_scroll_span },
            self.v_scroll_bar,
        }
    else
        self.v_scroll_bar = VerticalScrollBar:new{
            enable = box.page_count > 1,
            width = self.scroll_bar_width,
            height = self.height,
            scroll_callback = scroll_callback,
        }
        self[1] = HorizontalGroup:new{
            box,
            HorizontalSpan:new{ width = self.text_scroll_span },
            self.v_scroll_bar,
        }
    end
    self:_updateScrollBar()
    self.dimen = Geom:new(self[1]:getSize())
    -- same gestures and keys as ScrollHtmlWidget
    local GestureRange = require("ui/gesturerange")
    local Device = require("device")
    if Device:isTouchDevice() then
        self.ges_events = {
            ScrollText = { GestureRange:new{ ges = "swipe", range = function() return self.dimen end } },
            TapScrollText = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
        }
    end
    if Device:hasKeys() then
        self.key_events = {
            ScrollDown = { { Device.input.group.PgFwd } },
            ScrollUp = { { Device.input.group.PgBack } },
        }
    end
end

function WebScrollWidget:isVertical()
    return self.htmlbox_widget.vertical
end

function WebScrollWidget:jumpToPage(page)
    local box = self.htmlbox_widget
    page = math.max(1, math.min(box.page_count, page))
    if page == box.page_number then return end
    box:setPageNumber(page)
    self:_updateScrollBar()
    box:freeBb()
    box:_render()
    UIManager:setDirty(self.dialog, function() return "partial", self.dimen end)
end

-- The entry changed size (a section was opened): new page count, same widget.
function WebScrollWidget:_relayout()
    local box = self.htmlbox_widget
    self.v_scroll_bar.enable = box.page_count > 1
    self:_updateScrollBar()
    box:freeBb()
    box:_render()
    UIManager:setDirty(self.dialog, function() return "partial", self.dimen end)
end

function WebScrollWidget:resetScroll()
    -- an entry opened at an anchor starts on the anchor's page
    self.htmlbox_widget:setPageNumber(self.htmlbox_widget.anchor_page or 1)
    self:_updateScrollBar()
    self.v_scroll_bar.enable = self.htmlbox_widget.page_count > 1
end

function WebScrollWidget:onScrollText(arg, ges)
    if not self:isVertical() then
        return ScrollHtmlWidget.onScrollText(self, arg, ges)
    end
    local forward, back = "east", "west"
    if self.invert_vertical_swipes then forward, back = back, forward end
    if ges.direction == forward then
        self:scrollText(1)
        return true
    elseif ges.direction == back then
        self:scrollText(-1)
        return true
    elseif ges.direction == "north" or ges.direction == "south" then
        local dialog = self.dialog
        if dialog and dialog.onChangeToNextDict then
            if ges.direction == "north" then dialog:onChangeToNextDict() else dialog:onChangeToPrevDict() end
            return true
        end
    end
end

function WebScrollWidget:onTapScrollText(arg, ges)
    if not self:isVertical() then
        return ScrollHtmlWidget.onTapScrollText(self, arg, ges)
    end
    local forward = ges.pos.x < self.dimen.x + self.dimen.w / 2
    local dialog = self.dialog
    if self.ignore_taps then
        -- while finding in the definition, taps step through the matches in reading order
        if dialog and dialog.in_definition_search and dialog.findInDefinitionNextOrPreviousPage then
            dialog:findInDefinitionNextOrPreviousPage(forward and 1 or -1)
            return true
        end
        return false
    end
    -- past either end, go to the next or previous result in the same direction
    -- (DictQuickLookup would pick it by screen side, the other way round)
    if forward then
        if self:onScrollDown() then return true end
        if dialog and dialog.onReadNextResult then
            dialog:onReadNextResult()
            return true
        end
    else
        if self:onScrollUp() then return true end
        if dialog and dialog.onReadPrevResult then
            dialog:onReadPrevResult()
            return true
        end
    end
end

return WebScrollWidget
