--[[--
MDict dictionaries for KOReader.

Dictionaries (.mdx with their .mdd files) are found in KOReader's dictionary
folders (data/dict, data/dict_ext) and in folders chosen in the menu. They
appear in KOReader's own dictionary list and popup.

@module koplugin.mdict
]]

-- An update downloaded in an earlier session waits next to this folder (see mdict/update.lua).
-- It is moved in here, before any of the plugin's modules are loaded, and its main.lua runs instead.
do
    local dir = debug.getinfo(1, "S").source:match("^@(.+)/main%.lua$")
    local load_update = dir and loadfile(dir .. "/mdict/update.lua")
    if load_update then
        local ok, applied, from, to = pcall(function()
            return load_update().applyStaged(dir, function(...) require("logger").info(...) end)
        end)
        if not ok then require("logger").warn("MDict: applying an update failed:", applied) end
        if ok and applied then
            -- lets the new version say it was updated, even if KOReader was killed before saving settings
            package.loaded["mdict/applied_update"] = { from = from, to = to }
            return dofile(dir .. "/main.lua")
        end
    end
end

local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Integration = require("mdict/integration")
local Library = require("mdict/library")
local Updater = require("mdict/updater")
local fs = require("mdict/fs")

local SETTINGS_KEY = "mdict"

-- Shared by the reader's and the file manager's plugin instances.
local state = {
    library = nil,
    settings = nil,
    prepared = false,
}

local MDict = WidgetContainer:extend{
    name = "mdict",
    is_doc_only = false,
}
MDict._state = state -- for the specs
Updater.setup(state)

local function settings()
    if not state.settings then
        state.settings = G_reader_settings:readSetting(SETTINGS_KEY) or {}
        state.settings.folders = state.settings.folders or {}
    end
    return state.settings
end

-- flush: write the settings file now (KOReader otherwise writes it on exit or when put in the background)
local function save_settings(flush)
    G_reader_settings:saveSetting(SETTINGS_KEY, state.settings)
    if flush and G_reader_settings.flush then G_reader_settings:flush() end
end
state.saveSettings = save_settings

