--[[--
Builds the pager document that the WebView keeps loaded for a dictionary.

One document holds the dictionary's stylesheets, the font aliases, the pager
CSS and pager.js. Entries are swapped into it with MDict.setEntry, so the
(often large) dictionary stylesheet is parsed once per dictionary rather than
once per lookup. A document is reused while its key is unchanged.
]]

local Document = {}

--- Font families that dictionaries name but Android does not have, and the
-- kind of font that replaces each one.
Document.FONT_ALIASES = {
    ["Hiragino Mincho ProN"] = "serif-cjk",
    ["Hiragino Mincho Pro"] = "serif-cjk",
    ["ヒラギノ明朝 ProN"] = "serif-cjk",
    ["ヒラギノ明朝 Pro"] = "serif-cjk",
    ["YuMincho"] = "serif-cjk",
    ["Yu Mincho"] = "serif-cjk",
    ["MS Mincho"] = "serif-cjk",
    ["Hiragino Kaku Gothic ProN"] = "sans-cjk",
    ["Hiragino Kaku Gothic Pro"] = "sans-cjk",
    ["ヒラギノ角ゴ ProN"] = "sans-cjk",
    ["ヒラギノ角ゴ Pro"] = "sans-cjk",
    ["Hiragino Sans"] = "sans-cjk",
    ["Hiragino Maru Gothic ProN"] = "sans-cjk",
    ["YuGothic"] = "sans-cjk",
    ["Yu Gothic"] = "sans-cjk",
    ["MS Gothic"] = "sans-cjk",
    ["Meiryo"] = "sans-cjk",
    ["PingFang SC"] = "sans-cjk",
    ["Palatino"] = "serif",
    ["Palatino Linotype"] = "serif",
    ["Book Antiqua"] = "serif",
    ["Times New Roman"] = "serif",
    ["Times"] = "serif",
    ["Georgia"] = "serif",
    ["Verdana"] = "sans",
    ["Helvetica"] = "sans",
    ["Helvetica Neue"] = "sans",
    ["Arial"] = "sans",
    ["Avenir Next"] = "sans",
    ["Lucida Grande"] = "sans",
}

