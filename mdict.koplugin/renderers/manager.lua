--[[--
Chooses and owns the WebView renderer, and builds popup widgets with it.

On Android the renderer is the system WebView, through the dex bridge. On
desktops it is headless Chromium when MDICT_CHROMIUM_BRIDGE names
tools/chromium-bridge/bridge.js (for development). Anywhere else, or when
the WebView fails, MDict entries fall back to KOReader's MuPDF widget.
]]

local logger = require("logger")

local Manager = {
    renderer = nil,
    failed = nil, -- reason the renderer is unavailable for this session
    notified = false,
    vertical_seen = {}, -- dictionary id -> whether its last entry was vertical
}

local function plugin_dir()
    local src = debug.getinfo(1, "S").source
    return (src:match("^@(.*)/renderers/[^/]+$")) or "."
end

local function make_bridge()
    local AndroidBridge = require("renderers/android_bridge")
    if AndroidBridge.isAvailable() then
        return AndroidBridge.new(plugin_dir() .. "/android/mdict-bridge.dex")
    end
    local script = os.getenv("MDICT_CHROMIUM_BRIDGE")
    if script and script ~= "" then
        local ChromiumBridge = require("renderers/chromium_bridge")
        return ChromiumBridge.new({ script = script, node_path = os.getenv("NODE_PATH"),
                                    dpr = tonumber(os.getenv("MDICT_CHROMIUM_DPR")) or 1 })
    end
    return nil, "no WebView on this platform"
end

--- The renderer, created on first use; nil when entries should use MuPDF.
function Manager.get(state)
    if Manager.renderer then return Manager.renderer end
    if Manager.failed then return nil end
    if state.settings and state.settings.renderer == "mupdf" then return nil end
    local ok, bridge, err = pcall(make_bridge)
    if not ok then bridge, err = nil, bridge end
    if not bridge then
        Manager.failed = tostring(err)
        logger.info("MDict: WebView renderer unavailable:", Manager.failed)
        return nil
    end
    local WebRenderer = require("renderers/webview")
    Manager.renderer = WebRenderer.new({
        bridge = bridge,
        logger = logger,
        resolve = function(dict_id, path)
            local d = state.library and state.library:byId(dict_id)
            return d and d:resource(path)
        end,
    })
    return Manager.renderer
end

--- Gives up on the renderer for this session (after it failed on a real entry).
function Manager.disable(reason)
    Manager.failed = reason or "failed"
    Manager.shutdown()
    if not Manager.notified then
        Manager.notified = true
        local Notification = require("ui/widget/notification")
        local UIManager = require("ui/uimanager")
        local _ = require("gettext")
        UIManager:show(Notification:new{
            text = _("MDict: WebView rendering failed; using the built-in renderer."),
        })
    end
end

function Manager.shutdown()
    local r = Manager.renderer
    Manager.renderer = nil
    if r then
        r:close()
        if r.bridge.free then pcall(r.bridge.free, r.bridge) end
    end
    local a = Manager.audio_bridge
    Manager.audio_bridge = nil
    if a then pcall(a.free, a) end
end

-- A bridge that can play audio: the renderer's, or one of its own when the WebView is off.
local function audio_bridge(state)
    local r = Manager.get(state)
    if r and r.bridge.playAudio then return r.bridge end
    if Manager.audio_bridge then return Manager.audio_bridge end
    local AndroidBridge = require("renderers/android_bridge")
    if not AndroidBridge.isAvailable() then return nil end
    Manager.audio_bridge = AndroidBridge.new(plugin_dir() .. "/android/mdict-bridge.dex")
    return Manager.audio_bridge
end

