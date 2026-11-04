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
    local scheduled, shown, kb_calls
    local Manager
    local fake_bridge

    local function stub(name, value)
        saved[name] = package.loaded[name]
        package.loaded[name] = value
    end

    before_each(function()
        scheduled, shown, kb_calls = {}, {}, {}
        stub("device", { isKindle = function() return true end, hasEinkScreen = function() return true end,
            screen = { getWidth = function() return 1072 end, getHeight = function() return 1448 end,
                       getDPI = function() return 300 end } })
        stub("ui/uimanager", {
            scheduleIn = function(_, s, fn) scheduled[#scheduled + 1] = { s = s, fn = fn } end,
            unschedule = function() end,
            show = function(_, w) shown[#shown + 1] = w end,
        })
        stub("ui/widget/notification", { new = function(_, o) return o end })
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

    it("is off unless the reader turns it on", function()
        assert.is_nil(Manager.get({ settings = {} }))
        assert.equal(0, #kb_calls)
        assert.equal(0, #shown) -- nothing to tell
    end)

    it("starts the browser with one page, the screen's pixel ratio and the shim", function()
        local r = assert(Manager.get({ settings = { kindle_browser = true } }))
        assert.equal("killOrphans", kb_calls[1])
        local opts = kb_calls[2]
        assert.equal(300 / 160, opts.dpr)
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
        assert.truthy(shown[1].text:find("display server", 1, true))
        Manager.failed, Manager.notified = nil, false
        package.loaded["mdict/kindletest"].problems = function() return {} end
        assert(Manager.get({ settings = { kindle_browser = true } }))
        fake_bridge.dead = true
        assert.is_nil(Manager.get({ settings = { kindle_browser = true } }))
        assert.is_true(fake_bridge.freed)
        assert.equal(2, #shown)
        assert.truthy(shown[2].text:find("the browser ended", 1, true))
    end)

    it("needs enough free memory", function()
        package.loaded["renderers/kindle_browser"].availableMemory = function() return 50 * 1048576 end
        assert.is_nil(Manager.get({ settings = { kindle_browser = true } }))
        assert.truthy(Manager.failed:find("only 50 MB of memory", 1, true))
    end)
end)
