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
