require("spec.helper")
local Html = require("mdict/html")

describe("html", function()
    it("expands compact stylesheet markers", function()
        local styles = Html.parseStyleSheet("1\n<b>\n</b>\n2\n<i>\n</i>")
        assert.same({ "<b>", "</b>" }, styles[1])
        assert.equal("<b>bold</b><i>it</i>", Html.applyStyleSheet("`1`bold`2`it", styles))
        assert.equal("plain", Html.applyStyleSheet("plain", styles))
    end)

    it("rewrites round() as calc(), as the pager does", function()
        assert.equal(".a{--line:calc( 1.5em)}", Html.unround(".a{--line:round(nearest, 1.5em, 1px)}"))
        assert.equal(".a{line-height:calc(calc(1em) + 2px)}", Html.unround(".a{line-height:calc(ROUND(up,1em,1px) + 2px)}"))
        assert.equal("x{a:calc(1.5em);b:calc(2px)}", Html.unround("x{a:round(1.5em, 1px);b:round(2px)}"))
        -- nested, and a parenthesis inside a string
        assert.equal("x{a:calc( calc(calc(2px) + 1em))}",
            Html.unround("x{a:round(to-zero, calc(round(2px) + 1em), 1px)}"))
        assert.equal('x{a:calc(var(--a, ")"))}', Html.unround('x{a:round(var(--a, ")"), 1px)}'))
        -- other names that end in "round", and an unclosed call, stay as they are
        local same = ".around(x){} .a{--x-round(1px);_round(2px)} .b{line-height:1.5}"
        assert.equal(same, Html.unround(same))
        assert.equal("x{a:calc(1px)} y{b:round(2px", Html.unround("x{a:round(1px)} y{b:round(2px"))
    end)

    it("extracts unique stylesheets", function()
        local html, hrefs = Html.extractStylesheets(
            '<link rel="stylesheet" href="a.css"/><p>x</p><LINK REL=stylesheet HREF=a.css><link rel="icon" href="i.png">')
        assert.same({ "a.css" }, hrefs)
        assert.equal('<p>x</p><link rel="icon" href="i.png">', html)
    end)

    it("lists an entry's stylesheets and style elements in order", function()
        local sources = Html.styleSources('<style>.a{}</style><link rel="stylesheet" href="a.css"/><p>x</p>'
            .. '<LINK REL=stylesheet HREF=a.css><linkx rel="stylesheet" href="x.css"><link rel="icon" href="i.png">'
            .. '<STYLE type="text/css">.b{}</STYLE ><style/><stylex>.c{}</stylex><link href="b.css" rel="Stylesheet">'
            .. "<style>.d{}")
        assert.same({ { text = ".a{}" }, { href = "a.css" }, { text = ".b{}" }, { href = "b.css" }, { text = ".d{}" } },
            sources)
        assert.same({}, Html.styleSources("<p>plain</p>"))
    end)

    it("scales absolute CSS lengths", function()
        assert.equal("a{font-size:28px;margin:0 -4px 1.5em 2px;font:24px/1.4 serif}",
            Html.scaleLengths("a{font-size:14px;margin:0 -2px 1.5em 1PX;font:9pt/1.4 serif}", 2))
        assert.equal("b{width:calc(100% - 192px);border:1.5px solid;padding:32px}",
            Html.scaleLengths("b{width:calc(100% - 1in);border:.75px solid;padding:1rem}", 2))
        -- not in names, urls or numbers without units
        assert.equal('.w10px,.a-2px{background:url("img/10px.png");z-index:10;line-height:1.2}',
            Html.scaleLengths('.w10px,.a-2px{background:url("img/10px.png");z-index:10;line-height:1.2}', 2))
        assert.equal([[<p style="font-size:24px" data-style="x:1px"><b STYLE='margin: 3px'>]],
            Html.scaleStyleAttributes([[<p style="font-size:12px" data-style="x:1px"><b STYLE='margin: 1.5px'>]], 2))
    end)

    it("rewrites link schemes", function()
        assert.equal('<a href="bword://run#s1">', Html.rewriteLinks('<a href="entry://run#s1">'))
        -- a place in the same entry: no lookup
        assert.equal('<a href="#s1" onclick="go()">', Html.rewriteLinks('<a href="entry://#s1" onclick="go()">'))
        assert.equal("<a HREF='#s1'>", Html.rewriteLinks("<a HREF='ENTRY://#s1'>"))
        assert.equal("<a href='mdict-sound://a/b.aac'>", Html.rewriteLinks("<a href='sound://a/b.aac'>"))
        assert.equal('<img src="img/x.png">', Html.rewriteLinks('<img src="file://img/x.png">'))
        assert.equal('<a href="https://example.com">', Html.rewriteLinks('<a href="https://example.com">'))
    end)

    it("finds local resources", function()
        local refs = Html.resourceRefs('<img src="a.png"><img src="https://x/y.png"><span style="background:url(\'b.svg\')">'
            .. '<a href="#x"><script src="s.js"></script>')
        assert.same({ "a.png", "b.svg", "s.js" }, refs)
        assert.same({ "f/x.otf", "base.css" }, Html.cssRefs('@font-face{src:url("f/x.otf")} @import "base.css";'))
    end)

    it("normalises resource paths", function()
        assert.equal("img/a b.png", Html.resourcePath("file://img/a%20b.png?x=1"))
        assert.equal("css/img/x.png", Html.resourcePath("../img/x.png", "css/sub"))
        assert.equal("x.png", Html.resourcePath("/x.png", "css"))
        assert.equal("\\img\\a.png", Html.mddKey("img/a.png"))
    end)

    it("detects vertical writing and anchors", function()
        assert.is_true(Html.looksVertical(".a{ writing-mode: vertical-rl }"))
        assert.is_false(Html.looksVertical(".a{ writing-mode: horizontal-tb }"))
        assert.same({ "run", "s2" }, { Html.splitAnchor("run#s2") })
        assert.same({ "run" }, { Html.splitAnchor("run") })
        assert.equal("nucleic acid", Html.decodeLinkTarget("nucleic%20acid"))
        assert.equal("言葉#s1", Html.decodeLinkTarget("%E8%A8%80%E8%91%89#s1"))
        assert.equal("C%23 sharp", Html.decodeLinkTarget("C%23%20sharp"))
    end)
end)