--- Plays a sound from a dictionary (the part after mdict-sound://, as in the entry). Returns true,
-- or nil and a message.
function Manager.playSound(state, dict_title, path)
    local _ = require("gettext")
    local T = require("ffi/util").template
    local d = state.library and state.library:byTitle(dict_title)
    if not d then return nil end
    path = require("mdict/html").resourcePath(path, "")
    local ext = (path:match("%.(%w+)$") or ""):lower()
    if ext == "spx" then
        return nil, _("This sound is in the Speex format, which Android cannot play.")
    end
    local bridge = audio_bridge(state)
    if not bridge then return nil, _("Dictionary sounds can only be played on Android.") end
    local file = d:resource(path)
    if not file then return nil, T(_("Sound not found in the dictionary: %1"), path) end
    logger.dbg("MDict: playing", file)
    bridge:playAudio(file)
    return true
end

--- Text KOReader appended to a result's definition (the "(query : word)" footer).
-- Left out when the query was an internal key (a followed cross reference).
local function appended(dql, r)
    if type(dql.word) == "string" and require("mdict/lookup").isInternalKey(dql.word) then return "" end
    local def, base = dql.definition, r.definition
    if type(def) == "string" and type(base) == "string" and #def > #base and def:sub(1, #base) == base then
        return def:sub(#base + 1)
    end
    return ""
end

--- Font families a dictionary's stylesheets use (cached per dictionary and stylesheet list).
function Manager.cssFamilies(d, stylesheets)
    local Document = require("renderers/document")
    local Html = require("mdict/html")
    local fs = require("mdict/fs")
    local key = table.concat(stylesheets, "\0")
    d._css_families = d._css_families or {}
    local cached = d._css_families[key]
    if cached ~= nil then return cached or nil end
    local families
    local function scan(path, depth)
        local file = d:resource(path)
        local css = file and fs.readAll(file)
        if not css then return end
        families = Document.cssFamilies(css, families)
        if depth < 2 then
            local base = path:match("^(.*)/[^/]*$") or ""
            for _, ref in ipairs(Html.cssRefs(css)) do
                local p = Html.resourcePath(ref, base)
                if p:lower():match("%.css$") then scan(p, depth + 1) end
            end
        end
    end
    for _, p in ipairs(stylesheets) do scan(p, 0) end
    d._css_families[key] = families or false
    return families or nil
end

--- A dictionary's own setting, else the global one, else the default.
function Manager.dictSetting(settings, dict_id, key, default)
    local own = settings.dicts and settings.dicts[dict_id]
    if own and own[key] ~= nil then return own[key] end
    if settings[key] ~= nil then return settings[key] end
    return default
end

--- A WebScrollWidget for an MDict result in a DictQuickLookup, or nil to use MuPDF.
function Manager.widget(state, dql, r)
    local renderer = Manager.get(state)
    if not renderer then return nil end
    local d = state.library:byId(r.mdict.id)
    if not d then return nil end
    local settings = state.settings or {}
    local user_font = settings.user_font
    if not (user_font and user_font.file and user_font.scope) then user_font = nil end
    local writing = Manager.dictSetting(settings, d.id, "writing", "auto")
    local vertical_hint = writing == "vertical"
    if writing == "auto" then vertical_hint = Manager.vertical_seen[d.id] or false end
    local stylesheets, body = d:stylesheetsOf(r.mdict.html)
    local Device = require("device")
    local eink = settings.eink
    if eink == nil then eink = Device:hasEinkScreen() end
    local WebScrollWidget = require("widgets/webscrollwidget")
    local clock = require("renderers/webview").clock
    local t0 = clock()
    local widget, err = WebScrollWidget.create{
        renderer = renderer,
        doc = {
            dict_id = d.id,
            cache_root = d.res_dir,
            stylesheets = stylesheets,
            fonts = settings.fonts,
            user_font = user_font,
            css_families = user_font and Manager.cssFamilies(d, stylesheets) or nil,
            user_css = d:userCss(),
        },
        entry = {
            html = body .. '<div class="mdict-query">' .. appended(dql, r) .. "</div>",
            anchor = r.mdict.anchor,
            zoom = ((dql.dict_font_size or 20) / 20) * (settings.zoom or 1),
            eink = eink,
            writing = writing,
            pagination = Manager.dictSetting(settings, d.id, "pagination", "auto"),
        },
        vertical_hint = vertical_hint,
        on_layout = function(box) Manager.vertical_seen[d.id] = box.vertical end,
        width = dql.content_width,
        height = dql.definition_height,
        dialog = dql,
        highlight_text_selection = true,
        invert_vertical_swipes = settings.invert_vertical_swipes,
        html_link_tapped_callback = function(link)
            dql.html_dictionary_link_tapped_callback(dql.dictionary, link)
        end,
        on_clear_search = function()
            dql.in_definition_search = false
            if dql.shw_widget then dql.shw_widget:setTapScrollEnabled(true) end
        end,
    }
    logger.dbg("MDict: laid out", r.mdict.key, string.format("in %.0f ms", (clock() - t0) * 1000),
        widget and widget.htmlbox_widget.page_count or 0, "pages")
    if not widget then
        logger.warn("MDict: WebView could not show the entry:", err)
        if err == "timeout" or (err and err:find("^open")) or (err and err:find("^load")) then
            Manager.disable(err)
        end
        return nil
    end
    return widget
end

return Manager
