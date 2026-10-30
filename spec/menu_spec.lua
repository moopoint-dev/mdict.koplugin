--[[
Builds the plugin's menus against KOReader's frontend (needs KOREADER_FRONTEND),
and checks that the settings they write are the ones the renderer reads.
]]
local helper = require("spec.helper")
local frontend = os.getenv("KOREADER_FRONTEND")

if not frontend then
    describe("menus", function()
        pending("set KOREADER_FRONTEND to run")
    end)
    return
end

package.path = helper.root .. "/spec/koreader/?.lua;" .. package.path .. ";" .. frontend .. "/?.lua"
local store = {}
_G.G_reader_settings = {
    readSetting = function(_, k, default) if store[k] == nil then return default end return store[k] end,
    saveSetting = function(_, k, v) store[k] = v end,
    isFalse = function() return false end,
    isTrue = function() return false end,
    nilOrTrue = function() return true end,
}
_G.G_defaults = { readSetting = function() return nil end }

describe("menus", function()
    local MDict, Library
    setup(function()
        package.loaded["ui/widget/infomessage"] = { new = function(_, o) return o end }
        package.loaded["mdict/indexer"] = { status = function() return nil end }
        package.loaded["ui/widget/confirmbox"] = { new = function(_, o) return o end }
        package.loaded["ui/widget/notification"] = { new = function(_, o) return o end }
        package.loaded["ui/widget/menu"] = { new = function(_, o) return o end, onCloseWidget = function() end }
        package.loaded["datastorage"] = { getDataDir = function() return helper.tmpdir("menu-data") end }
        package.loaded["fontlist"] = {
            fontinfo = {
                ["/fonts/A.ttf"] = { { name = "Alpha" } },
                ["/fonts/A-Bold.ttf"] = { { name = "Alpha", bold = true } },
                ["/fonts/A-It.ttf"] = { { name = "Alpha", italic = true } },
                ["/fonts/B.ttc"] = { { name = "Beta" }, { name = "Beta UI" } },
            },
            getFontList = function() end,
        }
        Library = require("mdict/library")
        MDict = require("main")
    end)

    local function find(items, text)
        for _, it in ipairs(items) do
            local t = it.text or (it.text_func and it.text_func())
            if t and t:find(text, 1, true) then return it end
        end
        error("no menu item " .. text)
    end

    it("writes display and per-dictionary settings", function()
        local lib = Library.new({ dirs = { helper.fixtures() }, cache_dir = helper.tmpdir("menu-lib") })
        lib:scan()
        MDict._state.library = lib
        local plugin = setmetatable({}, { __index = MDict })
        local items = plugin:displayItems()
        find(find(items, "Text size").sub_item_table, "125 %").callback()
        assert.equal(1.25, store.mdict.zoom)
        local font = find(items, "Font").sub_item_table
        local families = find(font, "My font:").sub_item_table_func()
        assert.equal(2, #families)
        find(families, "Alpha").callback()
        assert.same({ name = "Alpha", file = "/fonts/A.ttf", bold_file = "/fonts/A-Bold.ttf",
            italic_file = "/fonts/A-It.ttf", scope = "all" }, store.mdict.user_font)
        find(font, "Latin").callback()
        assert.equal("latin", store.mdict.user_font.scope)
        find(font, "Dictionary fonts only").callback()
        assert.is_nil(store.mdict.user_font.scope)
        find(items, "Render entries").callback()
        assert.equal("mupdf", store.mdict.renderer)
        find(items, "Render entries").callback()
        assert.is_nil(store.mdict.renderer)
        find(find(items, "E-ink").sub_item_table, "Off").callback()
        assert.is_false(store.mdict.eink)

        local d = lib:byTitle("Basic Test")
        local per = find(plugin:dictSettingsItems(), "Basic Test").sub_item_table
        find(find(per, "Writing direction").sub_item_table, "Vertical").callback()
        find(find(per, "Page layout").sub_item_table, "Slices").callback()
        local Manager = require("renderers/manager")
        assert.equal("vertical", Manager.dictSetting(store.mdict, d.id, "writing", "auto"))
        assert.equal("slices", Manager.dictSetting(store.mdict, d.id, "pagination", "auto"))
        find(find(per, "Writing direction").sub_item_table, "Automatic").callback()
        assert.equal("auto", Manager.dictSetting(store.mdict, d.id, "writing", "auto"))
        -- the dictionary list has a row per dictionary with its index state, and the files
        -- that could not be read; a row opens the dictionary's details
        local UIManager = require("ui/uimanager")
        local show = UIManager.show
        local shown = {}
        UIManager.show = function(_, w) shown[#shown + 1] = w end
        lib.unreadable = { { path = "/dicts/broken.mdx", error = "bad header" } }
        find(plugin:menuItems(), "Index status").callback()
        local list = shown[1]
        assert.equal("MDict dictionaries (" .. #lib.dicts .. ")", list.title)
        local row = find(list.item_table, "Basic Test")
        assert.truthy(row.mandatory)
        local last = list.item_table[#list.item_table]
        assert.equal("broken.mdx", last.text)
        assert.equal("cannot read", last.mandatory)
        row.callback()
        UIManager.show = show
        assert.truthy(shown[2].text:find("Basic Test\n", 1, true))
        assert.truthy(shown[2].text:find("File: basic.mdx", 1, true))
        assert.truthy(shown[2].text:find("Resource files: ", 1, true))
        -- the list follows index builds while it is shown
        local DictList = require("widgets/dictlist")
        local switched
        list.switchItemTable = function(_, t, rows) switched = { title = t, items = rows } end
        MDict.onIndexChange({ path = "/x.mdx", title = "X" }, "done")
        assert.equal(list.title, switched.title)
        assert.equal(#list.item_table, #switched.items)
        DictList.shown = nil
    end)

    it("describes index states in the dictionary list", function()
        local DictList = require("widgets/dictlist")
        local Indexer = package.loaded["mdict/indexer"]
        local d = { path = "/d/a.mdx", title = "A", indexStates = function() return {} end,
            storedIndexState = function() return nil end }
        assert.equal("not opened", (DictList.status(d)))
        Indexer.queue = { { path = "/d/a.mdx" } }
        assert.equal("waiting", (DictList.status(d)))
        Indexer.queue = nil
        d.storedIndexState = function() return "sidecar" end
        assert.equal("ready", (DictList.status(d)))
        d.indexStates = function() return { { state = "file-order (unverified)" } } end
        assert.equal("checking", (DictList.status(d)))
        local status = Indexer.status
        Indexer.status = function() return { path = "/d/a.mdx" }, 0.42 end
        assert.equal("indexing 42 %", (DictList.status(d)))
        Indexer.status = status
        d.error = "bad header"
        assert.equal("error", (DictList.status(d)))
    end)

    it("says when a rebuild of all indexes is done", function()
        local lib = Library.new({ dirs = { helper.fixtures() }, cache_dir = helper.tmpdir("menu-reindex") })
        lib:scan()
        MDict._state.library = lib
        local Indexer = package.loaded["mdict/indexer"]
        local busy = true
        Indexer.busy = function() return busy end
        Indexer.stopAll = function() end
        local UIManager = require("ui/uimanager")
        local show = UIManager.show
        local shown = {}
        UIManager.show = function(_, w) shown[#shown + 1] = w end
        local plugin = setmetatable({}, { __index = MDict })
        find(plugin:menuItems(), "Rebuild indexes").callback()
        shown[1].ok_callback()
        while #UIManager.tasks > 0 do UIManager:runTasks() end
        -- every dictionary has been opened, and a build is still running
        assert.equal(1, #shown)
        busy = false
        MDict.onIndexChange({ path = "/x.mdx", title = "X" }, "done")
        MDict.onIndexChange({ path = "/y.mdx", title = "Y" }, "done")
        UIManager.show = show
        assert.equal(2, #shown)
        assert.equal("MDict: indexes rebuilt.", shown[2].text)
    end)
end)
