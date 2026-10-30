--[[--
The plugin's list of MDict dictionaries: one row per dictionary with the state
of its index, sorted by title, and a page of details when a row is tapped.
Files that could not be read are listed at the end.
]]

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template
local fs = require("mdict/fs")

local DictList = {}

local function megabytes(bytes)
    local mb = (bytes or 0) / (1024 * 1024)
    return mb < 10 and string.format("%.1f MB", mb) or string.format("%d MB", math.floor(mb + 0.5))
end

local function queued(path)
    local Indexer = require("mdict/indexer")
    for __, job in ipairs(Indexer.queue or {}) do
        if job.path == path then return true end
    end
    return false
end

--- The state of a dictionary's index: a short label for the list and a sentence for its details.
function DictList.status(d)
    if d.error then return _("error"), d.error end
    local job, fraction = require("mdict/indexer").status()
    if job and job.path == d.path then
        local pct = math.floor((fraction or 0) * 100)
        return T(_("indexing %1 %"), pct), T(_("Building its index: %1 % done."), pct)
    end
    local states = d:indexStates()
    local s = states[1] and states[1].state
    if not s then
        local stored = d:storedIndexState()
        if stored == "sidecar" then
            return _("ready"), _("Ready: it has an index file. Not opened yet.")
        elseif stored == "file-order" then
            return _("ready"), _("Ready: its keys are already sorted. Not opened yet.")
        elseif queued(d.path) then
            return _("waiting"), _("Waiting for its index to be built.")
        end
        return _("not opened"), _("Not opened yet. Its index is checked or built when it is first used.")
    end
    if s == "sidecar" then return _("ready"), _("Ready: it has an index file.") end
    if s == "file-order" then return _("ready"), _("Ready: its keys are already sorted.") end
    if s == "memory" then return _("ready"), _("Ready: small enough to be indexed in memory.") end
    if s == "file-order (unverified)" then
        return _("checking"), _("Ready while its key order is being checked.")
    end
    if s == "indexing" then
        return _("waiting"), _("Waiting for its index to be built. Lookups are slower until then.")
    end
    if s == "index failed" then
        return _("failed"), _("Its index could not be built. Rebuild indexes to try again.")
    end
    return s, s
end

--- The details shown when a row is tapped.
function DictList.details(d)
    local lines = { d.title, "" }
    local long = select(2, DictList.status(d))
    lines[#lines + 1] = long
    lines[#lines + 1] = ""
    lines[#lines + 1] = T(_("File: %1"), fs.basename(d.path))
    lines[#lines + 1] = T(_("Folder: %1"), fs.dirname(d.path))
    local size = fs.stat(d.path) or 0
    lines[#lines + 1] = T(_("Size: %1"), megabytes(size))
    local mdds = d.mdd_paths or {}
    if #mdds > 0 then
        local res = 0
        for __, p in ipairs(mdds) do res = res + (fs.stat(p) or 0) end
        lines[#lines + 1] = T(_("Resource files: %1 (%2)"), #mdds, megabytes(res))
    else
        lines[#lines + 1] = _("Resource files: none")
    end
    if d.mdx and d.mdx.num_entries then
        lines[#lines + 1] = T(_("Entries: %1"), d.mdx.num_entries)
    end
    local overrides = {}
    for __, ext in ipairs({ ".css", ".lua" }) do
        for ___, p in ipairs(d:_overrideFiles(ext)) do
            if fs.isFile(p) then overrides[#overrides + 1] = p end
        end
    end
    if #overrides > 0 then
        lines[#lines + 1] = _("Override files:")
        for __, p in ipairs(overrides) do lines[#lines + 1] = "  " .. p end
    end
    return table.concat(lines, "\n")
end

--- The rows: { text, mandatory, callback } per dictionary, then the files that could not be read.
function DictList.items(library)
    local dicts = {}
    for __, d in ipairs(library.dicts) do dicts[#dicts + 1] = d end
    table.sort(dicts, function(a, b) return a.title:lower() < b.title:lower() end)
    local items = {}
    for __, d in ipairs(dicts) do
        items[#items + 1] = {
            text = d.title,
            mandatory = (DictList.status(d)),
            callback = function()
                UIManager:show(InfoMessage:new{ text = DictList.details(d), show_icon = false })
            end,
        }
    end
    for __, u in ipairs(library.unreadable or {}) do
        items[#items + 1] = {
            text = fs.basename(u.path),
            mandatory = _("cannot read"),
            dim = true,
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = T(_("%1\n\nCannot be read: %2\n\nFolder: %3"), fs.basename(u.path), u.error,
                        fs.dirname(u.path)),
                    show_icon = false,
                })
            end,
        }
    end
    return items
end

local function title(library)
    return T(_("MDict dictionaries (%1)"), #library.dicts)
end

local function subtitle()
    local job, fraction = require("mdict/indexer").status()
    if job then
        return T(_("Indexing %1: %2 %"), job.title or fs.basename(job.path), math.floor((fraction or 0) * 100))
    end
    return ""
end

--- Shows the list full screen. Returns the menu.
function DictList.show(library)
    local Menu = require("ui/widget/menu")
    local items = DictList.items(library)
    if #items == 0 then
        items = { {
            text = _("No MDict dictionaries found. Put .mdx files (with their .mdd files) in a dictionary folder."),
            select_enabled = false,
        } }
    end
    local menu = Menu:new{
        title = title(library),
        subtitle = subtitle(),
        item_table = items,
        items_max_lines = 3,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
    }
    function menu:onCloseWidget()
        if DictList.shown == self then DictList.shown = nil end
        return Menu.onCloseWidget(self)
    end
    DictList.shown, DictList.library = menu, library
    UIManager:show(menu)
    return menu
end

--- Updates the list while it is shown: when an index build starts or ends, and every few
-- seconds while one makes progress.
function DictList.refresh(event)
    local menu, library = DictList.shown, DictList.library
    if not menu or not library then return end
    local now = os.time()
    if event == "progress" and DictList.refreshed and now - DictList.refreshed < 3 then return end
    DictList.refreshed = now
    menu:switchItemTable(title(library), DictList.items(library), -1, nil, subtitle())
end

return DictList
