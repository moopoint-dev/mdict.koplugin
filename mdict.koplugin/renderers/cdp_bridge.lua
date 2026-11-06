--[[--
Renderer bridge over a Chromium driven through its DevTools pipe (renderers/cdp_pipe.lua):
the Kindle's own browser, or a desktop Chromium. It speaks the Android bridge's interface
(see renderers/webview.lua), as tools/chromium-bridge/bridge.js does with Playwright, but
from Lua alone.

Each slot is a page target. The page's requests are intercepted and answered from the
dictionary's files (Fetch domain, or the older Network interception when the browser was
built without the network service, as Chromium 75 on Kindles is). Pages are decoded into the
page memory the widget hands over.

Pages come from the page's screencast when the bridge is given screencast parameters: a frame
of what the browser has drawn arrives a fraction of a second after a change, where a
screenshot makes the browser draw the page again (seconds on a Kindle). The viewport is a few
pixels taller than the page, and the page colours that strip below it with a different grey
for each capture, so a frame drawn before the change is told apart and skipped. When no frame
comes, a screenshot is taken instead.

A watch (opts.watch) can be run every second while the bridge waits for the browser, and
before each entry: given the bridge, it returns nothing, or why the browser must stop now
(the Kindle running out of memory), and the bridge then ends it rather than wait for the
kernel to.
]]

local json = require("mdict/json")
local base64 = require("mdict/base64")
local monotonic = require("mdict/clock")

local Bridge = {}
Bridge.__index = Bridge

Bridge.NEED_TIMEOUT = 4 -- seconds a request waits for a resource Lua extracts
Bridge.SETUP_TIMEOUT = 30
-- A screenshot that comes later is dropped: the renderer waits a little longer (capture_timeout),
-- so the page memory it handed over is never written after it gave up.
Bridge.CAPTURE_WAIT = 4
Bridge.CAST_WAIT = 3 -- seconds to wait for the screencast frame of a capture before taking a screenshot
Bridge.MARK_PX = 16 -- device pixels of the strip below the page that tells frames apart
Bridge.MARK_STEP = 36 -- grey levels between the strip's colours (36, 72 ... 252)
Bridge.WATCH_EVERY = 1 -- seconds between runs of the watch while waiting
Bridge.RELEASE_EVERY = 15 -- seconds at least between two requests to free memory

Bridge.TYPES = {
    css = "text/css", js = "text/javascript", png = "image/png", jpg = "image/jpeg", jpeg = "image/jpeg",
    svg = "image/svg+xml", otf = "font/otf", ttf = "font/ttf", ttc = "font/collection", woff = "font/woff",
    woff2 = "font/woff2", gif = "image/gif", webp = "image/webp", bmp = "image/bmp", html = "text/html",
    htm = "text/html", json = "application/json",
}

-- The page's bridge to Lua (as KOBridge on Android): arguments are put in place before an op
-- is called; results go back through the __koDone binding as "<id>\n<json>".
Bridge.KOBRIDGE = "window.KOBridge={_args:{},arg:function(id){var a=this._args[id];delete this._args[id];"
    .. "return a||'{}'},done:function(id,j){__koDone(id+'\\n'+j)},log:function(m){}};"

