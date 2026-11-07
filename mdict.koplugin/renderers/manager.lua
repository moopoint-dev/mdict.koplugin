--[[--
Chooses and owns the WebView renderer, and builds popup widgets with it.

On Android the renderer is the system WebView, through the dex bridge. On Kindles with
firmware 5.16 to 5.18 it can be the Kindle's own browser (experimental, off by default:
renderers/kindle_browser.lua). On desktops it is Chromium for development: over its DevTools
pipe when MDICT_CHROMIUM names its binary, or through Playwright when MDICT_CHROMIUM_BRIDGE
names tools/chromium-bridge/bridge.js. Anywhere else, or when the renderer fails, MDict
entries fall back to KOReader's MuPDF widget.
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
Manager.plugin_dir = plugin_dir

local function info_log(...) logger.info("MDict:", ...) end

-- The Kindle's browser as a bridge, when the reader turned it on and nothing stands in the way.
local function kindle_bridge(state)
    if not (state.settings and state.settings.kindle_browser) then return nil, "off" end
    local KB = require("renderers/kindle_browser")
    local Test = require("mdict/kindletest")
    local shim = plugin_dir() .. "/kindle/kindle_shim.so"
    KB.killOrphans()
    local problems = Test.problems({ is_kindle = true, shim = shim })
    local avail = KB.availableMemory()
    if #problems == 0 and avail and avail < KB.MIN_MEMORY then
        problems[1] = string.format("only %d MB of memory is available", math.floor(avail / 1048576))
    end
    if #problems > 0 then return nil, table.concat(problems, " ") end
    -- the first lookup waits for the browser (14 s on a Paperwhite 4) and its first page
    local UIManager = require("ui/uimanager")
    local _ = require("gettext")
    Manager.starting = require("ui/widget/infomessage"):new{
        text = _("Starting the Kindle's browser to lay out entries. The first lookup takes about 20 seconds; "
            .. "the next ones are quicker."),
    }
    UIManager:show(Manager.starting)
    if UIManager.forceRePaint then UIManager:forceRePaint() end
    local scr = require("device").screen
    -- Pages come from the browser's screencast, whose frames are in device pixels only at a
    -- whole pixel ratio: 2 on a 300 ppi Kindle, with entries zoomed to the size Android's 1.875
    -- gives them.
    local ratio = scr and scr.getDPI and scr:getDPI() / 160 or 2
    local dpr = math.max(1, math.floor(ratio + 0.5))
    local bridge, err = KB.bridge({
        shim = shim,
        screen = scr and { w = scr:getWidth(), h = scr:getHeight() },
        dpr = dpr,
        log = info_log,
    })
    if bridge then bridge.zoom = ratio / dpr end
    return bridge, err
end

local function make_bridge(state)
    local AndroidBridge = require("renderers/android_bridge")
    if AndroidBridge.isAvailable() then
        return AndroidBridge.new(plugin_dir() .. "/android/mdict-bridge.dex")
    end
    local Device = require("device")
    if Device.isKindle and Device:isKindle() then return kindle_bridge(state) end
    local chromium = os.getenv("MDICT_CHROMIUM")
    if chromium and chromium ~= "" then
        local Cdp = require("renderers/cdp_pipe")
        local profile = (os.getenv("TMPDIR") or "/tmp") .. "/mdict-chromium-profile"
        local cdp, err = Cdp.spawn({ exe = chromium,
            args = { "--headless=new", "--no-sandbox", "--remote-debugging-pipe", "--hide-scrollbars",
                     "--user-data-dir=" .. profile, "about:blank" },
            env = { "HOME=" .. profile, "PATH=" .. (os.getenv("PATH") or "/usr/bin:/bin") } })
        if not cdp then return nil, err end
        return require("renderers/cdp_bridge").new({ cdp = cdp, max_slots = 3, log = info_log,
            dpr = tonumber(os.getenv("MDICT_CHROMIUM_DPR")) or 1, decode = require("renderers/png").decodeInto,
            screencast = os.getenv("MDICT_CHROMIUM_SCREENSHOTS") ~= "1" and { format = "png" } or nil })
    end
    local script = os.getenv("MDICT_CHROMIUM_BRIDGE")
    if script and script ~= "" then
        local ChromiumBridge = require("renderers/chromium_bridge")
        return ChromiumBridge.new({ script = script, node_path = os.getenv("NODE_PATH"),
                                    dpr = tonumber(os.getenv("MDICT_CHROMIUM_DPR")) or 1 })
    end
    return nil, "no WebView on this platform"
end

Manager.IDLE_CHECK = 60 -- seconds between checks whether an idle browser can be closed

-- A browser that is only started for the plugin (the Kindle's) is closed once unused for a while.
function Manager._idleCheck()
    Manager.idle_scheduled = false
    local r = Manager.renderer
    if not (r and r.bridge.idle_close) then return end
    local idle = require("mdict/clock")() - (r.bridge.last_use or 0)
    if idle >= r.bridge.idle_close and next(r.jobs) == nil then
        info_log("closing the idle browser after", math.floor(idle), "s")
        Manager.shutdown()
        return
    end
    Manager.idle_scheduled = true
    require("ui/uimanager"):scheduleIn(Manager.IDLE_CHECK, Manager._idleCheck)
end

--- The renderer, created on first use; nil when entries should use MuPDF.
function Manager.get(state)
    if Manager.renderer then
        local b = Manager.renderer.bridge
        -- (the Kindle's: stopped here when memory runs low)
        local ended = b.checkNow and b:checkNow()
        if ended or (b.alive and not b:alive()) then
            Manager.disable(ended or b.ended or "the browser ended")
            return nil
        end
        b.last_use = require("mdict/clock")()
        return Manager.renderer
    end
    if Manager.failed then return nil end
    if state.settings and state.settings.renderer == "mupdf" then return nil end
    local ok, bridge, err = pcall(make_bridge, state)
    if not ok then bridge, err = nil, bridge end
    if Manager.starting then
        -- closed once the lookup that started the browser is shown
        local msg, UIManager = Manager.starting, require("ui/uimanager")
        Manager.starting = nil
        UIManager:nextTick(function() UIManager:close(msg) end)
    end
    if not bridge then
        Manager.failed = tostring(err)
        logger.info("MDict: WebView renderer unavailable:", Manager.failed)
        local Device = require("device")
        if err ~= "off" and Device.isKindle and Device:isKindle() then Manager.notify(Manager.failed) end
        return nil
    end
    local WebRenderer = require("renderers/webview")
    local UIManager = require("ui/uimanager")
    Manager.renderer = WebRenderer.new({
        bridge = bridge,
        logger = logger,
        max_slots = bridge.max_slots,
        resolve = function(dict_id, path)
            local d = state.library and state.library:byId(dict_id)
            return d and d:resource(path)
        end,
        schedule = function(seconds, fn) UIManager:scheduleIn(seconds, fn) end,
        unschedule = function(fn) UIManager:unschedule(fn) end,
    })
    if bridge.kindle then
        bridge.idle_close = require("renderers/kindle_browser").IDLE_CLOSE
        bridge.last_use = require("mdict/clock")()
        if not Manager.idle_scheduled then
            Manager.idle_scheduled = true
            UIManager:scheduleIn(Manager.IDLE_CHECK, Manager._idleCheck)
        end
    end
    return Manager.renderer
end

--- Tells the reader once per session that entries use the built-in renderer, and why.
function Manager.notify(reason)
    if Manager.notified then return end
    Manager.notified = true
    local Notification = require("ui/widget/notification")
    local UIManager = require("ui/uimanager")
    local _ = require("gettext")
    local text = _("MDict: WebView rendering failed; using the built-in renderer.")
    local Device = require("device")
    if Device.isKindle and Device:isKindle() then
        reason = tostring(reason)
        -- what kills it without a word is the kernel, when memory runs out
        if reason:find("killed by signal 9", 1, true) then reason = _("the Kindle ran out of memory") end
        text = require("ffi/util").template(
            _("MDict: the Kindle's browser cannot lay out entries (%1); using the built-in renderer."), reason)
    end
    UIManager:show(Notification:new{ text = text })
end

--- Gives up on the renderer for this session (after it failed on a real entry).
function Manager.disable(reason)
    Manager.failed = reason or "failed"
    local Device = require("device")
    if Manager.failed:find("killed by signal 9", 1, true) and Device.isKindle and Device:isKindle() then
        local b = Manager.renderer and Manager.renderer.bridge
        info_log("the browser was killed; memory", b and b.memoryNote and b.memoryNote() or "?",
            "; the kernel's last memory messages:", require("renderers/kindle_browser").oomLines() or "none")
    end
    Manager.shutdown()
    Manager.notify(Manager.failed)
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

-- Sounds a dictionary has on the web (see playSound) are downloaded once, into the cache.
Manager.SOUND_BLOCK_TIMEOUT, Manager.SOUND_TOTAL_TIMEOUT = 10, 30

local function download(url, path)
    local http = require("socket.http")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local fs = require("mdict/fs")
    fs.mkdirp(fs.dirname(path))
    local part = path .. ".part"
    local f, ferr = io.open(part, "wb")
    if not f then return nil, ferr end
    socketutil:set_timeout(Manager.SOUND_BLOCK_TIMEOUT, Manager.SOUND_TOTAL_TIMEOUT)
    local ok, code = pcall(function()
        return socket.skip(1, http.request{ url = url, method = "GET", sink = socketutil.file_sink(f) })
    end)
    socketutil:reset_timeout()
    pcall(f.close, f)
    local size = fs.stat(part)
    if ok and code == 200 and size and size > 0 and os.rename(part, path) then return true end
    os.remove(part)
    if not ok then return nil, tostring(code) end
    return nil, type(code) == "number" and ("HTTP " .. code) or tostring(code or "network error")
end

--- Plays a sound from a dictionary: path is the part after mdict-sound://, as in the entry;
-- sources, when given, are all the sources the entry gives the sound, in order (paths in the
-- dictionary, http(s) URLs). The first one in the dictionary plays; else the first on the web,
-- downloaded when KOReader is online. Returns true, or nil and a message.
function Manager.playSound(state, dict_title, path, sources)
    local _ = require("gettext")
    local T = require("ffi/util").template
    local Html = require("mdict/html")
    local d = state.library and state.library:byTitle(dict_title)
    if not d then return nil end
    local bridge = audio_bridge(state)
    if not bridge then return nil, _("Dictionary sounds can only be played on Android.") end
    local missing, speex, web
    for _, src in ipairs(sources or { path }) do
        if src:find("^[Hh][Tt][Tt][Pp][Ss]?://") then
            web = web or src
        else
            local p = Html.resourcePath(src, "")
            if (p:match("%.(%w+)$") or ""):lower() == "spx" then
                speex = true
            else
                local file = d:resource(p)
                if file then
                    logger.dbg("MDict: playing", file)
                    bridge:playAudio(file)
                    return true
                end
                missing = missing or p
            end
        end
    end
    if web then
        local name = web:gsub("^%a+://", ""):gsub("[?#].*$", ""):gsub("[^%w%.%-]", "_"):sub(-120)
        local file = d.cache_dir .. "/sounds/" .. d.id .. "/" .. name
        local fs = require("mdict/fs")
        if fs.isFile(file) then
            bridge:playAudio(file)
            return true
        end
        require("ui/network/manager"):runWhenOnline(function()
            local ok, err = download(web, file)
            if ok then
                logger.dbg("MDict: playing", web)
                bridge:playAudio(file)
            else
                logger.warn("MDict: cannot download", web, err)
                local Notification = require("ui/widget/notification")
                require("ui/uimanager"):show(Notification:new{
                    text = T(_("Could not download the sound: %1"), err),
                })
            end
        end)
        return true
    end
    if speex then return nil, _("This sound is in the Speex format, which Android cannot play.") end
    return nil, T(_("Sound not found in the dictionary: %1"), missing or path)
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

--- Those of a dictionary's stylesheets that use CSS round() (see Document.usesRound), as
-- { [path] = true }. Each is read once per dictionary.
function Manager.roundSheets(d, stylesheets)
    local Document = require("renderers/document")
    local fs = require("mdict/fs")
    d._round_sheets = d._round_sheets or {}
    local out = {}
    for _, p in ipairs(stylesheets) do
        local uses = d._round_sheets[p]
        if uses == nil then
            local file = d:resource(p)
            local css = file and fs.readAll(file)
            uses = css and Document.usesRound(css) or false
            d._round_sheets[p] = uses
        end
        if uses then out[p] = true end
    end
    return out
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
        -- with one page (the Kindle's browser), another result being laid out ahead holds it
        local p = dql and dql.mdict_prefetch
        if p and p.job and not p.job.done and Manager.renderer and Manager.renderer.max_slots < 2 then
            local job = p.job
            Manager.dropPrefetch(dql)
            -- (it lets the page go once what it asked the browser for is done)
            Manager.renderer:finishJob(job)
        end
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
            round_sheets = Manager.roundSheets(d, stylesheets),
            fonts = settings.fonts,
            user_font = user_font,
            css_families = user_font and Manager.cssFamilies(d, stylesheets) or nil,
            user_css = d:userCss(),
        },
        entry = {
            html = body .. '<div class="mdict-query">' .. query .. "</div>",
            anchor = r.mdict.anchor,
            zoom = ((dql.dict_font_size or 20) / 20) * (settings.zoom or 1) * (renderer.bridge.zoom or 1),
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
        flash_turns = settings.flash_page_turns and Device:hasEinkScreen() or false,
        grey_pages = Device:hasEinkScreen() and not (Device.hasColorScreen and Device:hasColorScreen()) or false,
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
        local b = renderer.bridge
        if err == "timeout" or (err and err:find("^open")) or (err and err:find("^load"))
            or (b.alive and not b:alive()) then
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
    if p.width ~= dql.content_width or p.height ~= dql.definition_height or p.font ~= dql.dict_font_size then
        w:free()
        return nil
    end
    local box = w.htmlbox_widget
    if box.slot then box.slot.held = nil end
    box.background = false
    return w
end

local function is_web(r) return r and r.mdict and not r.mdict_note end

-- With one page (the Kindle's browser): the MDict result nearest to the shown one, in the
-- way the reader moves first.
local function nearest_web(dql, step)
    for _, dir in ipairs({ step, -step }) do
        local i = dql.dict_index + dir
        while dql.results[i] do
            if is_web(dql.results[i]) then return i end
            i = i + dir
        end
    end
end

--- With one page (the Kindle's browser): keeps the MDict result the reader moves away from
-- to another dictionary's (its widget and the pages drawn), for when they come back.
-- w: the widget, r: its result. Returns true when it is kept (else the caller frees it).
function Manager.keep(state, dql, w, r)
    local renderer = Manager.renderer
    local settings = state.settings or {}
    if settings.prefetch == false or not (renderer and renderer.max_slots < 2) then return false end
    local box = w and w.htmlbox_widget
    if not (box and r and dql.results) then return false end
    local shown = dql.results[dql.dict_index]
    local p = dql.mdict_prefetch
    -- the same result again (a new font size), or the one kept or laid out ahead is wanted
    if shown == r or (p and p.r == shown) then return false end
    local index
    for i, x in ipairs(dql.results) do
        if x == r then index = i end
    end
    if not index then return false end
    Manager.dropPrefetch(dql)
    box:stopWork()
    if box.slot and box.slot.owner == box then box.slot.held = true end
    dql.mdict_prefetch = { r = r, index = index, widget = w, kept = true,
        width = dql.content_width, height = dql.definition_height, font = dql.dict_font_size }
    return true
end

--- After a popup shows a result: lays out the next one (in the direction the reader
-- moves) in the background, if it is an MDict result. With one page (the Kindle's
-- browser), the nearest MDict result instead, while another dictionary's result is shown.
function Manager.prefetch(state, dql)
    if dql.is_wiki or not dql.results or not dql.dict_index then return end
    local settings = state.settings or {}
    if settings.prefetch == false or settings.renderer == "mupdf" then return end
    local last = dql.mdict_last_index
    local delay = last and Manager.PREFETCH_DELAY or Manager.FIRST_PREFETCH_DELAY
    dql.mdict_last_index = dql.dict_index
    local step = (last and dql.dict_index < last) and -1 or 1
    local index = dql.dict_index + step
    if Manager.renderer and Manager.renderer.max_slots < 2 then
        -- the page belongs to the shown entry: what was kept or laid out ahead stays as it is
        if dql.mdict_widget then return end
        index = nearest_web(dql, step)
    end
    local r = index and dql.results[index]
    local p = dql.mdict_prefetch
    if p and p.r == r then return end
    Manager.dropPrefetch(dql)
    if not is_web(r) then return end
    local renderer = Manager.get(state)
    if not (renderer and renderer.schedule) then return end
    -- with one page, laying out ahead while an MDict result is shown would take its page
    if renderer.max_slots < 2 and dql.mdict_widget then return end
    local avoid = {}
    local shown = dql.mdict_widget and dql.mdict_widget.htmlbox_widget
    if shown and shown.slot then avoid[shown.slot.id] = true end
    p = { r = r, index = index, width = dql.content_width, height = dql.definition_height, font = dql.dict_font_size }
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
