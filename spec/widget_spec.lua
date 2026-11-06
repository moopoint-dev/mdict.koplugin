--[[
Runs KOReader's own HtmlBoxWidget/ScrollHtmlWidget code (from a KOReader
checkout) with the plugin's WebView widgets on top, rendering through
headless Chromium. Needs:
  KOREADER_FRONTEND=<koreader>/frontend
  MDICT_CHROMIUM=<a Chromium binary> (driven over its DevTools pipe, renderers/cdp_bridge.lua),
  or MDICT_CHROMIUM_BRIDGE=<repo>/tools/chromium-bridge/bridge.js (and NODE_PATH)
]]
local helper = require("spec.helper")
local frontend = os.getenv("KOREADER_FRONTEND")
local bridge_js = os.getenv("MDICT_CHROMIUM_BRIDGE")
local chromium = os.getenv("MDICT_CHROMIUM")

if not (frontend and (bridge_js or chromium)) then
    describe("WebView widgets", function()
        pending("set KOREADER_FRONTEND and MDICT_CHROMIUM (or MDICT_CHROMIUM_BRIDGE) to run")
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
        if bridge_js then
            bridge = assert(ChromiumBridge.new({ script = bridge_js, node_path = os.getenv("NODE_PATH"), dpr = 1,
                                                 tmpdir = helper.tmpdir("wcap") }))
        else
            local profile = helper.tmpdir("wprofile")
            local cdp = assert(require("renderers/cdp_pipe").spawn({ exe = chromium,
                args = { "--headless=new", "--no-sandbox", "--remote-debugging-pipe", "--hide-scrollbars",
                         "--user-data-dir=" .. profile, "about:blank" },
                env = { "HOME=" .. profile, "PATH=/usr/bin:/bin" } }))
            bridge = assert(require("renderers/cdp_bridge").new({ cdp = cdp, dpr = 1, max_slots = 3,
                decode = require("renderers/png").decodeInto }))
        end
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
            if k == "vertical_hint" or k == "grey_pages" then o[k] = v else o.entry[k] = v end
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

    it("draws the next page ahead in the way the reader turns, and keeps recent pages", function()
        local w = widget_for(entry("long"))
        local box = w.htmlbox_widget
        assert.is_true(box.page_count > 4)
        box:_render()
        for _ = 1, 3 do
            w:scrollText(1)
            UIManager:runTasks()
        end
        assert.equal(4, box.page_number)
        assert.truthy(box.page_cache[5])
        assert.is_nil(box.page_cache[2])
        -- turning back: the page before is drawn ahead, and the one just shown stays
        w:scrollText(-1)
        UIManager:runTasks()
        assert.equal(3, box.page_number)
        assert.truthy(box.page_cache[2])
        assert.truthy(box.page_cache[3])
        -- and forward again
        w:scrollText(1)
        UIManager:runTasks()
        assert.truthy(box.page_cache[5])
        w:free()
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
        -- page turns refresh without a flash, unless the reader wants one (e-ink ghosting)
        local function refresh()
            local d = UIManager.dirty[#UIManager.dirty]
            return (d[2]())
        end
        w:onScrollText(nil, { direction = "west" })
        assert.equal("partial", refresh())
        w.flash_turns = true
        w:onScrollText(nil, { direction = "east" })
        assert.equal("flashpartial", refresh())
        local n = #UIManager.dirty
        w:onScrollText(nil, { direction = "south" }) -- (changes dictionary, turns no page)
        assert.equal(n, #UIManager.dirty)
        w:jumpToPage(1)
        assert.equal("flashpartial", refresh())
        w:jumpToPage(2)
        w.flash_turns = false
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

    it("lays out entries that load scripts from the dictionary", function()
        local w = widget_for('<script src="js/viewer.js"></script><p>an entry with a script file</p>')
        local box = w.htmlbox_widget
        assert.is_true(box.scripts)
        assert.equal(1, box.page_count)
        assert.is_true(box:findText("script file"))
        w:free()
    end)

    it("lets the entry's scripts take a picture link over", function()
        -- a viewer like the ones exporters add: a click on the picture opens it over the entry
        local viewer = 'document.addEventListener("click", function (e) {'
            .. ' var a = e.target.closest && e.target.closest("a.pic"); if (!a) return;'
            .. ' var v = document.createElement("div"); v.className = "viewer";'
            .. ' v.style.cssText = "position:fixed;top:0;left:0;width:100%;height:100%;background:#000";'
            .. ' var b = document.createElement("button"); b.textContent = "close";'
            .. ' b.onclick = function () { v.parentNode.removeChild(v); };'
            .. ' v.appendChild(b); a.parentNode.appendChild(v); e.preventDefault(); e.stopPropagation(); }, true);'
        local html = '<p>words before the picture</p><p><a href="entry://picture" class="pic">'
            .. '<img src="img/icon.png" style="width:160px;height:120px"></a></p>'
            .. '<p>see <a href="entry://other">other</a></p><script>' .. viewer .. "</script>"
        local w = widget_for(html)
        local box = w.htmlbox_widget
        box.dimen.x, box.dimen.y = 0, 0
        assert.is_true(box.scripts)
        -- the picture is part of its link, not only the line under it
        local pic
        for _, l in ipairs(box:_links()) do
            if l.uri == "entry://picture" and l.y1 - l.y0 >= 100 then pic = l end
        end
        assert.truthy(pic)
        local tapped = #links_tapped
        local center = Geom:new{ x = (pic.x0 + pic.x1) / 2, y = (pic.y0 + pic.y1) / 2 }
        assert.is_true(box:onTapText(nil, { pos = center }))
        assert.equal(tapped, #links_tapped)
        assert.is_nil(box.entry.clicks)
        -- while the viewer is open, its taps stay in it and the entry's links are covered
        assert.same({}, box:_links())
        local next_result = dialog.next_result
        assert.is_true(box:onTapText(nil, { pos = Geom:new{ x = 300, y = 300 } }))
        assert.equal(next_result, dialog.next_result)
        assert.is_true(box:onTapText(nil, { pos = text_center(box, "close") }))
        assert.is_true(#box:_links() >= 2)
        -- links the scripts leave alone are followed as before
        box:onTapText(nil, { pos = text_center(box, "other") })
        assert.equal("entry://other", links_tapped[#links_tapped].uri)
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
        local max_slots = renderer.max_slots
        renderer.max_slots = 1 -- so that the nested popup takes the only one
        local a = widget_for(entry("long"))
        local b = widget_for(entry("Apple"))
        assert.equal(a.htmlbox_widget.slot, b.htmlbox_widget.slot)
        local abox = a.htmlbox_widget
        a:scrollText(1)
        a:scrollText(1)
        assert.equal(3, abox.page_number)
        assert.equal(abox, abox.slot.owner)
        assert.is_true(abox.bb:inkRatio() > 0.02)
        a:free()
        b:free()
        renderer.max_slots = max_slots
    end)

    it("leaves the pager of a popup still shown to the popups over it", function()
        local a = widget_for(entry("long"))
        local abox = a.htmlbox_widget
        local b = widget_for(entry("Apple"))
        assert.are_not.equal(abox.slot, b.htmlbox_widget.slot)
        b:free()
        -- the closed popup's slot can be used again, still not the shown one
        local c = widget_for(entry("Apple"))
        assert.are_not.equal(abox.slot, c.htmlbox_widget.slot)
        assert.equal(abox, abox.slot.owner)
        -- with every slot shown, one is still taken
        local d = widget_for(entry("split"))
        local e = widget_for(entry("Apple"))
        assert.equal(e.htmlbox_widget, e.htmlbox_widget.slot.owner)
        for _, w in ipairs({ e, d, c, a }) do w:free() end
    end)

    it("keeps pages in grey for grey e-ink screens", function()
        local colour = widget_for(entry("Apple"))
        local grey = widget_for(entry("Apple"), { grey_pages = true })
        local a, b = colour.htmlbox_widget, grey.htmlbox_widget
        a:_render()
        b:_render()
        assert.equal(Blitbuffer.TYPE_BBRGB32, a.page_cache[1]:getType())
        assert.equal(Blitbuffer.TYPE_BB8, b.page_cache[1]:getType())
        local expected = Blitbuffer.new(a.dimen.w, a.dimen.h, Blitbuffer.TYPE_BB8)
        expected:blitFrom(a.page_cache[1], 0, 0, 0, 0, a.dimen.w, a.dimen.h)
        assert.equal(expected:digest(), b.page_cache[1]:digest())
        expected:free()
        colour:free()
        grey:free()
    end)

    it("opens at an anchor", function()
        local html = "<p>start</p>" .. string.rep("<p>filler paragraph text</p>", 200) .. '<p id="here">target</p>'
        local w = widget_for(html, { anchor = "here" })
        local box = w.htmlbox_widget
        assert.is_true(box.page_count > 1)
        assert.equal(box.page_count, box.page_number)
        w:free()
    end)

    it("breaks between the blocks of an inline element that holds them", function()
        -- a sense group as one dictionary marks it up: the headword line and the
        -- definition with its examples in one span, in an entry with bottom padding
        local function sense(examples)
            local x = {}
            for i = 1, examples do x[i] = '<div id="x' .. i .. '">an example of the word in use</div>' end
            return '<div style="padding-bottom:60px"><a href="#top">*</a><span class="g">'
                .. '<span>headword</span> /prəˌnʌnsiˈeɪʃən/ verb '
                .. '<span id="d" style="display:block">the definition of the word</span>'
                .. table.concat(x) .. "</span></div>"
        end
        local split = 0
        for examples = 8, 22 do
            local w = widget_for(sense(examples))
            local box = w.htmlbox_widget
            if box.page_count > 1 then
                -- the definition stays with the headword, and only the examples that
                -- do not fit go to the next page
                assert.equal(0, renderer:pageOfAnchor(box.slot, "d").page)
                if renderer:pageOfAnchor(box.slot, "x" .. examples).page == 1
                    and renderer:pageOfAnchor(box.slot, "x1").page == 0 then
                    split = split + 1
                end
            end
            w:free()
        end
        assert.is_true(split > 0)
        -- the headword stays on the line it shares with the link before it
        local w = widget_for(sense(2))
        local box = w.htmlbox_widget
        local link = box:_links()[1]
        assert.is_true(box:findText("headword"))
        local head = box._search_index[1][1]
        assert.is_true(head.y < link.y1 and head.y + head.h > link.y0)
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

    it("lays out the next result ahead and hands it over when the reader gets there", function()
        local Manager = require("renderers/manager")
        local Library = require("mdict/library")
        local lib = Library.new({ dirs = { helper.fixtures() }, cache_dir = helper.tmpdir("plib") })
        lib:scan()
        local d = lib:byTitle("Basic Test")
        local state = { library = lib, settings = {} }
        local apple = Lookup.run({ d }, { "Apple" })[1]
        local long = Lookup.run({ d }, { "long" })[1]
        local split = Lookup.run({ d }, { "split" })[1]
        local dql = {
            results = { { dict = "Other", definition = "plain" }, apple, long, split },
            dict_index = 1, definition = "plain", word = "Apple",
            dict_font_size = 20, content_width = 600, definition_height = 300,
            html_dictionary_link_tapped_callback = function() end,
        }
        -- runs the scheduler (a background job's steps) for up to 40 s, until p's job is done
        local clock = WebRenderer.clock
        local function settle(p)
            local deadline = clock() + 40
            while clock() < deadline do
                if p.widget or p.job == nil or p.job.done then return end
                UIManager:runTasks()
                require("ffi").C.poll(nil, 0, 2)
            end
        end
        -- a plain result is shown: the MDict one after it is laid out in the background
        UIManager.tasks = {}
        Manager.prefetch(state, dql)
        local p = assert(dql.mdict_prefetch)
        assert.equal(2, p.index)
        assert.is_falsy(p.job.done) -- nothing happens before the scheduler runs it
        -- the popup has just opened: its first refresh comes first
        assert.equal(Manager.FIRST_PREFETCH_DELAY, UIManager.delays[p.job.step])
        local job = p.job
        settle(p)
        local ahead = assert(p.widget, tostring(job.ok) .. " " .. tostring(job.err))
        local box = ahead.htmlbox_widget
        assert.truthy(box.page_cache[box.page_number]) -- its first page is drawn already
        assert.is_true(box.slot.held)
        assert.is_true(box.trace.logged)
        -- not the shown result's footer: only the first result gets KOReader's query footer
        assert.is_false(box:findText("query"))

        -- the reader moves on to it: the widget laid out ahead is used as it is
        dql.dict_index, dql.definition = 2, apple.definition
        local w = Manager.widget(state, dql, apple)
        assert.equal(ahead, w)
        assert.is_nil(dql.mdict_prefetch)
        assert.is_nil(box.slot.held)
        dql.mdict_widget = w

        -- and the next one is laid out in another slot, leaving the shown entry's alone
        Manager.prefetch(state, dql)
        local p2 = assert(dql.mdict_prefetch)
        assert.equal(3, p2.index)
        assert.equal(Manager.PREFETCH_DELAY, UIManager.delays[p2.job.step])
        settle(p2)
        local box2 = assert(p2.widget).htmlbox_widget
        assert.are_not.equal(box.slot.id, box2.slot.id)
        assert.equal(box, box.slot.owner)
        assert.truthy(box:_pageBb(1))

        -- a result wanted before its background layout is done is finished at once
        dql.dict_index, dql.definition = 3, long.definition
        local w2 = Manager.widget(state, dql, long)
        assert.equal(p2.widget, w2)
        dql.mdict_widget = w2
        -- once shown, its next page is drawn in the background too; work on the entry
        -- meanwhile (here its links) waits for that to finish first
        local b2 = w2.htmlbox_widget
        assert.is_true(b2.page_count > 1)
        b2:_render()
        local page_job = assert(b2.page_job)
        assert.is_falsy(page_job.done)
        assert.is_nil(b2.page_cache[2])
        UIManager:runTasks()
        b2:_links()
        assert.is_true(page_job.done)
        assert.truthy(b2.page_cache[2])
        b2:freeBb()
        w:free()
        Manager.prefetch(state, dql)
        local p3 = assert(dql.mdict_prefetch)
        assert.equal(4, p3.index)
        dql.dict_index, dql.definition = 4, split.definition
        assert.is_falsy(p3.widget)
        local w3 = assert(Manager.widget(state, dql, split))
        assert.equal(p3.widget, w3)
        assert.truthy(w3.htmlbox_widget.page_cache[1])

        -- going back: the previous result is the one laid out next; closing drops it
        dql.mdict_widget = w3
        w2:free()
        Manager.prefetch(state, dql)
        dql.dict_index = 3
        Manager.prefetch(state, dql)
        assert.equal(2, dql.mdict_prefetch.index)
        Manager.dropPrefetch(dql)
        assert.is_nil(dql.mdict_prefetch)
        local deadline = clock() + 40
        while #UIManager.tasks > 0 and clock() < deadline do
            UIManager:runTasks()
            require("ffi").C.poll(nil, 0, 2)
        end
        assert.equal(0, #UIManager.tasks)
        w3:free()
        Manager.shutdown()
    end)

    it("with one page, lays out the MDict result ahead and keeps it when the reader moves away", function()
        local Manager = require("renderers/manager")
        local Library = require("mdict/library")
        local lib = Library.new({ dirs = { helper.fixtures() }, cache_dir = helper.tmpdir("olib") })
        lib:scan()
        local d = lib:byTitle("Basic Test")
        local state = { library = lib, settings = {} }
        local apple = Lookup.run({ d }, { "Apple" })[1]
        local long = Lookup.run({ d }, { "long" })[1]
        local plain = { dict = "Other", definition = "plain" }
        local plain2 = { dict = "Third", definition = "plain too" }
        local function popup(results)
            return {
                results = results, dict_index = 1, definition = "plain", word = "Apple",
                dict_font_size = 20, content_width = 600, definition_height = 300,
                html_dictionary_link_tapped_callback = function() end,
            }
        end
        local clock = WebRenderer.clock
        local function settle(p)
            local deadline = clock() + 40
            while clock() < deadline do
                if p.widget or p.job == nil or p.job.done then return end
                UIManager:runTasks()
                require("ffi").C.poll(nil, 0, 2)
            end
        end
        local browser = assert(Manager.get(state))
        local slots = browser.max_slots
        browser.max_slots = 1 -- as the Kindle's browser

        -- another dictionary's result is shown: the nearest MDict one is laid out ahead,
        -- even when it is not the next result
        UIManager.tasks = {}
        local dql = popup({ plain, plain2, apple })
        Manager.prefetch(state, dql)
        local p = assert(dql.mdict_prefetch)
        assert.equal(3, p.index)
        settle(p)
        local ahead = assert(p.widget)
        -- the reader gets there: it is used as it is, and nothing is laid out ahead meanwhile
        dql.dict_index = 3
        local w = Manager.widget(state, dql, apple)
        assert.equal(ahead, w)
        dql.mdict_widget, dql.mdict_widget_result = w, apple
        Manager.prefetch(state, dql)
        assert.is_nil(dql.mdict_prefetch)
        local page = assert(w.htmlbox_widget.page_cache[1])
        -- the reader moves to another dictionary's result: the entry is kept, and is what
        -- they get when they come back, its pages as they were
        dql.dict_index = 2
        assert.is_true(Manager.keep(state, dql, w, apple))
        dql.mdict_widget, dql.mdict_widget_result = nil, nil
        Manager.prefetch(state, dql)
        assert.equal(w, dql.mdict_prefetch.widget)
        dql.dict_index = 3
        assert.equal(w, Manager.widget(state, dql, apple))
        assert.equal(page, w.htmlbox_widget.page_cache[1])
        -- the same result again (a new font size) is not kept
        assert.is_false(Manager.keep(state, dql, w, apple))
        w:free()

        -- a result picked while another is being laid out ahead gets the page
        UIManager.tasks = {}
        local dql2 = popup({ plain, apple, long })
        Manager.prefetch(state, dql2)
        local p2 = assert(dql2.mdict_prefetch)
        assert.equal(2, p2.index)
        UIManager:runTasks() -- the layout ahead has begun
        dql2.dict_index = 3
        local w2 = assert(Manager.widget(state, dql2, long))
        assert.is_nil(dql2.mdict_prefetch)
        assert.is_true(w2.htmlbox_widget.page_count > 1)
        w2:free()

        browser.max_slots = slots
        Manager.shutdown()
    end)

    it("draws a page again when it was captured before the WebView had drawn it", function()
        local Manager = require("renderers/manager")
        local Library = require("mdict/library")
        local lib = Library.new({ dirs = { helper.fixtures() }, cache_dir = helper.tmpdir("slib") })
        lib:scan()
        local state = { library = lib, settings = {} }
        local long = Lookup.run({ lib:byTitle("Basic Test") }, { "long" })[1]
        local dql = {
            definition = long.definition, dict_font_size = 20, content_width = 600, definition_height = 300,
            html_dictionary_link_tapped_callback = function() end,
        }
        UIManager.tasks, UIManager.dirty = {}, {}
        local w = assert(Manager.widget(state, dql, long))
        local box = w.htmlbox_widget
        assert.is_true(box.page_count > 2)
        local box_renderer = box.renderer
        -- the next `early` captures come before the WebView has drawn (the Java side gave up waiting)
        local early, captures = 0, 0
        box_renderer.renderPage = function(...)
            captures = captures + 1
            local ok, err, timing = WebRenderer.renderPage(...)
            if ok and early > 0 then
                early = early - 1
                timing.via = "timeout"
            end
            return ok, err, timing
        end
        local clock = WebRenderer.clock
        local function settle(job)
            local deadline = clock() + 40
            while not job.done and clock() < deadline do
                UIManager:runTasks()
                require("ffi").C.poll(nil, 0, 2)
            end
            assert.is_true(job.done)
        end

        -- the shown page: shown as it came, then drawn again in the background and shown again
        box:_dropPages()
        box:freeBb()
        UIManager.tasks = {}
        early = 1
        box:_render()
        local shown = box.bb
        assert.is_true(box.page_stale[1])
        local job = assert(box.page_job)
        settle(job)
        assert.is_true(job.result)
        assert.is_nil(box.page_stale[1])
        assert.equal(shown, box.bb) -- not yet: once the work that finished the job is done
        UIManager.dirty = {}
        UIManager:runTasks()
        assert.are_not.equal(shown, box.bb)
        assert.equal(1, #UIManager.dirty)
        -- and then its next page is drawn ahead, as usual
        job = assert(box.page_job)
        early = 1
        settle(job)
        assert.is_true(box.page_stale[2])

        -- a page drawn ahead too early is drawn again when the reader gets there
        local before = captures
        w:jumpToPage(2)
        assert.equal(before + 1, captures)
        assert.is_nil(box.page_stale[2])
        -- one drawn right is used as it is
        if box.page_job then settle(box.page_job) end
        assert.truthy(box.page_cache[3])
        before = captures
        w:jumpToPage(3)
        assert.equal(before, captures)

        box_renderer.renderPage = nil
        w:free()
        Manager.shutdown()
    end)
end)