-- The strip below the page (KOBridge.reserve CSS pixels, which the pager leaves out of its
-- pages), in an element type that dictionaries' stylesheets do not style.
Bridge.MARK_JS = "KOBridge.mark=function(v){var m=document.getElementById('ko-mark');if(!m){"
    .. "m=document.createElement('ko-mark');m.id='ko-mark';document.documentElement.appendChild(m)}"
    .. "var s=m.style,c='rgb('+v+','+v+','+v+')',p={position:'fixed',display:'block',left:'0',bottom:'0',"
    .. "width:'100%',height:KOBridge.reserve+'px','z-index':'2147483647','pointer-events':'none',"
    .. "background:c,margin:'0',padding:'0',border:'0',transform:'none',opacity:'1'};"
    .. "for(var k in p)s.setProperty(k,p[k],'important')};"

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function url_decode(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

--- opts:
--   cdp: a started client (renderers/cdp_pipe), owned by the bridge from now on
--   dpr: device pixel ratio to lay pages out at (default 2)
--   max_slots: page targets to use; above 1, new ones are created (default 1)
--   capture: Page.captureScreenshot parameters (default PNG)
--   screencast: Page.startScreencast parameters, to take pages from the screencast (optional)
--   decode(data, ptr, w, h, extra): draws an encoded image into w*h RGBA at ptr; the image has
--     extra rows below the page (the strip), whose grey it returns: true, grey; or nil, err
--   on_free(cdp): called once the browser is closed (default: nothing)
--   capture_wait: seconds a screenshot may take (default CAPTURE_WAIT)
--   cast_wait: seconds to wait for a screencast frame first (default CAST_WAIT)
--   close_grace: seconds the browser gets to close before it is terminated (default 3)
--   load_timeout, op_timeout: seconds the renderer waits for a document and an op (its defaults)
--   log(...): debug messages (optional)
-- Returns the bridge, or nil and an error.
function Bridge.new(opts)
    local self = setmetatable({
        cdp = assert(opts.cdp, "cdp required"),
        dpr = opts.dpr or 2,
        max_slots = opts.max_slots or 1,
        capture_params = opts.capture or { format = "png" },
        decode = assert(opts.decode, "decode required"),
        on_free = opts.on_free,
        log = opts.log or function() end,
        capture_wait = opts.capture_wait or Bridge.CAPTURE_WAIT,
        screencast = opts.screencast,
        cast_wait = opts.cast_wait or Bridge.CAST_WAIT,
        close_grace = opts.close_grace or 3,
        watch = opts.watch,
        next_watch = 0,
        slots = {},
        sessions = {}, -- sessionId -> slot
        outbox = {},
        pending = {}, -- command id -> function(result, error)
        needs = {}, -- rid -> { slot, request, deadline }
        next_rid = 0,
        spare = {}, -- page targets not yet taken by a slot
    }, Bridge)
    -- the strip below the page, in CSS and device pixels
    self.mark_css = self.screencast and math.ceil(Bridge.MARK_PX / self.dpr) or 0
    self.mark_px = math.floor(self.mark_css * self.dpr + 0.5)
    self.capture_timeout = self.capture_wait + 2 + (self.screencast and self.cast_wait or 0)
    self.load_timeout, self.op_timeout = opts.load_timeout, opts.op_timeout
    local targets, err = self.cdp:call("Target.getTargets", nil, nil, Bridge.SETUP_TIMEOUT)
    if not targets then
        self:free()
        return nil, err
    end
    for _, t in ipairs(targets.targetInfos or {}) do
        if t.type == "page" then self.spare[#self.spare + 1] = t.targetId end
    end
    return self
end

function Bridge:_emit(ev)
    self.outbox[#self.outbox + 1] = type(ev) == "string" and ev or json.encode(ev)
end

-- Sends a command; on_reply(result, error) runs when its reply arrives.
function Bridge:_cmd(method, params, session, on_reply)
    local ok, id = pcall(self.cdp.send, self.cdp, method, params, session)
    if not ok then
        if on_reply then on_reply(nil, id) end
        return
    end
    if on_reply then self.pending[id] = on_reply end
end

-- Attaches a slot to a page target and prepares it (synchronously: done once per slot).
function Bridge:_setup(slot_id)
    local target = table.remove(self.spare, 1)
    local err
    if not target and self.max_slots < 2 then
        -- the browser's own page can come a while after its DevTools answer
        local used = {}
        for _, s in pairs(self.slots) do used[s.target] = true end
        local deadline = monotonic() + Bridge.SETUP_TIMEOUT
        while not target and monotonic() < deadline do
            local t = self.cdp:call("Target.getTargets", nil, nil, Bridge.SETUP_TIMEOUT)
            for _, ti in ipairs(t and t.targetInfos or {}) do
                if ti.type == "page" and not used[ti.targetId] then target = ti.targetId end
            end
            if not target and self.cdp:_pump(250) == nil then break end -- (nil: it ended)
        end
    end
    if not target then
        if self.max_slots < 2 then return nil, "no page" end
        local t
        -- a window of its own: a background tab draws no frames, so it could not be captured
        t, err = self.cdp:call("Target.createTarget", { url = "about:blank", newWindow = true }, nil,
            Bridge.SETUP_TIMEOUT)
        if not t then return nil, err end
        target = t.targetId
    end
    local att
    att, err = self.cdp:call("Target.attachToTarget", { targetId = target, flatten = true }, nil, Bridge.SETUP_TIMEOUT)
    if not att then return nil, err end
    local sid = att.sessionId
    local slot = { id = slot_id, target = target, session = sid, files = {}, host = "", root = "", doc = "" }
    for _, c in ipairs({
        { "Page.enable" }, { "Runtime.enable" },
        { "Runtime.addBinding", { name = "__koDone" } },
        { "Page.addScriptToEvaluateOnNewDocument", { source = Bridge.KOBRIDGE .. (self.mark_css > 0
            and string.format("KOBridge.reserve=%d;", self.mark_css) .. Bridge.MARK_JS or "") } },
    }) do
        local ok, e = self.cdp:call(c[1], c[2], sid, Bridge.SETUP_TIMEOUT)
        if not ok then return nil, e end
    end
    -- Fetch needs the network service; Chromium 75 on Kindles runs without it
    local ok = self.cdp:call("Fetch.enable", { patterns = { { urlPattern = "*" } } }, sid, Bridge.SETUP_TIMEOUT)
    if ok then
        slot.intercept = "fetch"
    else
        local e
        ok, e = self.cdp:call("Network.enable", {}, sid, Bridge.SETUP_TIMEOUT)
        if ok then
            ok, e = self.cdp:call("Network.setRequestInterception", { patterns = { { urlPattern = "*" } } }, sid,
                Bridge.SETUP_TIMEOUT)
        end
        if not ok then return nil, e end
        slot.intercept = "network"
    end
    self.slots[slot_id] = slot
    self.sessions[sid] = slot
    return slot
end

function Bridge:session(fn) return fn() end

function Bridge:open(slot_id, w, h)
    local slot = self.slots[slot_id]
    if not slot then
        local err
        slot, err = self:_setup(slot_id)
        if not slot then
            self:_emit({ ev = "error", slot = slot_id, msg = "open: " .. tostring(err) })
            return
        end
    end
    local dpr = self.dpr
    self:_cmd("Emulation.setDeviceMetricsOverride", {
        width = math.floor(w / dpr + 0.5), height = math.floor(h / dpr + 0.5) + self.mark_css,
        deviceScaleFactor = dpr, mobile = false,
    }, slot.session, function(_, err)
        if err then self:_emit({ ev = "error", slot = slot_id, msg = "open: " .. tostring(err) }) return end
        self:_emit({ ev = "opened", slot = slot_id })
    end)
end

function Bridge:load(slot_id, base, html, root, files_json)
    local slot = self.slots[slot_id]
    if not slot then
        self:_emit({ ev = "error", slot = slot_id, msg = "load: slot not open" })
        return
    end
    slot.host = base:match("^https://([^/]+)/") or ""
    slot.root, slot.doc = root or "", html
    slot.files = files_json and files_json ~= "" and json.decode(files_json) or {}
    slot.loading = true
    self:_cmd("Page.navigate", { url = base .. "__pager__.html" }, slot.session, function(r, err)
        err = err or (r and r.errorText)
        if err then
            slot.loading = false
            self:_emit({ ev = "error", slot = slot_id, msg = "load: " .. tostring(err) })
        end
    end)
end

function Bridge:call(slot_id, id, op, args)
    local slot = self.slots[slot_id]
    if not slot then
        self:_emit({ ev = "error", slot = slot_id, id = id, msg = "slot not open" })
        return
    end
    local expr = string.format("KOBridge._args[%d]=%s;MDict[%s](%d)", id, json.encode(args or "{}"),
        json.encode(op), id)
    self:_cmd("Runtime.evaluate", { expression = expr }, slot.session, function(r, err)
        if not err and r and r.exceptionDetails then
            local ex = r.exceptionDetails
            err = ex.exception and ex.exception.description or ex.text
        end
        if err then self:_emit({ ev = "error", slot = slot_id, id = id, msg = op .. ": " .. tostring(err) }) end
    end)
end

-- Answers an intercepted request with a file's contents (data), 404 without them, or fails
-- it (req.abort).
function Bridge:_answer(slot, req, data, ctype)
    local status = data and "200" or "404"
    if slot.intercept == "fetch" then
        if req.abort then
            self:_cmd("Fetch.failRequest", { requestId = req.id, errorReason = "Aborted" }, slot.session)
            return
        end
        -- built by hand: a body can be megabytes (fonts) that need no JSON escaping
        local params = '{"requestId":' .. json.encode(req.id) .. ',"responseCode":' .. status
            .. ',"responseHeaders":[{"name":"Content-Type","value":' .. json.encode(ctype or "text/plain") .. '},'
            .. '{"name":"Access-Control-Allow-Origin","value":"*"}],"body":"' .. base64.encode(data or "") .. '"}'
        self:_raw("Fetch.fulfillRequest", params, slot.session)
    else
        if req.abort then
            self:_cmd("Network.continueInterceptedRequest", { interceptionId = req.id, errorReason = "Aborted" },
                slot.session)
            return
        end
        data = data or ""
        local head = "HTTP/1.1 " .. (status == "200" and "200 OK" or "404 Not Found") .. "\r\nContent-Type: "
            .. (ctype or "text/plain") .. "\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: " .. #data .. "\r\n\r\n"
        local params = '{"interceptionId":' .. json.encode(req.id) .. ',"rawResponse":"'
            .. base64.encode(head .. data) .. '"}'
        self:_raw("Network.continueInterceptedRequest", params, slot.session)
    end
end

function Bridge:_raw(method, params_json, session)
    local ok, err = pcall(self.cdp.sendRaw, self.cdp, method, params_json, session)
    if not ok then self.log("send failed", method, err) end
end

local function content_type(path)
    local ext = (path:match("%.(%w+)$") or ""):lower()
    local t = Bridge.TYPES[ext] or "application/octet-stream"
    if t:match("^text/") then t = t .. "; charset=utf-8" end
    return t
end

function Bridge:_serveFile(slot, req, file)
    local data = file and file ~= "" and read_file(file)
    self:_answer(slot, req, data or nil, data and content_type(file))
end

-- An intercepted request: the pager document, a file the document names, or a dictionary
-- resource (extracted on demand: Lua is asked for it with a "need" event).
function Bridge:_request(slot, req)
    local scheme, host, path = req.url:match("^(%a+)://([^/]*)(/?[^?#]*)")
    if scheme ~= "https" or host ~= slot.host then return self:_answer(slot, req, nil) end
    path = url_decode(path)
    if path == "/__pager__.html" then return self:_answer(slot, req, slot.doc, "text/html; charset=utf-8") end
    if path == "/favicon.ico" then return self:_answer(slot, req, nil) end -- the browser's own, not the entry's
    -- like the Android bridge: entries never navigate the pager away
    if req.navigation then
        req.abort = true
        return self:_answer(slot, req, nil)
    end
    if path:sub(1, 10) == "/__file__/" then return self:_serveFile(slot, req, slot.files[path:sub(11)]) end
    local rel = path:gsub("^/+", "")
    if rel == "" or rel:find("..", 1, true) then return self:_answer(slot, req, nil) end
    local file = slot.root ~= "" and (slot.root .. "/" .. rel) or nil
    local f = file and io.open(file, "rb")
    if f then
        local data = f:read("*a")
        f:close()
        return self:_answer(slot, req, data, content_type(file))
    end
    self.next_rid = self.next_rid + 1
    local rid = self.next_rid
    self.needs[rid] = { slot = slot, req = req, deadline = monotonic() + Bridge.NEED_TIMEOUT }
    self:_emit({ ev = "need", slot = slot.id, rid = rid, path = rel })
end

function Bridge:provide(rid, path)
    local n = self.needs[rid]
    if not n then return end
    self.needs[rid] = nil
    self:_serveFile(n.slot, n.req, path)
end

function Bridge:capture(slot_id, id, ptr, w, h)
    local slot = self.slots[slot_id]
    if not slot then
        self:_emit({ ev = "captured", slot = slot_id, id = id, ok = false })
        return
    end
    local cap = { id = id, ptr = ptr, w = w, h = h, t0 = monotonic(), frames = 0 }
    if not self.screencast then return self:_screenshot(slot, cap) end
    if slot.cap then self:_endCast(slot, false) end
    -- a grey the strip did not have for the last captures
    slot.mark = (slot.mark or 0) % math.floor(255 / Bridge.MARK_STEP) + 1
    cap.level = slot.mark * Bridge.MARK_STEP
    cap.deadline = cap.t0 + self.cast_wait
    slot.cap = cap
    self:_cmd("Runtime.evaluate", { expression = "KOBridge.mark(" .. cap.level .. ")" }, slot.session, function(r, err)
        if not err and r and r.exceptionDetails then err = "the page has no strip" end
        if err and slot.cap == cap then
            self.log("screencast capture failed:", tostring(err))
            self:_endCast(slot, true)
        end
    end)
    if not slot.casting then
        slot.casting = true
        self:_cmd("Page.startScreencast", self.screencast, slot.session, function(_, err)
            if not err then return end
            self.log("no screencast:", tostring(err))
            self.screencast = nil -- screenshots from now on (the strip stays)
            slot.casting = false
            if slot.cap then self:_endCast(slot, true) end
        end)
    end
end

-- A screenshot of the slot's page (cap: the capture). One that comes too late is dropped.
function Bridge:_screenshot(slot, cap)
    local t0 = monotonic()
    self:_cmd("Page.captureScreenshot", self.capture_params, slot.session, function(r, err)
        local t1 = monotonic()
        local ok = false
        if t1 - t0 > self.capture_wait then
            r, err = nil, string.format("screenshot came after %.1f s", t1 - t0)
        end
        if r and r.data then
            local data = base64.decode(r.data)
            local dok, res, derr = pcall(self.decode, data, cap.ptr, cap.w, cap.h, self.mark_px)
            ok = dok and res == true
            if not ok then err = dok and derr or res end
        end
        if err then self.log("capture failed:", tostring(err)) end
        self:_emit({ ev = "captured", slot = slot.id, id = cap.id, ok = ok,
            wait = math.floor((t1 - cap.t0) * 1000 + 0.5), draw = math.floor((monotonic() - t1) * 1000 + 0.5),
            via = "screenshot" })
    end)
end

-- Ends the slot's screencast capture: with a screenshot instead (fallback), or not at all.
function Bridge:_endCast(slot, fallback)
    local cap = slot.cap
    slot.cap = nil
    if slot.casting then
        slot.casting = false
        self:_cmd("Page.stopScreencast", nil, slot.session)
    end
    if not cap then return end
    if fallback then
        self:_screenshot(slot, cap)
    else
        self:_emit({ ev = "captured", slot = slot.id, id = cap.id, ok = false })
    end
end

-- A screencast frame: the capture's page once the strip has the capture's grey.
function Bridge:_frame(slot, p)
    self:_cmd("Page.screencastFrameAck", { sessionId = p.sessionId }, slot.session)
    local cap = slot.cap
    if not (cap and p.data) then return end
    cap.frames = cap.frames + 1
    local t1 = monotonic()
    local dok, res, grey = pcall(self.decode, base64.decode(p.data), cap.ptr, cap.w, cap.h, self.mark_px)
    if not (dok and res == true) then
        -- (a recent desktop Chromium sends frames in CSS pixels, smaller than the page)
        self.log("cannot use screencast frames, taking screenshots:", tostring(dok and grey or res))
        self.screencast = nil
        return self:_endCast(slot, true)
    end
    if type(grey) ~= "number" or math.abs(grey - cap.level) > Bridge.MARK_STEP / 2 - 4 then return end
    slot.cap = nil
    slot.casting = false
    self:_cmd("Page.stopScreencast", nil, slot.session)
    self:_emit({ ev = "captured", slot = slot.id, id = cap.id, ok = true,
        wait = math.floor((t1 - cap.t0) * 1000 + 0.5), draw = math.floor((monotonic() - t1) * 1000 + 0.5),
        via = "screencast", frames = cap.frames })
end

-- Handles one message from the browser.
function Bridge:_handle(m)
    if m.id then
        local cb = self.pending[m.id]
        if cb then
            self.pending[m.id] = nil
            if m.error then
                cb(nil, tostring(m.error.message or json.encode(m.error)))
            else
                cb(m.result or {})
            end
        end
        return
    end
    local slot = m.sessionId and self.sessions[m.sessionId]
    local p = m.params or {}
    local method = m.method
    if method == "Runtime.bindingCalled" and p.name == "__koDone" and slot then
        local id, r = (p.payload or ""):match("^(%d+)\n(.*)$")
        if id then
            self:_emit('{"ev":"done","slot":' .. slot.id .. ',"id":' .. id .. ',"r":' .. (r ~= "" and r or "null") .. "}")
        end
    elseif method == "Fetch.requestPaused" and slot then
        self:_request(slot, { id = p.requestId, url = p.request and p.request.url or "",
            navigation = p.resourceType == "Document" and p.frameId == slot.target })
    elseif method == "Network.requestIntercepted" and slot then
        self:_request(slot, { id = p.interceptionId, url = p.request and p.request.url or "",
            navigation = p.isNavigationRequest and p.resourceType == "Document" and p.frameId == slot.target })
    elseif method == "Page.screencastFrame" and slot then
        self:_frame(slot, p)
    elseif method == "Page.loadEventFired" and slot then
        if slot.loading then
            slot.loading = false
            self:_emit({ ev = "loaded", slot = slot.id })
        end
    elseif method == "Runtime.exceptionThrown" and slot then
        local ex = p.exceptionDetails or {}
        self:_emit({ ev = "error", slot = slot.id,
            msg = tostring(ex.exception and ex.exception.description or ex.text) })
    elseif method == "Inspector.targetCrashed" or method == "Target.targetCrashed" then
        self:_emit({ ev = "error", slot = slot and slot.id or 0, msg = "the browser's page crashed", fatal = true })
    elseif method == "Target.detachedFromTarget" and p.sessionId and self.sessions[p.sessionId] then
        local s = self.sessions[p.sessionId]
        self.sessions[p.sessionId] = nil
        self.slots[s.id] = nil
        self:_emit({ ev = "error", slot = s.id, msg = "the browser closed the page", fatal = true })
    end
end

--- Asks the browser to free what memory it can (its caches, unused script memory), at most
-- once every RELEASE_EVERY seconds. Returns true when it asked.
function Bridge:releaseMemory()
    local now = monotonic()
    if self.closed or (self.released_at and now - self.released_at < Bridge.RELEASE_EVERY) then return false end
    self.released_at = now
    for _, slot in pairs(self.slots) do
        self:_cmd("Memory.simulatePressureNotification", { level = "critical" }, slot.session)
    end
    return true
end

--- Runs the watch now. Returns nothing, or the reason the browser was stopped.
function Bridge:checkNow()
    if not self.watch or self.closed then return self.ended end
    self.next_watch = monotonic() + Bridge.WATCH_EVERY
    local ok, err = pcall(self.watch, self)
    if not ok then
        self.log("watch failed:", tostring(err))
        return
    end
    if err then self:_stop(err) end
    return self.ended
end

-- Ends the browser for a reason of the plugin's (it is killed once the bridge is freed).
function Bridge:_stop(reason)
    if self.closed then return end
    self.log("stopping the browser:", reason)
    self.closed, self.ended = true, reason
    self:_emit({ ev = "error", slot = 0, msg = reason, fatal = true })
end

-- Reads what the browser sent within timeout_ms and handles it.
function Bridge:_pump(timeout_ms)
    if self.watch and not self.closed and monotonic() >= self.next_watch then
        if self:checkNow() then return end
    end
    local cdp = self.cdp
    local got = cdp:_pump(timeout_ms)
    local msgs = cdp.messages
    cdp.messages = {}
    for _, m in ipairs(msgs) do self:_handle(m) end
    if got == nil and not self.closed then
        self.closed = true
        self.ended = "the browser ended (" .. tostring(cdp:exitStatus()) .. ")"
        self:_emit({ ev = "error", slot = 0, msg = self.ended, fatal = true })
    end
    for _, slot in pairs(self.slots) do
        local cap = slot.cap
        if cap and monotonic() >= cap.deadline then
            self.log(string.format("no screencast frame after %.1f s (%d other frames): taking a screenshot",
                monotonic() - cap.t0, cap.frames))
            self:_endCast(slot, true)
        end
    end
    if next(self.needs) then
        local now = monotonic()
        for rid, n in pairs(self.needs) do
            if now >= n.deadline then
                self.needs[rid] = nil
                self:_answer(n.slot, n.req, nil)
            end
        end
    end
end

function Bridge:poll(timeout_ms)
    if #self.outbox == 0 then
        self:_pump(0)
        if #self.outbox == 0 and (timeout_ms or 0) > 0 and not self.closed then self:_pump(timeout_ms) end
    end
    return table.remove(self.outbox, 1)
end

function Bridge:drain()
    self:_pump(0)
    self.outbox = {}
end

function Bridge:close(slot_id)
    local slot = self.slots[slot_id]
    if not slot then return end
    -- the page stays (Kindles cannot create another): only its document goes
    slot.doc, slot.files, slot.loading = "", {}, false
    if slot.cap or slot.casting then self:_endCast(slot, false) end
    for rid, n in pairs(self.needs) do
        if n.slot == slot then
            self.needs[rid] = nil
            self:_answer(slot, n.req, nil)
        end
    end
    self:_cmd("Page.navigate", { url = "about:blank" }, slot.session)
end

function Bridge:closeAll()
    for id in pairs(self.slots) do self:close(id) end
end

--- Whether the browser still runs.
function Bridge:alive() return not self.closed and not self.cdp:exitStatus() end

function Bridge:free()
    if self.freed then return end
    self.freed = true
    local how, status = self.cdp:close(self.close_grace)
    self.log("browser closed:", how, status)
    if self.on_free then pcall(self.on_free, self.cdp) end
end

return Bridge
