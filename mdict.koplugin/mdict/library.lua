--[[--
Finds MDict dictionaries in the configured folders and hands out Dictionary
objects. Titles are read from the file headers and cached by size and mtime,
so a rescan does not reopen every file.
]]

local Dictionary = require("mdict/dictionary")
local Reader = require("mdict/reader")
local fs = require("mdict/fs")
local json = require("mdict/json")

local Library = {}
Library.__index = Library

--- o: dirs (list of folders), cache_dir, builder (index builder, see Dictionary), depth
function Library.new(o)
    local self = setmetatable(o, Library)
    self.dicts = {}
    self.by_title, self.by_id, self.by_path = {}, {}, {}
    self.title_cache_path = self.cache_dir .. "/titles.json"
    return self
end

function Library:_loadTitleCache()
    local data = fs.readAll(self.title_cache_path)
    local ok, t = pcall(json.decode, data or "{}")
    return ok and type(t) == "table" and t or {}
end

--- Scans the folders. Returns the list of dictionaries, ordered by title.
-- reserved: names already used by other dictionaries (StarDict), to keep titles unique.
function Library:scan(reserved)
    reserved = reserved or {}
    local cache = self:_loadTitleCache()
    local new_cache, dirty = {}, false
    local found, seen = {}, {}
    self.unreadable = {} -- { path, error } for files whose header could not be read
    for _, dir in ipairs(self.dirs) do
        if fs.isDir(dir) then
            fs.walk(dir, "%.[Mm][Dd][Xx]$", function(path)
                if seen[path] then return end
                seen[path] = true
                local size, mtime = fs.stat(path)
                local c = cache[path]
                local title
                if c and c.size == size and c.mtime == mtime then
                    -- cleaned again: older versions cached a title written as HTML as it was
                    title = Reader.cleanTitle(c.title) or ""
                else
                    local h, err = Reader.peekHeader(path)
                    if not h then
                        require("logger").warn("MDict: cannot read", path, err)
                        self.unreadable[#self.unreadable + 1] = { path = path, error = tostring(err) }
                        return
                    end
                    title = h.title or ""
                    dirty = true
                end
                new_cache[path] = { size = size, mtime = mtime, title = title }
                if title == "" then title = fs.basename(path):gsub("%.[Mm][Dd][Xx]$", "") end
                found[#found + 1] = { path = path, title = title, root = dir }
            end, self.depth or 4)
        end
    end
    for path in pairs(cache) do
        if not new_cache[path] then dirty = true end
    end
    if dirty then
        fs.mkdirp(self.cache_dir)
        fs.writeAtomic(self.title_cache_path, json.encode(new_cache))
    end

    -- unique titles: same-named dictionaries get their file name appended
    local count = {}
    for _, f in ipairs(found) do count[f.title] = (count[f.title] or 0) + 1 end
    local old = self.by_path
    self.dicts, self.by_title, self.by_id, self.by_path = {}, {}, {}, {}
    for _, f in ipairs(found) do
        local title = f.title
        if count[title] > 1 or reserved[title] then
            title = string.format("%s (%s)", title, fs.basename(f.path))
        end
        local d = old[f.path]
        if d and d.title == title then
            d.mdd_paths = Dictionary.findMdds(f.path)
        else
            if d then d:close() end
            d = Dictionary.new({ path = f.path, title = title, root = f.root, cache_dir = self.cache_dir,
                builder = self.builder })
        end
        self.dicts[#self.dicts + 1] = d
        self.by_title[title] = d
        self.by_id[d.id] = d
        self.by_path[f.path] = d
    end
    for path, d in pairs(old) do
        if not self.by_path[path] then d:close() end
    end
    table.sort(self.dicts, function(a, b) return a.title < b.title end)
    return self.dicts
end

function Library:byTitle(title) return self.by_title[title] end
function Library:byId(id) return self.by_id[id] end

function Library:closeAll()
    for _, d in ipairs(self.dicts) do d:close() end
end

--- Removes extracted resources beyond max_bytes, least recently used first.
function Library:pruneResources(max_bytes)
    local files = fs.listFiles(self.cache_dir .. "/res")
    local total = 0
    for _, f in ipairs(files) do total = total + f.size end
    if total <= max_bytes then return 0 end
    table.sort(files, function(a, b) return a.atime < b.atime end)
    local removed = 0
    for _, f in ipairs(files) do
        if total <= max_bytes * 0.8 then break end
        if os.remove(f.path) then
            total = total - f.size
            removed = removed + 1
        end
    end
    return removed
end

return Library
