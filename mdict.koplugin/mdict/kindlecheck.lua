--[[--
"Kindle browser check": a report on whether this Kindle could lay out entries with its
own Chromium browser, which recent firmware ships for Amazon's web browser.

It only reads: /proc, a few system files and KOReader's environment. It starts nothing
and changes nothing on the device. The report is shown and saved as
koreader/mdict-kindle-report.txt, so it can be attached to a GitHub issue; it holds no
serial numbers, account, network or book names.
]]

local fs = require("mdict/fs")

local M = {}

M.root = "" -- prefix for every path read (the specs point it at a fake device)
M.REPORT_NAME = "mdict-kindle-report.txt"
M.FORMAT = 1 -- bumped when the report's contents change

local MB = 1024 * 1024

local function p(path) return M.root .. path end

local function read(path, max)
    local f = io.open(p(path), "rb")
    if not f then return nil end
    local s = f:read(max or "*a")
    f:close()
    return s
end

local function mb(bytes)
    if not bytes then return "?" end
    return string.format("%d MB", math.floor(bytes / MB + 0.5))
end

-- /proc/meminfo, in bytes
local function meminfo()
    local m = {}
    for k, v in (read("/proc/meminfo") or ""):gmatch("(%w+):%s+(%d+) kB") do m[k] = tonumber(v) * 1024 end
    return m
end

local function status_kb(text, key)
    local v = text and text:match("\n" .. key .. ":%s+(%d+) kB")
    return v and tonumber(v) * 1024
end

-- Every process: { pid, name, state, rss }
local function processes()
    local list = {}
    local ok, iter, dir = pcall(fs.lfs.dir, p("/proc"))
    if not ok then return list end
    for entry in iter, dir do
        if entry:match("^%d+$") then
            local stat = read("/proc/" .. entry .. "/stat") or ""
            local name, state = stat:match("^%d+ %((.*)%) (%S)")
            if name then
                list[#list + 1] = { pid = tonumber(entry), name = name, state = state,
                    rss = status_kb("\n" .. (read("/proc/" .. entry .. "/status") or ""), "VmRSS") }
            end
        end
    end
    table.sort(list, function(a, b) return a.pid < b.pid end)
    return list
end

local STATES = { R = "running", S = "running", D = "running", I = "running", T = "stopped", t = "stopped",
    Z = "zombie" }

-- Amazon's services that matter for running its browser beside KOReader.
local SERVICES = {
    { "X server", { "X", "Xorg", "Xfbdev" } },
    { "window manager", { "awesome" } },
    { "app manager", { "appmgrd" } },
    { "LIPC", { "lipc-daemon" } },
    { "D-Bus", { "dbus-daemon" } },
    { "framework", { "cvm", "kppmainapp" } },
    { "status bar", { "pillowd" } },
    { "web reader", { "webreader" } },
    { "browser", { "kindle_browser", "browserd" } },
    { "USB storage", { "volumd" } },
}

