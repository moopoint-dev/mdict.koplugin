--[[--
Plugin updates from the project's GitHub releases: version numbers, GitHub's
"latest release" answer, downloading and unpacking a release, and moving a
downloaded update into place when KOReader starts.

An update is unpacked next to the plugin folder (`.mdict.koplugin.update`) and
only moved in at the next start, by main.lua, before any of the plugin's
modules are loaded. The running session never mixes old and new files.

This file must not require the plugin's own modules at load time: main.lua
runs it with loadfile before an update replaces them.
]]

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then lfs = require("lfs") end

local M = {}

M.REPO = "moopoint-dev/mdict.koplugin"
M.API_URL = "https://api.github.com/repos/" .. M.REPO .. "/releases/latest"
M.RELEASES_URL = "https://github.com/" .. M.REPO .. "/releases"
-- release assets: mdict.koplugin-<version>.zip
M.ASSET_PATTERN = "^mdict%.koplugin.*%.zip$"

-- Versions -------------------------------------------------------------------

--- "v1.2.3", "1.2" or "1.2.3-rc.1" -> { 1, 2, 3, pre = "rc.1" }, or nil.
function M.parseVersion(s)
    if type(s) ~= "string" then return nil end
    local core, rest = s:match("^%s*[vV]?(%d[%d%.]*)(.-)%s*$")
    if not core or core:sub(-1) == "." or core:find("..", 1, true) then return nil end
    local v = {}
    for n in core:gmatch("%d+") do v[#v + 1] = tonumber(n) end
    if rest ~= "" then
        local pre = rest:match("^%-([%w%.%-]+)$")
        if not pre then return nil end
        v.pre = pre
    end
    return v
end

--- -1, 0 or 1 as version a is older than, the same as or newer than b; nil if either is not a version.
-- A pre-release is older than its release (1.0-rc.1 < 1.0).
function M.compare(a, b)
    a = type(a) == "table" and a or M.parseVersion(a)
    b = type(b) == "table" and b or M.parseVersion(b)
    if not a or not b then return nil end
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x ~= y then return x < y and -1 or 1 end
    end
    if a.pre == b.pre then return 0 end
    if not a.pre then return 1 end
    if not b.pre then return -1 end
    return a.pre < b.pre and -1 or 1
end

--- The version in a plugin's _meta.lua, read without running KOReader code, or nil.
function M.readMetaVersion(path)
    local chunk = loadfile(path)
    if not chunk then return nil end
    setfenv(chunk, {
        require = function(name)
            if name == "gettext" then return function(s) return s end end
            error("not available: " .. tostring(name))
        end,
    })
    local ok, meta = pcall(chunk)
    if ok and type(meta) == "table" and M.parseVersion(meta.version) then return meta.version end
    return nil
end

-- Releases -------------------------------------------------------------------

local function str(v) return type(v) == "string" and v or nil end

--- The parts of a GitHub release (decoded JSON) the updater uses, or nil and why not.
-- { tag, version, title, notes, url, asset = { name, url, size, sha256 } }; asset is nil
-- when the release has no plugin zip.
function M.releaseInfo(r)
    if type(r) ~= "table" or not str(r.tag_name) then return nil, "no release" end
    if r.draft == true or r.prerelease == true then return nil, "not a release" end
    if not M.parseVersion(r.tag_name) then return nil, "unknown version " .. r.tag_name end
    local asset
    for _, a in ipairs(type(r.assets) == "table" and r.assets or {}) do
        if type(a) == "table" and str(a.name) and a.name:match(M.ASSET_PATTERN)
                and str(a.browser_download_url) and (a.state == nil or a.state == "uploaded") then
            local digest = str(a.digest)
            asset = {
                name = a.name,
                url = a.browser_download_url,
                size = tonumber(a.size),
                sha256 = digest and digest:match("^sha256:(%x+)$") and digest:sub(8):lower() or nil,
            }
            break
        end
    end
    return {
        tag = r.tag_name,
        version = (r.tag_name:gsub("^%s*[vV]", "")),
        title = str(r.name),
        notes = str(r.body) or "",
        url = str(r.html_url) or M.RELEASES_URL,
        asset = asset,
    }
end

--- Release notes (Markdown) as plain text for KOReader's text widgets.
function M.plainNotes(md)
    local lines = {}
    for line in ((md or ""):gsub("\r\n?", "\n") .. "\n"):gmatch("(.-)\n") do
        line = line:gsub("^%s*#+%s*", "")
            :gsub("^(%s*)[-*]%s+", "%1• ")
            :gsub("%*%*(.-)%*%*", "%1")
            :gsub("__(.-)__", "%1")
            :gsub("`([^`]*)`", "%1")
            :gsub("!?%[([^%]]*)%]%(([^)]*)%)", "%1")
            :gsub("%*([^*%s][^*]-)%*", "%1")
        lines[#lines + 1] = line
    end
    return (table.concat(lines, "\n"):gsub("\n\n\n+", "\n\n"):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Network (run these in a subprocess: they block) ------------------------------

local function describe(code, status, headers, block, total)
    if type(code) == "number" then
        if code == 403 and headers and headers["x-ratelimit-remaining"] == "0" then
            return "GitHub's limit on requests was reached. Try again in an hour."
        elseif code == 404 then
            return "No release found (HTTP 404)."
        end
        return "HTTP " .. (status or code)
    end
    local ok, socketutil = pcall(require, "socketutil")
    local text = ok and socketutil.describe_error and socketutil.describe_error(code, block, total)
    if text then return text end
    -- KOReader before 2026.10 has no describe_error
    if code == "timeout" or code == "wantread" or code == "wantwrite" or code == "sink timeout" then
        return string.format("The connection timed out (%s).", code)
    elseif code == "closed" then
        return "The server closed the connection (closed)."
    end
    return tostring(code or "network error")
end

local function get(url, sink, headers, block, total)
    local http = require("socket.http")
    local socket = require("socket")
    local socketutil = require("socketutil")
    block, total = socketutil:set_timeout(block, total)
    local ok, code, resp_headers, status = pcall(function()
        return socket.skip(1, http.request{ url = url, method = "GET", headers = headers, sink = sink })
    end)
    socketutil:reset_timeout()
    if not ok then return nil, tostring(code) end
    if code ~= 200 then return nil, describe(code, status, resp_headers, block, total) end
    return true
end

--- GitHub's answer about the latest release, as JSON text; or nil and an error.
function M.fetchLatest()
    local socketutil = require("socketutil")
    local chunks = {}
    local ok, err = get(M.API_URL, socketutil.table_sink(chunks), {
        ["Accept"] = "application/vnd.github+json",
        ["X-GitHub-Api-Version"] = "2022-11-28",
    }, socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    if not ok then return nil, err end
    return table.concat(chunks)
end

--- Checks a downloaded file's size and SHA-256 (when known).
function M.verifyFile(path, size, sha256)
    local f = io.open(path, "rb")
    if not f then return nil, "cannot read " .. path end
    local data = f:read("*a")
    f:close()
    if size and #data ~= size then
        return nil, string.format("The download is %d bytes instead of %d.", #data, size)
    end
    if sha256 then
        local ok, sha2 = pcall(require, "ffi/sha2")
        if ok and type(sha2) == "table" and sha2.sha256 and sha2.sha256(data):lower() ~= sha256 then
            return nil, "The download is damaged (checksum mismatch)."
        end
    end
    return true
end

-- Downloads are tried a few times, with more time than KOReader gives files (15 s without
-- data, 60 s in all): from some networks GitHub's downloads are slow and stall now and then.
M.DOWNLOAD_TRIES = 3
M.DOWNLOAD_BLOCK_TIMEOUT, M.DOWNLOAD_TOTAL_TIMEOUT = 30, 180

local function download_once(asset, path)
    local socketutil = require("socketutil")
    os.remove(path)
    local f, ferr = io.open(path, "wb")
    if not f then return nil, ferr end
    local ok, err = get(asset.url, socketutil.file_sink(f), nil, M.DOWNLOAD_BLOCK_TIMEOUT, M.DOWNLOAD_TOTAL_TIMEOUT)
    pcall(f.close, f)
    if ok then ok, err = M.verifyFile(path, asset.size, asset.sha256) end
    if not ok then os.remove(path) end
    return ok, err
end

--- Downloads a release asset to path and checks it (trying again when it fails).
function M.download(asset, path)
    local ok, err
    for _ = 1, M.DOWNLOAD_TRIES do
        ok, err = download_once(asset, path)
        if ok then return true end
    end
    return nil, err
end

-- Files -------------------------------------------------------------------------

local function mode(path) return lfs.symlinkattributes(path, "mode") end

--- Removes a file or a directory tree (symbolic links are removed, not followed).
function M.removeTree(path)
    local m = mode(path)
    if m == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then M.removeTree(path .. "/" .. name) end
        end
        return lfs.rmdir(path)
    elseif m then
        return os.remove(path)
    end
    return true
end

--- Where an update of the plugin in plugin_dir is unpacked and where the replaced version goes.
-- Hidden names that do not end in .koplugin, so KOReader never loads them as plugins.
function M.paths(plugin_dir)
    plugin_dir = plugin_dir:gsub("/+$", "")
    local parent, name = plugin_dir:match("^(.*)/([^/]+)$")
    if not parent then parent, name = ".", plugin_dir end
    return {
        dir = plugin_dir,
        staged = parent .. "/." .. name .. ".update",
        old = parent .. "/." .. name .. ".old",
    }
end

local function shell_quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

local function safe_entry(p)
    if p == "" or p:sub(1, 1) == "/" or p:find("\\", 1, true) then return false end
    for part in p:gmatch("[^/]+") do
        if part == ".." then return false end
    end
    return true
end

--- Unpacks a zip into the directory dest (which must exist).
function M.unzip(zip, dest)
    local ok_a, Archiver = pcall(require, "ffi/archiver")
    if ok_a and type(Archiver) == "table" and Archiver.Reader then
        local arc = Archiver.Reader:new()
        if not arc:open(zip) then return nil, "cannot open the zip: " .. tostring(arc.err) end
        local err
        for entry in arc:iterate() do
            if not safe_entry(entry.path) then
                err = "unsafe path in the zip: " .. entry.path
                break
            end
            if entry.mode == "file" or entry.mode == "directory" then
                if not arc:extractToPath(entry.path, dest .. "/" .. entry.path) then
                    err = arc.err or ("cannot extract " .. entry.path)
                    break
                end
            end
        end
        err = err or arc.err
        arc:close()
        if err then return nil, err end
        return true
    end
    -- KOReader without libarchive: the system's unzip
    local list = io.popen("unzip -Z1 " .. shell_quote(zip) .. " 2>/dev/null")
    if list then
        for p in list:lines() do
            if not safe_entry(p) then
                list:close()
                return nil, "unsafe path in the zip: " .. p
            end
        end
        list:close()
    end
    local rc = os.execute("unzip -qo " .. shell_quote(zip) .. " -d " .. shell_quote(dest) .. " >/dev/null 2>&1")
    if rc ~= 0 and rc ~= true then return nil, "unzip failed" end
    return true
end

-- The plugin folder inside an unpacked zip: the zip's single top folder, or dir itself.
local function plugin_root(dir)
    if mode(dir .. "/main.lua") == "file" then return dir end
    local found
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." then
            if found or mode(dir .. "/" .. name) ~= "directory" then return nil end
            found = dir .. "/" .. name
        end
    end
    if found and mode(found .. "/main.lua") == "file" then return found end
    return nil
end

--- Unpacks a release zip next to plugin_dir, ready to replace it at the next start.
-- expected_version: the release's version; the zip's _meta.lua must say the same.
-- Returns the staged version, or nil and an error.
function M.stage(zip, plugin_dir, expected_version)
    local p = M.paths(plugin_dir)
    local tmp = p.staged .. ".part"
    M.removeTree(tmp)
    M.removeTree(p.staged)
    local ok, err = lfs.mkdir(tmp)
    if not ok then return nil, "cannot write next to " .. p.dir .. ": " .. tostring(err) end
    ok, err = M.unzip(zip, tmp)
    local root = ok and plugin_root(tmp)
    local version = root and M.readMetaVersion(root .. "/_meta.lua")
    if ok and not version then
        ok, err = nil, "The download is not an MDict plugin package."
    elseif ok and expected_version and M.compare(version, expected_version) ~= 0 then
        ok, err = nil, string.format("The download is version %s, not %s.", version, expected_version)
    end
    if ok then ok, err = os.rename(root, p.staged) end
    M.removeTree(tmp)
    if not ok then
        M.removeTree(p.staged)
        return nil, err
    end
    return version
end

--- The version of an update waiting to be moved in at the next start, or nil.
function M.stagedVersion(plugin_dir)
    local p = M.paths(plugin_dir)
    if mode(p.staged .. "/main.lua") ~= "file" then return nil end
    return M.readMetaVersion(p.staged .. "/_meta.lua")
end

--- At KOReader's start, before the plugin loads: moves a staged update into plugin_dir.
-- Returns true, old version, new version when it did. An update that is not newer than
-- the installed version (installed by hand meanwhile) is dropped.
function M.applyStaged(plugin_dir, log)
    log = log or function() end
    local p = M.paths(plugin_dir)
    if mode(p.staged .. ".part") then M.removeTree(p.staged .. ".part") end -- left by a killed download
    if mode(p.staged) ~= "directory" then return false end
    local new = M.stagedVersion(plugin_dir)
    local cur = M.readMetaVersion(p.dir .. "/_meta.lua")
    if not new or (cur and M.compare(new, cur) <= 0) then
        log("MDict: dropping a downloaded update that is not newer:", new, "installed:", cur)
        M.removeTree(p.staged)
        return false
    end
    M.removeTree(p.old)
    local ok, err = os.rename(p.dir, p.old)
    if not ok then
        log("MDict: cannot move the old version aside:", err)
        return false
    end
    ok, err = os.rename(p.staged, p.dir)
    if not ok then
        os.rename(p.old, p.dir)
        log("MDict: cannot move the update in:", err)
        return false
    end
    M.removeTree(p.old)
    log("MDict: updated from", cur, "to", new)
    return true, cur, new
end

return M
