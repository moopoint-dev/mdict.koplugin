--[[
Plugin updates: versions, GitHub's release answer, unpacking a release zip next to
the plugin, moving it in at start (main.lua's first lines), and the automatic check.
]]
local helper = require("spec.helper")
local Update = require("mdict/update")
local json = require("mdict/json")

local root = helper.root
local lfs = require("mdict/fs").lfs

local function sh(cmd)
    local ok = os.execute(cmd)
    assert(ok == 0 or ok == true, cmd)
end

local function write(path, data)
    local f = assert(io.open(path, "wb"))
    f:write(data)
    f:close()
end

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local d = f:read("*a")
    f:close()
    return d
end

local function meta(version)
    return 'local _ = require("gettext")\nreturn { fullname = _("MDict"), version = "' .. version .. '" }\n'
end

-- A plugins folder holding a copy of this repo's plugin, its _meta.lua set to version.
local function installed(version)
    local plugins = helper.tmpdir("update-plugins")
    sh(string.format("cp -R '%s/mdict.koplugin' '%s/'", root, plugins))
    write(plugins .. "/mdict.koplugin/_meta.lua", meta(version))
    return plugins, plugins .. "/mdict.koplugin"
end

-- The release zip of this repo's plugin (what tools/release.sh makes).
local function release_zip()
    local dir = helper.tmpdir("update-zip")
    local zip = dir .. "/mdict.koplugin-test.zip"
    sh(string.format("cd '%s' && zip -qr -X '%s' mdict.koplugin -x '*/.*'", root, zip))
    return zip
end

local REPO_VERSION = Update.readMetaVersion(root .. "/mdict.koplugin/_meta.lua")

local function sample_release(tag, extra)
    local r = {
        tag_name = tag,
        name = "mdict.koplugin " .. tag:sub(2),
        html_url = "https://github.com/" .. Update.REPO .. "/releases/tag/" .. tag,
        draft = false,
        prerelease = false,
        body = "## Highlights\r\n\r\n- **Faster** lookups, see `README`.\r\n- Appear in *Manage dictionaries*.",
        assets = {
            { name = "notes.txt", browser_download_url = "https://example.invalid/notes.txt", size = 3 },
            { name = "mdict.koplugin-" .. tag:sub(2) .. ".zip", state = "uploaded", size = 1234,
              digest = "sha256:ABCDEF0123", browser_download_url = "https://example.invalid/p.zip" },
        },
    }
    for k, v in pairs(extra or {}) do r[k] = v end
    return r
end

describe("update versions", function()
    it("parses and compares versions", function()
        assert.same({ 0, 2, 0 }, Update.parseVersion("v0.2.0"))
        assert.same({ 1, 10, pre = "rc.1" }, Update.parseVersion("1.10-rc.1"))
        assert.is_nil(Update.parseVersion("0.2."))
        assert.is_nil(Update.parseVersion("latest"))
        assert.is_nil(Update.parseVersion("1.2 beta"))
        assert.equal(1, Update.compare("v0.10.0", "0.9.9"))
        assert.equal(0, Update.compare("0.2", "v0.2.0"))
        assert.equal(-1, Update.compare("0.2.0-rc.1", "0.2.0"))
        assert.equal(-1, Update.compare("0.2.0-rc.1", "0.2.0-rc.2"))
        assert.is_nil(Update.compare("x", "0.1"))
    end)

    it("takes the version from _meta.lua only", function()
        assert.truthy(REPO_VERSION)
        assert.truthy(Update.parseVersion(REPO_VERSION))
        -- the release script reads the same line
        local f = io.popen(string.format("sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p' "
            .. "'%s/mdict.koplugin/_meta.lua'", root))
        assert.equal(REPO_VERSION, f:read("*l"))
        f:close()
    end)
end)

describe("update releases", function()
    it("reads GitHub's latest release", function()
        local rel = Update.releaseInfo(json.decode(json.encode(sample_release("v0.3.0"))))
        assert.equal("v0.3.0", rel.tag)
        assert.equal("0.3.0", rel.version)
        assert.same({ name = "mdict.koplugin-0.3.0.zip", url = "https://example.invalid/p.zip", size = 1234,
            sha256 = "abcdef0123" }, rel.asset)
        assert.equal("Highlights\n\n• Faster lookups, see README.\n• Appear in Manage dictionaries.",
            Update.plainNotes(rel.notes))
    end)

    it("skips drafts, pre-releases, odd tags and missing packages", function()
        assert.is_nil(Update.releaseInfo(sample_release("v0.3.0", { draft = true })))
        assert.is_nil(Update.releaseInfo(sample_release("v0.3.0", { prerelease = true })))
        assert.is_nil(Update.releaseInfo(sample_release("nightly")))
        assert.is_nil(Update.releaseInfo({ message = "Not Found" }))
        local rel = Update.releaseInfo(sample_release("v0.3.0", { assets = json.array({}) }))
        assert.is_nil(rel.asset)
        rel = Update.releaseInfo(sample_release("v0.3.0", { body = json.null }))
        assert.equal("", rel.notes)
    end)

    it("checks downloads by size and checksum", function()
        local p = helper.tmpdir("update-verify") .. "/f"
        write(p, "hello")
        assert.is_true(Update.verifyFile(p, 5))
        assert.is_nil((Update.verifyFile(p, 6)))
        assert.is_nil((Update.verifyFile(p .. "x", 5)))
    end)

    it("tries a download again when the connection stalls, and says so when it never works", function()
        local names = { "socket.http", "socket", "socketutil" }
        local saved = {}
        for _, n in ipairs(names) do saved[n] = package.loaded[n] end
        local calls, works_at, timeouts = 0, 3, {}
        package.loaded["socket"] = { skip = function(n, ...) return select(n + 1, ...) end }
        package.loaded["socketutil"] = { -- an older KOReader's: no describe_error
            set_timeout = function(_, b, t) timeouts[#timeouts + 1] = { b, t } return b, t end,
            reset_timeout = function() end,
            file_sink = function(f) return function(chunk) if chunk then f:write(chunk) end return 1 end end,
        }
        package.loaded["socket.http"] = { request = function(req)
            calls = calls + 1
            if calls < works_at then return nil, "wantread" end
            req.sink("hello")
            req.sink(nil)
            return 1, 200, {}, "HTTP/1.1 200 OK"
        end }
        local p = helper.tmpdir("update-retry") .. "/p.zip"
        assert.is_true(Update.download({ url = "https://example.invalid/p.zip", size = 5 }, p))
        assert.equal(3, calls)
        assert.same({ Update.DOWNLOAD_BLOCK_TIMEOUT, Update.DOWNLOAD_TOTAL_TIMEOUT }, timeouts[1])
        assert.is_true(Update.DOWNLOAD_BLOCK_TIMEOUT >= 30)
        calls, works_at = 0, 99
        local ok, err = Update.download({ url = "https://example.invalid/p.zip", size = 5 }, p)
        assert.is_nil(ok)
        assert.equal(Update.DOWNLOAD_TRIES, calls)
        assert.equal("The connection timed out (wantread).", err)
        assert.is_nil(io.open(p))
        for _, n in ipairs(names) do package.loaded[n] = saved[n] end
    end)
end)

describe("update install", function()
    it("unpacks a release next to the plugin, and moves it in at the next start", function()
        local plugins, dir = installed("0.1.0")
        local version = assert(Update.stage(release_zip(), dir, REPO_VERSION))
        assert.equal(REPO_VERSION, version)
        local p = Update.paths(dir)
        assert.equal(plugins .. "/.mdict.koplugin.update", p.staged)
        assert.equal(REPO_VERSION, Update.stagedVersion(dir))
        assert.is_nil(lfs.attributes(p.staged .. ".part"))
        -- the running version is untouched
        assert.equal("0.1.0", Update.readMetaVersion(dir .. "/_meta.lua"))

        local applied, old, new = Update.applyStaged(dir)
        assert.is_true(applied)
        assert.equal("0.1.0", old)
        assert.equal(REPO_VERSION, new)
        assert.equal(REPO_VERSION, Update.readMetaVersion(dir .. "/_meta.lua"))
        assert.equal(read(root .. "/mdict.koplugin/mdict/update.lua"), read(dir .. "/mdict/update.lua"))
        assert.is_nil(lfs.attributes(p.staged))
        assert.is_nil(lfs.attributes(p.old))
        assert.is_false(Update.applyStaged(dir))
    end)

    it("refuses packages that are not the release's version or not the plugin", function()
        local _, dir = installed("0.1.0")
        local version, err = Update.stage(release_zip(), dir, "9.9.9")
        assert.is_nil(version)
        assert.matches("not 9.9.9", err)
        assert.is_nil(Update.stagedVersion(dir))

        local zdir = helper.tmpdir("update-bad")
        sh(string.format("cd '%s' && mkdir x && echo hi > x/readme.txt && zip -qr bad.zip x", zdir))
        version, err = Update.stage(zdir .. "/bad.zip", dir, nil)
        assert.is_nil(version)
        assert.matches("not an MDict plugin", err)

        write(zdir .. "/broken.zip", "not a zip")
        assert.is_nil((Update.stage(zdir .. "/broken.zip", dir, nil)))
        assert.is_nil(lfs.attributes(Update.paths(dir).staged .. ".part"))
    end)

    it("drops a staged update that is not newer than the installed version", function()
        local _, dir = installed("0.1.0")
        assert(Update.stage(release_zip(), dir, REPO_VERSION))
        write(dir .. "/_meta.lua", meta("99.0"))
        assert.is_false(Update.applyStaged(dir))
        assert.equal("99.0", Update.readMetaVersion(dir .. "/_meta.lua"))
        assert.is_nil(Update.stagedVersion(dir))
    end)

    it("applies a staged update in main.lua before loading any plugin module", function()
        local _, dir = installed("0.1.0")
        local staged = Update.paths(dir).staged
        sh(string.format("mkdir -p '%s'", staged))
        write(staged .. "/_meta.lua", meta("0.9.0"))
        write(staged .. "/main.lua", 'return { marker = "new main", loaded = package.loaded["mdict/integration"] }')
        package.loaded["mdict/integration"] = nil
        local loaded_before = {}
        for k in pairs(package.loaded) do loaded_before[k] = true end
        local mod = dofile(dir .. "/main.lua")
        assert.equal("new main", mod.marker)
        assert.is_nil(mod.loaded)
        for k in pairs(package.loaded) do
            local ok = loaded_before[k] or k == "mdict/applied_update" or not k:match("^mdict/")
            assert.is_true(ok or false, "loaded " .. k)
        end
        assert.equal("0.9.0", Update.readMetaVersion(dir .. "/_meta.lua"))
        assert.is_nil(lfs.attributes(staged))
        assert.same({ from = "0.1.0", to = "0.9.0" }, package.loaded["mdict/applied_update"])
        package.loaded["mdict/applied_update"] = nil
    end)
end)

describe("update checks", function()
    local Updater, shown, scheduled, connected, store, top
    local release_json

    setup(function()
        package.loaded["ui/uimanager"] = {
            show = function(_, w) shown[#shown + 1] = w end,
            scheduleIn = function(_, s, f) scheduled[#scheduled + 1] = { s, f } end,
            getTopmostVisibleWidget = function() return top end,
            askForRestart = function(_, text) shown[#shown + 1] = { restart = text } end,
        }
        package.loaded["ui/network/manager"] = { isConnected = function() return connected end }
        package.loaded["ui/widget/confirmbox"] = { new = function(_, o) o.confirm = true return o end }
        package.loaded["ui/widget/infomessage"] = { new = function(_, o) o.info = true return o end }
        Updater = require("mdict/updater")
    end)

    before_each(function()
        shown, scheduled, connected, top = {}, {}, true, { name = "ReaderUI" }
        store = {}
        Updater.setup({
            settings = store,
            saveSettings = function() end,
            plugin = { version = "0.2.0", path = root .. "/mdict.koplugin" },
        })
        release_json = json.encode(sample_release("v0.3.0"))
        Updater.runInBackground = function(task, done) done("ok\n" .. release_json) end
    end)

    it("offers a newer release once a day, only when connected", function()
        connected = false
        Updater.autoCheck("start")
        assert.equal(0, #shown)
        assert.is_nil(store.update_checked)

        connected = true
        Updater.autoCheck("start")
        assert.equal(1, #shown)
        assert.is_true(shown[1].confirm)
        assert.matches("Installed: 0.2.0\nAvailable: 0.3.0", shown[1].text, 1, true)
        assert.truthy(store.update_checked)

        Updater.autoCheck("network")
        assert.equal(1, #shown)
        store.update_checked = os.time() - 25 * 3600
        Updater.autoCheck("resume")
        assert.equal(2, #shown)
    end)

    it("waits for the reader to be on top, honours Skip and the switch", function()
        top = { name = "DictQuickLookup" }
        Updater.autoCheck("start")
        assert.equal(0, #shown)
        assert.equal(1, #scheduled)
        top = { name = "filemanager" }
        scheduled[1][2]()
        assert.equal(1, #shown)

        -- Skip this version
        local skip = shown[1].other_buttons[1][2]
        assert.equal("Skip this version", skip.text)
        skip.callback()
        assert.equal("v0.3.0", store.update_skip)
        store.update_checked = nil
        Updater.autoCheck("start")
        assert.equal(1, #shown)

        -- the switch in the menu
        store.update_skip, store.update_checked = nil, nil
        local auto = Updater.menuItem().sub_item_table[2]
        assert.is_true(auto.checked_func())
        auto.callback()
        assert.is_false(store.auto_update)
        Updater.autoCheck("start")
        assert.equal(1, #shown)
        auto.callback()
        assert.is_nil(store.auto_update)
        Updater.autoCheck("start")
        assert.equal(2, #shown)
    end)

    it("stays quiet when up to date or when the check fails", function()
        release_json = json.encode(sample_release("v0.2.0"))
        Updater.autoCheck("start")
        assert.equal(0, #shown)
        assert.truthy(store.update_checked)

        store.update_checked = nil
        Updater.runInBackground = function(task, done) done("error\nHTTP 500") end
        Updater.autoCheck("start")
        assert.equal(0, #shown)
        assert.is_nil(store.update_checked)
        -- failed checks wait an hour
        local tries = 0
        Updater.runInBackground = function(task, done) tries = tries + 1 done("ok\n" .. release_json) end
        Updater.autoCheck("network")
        assert.equal(0, tries)
    end)

    it("says once when the plugin was updated", function()
        package.loaded["ui/widget/notification"] = { new = function(_, o) o.note = true return o end }
        Updater.announceVersion()
        assert.equal("0.2.0", store.version_seen)
        assert.equal(0, #scheduled)
        store.version_seen = "0.1.0"
        Updater.announceVersion()
        assert.equal(1, #scheduled)
        scheduled[1][2]()
        assert.equal("MDict dictionaries updated to 0.2.0.", shown[1].text)
        Updater.announceVersion()
        assert.equal(1, #scheduled)
        -- moved in at this start, though the settings never recorded the old version
        store.version_seen = nil
        package.loaded["mdict/applied_update"] = { from = "0.1.9", to = "0.2.0" }
        Updater.announceVersion()
        assert.equal(2, #scheduled)
        assert.is_nil(package.loaded["mdict/applied_update"])
    end)

    it("reads the subprocess's answer", function()
        assert.equal("0.3.0", Updater.parseResult("ok\n" .. release_json).version)
        assert.equal("HTTP 500", select(2, Updater.parseResult("error\nHTTP 500")))
        assert.is_nil((Updater.parseResult("ok\n{bad")))
        assert.is_nil((Updater.parseResult("")))
    end)
end)
