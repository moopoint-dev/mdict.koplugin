local helper = require("spec.helper")

-- G_reader_settings stub
local store = {}
_G.G_reader_settings = {
    readSetting = function(_, k) return store[k] end,
    saveSetting = function(_, k, v) store[k] = v end,
}

local Integration = require("mdict/integration")
local Library = require("mdict/library")
local ReaderDictionary = require("apps/reader/modules/readerdictionary")
local DictQuickLookup = require("ui/widget/dictquicklookup")

describe("integration", function()
    local lib, rd
    setup(function()
        ReaderDictionary.reset()
        ReaderDictionary.stardict = { { name = "Star", file = "/dict/star.ifo" } }
        ReaderDictionary.sdcv_db = { Star = { apples = "star apples", bank = "star bank" } }
        rd = ReaderDictionary:new({ ui = {} })
        local fx = helper.fixtures()
        lib = Library.new({ dirs = { fx }, cache_dir = helper.tmpdir("integ") })
        lib:scan(Integration.stardictNames(ReaderDictionary))
        Integration.install({ library = lib })
        assert.is_true(Integration.syncIfos(ReaderDictionary, rd))
    end)

    it("adds MDict dictionaries to KOReader's list", function()
        local names = {}
        for _, n in ipairs(rd.enabled_dict_names) do names[n] = true end
        assert.is_true(names["Star"])
        assert.is_true(names["Basic Test"])
        assert.is_true(names["Multi"])
        -- syncing again does not duplicate them
        local n = #rd.enabled_dict_names
        Integration.syncIfos(ReaderDictionary, rd)
        assert.equal(n, #rd.enabled_dict_names)
    end)

    it("merges results in dictionary order and skips sdcv when not needed", function()
        local results = rd:startSdcv("apples", rd.enabled_dict_names, false)
        assert.equal("Basic Test", results[1].dict)
        assert.equal("Apple", results[1].word)
        assert.is_true(results[1].is_html)
        local found_star = false
        for _, r in ipairs(results) do if r.dict == "Star" then found_star = true end end
        assert.is_true(found_star)
        -- sdcv did not receive MDict names
        for _, name in ipairs(rd.last_sdcv_names) do assert.is_nil(lib:byTitle(name)) end
        local calls = rd.sdcv_calls
        results = rd:startSdcv("Bank", { "Multi" }, false)
        assert.equal(calls, rd.sdcv_calls)
        assert.equal(3, #results)
        -- nothing anywhere: KOReader's placeholder stays
        results = rd:startSdcv("zzzzqqq", rd.enabled_dict_names, false)
        assert.is_true(results[1].no_result)
    end)

    it("looks up the longest Japanese prefix that is a headword", function()
        local results = rd:startSdcv("日本語の辞書", { "Basic Test" }, false)
        assert.equal("日本語", results[1].word)
        assert.is_true(results[1].is_html)
        results = rd:startSdcv("本語", { "Basic Test" }, false)
        assert.is_true(results[1].no_result)
    end)

    it("adds a note for dictionaries that cannot answer yet", function()
        local d = lib:byTitle("Multi")
        local orig = d.lookup
        d.lookup = function() return nil, "indexing" end
        local ok, results = pcall(rd.startSdcv, rd, "Bank", { "Multi" }, false)
        d.lookup = orig
        assert.is_true(ok, tostring(results))
        assert.equal(1, #results)
        assert.is_true(results[1].mdict_note)
        assert.truthy(results[1].definition:find("being indexed", 1, true))
    end)

    it("replaces placeholders and keeps MDict fields through showDict", function()
        rd:stardictLookup("lookup", { "Basic Test" }, false)
        assert.equal(2, #rd.shown.results)
        rd:stardictLookup("apples", { "Basic Test" }, false)
        local r = rd.shown.results
        assert.equal(1, #r)
        assert.is_true(r[1].is_html)
        assert.equal(lib:byTitle("Basic Test").res_dir, r[1].dictionary_resource_directory)
        -- MuPDF needs the resources up front when no other renderer is active
        assert.truthy(require("mdict/fs").isFile(lib:byTitle("Basic Test").res_dir .. "/basic.css"))
        -- and the entry's stylesheet in its CSS: MuPDF does not read the <link> in the entry
        assert.truthy(r[1].css:find(".hw{font-weight:bold}", 1, true))
    end)

    it("handles MDict link schemes", function()
        local played
        Integration.state.playSound = function(dict, path, sources) played = { dict, path, sources } end
        rd.shown = nil
        rd:onHtmlDictionaryLinkTapped("Basic Test", { uri = "mdict-sound://audio/x.mp3" })
        assert.same({ "Basic Test", "audio/x.mp3" }, played)
        assert.is_nil(rd.shown)
        -- an audio player's sources (see WebHtmlBoxWidget:_tapEntry)
        rd:onHtmlDictionaryLinkTapped("Basic Test",
            { uri = "mdict-sound://a.mp3", sources = { "a.mp3", "https://example.org/a.mp3" } })
        assert.same({ "Basic Test", "a.mp3", { "a.mp3", "https://example.org/a.mp3" } }, played)
        rd:onHtmlDictionaryLinkTapped("Basic Test", { uri = "#sense2" })
        assert.is_nil(rd.shown)
        rd:onHtmlDictionaryLinkTapped("Basic Test", { uri = "bword://apples", text = "apples!" })
        assert.equal("Apple", rd.shown.results[1].word)
        -- targets are URL-encoded in some dictionaries
        rd.shown = nil
        local link = { uri = "bword://%61pples", text = "apples" }
        rd:onHtmlDictionaryLinkTapped("Basic Test", link)
        assert.equal("Apple", rd.shown.results[1].word)
        assert.equal("bword://%61pples", link.uri)
        Integration.state.playSound = nil
    end)

    it("lets the renderer provide the definition widget", function()
        local made = 0
        Integration.state.widget = function(_, r)
            made = made + 1
            return { kind = "web", html = r.mdict.html, free = function() end }
        end
        local results = rd:startSdcv("apples", rd.enabled_dict_names, false)
        local dql = DictQuickLookup:new({ results = results })
        assert.equal("web", dql.text_widget.kind)
        -- switch to the StarDict result and back
        local star
        for i, r in ipairs(results) do if r.dict == "Star" then star = i end end
        dql:changeDictionary(star)
        assert.equal("text", dql.text_widget.kind)
        dql:changeDictionary(1)
        assert.equal("web", dql.text_widget.kind)
        assert.equal(2, made)
        Integration.state.widget = nil
    end)

    it("stops a result's sound when the popup leaves the result or closes", function()
        local stops = 0
        Integration.state.stopSound = function() stops = stops + 1 end
        local results = rd:startSdcv("apples", rd.enabled_dict_names, false)
        local dql = DictQuickLookup:new({ results = results })
        local opened = stops
        dql:changeDictionary(2)
        assert.equal(opened + 1, stops)
        dql:onCloseWidget()
        assert.equal(opened + 2, stops)
        Integration.state.stopSound = nil
    end)

    it("gives MuPDF the dictionary's CSS for a result the renderer cannot show", function()
        Integration.state.renderer = function() return {} end
        Integration.state.widget = function() return nil end
        rd:stardictLookup("apples", { "Basic Test" }, false)
        local r = rd.shown.results[1]
        assert.is_nil(r.css)
        local dql = DictQuickLookup:new({ results = rd.shown.results })
        assert.equal("html", dql.text_widget.kind)
        assert.truthy(dql.css:find(".hw{font-weight:bold}", 1, true))
        Integration.state.renderer, Integration.state.widget = nil, nil
    end)

    it("asks for the next result to be laid out ahead, and drops it on close", function()
        local seen, dropped = {}, 0
        Integration.state.widget = function(_, r) return { kind = "web", html = r.mdict.html, free = function() end } end
        Integration.state.prefetch = function(d) seen[#seen + 1] = d.dict_index end
        Integration.state.dropPrefetch = function() dropped = dropped + 1 end
        local results = rd:startSdcv("apples", rd.enabled_dict_names, false)
        local dql = DictQuickLookup:new({ results = results })
        assert.same({ 1 }, seen)
        dql:changeDictionary(2)
        assert.same({ 1, 2 }, seen)
        dql:paintTo()
        assert.equal(1, dql.painted)
        assert.is_nil(dql.mdict_lookup_started) -- logged once
        dql:onCloseWidget()
        assert.equal(1, dropped)
        assert.is_true(dql.closed)
        Integration.state.widget, Integration.state.prefetch, Integration.state.dropPrefetch = nil, nil, nil
    end)
end)
