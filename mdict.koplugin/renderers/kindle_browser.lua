--[[--
Starts and stops the Kindle's own browser (Chromium 75 in Amazon's /chroot, firmware 5.16 to
5.18) for the plugin: for the "Kindle browser test" (mdict/kindletest.lua) and as the
experimental renderer (renderers/cdp_bridge.lua over it).

The browser runs with kindle/kindle_shim.so preloaded, which opens the DevTools pipe, keeps
its window off the screen and keeps it away from the Kindle's own software. Its files go to
/tmp/chroot/tmp/mdict-browser (tmpfs), removed when it stops.
]]

local ffi = require("ffi")
local fs = require("mdict/fs")
local monotonic = require("mdict/clock")
local Cdp = require("renderers/cdp_pipe") -- also declares poll()

pcall(ffi.cdef, "int chmod(const char *path, unsigned int mode);")

local KB = {}

-- A Paperwhite 4 (5.18.1.1.1, one core at 1 GHz) took 14 s to start the browser, 5 s more to
-- load the first page, and 3.5 to 6 s for each PNG screenshot of a 1000x1100 page.
KB.START_TIMEOUT = 90
-- pages as JPEG: Chromium encodes them in about half the time PNG takes
KB.CAPTURE = { format = "jpeg", quality = 92 } -- screenshots, when no screencast frame comes
KB.SCREENCAST = { format = "jpeg", quality = 92 }
KB.IDLE_CLOSE = 1200 -- seconds awake without a lookup before the renderer's browser is closed
KB.MIN_MEMORY = 80 * 1024 * 1024 -- available memory the renderer needs to start the browser
KB.CAST_WAIT, KB.CAPTURE_WAIT = 5, 15 -- seconds for a screencast frame, then for a screenshot
KB.LOAD_TIMEOUT, KB.OP_TIMEOUT = 60, 45 -- seconds
-- it ignores Browser.close (the test waited 5 s for nothing): it is terminated right away
KB.CLOSE_GRACE = 0
-- Memory while the browser runs (checked before each entry, and every second while waiting
-- for the browser). Below RELEASE_BELOW available, the browser is asked to free its caches;
-- below STOP_BELOW, once asked, it is stopped. A Paperwhite 4 that ran out froze for half a
-- minute before the kernel killed the browser.
KB.RELEASE_BELOW = 50 * 1024 * 1024
KB.STOP_BELOW = 25 * 1024 * 1024
KB.RELEASE_SETTLE = 500 -- milliseconds the browser gets to free memory before it is measured again
KB.DMESG = "dmesg" -- the kernel's log, read after the browser was killed

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

local function sleep_ms(ms) ffi.C.poll(nil, 0, ms) end

-- Asks the browser, as Amazon's app manager would, to load: it starts up faster then.
function KB.lipcLoad()
    local ok = os.execute("lipc-set-prop -s com.lab126.browser load app://com.lab126.browser >/dev/null 2>&1")
    return ok == 0 or ok == true
end

KB.root = "" -- prefix for /proc (the specs point it at a fake one)

--- Memory available now (MemAvailable), in bytes, or nil.
function KB.availableMemory()
    local v = (read(KB.root .. "/proc/meminfo") or ""):match("MemAvailable:%s+(%d+) kB")
    return v and tonumber(v) * 1024
end

--- The resident memory of process pid (the browser runs as one process), in bytes, or nil.
function KB.processMemory(pid)
    local v = (read(KB.root .. "/proc/" .. tostring(pid) .. "/status") or ""):match("VmRSS:%s+(%d+) kB")
    return v and tonumber(v) * 1024
end

local function mb(bytes)
    return bytes and string.format("%d MB", math.floor(bytes / 1048576 + 0.5)) or "?"
end

--- Memory for the log: "95 MB free, browser 71 MB".
function KB.memoryText(pid)
    return mb(KB.availableMemory()) .. " free, browser " .. mb(pid and KB.processMemory(pid))
end

--- The bridge's watch (see renderers/cdp_bridge.lua): nothing, or why the browser must stop.
function KB.watch(bridge)
    local avail = KB.availableMemory()
    if not avail or avail >= KB.RELEASE_BELOW then return end
    if bridge:releaseMemory() then
        bridge.log("low memory, asked the browser to free some:", KB.memoryText(bridge.cdp.pid))
        if avail < KB.STOP_BELOW then
            sleep_ms(KB.RELEASE_SETTLE)
            avail = KB.availableMemory() or avail
        end
    end
    if avail < KB.STOP_BELOW then
        return "the Kindle is low on memory (" .. mb(avail) .. " free)"
    end
end

