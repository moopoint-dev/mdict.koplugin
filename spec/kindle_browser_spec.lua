--[[
The Kindle browser as a renderer: what renderers/kindle_browser.lua checks before it starts
one, and how the manager uses it (off by default, one page, closed when idle or asleep).
]]
local helper = require("spec.helper")
local KB = require("renderers/kindle_browser")

local function write(path, data)
    local f = assert(io.open(path, "wb"))
    f:write(data)
    f:close()
end

describe("Kindle browser", function()
    it("reads the memory available", function()
        local root = helper.tmpdir("kb-root")
        os.execute("mkdir -p '" .. root .. "/proc'")
        write(root .. "/proc/meminfo", "MemTotal:  502788 kB\nMemFree:  32768 kB\nMemAvailable:  164864 kB\n")
        KB.root = root
        assert.equal(164864 * 1024, KB.availableMemory())
        KB.root = ""
    end)

    it("watches memory: frees the browser's caches when it runs low, and stops it when that is not enough", function()
        local root = helper.tmpdir("kb-watch")
        os.execute("mkdir -p '" .. root .. "/proc/321'")
        write(root .. "/proc/321/status", "Name:\tkindle_browser\nVmRSS:\t   73728 kB\n")
        local function avail(mb) write(root .. "/proc/meminfo", "MemAvailable:  " .. mb * 1024 .. " kB\n") end
        KB.root = root
        local released, logged = 0, {}
        local bridge = { cdp = { pid = 321 }, log = function(...) logged[#logged + 1] = table.concat({ ... }, " ") end }
        local can_release = true
        function bridge.releaseMemory()
            if not can_release then return false end
            released = released + 1
            return true
        end
        avail(120)
        assert.is_nil(KB.watch(bridge))
        assert.equal(0, released)
        assert.equal("120 MB free, browser 72 MB", KB.memoryText(321))
        avail(45) -- low: the browser frees what it can
        assert.is_nil(KB.watch(bridge))
        assert.equal(1, released)
        assert.truthy(logged[1]:find("45 MB free, browser 72 MB", 1, true))
        can_release = false -- (asked a moment ago)
        avail(20)
        assert.equal("the Kindle is low on memory (20 MB free)", KB.watch(bridge))
        can_release = true -- asked now, and it freed enough
        local settle = KB.RELEASE_SETTLE
        KB.RELEASE_SETTLE = 10
        local reads = 0
        local availableMemory = KB.availableMemory
        KB.availableMemory = function()
            reads = reads + 1
            return (reads == 1 and 20 or 40) * 1048576
        end
        assert.is_nil(KB.watch(bridge))
        assert.equal(2, released)
        KB.availableMemory, KB.RELEASE_SETTLE, KB.root = availableMemory, settle, ""
    end)

    it("finds the kernel's messages about running out of memory", function()
        local dmesg = KB.DMESG
        KB.DMESG = "printf '[1] usb ok\\n[2] kindle_browser invoked oom-killer: gfp_mask=0x201da\\n"
            .. "[3] Out of memory: Kill process 4242 (kindle_browser) score 1000\\n[4] wifi up\\n'"
        assert.equal("[2] kindle_browser invoked oom-killer: gfp_mask=0x201da | "
            .. "[3] Out of memory: Kill process 4242 (kindle_browser) score 1000", KB.oomLines())
        KB.DMESG = "printf '[1] quiet\\n'"
        assert.is_nil(KB.oomLines())
        KB.DMESG = dmesg
    end)

    it("reports the kernel's new messages about the e-ink screen", function()
        local dmesg = KB.DMESG
        KB.screen_seen = nil
        KB.DMESG = "printf '[1] usb ok\\n[2] mxc_epdc_fb: TCE underrun! Will continue to update panel\\n[3] wifi up\\n'"
        assert.equal("[2] mxc_epdc_fb: TCE underrun! Will continue to update panel", KB.screenLines())
        -- only what is new since the last time
        assert.is_nil(KB.screenLines())
        KB.DMESG = "printf '[2] mxc_epdc_fb: TCE underrun! Will continue to update panel\\n[5] wifi down\\n"
            .. "[6] mxc_epdc_fb: Collision occurred\\n'"
        assert.equal("[6] mxc_epdc_fb: Collision occurred", KB.screenLines())
        KB.DMESG = "false"
        assert.is_nil(KB.screenLines())
        KB.DMESG, KB.screen_seen = dmesg, nil
    end)

    it("ends browsers it started that outlived KOReader, and nothing else", function()
        local dir = helper.tmpdir("kb-orphan")
        local function start(env)
            os.execute(string.format("env %s sleep 30 >/dev/null 2>&1 & echo $! > '%s/pid'", env, dir))
            local f = assert(io.open(dir .. "/pid"))
            local pid = f:read("*l")
            f:close()
            return pid
        end
        local orphan = start("KO_DEVTOOLS_PIPE=1 KO_QUIET_LIPC=1")
        local other = start("KO_DEVTOOLS_PIPE=1")
        assert.truthy(io.open("/proc/" .. orphan .. "/environ"))
        assert.is_true(KB.killOrphans() >= 1)
        local function alive(pid)
            local f = io.open("/proc/" .. pid .. "/stat")
            local st = f and f:read("*a") or ""
            if f then f:close() end
            return st ~= "" and not st:match("^%d+ %b() Z")
        end
        assert.is_false(alive(orphan))
        assert.is_true(alive(other))
        os.execute("kill " .. other)
    end)
end)

describe("Kindle browser in the manager", function()
    local saved = {}
    local scheduled, shown, kb_calls, closed
    local Manager
    local fake_bridge

    local function stub(name, value)
        saved[name] = package.loaded[name]
        package.loaded[name] = value
    end

    before_each(function()
        scheduled, shown, kb_calls, closed = {}, {}, {}, {}
        stub("device", { isKindle = function() return true end, hasEinkScreen = function() return true end,
            screen = { getWidth = function() return 1072 end, getHeight = function() return 1448 end,
                       getDPI = function() return 300 end } })
        stub("ui/uimanager", {
            scheduleIn = function(_, s, fn) scheduled[#scheduled + 1] = { s = s, fn = fn } end,
            unschedule = function() end,
            show = function(_, w) shown[#shown + 1] = w end,
            close = function(_, w) closed[#closed + 1] = w end,
            nextTick = function(_, fn) fn() end,
            forceRePaint = function() end,
        })
        stub("ui/widget/notification", { new = function(_, o) o.kind = "notification" return o end })
        stub("ui/widget/infomessage", { new = function(_, o) o.kind = "info" return o end })
        stub("renderers/android_bridge", { isAvailable = function() return false end })
        stub("mdict/kindletest", { problems = function() return {} end })
        fake_bridge = {
            max_slots = 1, kindle = {}, dead = false,
            alive = function(b) return not b.dead end,
            closeAll = function() end,
            free = function(b) b.freed = true end,
        }
        stub("renderers/kindle_browser", {
            IDLE_CLOSE = 600, MIN_MEMORY = 80 * 1048576,
            killOrphans = function() kb_calls[#kb_calls + 1] = "killOrphans" return 0 end,
            oomLines = function() return "[3] Out of memory: Kill process 4242 (kindle_browser)" end,
            availableMemory = function() return 150 * 1048576 end,
            bridge = function(opts)
                kb_calls[#kb_calls + 1] = opts
                return fake_bridge
            end,
        })
        package.loaded["renderers/manager"] = nil
        Manager = require("renderers/manager")
    end)

    after_each(function()
        for name, value in pairs(saved) do package.loaded[name] = value end
        saved = {}
        package.loaded["renderers/manager"] = nil
    end)

    it("is on unless the reader turns it off", function()
        assert.is_nil(Manager.get({ settings = { kindle_browser = false } }))
        assert.equal(0, #kb_calls)
        assert.equal(0, #shown) -- nothing to tell
        Manager.failed = nil -- (as turning it on in the menu does)
        assert(Manager.get({ settings = {} }))
        assert.equal("killOrphans", kb_calls[1])
        Manager.shutdown()
    end)

    it("leaves Kindles that cannot run it to the built-in renderer without a word, unless turned on", function()
        package.loaded["mdict/kindletest"].problems = function()
            return { "This Kindle's browser is not supported by the test yet." }
        end
        assert.is_nil(Manager.get({ settings = {} }))
        assert.truthy(Manager.failed:find("not supported", 1, true))
        assert.equal(0, #shown)
        -- turned on in the menu (when it was off by default): the reader is told
        Manager.failed = nil
        assert.is_nil(Manager.get({ settings = { kindle_browser = true } }))
        assert.equal(1, #shown)
        assert.truthy(shown[1].text:find("not supported", 1, true))
    end)

    it("starts the browser with one page, the screen's pixel ratio and the shim", function()
        local r = assert(Manager.get({ settings = { kindle_browser = true } }))
        -- the reader is told while it starts, and the message goes once the lookup is shown
        assert.equal("info", shown[1].kind)
        assert.truthy(shown[1].text:find("Starting the Kindle's browser", 1, true))
        assert.equal(shown[1], closed[1])
        assert.equal("killOrphans", kb_calls[1])
        local opts = kb_calls[2]
        -- a whole pixel ratio (screencast frames are in device pixels only then), zoomed to 300/160
        assert.equal(2, opts.dpr)
        assert.equal(300 / 160 / 2, r.bridge.zoom)
        assert.same({ w = 1072, h = 1448 }, opts.screen)
        assert.truthy(opts.shim:find("/kindle/kindle_shim%.so$"))
        assert.equal(1, r.max_slots)
        assert.equal(r, Manager.get({ settings = { kindle_browser = true } }))
        Manager.shutdown()
        assert.is_true(fake_bridge.freed)
    end)

    it("closes the browser once it has not been used for a while", function()
        local clock = require("mdict/clock")
        local state = { settings = { kindle_browser = true } }
        assert(Manager.get(state))
        assert.equal(1, #scheduled)
        scheduled[1].fn() -- just used: checked again later
        assert.truthy(Manager.renderer)
        assert.equal(2, #scheduled)
        fake_bridge.last_use = clock() - 601
        scheduled[2].fn()
        assert.is_nil(Manager.renderer)
        assert.is_true(fake_bridge.freed)
        -- the next lookup starts it again
        fake_bridge.freed = false
        assert(Manager.get(state))
    end)

    it("falls back to the built-in renderer, and says why, when the browser cannot start or ends", function()
        package.loaded["mdict/kindletest"].problems = function() return { "Amazon's display server (X) is not running." } end
        assert.is_nil(Manager.get({ settings = { kindle_browser = true } }))
        assert.equal(1, #shown)
        assert.equal("notification", shown[1].kind) -- (nothing was started)
        assert.truthy(shown[1].text:find("display server", 1, true))
        Manager.failed, Manager.notified = nil, false
        package.loaded["mdict/kindletest"].problems = function() return {} end
        assert(Manager.get({ settings = { kindle_browser = true } }))
        fake_bridge.dead = true
        assert.is_nil(Manager.get({ settings = { kindle_browser = true } }))
        assert.is_true(fake_bridge.freed)
        assert.equal(3, #shown)
        assert.truthy(shown[3].text:find("the browser ended", 1, true))
    end)

    it("stops the browser when memory runs low, and says when the Kindle ran out", function()
        local state = { settings = { kindle_browser = true } }
        assert(Manager.get(state))
        fake_bridge.checkNow = function() return "the Kindle is low on memory (20 MB free)" end
        assert.is_nil(Manager.get(state))
        assert.is_true(fake_bridge.freed)
        assert.truthy(shown[#shown].text:find("(the Kindle is low on memory (20 MB free))", 1, true))
        -- killed by the kernel, without a word
        Manager.failed, Manager.notified, fake_bridge.freed = nil, false, false
        fake_bridge.checkNow = nil
        assert(Manager.get(state))
        fake_bridge.dead, fake_bridge.ended = true, "the browser ended (killed by signal 9)"
        assert.is_nil(Manager.get(state))
        assert.equal("the browser ended (killed by signal 9)", Manager.failed)
        assert.truthy(shown[#shown].text:find("(the Kindle ran out of memory)", 1, true))
    end)

    it("needs enough free memory", function()
        package.loaded["renderers/kindle_browser"].availableMemory = function() return 50 * 1048576 end
        assert.is_nil(Manager.get({ settings = { kindle_browser = true } }))
        assert.truthy(Manager.failed:find("only 50 MB of memory", 1, true))
    end)
end)
