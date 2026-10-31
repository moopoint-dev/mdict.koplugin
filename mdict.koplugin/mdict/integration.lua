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
- Link taps: "#anchor" links stay in the entry, mdict-sound:// plays audio.
- DictQuickLookup shows MDict results with the plugin's renderer when one is
  available (see Integration.widget).
]]

local Lookup = require("mdict/lookup")
local clock = require("mdict/clock")

local Integration = {
    installed = false,
    state = nil, -- { library, settings, renderer (optional), playSound (optional) }
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
        local mres, problems = Lookup.run(targets, { prefix }, { display_word = display })
        if #mres > 0 or #problems > 0 then return mres, problems end
    end
    return {}, {}
end

Integration.MAX_PREFIX = 12

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
    if others == nil or #others > 0 then
        results = orig(rd, word, others, fuzzy_search)
    else
        results = {}
    end
    t_sdcv = clock() - t_sdcv
    local words = Integration.candidates(rd, word)
    local all_cjk = true
    for _, w in ipairs(words) do
        if not has_cjk(w) then all_cjk = false end
    end
    local display = Integration.pending_display and Integration.pending_display[word]
    local st = require("mdict/reader").stats
    st.key_blocks, st.record_blocks, st.bytes, st.seconds = 0, 0, 0, 0
    local t0, c0 = clock(), os.clock()
    local mres, problems = Lookup.run(targets, words, { fuzzy = fuzzy_search and not all_cjk, display_word = display })
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

--- The wrapped showDict: restores MDict fields, prepares MuPDF resources when needed.
function Integration.prepareResults(results)
    if not results then return end
    local lib = Integration.state.library
    local static = not (Integration.state.renderer and Integration.state.renderer())
    for _, r in ipairs(results) do
        if r.mdict then
            local d = lib:byId(r.mdict.id)
            r.is_html = true
            if d then
                r.dictionary_resource_directory = d.res_dir
                r.css = d:userCss()
                if static then pcall(d.prefetch, d, r.definition) end
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
        return orig_showDict(rd, word, results, ...)
    end

    local orig_link = ReaderDictionary.onHtmlDictionaryLinkTapped
    ReaderDictionary.onHtmlDictionaryLinkTapped = function(rd, dictionary, link)
        local uri = link and link.uri
        if uri and Integration.state.library:byTitle(dictionary) then
            if uri:sub(1, 1) == "#" then return end -- handled inside the entry
            local sound = uri:match("^mdict%-sound://(.*)$")
            if sound then
                if Integration.state.playSound then Integration.state.playSound(dictionary, sound) end
                return
            end
            local prefix, word = uri:match("^(bword://)(.*)$")
            if not prefix and not uri:find("://") then prefix, word = "", uri end
            if word then
                -- targets are written URL-encoded ("nucleic%20acid"), keys are not
                local decoded = require("mdict/html").decodeLinkTarget(word)
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

    -- lays out the next MDict result while the reader looks at this one
    local function prefetch(dql)
        local p = Integration.state.prefetch
        if p then
            local ok, err = pcall(p, dql)
            if not ok then require("logger").warn("MDict: prefetch failed:", err) end
        end
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
                dql.mdict_widget = widget
                dql.shw_widget, dql.stw_widget = widget, nil
                dql.text_widget = widget
                return
            end
        end
        dql.mdict_widget = nil
        return orig_instantiate(dql)
    end

    DictQuickLookup.update = function(dql)
        local r = web_result(dql)
        if r or dql.mdict_widget then
            -- switching to, from or between MDict entries: always build a fresh widget
            if dql.text_widget and dql.text_widget.free then dql.text_widget:free() end
            dql.text_widget = nil
            dql.shw_widget, dql.stw_widget = nil, nil
        end
        local a, b = orig_update(dql)
        prefetch(dql)
        return a, b
    end

    if orig_init then
        DictQuickLookup.init = function(dql, ...)
            local a, b = orig_init(dql, ...)
            prefetch(dql)
            return a, b
        end
    end

    DictQuickLookup.onCloseWidget = function(dql, ...)
        local drop = Integration.state.dropPrefetch
        if drop then pcall(drop, dql) end
        if orig_close then return orig_close(dql, ...) end
    end
end

return Integration
