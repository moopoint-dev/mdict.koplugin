--[[--
A DevTools protocol client over Chromium's remote debugging pipe: the browser reads
commands on fd 3 and writes replies and events on fd 4, each a JSON text ended by NUL.

It starts the browser itself (optionally inside a chroot, as Amazon runs its browser on
Kindles) and talks to it directly from Lua, with no other program in between.
]]

local ffi = require("ffi")
local json = require("mdict/json")
local monotonic = require("mdict/clock")

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
    "int fcntl(int fd, int cmd, ...);",
    "int open(const char *pathname, int flags, ...);",
    "int chroot(const char *path);",
    "int chdir(const char *path);",
    "int execve(const char *path, char *const argv[], char *const envp[]);",
    "void _exit(int status);",
    "long read(int fd, void *buf, unsigned long count);",
    "long write(int fd, const void *buf, unsigned long count);",
    "int kill(int pid, int sig);",
    "int waitpid(int pid, int *status, int options);",
    -- named apart from any signal() KOReader declares, whose handler type would differ
    "void *mdict_signal(int signum, void *handler) __asm__(\"signal\");",
}) do
    pcall(ffi.cdef, decl)
end
local C = ffi.C

local POLLIN, WNOHANG, F_DUPFD, SIGPIPE = 1, 1, 0, 13
local O_RDONLY, O_WRONLY, O_CREAT, O_TRUNC = 0, 1, 64, 512

local Cdp = {}
Cdp.__index = Cdp

