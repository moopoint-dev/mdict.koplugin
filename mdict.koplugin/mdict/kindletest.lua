--[[--
"Kindle browser test" (experimental): starts the Kindle's own web browser (Chromium 75,
which firmware 5.16 and later ship) in the background, the way the plugin would use it to
lay out dictionary entries, lays out two sample entries, and reports how long it took
and how much memory it needed. Then it closes the browser again.

The browser runs in Amazon's /chroot with a small library preloaded
(kindle/kindle_shim.so, source in the repository's kindle/ folder) that opens the
DevTools pipe, keeps its window off the screen, and keeps it away from the rest of the
Kindle's software (no title bar, no history, the app manager is not told). Everything
the test writes goes to /tmp/chroot/tmp/mdict-browser, which it removes afterwards; the
report and the two pages it drew are saved in KOReader's folder.
]]

local ffi = require("ffi")
local fs = require("mdict/fs")
local json = require("mdict/json")
local monotonic = require("mdict/clock")
local KB = require("renderers/kindle_browser") -- also declares poll()

local M = {}

M.root = "" -- prefix for every path on the device (the specs point it at a fake one)
M.FORMAT = 1
M.REPORT_NAME = "mdict-kindle-browser-test.txt"
M.PAGE_NAMES = { "mdict-kindle-browser-ja.png", "mdict-kindle-browser-en.png" }
M.CHROOT = "/chroot"
M.EXE = "/usr/bin/chromium/bin/kindle_browser"
M.WORK = "/tmp/mdict-browser" -- inside the chroot
M.LIBRARY_PATH = "/usr/bin/chromium/lib:/usr/bin/chromium/usr/lib:/usr/lib/"
M.START_TIMEOUT = 90
M.OP_TIMEOUT = 45
M.MIN_MEMORY = 60 * 1024 * 1024

-- Amazon's own flags (/usr/bin/browser), less the reading view, proxy and user agent ones.
M.FLAGS = {
    "--no-zygote", "--no-sandbox", "--single-process", "--skia-resource-cache-limit-mb=64",
    "--disable-gpu", "--in-process-gpu", "--disable-gpu-sandbox", "--disable-gpu-compositing",
    "--force-device-scale-factor=2", "--js-flags=jitless", "--content-shell-hide-toolbar",
    "--content-shell-host-window-cord=0,0", "--force-gpu-mem-available-mb=40",
    "--enable-low-end-device-mode", "--enable-low-res-tiling", "--disable-site-isolation-trials",
    "--enable-grayscale-mode", "about:blank",
}

-- The page's bridge to Lua: pager.js asks KOBridge for its arguments and hands it results.
local KOBRIDGE = "window.KOBridge={_args:{},arg:function(id){var a=this._args[id];delete this._args[id];"
    .. "return a||'{}'},done:function(id,j){__koDone(JSON.stringify({id:id,r:j}))},log:function(m){}};"