--- The kernel's last messages about running out of memory, or nil.
function KB.oomLines()
    local ok, p = pcall(io.popen, KB.DMESG .. " 2>/dev/null")
    if not ok or not p then return nil end
    local lines = {}
    for line in p:lines() do
        local l = line:lower()
        if l:find("out of memory", 1, true) or l:find("killed process", 1, true) or l:find("oom", 1, true) then
            lines[#lines + 1] = line
            if #lines > 6 then table.remove(lines, 1) end
        end
    end
    p:close()
    return #lines > 0 and table.concat(lines, " | ") or nil
end

-- What the kernel said about the e-ink screen's controller (errors such as underruns can
-- leave pages half drawn): the lines since the last call, at most a few, or nil.
KB.SCREEN_WORDS = { "epdc", "underrun", "collision", "waveform", "mxcfb" }
function KB.screenLines()
    local ok, p = pcall(io.popen, KB.DMESG .. " 2>/dev/null")
    if not ok or not p then return nil end
    local all = {}
    for line in p:lines() do
        local l = line:lower()
        for _, w in ipairs(KB.SCREEN_WORDS) do
            if l:find(w, 1, true) then
                all[#all + 1] = line
                break
            end
        end
    end
    p:close()
    local last = KB.screen_seen
    KB.screen_seen = all[#all] or last
    local from = 1
    if last then
        for i = #all, 1, -1 do
            if all[i] == last then
                from = i + 1
                break
            end
        end
    end
    local new = {}
    for i = math.max(from, #all - 3), #all do new[#new + 1] = all[i]:sub(1, 160) end
    return #new > 0 and table.concat(new, " | ") or nil
end

--- Ends browsers the plugin started that outlived it (KOReader crashed, or was killed):
-- Chromium 75 keeps running when its DevTools pipe closes. Returns how many it ended.
function KB.killOrphans()
    local ok, iter, dir = pcall(fs.lfs.dir, KB.root .. "/proc")
    if not ok then return 0 end
    local killed = {}
    for entry in iter, dir do
        if entry:match("^%d+$") then
            local env = "\0" .. (read(KB.root .. "/proc/" .. entry .. "/environ") or "")
            if env:find("\0KO_DEVTOOLS_PIPE=1\0", 1, true) and env:find("\0KO_QUIET_LIPC=1\0", 1, true) then
                ffi.C.kill(tonumber(entry), 9)
                killed[#killed + 1] = entry
            end
        end
    end
    -- gone once init has reaped them
    for _ = 1, 20 do
        local left = false
        for _, pid in ipairs(killed) do
            if fs.lfs.attributes(KB.root .. "/proc/" .. pid) then left = true end
        end
        if not left then break end
        sleep_ms(50)
    end
    return #killed
end

--- Makes the browser's folder (cfg from mdict/kindletest kindleConfig()), with the shim in it.
-- Returns true, or nil and an error.
function KB.prepare(cfg)
    fs.removeTree(cfg.host_work)
    if not fs.mkdirp(cfg.host_work .. "/profile") then return nil, "cannot create " .. cfg.host_work end
    ffi.C.chmod(cfg.host_work, tonumber("755", 8))
    ffi.C.chmod(cfg.host_work .. "/profile", tonumber("777", 8)) -- the browser runs as user 9000
    if cfg.shim then
        local data = read(cfg.shim)
        if not data or not write(cfg.host_work .. "/kindle_shim.so", data) then return nil, "cannot copy the library" end
        ffi.C.chmod(cfg.host_work .. "/kindle_shim.so", tonumber("755", 8))
    end
    return true
end

--- Starts the browser and waits until its DevTools answer. info (optional) gets pid, load_at,
-- ready_at (seconds after t0, default now) and version.
-- Returns the client; or nil, an error and the client when it started but did not answer.
function KB.start(cfg, info, t0)
    info = info or {}
    t0 = t0 or monotonic()
    local browser, err = Cdp.spawn({ exe = cfg.exe, args = cfg.args, env = cfg.env, root = cfg.root or nil,
        log = cfg.host_work .. "/browser.log" })
    if not browser then return nil, err end
    info.pid = browser.pid
    -- should memory run out, the kernel ends the browser first, not the Kindle's own software
    if cfg.oom_adjust ~= false then write((cfg.proc or "/proc") .. "/" .. info.pid .. "/oom_score_adj", "1000") end
    if cfg.lipc_load then
        local deadline = monotonic() + 10
        while monotonic() < deadline and not browser:exitStatus() do
            if KB.lipcLoad() then info.load_at = monotonic() - t0 break end
            sleep_ms(250)
        end
    end
    local version
    version, err = browser:call("Browser.getVersion", nil, nil, (cfg.start_timeout or KB.START_TIMEOUT) - (monotonic() - t0))
    if not version then return nil, err, browser end
    info.version, info.ready_at = version.product, monotonic() - t0
    return browser
end

--- Removes what the browser left: its pid file (when it is ours) and its folder.
-- Returns the browser's log.
function KB.cleanup(cfg, pid)
    local log = read(cfg.host_work .. "/browser.log")
    if cfg.pid_file and pid and (read(cfg.pid_file) or ""):match("^%s*(%d+)") == tostring(pid) then
        os.remove(cfg.pid_file)
    end
    fs.removeTree(cfg.host_work)
    return log
end

--- Closes the browser and cleans up. Returns how it ended, its exit status and its log.
function KB.stop(browser, cfg)
    local pid = browser.pid
    local how, status = browser:close(KB.CLOSE_GRACE)
    return how, status, KB.cleanup(cfg, pid)
end

-- Draws a page image (JPEG or PNG) into w*h RGBA with KOReader's image decoders. It can be
-- a pixel or two off the page size (a CSS size times a fractional pixel ratio): the page
-- then gets what overlaps, and white for the rest. extra: rows below the page (the bridge's
-- strip, of one grey), whose grey is returned after true.
function KB.decode(data, ptr, w, h, extra)
    extra = extra or 0
    local mupdf = require("ffi/mupdf")
    local Blitbuffer = require("ffi/blitbuffer")
    local img = mupdf.renderImage(data, #data)
    if not img then return nil, "cannot decode the page" end
    local iw, ih = img:getWidth(), img:getHeight()
    if math.abs(iw - w) > 2 or math.abs(ih - h - extra) > 2 then
        img:free()
        return nil, string.format("the page is %dx%d, not %dx%d", iw, ih, w, h + extra)
    end
    local grey
    if extra > 0 then
        local y, sum, n = ih - 1 - math.floor(extra / 4), 0, 0
        for x = math.floor(iw / 4), math.floor(iw * 3 / 4), 4 do
            sum, n = sum + img:getPixel(x, y):getColor8().a, n + 1
        end
        grey = sum / n
    end
    local dst = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB32, ptr)
    if iw < w or ih < h then dst:fill(Blitbuffer.COLOR_WHITE) end
    dst:blitFrom(img, 0, 0, 0, 0, math.min(w, iw), math.min(h, ih))
    img:free()
    return true, grey
end

--- Starts the browser as a renderer bridge. opts: shim, screen ({ w, h }), dpr, log(...),
-- config (instead of kindleConfig, for tests), decode (instead of KB.decode), watch (instead of
-- KB.watch; false for none).
-- Returns the bridge, or nil and an error.
function KB.bridge(opts)
    local Test = require("mdict/kindletest")
    local cfg = opts.config or Test.kindleConfig(opts.screen, opts.shim)
    local ok, err = KB.prepare(cfg)
    if not ok then return nil, err end
    local info = {}
    local browser, berr, started = KB.start(cfg, info)
    if not browser then
        if started then KB.stop(started, cfg) else KB.cleanup(cfg) end
        return nil, "the browser did not start: " .. tostring(berr)
    end
    if opts.log then
        opts.log("Kindle browser ready after", string.format("%.1f s", info.ready_at), info.version,
            "with memory", KB.memoryText(browser.pid))
    end
    local CdpBridge = require("renderers/cdp_bridge")
    local pid = browser.pid
    local bridge
    bridge, err = CdpBridge.new({
        cdp = browser,
        dpr = opts.dpr,
        max_slots = 1, -- a new page crashes this browser
        capture = KB.CAPTURE,
        screencast = KB.SCREENCAST,
        decode = opts.decode or KB.decode,
        log = opts.log,
        -- a single core at 1 GHz: a large dictionary's first entry can take seconds
        cast_wait = KB.CAST_WAIT, capture_wait = KB.CAPTURE_WAIT,
        load_timeout = KB.LOAD_TIMEOUT, op_timeout = KB.OP_TIMEOUT,
        close_grace = KB.CLOSE_GRACE,
        watch = opts.watch == nil and KB.watch or opts.watch or nil,
        on_free = function() KB.cleanup(cfg, pid) end,
    })
    if not bridge then
        KB.stop(browser, cfg)
        return nil, err
    end
    bridge.kindle = { cfg = cfg, info = info }
    bridge.memoryNote = function() return KB.memoryText(pid) end
    bridge.screenNote = KB.screenLines
    KB.screenLines() -- only what comes from now on
    return bridge
end

return KB