-- NULL-terminated char*[] from a list of strings; keep is filled with what must stay alive.
local function cstrings(list, keep)
    local arr = ffi.new("char*[?]", #list + 1)
    for i, s in ipairs(list) do
        keep[#keep + 1] = ffi.new("char[?]", #s + 1, s)
        arr[i - 1] = keep[#keep]
    end
    arr[#list] = nil
    keep[#keep + 1] = arr
    return arr
end

--- Starts a browser with the DevTools pipe on fds 3 and 4.
-- opts: exe (path as seen after the chroot), args (list), env (list of "NAME=value", the
-- browser's whole environment), root (chroot into it first; needs root), log (path for the
-- browser's stdout and stderr, opened before the chroot).
-- Returns the client, or nil and an error.
function Cdp.spawn(opts)
    local keep = {}
    local argv = cstrings({ opts.exe, unpack(opts.args or {}) }, keep)
    local envp = cstrings(opts.env or {}, keep)
    local to_child, from_child = ffi.new("int[2]"), ffi.new("int[2]")
    -- casts made now: the child should not allocate
    local hi, mode = ffi.cast("int", 200), ffi.cast("int", 420)
    local sig_dfl, sig_ign = ffi.cast("void *", 0), ffi.cast("void *", 1)
    if C.pipe(to_child) ~= 0 then return nil, "pipe failed" end
    if C.pipe(from_child) ~= 0 then
        C.close(to_child[0]); C.close(to_child[1])
        return nil, "pipe failed"
    end
    local pid = C.fork()
    if pid == 0 then
        -- the child: only system calls from here on
        C.mdict_signal(SIGPIPE, sig_dfl)
        local r = C.fcntl(to_child[0], F_DUPFD, hi)
        local w = C.fcntl(from_child[1], F_DUPFD, hi)
        C.dup2(r, 3)
        C.dup2(w, 4)
        local null = C.open("/dev/null", O_RDONLY)
        if null >= 0 then C.dup2(null, 0) end
        local log = opts.log and C.open(opts.log, O_WRONLY + O_CREAT + O_TRUNC, mode) or -1
        if log < 0 then log = C.open("/dev/null", O_WRONLY) end
        if log >= 0 then
            C.dup2(log, 1)
            C.dup2(log, 2)
        end
        for fd = 5, 1023 do C.close(fd) end -- KOReader's own files stay out of the browser
        if opts.root and (C.chroot(opts.root) ~= 0 or C.chdir("/") ~= 0) then C._exit(126) end
        C.execve(argv[0], argv, envp)
        C._exit(127)
    end
    C.close(to_child[0])
    C.close(from_child[1])
    if pid < 0 then
        C.close(to_child[1]); C.close(from_child[0])
        return nil, "fork failed"
    end
    -- a write to the pipe of a browser that died must fail, not end KOReader
    local old_pipe = C.mdict_signal(SIGPIPE, sig_ign)
    local self = setmetatable({
        pid = pid, wfd = to_child[1], rfd = from_child[0], old_pipe = old_pipe,
        parts = {}, messages = {}, next_id = 0,
        readbuf = ffi.new("uint8_t[65536]"), pfd = ffi.new("struct pollfd[1]"),
    }, Cdp)
    self.pfd[0].fd, self.pfd[0].events = self.rfd, POLLIN
    return self
end

function Cdp:send(method, params, session)
    if not self.wfd then error("browser pipe closed", 0) end
    self.next_id = self.next_id + 1
    local msg = { id = self.next_id, method = method, params = params or {} }
    if session then msg.sessionId = session end
    local data = json.encode(msg) .. "\0"
    local off = 0
    while off < #data do
        local n = C.write(self.wfd, ffi.cast("const char*", data) + off, #data - off)
        if n <= 0 then error("browser pipe closed", 0) end
        off = off + n
    end
    return self.next_id
end

-- Reads what the browser sent within timeout_ms. False when nothing came, nil at end of pipe.
function Cdp:_pump(timeout_ms)
    if not self.rfd then return nil end
    local r = C.poll(self.pfd, 1, timeout_ms)
    if r <= 0 then return false end
    local n = C.read(self.rfd, self.readbuf, 65536)
    if n <= 0 then
        C.close(self.rfd)
        self.rfd = nil
        return nil
    end
    local chunk = ffi.string(self.readbuf, n)
    local start = 1
    while true do
        local z = chunk:find("\0", start, true)
        if not z then break end
        self.parts[#self.parts + 1] = chunk:sub(start, z - 1)
        local text = table.concat(self.parts)
        self.parts = {}
        local ok, msg = pcall(json.decode, text)
        if ok and type(msg) == "table" then self.messages[#self.messages + 1] = msg end
        start = z + 1
    end
    if start <= #chunk then self.parts[#self.parts + 1] = chunk:sub(start) end
    return true
end

-- The first queued message that pred accepts, removed from the queue.
function Cdp:_take(pred)
    for i, m in ipairs(self.messages) do
        if pred(m) then
            table.remove(self.messages, i)
            return m
        end
    end
end

--- Waits for a message that pred accepts, at most timeout seconds. Returns it, or nil and an error.
function Cdp:waitFor(pred, timeout, what)
    local deadline = monotonic() + (timeout or 30)
    while true do
        local m = self:_take(pred)
        if m then return m end
        local left = deadline - monotonic()
        if left <= 0 then return nil, "timed out waiting for " .. (what or "the browser") end
        local got = self:_pump(math.max(1, math.floor(math.min(left, 1) * 1000)))
        if got == nil and not self:_take(pred) then return nil, "the browser closed the pipe" end
    end
end

--- Sends a command and waits for its reply. Returns the result, or nil and an error.
function Cdp:call(method, params, session, timeout)
    local ok, id = pcall(self.send, self, method, params, session)
    if not ok then return nil, id end
    local m, err = self:waitFor(function(msg) return msg.id == id end, timeout, method)
    if not m then return nil, err end
    if m.error then return nil, method .. ": " .. tostring(m.error.message or json.encode(m.error)) end
    return m.result or {}
end

--- Waits for an event. pred(params) can narrow it down.
function Cdp:waitEvent(name, timeout, pred)
    local m, err = self:waitFor(function(msg)
        return msg.method == name and (not pred or pred(msg.params or {}))
    end, timeout, name)
    return m and (m.params or {}), err
end

--- Drops queued events (replies to commands are kept).
function Cdp:dropEvents(name)
    local kept = {}
    for _, m in ipairs(self.messages) do
        if m.id or (name and m.method ~= name) then kept[#kept + 1] = m end
    end
    self.messages = kept
end

-- "exited 0", "killed by signal 9", or nil while the browser runs.
function Cdp:exitStatus()
    if self.status then return self.status end
    if not self.pid then return nil end
    local st = ffi.new("int[1]")
    local w = C.waitpid(self.pid, st, WNOHANG)
    if w < 0 then -- reaped elsewhere
        self.status, self.pid = "gone", nil
    elseif w == self.pid then
        local s = st[0]
        if s % 128 == 0 then
            self.status = "exited " .. math.floor(s / 256) % 256
        else
            self.status = "killed by signal " .. s % 128
        end
        self.pid = nil
    end
    return self.status
end

--- Stops the browser: asks it to close, then terminates and kills it if it does not.
-- Returns how it ended ("closed", "terminated", "killed") and its exit status.
function Cdp:close(grace)
    local how = "closed"
    if not self:exitStatus() and self.wfd then pcall(self.send, self, "Browser.close") end
    local function wait(s)
        local deadline = monotonic() + s
        while not self:exitStatus() and monotonic() < deadline do
            if not self:_pump(100) then C.poll(nil, 0, 100) end
        end
        return self:exitStatus()
    end
    if not wait(grace or 5) and self.pid then
        how = "terminated"
        C.kill(self.pid, 15)
        if not wait(3) and self.pid then
            how = "killed"
            C.kill(self.pid, 9)
            wait(3)
        end
    end
    if self.wfd then C.close(self.wfd); self.wfd = nil end
    if self.rfd then C.close(self.rfd); self.rfd = nil end
    if self.old_pipe then
        C.mdict_signal(SIGPIPE, self.old_pipe)
        self.old_pipe = nil
    end
    return how, self.status
end

return Cdp