local function service_line(label, names, procs)
    local found = {}
    for _, pr in ipairs(procs) do
        for _, n in ipairs(names) do
            if pr.name == n then
                found[#found + 1] = string.format("%s %s%s", n, STATES[pr.state] or pr.state,
                    pr.rss and (", " .. mb(pr.rss)) or "")
            end
        end
    end
    return string.format("  %s: %s", label, #found > 0 and table.concat(found, "; ") or "not running")
end

local function file_size(path)
    local size = fs.stat(p(path))
    return size
end

local function count_files(dir)
    local n = 0
    local ok, iter, d = pcall(fs.lfs.dir, p(dir))
    if not ok then return nil end
    for entry in iter, d do
        if entry ~= "." and entry ~= ".." then n = n + 1 end
    end
    return n
end

local function mounts()
    local list = {}
    for line in (read("/proc/mounts") or ""):gmatch("[^\n]+") do
        local dev, at, kind = line:match("^(%S+) (%S+) (%S+)")
        if at then list[#list + 1] = { dev = dev, at = at, kind = kind } end
    end
    return list
end

local function mounted_at(list, at)
    for _, m in ipairs(list) do if m.at == at then return m end end
end

local function free_space(path, df)
    if not fs.isDir(p(path)) then return nil end
    local total, _, available
    if df then total, _, available = df(p(path)) end
    if not total then return nil end
    return string.format("%s %s free of %s", path, mb(available), mb(total))
end

--- The report, as text.
-- info: { plugin_version, koreader_version, model, is_kindle, screen = { w, h, dpi }, df = ffiUtil.df }
function M.collect(info)
    info = info or {}
    local out = {}
    local function add(fmt, ...) out[#out + 1] = select("#", ...) > 0 and string.format(fmt, ...) or fmt end

    add("MDict Kindle browser check (format %d)", M.FORMAT)
    add("Plugin %s, KOReader %s", info.plugin_version or "?", info.koreader_version or "?")
    local scr = info.screen
    add("Device: %s%s%s", info.model or "?", info.is_kindle == false and " (not a Kindle)" or "",
        scr and string.format(", screen %dx%d at %d dpi", scr.w, scr.h, scr.dpi) or "")
    local version = (read("/etc/prettyversion.txt") or ""):match("^[^\n]*")
    add("Firmware: %s", version ~= "" and version or "?")
    add("Kernel: %s", (read("/proc/version") or ""):match("^Linux version (%S+)") or "?")

    local cpuinfo = read("/proc/cpuinfo") or ""
    local cores = 0
    for _ in cpuinfo:gmatch("\nprocessor%s*:") do cores = cores + 1 end
    if cpuinfo:match("^processor%s*:") then cores = cores + 1 end
    add("CPU: %s, %d core%s%s", cpuinfo:match("model name%s*:%s*([^\n]+)") or cpuinfo:match("Processor%s*:%s*([^\n]+)")
        or "?", cores, cores == 1 and "" or "s",
        cpuinfo:match("Hardware%s*:%s*([^\n]+)") and (", " .. cpuinfo:match("Hardware%s*:%s*([^\n]+)")) or "")

    local m = meminfo()
    local self_status = "\n" .. (read("/proc/self/status") or "")
    add("Memory: %s total, %s available, %s free, %s cached; swap %s, %s free",
        mb(m.MemTotal), mb(m.MemAvailable), mb(m.MemFree), mb(m.Cached), mb(m.SwapTotal), mb(m.SwapFree))
    local uid = self_status:match("\nUid:%s+(%d+)")
    add("KOReader: %s resident, %s as root", mb(status_kb(self_status, "VmRSS")),
        uid == "0" and "runs" or (uid and "does not run" or "? runs"))

    local env = {}
    for _, k in ipairs({ "STOP_FRAMEWORK", "AWESOME_STOPPED", "PILLOW_HARD_DISABLED", "PILLOW_SOFT_DISABLED",
                         "DISPLAY" }) do
        env[#env + 1] = k .. "=" .. (os.getenv(k) or "(unset)")
    end
    add("Started with: %s", table.concat(env, " "))
    add("X display socket: %s", fs.lfs.attributes(p("/tmp/.X11-unix/X0")) and "present" or "missing")

    -- The browser: a squashfs image mounted at /usr/bin/chromium. Firmware up to 5.18
    -- runs it in a chroot with its own C library; later firmware links it to the system's.
    local ms = mounts()
    local sqsh = file_size("/usr/bin/chromium.sqsh")
    add("Browser image: %s", sqsh and ("/usr/bin/chromium.sqsh, " .. mb(sqsh)) or "none")
    local at = mounted_at(ms, "/usr/bin/chromium")
    add("Browser mounted: %s", at and (at.kind .. " at /usr/bin/chromium") or "no")
    if fs.isFile(p("/usr/bin/chromium/bin/kindle_browser")) then
        add("Browser build: chroot, own C library%s",
            fs.isFile(p("/chroot/usr/bin/chromium/bin/kindle_browser")) and "; /chroot is ready" or "; /chroot is not ready")
    elseif fs.isFile(p("/usr/bin/chromium/kindle_browser")) then
        add("Browser build: system libraries")
    else
        add("Browser build: not found")
    end
    add("Browser launcher: %s", fs.isFile(p("/usr/bin/browser")) and "/usr/bin/browser" or "none")
    local fonts = count_files("/usr/java/lib/fonts")
    add("System fonts: %s", fonts and string.format("%d files in /usr/java/lib/fonts", fonts) or "none")

    local space = {}
    for _, dir in ipairs({ "/mnt/us", "/tmp", "/var/tmp", "/var/local" }) do
        space[#space + 1] = free_space(dir, info.df)
    end
    add("Storage: %s", #space > 0 and table.concat(space, "; ") or "?")

    local procs = processes()
    add("Amazon services:")
    for _, s in ipairs(SERVICES) do add(service_line(s[1], s[2], procs)) end

    local big = {}
    for _, pr in ipairs(procs) do if pr.rss and pr.rss >= 4 * MB then big[#big + 1] = pr end end
    table.sort(big, function(a, b) return a.rss > b.rss end)
    local top = {}
    for i = 1, math.min(12, #big) do
        top[i] = string.format("%s %s%s", big[i].name, mb(big[i].rss), big[i].state == "T" and " (stopped)" or "")
    end
    add("Largest processes: %s", #top > 0 and table.concat(top, ", ") or "?")
    add("Processes: %d", #procs)
    return table.concat(out, "\n") .. "\n"
end

-- KOReader's facts for collect().
local function koreader_info(plugin_version)
    local Device = require("device")
    local info = { plugin_version = plugin_version, model = Device.model, is_kindle = Device:isKindle() }
    local ok, Version = pcall(require, "version")
    if ok and Version and Version.getCurrentRevision then info.koreader_version = Version:getCurrentRevision() end
    local scr = Device.screen
    if scr then info.screen = { w = scr:getWidth(), h = scr:getHeight(), dpi = scr:getDPI() } end
    local ok_util, ffiUtil = pcall(require, "ffi/util")
    if ok_util and ffiUtil.df then info.df = ffiUtil.df end
    return info
end

--- Runs the check, saves the report in KOReader's folder and shows it.
function M.show(plugin_version)
    local UIManager = require("ui/uimanager")
    local DataStorage = require("datastorage")
    local _ = require("gettext")
    local T = require("ffi/util").template
    local ok, report = pcall(M.collect, koreader_info(plugin_version))
    if not ok then report = "The check failed: " .. tostring(report) .. "\n" end
    local path = DataStorage:getDataDir() .. "/" .. M.REPORT_NAME
    local saved = fs.writeAtomic(path, report)
    local note = saved and T(_("Saved as %1. Please attach this file to the GitHub issue."), path)
        or T(_("Could not save the report to %1."), path)
    UIManager:show(require("ui/widget/textviewer"):new{
        title = _("Kindle browser check"),
        text = note .. "\n\n" .. report,
    })
    return report, saved and path
end

return M
