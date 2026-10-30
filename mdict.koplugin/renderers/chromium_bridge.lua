--[[--
Renderer bridge backed by headless Chromium (tools/chromium-bridge/bridge.js,
run with Node and Playwright). It speaks the Android bridge's interface, so
the KOReader emulator and the integration tests exercise the same code path
as a device.
]]

local ffi = require("ffi")
local json = require("mdict/json")

-- Inside KOReader, ffi/posix_h declares most of these already (redeclaring fails), and
-- poll() takes its struct pollfd: declare only what is missing.
if not pcall(require, "ffi/posix_h") then
    pcall(ffi.cdef, "struct pollfd { int fd; short events; short revents; };")
    pcall(ffi.cdef, "int poll(struct pollfd *fds, unsigned long nfds, int timeout);")
end
for _, decl in ipairs({
    "int pipe(int fds[2]);",
    "int fork(void);",
    "int dup2(int oldfd, int newfd);",
    "int close(int fd);",
    "int execvp(const char *file, char *const argv[]);",
    "void _exit(int status);",
    "long read(int fd, void *buf, unsigned long count);",
    "long write(int fd, const void *buf, unsigned long count);",
    "int kill(int pid, int sig);",
    "int waitpid(int pid, int *status, int options);",
    "int setenv(const char *name, const char *value, int overwrite);",
}) do
    pcall(ffi.cdef, decl)
end
local C = ffi.C

local Bridge = {}
Bridge.__index = Bridge

local POLLIN = 1

--- Starts the bridge process. opts: script (bridge.js path), node ("node"), node_path (NODE_PATH),
-- dpr (device pixel ratio to emulate), tmpdir (for page captures).
function Bridge.new(opts)
    local self = setmetatable({
        dpr = opts.dpr or 2,
        tmpdir = opts.tmpdir or os.getenv("TMPDIR") or "/tmp",
        buf = "",
        captures = {},
    }, Bridge)
    local to_child, from_child = ffi.new("int[2]"), ffi.new("int[2]")
    assert(C.pipe(to_child) == 0 and C.pipe(from_child) == 0, "pipe failed")
    local argv_strs = { opts.node or "node", opts.script }
    local argv = ffi.new("char*[?]", #argv_strs + 1)
    local keep = {}
    for i, s in ipairs(argv_strs) do
        keep[i] = ffi.new("char[?]", #s + 1, s)
        argv[i - 1] = keep[i]
    end
    argv[#argv_strs] = nil
    if opts.node_path then C.setenv("NODE_PATH", opts.node_path, 1) end
    local pid = C.fork()
    if pid == 0 then
        C.dup2(to_child[0], 0)
        C.dup2(from_child[1], 1)
        C.close(to_child[1])
        C.close(from_child[0])
        C.execvp(argv[0], argv)
        C._exit(127)
    end
    assert(pid > 0, "fork failed")
    C.close(to_child[0])
    C.close(from_child[1])
    self.pid, self.wfd, self.rfd = pid, to_child[1], from_child[0]
    self.pfd = ffi.new("struct pollfd[1]")
    self.pfd[0].fd, self.pfd[0].events = self.rfd, POLLIN
    self.readbuf = ffi.new("uint8_t[65536]")
    local ready = self:_readLine(30000)
    if not ready or not ready:find('"ready"', 1, true) then
        self:free()
        return nil, "chromium bridge did not start: " .. tostring(ready)
    end
    return self
end

function Bridge:_send(cmd)
    local line = json.encode(cmd) .. "\n"
    local off = 0
    while off < #line do
        local n = C.write(self.wfd, ffi.cast("const char*", line) + off, #line - off)
        if n <= 0 then error("chromium bridge: write failed") end
        off = off + n
    end
end

function Bridge:_readLine(timeout_ms)
    while true do
        local nl = self.buf:find("\n", 1, true)
        if nl then
            local line = self.buf:sub(1, nl - 1)
            self.buf = self.buf:sub(nl + 1)
            return line
        end
        local r = C.poll(self.pfd, 1, timeout_ms)
        if r <= 0 then return nil end
        local n = C.read(self.rfd, self.readbuf, 65536)
        if n <= 0 then return nil end
        self.buf = self.buf .. ffi.string(self.readbuf, n)
    end
end

function Bridge:session(fn) return fn() end

function Bridge:open(slot, w, h) self:_send({ cmd = "open", slot = slot, w = w, h = h, dpr = self.dpr }) end

function Bridge:load(slot, base, html, root, files_json)
    self:_send({ cmd = "load", slot = slot, base = base, html = html, root = root,
                 files = files_json ~= "" and json.decode(files_json) or {} })
end

function Bridge:call(slot, id, op, args) self:_send({ cmd = "call", slot = slot, id = id, op = op, args = args }) end

function Bridge:provide(rid, path) self:_send({ cmd = "provide", rid = rid, path = path or "" }) end

function Bridge:capture(slot, id, ptr, w, h)
    local file = string.format("%s/mdict-capture-%d-%d.rgba", self.tmpdir, self.pid, id)
    self.captures[id] = { ptr = ptr, size = w * h * 4, file = file }
    self:_send({ cmd = "capture", slot = slot, id = id, w = w, h = h, file = file })
end

function Bridge:poll(timeout_ms)
    local line = self:_readLine(timeout_ms or 0)
    if line and line:find('"ev":"captured"', 1, true) then
        local ev = json.decode(line)
        local c = self.captures[ev.id]
        self.captures[ev.id] = nil
        if c and ev.ok then
            local f = io.open(c.file, "rb")
            local data = f and f:read("*a")
            if f then f:close() end
            os.remove(c.file)
            if data and #data == c.size then
                ffi.copy(c.ptr, data, c.size)
            else
                line = line:gsub('"ok":true', '"ok":false')
            end
        end
    end
    return line
end

function Bridge:drain()
    while self:_readLine(0) do end
end

function Bridge:close(slot) self:_send({ cmd = "close", slot = slot }) end

function Bridge:closeAll() self:_send({ cmd = "closeAll" }) end

function Bridge:free()
    if not self.pid then return end
    pcall(function() self:_send({ cmd = "quit" }) end)
    C.close(self.wfd)
    C.close(self.rfd)
    local status = ffi.new("int[1]")
    for _ = 1, 50 do
        if C.waitpid(self.pid, status, 1) ~= 0 then break end -- WNOHANG
        C.poll(nil, 0, 20)
    end
    C.kill(self.pid, 9)
    C.waitpid(self.pid, status, 1)
    self.pid = nil
end

return Bridge
