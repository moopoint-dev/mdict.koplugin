--[[--
File system helpers (LuaFileSystem inside or outside KOReader).
]]

local ok, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok then lfs = require("lfs") end

local M = { lfs = lfs }

--- size, mtime of a file, or nil.
function M.stat(path)
    local a = lfs.attributes(path)
    if not a or a.mode ~= "file" then return nil end
    return a.size, a.modification
end

function M.isDir(path)
    return lfs.attributes(path, "mode") == "directory"
end

function M.isFile(path)
    return lfs.attributes(path, "mode") == "file"
end

function M.mkdirp(path)
    if path == "" or M.isDir(path) then return true end
    local parent = path:match("^(.*)/[^/]+/?$")
    if parent and parent ~= "" and not M.isDir(parent) then M.mkdirp(parent) end
    return lfs.mkdir(path) or M.isDir(path)
end

function M.dirname(path)
    return path:match("^(.*)/[^/]*$") or "."
end

function M.basename(path)
    return path:match("([^/]*)$")
end

--- Writes data to path through a temporary file, creating directories.
function M.writeAtomic(path, data)
    M.mkdirp(M.dirname(path))
    local tmp = path .. ".part"
    local f, err = io.open(tmp, "wb")
    if not f then return nil, err end
    f:write(data)
    f:close()
    local rok, rerr = os.rename(tmp, path)
    if not rok then
        os.remove(tmp)
        return nil, rerr
    end
    return true
end

function M.readAll(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

--- Calls fn(path) for each file under dir whose name matches pattern, to `depth` levels.
function M.walk(dir, pattern, fn, depth)
    depth = depth or 4
    local okd, iter, state = pcall(lfs.dir, dir)
    if not okd then return end
    local entries = {}
    for name in iter, state do
        if name ~= "." and name ~= ".." and name:sub(1, 1) ~= "." then entries[#entries + 1] = name end
    end
    table.sort(entries)
    for _, name in ipairs(entries) do
        local path = dir .. "/" .. name
        local mode = lfs.attributes(path, "mode")
        if mode == "directory" then
            if depth > 0 then M.walk(path, pattern, fn, depth - 1) end
        elseif mode == "file" and name:find(pattern) then
            fn(path)
        end
    end
end

--- Removes a directory tree (used for the plugin's own cache only).
function M.removeTree(path)
    if not M.isDir(path) then
        os.remove(path)
        return
    end
    for name in lfs.dir(path) do
        if name ~= "." and name ~= ".." then M.removeTree(path .. "/" .. name) end
    end
    lfs.rmdir(path)
end

--- Files under dir as { path, size, atime }, for cache pruning.
function M.listFiles(dir, out)
    out = out or {}
    local okd, iter, state = pcall(lfs.dir, dir)
    if not okd then return out end
    for name in iter, state do
        if name ~= "." and name ~= ".." then
            local path = dir .. "/" .. name
            local a = lfs.attributes(path)
            if a and a.mode == "directory" then
                M.listFiles(path, out)
            elseif a and a.mode == "file" then
                out[#out + 1] = { path = path, size = a.size, atime = math.max(a.access or 0, a.modification or 0) }
            end
        end
    end
    return out
end

return M
