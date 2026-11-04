local helper = require("spec.helper")

describe("reader", function()
    local Reader = require("mdict/reader")
    local fx = helper.fixtures()

    local function keymap(d)
        local m = {}
        d:eachKey(function(k, ord) m[k] = m[k] or ord end)
        return m
    end

    for _, name in ipairs({ "basic.mdx", "v12.mdx", "utf16.mdx", "raw.mdx", "unsorted.mdx" }) do
        it("reads every record of " .. name, function()
            local d = assert(Reader.open(fx .. "/" .. name))
            local m = keymap(d)
            local n = 0
            for k, ord in pairs(m) do
                local r = d:record(ord)
                assert.is_truthy(r and #r > 0, k)
                n = n + 1
            end
            assert.are.equal(d.num_entries, n)
            assert.are.equal("@@@LINK=Apple", d:record(m["apples"]))
            assert.is_truthy(d:record(m["Apple"]):find("a round fruit", 1, true))
            d:close()
        end)
    end

    it("parses the header", function()
        local d = assert(Reader.open(fx .. "/basic.mdx"))
        assert.are.equal("Basic Test", d.title)
        assert.are.equal("UTF-8", d.encoding)
        assert.are.equal(2, d.version)
        assert.is_false(d.is_mdd)
        d:close()
    end)

    it("takes the text out of a title written as HTML", function()
        -- as macOS's Cocoa HTML Writer writes it (现代汉语规范词典 from macOS)
        local page = '<!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01//EN" "http://www.w3.org/TR/html4/strict.dtd">\n'
            .. '<html>\n<head>\n  <meta http-equiv="Content-Type" content="text/html; charset=utf-8">\n'
            .. '  <title></title>\n  <style type="text/css">\n    p.p1 {margin: 0.0px; font: 12.0px Helvetica}\n'
            .. '  </style>\n</head>\n<body>\n<p class="p1"><span class="s1">现代&amp;Co</span></p>\n'
            .. '</body>\n</html>'
        assert.are.equal("现代&Co", Reader.cleanTitle(page))
        assert.are.equal("Named", Reader.cleanTitle("<html><head><TITLE>Named</TITLE></head><body>x</body></html>"))
        assert.are.equal("Bold é 漢", Reader.cleanTitle("<b>Bold</b> &#233; &#x6F22;"))
        assert.are.equal("Plain & simple", Reader.cleanTitle("Plain & simple"))
        assert.is_nil(Reader.cleanTitle("<p> </p>"))
        assert.is_nil(Reader.cleanTitle("  Title (No HTML code allowed)"))
    end)

    it("reads UTF-16 keys and binary resources from .mdd", function()
        local d = assert(Reader.open(fx .. "/basic.mdd"))
        assert.is_true(d.is_mdd)
        local m = keymap(d)
        assert.is_truthy(m["\\basic.css"])
        assert.is_truthy(m["\\img\\icon.png"])
        assert.are.equal("\137PNG", d:record(m["\\img\\icon.png"]):sub(1, 4))
        d:close()
    end)

    it("keeps duplicate keys and large records", function()
        local d = assert(Reader.open(fx .. "/multi.mdx"))
        local seen = {}
        d:eachKey(function(k, ord) seen[#seen + 1] = { k, d:record(ord) } end)
        assert.are.equal(4, #seen)
        assert.are.equal("bank", seen[1][1])
        assert.are.equal("<b>bank</b> (money)", seen[2][2])
        assert.are.equal(70000, #seen[4][2])
        d:close()
    end)

    it("ends a record at its terminator when the next key's record is further on", function()
        for _, enc in ipairs({ "utf-8", "utf-16" }) do
            local d = assert(Reader.open(fx .. "/order-" .. enc .. ".mdx"))
            local seen = {}
            d:eachKey(function(k, ord) seen[#seen + 1] = k .. "=" .. d:record(ord) end)
            assert.same({ "pitch=<p>tar</p>", "pitch=<p>field</p>", "pitcher=<p>jug</p>" }, seen)
            d:close()
        end
    end)

    it("reports unreadable files", function()
        local path = helper.tmpdir("bad") .. "/x.mdx"
        local f = io.open(path, "wb"); f:write("not a dictionary"); f:close()
        local d, err = Reader.open(path)
        assert.is_nil(d)
        assert.is_truthy(err)
        assert.is_nil(Reader.open("/nonexistent/file.mdx"))
    end)

    it("converts UTF-16", function()
        assert.are.equal("日本語€😀", Reader.utf16le_to_utf8(Reader.utf8_to_utf16le("日本語€😀")))
    end)
end)
