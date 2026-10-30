--[[--
Background index builds inside KOReader: one subprocess at a time, polled from
the UI loop, reporting progress through a pipe.
]]

local Dictionary = require("mdict/dictionary")
local UIManager = require("ui/uimanager")
local ffi = require("ffi")
local ffiUtil = require("ffi/util")
local logger = require("logger")
require("ffi/posix_h")
local C = ffi.C

-- What the child has written so far, without blocking.
local function read_available(fd)
    local n = ffiUtil.getNonBlockingReadSize(fd)
    if not n or n <= 0 then return "" end
    local buf = ffi.new("char[?]", n)
    local got = tonumber(C.read(fd, buf, n))
    if not got or got <= 0 then return "" end
    return ffi.string(buf, got)
end

local Indexer = {
    queue = {},
    current = nil,
    POLL_S = 0.5,
    on_change = nil, -- called with (job, event) for "start", "progress", "done", "failed"
}

local function notify(job, event)
    if Indexer.on_change then pcall(Indexer.on_change, job, event) end
end

--- Builder for Dictionary objects: queues the job, calls done(ok) when it finishes.
function Indexer.build(job, done)
    for _, q in ipairs(Indexer.queue) do
        if q.job.sidecar == job.sidecar then
            table.insert(q.callbacks, done)
            return
        end
    end
    if Indexer.current and not Indexer.current.cancelled and Indexer.current.job.sidecar == job.sidecar then
        table.insert(Indexer.current.callbacks, done)
        return
    end
    table.insert(Indexer.queue, { job = job, callbacks = { done } })
    Indexer._next()
end

--- Moves queued builds for these files (set of paths) to the front: someone is waiting for them.
function Indexer.promote(paths)
    local front, rest = {}, {}
    for _, q in ipairs(Indexer.queue) do
        table.insert(paths[q.job.path] and front or rest, q)
    end
    for _, q in ipairs(rest) do front[#front + 1] = q end
    Indexer.queue = front
end

function Indexer.busy()
    return Indexer.current ~= nil or #Indexer.queue > 0
end

function Indexer._finish(ok)
    local cur = Indexer.current
    Indexer.current = nil
    if cur.fd then C.close(cur.fd) end
    local output = (cur.output or ""):gsub("p [%d.]+\n", "") -- without the progress lines
    logger.info("MDict: index", ok and "built" or (cur.cancelled and "cancelled" or "FAILED"), cur.job.path,
        output:sub(-300))
    if not cur.cancelled then notify(cur.job, ok and "done" or "failed") end
    for _, cb in ipairs(cur.callbacks) do pcall(cb, ok) end
    Indexer._next()
end

function Indexer._next()
    if Indexer.current or #Indexer.queue == 0 then return end
    local item = table.remove(Indexer.queue, 1)
    local job = item.job
    local plain = {}
    for k, v in pairs(job) do
        if type(v) ~= "table" and type(v) ~= "function" then plain[k] = v end
    end
    local pid, fd = ffiUtil.runInSubProcess(function(_, write_fd)
        local last = -1
        local ok, err = pcall(Dictionary.buildIndexJob, plain, function(fraction)
            if fraction - last >= 0.01 then
                last = fraction
                ffiUtil.writeToFD(write_fd, string.format("p %.3f\n", fraction))
            end
        end)
        ffiUtil.writeToFD(write_fd, ok and "ok\n" or ("err " .. tostring(err) .. "\n"), true)
    end, true)
    if not pid then
        logger.warn("MDict: cannot start indexer:", fd)
        Indexer.current = item
        Indexer._finish(false)
        return
    end
    item.pid, item.fd, item.output, item.progress = pid, fd, "", 0
    Indexer.current = item
    notify(job, "start")
    UIManager:scheduleIn(Indexer.POLL_S, Indexer._poll)
end

function Indexer._poll()
    local cur = Indexer.current
    if not cur then return end
    if cur.fd then cur.output = cur.output .. read_available(cur.fd) end
    local p = cur.output:match(".*p ([%d.]+)\n")
    if p and tonumber(p) ~= cur.progress then
        cur.progress = tonumber(p)
        notify(cur.job, "progress")
    end
    if ffiUtil.isSubProcessDone(cur.pid) then
        if cur.fd then
            cur.output = cur.output .. (ffiUtil.readAllFromFD(cur.fd) or "")
            cur.fd = nil
        end
        Indexer._finish(cur.output:find("\nok\n", 1, true) ~= nil or cur.output:sub(1, 3) == "ok\n")
        return
    end
    UIManager:scheduleIn(Indexer.POLL_S, Indexer._poll)
end

--- Progress of the running build: job, fraction.
function Indexer.status()
    if not Indexer.current then return nil end
    return Indexer.current.job, Indexer.current.progress or 0
end

function Indexer.stopAll()
    Indexer.queue = {}
    local cur = Indexer.current
    if cur and cur.pid then
        cur.cancelled = true
        ffiUtil.terminateSubProcess(cur.pid)
    end
end

return Indexer
