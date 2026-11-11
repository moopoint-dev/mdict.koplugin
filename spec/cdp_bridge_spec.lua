--[[
The DevTools bridge (renderers/cdp_bridge.lua) under the WebView renderer. Without a browser,
the parts that need none; with MDICT_CHROMIUM naming a Chromium binary, the whole path:
document, resources asked for on demand, fonts, ops and page captures.
]]
local helper = require("spec.helper")
local ffi = require("ffi")
local json = require("mdict/json")
local Bridge = require("renderers/cdp_bridge")
local Cdp = require("renderers/cdp_pipe")
local Png = require("renderers/png")
local WebRenderer = require("renderers/webview")

local function write(path, data)
    local f = assert(io.open(path, "wb"))
    f:write(data)
    f:close()
end

-- A client that records what is sent and answers from a script.
local function fake_cdp(answers)
    local c = { sent = {}, messages = {}, next_id = 0 }
    function c:send(method, params, session)
        self.next_id = self.next_id + 1
        self.sent[#self.sent + 1] = { id = self.next_id, method = method, params = params, session = session }
        local a = answers[method]
        if a then self.messages[#self.messages + 1] = { id = self.next_id, result = a(params) } end
        return self.next_id
    end
    function c:sendRaw(method, params_json, session)
        return self:send(method, json.decode(params_json), session)
    end
    function c:call(method, params, session)
        local id = self:send(method, params, session)
        for i, m in ipairs(self.messages) do
            if m.id == id then
                table.remove(self.messages, i)
                return m.result
            end
        end
        return nil, method .. " failed"
    end
    function c:_pump() return false end
    function c:exitStatus() return nil end
    function c:close() self.closed = true return "closed", "exited 0" end
    return c
end

describe("DevTools bridge", function()
    it("serves the document, a dictionary's files and resources asked for", function()
        local root = helper.tmpdir("cdp-root")
        write(root .. "/style.css", "p{color:red}")
        write(root .. "/font.ttf", "FONT")
        local cdp = fake_cdp({
            ["Target.getTargets"] = function() return { targetInfos = { { type = "page", targetId = "T1" } } } end,
            ["Target.attachToTarget"] = function() return { sessionId = "S1" } end,
            ["Page.enable"] = function() return {} end,
            ["Runtime.enable"] = function() return {} end,
            ["Runtime.addBinding"] = function() return {} end,
            ["Page.addScriptToEvaluateOnNewDocument"] = function() return {} end,
            -- like Chromium 75 on a Kindle: no Fetch, only the older interception
            ["Network.enable"] = function() return {} end,
            ["Network.setRequestInterception"] = function() return {} end,
            ["Emulation.setDeviceMetricsOverride"] = function() return {} end,
            ["Page.navigate"] = function() return { frameId = "T1" } end,
        })
        local b = assert(Bridge.new({ cdp = cdp, dpr = 2, decode = function() return true end }))
        b:open(1, 1000, 1100)
        assert.equal('{"ev":"opened","slot":1}', b:poll(0))
        local metrics
        for _, s in ipairs(cdp.sent) do if s.method == "Emulation.setDeviceMetricsOverride" then metrics = s.params end end
        assert.same({ width = 500, height = 550, deviceScaleFactor = 2, mobile = false }, metrics)
        b:load(1, "https://d1.mdict.local/", "<p>doc</p>", root, json.encode({ ["f1.ttf"] = root .. "/font.ttf" }))
        local function request(id, url, rtype, nav)
            cdp.messages[#cdp.messages + 1] = { method = "Network.requestIntercepted", sessionId = "S1", params = {
                interceptionId = id, request = { url = url }, resourceType = rtype, frameId = "T1",
                isNavigationRequest = nav } }
            b:poll(0)
            local last = cdp.sent[#cdp.sent]
            assert.equal(id, last.params.interceptionId)
            if last.params.errorReason then return last.params.errorReason end
            return require("mdict/base64").decode(last.params.rawResponse)
        end
        local doc = request("i1", "https://d1.mdict.local/__pager__.html", "Document", true)
        assert.truthy(doc:find("^HTTP/1.1 200 OK\r\nContent%-Type: text/html; charset=utf%-8\r\n"))
        assert.truthy(doc:find("\r\n\r\n<p>doc</p>$"))
        assert.truthy(request("i2", "https://d1.mdict.local/style.css", "Stylesheet"):find("\r\n\r\np{color:red}$"))
        assert.truthy(request("i3", "https://d1.mdict.local/__file__/f1.ttf", "Font"):find("font/ttf.*\r\n\r\nFONT$"))
        assert.truthy(request("i4", "https://elsewhere.example/x.png", "Image"):find("^HTTP/1.1 404"))
        assert.equal("Aborted", request("i5", "https://d1.mdict.local/other.html", "Document", true))
        -- a resource not extracted yet: Lua is asked for it
        cdp.messages[#cdp.messages + 1] = { method = "Network.requestIntercepted", sessionId = "S1", params = {
            interceptionId = "i6", request = { url = "https://d1.mdict.local/img/a%20b.png" }, resourceType = "Image",
            frameId = "T1" } }
        local need = json.decode(b:poll(0))
        assert.same({ ev = "need", slot = 1, rid = 1, path = "img/a b.png" }, need)
        write(root .. "/extracted.png", "PNGDATA")
        b:provide(1, root .. "/extracted.png")
        local last = cdp.sent[#cdp.sent]
        assert.equal("i6", last.params.interceptionId)
        assert.truthy(require("mdict/base64").decode(last.params.rawResponse):find("image/png.*\r\n\r\nPNGDATA$"))
        -- the document loaded, an op's result
        cdp.messages[#cdp.messages + 1] = { method = "Page.loadEventFired", sessionId = "S1", params = {} }
        assert.equal('{"ev":"loaded","slot":1}', b:poll(0))
        b:call(1, 7, "ping", "{}")
        local eval = cdp.sent[#cdp.sent]
        assert.equal('KOBridge._args[7]="{}";MDict["ping"](7)', eval.params.expression)
        cdp.messages[#cdp.messages + 1] = { method = "Runtime.bindingCalled", sessionId = "S1", params = {
            name = "__koDone", payload = '7\n{"ok":true,"w":500}' } }
        assert.equal('{"ev":"done","slot":1,"id":7,"r":{"ok":true,"w":500}}', b:poll(0))
        b:free()
        assert.is_true(cdp.closed)
    end)

    it("takes pages from the screencast, telling frames apart by the strip below the page", function()
        local b64 = require("mdict/base64").encode
        local cdp = fake_cdp({
            ["Target.getTargets"] = function() return { targetInfos = { { type = "page", targetId = "T1" } } } end,
            ["Target.attachToTarget"] = function() return { sessionId = "S1" } end,
            ["Page.enable"] = function() return {} end,
            ["Runtime.enable"] = function() return {} end,
            ["Runtime.addBinding"] = function() return {} end,
            ["Page.addScriptToEvaluateOnNewDocument"] = function() return {} end,
            ["Network.enable"] = function() return {} end,
            ["Network.setRequestInterception"] = function() return {} end,
            ["Emulation.setDeviceMetricsOverride"] = function() return {} end,
            ["Page.captureScreenshot"] = function() return { data = b64("grey:0") } end,
        })
        local decoded = {}
        local b = assert(Bridge.new({ cdp = cdp, dpr = 2, screencast = { format = "jpeg", quality = 92 },
            cast_wait = 0.2, capture_wait = 1,
            decode = function(data, _, w, h, extra)
                decoded[#decoded + 1] = { data = data, w = w, h = h, extra = extra }
                return true, tonumber(data:match("^grey:(%d+)$"))
            end }))
        b:open(1, 1000, 1100)
        assert.equal('{"ev":"opened","slot":1}', b:poll(0))
        local sent = {}
        for _, m in ipairs(cdp.sent) do sent[m.method] = m.params end
        -- 8 CSS pixels (16 device pixels) below the page, which the pager leaves out
        assert.same({ width = 500, height = 558, deviceScaleFactor = 2, mobile = false },
            sent["Emulation.setDeviceMetricsOverride"])
        assert.truthy(sent["Page.addScriptToEvaluateOnNewDocument"].source:find("KOBridge.reserve=8;", 1, true))
        assert.equal(1 + 2 + 0.2, b.capture_timeout)
        local function frame(data)
            cdp.messages[#cdp.messages + 1] = { method = "Page.screencastFrame", sessionId = "S1",
                params = { data = b64(data), sessionId = #cdp.sent, metadata = {} } }
            return b:poll(0)
        end
        local function last(method)
            for i = #cdp.sent, 1, -1 do if cdp.sent[i].method == method then return cdp.sent[i] end end
        end
        b:capture(1, 5, nil, 1000, 1100)
        assert.equal("KOBridge.mark(36)", last("Runtime.evaluate").params.expression)
        assert.same({ format = "jpeg", quality = 92 }, last("Page.startScreencast").params)
        -- a frame drawn before the strip changed is skipped (and acknowledged)
        assert.is_nil(frame("grey:252"))
        assert.equal("Page.screencastFrameAck", cdp.sent[#cdp.sent].method)
        local ev = json.decode(frame("grey:38"))
        assert.same({ "captured", 5, true, "screencast", 2 }, { ev.ev, ev.id, ev.ok, ev.via, ev.frames })
        assert.same({ w = 1000, h = 1100, extra = 16 }, { w = decoded[2].w, h = decoded[2].h, extra = decoded[2].extra })
        assert.truthy(last("Page.stopScreencast"))
        assert.is_nil(frame("grey:38")) -- late frames go nowhere
        -- the next capture wants the next grey; without a frame, a screenshot is taken
        b:capture(1, 6, nil, 1000, 1100)
        assert.equal("KOBridge.mark(72)", last("Runtime.evaluate").params.expression)
        assert.is_nil(b:poll(0))
        assert.is_nil(last("Page.captureScreenshot"))
        os.execute("sleep 0.3")
        assert.is_nil(b:poll(0)) -- asks for the screenshot
        ev = json.decode(b:poll(0))
        assert.same({ "captured", 6, true, "screenshot" }, { ev.ev, ev.id, ev.ok, ev.via })
        b:free()
    end)

    it("runs its watch while waiting, frees memory and stops the browser when the watch says so", function()
        local cdp = fake_cdp({
            ["Target.getTargets"] = function() return { targetInfos = { { type = "page", targetId = "T1" } } } end,
            ["Target.attachToTarget"] = function() return { sessionId = "S1" } end,
            ["Page.enable"] = function() return {} end,
            ["Runtime.enable"] = function() return {} end,
            ["Runtime.addBinding"] = function() return {} end,
            ["Page.addScriptToEvaluateOnNewDocument"] = function() return {} end,
            ["Network.enable"] = function() return {} end,
            ["Network.setRequestInterception"] = function() return {} end,
            ["Emulation.setDeviceMetricsOverride"] = function() return {} end,
        })
        local verdict, runs, b = nil, 0, nil
        b = assert(Bridge.new({ cdp = cdp, dpr = 2, decode = function() return true end,
            watch = function(bridge)
                runs = runs + 1
                assert.equal(b, bridge)
                return verdict
            end }))
        b:open(1, 1000, 1100)
        assert.equal('{"ev":"opened","slot":1}', b:poll(0))
        local function count(method)
            local n = 0
            for _, m in ipairs(cdp.sent) do if m.method == method then n = n + 1 end end
            return n
        end
        -- asks the page to free memory, at most once in a while
        assert.is_true(b:releaseMemory())
        assert.is_false(b:releaseMemory())
        assert.equal(1, count("Memory.simulatePressureNotification"))
        assert.same({ level = "critical" }, cdp.sent[#cdp.sent].params)
        assert.equal("S1", cdp.sent[#cdp.sent].session)
        -- once a second while polling, and whenever asked
        local before = runs
        assert.is_nil(b:poll(0))
        assert.is_nil(b:checkNow())
        assert.equal(before + 1, runs)
        assert.is_true(b:alive())
        verdict = "the Kindle is low on memory (20 MB free)"
        assert.equal(verdict, b:checkNow())
        assert.is_false(b:alive())
        assert.equal(verdict, b.ended)
        local ev = json.decode(b:poll(100))
        assert.same({ "error", verdict, true }, { ev.ev, ev.msg, ev.fatal })
        assert.equal(verdict, b:checkNow()) -- and stays stopped
        b:free()
        assert.is_true(cdp.closed)
    end)

    it("decodes PNG screenshots", function()
        -- 2x2 RGBA, each row with filter 1 (each byte adds the one a pixel to its left)
        local rgba = "\1" .. "\255\0\0\255" .. "\0\255\0\255" .. "\1" .. "\0\0\255\255" .. "\255\255\255\128"
        local tmp = helper.tmpdir("png") .. "/raw"
        write(tmp, rgba)
        local f = io.popen("python3 -c \"import sys,zlib,struct;d=open(sys.argv[1],'rb').read();"
            .. "c=lambda t,b:struct.pack('>I',len(b))+t+b+struct.pack('>I',zlib.crc32(t+b));"
            .. "sys.stdout.buffer.write(b'\\x89PNG\\r\\n\\x1a\\n'+c(b'IHDR',struct.pack('>IIBBBBB',2,2,8,6,0,0,0))"
            .. "+c(b'IDAT',zlib.compress(d))+c(b'IEND',b''))\" " .. tmp)
        local png = f:read("*a")
        f:close()
        local buf = ffi.new("uint8_t[16]")
        assert.is_true(Png.decodeInto(png, buf, 2, 2))
        local got = {}
        for i = 0, 15 do got[#got + 1] = buf[i] end
        -- filter 1 adds the pixel to the left
        assert.same({ 255, 0, 0, 255, 255, 255, 0, 510 % 256, 0, 0, 255, 255, 255, 255, 510 % 256, 383 % 256 }, got)
        -- a pixel off (a fractional pixel ratio): what overlaps, white for the rest
        local wide = ffi.new("uint8_t[24]")
        assert.is_true(Png.decodeInto(png, wide, 3, 2))
        assert.same({ 255, 0, 0, 255, 255, 255, 0, 254, 255, 255, 255, 255 },
            { wide[0], wide[1], wide[2], wide[3], wide[4], wide[5], wide[6], wide[7], wide[8], wide[9], wide[10], wide[11] })
        local _, err = Png.decodeInto(png, buf, 6, 2)
        assert.equal("PNG is 2x2, not 6x2", err)
        -- a strip below the page: left out of it, its grey returned
        local grey = "\0" .. "\10\20" .. "\0" .. "\30\40" .. "\0" .. "\100\102"
        write(tmp, grey)
        f = io.popen("python3 -c \"import sys,zlib,struct;d=open(sys.argv[1],'rb').read();"
            .. "c=lambda t,b:struct.pack('>I',len(b))+t+b+struct.pack('>I',zlib.crc32(t+b));"
            .. "sys.stdout.buffer.write(b'\\x89PNG\\r\\n\\x1a\\n'+c(b'IHDR',struct.pack('>IIBBBBB',2,3,8,0,0,0,0))"
            .. "+c(b'IDAT',zlib.compress(d))+c(b'IEND',b''))\" " .. tmp)
        png = f:read("*a")
        f:close()
        local ok, level = Png.decodeInto(png, buf, 2, 2, 1)
        assert.is_true(ok)
        assert.equal(101, level)
        assert.same({ 10, 10, 10, 255, 20, 30, 40, 255 }, { buf[0], buf[1], buf[2], buf[3], buf[4], buf[8], buf[12], buf[15] })
        _, err = Png.decodeInto(png, buf, 2, 2, 5)
        assert.equal("PNG is 2x3, not 2x7", err)
    end)

    local chromium = os.getenv("MDICT_CHROMIUM")
    local real = chromium and it or pending
    real("lays out and draws entries in a real browser", function()
        local work = helper.tmpdir("cdp-real")
        local root = work .. "/res"
        os.execute("mkdir -p '" .. root .. "/img' '" .. work .. "/profile'")
        write(root .. "/d.css", ".big{font-size:40px;color:#000} img{width:20px;height:20px}")
        write(work .. "/later.svg", "<svg xmlns='http://www.w3.org/2000/svg' width='20' height='20'>"
            .. "<rect width='20' height='20' fill='black'/></svg>")
        local cdp = assert(Cdp.spawn({ exe = chromium,
            args = { "--headless=new", "--no-sandbox", "--remote-debugging-pipe", "--hide-scrollbars",
                     "--user-data-dir=" .. work .. "/profile", "about:blank" },
            env = { "HOME=" .. work .. "/profile", "PATH=/usr/bin:/bin" } }))
        local bridge = assert(Bridge.new({ cdp = cdp, dpr = 2, decode = Png.decodeInto, max_slots = 2 }))
        local asked = {}
        local wr = WebRenderer.new({ bridge = bridge, resolve = function(_, path)
            asked[#asked + 1] = path
            return path == "img/later.svg" and work .. "/later.svg" or nil
        end })
        local slot, err = wr:document({ dict_id = "d1", cache_root = root, stylesheets = { "d.css" } }, 600, 400)
        assert.truthy(slot, err)
        -- what the browser can read, from the pager (see Manager.documentSheets)
        assert.is_true(wr.has_round)
        assert.is_true(wr.has_selectors)
        local r = assert(wr:setEntry(slot, { html = '<p class="big">' .. string.rep("Word ", 200)
            .. '</p><img src="img/later.svg"><img src="img/missing.png">', writing = "horizontal" }))
        assert.truthy(r.pages > 1)
        assert.same({ "img/later.svg", "img/missing.png" }, asked)
        local buf = ffi.new("uint8_t[?]", 600 * 400 * 4)
        local ok, perr, timing = wr:renderPage(slot, 0, buf)
        assert.is_true(ok, perr)
        assert.equal("screenshot", timing.via)
        local dark = 0
        for i = 0, 600 * 400 - 1 do if buf[i * 4] < 100 then dark = dark + 1 end end
        assert.truthy(dark > 1000, "page 1 has text") -- black text on white
        assert.truthy(dark < 600 * 400 / 2)
        local links = assert(wr:links(slot))
        assert.equal("table", type(links))
        -- a second slot gets a page of its own
        local other = assert(wr:document({ dict_id = "d2", cache_root = root, stylesheets = {} }, 600, 400, { [slot.id] = true }))
        assert.are_not.equal(slot.id, other.id)
        wr:close()
        bridge:free()
        assert.truthy(cdp:exitStatus())
    end)

    real("takes pages from a real browser's screencast", function()
        local work = helper.tmpdir("cdp-cast")
        os.execute("mkdir -p '" .. work .. "/profile'")
        local cdp = assert(Cdp.spawn({ exe = chromium,
            args = { "--headless=new", "--no-sandbox", "--remote-debugging-pipe", "--hide-scrollbars",
                     "--user-data-dir=" .. work .. "/profile", "about:blank" },
            env = { "HOME=" .. work .. "/profile", "PATH=/usr/bin:/bin" } }))
        local bridge = assert(Bridge.new({ cdp = cdp, dpr = 1, decode = Png.decodeInto,
            screencast = { format = "png" } }))
        local wr = WebRenderer.new({ bridge = bridge })
        local slot = assert(wr:document({ dict_id = "d1", cache_root = work, stylesheets = {} }, 600, 400))
        local r = assert(wr:setEntry(slot, { html = '<p style="font-size:30px">' .. string.rep("Word ", 150)
            .. "</p><p>End</p>", writing = "horizontal" }))
        assert.truthy(r.pages > 1)
        local function draw(n)
            local buf = ffi.new("uint8_t[?]", 600 * 400 * 4)
            local ok, err, timing = wr:renderPage(slot, n, buf)
            assert.is_true(ok, err)
            assert.equal("screencast", timing.via)
            local dark, where = 0, 0
            for i = 0, 600 * 400 - 1 do
                if buf[i * 4] < 100 then dark, where = dark + 1, (where + i) % 1000003 end
            end
            return dark, dark .. ":" .. where
        end
        local dark, first = draw(0)
        local _, last = draw(r.pages - 1)
        assert.truthy(dark > 1000, "page 1 has text")
        assert.are_not.equal(first, last) -- the last page, not page 1 again
        assert.equal(first, select(2, draw(0)))
        wr:close()
        bridge:free()
        -- frames that are not the page's size (this Chromium's are in CSS pixels): screenshots
        os.execute("mkdir -p '" .. work .. "/profile2'")
        cdp = assert(Cdp.spawn({ exe = chromium,
            args = { "--headless=new", "--no-sandbox", "--remote-debugging-pipe", "--hide-scrollbars",
                     "--user-data-dir=" .. work .. "/profile2", "about:blank" },
            env = { "HOME=" .. work .. "/profile2", "PATH=/usr/bin:/bin" } }))
        bridge = assert(Bridge.new({ cdp = cdp, dpr = 1.5, decode = Png.decodeInto,
            screencast = { format = "png" } }))
        wr = WebRenderer.new({ bridge = bridge })
        slot = assert(wr:document({ dict_id = "d1", cache_root = work, stylesheets = {} }, 600, 401))
        assert(wr:setEntry(slot, { html = "<p>Word</p>", writing = "horizontal" }))
        local ok, err, timing = wr:renderPage(slot, 0, ffi.new("uint8_t[?]", 600 * 401 * 4))
        assert.is_true(ok, err)
        assert.equal("screenshot", timing.via)
        assert.is_nil(bridge.screencast)
        wr:close()
        bridge:free()
    end)

    real("reports a browser that ended", function()
        local work = helper.tmpdir("cdp-dead")
        local cdp = assert(Cdp.spawn({ exe = chromium,
            args = { "--headless=new", "--no-sandbox", "--remote-debugging-pipe", "--user-data-dir=" .. work, "about:blank" },
            env = { "HOME=" .. work, "PATH=/usr/bin:/bin" } }))
        local bridge = assert(Bridge.new({ cdp = cdp, decode = Png.decodeInto }))
        require("ffi").C.kill(cdp.pid, 9)
        local ev
        for _ = 1, 50 do
            ev = bridge:poll(100)
            if ev then break end
        end
        ev = json.decode(ev)
        assert.equal("error", ev.ev)
        assert.is_true(ev.fatal)
        assert.is_false(bridge:alive())
        bridge:free()
    end)
end)
