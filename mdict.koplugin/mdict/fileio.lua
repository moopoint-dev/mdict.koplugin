--[[--
Positional reads with 64-bit offsets (dictionary files can exceed 2 GB, and
`file:seek` is limited to 32-bit offsets on 32-bit Android builds).
]]

local bit = require("bit")
local ffi = require("ffi")
local C = ffi.C

local function cdef(decl)
    pcall(ffi.cdef, decl)
end
cdef("int open(const char *pathname, int flags, ...);")
cdef("int close(int fd);")
cdef("intptr_t pread64(int fd, void *buf, size_t count, int64_t offset);")
cdef("char *strerror(int errnum);")

local O_RDONLY = 0
-- Needed on 32-bit targets to open files larger than 2 GB (implicit on 64-bit).
local O_LARGEFILE = ({ arm = 0x20000, x86 = 0x8000 })[ffi.arch] or 0

local File = {}
File.__index = File

local M = {}

function M.open(path)
    local fd = C.open(path, bit.bor(O_RDONLY, O_LARGEFILE))
    if fd < 0 then
        return nil, "cannot open " .. path .. ": " .. ffi.string(C.strerror(ffi.errno()))
    end
    return setmetatable({ fd = fd, path = path }, File)
end

--- Read exactly `n` bytes at `offset` into a new uint8_t buffer.
function File:read(offset, n)
    local buf = ffi.new("uint8_t[?]", math.max(n, 1))
    local got = 0
    while got < n do
        local r = tonumber(C.pread64(self.fd, buf + got, n - got, offset + got))
        if r <= 0 then
            error(string.format("short read in %s at %.0f (%d of %d bytes)", self.path, offset, got, n))
        end
        got = got + r
    end
    return buf
end

--- Read `n` bytes at `offset` as a Lua string.
function File:readString(offset, n)
    return ffi.string(self:read(offset, n), n)
end

function File:close()
    if self.fd and self.fd >= 0 then
        C.close(self.fd)
    end
    self.fd = nil
end

return M
