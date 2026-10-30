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
        -- the index status text lists every dictionary, and the files that could not be read
        local UIManager = require("ui/uimanager")
        local show = UIManager.show
        local shown
        UIManager.show = function(_, w) shown = w end
        lib.unreadable = { { path = "/dicts/broken.mdx", error = "bad header" } }
        find(plugin:menuItems(), "Index status").callback()
        UIManager.show = show
        assert.truthy(shown.text:find("Basic Test: ", 1, true))
        assert.truthy(shown.text:find("broken.mdx: cannot read (bad header)", 1, true))
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
