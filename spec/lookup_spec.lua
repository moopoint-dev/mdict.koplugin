local helper = require("spec.helper")
local Dictionary = require("mdict/dictionary")
local Lookup = require("mdict/lookup")

describe("lookup", function()
    it("finds readable headwords", function()
        assert.equal("bank", Lookup.headwordOf('<div class="x"><span class="hw">bank<br>'
            .. '<sup>1</sup></span> money</div>'):gsub("%s*1$", ""))
        assert.is_nil(Lookup.headwordOf("<p>nothing</p>"))
        assert.is_true(Lookup.isInternalKey("EXPORT:83:49022"))
        assert.is_true(Lookup.isInternalKey("EXPORT:83:File:appendix/x.html"))
        assert.is_false(Lookup.isInternalKey("run"))
        assert.is_false(Lookup.isInternalKey("U.S.A."))
        assert.is_true(Lookup.isInternalKey("LINKe578507222d7199d1963a0b4"))
        assert.is_false(Lookup.isInternalKey("decaf"))
        assert.is_false(Lookup.isInternalKey("0123456789abcdef and more"))
        assert.is_true(Lookup.isRecordKey("OKG1121512"))
        assert.is_true(Lookup.isRecordKey("SKOGO10259"))
        assert.is_false(Lookup.isRecordKey("MP3"))
        assert.is_false(Lookup.isRecordKey("COVID-19"))
        assert.is_false(Lookup.isRecordKey("Win2000"))
    end)

    it("names an entry that a word links to by record number after the entry", function()
        local fx = helper.fixtures()
        local d = Dictionary.new({ path = fx .. "/basic.mdx", cache_dir = helper.tmpdir("lk3"), title = "Basic" })
        local results = Lookup.run({ d }, { "banana" })
        assert.equal(1, #results)
        assert.equal("FRT0001234", results[1].mdict.key)
        assert.equal("ba·nana", results[1].word)
        -- the key is kept when it is a word
        assert.equal("Apple", Lookup.run({ d }, { "apples" })[1].word)
        -- or when it was looked up itself
        assert.equal("FRT0001234", Lookup.run({ d }, { "FRT0001234" })[1].word)
        d:close()
    end)

    it("builds KOReader results with a script-free fallback", function()
        local fx = helper.fixtures()
        local d = Dictionary.new({ path = fx .. "/basic.mdx", cache_dir = helper.tmpdir("lk"), title = "Basic" })
        local m = Dictionary.new({ path = fx .. "/multi.mdx", cache_dir = helper.tmpdir("lk2"), title = "Multi" })
        local results, problems = Lookup.run({ m, d }, { "Bank", "apples" })
        assert.same({}, problems)
        assert.equal(4, #results)
        assert.equal("Multi", results[1].dict)
        assert.equal("Bank", results[1].word)
        assert.equal("Basic", results[4].dict)
        assert.equal("Apple", results[4].word)
        assert.is_true(results[4].is_html)
        assert.equal(d.res_dir, results[4].dictionary_resource_directory)
        assert.matches("bword://apples", results[4].mdict.html)
    end)

    it("prepares an entry's HTML only when its result is read", function()
        local fx = helper.fixtures()
        local m = Dictionary.new({ path = fx .. "/multi.mdx", cache_dir = helper.tmpdir("lk3"), title = "Multi" })
        local prepared = 0
        local entryHtml = m.entryHtml
        m.entryHtml = function(...) prepared = prepared + 1; return entryHtml(...) end
        local results = Lookup.run({ m }, { "Bank" })
        assert.is_true(#results > 1)
        assert.equal(0, prepared)
        assert.equal("Bank", results[1].word)
        assert.equal(0, prepared)
        local html = results[1].mdict.html
        assert.is_nil(results[1].definition:find("<script", 1, true))
        assert.equal(html, results[1].mdict.html)
        assert.equal(1, prepared)
    end)

    it("finds stylesheets, links and scripts where they are", function()
        local Html = require("mdict/html")
        local html = '<link rel="stylesheet" href="a.css"><LINK REL="icon" HREF="i.ico"><p class="x">'
            .. '<a href="entry://run#s1">run</a> <a HREF=\'sound://r.mp3\'>&#x1f50a;</a><img src="file://p.png">'
            .. '<script>var s = "<b>"</script><Script src="x.js"/></p>'
        local stripped, hrefs = Html.extractStylesheets(html)
        assert.same({ "a.css" }, hrefs)
        assert.is_nil(stripped:find("a.css", 1, true))
        assert.equal('<a href="bword://run#s1">run</a> <a HREF=\'sound://r.mp3\'>&#x1f50a;</a><img src="p.png">',
            Html.rewriteLinks(html):match("(<a .-<img[^>]*>)"))
        assert.equal('<link rel="stylesheet" href="a.css"><LINK REL="icon" HREF="i.ico"><p class="x">'
            .. '<a href="entry://run#s1">run</a> <a HREF=\'sound://r.mp3\'>&#x1f50a;</a><img src="file://p.png"></p>',
            Html.stripScripts(html))
    end)
    describe("repeated entries", function()
        local L, HR, END = '<link rel="stylesheet" href="d.css">', "<hr>", "\r\n"
        local function div(text) return '<div class="e"><span class="hw">' .. text .. '</span>'
            .. string.rep(" " .. text, 40) .. '</div>' end
        local U1, U2, U3, U4 = div("one"), div("two"), div("three"), div("four")
        local function trim(...)
            local entries = {}
            for i, r in ipairs({ ... }) do entries[i] = type(r) == "table" and r or { key = "k" .. i, record = r } end
            local out = {}
            for i, e in ipairs(Lookup.trimRepeats(entries)) do out[i] = e.key .. "=" .. e.record end
            return out
        end

        it("shows each entry of a dictionary once", function()
            local fx = helper.fixtures()
            local d = Dictionary.new({ path = fx .. "/repeats.mdx", cache_dir = helper.tmpdir("lk4"), title = "Repeats" })
            local results = Lookup.run({ d }, { "spring" })
            assert.equal(2, #results)
            assert.equal("spring", results[1].mdict.key)
            assert.matches("the season", results[1].mdict.html)
            assert.is_nil(results[1].mdict.html:find("a coil", 1, true))
            assert.is_nil(results[1].definition:find("<hr>", 1, true))
            assert.equal("\u{3010}spring\u{3011}", results[2].mdict.key)
            assert.matches("a coil", results[2].mdict.html)
        end)

        it("finds the entries of a record", function()
            local r = L .. '<!-- c --> text <i>x</i><p>a<br/>b<script>if (a<b) {}</script></p>'
                .. '<script>s()</script><img src="p.png"/>' .. HR .. L .. '<div>c < d</div>\r\n'
            local got = {}
            for i, u in ipairs(Lookup.entriesOf(r)) do got[i] = r:sub(u.from, u.to) end
            assert.same({ "text", "<i>x</i>", '<p>a<br/>b<script>if (a<b) {}</script></p><script>s()</script>',
                '<img src="p.png"/>', "<div>c < d</div>" }, got)
        end)

        it("cuts out of a page the entries that another result shows", function()
            assert.same({ "k1=" .. L .. U1 .. END, "k2=" .. L .. U2 .. END },
                trim(L .. U1 .. HR .. L .. U2 .. END, L .. U2 .. END))
            assert.same({ "k1=" .. L .. U2 .. END, "k2=" .. L .. U1 .. HR .. L .. U3 .. END },
                trim(L .. U2 .. END, L .. U1 .. HR .. L .. U2 .. HR .. L .. U3 .. END))
            assert.same({ "k1=" .. L .. U2 .. END, "k2=" .. L .. U1 .. END },
                trim(L .. U2 .. END, L .. U2 .. HR .. L .. U1 .. END))
        end)

        it("cuts entries that are apart or in another order", function()
            assert.same({ "k1=" .. L .. U2 .. HR .. L .. U4 .. END, "k2=" .. L .. U3 .. HR .. L .. U1 .. END },
                trim(L .. U1 .. HR .. L .. U2 .. HR .. L .. U3 .. HR .. L .. U4 .. END, L .. U3 .. HR .. L .. U1 .. END))
            -- an entry's own script goes with it
            local S = "<script>v()</script>"
            assert.same({ "k1=" .. L .. U1 .. S .. END, "k2=" .. L .. U2 .. S },
                trim(L .. U1 .. S .. HR .. L .. U2 .. S .. END, L .. U2 .. S))
        end)

        it("drops a page whose entries are all shown, and a repeat of an earlier result", function()
            assert.same({ "k2=" .. U1, "k3=" .. U2 }, trim(U1 .. HR .. U2, U1, U2))
            assert.same({ "k1=" .. L .. U1 }, trim(L .. U1, '<link rel="stylesheet" href="other.css">' .. U1))
            -- shared by two pages as long: the first keeps it
            assert.same({ "k1=" .. U1 .. HR .. U2, "k2=" .. U3 }, trim(U1 .. HR .. U2, U2 .. HR .. U3))
        end)

        it("leaves alone short entries, others' entries and pages a link points into", function()
            assert.same({ "k1=<b>x</b> one <i>two</i>", "k2=<i>two</i>" }, trim("<b>x</b> one <i>two</i>", "<i>two</i>"))
            assert.same({ "k1=" .. U1 .. U3, "k2=" .. U2 }, trim(U1 .. U3, U2))
            local U2a = U2:gsub('class="e"', 'class="e" id="s2"')
            assert.same({ "k1=" .. U1 .. HR .. U2a, "k2=" .. U2a },
                trim({ key = "k1", record = U1 .. HR .. U2a, anchor = "s2" }, U2a))
            assert.same({ "k1=" .. U1, "k2=" .. U2a }, trim({ key = "k1", record = U1 .. HR .. U2a, anchor = "s1" }, U2a))
        end)
    end)
end)
