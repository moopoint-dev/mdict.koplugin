require("spec.helper")
local Document = require("renderers/document")

describe("document", function()
    it("aliases dictionary fonts to local fonts and user files", function()
        local css, files = Document.fontAliasCss({ ["serif-cjk"] = { file = "/fonts/Mincho.otf", names = { "My Mincho" } } },
            { ["Hiragino Mincho ProN"] = "serif-cjk", Verdana = "sans" })
        local want = 'font-family:"Hiragino Mincho ProN";font-weight:100 549;'
            .. 'src:url(/__file__/f1.otf), local("My Mincho"), local("Noto Serif CJK JP")'
        assert.truthy(css:find(want, 1, true))
        assert.truthy(css:find('font-family:"Verdana";font-weight:550 900;src:local("Roboto Bold")', 1, true))
        assert.same({ ["f1.otf"] = "/fonts/Mincho.otf" }, files)
    end)

    it("builds a document whose key follows its inputs", function()
        local a, ka = Document.build({ stylesheets = { "style.css" } })
        local _, kb = Document.build({ stylesheets = { "style.css" }, user_css = "p{}" })
        local _, kc = Document.build({ stylesheets = { "style.css" } })
        assert.truthy(a:find('<link rel="stylesheet" href="style.css">', 1, true))
        assert.truthy(a:find("window.MDict = MDict", 1, true))
        assert.truthy(a:find('id="mdict-zoom"', 1, true))
        assert.are_not.equal(ka, kb)
        assert.equal(ka, kc)
        -- pager CSS comes after the dictionary's stylesheet
        assert.truthy(a:find("style.css", 1, true) < a:find("mdict-pager-css", 1, true))
    end)

    it("finds the font families a stylesheet uses", function()
        local fam = Document.cssFamilies([[
            /* font-family: "Commented Out"; */
            @font-face { font-family: "MK Sans"; font-weight: 600; src: url(a.otf) }
            @font-face { font-family: 'MK Sans'; font-style: italic; src: url(b.otf) }
            .hw { font-family: "Hiragino Mincho ProN", serif !important }
            p { font: 12px/1.4 Verdana, sans-serif; }
            .x { font-family: var(--f), "MK Sans" }
        ]])
        assert.same({ "MK Sans", "Hiragino Mincho ProN", "Verdana" }, fam.order)
        assert.same({ { weight = "600", style = "normal" }, { weight = "normal", style = "italic" } },
            fam.faces["MK Sans"])
    end)

    it("puts the user's font in place of the dictionary's for one script", function()
        local fam = Document.cssFamilies([[
            @font-face { font-family: "MK Sans"; font-weight: 700; src: url(a.otf) }
            @font-face { font-family: "MK Sans"; font-style: italic; src: url(b.otf) }
            .hw { font-family: "Hiragino Mincho ProN", "Local Font" }
        ]])
        local html, key, files = Document.build({ stylesheets = { "style.css" }, css_families = fam,
            user_font = { file = "/fonts/Mine.ttf", scope = "cjk" } })
        local token
        for t, p in pairs(files) do if p == "/fonts/Mine.ttf" then token = t end end
        assert.truthy(token)
        local css = html:match('<style id="mdict%-user%-font">(.-)</style>')
        assert.truthy(css)
        local cjk = Document.USER_FONT_RANGES.cjk
        -- after the dictionary's stylesheet, so its faces win for the range
        assert.truthy(html:find("style.css", 1, true) < html:find("mdict-user-font", 1, true))
        assert.truthy(css:find('font-family:"MDict User";font-weight:100 900;src:url(/__file__/' .. token
            .. ');unicode-range:' .. cjk, 1, true))
        -- no bold file: the dictionary's bold and italic faces stay
        assert.falsy(css:find('"MK Sans"', 1, true))
        assert.truthy(css:find('font-family:"Hiragino Mincho ProN";font-weight:100 549;src:url', 1, true))
        -- a local font keeps serving the characters outside the range
        assert.truthy(css:find('font-family:"Local Font";font-weight:100 549;src:local("Local Font")}', 1, true))
        assert.truthy(html:find('body{font-family:"MDict User",serif}', 1, true))
        local _, key2 = Document.build({ stylesheets = { "style.css" }, css_families = fam,
            user_font = { file = "/fonts/Mine.ttf", bold_file = "/fonts/Mine-Bold.ttf", scope = "latin" } })
        assert.are_not.equal(key, key2)
        local html3 = Document.build({ stylesheets = { "style.css" }, css_families = fam,
            user_font = { file = "/fonts/Mine.ttf", bold_file = "/fonts/Mine-Bold.ttf" } })
        assert.truthy(html3:find('font-family:"MK Sans";font-weight:700;src:url', 1, true))
        assert.falsy(html3:find("font-style:italic", 1, true))
        -- with an italic file, italic text gets it too (WebView 91 would not slant the regular face)
        local html4 = Document.build({ stylesheets = { "style.css" }, css_families = fam,
            user_font = { file = "/fonts/Mine.ttf", italic_file = "/fonts/Mine-It.ttf" } })
        assert.truthy(html4:find('font-family:"MK Sans";font-weight:normal;font-style:italic;src:url', 1, true))
        assert.truthy(html4:find('font-family:"MDict User";font-weight:100 900;font-style:italic;src:url', 1, true))
        assert.truthy(html4:find('font-family:"Local Font";font-weight:100 549;font-style:italic;src:url', 1, true))
    end)
end)
