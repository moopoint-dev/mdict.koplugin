--[[--
Hooks into KOReader's dictionary lookup.

- MDict dictionaries are added to ReaderDictionary's list of installed
  dictionaries, so KOReader's own "Manage dictionaries" menu enables,
  disables and orders them, and per-book preferred dictionaries work.
- ReaderDictionary:startSdcv also asks the MDict dictionaries among the
  requested names, and merges their results in dictionary order. sdcv is
  only run when StarDict dictionaries are requested.
- ReaderDictionary:showDict restores the fields tidyMarkup may change and,
  when MuPDF renders, extracts the resources it needs first.
- Link taps: "#anchor" links stay in the entry, sound:// plays audio.
- DictQuickLookup shows MDict results with the plugin's renderer when one is
  available (see Integration.widget).
]]

local Html = require("mdict/html")
local Lookup = require("mdict/lookup")
local clock = require("mdict/clock")

local Integration = {
    installed = false,
    state = nil, -- { library, settings, renderer (optional), playSound, stopSound (optional) }
    ifos_injected = false,
}

local function find_upvalue(fn, name)
    if type(fn) ~= "function" then return nil end
    for i = 1, 200 do
        local n, v = debug.getupvalue(fn, i)
        if not n then break end
        if n == name then return v end
    end
end

--- KOReader's list of installed (StarDict) dictionaries, if it can be reached.
function Integration.availableIfos(ReaderDictionary)
    local ifos = find_upvalue(ReaderDictionary.init, "available_ifos")
        or find_upvalue(ReaderDictionary.sortAvailableIfos, "available_ifos")
        or find_upvalue(ReaderDictionary.updateSdcvDictNamesOptions, "available_ifos")
    return type(ifos) == "table" and ifos or nil
end

--- Names used by StarDict dictionaries (so MDict titles can avoid them).
function Integration.stardictNames(ReaderDictionary)
    local names = {}
    for _, ifo in ipairs(Integration.availableIfos(ReaderDictionary) or {}) do
        if not ifo.mdict then names[ifo.name] = true end
    end
    return names
end

--- Puts the library's dictionaries into KOReader's list, replacing earlier MDict entries.
function Integration.syncIfos(ReaderDictionary, rd)
    local ifos = Integration.availableIfos(ReaderDictionary)
    if not ifos then
        Integration.ifos_injected = false
        return false
    end
    for i = #ifos, 1, -1 do
        if ifos[i].mdict then table.remove(ifos, i) end
    end
    for _, d in ipairs(Integration.state.library.dicts) do
        table.insert(ifos, { file = d.path, name = d.title, is_html = true, mdict = d.id })
    end
    Integration.ifos_injected = true
    if rd then
        rd:sortAvailableIfos()
        rd:updateSdcvDictNamesOptions()
    end
    return true
end

