--[[
The Kindle browser check reads a fake Kindle (a Paperwhite on firmware 5.18, with KOReader
started without stopping the framework) and the machine running the specs.
]]
local helper = require("spec.helper")
local Check = require("mdict/kindlecheck")

local function write(root, path, data)
    local full = root .. path
    os.execute("mkdir -p '" .. full:match("^(.*)/[^/]*$") .. "'")
    local f = assert(io.open(full, "wb"))
    f:write(data or "")
    f:close()
end

local function proc(root, pid, name, state, rss_kb)
    write(root, "/proc/" .. pid .. "/stat", string.format("%d (%s) %s 1 1 1 0 -1", pid, name, state))
    write(root, "/proc/" .. pid .. "/status", string.format("Name:\t%s\nUid:\t0\t0\t0\t0\n%s", name,
        rss_kb and string.format("VmRSS:\t%8d kB\n", rss_kb) or ""))
end

local function fake_kindle()
    local root = helper.tmpdir("kindle")
    write(root, "/proc/meminfo", "MemTotal:         505648 kB\nMemFree:           40960 kB\n"
        .. "MemAvailable:     204800 kB\nBuffers:            8192 kB\nCached:           150000 kB\n"
        .. "SwapTotal:        131068 kB\nSwapFree:         120000 kB\n")
    write(root, "/proc/cpuinfo", "processor\t: 0\nmodel name\t: ARMv7 Processor rev 10 (v7l)\nBogoMIPS\t: 48.00\n\n"
        .. "Hardware\t: Freescale i.MX 6SoloLite based Board\nSerial\t\t: 0123456789abcdef\n")
    write(root, "/proc/version", "Linux version 4.1.15-lab126 (builder@host) (gcc version 4.9) #1 PREEMPT\n")
    write(root, "/proc/self/status", "Name:\tluajit\nUid:\t0\t0\t0\t0\nVmRSS:\t   61440 kB\n")
    write(root, "/proc/mounts", "rootfs / rootfs rw 0 0\n/dev/loop/1 /usr/bin/chromium squashfs ro 0 0\n"
        .. "/dev/loop/0 /usr/java/lib/fonts squashfs ro 0 0\n")
    proc(root, 1, "init", "S", 900)
    proc(root, 210, "X", "S", 14336)
    proc(root, 230, "awesome", "T", 6144)
    proc(root, 240, "appmgrd", "S", 3072)
    proc(root, 250, "cvm", "T", 51200)
    proc(root, 260, "lipc-daemon", "S", 2048)
    proc(root, 300, "reader.lua", "R", 61440)
    proc(root, 301, "kworker/0:1 x", "I") -- a name with a space, no memory
    write(root, "/etc/prettyversion.txt", "Kindle 5.18.1.1 (1234567890)\n")
    write(root, "/usr/bin/chromium.sqsh", string.rep("x", 3 * 1024 * 1024))
    write(root, "/usr/bin/chromium/bin/kindle_browser")
    write(root, "/chroot/usr/bin/chromium/bin/kindle_browser")
    write(root, "/usr/bin/browser", "#!/bin/bash\n")
    write(root, "/usr/java/lib/fonts/a.ttf")
    write(root, "/usr/java/lib/fonts/b.ttf")
    write(root, "/tmp/.X11-unix/X0")
    write(root, "/mnt/us/documents/.keep")
    return root
end