-- Two made-up entries: vertical Japanese with ruby and upright numbers, and plain English.
local function sample_entries()
    local senses = {
        "人と人とが顔を合わせる。約束して対面する。", "物事に出くわす。偶然に行き当たる。",
        "ある事態に直面する。経験する。", "二つのものが一つになる。合流する。", "調和する。釣り合う。",
        "昭和<span style=\"text-combine-upright:all\">47</span>年に改められた用法。",
    }
    local marks = { "❶", "❷", "❸", "❹", "❺", "❻" }
    local ja = {}
    for i, s in ipairs(senses) do
        ja[#ja + 1] = string.format("<p><b>%s</b> %s「<ruby>友人<rt>ゆうじん</rt></ruby>に駅前で"
            .. "<ruby>会<rt>あ</rt></ruby>う」「旅先で雨に遭う」</p>", marks[i], s)
    end
    local en = {
        "Something that shows what others of its kind are like.",
        "A person or their conduct seen as a model to copy.",
        "A punishment meant to warn others.",
        "A problem worked through to show how a rule is used.",
    }
    local en_html = {}
    for _, s in ipairs(en) do
        en_html[#en_html + 1] = string.format("<li>%s <i>She set an example for the others.</i></li>", s)
    end
    return {
        { name = "Japanese, vertical", writing = "vertical",
          html = "<div style=\"writing-mode:vertical-rl\"><h2>あ・う【会う・逢う・遭う】</h2><p>〔動ワ五（ハ四）〕</p>"
              .. string.rep(table.concat(ja), 3) .. "</div>" },
        { name = "English, horizontal", writing = "horizontal",
          html = "<h2>ex·am·ple <span style=\"font-weight:normal\">/ɪɡˈzɑːm.pəl/</span></h2><p><i>noun</i></p><ol>"
              .. string.rep(table.concat(en_html), 3) .. "</ol><p><b>for example</b> used to give "
              .. "an instance of what was just said.</p>" },
    }
end

local function p(path) return M.root .. path end

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function write(path, data)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

local function mb(bytes)
    if not bytes then return "?" end
    return string.format("%d MB", math.floor(bytes / 1048576 + 0.5))
end

local function secs(t) return t and string.format("%.1f s", t) or "?" end

local function meminfo()
    local m = {}
    for k, v in (read(p("/proc/meminfo")) or ""):gmatch("(%w+):%s+(%d+) kB") do m[k] = tonumber(v) * 1024 end
    return m
end

local function proc_status(pid)
    local s = "\n" .. (read(p("/proc/" .. pid .. "/status")) or "")
    local function kb(key)
        local v = s:match("\n" .. key .. ":%s+(%d+) kB")
        return v and tonumber(v) * 1024
    end
    return { rss = kb("VmRSS"), peak = kb("VmHWM"), swap = kb("VmSwap") }
end

local function sleep_ms(ms) ffi.C.poll(nil, 0, ms) end

-- Is a process with this name running? (/proc/<pid>/stat holds the name in parentheses.)
local function running(names)
    local ok, iter, dir = pcall(fs.lfs.dir, p("/proc"))
    if not ok then return nil end
    for entry in iter, dir do
        if entry:match("^%d+$") then
            local name = (read(p("/proc/" .. entry .. "/stat")) or ""):match("^%d+ %((.*)%) ")
            for _, n in ipairs(names) do if name == n then return n end end
        end
    end
end

-- Mount options of the file system holding path, from /proc/mounts.
local function mount_options(paths)
    local best, opts = "", nil
    for line in (read(p("/proc/mounts")) or ""):gmatch("[^\n]+") do
        local at, o = line:match("^%S+ (%S+) %S+ (%S+)")
        if at then
            for _, path in ipairs(paths) do
                if (path == at or path:sub(1, #at + 1) == at .. "/" or at == "/") and #at > #best then
                    best, opts = at, o
                end
            end
        end
    end
    return opts, best
end

local B64 = {}
do
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    for i = 1, 64 do B64[chars:byte(i)] = i - 1 end
end

--- Decodes base64 (as the browser returns screenshots).
function M.unbase64(s)
    s = s:gsub("[^%w%+/]", "")
    local out, buf, n = {}, {}, 0
    local char, floor = string.char, math.floor
    local full = #s - #s % 4
    for i = 1, full, 4 do
        local a, b, c, d = s:byte(i, i + 3)
        local v = ((B64[a] * 64 + B64[b]) * 64 + B64[c]) * 64 + B64[d]
        buf[n + 1], buf[n + 2], buf[n + 3] = floor(v / 65536), floor(v / 256) % 256, v % 256
        n = n + 3
        if n >= 3000 then
            out[#out + 1] = char(unpack(buf, 1, n))
            n = 0
        end
    end
    local rest = #s - full
    if rest >= 2 then
        local a, b, c = s:byte(full + 1, full + 3)
        local v = (B64[a] * 64 + B64[b]) * 64 + (c and B64[c] or 0)
        buf[n + 1] = floor(v / 1024)
        n = n + 1
        if rest == 3 then
            buf[n + 1] = floor(v / 4) % 256
            n = n + 1
        end
    end
    if n > 0 then out[#out + 1] = char(unpack(buf, 1, n)) end
    return table.concat(out)
end

--- What stands in the way of the test on this device, as a list of sentences (empty: none).
-- info: { is_kindle, shim (path of kindle_shim.so) }
function M.problems(info)
    local list = {}
    if not info.is_kindle then list[#list + 1] = "This is not a Kindle." end
    if not fs.isFile(p(M.CHROOT .. M.EXE)) then
        if fs.isFile(p(M.EXE)) then
            list[#list + 1] = "Amazon's /chroot is not ready (the Kindle prepares it when its own software starts)."
        else
            list[#list + 1] = "This Kindle's browser is not supported by the test yet: it needs the browser of "
                .. "firmware 5.16 to 5.18, which runs in /chroot."
        end
    end
    if not (info.shim and fs.isFile(info.shim)) then
        list[#list + 1] = "The plugin is missing kindle/kindle_shim.so; reinstall it."
    end
    if not fs.lfs.attributes(p("/tmp/.X11-unix/X0")) then
        list[#list + 1] = "Amazon's display server (X) is not running."
    end
    local open = running({ "kindle_browser", "browserd" })
    if open then list[#list + 1] = "Amazon's browser is open (" .. open .. "); close it first." end
    local opts = mount_options({ "/tmp/chroot/tmp", M.CHROOT .. "/tmp" })
    if opts and ("," .. opts .. ","):find(",noexec,", 1, true) then
        list[#list + 1] = "/tmp does not allow programs (noexec), so the browser cannot load the plugin's library."
    end
    local avail = meminfo().MemAvailable
    if avail and avail < M.MIN_MEMORY then
        list[#list + 1] = string.format("Only %s of memory is available; the test needs at least %s.",
            mb(avail), mb(M.MIN_MEMORY))
    end
    return list
end

--- How the test starts the browser on a Kindle. screen: { w, h } in pixels.
function M.kindleConfig(screen, shim)
    local work = M.WORK
    local off = math.max(screen and screen.w or 0, screen and screen.h or 0, 1072) + 16
    return {
        root = p(M.CHROOT),
        host_work = p(M.CHROOT .. work),
        work = work,
        shim = shim,
        exe = M.EXE,
        args = M.FLAGS,
        env = {
            "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME=" .. work .. "/profile",
            "XDG_CONFIG_HOME=" .. work .. "/profile",
            "LD_LIBRARY_PATH=" .. M.LIBRARY_PATH,
            "LD_PRELOAD=" .. work .. "/kindle_shim.so",
            "DISPLAY=" .. (os.getenv("DISPLAY") or ":0.0"),
            "KO_DEVTOOLS_PIPE=1",
            "KO_QUIET_LIPC=1",
            "KO_OFFSCREEN=" .. off,
        },
        lipc_load = true,
        pid_file = p("/var/run/chromium.pid"),
        proc = p("/proc"),
        start_timeout = M.START_TIMEOUT,
    }
end

--- Runs the test. cfg: from kindleConfig(), or the specs' own (root = false runs without chroot;
-- samples replaces the sample entries; inspect, a script whose value is kept with each sample).
-- page_files: where to save the pages drawn (one per sample entry).
-- progress(text): called before each step. Returns a result table (see report()).
function M.run(cfg, page_files, progress)
    local Document = require("renderers/document")
    progress = progress or function() end
    local r = { steps = {}, samples = {}, mem_before = meminfo() }
    local t0 = monotonic()
    local function step(name) r.steps[#r.steps + 1] = { name = name, at = monotonic() - t0 } progress(name) end
    local function fail(err) r.error = r.steps[#r.steps].name .. ": " .. tostring(err) return r end

    step("prepare")
    local prepared, err = KB.prepare(cfg)
    if not prepared then return fail(err) end
    local html = Document.build({ font_aliases = false, lang = "ja" })
    if not write(cfg.host_work .. "/page.html", html) then return fail("cannot write the page") end

    step("start")
    local browser, started
    browser, err, started = KB.start(cfg, r, t0)
    browser = browser or started
    if not browser then return fail(err) end
    local function finish()
        step("close")
        r.mem_during = r.mem_during or meminfo()
        r.closed, r.exit, r.log = KB.stop(browser, cfg)
        r.total = monotonic() - t0
        return r
    end
    local function abort(e)
        fail(e)
        r.exit_early = browser:exitStatus()
        return finish()
    end
    if err then return abort(err) end

    step("open page")
    local page
    for _ = 1, 40 do
        local targets = browser:call("Target.getTargets", nil, nil, 10)
        for _, t in ipairs(targets and targets.targetInfos or {}) do
            if t.type == "page" then page = t break end
        end
        if page then break end
        sleep_ms(250)
    end
    if not page then return abort("no page") end
    local att
    att, err = browser:call("Target.attachToTarget", { targetId = page.targetId, flatten = true }, nil, 30)
    if not att then return abort(err) end
    local sid = att.sessionId
    local W, H, DPR = cfg.width or 500, cfg.height or 550, cfg.dpr or 2
    for _, c in ipairs({
        { "Page.enable" }, { "Runtime.enable" }, { "Runtime.addBinding", { name = "__koDone" } },
        { "Page.addScriptToEvaluateOnNewDocument", { source = KOBRIDGE } },
        { "Emulation.setDeviceMetricsOverride", { width = W, height = H, deviceScaleFactor = DPR, mobile = false } },
    }) do
        local ok, e = browser:call(c[1], c[2], sid, 30)
        if not ok then return abort(e) end
    end
    browser:dropEvents()
    local nav
    nav, err = browser:call("Page.navigate", { url = "file://" .. cfg.work .. "/page.html" }, sid, 30)
    if not nav then return abort(err) end
    if nav.errorText then return abort(nav.errorText) end
    local loaded
    loaded, err = browser:waitEvent("Page.loadEventFired", 60)
    if not loaded then return abort(err) end
    r.page_at = monotonic() - t0

    local op_id = 0
    local function op(name, args)
        op_id = op_id + 1
        local id = op_id
        local ok, e = browser:call("Runtime.evaluate", {
            expression = string.format("KOBridge._args[%d]=%s;MDict.%s(%d)", id, json.encode(json.encode(args)), name, id),
        }, sid, 30)
        if not ok then return nil, e end
        if ok.exceptionDetails then return nil, name .. ": " .. tostring(ok.exceptionDetails.text) end
        local ev
        ev, e = browser:waitEvent("Runtime.bindingCalled", M.OP_TIMEOUT, function(prm)
            local okp, pl = pcall(json.decode, prm.payload or "")
            return okp and type(pl) == "table" and pl.id == id
        end)
        if not ev then return nil, e end
        local res = json.decode(json.decode(ev.payload).r)
        if type(res) == "table" and res.error then return nil, name .. ": " .. tostring(res.error) end
        return res
    end
    local ping
    ping, err = op("ping", {})
    if not ping then return abort(err) end

    for i, sample in ipairs(cfg.samples or sample_entries()) do
        step("lay out " .. sample.name)
        local t = monotonic()
        local res
        res, err = op("setEntry", { html = sample.html, writing = sample.writing, pagination = "auto",
            clicks = json.array({}), zoom = 1, eink = true, runScripts = false, skipScripts = json.array({}) })
        if not res then return abort(err) end
        local s = { name = sample.name, pages = res.pages, vertical = res.vertical, mode = res.mode,
            ms = res.ms, layout = monotonic() - t }
        if cfg.inspect then
            local v = browser:call("Runtime.evaluate", { expression = cfg.inspect, returnByValue = true }, sid, 30)
            s.inspect = v and v.result and v.result.value
        end
        r.samples[#r.samples + 1] = s
        local shown
        shown, err = op("showPage", { page = 0 })
        if not shown then return abort(err) end
        t = monotonic()
        local shot
        shot, err = browser:call("Page.captureScreenshot", { format = "png" }, sid, M.OP_TIMEOUT)
        if not shot then return abort(err) end
        s.capture = monotonic() - t
        local png = M.unbase64(shot.data or "")
        s.png_bytes = #png
        if page_files and page_files[i] and write(page_files[i], png) then s.file = page_files[i] end
        s.browser_mem = proc_status(r.pid)
        r.mem_during = meminfo()
    end
    r.ok = true
    return finish()
end

--- The report, as text. info: { plugin_version, koreader_version, model }
function M.report(info, r)
    local out = {}
    local function add(fmt, ...) out[#out + 1] = select("#", ...) > 0 and string.format(fmt, ...) or fmt end
    add("MDict Kindle browser test (format %d)", M.FORMAT)
    add("Plugin %s, KOReader %s", info.plugin_version or "?", info.koreader_version or "?")
    local fw = (read(p("/etc/prettyversion.txt")) or ""):match("^[^\n]*")
    add("Device: %s; firmware %s", info.model or "?", fw ~= "" and fw or "?")
    if r.problems then
        add("Not run:")
        for _, s in ipairs(r.problems) do add("  " .. s) end
        return table.concat(out, "\n") .. "\n"
    end
    add("Result: %s", r.ok and "OK" or ("FAILED at " .. tostring(r.error)))
    local mb0 = r.mem_before or {}
    add("Memory before: %s available, swap %s free", mb(mb0.MemAvailable), mb(mb0.SwapFree))
    if r.version then add("Browser: %s", r.version) end
    add("Started: DevTools ready after %s%s", r.ready_at and secs(r.ready_at) or "never",
        r.load_at and (", load sent after " .. secs(r.load_at)) or ", load not sent")
    if r.page_at then add("Page loaded after %s", secs(r.page_at)) end
    for _, s in ipairs(r.samples or {}) do
        local ms = s.ms or {}
        add("%s: %s pages (%s, %s), laid out in %s (pager %s ms, fonts %s ms), page drawn in %s, %d KB",
            s.name, tostring(s.pages), s.vertical and "vertical" or "horizontal", tostring(s.mode), secs(s.layout),
            tostring(ms.total or "?"), tostring(ms.fonts or "?"), s.capture and secs(s.capture) or "?",
            math.floor((s.png_bytes or 0) / 1024))
        local bm = s.browser_mem or {}
        add("  browser memory: %s resident, peak %s, %s in swap", mb(bm.rss), mb(bm.peak), mb(bm.swap))
    end
    local md = r.mem_during or {}
    add("Memory while running: %s available, swap %s free", mb(md.MemAvailable), mb(md.SwapFree))
    if r.exit_early then add("The browser ended early: %s", r.exit_early) end
    add("Closed: %s (%s) after %s in all", tostring(r.closed or "?"), tostring(r.exit or "?"),
        r.total and secs(r.total) or "?")
    local steps = {}
    for _, s in ipairs(r.steps or {}) do steps[#steps + 1] = string.format("%s %.1f", s.name, s.at) end
    add("Steps (s): %s", table.concat(steps, ", "))
    -- the browser's own messages, less font configuration noise
    local lines = {}
    for line in (r.log or ""):gmatch("[^\n]+") do
        if not line:find("^Fontconfig") and not line:find("^%s*$") then lines[#lines + 1] = line:sub(1, 200) end
    end
    if #lines > 0 then
        add("Browser messages (last %d):", math.min(#lines, 20))
        for i = math.max(1, #lines - 19), #lines do add("  " .. lines[i]) end
    end
    return table.concat(out, "\n") .. "\n"
end

local function plugin_dir()
    local src = debug.getinfo(1, "S").source
    return (src:match("^@(.*)/mdict/[^/]+$")) or "."
end

--- Asks first, then runs the test on this Kindle, saves the report and shows it.
function M.show(plugin_version)
    local UIManager = require("ui/uimanager")
    local Device = require("device")
    local DataStorage = require("datastorage")
    local _ = require("gettext")
    local T = require("ffi/util").template
    local info = { plugin_version = plugin_version, model = Device.model }
    local okv, Version = pcall(require, "version")
    if okv and Version and Version.getCurrentRevision then info.koreader_version = Version:getCurrentRevision() end
    local shim = plugin_dir() .. "/kindle/kindle_shim.so"
    local dir = DataStorage:getDataDir()
    local report_path = dir .. "/" .. M.REPORT_NAME

    local function show_result(r)
        local report = M.report(info, r)
        local saved = fs.writeAtomic(report_path, report)
        local buttons = {}
        for _, s in ipairs(r.samples or {}) do
            if s.file then
                buttons[#buttons + 1] = { text = s.name, callback = function()
                    UIManager:show(require("ui/widget/imageviewer"):new{ file = s.file, fullscreen = true,
                        with_title_bar = true, title_text = s.name })
                end }
            end
        end
        local note = saved and T(_("Saved as %1. Please attach this file and the two pictures next to it to the GitHub issue."),
            report_path) or T(_("Could not save the report to %1."), report_path)
        UIManager:show(require("ui/widget/textviewer"):new{
            title = _("Kindle browser test"),
            text = note .. "\n\n" .. report,
            buttons_table = #buttons > 0 and { buttons } or nil,
            add_default_buttons = true,
        })
    end

    local problems = M.problems({ is_kindle = Device:isKindle(), shim = shim })
    if #problems > 0 then return show_result({ problems = problems }) end
    UIManager:show(require("ui/widget/confirmbox"):new{
        text = _("This starts the Kindle's own web browser in the background, lays out two sample entries with it "
            .. "and closes it again. KOReader does not respond while it runs, which can take two minutes.\n\n"
            .. "Nothing is installed on the Kindle. If it behaves oddly afterwards, restart it.\n\nRun the test?"),
        ok_text = _("Run test"),
        ok_callback = function()
            local InfoMessage = require("ui/widget/infomessage")
            local msg = InfoMessage:new{ text = _("Testing the Kindle's browser…") }
            UIManager:show(msg)
            UIManager:forceRePaint()
            UIManager:nextTick(function()
                local scr = Device.screen
                local cfg = M.kindleConfig(scr and { w = scr:getWidth(), h = scr:getHeight() }, shim)
                local files = {}
                for i, name in ipairs(M.PAGE_NAMES) do files[i] = dir .. "/" .. name end
                local ok, r = pcall(M.run, cfg, files)
                if not ok then r = { error = "the test itself failed: " .. tostring(r) } end
                UIManager:close(msg)
                show_result(r)
            end)
        end,
    })
end

return M
