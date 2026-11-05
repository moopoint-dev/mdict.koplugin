--[[
The Kindle browser test, on a fake Kindle (what stands in the way, how the browser is
started, the report) and, when MDICT_CHROMIUM names a Chromium binary, run for real
against that browser through its DevTools pipe.
]]
local helper = require("spec.helper")
local Test = require("mdict/kindletest")

local function write(root, path, data)
    local full = root .. path
    os.execute("mkdir -p '" .. full:match("^(.*)/[^/]*$") .. "'")
    local f = assert(io.open(full, "wb"))
    f:write(data or "")
    f:close()
end

local function proc(root, pid, name)
    write(root, "/proc/" .. pid .. "/stat", string.format("%d (%s) S 1 1 1 0 -1", pid, name))
end

-- A Paperwhite on firmware 5.18 whose browser is ready to start.
local function ready_kindle()
    local root = helper.tmpdir("kindle-test")
    write(root, "/proc/meminfo", "MemTotal:  505648 kB\nMemAvailable:  204800 kB\nSwapFree:  120000 kB\n")
    write(root, "/proc/mounts", "rootfs / rootfs rw 0 0\ntmpfs /tmp tmpfs rw,relatime,size=65536k 0 0\n")
    proc(root, 1, "init")
    proc(root, 300, "reader.lua")
    write(root, "/chroot/usr/bin/chromium/bin/kindle_browser")
    write(root, "/usr/bin/chromium/bin/kindle_browser")
    write(root, "/tmp/.X11-unix/X0")
    write(root, "/etc/prettyversion.txt", "Kindle 5.18.1.1.1 (1234567890)\n")
    write(root, "/plugin/kindle/kindle_shim.so", "\127ELF")
    return root
end