describe("Kindle browser check", function()
    after_each(function() Check.root = "" end)

    it("reports memory, Amazon's services and the browser on a Kindle", function()
        Check.root = fake_kindle()
        local df = function(path)
            if path:find("/mnt/us$") then return 3000 * 1048576, 2100 * 1048576, 2048 * 1048576 end
        end
        local r = Check.collect({ plugin_version = "0.2.3-beta.1", koreader_version = "v2026.07.1",
            model = "KindlePaperWhite4", is_kindle = true, screen = { w = 1072, h = 1448, dpi = 300 }, df = df })
        local function has(s) assert(r:find(s, 1, true), "missing: " .. s .. "\n" .. r) end
        has("MDict Kindle browser check (format 1)\n")
        has("Plugin 0.2.3-beta.1, KOReader v2026.07.1\n")
        has("Device: KindlePaperWhite4, screen 1072x1448 at 300 dpi\n")
        has("Firmware: Kindle 5.18.1.1 (1234567890)\n")
        has("Kernel: 4.1.15-lab126\n")
        has("CPU: ARMv7 Processor rev 10 (v7l), 1 core, Freescale i.MX 6SoloLite based Board\n")
        has("Memory: 494 MB total, 200 MB available, 40 MB free, 146 MB cached; swap 128 MB, 117 MB free\n")
        has("KOReader: 60 MB resident, runs as root\n")
        has("Browser image: /usr/bin/chromium.sqsh, 3 MB\n")
        has("Browser mounted: squashfs at /usr/bin/chromium\n")
        has("Browser build: chroot, own C library; /chroot is ready\n")
        has("Browser launcher: /usr/bin/browser\n")
        has("System fonts: 2 files in /usr/java/lib/fonts\n")
        has("X display socket: present\n")
        has("Storage: /mnt/us 2048 MB free of 3000 MB\n")
        has("  X server: X running, 14 MB\n")
        has("  window manager: awesome stopped, 6 MB\n")
        has("  framework: cvm stopped, 50 MB\n")
        has("  browser: not running\n")
        has("Largest processes: reader.lua 60 MB, cvm 50 MB (stopped), X 14 MB, awesome 6 MB (stopped)\n")
        has("Processes: 8\n")
        -- nothing that could identify the device or its owner
        assert.is_nil(r:find("0123456789abcdef", 1, true))
        assert.is_nil(r:find("builder@host", 1, true))
    end)

    it("says what is missing on a device without the browser", function()
        Check.root = helper.tmpdir("bare")
        local r = Check.collect({ model = "KindleTouch", is_kindle = true })
        assert.truthy(r:find("Browser image: none\n", 1, true))
        assert.truthy(r:find("Browser mounted: no\n", 1, true))
        assert.truthy(r:find("Browser build: not found\n", 1, true))
        assert.truthy(r:find("Firmware: ?\n", 1, true))
        assert.truthy(r:find("  app manager: not running\n", 1, true))
    end)

    it("saves the report in KOReader's folder and shows it", function()
        local data = helper.tmpdir("kindle-data")
        local shown
        package.loaded["device"] = { model = "KindlePaperWhite4", isKindle = function() return true end,
            screen = { getWidth = function() return 1072 end, getHeight = function() return 1448 end,
                       getDPI = function() return 300 end } }
        package.loaded["version"] = { getCurrentRevision = function() return "v2026.07.1" end }
        package.loaded["datastorage"] = { getDataDir = function() return data end }
        package.loaded["ui/uimanager"] = { show = function(_, w) shown = w end }
        package.loaded["ui/widget/textviewer"] = { new = function(_, o) return o end }
        package.loaded["gettext"] = function(s) return s end
        package.loaded["ffi/util"] = { template = function(s, a) return (s:gsub("%%1", a)) end,
            df = function() return nil end }
        Check.root = fake_kindle()
        local report, path = Check.show("0.2.3-beta.1")
        for _, m in ipairs({ "device", "version", "datastorage", "ui/uimanager", "ui/widget/textviewer", "gettext",
                             "ffi/util" }) do
            package.loaded[m] = nil
        end
        assert.equal(data .. "/mdict-kindle-report.txt", path)
        local f = assert(io.open(path, "rb"))
        assert.equal(report, f:read("*a"))
        f:close()
        assert.truthy(report:find("Plugin 0.2.3-beta.1, KOReader v2026.07.1\n", 1, true))
        assert.truthy(report:find("Device: KindlePaperWhite4, screen 1072x1448 at 300 dpi\n", 1, true))
        assert.equal("Kindle browser check", shown.title)
        assert.truthy(shown.text:find("Saved as " .. path, 1, true))
        assert.truthy(shown.text:find(report, 1, true))
    end)

    it("runs on the machine running the specs", function()
        local r = Check.collect({ model = "test", is_kindle = false })
        assert.truthy(r:find("Device: test (not a Kindle)", 1, true))
        assert.truthy(r:find("\nMemory: %d+ MB total"))
        assert.truthy(r:find("\nProcesses: %d+\n"))
    end)
end)