-- The MDict dictionaries to query for a list of requested names, in that order.
local function mdict_targets(rd, dict_names)
    local lib = Integration.state.library
    local targets, others = {}, {}
    if dict_names == nil then
        for _, d in ipairs(lib.dicts) do
            if not Integration.isDisabled(d) then targets[#targets + 1] = d end
        end
        return targets, nil
    end
    for _, name in ipairs(dict_names) do
        local d = lib:byTitle(name)
        if d then targets[#targets + 1] = d else others[#others + 1] = name end
    end
    -- Without our entries in KOReader's list, its enabled list never names us: query all.
    if #targets == 0 and not Integration.ifos_injected and dict_names == rd.enabled_dict_names then
        for _, d in ipairs(lib.dicts) do
            if not Integration.isDisabled(d) then targets[#targets + 1] = d end
        end
    end
    return targets, others
end

function Integration.isDisabled(d)
    local disabled = G_reader_settings and G_reader_settings:readSetting("dicts_disabled") or {}
    return disabled[d.path] == true
end

local function is_placeholder(results)
    if not results or #results == 0 then return true end
    if #results == 1 and (results[1].no_result or results[1].dict == "") then return true end
    return false
end

--- Candidate words for MDict, as ReaderDictionary:startSdcv builds them for sdcv.
function Integration.candidates(rd, word)
    local words = { word }
    if rd.ui and rd.ui.languagesupport and rd.ui.languagesupport:hasActiveLanguagePlugins() then
        local ok, extra = pcall(rd.ui.languagesupport.extraDictionaryFormCandidates, rd.ui.languagesupport, word)
        if ok and extra then
            for _, w in ipairs(extra) do words[#words + 1] = w end
        end
    end
    return words
end

local function has_cjk(s)
    -- CJK ideographs, kana, hangul (rough, as KOReader's util.hasCJKChar)
    return s:find("[\227-\237][\128-\191][\128-\191]") ~= nil
end

--- Japanese and Chinese text has no spaces, so a selection often runs past the
-- word: try shorter and shorter prefixes until one is a headword.
function Integration.prefixLookup(targets, word, display)
    local chars = {}
    for c in word:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = c end
    for n = math.min(#chars, Integration.MAX_PREFIX) - 1, 1, -1 do
        local prefix = table.concat(chars, "", 1, n)
        local mres, problems = Lookup.run(targets, { prefix }, { display_word = display,
            tick = Integration.showLookupMessage })
        if #mres > 0 or #problems > 0 then return mres, problems end
    end
    return {}, {}
end

Integration.MAX_PREFIX = 12

-- KOReader's lookup message ("Searching dictionary for: …") is shown after a delay, by its
-- scheduler: sdcv's search gives the scheduler control while it waits, MDict's lookups and the
-- WebView laying out the first result do not, so a lookup that took seconds there showed
-- nothing. The plugin shows the message itself once the delay has passed (see
-- Integration.showLookupMessage), until the popup is up.
Integration.pending_message = nil -- { rd, msg, due }

--- When the pending lookup message is due (clock time), or nil.
function Integration.lookupMessageDue()
    local p = Integration.pending_message
    return p and p.due or nil
end

--- Shows KOReader's lookup message now if its delay has passed and it is still hidden.
function Integration.showLookupMessage()
    local p = Integration.pending_message
    if not p or clock() < p.due then return end
    Integration.pending_message = nil
    local msg = p.msg
    if not (msg and p.rd.lookup_progress_msg == msg and msg.invisible) then return end
    local UIManager = require("ui/uimanager")
    local ok, err = pcall(function()
        if msg._delayed_show_action then
            UIManager:unschedule(msg._delayed_show_action)
            msg._delayed_show_action = nil
        end
        msg.invisible = false
        msg:onShow()
        UIManager:forceRePaint()
    end)
    if not ok then require("logger").warn("MDict: cannot show the lookup message:", err) end
end

--- The wrapped startSdcv.
function Integration.startSdcv(orig, rd, word, dict_names, fuzzy_search)
    local _ = require("gettext")
    local T = require("ffi/util").template
    local targets, others = mdict_targets(rd, dict_names)
    if #targets == 0 then
        return orig(rd, word, dict_names, fuzzy_search)
    end
    local results
    local t_sdcv = clock()
    Integration.lookup_started = t_sdcv
    if others == nil or #others > 0 then
        results = orig(rd, word, others, fuzzy_search)
    else
        results = {}
    end
    t_sdcv = clock() - t_sdcv
    local msg = rd.lookup_progress_msg
    Integration.pending_message = nil
    if type(msg) == "table" and msg.invisible then
        Integration.pending_message = { rd = rd, msg = msg,
            due = Integration.lookup_started + (tonumber(rd.lookup_msg_delay) or 0.5) }
    end
    local words = Integration.candidates(rd, word)
    local all_cjk = true
    for _, w in ipairs(words) do
        if not has_cjk(w) then all_cjk = false end
    end
    local display = Integration.pending_display and Integration.pending_display[word]
    local st = require("mdict/reader").stats
    st.key_blocks, st.record_blocks, st.bytes, st.seconds = 0, 0, 0, 0
    local t0, c0 = clock(), os.clock()
    local mres, problems = Lookup.run(targets, words, { fuzzy = fuzzy_search and not all_cjk, display_word = display,
        tick = Integration.showLookupMessage })
    if #mres == 0 and #problems == 0 and all_cjk then
        mres, problems = Integration.prefixLookup(targets, word, display)
    end
    require("logger").info(string.format("MDict: looked up in %d dictionaries: %d results in %.0f ms (%.0f ms CPU),"
        .. " %d key and %d record blocks (%.0f KB) decoded in %.0f ms; other dictionaries %.0f ms",
        #targets, #mres, (clock() - t0) * 1000, (os.clock() - c0) * 1000,
        st.key_blocks, st.record_blocks, st.bytes / 1024, st.seconds * 1000, t_sdcv * 1000))
    for __, p in ipairs(problems) do
        local text
        if p.state == "indexing" then
            text = T(_("%1 is being indexed. It will answer lookups once indexing finishes."), p.dict.title)
            Integration.state.waiting_for_index = Integration.state.waiting_for_index or {}
            for _i, f in ipairs(p.dict.files or {}) do
                if f.building then Integration.state.waiting_for_index[f.path] = true end
            end
            if Integration.state.promoteIndexes then
                Integration.state.promoteIndexes(Integration.state.waiting_for_index)
            end
        else
            text = T(_("%1 could not be opened: %2"), p.dict.title, tostring(p.state))
        end
        mres[#mres + 1] = { dict = p.dict.title, word = word, definition = text, mdict_note = true }
    end
    if #mres == 0 then
        if #results == 0 then
            -- sdcv was skipped: give KOReader the placeholder it would have made (it reads results[1])
            return { { dict = _("Not available"), word = word, definition = _("No results."),
                       no_result = true, lookup_cancelled = false } }
        end
        return results
    end
    local cancelled = results.lookup_cancelled
    if is_placeholder(results) then results = {} end
    -- merge in the requested dictionary order (sdcv already returns its results in that order)
    local order = {}
    for i, name in ipairs(dict_names or rd.enabled_dict_names or {}) do
        if not order[name] then order[name] = i end
    end
    local merged = {}
    for i, r in ipairs(results) do merged[#merged + 1] = { r = r, i = i } end
    for i, r in ipairs(mres) do merged[#merged + 1] = { r = r, i = #results + i } end
    local big = math.huge
    table.sort(merged, function(a, b)
        local pa, pb = order[a.r.dict] or big, order[b.r.dict] or big
        if pa ~= pb then return pa < pb end
        return a.i < b.i
    end)
    local out = {}
    for i, m in ipairs(merged) do out[i] = m.r end
    out.lookup_cancelled = cancelled
    return out
end

--- Screen pixels for a CSS px in KOReader's dictionary popup: its text size (dict_font_size,
-- scaled for the screen as the popup does) for 16 px, the size of a browser's default text.
function Integration.cssPx(font_size)
    local ok, Device = pcall(require, "device")
    local screen = ok and type(Device) == "table" and Device.screen
    if not (screen and screen.scaleBySize) then return 1 end
    font_size = font_size or (G_reader_settings and G_reader_settings:readSetting("dict_font_size")) or 20
    return screen:scaleBySize(font_size) / 16
end

--- Readies an MDict result for KOReader's own renderer (MuPDF): extracts its resources, gives
-- it the dictionary's CSS, and scales the absolute lengths in that CSS and in the entry's style
-- attributes to the popup's text size. font_size: the popup's, when there is one.
function Integration.prepareStatic(r, d, font_size)
    if r.mdict_static then return end
    r.mdict_static = true
    pcall(d.prefetch, d, r.definition)
    local px = Integration.cssPx(font_size)
    local ok, css = pcall(d.staticCss, d, r.definition, px)
    if ok then
        r.css = css
        if px ~= 1 then r.definition = Html.scaleStyleAttributes(r.definition, px) end
    else
        require("logger").warn("MDict: stylesheets for", d.title, "failed:", css)
    end
end

--- The wrapped showDict: restores MDict fields. Results MuPDF shows are readied for it one
-- at a time, when shown (see installWidgetHooks): readying all of them first extracted the
-- resources of every dictionary that answered, and built and scaled each one's stylesheets.
function Integration.prepareResults(results)
    if not results then return end
    local lib = Integration.state.library
    for _, r in ipairs(results) do
        if r.mdict then
            local d = lib:byId(r.mdict.id)
            r.is_html = true
            if d then
                r.dictionary_resource_directory = d.res_dir
                r.css = d:userCss()
            end
        end
    end
end

function Integration.install(state)
    Integration.state = state
    if Integration.installed then return end
    Integration.installed = true

    local ReaderDictionary = require("apps/reader/modules/readerdictionary")
    local orig_startSdcv = ReaderDictionary.startSdcv
    ReaderDictionary.startSdcv = function(rd, word, dict_names, fuzzy_search)
        return Integration.startSdcv(orig_startSdcv, rd, word, dict_names, fuzzy_search)
    end

    local orig_showDict = ReaderDictionary.showDict
    ReaderDictionary.showDict = function(rd, word, results, ...)
        local ok, err = pcall(Integration.prepareResults, results)
        if not ok then require("logger").warn("MDict: preparing results failed:", err) end
        local a, b = orig_showDict(rd, word, results, ...)
        Integration.pending_message = nil -- the popup is up (KOReader closed the message)
        return a, b
    end

    local orig_link = ReaderDictionary.onHtmlDictionaryLinkTapped
    ReaderDictionary.onHtmlDictionaryLinkTapped = function(rd, dictionary, link)
        local uri = link and link.uri
        if uri and Integration.state.library:byTitle(dictionary) then
            -- handled inside the entry (bword://#x: a place in the same entry, nothing to look up)
            if uri:sub(1, 1) == "#" or uri:find("^bword://#") then return end
            local sound = Html.soundPath(uri)
            if sound then
                if Integration.state.playSound then Integration.state.playSound(dictionary, sound, link.sources) end
                return
            end
            local prefix, word = uri:match("^(bword://)(.*)$")
            if not prefix and not uri:find("://") then prefix, word = "", uri end
            if word then
                -- targets are written URL-encoded ("nucleic%20acid"), keys are not
                local decoded = Html.decodeLinkTarget(word)
                if decoded ~= word then
                    local copy = {}
                    for k, v in pairs(link) do copy[k] = v end
                    copy.uri, link, word = prefix .. decoded, copy, decoded
                end
                if link.text and link.text ~= "" then
                    Integration.pending_display = { [word] = link.text }
                end
            end
        end
        local ok, err = pcall(orig_link, rd, dictionary, link)
        Integration.pending_display = nil
        if not ok then error(err, 0) end
    end

    Integration.installWidgetHooks()
end

--- DictQuickLookup: MDict results go to the plugin's renderer when it provides a widget.
function Integration.installWidgetHooks()
    local DictQuickLookup = require("ui/widget/dictquicklookup")
    local orig_instantiate = DictQuickLookup._instantiateScrollWidget
    local orig_update = DictQuickLookup.update
    local orig_init = DictQuickLookup.init
    local orig_close = DictQuickLookup.onCloseWidget
    local orig_paint = DictQuickLookup.paintTo

    -- lays out the next MDict result while the reader looks at this one
    local function prefetch(dql)
        local p = Integration.state.prefetch
        if p then
            local ok, err = pcall(p, dql)
            if not ok then require("logger").warn("MDict: prefetch failed:", err) end
        end
    end

    -- a sound played from a result stops when the popup leaves it (or closes, or a lookup
    -- from it opens another popup)
    local function stop_sound()
        local stop = Integration.state.stopSound
        if stop then pcall(stop) end
    end

    local function web_result(dql)
        local r = dql.results and dql.results[dql.dict_index]
        if not (r and r.mdict and Integration.state.widget) then return nil end
        return r
    end

    DictQuickLookup._instantiateScrollWidget = function(dql)
        local r = web_result(dql)
        if r then
            local widget = Integration.state.widget(dql, r)
            if widget then
                -- it is a ScrollHtmlWidget, so find and text selection reach it the usual way
                dql.mdict_widget, dql.mdict_widget_result = widget, r
                dql.shw_widget, dql.stw_widget = widget, nil
                dql.text_widget = widget
                return
            end
        end
        dql.mdict_widget, dql.mdict_widget_result = nil, nil
        -- an MDict result that MuPDF shows after all (the WebView could not)
        r = dql.results and dql.results[dql.dict_index]
        local d = r and r.mdict and not r.mdict_static and Integration.state.library:byId(r.mdict.id)
        if d then
            Integration.prepareStatic(r, d, dql.dict_font_size)
            dql.css, dql.definition = r.css, r.definition
        end
        return orig_instantiate(dql)
    end

    DictQuickLookup.update = function(dql)
        stop_sound()
        local r = web_result(dql)
        if r or dql.mdict_widget then
            -- switching to, from or between MDict entries: always build a fresh widget (or
            -- take one laid out ahead); one the reader leaves may be kept for their return
            local old = dql.text_widget
            local keep = Integration.state.keep
            if old and old == dql.mdict_widget and keep and keep(dql, old, dql.mdict_widget_result) then
                old = nil
            end
            if old and old.free then old:free() end
            dql.text_widget = nil
            dql.shw_widget, dql.stw_widget = nil, nil
        end
        local a, b = orig_update(dql)
        prefetch(dql)
        return a, b
    end

    if orig_init then
        DictQuickLookup.init = function(dql, ...)
            stop_sound()
            dql.mdict_lookup_started, Integration.lookup_started = Integration.lookup_started, nil
            local a, b = orig_init(dql, ...)
            Integration.pending_message = nil
            prefetch(dql)
            return a, b
        end
    end

    -- when a popup is first drawn, for the log (the screen shows it after its refresh)
    if orig_paint then
        DictQuickLookup.paintTo = function(dql, ...)
            local a, b = orig_paint(dql, ...)
            local t0 = dql.mdict_lookup_started
            if t0 then
                dql.mdict_lookup_started = nil
                require("logger").info(string.format("MDict: popup drawn %.0f ms after the lookup started",
                    (clock() - t0) * 1000))
            end
            return a, b
        end
    end

    DictQuickLookup.onCloseWidget = function(dql, ...)
        stop_sound()
        local drop = Integration.state.dropPrefetch
        if drop then pcall(drop, dql) end
        if orig_close then return orig_close(dql, ...) end
    end
end

return Integration