describe("Kindle browser test", function()
    after_each(function() Test.root = "" end)

    it("decodes the browser's base64", function()
        assert.equal("hello", Test.unbase64("aGVsbG8="))
        assert.equal("hello!", Test.unbase64("aGVsbG8h"))
        assert.equal("hell", Test.unbase64("aGVsbA=="))
        assert.equal("\0\1\2\255", Test.unbase64("AAEC/w=="))
        assert.equal("", Test.unbase64(""))
        -- a long one, from a plain encoder
        local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        local big = string.rep("\0\1\2\255xyz", 5000) .. "ab"
        local enc = {}
        for i = 1, #big, 3 do
            local a, b, c = big:byte(i, i + 2)
            local v = a * 65536 + (b or 0) * 256 + (c or 0)
            local q = {}
            for k = 3, 0, -1 do q[#q + 1] = chars:sub(math.floor(v / 64 ^ k) % 64 + 1, math.floor(v / 64 ^ k) % 64 + 1) end
            if not c then q[4] = "=" end
            if not b then q[3] = "=" end
            enc[#enc + 1] = table.concat(q)
        end
        assert.equal(big, Test.unbase64(table.concat(enc)))
    end)

    it("finds nothing in the way on a ready Kindle", function()
        Test.root = ready_kindle()
        assert.same({}, Test.problems({ is_kindle = true, shim = Test.root .. "/plugin/kindle/kindle_shim.so" }))
    end)

    it("says what is in the way", function()
        Test.root = helper.tmpdir("kindle-bare")
        write(Test.root, "/proc/meminfo", "MemAvailable:  40960 kB\n")
        write(Test.root, "/proc/mounts", "tmpfs /tmp tmpfs rw,noexec 0 0\n")
        proc(Test.root, 410, "kindle_browser")
        local list = Test.problems({ is_kindle = false, shim = Test.root .. "/missing.so" })
        local text = table.concat(list, "\n")
        for _, s in ipairs({ "not a Kindle", "not supported by the test yet", "missing kindle/kindle_shim.so",
                             "display server (X) is not running", "browser is open (kindle_browser)",
                             "noexec", "Only 40 MB of memory is available" }) do
            assert.truthy(text:find(s, 1, true), "missing: " .. s .. "\n" .. text)
        end
        -- the browser is there but Amazon has not prepared /chroot yet
        Test.root = ready_kindle()
        os.remove(Test.root .. "/chroot/usr/bin/chromium/bin/kindle_browser")
        list = Test.problems({ is_kindle = true, shim = Test.root .. "/plugin/kindle/kindle_shim.so" })
        assert.equal(1, #list)
        assert.truthy(list[1]:find("/chroot is not ready", 1, true))
    end)

    it("starts Amazon's browser in its chroot, with the library preloaded and its window off the screen", function()
        local cfg = Test.kindleConfig({ w = 1072, h = 1448 }, "/plugin/kindle/kindle_shim.so")
        assert.equal("/chroot", cfg.root)
        assert.equal("/chroot/tmp/mdict-browser", cfg.host_work)
        assert.equal("/usr/bin/chromium/bin/kindle_browser", cfg.exe)
        local env = table.concat(cfg.env, "\n") .. "\n"
        for _, kv in ipairs({ "LD_PRELOAD=/tmp/mdict-browser/kindle_shim.so", "KO_DEVTOOLS_PIPE=1", "KO_QUIET_LIPC=1",
                              "KO_OFFSCREEN=1464", "XDG_CONFIG_HOME=/tmp/mdict-browser/profile",
                              "LD_LIBRARY_PATH=/usr/bin/chromium/lib:/usr/bin/chromium/usr/lib:/usr/lib/" }) do
            assert.truthy(env:find(kv .. "\n", 1, true), "missing " .. kv)
        end
        local args = table.concat(cfg.args, " ")
        assert.truthy(args:find("--single-process", 1, true))
        assert.truthy(args:find("--enable-grayscale-mode", 1, true))
        assert.is_nil(args:find("user-agent", 1, true))
        assert.equal("about:blank", cfg.args[#cfg.args])
    end)

    it("reports a test that could not run", function()
        Test.root = ready_kindle()
        local r = Test.report({ plugin_version = "0.2.4", koreader_version = "v2026.07.2", model = "KindlePaperWhite4" },
            { problems = { "Amazon's display server (X) is not running." } })
        assert.equal("MDict Kindle browser test (format 1)\nPlugin 0.2.4, KOReader v2026.07.2\n"
            .. "Device: KindlePaperWhite4; firmware Kindle 5.18.1.1.1 (1234567890)\n"
            .. "Not run:\n  Amazon's display server (X) is not running.\n", r)
    end)

    it("reports timings, memory and the browser's messages", function()
        local r = Test.report({ plugin_version = "0.2.4", model = "KindlePaperWhite4" }, {
            ok = true, version = "Chrome/75.0.3770.143", ready_at = 3.04, load_at = 0.6, page_at = 6.3, total = 17.9,
            mem_before = { MemAvailable = 160 * 1048576, SwapFree = 126 * 1048576 },
            mem_during = { MemAvailable = 40 * 1048576, SwapFree = 90 * 1048576 },
            samples = { { name = "Japanese, vertical", pages = 3, vertical = true, mode = "columns", layout = 0.74,
                          ms = { total = 641, fonts = 288 }, capture = 2.8, png_bytes = 178000,
                          browser_mem = { rss = 120 * 1048576, peak = 131 * 1048576, swap = 0 } } },
            closed = "terminated", exit = "killed by signal 15",
            steps = { { name = "prepare", at = 0 }, { name = "start", at = 0.01 } },
            log = "Fontconfig warning: x\n\nDevTools listening on ws://127.0.0.1:1/devtools/browser/x\n",
        })
        local function has(s) assert(r:find(s, 1, true), "missing: " .. s .. "\n" .. r) end
        has("Result: OK\n")
        has("Memory before: 160 MB available, swap 126 MB free\n")
        has("Started: DevTools ready after 3.0 s, load sent after 0.6 s\n")
        has("Japanese, vertical: 3 pages (vertical, columns), laid out in 0.7 s (pager 641 ms, fonts 288 ms), "
            .. "page drawn in 2.8 s, 173 KB\n")
        has("  browser memory: 120 MB resident, peak 131 MB, 0 MB in swap\n")
        has("Memory while running: 40 MB available, swap 90 MB free\n")
        has("Closed: terminated (killed by signal 15) after 17.9 s in all\n")
        has("Steps (s): prepare 0.0, start 0.0\n")
        has("Browser messages (last 1):\n  DevTools listening")
        assert.is_nil(r:find("Fontconfig", 1, true))
    end)

    it("asks first, runs, saves the report and offers the pages", function()
        local data = helper.tmpdir("kindle-test-data")
        local shown, closed, asked = {}, {}, nil
        local stubs = {
            device = { model = "KindlePaperWhite4", isKindle = function() return true end,
                screen = { getWidth = function() return 1072 end, getHeight = function() return 1448 end } },
            version = { getCurrentRevision = function() return "v2026.07.2" end },
            datastorage = { getDataDir = function() return data end },
            ["ui/uimanager"] = { show = function(_, w) shown[#shown + 1] = w end,
                close = function(_, w) closed[#closed + 1] = w end,
                forceRePaint = function() end, nextTick = function(_, fn) fn() end },
            ["ui/widget/textviewer"] = { new = function(_, o) o.kind = "text" return o end },
            ["ui/widget/infomessage"] = { new = function(_, o) o.kind = "info" return o end },
            ["ui/widget/imageviewer"] = { new = function(_, o) o.kind = "image" return o end },
            ["ui/widget/confirmbox"] = { new = function(_, o) asked = o o.kind = "confirm" return o end },
            gettext = function(t) return t end,
            ["ffi/util"] = { template = function(t, a) return (t:gsub("%%1", a)) end },
        }
        for name, m in pairs(stubs) do package.loaded[name] = m end
        local problems, run = Test.problems, Test.run
        local ran
        Test.problems = function() return {} end
        Test.run = function(cfg, files)
            ran = cfg
            return { ok = true, steps = {}, samples = { { name = "Japanese, vertical", pages = 3, vertical = true,
                file = files[1] } } }
        end
        Test.show("0.2.4")
        assert.equal("confirm", shown[1].kind)
        asked.ok_callback()
        Test.problems, Test.run = problems, run
        assert.equal("info", shown[2].kind)
        assert.equal(shown[2], closed[1])
        assert.equal("/chroot", ran.root)
        local viewer = shown[3]
        assert.equal("text", viewer.kind)
        assert.equal("Kindle browser test", viewer.title)
        assert.truthy(viewer.text:find("Result: OK", 1, true))
        local f = assert(io.open(data .. "/mdict-kindle-browser-test.txt", "rb"))
        assert.truthy(viewer.text:find(f:read("*a"), 1, true))
        f:close()
        assert.equal("Japanese, vertical", viewer.buttons_table[1][1].text)
        viewer.buttons_table[1][1].callback()
        for name in pairs(stubs) do package.loaded[name] = nil end
        assert.equal("image", shown[4].kind)
        assert.equal(data .. "/mdict-kindle-browser-ja.png", shown[4].file)
    end)

    local chromium = os.getenv("MDICT_CHROMIUM")
    local real = chromium and it or pending
    real("lays out the sample entries in a real browser over its DevTools pipe", function()
        local work = helper.tmpdir("kindle-test-run")
        local out = helper.tmpdir("kindle-test-out")
        local cfg = {
            root = false, host_work = work .. "/w", work = work .. "/w", exe = chromium,
            args = { "--headless=new", "--no-sandbox", "--remote-debugging-pipe", "--hide-scrollbars",
                     "--user-data-dir=" .. work .. "/w/profile", "about:blank" },
            env = { "HOME=" .. work .. "/w/profile", "PATH=/usr/bin:/bin" },
        }
        local r = Test.run(cfg, { out .. "/ja.png", out .. "/en.png" })
        assert.is_true(r.ok, tostring(r.error))
        assert.equal(2, #r.samples)
        assert.is_true(r.samples[1].vertical)
        assert.is_false(r.samples[2].vertical)
        for _, s in ipairs(r.samples) do
            assert.truthy(s.pages >= 1)
            local f = assert(io.open(s.file, "rb"))
            assert.equal("\137PNG", f:read(4))
            f:close()
        end
        -- terminated right away: the Kindle's browser ignores Browser.close
        assert.equal("terminated", r.closed)
        assert.is_nil(io.open(work .. "/w/page.html", "rb")) -- cleaned up
    end)

    real("keeps ruby whole where the browser lays ruby text out as a block", function()
        local work = helper.tmpdir("kindle-test-ruby")
        local cfg = {
            root = false, host_work = work .. "/w", work = work .. "/w", exe = chromium,
            args = { "--headless=new", "--no-sandbox", "--remote-debugging-pipe",
                     "--user-data-dir=" .. work .. "/w/profile", "about:blank" },
            env = { "HOME=" .. work .. "/w/profile", "PATH=/usr/bin:/bin" },
            -- what Chromium before 121 does by itself
            samples = { { name = "ruby", writing = "vertical", html = "<style>ruby{display:inline}rt{display:block}</style>"
                .. "<p><span>「<ruby>友人<rt>ゆうじん</rt></ruby>に会う」</span></p>" } },
            inspect = "document.querySelectorAll('ruby[data-mdict-contents]').length + ' of '"
                .. " + document.querySelectorAll('ruby').length",
        }
        local r = Test.run(cfg, {})
        assert.is_true(r.ok, tostring(r.error))
        assert.equal("0 of 1", r.samples[1].inspect)
    end)
end)