--- Local font names tried for each kind, regular and bold, in order.
-- Names are full names and PostScript names as Android's font index knows them, then the
-- fonts of Kindle firmware (for the Kindle's browser). Its Chromium 75 matches local() against
-- family names only, and always finds the regular face: bold lists leave the family out, so
-- that their face fails and bold is drawn from the regular one.
Document.FONT_TARGETS = {
    ["serif-cjk"] = {
        regular = { "Noto Serif CJK JP", "NotoSerifCJKjp-Regular", "Noto Serif CJK JP Regular",
                    "Noto Sans CJK JP", "NotoSansCJKjp-Regular", "Noto Sans CJK JP Regular",
                    "TBMincho Medium", "MonotypeTBMincho-Medium", "TBMincho" },
        bold = { "Noto Serif CJK JP Bold", "NotoSerifCJKjp-Bold",
                 "Noto Sans CJK JP Bold", "NotoSansCJKjp-Bold",
                 "TBMincho Bold", "MonotypeTBMincho-Bold" },
    },
    ["sans-cjk"] = {
        regular = { "Noto Sans CJK JP", "NotoSansCJKjp-Regular", "Noto Sans CJK JP Regular",
                    "TBGothic Medium", "MonotypeTBGothic-Medium", "TBGothic" },
        bold = { "Noto Sans CJK JP Bold", "NotoSansCJKjp-Bold", "TBGothic Bold", "MonotypeTBGothic-Bold" },
    },
    serif = {
        regular = { "Noto Serif", "NotoSerif", "Noto Serif Regular", "NotoSerif-Regular",
                    "Bookerly Regular", "Bookerly-Regular", "Bookerly" },
        bold = { "Noto Serif Bold", "NotoSerif-Bold", "Bookerly Bold", "Bookerly-Bold" },
    },
    sans = {
        regular = { "Roboto", "Roboto-Regular", "Roboto Regular", "Noto Sans", "NotoSans-Regular",
                    "Amazon Ember Regular", "AmazonEmber-Regular", "Amazon Ember" },
        bold = { "Roboto Bold", "Roboto-Bold", "Noto Sans Bold", "NotoSans-Bold", "Amazon Ember Bold",
                 "AmazonEmber-Bold", "Amazon Ember" },
    },
}

local function css_string(s)
    return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\a ") .. '"'
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function ext_of(path)
    return (path:match("%.([%w]+)$") or "ttf"):lower()
end

--- @font-face rules mapping each alias to its replacement.
-- fonts: optional per-kind settings { [kind] = { file = path, bold_file = path, names = { ... } } }.
-- `file` is a font chosen by the user; `names` are extra local() names tried first.
-- regular_only: no bold faces (the reader's font has no bold, see userFontCss).
-- Returns the CSS and the files the WebView may serve: { [token] = path }.
function Document.fontAliasCss(fonts, aliases, regular_only)
    fonts = fonts or {}
    aliases = aliases or Document.FONT_ALIASES
    local files, nfiles = {}, 0
    local tokens = {}
    local function file_url(path)
        if not tokens[path] then
            nfiles = nfiles + 1
            local token = "f" .. nfiles .. "." .. ext_of(path)
            tokens[path] = token
            files[token] = path
        end
        return "url(/__file__/" .. tokens[path] .. ")"
    end
    local function sources(kind, weight)
        local conf = fonts[kind] or {}
        local target = Document.FONT_TARGETS[kind]
        local src = {}
        local file = weight == "bold" and (conf.bold_file or conf.file) or conf.file
        if file and file ~= "" then src[#src + 1] = file_url(file) end
        for _, n in ipairs(conf.names or {}) do src[#src + 1] = "local(" .. css_string(n) .. ")" end
        for _, n in ipairs(target[weight]) do src[#src + 1] = "local(" .. css_string(n) .. ")" end
        return table.concat(src, ", ")
    end
    local names = {}
    for family in pairs(aliases) do names[#names + 1] = family end
    table.sort(names)
    local out = {}
    for _, family in ipairs(names) do
        local kind = aliases[family]
        if Document.FONT_TARGETS[kind] then
            out[#out + 1] = string.format("@font-face{font-family:%s;font-weight:400;src:%s}",
                css_string(family), sources(kind, "regular"))
            if not regular_only then
                out[#out + 1] = string.format("@font-face{font-family:%s;font-weight:700;src:%s}",
                    css_string(family), sources(kind, "bold"))
            end
        end
    end
    return table.concat(out, "\n"), files
end

local GENERIC = {
    serif = true, ["sans-serif"] = true, monospace = true, cursive = true, fantasy = true, ["system-ui"] = true,
    ["ui-serif"] = true, ["ui-sans-serif"] = true, ["ui-monospace"] = true, ["ui-rounded"] = true, math = true,
    emoji = true, fangsong = true, inherit = true, initial = true, unset = true, revert = true,
    ["revert-layer"] = true,
}

local function family_list(value)
    local out = {}
    for item in (value .. ","):gmatch("([^,]*),") do
        local name = item:gsub("!%s*important", ""):match("^%s*(.-)%s*$")
        name = name:match('^"(.*)"$') or name:match("^'(.*)'$") or name
        if name ~= "" and not GENERIC[name:lower()] and not name:find("var%(") then out[#out + 1] = name end
    end
    return out
end

--- Font families a stylesheet uses: { order = { name... }, faces = { [name] = { { weight, style }... } } }.
-- `faces` holds the @font-face rules the stylesheet defines; other names are local fonts.
-- Pass the result back as `into` to collect several stylesheets.
function Document.cssFamilies(css, into)
    local out = into or { order = {}, faces = {}, seen = {} }
    css = css:gsub("/%*.-%*/", "")
    local function add(name)
        if not out.seen[name] then
            out.seen[name] = true
            out.order[#out.order + 1] = name
        end
    end
    for body in css:gmatch("@font%-face%s*(%b{})") do
        local fam = body:match("font%-family%s*:%s*([^;}]+)")
        local name = fam and family_list(fam)[1]
        if name then
            add(name)
            out.faces[name] = out.faces[name] or {}
            table.insert(out.faces[name], {
                weight = (body:match("font%-weight%s*:%s*([^;}]+)") or "normal"):match("^%s*(.-)%s*$"),
                style = (body:match("font%-style%s*:%s*([^;}]+)") or "normal"):match("^%s*(.-)%s*$"),
            })
        end
    end
    local plain = css:gsub("@font%-face%s*%b{}", "")
    for value in plain:gmatch("font%-family%s*:%s*([^;}]+)") do
        for _, name in ipairs(family_list(value)) do add(name) end
    end
    for value in plain:gmatch("[{;%s]font%s*:%s*([^;}]+)") do
        -- shorthand: the families follow the size ("12px/1.4 Foo, serif")
        local fams = value:match("[%d.]+%a*%s*/?%s*[%d.]*%a*%s+(.+)$")
        for _, name in ipairs(fams and family_list(fams) or {}) do add(name) end
    end
    return out
end

--- Unicode ranges for the user's font.
Document.USER_FONT_RANGES = {
    all = "U+0-DFFF, U+F900-10FFFF", -- everything but private use (symbol and gaiji fonts)
    latin = "U+0-36F, U+370-52F, U+1D00-1FFF, U+2000-206F, U+20A0-20CF, U+2100-218F, U+2C60-2C7F, U+A720-A7FF, "
        .. "U+FB00-FB06",
    cjk = "U+2E80-2FDF, U+2FF0-30FF, U+3100-312F, U+3190-31FF, U+3200-9FFF, U+A960-A97F, U+AC00-D7FF, "
        .. "U+F900-FAFF, U+FE30-FE4F, U+FF00-FFEF, U+20000-3134F",
}

local function is_bold(weight)
    local w = tostring(weight):lower()
    if w == "bold" or w == "bolder" then return true end
    local n = tonumber(w:match("^(%d+)"))
    return n ~= nil and n >= 550
end

--- @font-face rules that put the user's font in place of the dictionary's fonts for one range of
-- characters (user_font.scope: "all", "latin" or "cjk"). They come after the dictionary's
-- stylesheets: for equal descriptors the last face covering a character wins, so text outside
-- the range keeps the dictionary's font.
-- A style the user's font has no file for gets no face of its own: its text takes the nearest
-- face of the family, the regular one, which the WebView emboldens or slants (as KOReader does
-- for a font without bold). A face declared bold would be drawn as it is, in regular weight.
-- Only the dictionary's own bold (italic) web fonts stay for that text: their faces cannot be
-- taken out of the family.
-- Faces get one weight, 400 or 700, not a range such as 100 549: WebView 91 emboldens and
-- slants no face declared with a range. Weights then match as with the ranges (300 and 500 take
-- the 400 face, 600 and 900 the 700 one), and the alias faces (fontAliasCss) are declared the
-- same way, so for each weight the user's face and the one it stands in for are in one set.
-- user_font: { file, bold_file, italic_file, bold_italic_file, scope }; families: from cssFamilies.
-- Returns the CSS for after the dictionary's stylesheets, and the base rule for before them.
function Document.userFontCss(user_font, families, aliases, file_url)
    aliases = aliases or Document.FONT_ALIASES
    local range = Document.USER_FONT_RANGES[user_font.scope or "all"] or Document.USER_FONT_RANGES.all
    local regular = file_url(user_font.file)
    local function opt(file) return file and file ~= "" and file_url(file) or nil end
    local bold, italic, bold_italic = opt(user_font.bold_file), opt(user_font.italic_file), opt(user_font.bold_italic_file)
    local out = {}
    local function face(name, weight, src, with_range, style)
        if not src then return end
        out[#out + 1] = string.format("@font-face{font-family:%s;font-weight:%s%s;src:%s%s}", css_string(name), weight,
            style and (";font-style:" .. style) or "", src, with_range and (";unicode-range:" .. range) or "")
    end
    local function faces_for(name)
        face(name, "400", regular, true)
        face(name, "700", bold, true)
        face(name, "400", italic, true, "italic")
        face(name, "700", bold_italic, true, "italic")
    end
    -- A local font by name, in one style: local("Name") is the family's regular face only.
    local function local_src(name, style)
        if style == "" then return "local(" .. css_string(name) .. ")" end
        return "local(" .. css_string(name .. " " .. style) .. "), local("
            .. css_string(name:gsub("%s+", "") .. "-" .. style:gsub("%s+", "")) .. ")"
    end
    faces_for("MDict User")
    for _, name in ipairs(families and families.order or {}) do
        local faces = families.faces[name]
        if faces then
            for _, f in ipairs(faces) do
                local style = f.style:lower()
                local slanted = style:find("italic") or style:find("oblique")
                local heavy = is_bold(f.weight)
                local src
                if slanted then
                    if heavy then src = bold_italic else src = italic end
                else
                    if heavy then src = bold else src = regular end
                end
                face(name, f.weight, src, true, slanted and "italic" or nil)
            end
        else
            if not aliases[name] then
                -- a local font: keep it for the characters outside the range, in the styles
                -- the user's font has faces for (the others are emboldened or slanted)
                face(name, "400", local_src(name, ""), false)
                if bold then face(name, "700", local_src(name, "Bold"), false) end
                if italic then face(name, "400", local_src(name, "Italic"), false, "italic") end
                if bold_italic then face(name, "700", local_src(name, "Bold Italic"), false, "italic") end
            end
            faces_for(name)
        end
    end
    return table.concat(out, "\n"), 'body{font-family:"MDict User",serif}'
end

local function html_attr(s)
    return (s:gsub("&", "&amp;"):gsub('"', "&quot;"):gsub("<", "&lt;"))
end

local function plugin_dir()
    local src = debug.getinfo(1, "S").source
    return (src:match("^@(.*)/renderers/[^/]+$")) or "."
end

local asset_cache = {}
local function asset(dir, name)
    local path = dir .. "/renderers/" .. name
    if not asset_cache[path] then
        asset_cache[path] = assert(read_file(path), "missing " .. path)
    end
    return asset_cache[path]
end

--- Builds the document.
-- opts:
--   stylesheets: resource paths of the dictionary's stylesheets, relative to the dictionary root
--   fonts: per-kind font settings (see fontAliasCss)
--   font_aliases: replaces Document.FONT_ALIASES (false disables aliasing)
--   user_css: extra CSS applied after the dictionary's own (e.g. <name>.koreader.css)
--   user_font: { file, bold_file, italic_file, bold_italic_file, scope } the reader's font (see userFontCss)
--   css_families: font families the dictionary's stylesheets use (from cssFamilies)
--   lang: document language, used for line breaking and font fallback
--   plugin_dir: where renderers/ lives (defaults to this file's plugin)
-- Returns html, key, files. `key` changes whenever the document would change.
function Document.build(opts)
    local dir = opts.plugin_dir or plugin_dir()
    local alias_css, files = "", {}
    if opts.font_aliases ~= false then
        -- bold text in the reader's font when it has no bold (see userFontCss)
        local uf = opts.user_font
        local regular_only = uf and uf.file and not (uf.bold_file and uf.bold_file ~= "") or false
        alias_css, files = Document.fontAliasCss(opts.fonts, opts.font_aliases or nil, regular_only)
    end
    local user_font_css = ""
    if opts.user_font and opts.user_font.file then
        local tokens, n = {}, 0
        for token, path in pairs(files) do
            tokens[path] = token
            n = n + 1
        end
        local function file_url(path)
            if not tokens[path] then
                n = n + 1
                tokens[path] = "u" .. n .. "." .. ext_of(path)
                files[tokens[path]] = path
            end
            return "url(/__file__/" .. tokens[path] .. ")"
        end
        local base
        user_font_css, base = Document.userFontCss(opts.user_font, opts.css_families,
            opts.font_aliases or nil, file_url)
        alias_css = alias_css .. "\n" .. base
    end
    local parts = {
        "<!DOCTYPE html><html", opts.lang and (' lang="' .. html_attr(opts.lang) .. '"') or "", "><head>",
        '<meta charset="utf-8">',
        '<meta name="viewport" content="width=device-width,initial-scale=1,minimum-scale=1,maximum-scale=1,user-scalable=no">',
        '<meta name="color-scheme" content="light only">',
        "<style id=\"mdict-fonts\">\n", alias_css, "\n</style>",
    }
    for _, href in ipairs(opts.stylesheets or {}) do
        parts[#parts + 1] = '<link rel="stylesheet" href="' .. html_attr(href) .. '">'
    end
    if user_font_css ~= "" then
        parts[#parts + 1] = "<style id=\"mdict-user-font\">\n" .. user_font_css .. "\n</style>"
    end
    -- After the dictionary's CSS so equal-specificity pager rules win.
    parts[#parts + 1] = "<style id=\"mdict-pager-css\">\n" .. asset(dir, "pager.css") .. "\n</style>"
    if opts.user_css and opts.user_css ~= "" then
        parts[#parts + 1] = "<style id=\"mdict-user-css\">\n" .. opts.user_css:gsub("</", "<\\/") .. "\n</style>"
    end
    parts[#parts + 1] = "<script>\n" .. asset(dir, "pager.js") .. "\n</script>"
    -- The pager's boxes are elements of their own, not divs: a dictionary's div rules
    -- (Encarta makes every div inline) must not reach them.
    parts[#parts + 1] = '</head><body><mdict-pager id="mdict-pager"><mdict-content id="mdict-content">'
        .. '<mdict-zoom id="mdict-zoom"></mdict-zoom></mdict-content></mdict-pager></body></html>'
    local html = table.concat(parts)
    local key_parts = { tostring(#html), opts.lang or "" }
    for _, href in ipairs(opts.stylesheets or {}) do key_parts[#key_parts + 1] = href end
    key_parts[#key_parts + 1] = alias_css
    key_parts[#key_parts + 1] = user_font_css
    key_parts[#key_parts + 1] = opts.user_css or ""
    return html, table.concat(key_parts, "\0"), files
end

return Document
