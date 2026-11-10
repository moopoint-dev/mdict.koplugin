require("spec.helper")
local json = require("mdict/json")
local WebRenderer = require("renderers/webview")

-- A scripted bridge: answers ops like the pager would, and asks for one resource during setEntry.
-- With b.lag = n, each event shows up only after n more polls (an answer that takes a while).
local function fake_bridge()
    local b = { queue = {}, provided = {}, calls = {}, polls = 0 }
    local function push(ev) b.queue[#b.queue + 1] = { raw = json.encode(ev), ready = b.polls + (b.lag or 0) } end
    function b.session(_, fn) return fn() end
    function b.open(_, slot) push({ ev = "opened", slot = slot }) end
    function b.load(_, slot, base) b.base = base; push({ ev = "loaded", slot = slot, renewIn = b.renew_in }) end
    function b.call(_, slot, id, op, args)
        b.calls[#b.calls + 1] = op
        local a = json.decode(args)
        if op == "ping" then
            push({ ev = "done", slot = slot, id = id, r = { w = 575, h = 550, dpr = 2 } })
        elseif op == "setEntry" then
            b.entry_args = args
            push({ ev = "done", slot = slot, id = 999, r = { stale = true } })
            push({ ev = "need", slot = slot, rid = 5, path = "img/a.png" })
            b.pending = { slot = slot, id = id, html = a.html }
        elseif op == "showPage" then
            push({ ev = "done", slot = slot, id = id, r = { page = a.page } })
        else
            push({ ev = "done", slot = slot, id = id, r = { error = "unknown op" } })
        end
    end
    function b.provide(_, rid, path)
        b.provided[rid] = path
        local p = b.pending
        push({ ev = "done", slot = p.slot, id = p.id, r = { pages = 3, vertical = false, anchorPage = -1 } })
    end
    function b.capture(_, slot, id, ptr)
        ptr[0] = 42
        push({ ev = "captured", slot = slot, id = id, ok = true, renew = b.renew })
    end
    function b.poll()
        b.polls = b.polls + 1
        local e = b.queue[1]
        if e and e.ready <= b.polls then
            table.remove(b.queue, 1)
            return e.raw
        end
    end
    function b.closeAll() end
    return b
end

describe("webview renderer", function()
    it("loads a document, serves resources and renders pages", function()
        local bridge = fake_bridge()
        local wr = WebRenderer.new({ bridge = bridge,
            resolve = function(dict, path) return "/cache/" .. dict .. "/" .. path end })
        local slot = assert(wr:document({ dict_id = "dict1", cache_root = "/cache/dict1", stylesheets = {} }, 1150, 1100))
        assert.equal("https://dict1.mdict.local/", bridge.base)
        local r = assert(wr:setEntry(slot, { html = "<p>x</p>" }))
        assert.equal(3, r.pages)
        -- lists go to the pager as JSON arrays, even when empty
        assert.truthy(bridge.entry_args:find('"skipScripts":[]', 1, true))
        assert.truthy(bridge.entry_args:find('"clicks":[]', 1, true))
        assert.equal("/cache/dict1/img/a.png", bridge.provided[5])
        local buf = require("ffi").new("uint8_t[4]")
        assert.is_true(wr:renderPage(slot, 1, buf))
        assert.equal(42, buf[0])
        local _, err = wr:op(slot.id, "nope")
        assert.equal("unknown op", err)
    end)

    it("reuses a loaded document for the same dictionary", function()
        local bridge = fake_bridge()
        local wr = WebRenderer.new({ bridge = bridge })
        local a = assert(wr:document({ dict_id = "a", cache_root = "/c", stylesheets = { "s.css" } }, 1150, 1100))
        local loads = 0
        local load = bridge.load
        bridge.load = function(...) loads = loads + 1; return load(...) end
        local b = assert(wr:document({ dict_id = "a", cache_root = "/c", stylesheets = { "s.css" } }, 1150, 1100))
        assert.equal(a, b)
        assert.equal(0, loads)
        local c = assert(wr:document({ dict_id = "b", cache_root = "/c", stylesheets = {} }, 1150, 1100))
        assert.are_not.equal(a.id, c.id)
        assert.equal(1, loads)
        assert(wr:document({ dict_id = "c", cache_root = "/c", stylesheets = {} }, 1150, 1100))
        assert.equal(2, loads)
        -- a fourth dictionary evicts the least recently used slot
        local d = assert(wr:document({ dict_id = "d", cache_root = "/c", stylesheets = {} }, 1150, 1100))
        assert.equal(3, loads)
        assert.equal(3, #wr.slots)
        assert.equal(a.id, d.id)
        -- unless told to leave it alone
        local e = assert(wr:document({ dict_id = "e", cache_root = "/c", stylesheets = {} }, 1150, 1100,
            { [c.id] = true }))
        assert.are_not.equal(c.id, e.id)
        assert.equal(4, loads)
        -- a WebView that captured slowly asks for its document again (to load it into a new one)
        bridge.renew = true
        assert.is_true(wr:renderPage(e, 0, require("ffi").new("uint8_t[4]")))
        bridge.renew = nil
        assert.equal(e, assert(wr:document({ dict_id = "e", cache_root = "/c", stylesheets = {} }, 1150, 1100)))
        assert.equal(5, loads)
        assert(wr:document({ dict_id = "e", cache_root = "/c", stylesheets = {} }, 1150, 1100))
        assert.equal(5, loads)
    end)

    it("renews an old WebView that keeps its document", function()
        local bridge = fake_bridge()
        local wr = WebRenderer.new({ bridge = bridge })
        local doc = { dict_id = "a", cache_root = "/c", stylesheets = {} }
        bridge.renew_in = 60000
        local a = assert(wr:document(doc, 1150, 1100))
        local loads = 0
        local load = bridge.load
        bridge.load = function(...) loads = loads + 1; return load(...) end
        assert.equal(a, assert(wr:document(doc, 1150, 1100)))
        assert.equal(0, loads)
        a.renew_at = a.renew_at - 61 -- a minute later
        assert.equal(a, assert(wr:document(doc, 1150, 1100)))
        assert.equal(1, loads)
        assert.is_true(a.renew_at > require("mdict/clock")() + 59)
        assert(wr:document(doc, 1150, 1100))
        assert.equal(1, loads)
    end)

    -- a scheduler run by hand: run() does one round of the scheduled functions
    local function scheduler()
        local sch = { tasks = {} }
        sch.schedule = function(_, fn) sch.tasks[#sch.tasks + 1] = fn end
        sch.unschedule = function(fn)
            for i = #sch.tasks, 1, -1 do if sch.tasks[i] == fn then table.remove(sch.tasks, i) end end
        end
        sch.run = function()
            local t = sch.tasks
            sch.tasks = {}
            for _, fn in ipairs(t) do fn() end
            return #t
        end
        return sch
    end

    local function renderer(bridge, sch)
        return WebRenderer.new({ bridge = bridge, schedule = sch.schedule, unschedule = sch.unschedule,
            resolve = function(dict, path) return "/cache/" .. dict .. "/" .. path end })
    end

    local doc_a = { dict_id = "a", cache_root = "/c", stylesheets = {} }
    local doc_b = { dict_id = "b", cache_root = "/c", stylesheets = {} }

    it("runs background jobs a step at a time while other work goes on", function()
        local bridge, sch = fake_bridge(), scheduler()
        bridge.lag = 3
        local wr = renderer(bridge, sch)
        local shown = assert(wr:document(doc_a, 1150, 1100))
        local done
        local job = wr:startJob(function()
            local slot = assert(wr:document(doc_b, 1150, 1100, { [shown.id] = true }))
            local r = assert(wr:setEntry(slot, { html = "<p>b</p>" }))
            return { slot = slot, pages = r.pages }
        end, function(j) done = j end)
        assert.is_nil(done)
        -- the job yields while it waits; a blocking op on the shown slot still works in between
        sch.run()
        sch.run()
        assert.is_nil(done)
        local r = assert(wr:op(shown.id, "showPage", { page = 0 }))
        assert.equal(0, r.page)
        local rounds = 0
        while not done and rounds < 200 do
            sch.run()
            rounds = rounds + 1
        end
        assert.is_true(rounds > 2)
        assert.is_true(done.ok)
        assert.equal(job, done)
        assert.are_not.equal(shown.id, done.result.slot.id)
        assert.equal(3, done.result.pages)
        assert.equal("/cache/b/img/a.png", bridge.provided[5])
        assert.is_nil(done.result.slot.job)
        assert.equal(0, #sch.tasks)
    end)

    it("finishes a job at once when its result is wanted, and stops a cancelled one", function()
        local bridge, sch = fake_bridge(), scheduler()
        bridge.lag = 2
        local wr = renderer(bridge, sch)
        local job = wr:startJob(function()
            local slot = assert(wr:document(doc_b, 1150, 1100))
            return assert(wr:setEntry(slot, { html = "<p>b</p>" })).pages
        end)
        sch.run()
        assert.is_falsy(job.done)
        wr:finishJob(job)
        assert.is_true(job.done)
        assert.equal(3, job.result)
        assert.equal(0, #sch.tasks)

        local ended
        local cancelled = wr:startJob(function()
            local slot = assert(wr:document(doc_a, 1150, 1100))
            return wr:setEntry(slot, { html = "<p>a</p>" })
        end, function(j) ended = j end)
        sch.run()
        wr:cancelJob(cancelled)
        for _ = 1, 50 do if ended then break end sch.run() end
        assert.is_false(ended.ok)
        assert.equal(WebRenderer.CANCELLED, ended.err)
        -- nothing it asked for is left pending
        assert.equal(0, #bridge.queue)
    end)

    it("keeps a slot a job uses for that job", function()
        local bridge, sch = fake_bridge(), scheduler()
        bridge.lag = 2
        local wr = renderer(bridge, sch)
        local held
        local job = wr:startJob(function()
            held = assert(wr:document(doc_b, 1150, 1100))
            return wr:setEntry(held, { html = "<p>b</p>" })
        end)
        while not held do sch.run() end
        assert.is_falsy(job.done)
        assert.equal(job, held.job)
        -- the same document, wanted meanwhile, goes into another slot
        local other = assert(wr:document(doc_b, 1150, 1100))
        assert.are_not.equal(held.id, other.id)
        wr:finishJob(job)
        assert.is_nil(held.job)
    end)

    it("times out when the backend never answers", function()
        local bridge = fake_bridge()
        bridge.call = function() end
        local wr = WebRenderer.new({ bridge = bridge })
        local _, err = wr:op(1, "ping", {}, 0.05)
        assert.equal("timeout", err)
    end)

    it("wakes its caller once, outside the bridge's session, while waiting", function()
        local bridge = fake_bridge()
        bridge.lag = 3
        local in_session = false
        bridge.session = function(_, fn)
            in_session = true
            local a, b, c = fn()
            in_session = false
            return a, b, c
        end
        local due, woke = 0, {}
        local wr = WebRenderer.new({ bridge = bridge,
            wake_at = function() return due end,
            on_wake = function() woke[#woke + 1] = in_session; due = nil end })
        local r = assert(wr:op(1, "ping", {}, 1))
        assert.equal(575, r.w)
        assert.same({ false }, woke)
        -- without on_wake, wake_at is not asked
        local plain = WebRenderer.new({ bridge = fake_bridge(), wake_at = function() error("asked") end })
        assert.truthy(plain:op(1, "ping", {}, 1))
    end)

    it("does not count the time spent extracting resources toward the timeout", function()
        local bridge = fake_bridge()
        local now = require("mdict/clock")
        -- each extraction takes 30 ms, and the op asks for five before it is done
        local wr = WebRenderer.new({ bridge = bridge, resolve = function(_, path)
            local t = now() + 0.03
            while now() < t do end
            return "/c/" .. path
        end })
        bridge.call = function(_, slot, id)
            for rid = 1, 5 do
                bridge.queue[#bridge.queue + 1] = { raw = json.encode({ ev = "need", slot = slot, rid = rid,
                    path = "f" .. rid .. ".otf" }), ready = 0 }
            end
            bridge.queue[#bridge.queue + 1] = { raw = json.encode({ ev = "done", slot = slot, id = id, r = {} }),
                ready = 0 }
        end
        bridge.provide = function(_, rid, path) bridge.provided[rid] = path end
        wr.slots[1] = { id = 1, dict_id = "d" }
        local r, err = wr:op(1, "setEntry", {}, 0.1)
        assert.is_nil(err)
        assert.truthy(r)
        assert.equal("/c/f5.otf", bridge.provided[5])
        assert.is_true(wr.serving >= 0.15)
    end)
end)
