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
    local UIManager = require("ui/uimanager")
    Manager.renderer = WebRenderer.new({
        bridge = bridge,
        logger = logger,
        resolve = function(dict_id, path)
            local d = state.library and state.library:byId(dict_id)
            return d and d:resource(path)
        end,
        schedule = function(seconds, fn) UIManager:scheduleIn(seconds, fn) end,
        unschedule = function(fn) UIManager:unschedule(fn) end,
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
-- shown: the definition KOReader shows (default: the popup's current one).
local function appended(dql, r, shown)
    if type(dql.word) == "string" and require("mdict/lookup").isInternalKey(dql.word) then return "" end
    local def, base = shown or dql.definition, r.definition
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

-- Whether a dictionary's entries were vertical last time (remembered across sessions,
-- so its first entry is laid out once, for the right page shape).
local function vertical_seen(settings, id)
    local v = Manager.vertical_seen[id]
    if v == nil and settings.vertical_seen then v = settings.vertical_seen[id] end
    return v
end

local function remember_vertical(settings, id, vertical)
    Manager.vertical_seen[id] = vertical
    settings.vertical_seen = settings.vertical_seen or {}
    if settings.vertical_seen[id] ~= vertical then settings.vertical_seen[id] = vertical end
end

--- A WebScrollWidget for an MDict result in a DictQuickLookup, or nil to use MuPDF.
-- opts (for laying out a result ahead): definition (the result's own, instead of the shown
-- one's), avoid (renderer slot ids to leave alone), background (in a background job).
function Manager.widget(state, dql, r, opts)
    if not opts then
        local ready = Manager.takePrefetched(dql, r)
        if ready then return ready end
    end
    opts = opts or {}
    local renderer = Manager.get(state)
    if not renderer then return nil end
    local d = state.library:byId(r.mdict.id)
    if not d then return nil end
    local settings = state.settings or {}
    local user_font = settings.user_font
    if not (user_font and user_font.file and user_font.scope) then user_font = nil end
    local writing = Manager.dictSetting(settings, d.id, "writing", "auto")
    local vertical_hint = writing == "vertical"
    if writing == "auto" then vertical_hint = vertical_seen(settings, d.id) or false end
    local clock = require("renderers/webview").clock
    local t_html = clock()
    local stylesheets, body = d:stylesheetsOf(r.mdict.html)
    local query = appended(dql, r, opts.definition)
    local Device = require("device")
    local eink = settings.eink
    if eink == nil then eink = Device:hasEinkScreen() end
    local WebScrollWidget = require("widgets/webscrollwidget")
    local t0 = clock()
    t_html = t0 - t_html
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
            html = body .. '<div class="mdict-query">' .. query .. "</div>",
            anchor = r.mdict.anchor,
            zoom = ((dql.dict_font_size or 20) / 20) * (settings.zoom or 1),
            eink = eink,
            writing = writing,
            pagination = Manager.dictSetting(settings, d.id, "pagination", "auto"),
        },
        vertical_hint = vertical_hint,
        on_layout = function(box) remember_vertical(settings, d.id, box.vertical) end,
        avoid_slots = opts.avoid,
        label = d.title,
        background = opts.background,
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
    logger.info(string.format("MDict: laid out %s (%.0f KB, prepared in %.0f ms) in %.0f ms: %d pages",
        r.mdict.key, #r.mdict.html / 1024, t_html * 1000, (clock() - t0) * 1000,
        widget and widget.htmlbox_widget.page_count or 0))
    if not widget then
        if opts.background then return nil, err end
        logger.warn("MDict: WebView could not show the entry:", err)
        if err == "timeout" or (err and err:find("^open")) or (err and err:find("^load")) then
            Manager.disable(err)
        end
        return nil
    end
    return widget
end

-- laying out the next result ahead ------------------------------------------------

Manager.PREFETCH_DELAY = 0.3 -- seconds after a result is shown
-- after a popup opens, so that the popup's own first refresh comes first
Manager.FIRST_PREFETCH_DELAY = 1

--- Frees the result laid out ahead for a popup, and stops laying it out.
function Manager.dropPrefetch(dql)
    local p = dql.mdict_prefetch
    if not p then return end
    dql.mdict_prefetch = nil
    p.dropped = true
    if p.job and not p.job.done and Manager.renderer then Manager.renderer:cancelJob(p.job) end
    if p.widget then
        local box = p.widget.htmlbox_widget
        if box and box.slot then box.slot.held = nil end
        p.widget:free()
        p.widget = nil
    end
end

--- The widget laid out ahead for result r, if it is the one (finishing it first if needed).
function Manager.takePrefetched(dql, r)
    local p = dql and dql.mdict_prefetch
    if not (p and p.r == r) then return nil end
    if p.job and not p.job.done and Manager.renderer then Manager.renderer:finishJob(p.job) end
    local w = p.widget
    dql.mdict_prefetch = nil
    if not w then return nil end
    if p.width ~= dql.content_width or p.height ~= dql.definition_height then
        w:free()
        return nil
    end
    local box = w.htmlbox_widget
    if box.slot then box.slot.held = nil end
    box.background = false
    return w
end

--- After a popup shows a result: lays out the next one (in the direction the reader
-- moves) in the background, if it is an MDict result.
function Manager.prefetch(state, dql)
    if dql.is_wiki or not dql.results or not dql.dict_index then return end
    local settings = state.settings or {}
    if settings.prefetch == false or settings.renderer == "mupdf" then return end
    local last = dql.mdict_last_index
    local delay = last and Manager.PREFETCH_DELAY or Manager.FIRST_PREFETCH_DELAY
    dql.mdict_last_index = dql.dict_index
    local step = (last and dql.dict_index < last) and -1 or 1
    local index = dql.dict_index + step
    local r = dql.results[index]
    local p = dql.mdict_prefetch
    if p and p.r == r then return end
    Manager.dropPrefetch(dql)
    if not (r and r.mdict and not r.mdict_note) then return end
    local renderer = Manager.get(state)
    if not (renderer and renderer.schedule) then return end
    local avoid = {}
    local shown = dql.mdict_widget and dql.mdict_widget.htmlbox_widget
    if shown and shown.slot then avoid[shown.slot.id] = true end
    p = { r = r, index = index, width = dql.content_width, height = dql.definition_height }
    dql.mdict_prefetch = p
    p.job = renderer:startJob(function()
        local w, err = Manager.widget(state, dql, r, { definition = r.definition, avoid = avoid, background = true })
        if not w then return nil, err end
        local box = w.htmlbox_widget
        box:_pageBb(box.page_number)
        return w
    end, function(job)
        local w = job.ok and job.result or nil
        if p.dropped or dql.mdict_prefetch ~= p then
            if w then w:free() end
            return
        end
        p.job = nil
        p.widget = w
        if w and w.htmlbox_widget.slot then w.htmlbox_widget.slot.held = true end
        if not w and job.err and job.err ~= renderer.CANCELLED then
            logger.dbg("MDict: could not lay out the next result ahead:", job.err)
        end
    end, delay)
end

return Manager
