--[[
Runs KOReader's own HtmlBoxWidget/ScrollHtmlWidget code (from a KOReader
checkout) with the plugin's WebView widgets on top, rendering through
headless Chromium. Needs:
  KOREADER_FRONTEND=<koreader>/frontend
  MDICT_CHROMIUM_BRIDGE=<repo>/tools/chromium-bridge/bridge.js (and NODE_PATH)
]]
local helper = require("spec.helper")
local frontend = os.getenv("KOREADER_FRONTEND")
local bridge_js = os.getenv("MDICT_CHROMIUM_BRIDGE")

if not (frontend and bridge_js) then
    describe("WebView widgets", function()
        pending("set KOREADER_FRONTEND and MDICT_CHROMIUM_BRIDGE to run")
    end)
    return
end

package.path = helper.root .. "/spec/koreader/?.lua;" .. package.path .. ";" .. frontend .. "/?.lua"
_G.G_reader_settings = {
    readSetting = function(_, _, default) return default end,
    isFalse = function() return false end,
    isTrue = function() return false end,
    nilOrTrue = function() return true end,
}
_G.G_defaults = { readSetting = function() return 1 end }

local Blitbuffer = require("ffi/blitbuffer")
local ChromiumBridge = require("renderers/chromium_bridge")
local Dictionary = require("mdict/dictionary")
local Geom = require("ui/geometry")
local Lookup = require("mdict/lookup")
local UIManager = require("ui/uimanager")
local WebRenderer = require("renderers/webview")
local WebScrollWidget = require("widgets/webscrollwidget")

