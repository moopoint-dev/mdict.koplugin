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
        assert.equal('<a href="bword://run#s1">run</a> <a HREF=\'mdict-sound://r.mp3\'>&#x1f50a;</a><img src="p.png">',
            Html.rewriteLinks(html):match("(<a .-<img[^>]*>)"))
        assert.equal('<link rel="stylesheet" href="a.css"><LINK REL="icon" HREF="i.ico"><p class="x">'
            .. '<a href="entry://run#s1">run</a> <a HREF=\'sound://r.mp3\'>&#x1f50a;</a><img src="file://p.png"></p>',
            Html.stripScripts(html))
    end)
end)
