--[[--
Renderer bridge over a Chromium driven through its DevTools pipe (renderers/cdp_pipe.lua):
the Kindle's own browser, or a desktop Chromium. It speaks the Android bridge's interface
(see renderers/webview.lua), as tools/chromium-bridge/bridge.js does with Playwright, but
from Lua alone.

Each slot is a page target. The page's requests are intercepted and answered from the
dictionary's files (Fetch domain, or the older Network interception when the browser was
built without the network service, as Chromium 75 on Kindles is). Screenshots are decoded
into the page memory the widget hands over.
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
--   decode(data, ptr, w, h): draws an encoded screenshot into w*h RGBA at ptr; true or nil, err
--   on_free(cdp): called once the browser is closed (default: nothing)
--   capture_wait: seconds a screenshot may take (default CAPTURE_WAIT)
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
        slots = {},
        sessions = {}, -- sessionId -> slot
        outbox = {},
        pending = {}, -- command id -> function(result, error)
        needs = {}, -- rid -> { slot, request, deadline }
        next_rid = 0,
        spare = {}, -- page targets not yet taken by a slot
    }, Bridge)
    self.capture_timeout = self.capture_wait + 2
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
        { "Page.addScriptToEvaluateOnNewDocument", { source = Bridge.KOBRIDGE } },
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
        width = math.floor(w / dpr + 0.5), height = math.floor(h / dpr + 0.5), deviceScaleFactor = dpr, mobile = false,
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
    local t0 = monotonic()
    self:_cmd("Page.captureScreenshot", self.capture_params, slot.session, function(r, err)
        local t1 = monotonic()
        local ok = false
        if t1 - t0 > self.capture_wait then
            r, err = nil, string.format("screenshot came after %.1f s", t1 - t0)
        end
        if r and r.data then
            local data = base64.decode(r.data)
            local dok, res, derr = pcall(self.decode, data, ptr, w, h)
            ok = dok and res == true
            if not ok then err = dok and derr or res end
        end
        if err then self.log("capture failed:", tostring(err)) end
        self:_emit({ ev = "captured", slot = slot_id, id = id, ok = ok,
            wait = math.floor((t1 - t0) * 1000 + 0.5), draw = math.floor((monotonic() - t1) * 1000 + 0.5),
            via = "screenshot" })
    end)
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

-- Reads what the browser sent within timeout_ms and handles it.
function Bridge:_pump(timeout_ms)
    local cdp = self.cdp
    local got = cdp:_pump(timeout_ms)
    local msgs = cdp.messages
    cdp.messages = {}
    for _, m in ipairs(msgs) do self:_handle(m) end
    if got == nil and not self.closed then
        self.closed = true
        self:_emit({ ev = "error", slot = 0, msg = "the browser ended (" .. tostring(cdp:exitStatus()) .. ")",
            fatal = true })
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
    local how, status = self.cdp:close(3)
    self.log("browser closed:", how, status)
    if self.on_free then pcall(self.on_free, self.cdp) end
end

return Bridge