describe("WebView widgets", function()
    local bridge, renderer, dict
    setup(function()
        bridge = assert(ChromiumBridge.new({ script = bridge_js, node_path = os.getenv("NODE_PATH"), dpr = 1,
                                             tmpdir = helper.tmpdir("wcap") }))
        dict = Dictionary.new({ path = helper.fixtures() .. "/basic.mdx", cache_dir = helper.tmpdir("wcache"),
                                title = "Basic" })
        renderer = WebRenderer.new({ bridge = bridge, resolve = function(_, path) return dict:resource(path) end })
    end)
    teardown(function()
        if renderer then renderer:close() end
        if bridge then bridge:free() end
    end)

    local links_tapped = {}
    local dialog = { onChangeToNextDict = function(d) d.next = (d.next or 0) + 1 end,
                     onChangeToPrevDict = function(d) d.prev = (d.prev or 0) + 1 end,
                     onReadNextResult = function(d) d.next_result = (d.next_result or 0) + 1 end }

    local function widget_for(html, extra)
        local stylesheets, body = dict:stylesheetsOf(html)
        local o = {
            renderer = renderer, dialog = dialog, width = 618, height = 400, highlight_text_selection = true,
            doc = { dict_id = dict.id, cache_root = dict.res_dir, stylesheets = stylesheets },
            entry = { html = body, eink = true },
            html_link_tapped_callback = function(link) table.insert(links_tapped, link) end,
        }
        for k, v in pairs(extra or {}) do
            if k == "vertical_hint" then o[k] = v else o.entry[k] = v end
        end
        return assert(WebScrollWidget.create(o))
    end

    local function entry(word)
        local r = Lookup.run({ dict }, { word })
        return r[1].mdict.html
    end

    it("paginates a long entry and renders its pages", function()
        local live = Blitbuffer.live
        local w = widget_for(entry("long"))
        local box = w.htmlbox_widget
        assert.is_true(box.page_count > 3)
        assert.is_false(box.vertical)
        box:_render()
        local first = box.bb:digest()
        assert.is_true(box.bb:inkRatio() > 0.02)
        w:scrollText(1)
        assert.equal(2, box.page_number)
        assert.are_not.equal(first, box.bb:digest())
        -- the prefetch renders page 3 ahead
        UIManager:runTasks()
        assert.truthy(box.page_cache[3])
        -- find in definition: stepping to the next match shows that page with its matches
        assert.is_true(box:findText("lorem"))
        assert.is_true(#box._match_page_list >= box.page_count - 1)
        local before = box.page_number
        box:_render()
        local shown = box.bb:digest()
        assert.is_true(box:findTextNextPage(1))
        assert.are_not.equal(before, box.page_number)
        assert.truthy(box.highlight_rects and #box.highlight_rects > 0)
        assert.is_nil(box.bb)
        box:_render()
        assert.are_not.equal(shown, box.bb:digest())
        w:free()
        assert.equal(live, Blitbuffer.live)
    end)

    it("finds words split by markup, but not across blocks", function()
        local w = widget_for(entry("split"))
        local box = w.htmlbox_widget
        assert.is_true(box:findText("split"))
        assert.truthy(box._search_index[1] and #box._search_index[1] >= 1) -- one rect per piece
        assert.is_false(box:findText("oneword"))
        w:free()
    end)

    it("follows links and selects text", function()
        local w = widget_for(entry("Apple"))
        local box = w.htmlbox_widget
        box.dimen.x, box.dimen.y = 0, 0
        local links = box:_links()
        assert.is_true(#links >= 1)
        local l = links[1]
        assert.equal("bword://apples", l.uri)
        assert.equal("apples", l.text)
        box:onTapText(nil, { pos = Geom:new{ x = (l.x0 + l.x1) / 2, y = (l.y0 + l.y1) / 2 } })
        assert.equal("bword://apples", links_tapped[#links_tapped].uri)
        box.hold_start_pos = Geom:new{ x = l.x0 + 3, y = (l.y0 + l.y1) / 2 }
        box.hold_end_pos = box.hold_start_pos
        assert.is_true(box:updateHighlight())
        assert.equal("apples", box.highlight_text)
        w:free()
    end)

    it("turns vertical pages with horizontal swipes", function()
        local text = string.rep("縦書きの辞書の項目です。", 400)
        local w = widget_for('<div style="writing-mode:vertical-rl">' .. text .. "</div>")
        local box = w.htmlbox_widget
        assert.is_true(box.vertical)
        assert.is_true(box.page_count > 1)
        w:onScrollText(nil, { direction = "east" })
        assert.equal(2, box.page_number)
        w:onScrollText(nil, { direction = "west" })
        assert.equal(1, box.page_number)
        w:onScrollText(nil, { direction = "north" })
        assert.equal(1, dialog.next)
        w.dimen = Geom:new{ x = 0, y = 0, w = 618, h = 400 }
        w:onTapScrollText(nil, { pos = Geom:new{ x = 10, y = 100 } })
        assert.equal(2, box.page_number)
        -- full width; the scroll bar runs along the bottom, filled from the right
        assert.equal(618, box.dimen.w)
        assert.is_true(box.dimen.h < 400)
        assert.equal(618, w.v_scroll_bar.width)
        assert.is_true(w.v_scroll_bar.low > 0)
        -- the left half goes forward past the last page, to the next result
        w:jumpToPage(box.page_count)
        w:onTapScrollText(nil, { pos = Geom:new{ x = 10, y = 100 } })
        assert.equal(1, dialog.next_result)
        w:free()
        -- laid out once when the dictionary's last entry was vertical too
        local calls = 0
        local orig = renderer.setEntry
        renderer.setEntry = function(...) calls = calls + 1 return orig(...) end
        w = widget_for('<div style="writing-mode:vertical-rl">' .. text .. "</div>", { vertical_hint = true })
        renderer.setEntry = orig
        assert.equal(1, calls)
        assert.is_true(w.htmlbox_widget.vertical)
        w:free()
    end)

    local function text_center(box, word)
        local r = box.renderer:find(box.slot, word)
        local rect = r and (r["0"] or r[0])
        assert.truthy(rect, word .. " not on the first page")
        return Geom:new{ x = (rect[1].x0 + rect[1].x1) / 2, y = (rect[1].y0 + rect[1].y1) / 2 }
    end

    it("opens collapsed sections in place and keeps them open", function()
        local html = "<p>intro words</p><details><summary>More examples</summary>"
            .. string.rep("<p>hidden example sentence</p>", 120) .. "</details>"
        local w = widget_for(html)
        local box = w.htmlbox_widget
        box.dimen.x, box.dimen.y = 0, 0
        assert.equal(1, box.page_count)
        -- plain text is not interactive: the tap is left to KOReader (page turns)
        assert.is_nil(box:onTapText(nil, { pos = text_center(box, "intro") }))
        assert.is_true(box:onTapText(nil, { pos = text_center(box, "More") }))
        local pages = box.page_count
        assert.is_true(pages > 1)
        assert.equal(1, #box.entry.clicks)
        -- a nested popup takes the pager; the section is still open afterwards
        local other = widget_for(entry("Apple"))
        assert.is_true(box:_ensure())
        assert.equal(pages, box.page_count)
        other:free()
        w:free()
    end)

    it("pages boxes columns cannot split as slices", function()
        local tall = '<div style="display:inline-block;width:100%">'
            .. string.rep("<p>a line in a box that cannot be split into columns</p>", 80) .. "</div>"
        local w = widget_for(tall)
        local box = w.htmlbox_widget
        assert.equal("slices", box.mode)
        assert.is_true(box.page_count > 2)
        w:scrollText(1)
        assert.is_true(box.bb:inkRatio() > 0.01)
        w:free()
        w = widget_for(tall, { pagination = "columns" })
        assert.equal("columns", w.htmlbox_widget.mode)
        assert.equal(1, w.htmlbox_widget.page_count)
        w:free()
    end)

    it("restores its entry after a nested popup used the pager", function()
        local a = widget_for(entry("long"))
        local b = widget_for(entry("Apple"))
        local abox = a.htmlbox_widget
        a:scrollText(1)
        a:scrollText(1)
        assert.equal(3, abox.page_number)
        assert.equal(abox, abox.slot.owner)
        assert.is_true(abox.bb:inkRatio() > 0.02)
        a:free()
        b:free()
    end)

    it("opens at an anchor", function()
        local html = "<p>start</p>" .. string.rep("<p>filler paragraph text</p>", 200) .. '<p id="here">target</p>'
        local w = widget_for(html, { anchor = "here" })
        local box = w.htmlbox_widget
        assert.is_true(box.page_count > 1)
        assert.equal(box.page_count, box.page_number)
        w:free()
    end)

    it("builds popup widgets through the manager", function()
        local Manager = require("renderers/manager")
        local Library = require("mdict/library")
        local lib = Library.new({ dirs = { helper.fixtures() }, cache_dir = helper.tmpdir("mlib") })
        lib:scan()
        local state = { library = lib, settings = {} }
        local results = Lookup.run({ lib:byTitle("Basic Test") }, { "Apple" })
        local r = results[1]
        local tapped
        local dql = {
            definition = r.definition .. "<br/>_______<br/>(query : Apple)",
            dict_font_size = 20, content_width = 600, definition_height = 300, dictionary = "Basic Test",
            html_dictionary_link_tapped_callback = function(dictionary, link) tapped = { dictionary, link.uri } end,
        }
        local w = assert(Manager.widget(state, dql, r))
        local box = w.htmlbox_widget
        box.dimen.x, box.dimen.y = 0, 0
        assert.equal(1, box.page_count)
        local found = false
        for _, l in ipairs(box:_links()) do
            if l.uri == "bword://apples" then
                box:onTapText(nil, { pos = Geom:new{ x = (l.x0 + l.x1) / 2, y = (l.y0 + l.y1) / 2 } })
                found = true
            end
        end
        assert.is_true(found)
        assert.same({ "Basic Test", "bword://apples" }, tapped)
        -- the query footer KOReader appends is part of the entry
        assert.is_true(box:findText("query"))
        w:free()
        Manager.shutdown()
    end)
end)