local function dict_dirs()
    local data = G_defaults:readSetting("STARDICT_DATA_DIR") or os.getenv("STARDICT_DATA_DIR")
        or DataStorage:getDataDir() .. "/data/dict"
    local dirs = { data, data .. "_ext" }
    for _, f in ipairs(settings().folders) do dirs[#dirs + 1] = f end
    return dirs
end

function MDict.cacheDir()
    return DataStorage:getDataDir() .. "/cache/mdict"
end
state.cacheDir = MDict.cacheDir

function MDict:init()
    local ReaderDictionary = require("apps/reader/modules/readerdictionary")
    if not state.library then
        local Indexer = require("mdict/indexer")
        Indexer.on_change = MDict.onIndexChange
        state.promoteIndexes = Indexer.promote
        fs.mkdirp(MDict.cacheDir())
        state.library = Library.new({ dirs = dict_dirs(), cache_dir = MDict.cacheDir(), builder = Indexer.build })
        state.library:scan(Integration.stardictNames(ReaderDictionary))
        logger.info("MDict: found", #state.library.dicts, "dictionaries")
    end
    state.plugin = self
    local Manager = require("renderers/manager")
    state.settings = settings()
    state.renderer = function() return Manager.get(state) end
    state.widget = function(dql, r) return Manager.widget(state, dql, r) end
    state.prefetch = function(dql) return Manager.prefetch(state, dql) end
    state.dropPrefetch = function(dql) return Manager.dropPrefetch(dql) end
    state.keep = function(dql, w, r) return Manager.keep(state, dql, w, r) end
    state.playSound = function(dictionary, path, sources)
        local ok, msg = Manager.playSound(state, dictionary, path, sources)
        if not ok and msg then
            local Notification = require("ui/widget/notification")
            UIManager:show(Notification:new{ text = msg })
        end
    end
    Integration.install(state)
    if self.ui and self.ui.dictionary then
        Integration.syncIfos(ReaderDictionary, self.ui.dictionary)
    end
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    if not state.prepared then
        state.prepared = true
        UIManager:scheduleIn(5, function() MDict.prepareIndexes() end)
        Updater.announceVersion()
        UIManager:scheduleIn(60, function() Updater.autoCheck("start") end)
    end
end

-- Automatic update checks (at most daily, only when already connected). Handlers return
-- nothing, so the events go on to the other modules.
function MDict:onNetworkConnected()
    UIManager:scheduleIn(5, function() Updater.autoCheck("network") end)
end

function MDict:onResume()
    UIManager:scheduleIn(30, function() Updater.autoCheck("resume") end)
end

--- Tells the reader when a dictionary they looked something up in has finished indexing,
-- and about every failed build.
function MDict.onIndexChange(job, event)
    local waiting = state.waiting_for_index or {}
    local text
    if event == "failed" then
        text = T(_("MDict: indexing %1 failed. See Index status."), job.title)
    elseif event == "done" and waiting[job.path] then
        text = T(_("MDict: %1 is ready."), job.title)
    end
    if event == "done" or event == "failed" then waiting[job.path] = nil end
    if text then
        local Notification = require("ui/widget/notification")
        UIManager:show(Notification:new{ text = text })
    end
    if event == "done" or event == "failed" then MDict.checkRebuilt() end
    if package.loaded["widgets/dictlist"] then package.loaded["widgets/dictlist"].refresh(event) end
end

--- After "Rebuild indexes": says so once every dictionary is queued and the last build is done.
function MDict.checkRebuilt()
    if state.rebuilding ~= "building" or require("mdict/indexer").busy() then return end
    state.rebuilding = nil
    local Notification = require("ui/widget/notification")
    UIManager:show(Notification:new{ text = _("MDict: indexes rebuilt.") })
end

--- Opens each dictionary once in the background so missing indexes start building.
-- on_queued: called once every dictionary has been opened (its builds queued).
function MDict.prepareIndexes(on_queued)
    local dicts = {}
    for _, d in ipairs(state.library.dicts) do
        if not Integration.isDisabled(d) then dicts[#dicts + 1] = d end
    end
    local i = 0
    local function step()
        i = i + 1
        local d = dicts[i]
        if not d then
            if on_queued then on_queued() end
            return
        end
        local ok, err = pcall(d.prepareIndexes, d)
        if not ok then logger.warn("MDict: cannot open", d.path, err) end
        if not d.recently_used then d:close() end
        UIManager:scheduleIn(0.2, step)
    end
    step()
end

function MDict:rescan()
    local ReaderDictionary = require("apps/reader/modules/readerdictionary")
    state.library.dirs = dict_dirs()
    state.library:scan(Integration.stardictNames(ReaderDictionary))
    if self.ui and self.ui.dictionary then
        Integration.syncIfos(ReaderDictionary, self.ui.dictionary)
    end
    MDict.prepareIndexes()
end

function MDict:addToMainMenu(menu_items)
    menu_items.mdict = {
        text = _("MDict dictionaries"),
        sorting_hint = "search_settings",
        sub_item_table_func = function() return self:menuItems() end,
    }
end

function MDict:menuItems()
    local items = {
        {
            text_func = function()
                return T(_("Dictionaries found: %1"), #state.library.dicts)
            end,
            keep_menu_open = true,
            callback = function()
                require("widgets/dictlist").show(state.library)
            end,
        },
        {
            text = _("Dictionary folders"),
            sub_item_table_func = function() return self:folderItems() end,
        },
        {
            text = _("Display"),
            sub_item_table_func = function() return self:displayItems() end,
        },
        {
            text = _("Dictionary settings"),
            enabled_func = function() return #state.library.dicts > 0 end,
            sub_item_table_func = function() return self:dictSettingsItems() end,
        },
        {
            text = _("Rescan dictionaries"),
            keep_menu_open = true,
            callback = function()
                self:rescan()
                UIManager:show(InfoMessage:new{ text = T(_("Found %1 MDict dictionaries."), #state.library.dicts),
                    timeout = 2 })
            end,
        },
        {
            text = _("Index status"),
            keep_menu_open = true,
            callback = function()
                require("widgets/dictlist").show(state.library)
            end,
        },
        {
            text = _("Rebuild indexes"),
            keep_menu_open = true,
            callback = function()
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = _("Delete the MDict indexes and build them again?\n\n"
                        .. "Large dictionaries answer lookups again once their index is rebuilt."),
                    ok_text = _("Rebuild"),
                    ok_callback = function()
                        require("mdict/indexer").stopAll()
                        state.library:closeAll()
                        fs.removeTree(MDict.cacheDir() .. "/idx")
                        state.rebuilding = "queuing"
                        MDict.prepareIndexes(function()
                            state.rebuilding = "building"
                            MDict.checkRebuilt()
                        end)
                    end,
                })
            end,
        },
        {
            text = _("Clear extracted resources"),
            keep_menu_open = true,
            callback = function()
                fs.removeTree(MDict.cacheDir() .. "/res")
                UIManager:show(InfoMessage:new{ text = _("Extracted resources cleared."), timeout = 2 })
            end,
            separator = true,
        },
        Updater.menuItem(),
    }
    if require("device"):isKindle() then
        -- a read-only report for the Kindle renderer under development (mdict/kindlecheck.lua)
        items[#items + 1] = {
            text = _("Kindle browser check"),
            keep_menu_open = true,
            callback = function() require("mdict/kindlecheck").show(Updater.version()) end,
        }
        -- starts Amazon's browser once to see whether it can lay out entries (mdict/kindletest.lua)
        items[#items + 1] = {
            text = _("Kindle browser test (experimental)"),
            keep_menu_open = true,
            callback = function() require("mdict/kindletest").show(Updater.version()) end,
        }
    end
    return items
end

-- Font families KOReader knows (its own fonts folder and the system's), with their regular,
-- bold, italic and bold italic files.
local function font_families()
    local FontList = require("fontlist")
    FontList:getFontList()
    local by_name, list = {}, {}
    for path, faces in pairs(FontList.fontinfo or {}) do
        -- the WebView loads the first face of a collection (.ttc)
        local f = type(faces) == "table" and faces[1]
        if f and f.name then
            local fam = by_name[f.name]
            if not fam then
                fam = { name = f.name }
                by_name[f.name] = fam
                list[#list + 1] = fam
            end
            local key = (f.bold and "bold_" or "") .. (f.italic and "italic_" or "") .. "file"
            fam[key] = fam[key] or path
        end
    end
    local out = {}
    for __, fam in ipairs(list) do if fam.file then out[#out + 1] = fam end end
    table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
    return out
end

local function radio(text, get, value, set, help)
    return {
        text = text,
        help_text = help,
        radio = true,
        checked_func = function() return get() == value end,
        callback = function()
            set(value)
            save_settings()
        end,
    }
end

function MDict:displayItems()
    local Manager = require("renderers/manager")
    local s = settings()
    local function setter(key) return function(v) s[key] = v end end
    local function getter(key) return function() return s[key] end end
    local zoom_items = {}
    for __, z in ipairs({ 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75 }) do
        zoom_items[#zoom_items + 1] = radio(string.format("%d %%", z * 100),
            function() return s.zoom or 1 end, z, setter("zoom"))
    end
    local font = function() return s.user_font or {} end
    local scope_items = {}
    for __, c in ipairs({
        { nil, _("Dictionary fonts only") },
        { "all", _("My font for all text") },
        { "latin", _("My font for Latin text") },
        { "cjk", _("My font for Japanese and Chinese text") },
    }) do
        scope_items[#scope_items + 1] = radio(c[2], function() return font().scope end, c[1], function(v)
            s.user_font = s.user_font or {}
            s.user_font.scope = v
        end)
    end
    scope_items[#scope_items].separator = true
    scope_items[#scope_items + 1] = {
        text_func = function()
            return T(_("My font: %1"), font().name or _("not chosen"))
        end,
        sub_item_table_func = function()
            local items = {}
            for __, fam in ipairs(font_families()) do
                items[#items + 1] = {
                    text = fam.name,
                    radio = true,
                    checked_func = function() return font().name == fam.name end,
                    callback = function()
                        s.user_font = s.user_font or {}
                        s.user_font.name, s.user_font.file = fam.name, fam.file
                        s.user_font.bold_file, s.user_font.italic_file = fam.bold_file, fam.italic_file
                        s.user_font.bold_italic_file = fam.bold_italic_file
                        s.user_font.scope = s.user_font.scope or "all"
                        save_settings()
                    end,
                }
            end
            return items
        end,
    }
    local render_item = {
        text = _("Render entries with the WebView"),
        help_text = _("Lays entries out as a web browser does, so they look as their dictionary intends. "
            .. "When off, KOReader's built-in HTML renderer is used."),
        checked_func = function() return s.renderer ~= "mupdf" end,
        callback = function()
            s.renderer = s.renderer ~= "mupdf" and "mupdf" or nil
            save_settings()
            Manager.shutdown()
            Manager.failed = nil
        end,
    }
    if require("device"):isKindle() then
        -- off by default: it starts Amazon's browser in the background (renderers/kindle_browser.lua)
        render_item = {
            text = _("Render entries with the Kindle's browser (experimental)"),
            help_text = _("Lays entries out with the web browser of the Kindle's firmware (5.16 to 5.18), so they "
                .. "look as their dictionary intends, with vertical text and the dictionary's scripts. The first "
                .. "lookup starts the browser, which takes about 20 seconds on a Paperwhite; it then stays open, "
                .. "also while the Kindle sleeps, and closes after twenty minutes without a lookup. It uses about "
                .. "70 MB of memory, starts only when 80 MB are free, and is closed if memory runs low later. "
                .. "When off, or once the browser has failed, KOReader's built-in HTML renderer is used (until "
                .. "KOReader restarts, or this is turned off and on). If the Kindle behaves oddly, turn this off "
                .. "and restart the Kindle."),
            checked_func = function() return s.kindle_browser == true end,
            callback = function()
                s.kindle_browser = not s.kindle_browser or nil
                save_settings()
                Manager.shutdown()
                Manager.failed, Manager.notified = nil, false
            end,
        }
    end
    return {
        render_item,
        {
            text_func = function() return T(_("Text size: %1 %"), math.floor((s.zoom or 1) * 100 + 0.5)) end,
            help_text = _("Relative to KOReader's dictionary font size."),
            sub_item_table = zoom_items,
        },
        {
            text = _("Font"),
            sub_item_table = scope_items,
        },
        {
            text = _("E-ink mode"),
            sub_item_table = {
                radio(_("Automatic"), getter("eink"), nil, setter("eink"),
                    _("On for e-ink screens: black text, no tinted backgrounds.")),
                radio(_("On"), getter("eink"), true, setter("eink")),
                radio(_("Off"), getter("eink"), false, setter("eink")),
            },
        },
        {
            text = _("Flash the screen on page turns"),
            help_text = _("Each page turn in an entry fully refreshes the popup, which clears the ghosts of earlier "
                .. "pages that e-ink screens can show, at the cost of a flash."),
            enabled_func = function() return require("device"):hasEinkScreen() end,
            checked_func = function() return s.flash_page_turns == true end,
            callback = function()
                s.flash_page_turns = not s.flash_page_turns or nil
                save_settings()
            end,
        },
        {
            text = _("Reverse page turn swipes in vertical text"),
            help_text = _("By default, swiping from left to right turns to the next page of a vertical entry."),
            checked_func = function() return s.invert_vertical_swipes == true end,
            callback = function()
                s.invert_vertical_swipes = not s.invert_vertical_swipes or nil
                save_settings()
            end,
        },
        {
            text = _("Prepare the next result in advance"),
            help_text = _("While you read a result in the dictionary popup, the next MDict result is laid out "
                .. "in the background, so it shows at once. Turn off to save memory and battery."),
            checked_func = function() return s.prefetch ~= false end,
            callback = function()
                if s.prefetch == false then s.prefetch = nil else s.prefetch = false end
                save_settings()
            end,
        },
    }
end

-- Radio items for one per-dictionary setting; nil (the first choice) means automatic.
local function choice_items(dict_id, key, choices, on_change)
    local items = {}
    for __, c in ipairs(choices) do
        items[#items + 1] = {
            text = c.text,
            help_text = c.help,
            radio = true,
            checked_func = function()
                local own = settings().dicts and settings().dicts[dict_id]
                return (own and own[key]) == c.value
            end,
            callback = function()
                local all = settings()
                all.dicts = all.dicts or {}
                all.dicts[dict_id] = all.dicts[dict_id] or {}
                all.dicts[dict_id][key] = c.value
                if next(all.dicts[dict_id]) == nil then all.dicts[dict_id] = nil end
                save_settings()
                if on_change then on_change() end
            end,
        }
    end
    return items
end

function MDict:dictSettingsItems()
    local items = {}
    for __, d in ipairs(state.library.dicts) do
        local id = d.id
        items[#items + 1] = {
            text = d.title,
            sub_item_table = {
                {
                    text = _("Writing direction"),
                    sub_item_table = choice_items(id, "writing", {
                        { text = _("Automatic"), help = _("Follow the direction the dictionary's own style sheet sets.") },
                        { text = _("Horizontal"), value = "horizontal" },
                        { text = _("Vertical (right to left)"), value = "vertical" },
                    }, function() require("renderers/manager").vertical_seen[id] = nil end),
                },
                {
                    text = _("Page layout"),
                    sub_item_table = choice_items(id, "pagination", {
                        { text = _("Automatic"),
                          help = _("Use columns, and switch to slices for entries columns would cut off.") },
                        { text = _("Columns"), value = "columns",
                          help = _("Flow the entry into pages. Lines and images are never split.") },
                        { text = _("Slices"), value = "slices",
                          help = _("Cut the entry as laid out on one long page, between lines. "
                              .. "Works with any layout; tall boxes and tables may be split.") },
                    }),
                },
            },
        }
    end
    return items
end

function MDict:folderItems()
    local items = {}
    for i, folder in ipairs(settings().folders) do
        items[#items + 1] = {
            text = folder,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = T(_("Stop looking for dictionaries in\n%1?"), folder),
                    ok_text = _("Remove"),
                    ok_callback = function()
                        table.remove(settings().folders, i)
                        save_settings()
                        self:rescan()
                        touchmenu_instance:updateItems()
                    end,
                })
            end,
        }
    end
    items[#items + 1] = {
        text = _("Add folder…"),
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local PathChooser = require("ui/widget/pathchooser")
            UIManager:show(PathChooser:new{
                select_file = false,
                show_files = false,
                path = G_reader_settings:readSetting("lastdir") or DataStorage:getDataDir(),
                onConfirm = function(dir)
                    table.insert(settings().folders, dir)
                    save_settings()
                    self:rescan()
                    touchmenu_instance:updateItems()
                end,
            })
        end,
    }
    return items
end

function MDict:onExit()
    require("renderers/manager").shutdown()
    if state.library then state.library:closeAll() end
end

return MDict
