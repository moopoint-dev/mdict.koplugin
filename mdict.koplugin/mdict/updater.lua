--[[--
Checking for, offering and installing new versions of the plugin (see mdict/update.lua).

- "Check for updates" in the menu asks GitHub for the latest release now, turning
  the network on if needed.
- Automatic checks run at most once a day, a minute after start, when the network
  connects and when the device wakes, but only when the device is already
  connected: they never turn Wi-Fi on. They can be turned off in the menu.
- Network requests run in a subprocess, so the reader never waits on them.
- An installed update is moved into place when KOReader next starts.
]]

local Update = require("mdict/update")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local DAY = 24 * 3600
local RETRY_AFTER_FAILURE = 3600 -- automatic checks that failed
local CHILD_TIMEOUT = 90         -- seconds before a background check is killed
local PROMPT_RETRY = 120         -- seconds between tries to show an automatic offer

local Updater = {}

local state -- the plugin's shared state

function Updater.setup(s)
    state = s
end

local function settings() return state.settings end
local function save() if state.saveSettings then state.saveSettings() end end

function Updater.pluginDir()
    local p = state.plugin and state.plugin.path
    if p then return p end
    local here = debug.getinfo(1, "S").source:match("^@(.*)/mdict/updater%.lua$")
    return here or "."
end

function Updater.version()
    if state.plugin and state.plugin.version then return state.plugin.version end
    state.version = state.version or Update.readMetaVersion(Updater.pluginDir() .. "/_meta.lua") or "0"
    return state.version
end

function Updater.autoEnabled()
    return settings().auto_update ~= false
end

-- Child task: GitHub's latest release, as "ok\n<json>" or "error\n<message>".
local function fetch_task()
    local ok, text, err = pcall(Update.fetchLatest)
    if ok and text then return "ok\n" .. text end
    return "error\n" .. tostring(ok and err or text or "network error")
end

-- Decodes a fetch_task result into a release, or nil and an error.
function Updater.parseResult(out)
    if type(out) ~= "string" or out == "" then return nil, _("No answer from GitHub.") end
    local kind, body = out:match("^(%a+)\n(.*)$")
    if kind ~= "ok" then return nil, body or out end
    local ok, r = pcall(require("mdict/json").decode, body)
    if not ok then return nil, _("GitHub's answer could not be read.") end
    return Update.releaseInfo(r)
end

--- Runs task (returning a string) in a subprocess and calls done(output) on the UI loop;
-- done(nil, err) when it cannot run or takes too long. Replaceable in the specs.
function Updater.runInBackground(task, done)
    local ok_util, ffiutil = pcall(require, "ffi/util")
    if not ok_util or not ffiutil.runInSubProcess then return done(nil, "no subprocess support") end
    local pid, fd = ffiutil.runInSubProcess(function(_pid, child_fd)
        local out = task()
        ffiutil.writeToFD(child_fd, out or "", true)
    end, true)
    if not pid then return done(nil, fd or "cannot start a subprocess") end
    local started = os.time()
    local chunks = {}
    local function poll()
        if fd and ffiutil.getNonBlockingReadSize(fd) ~= 0 then
            chunks[#chunks + 1] = ffiutil.readAllFromFD(fd) -- reads to EOF and closes
            fd = nil
        end
        if ffiutil.isSubProcessDone(pid) then
            if fd then
                chunks[#chunks + 1] = ffiutil.readAllFromFD(fd)
                fd = nil
            end
            return done(table.concat(chunks))
        end
        if os.time() - started > CHILD_TIMEOUT then
            ffiutil.terminateSubProcess(pid)
            local function reap()
                if not ffiutil.isSubProcessDone(pid) then UIManager:scheduleIn(5, reap) end
            end
            UIManager:scheduleIn(5, reap)
            if fd then
                pcall(ffiutil.readAllFromFD, fd)
                fd = nil
            end
            return done(nil, "timed out")
        end
        UIManager:scheduleIn(0.5, poll)
    end
    UIManager:scheduleIn(0.5, poll)
end

local function info(text, timeout)
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout })
end

local function ask_restart(version)
    local text = T(_("MDict dictionaries %1 is installed. Restart KOReader to start using it."), version)
    if UIManager.askForRestart then UIManager:askForRestart(text) else info(text) end
end

local function is_newer(release)
    return release and Update.compare(release.version, Updater.version()) == 1
end

-- Installs a release: download in a subprocess (can be cancelled), unpack next to the plugin.
function Updater.install(release)
    if not release.asset then
        info(T(_("This release has no plugin package to install. See %1"), release.url))
        return
    end
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        local Trapper = require("ui/trapper")
        Trapper:wrap(function()
            local fs = require("mdict/fs")
            local dir = state.cacheDir() .. "/update"
            fs.mkdirp(dir)
            local zip = dir .. "/" .. (release.asset.name:gsub("[^%w%.%-_]", "_"))
            local asset = release.asset
            local completed, out = Trapper:dismissableRunInSubprocess(function()
                local ok, err = Update.download(asset, zip)
                return ok and "ok" or ("error\n" .. tostring(err))
            end, T(_("Downloading MDict dictionaries %1…"), release.version), true)
            if not completed then
                os.remove(zip)
                return
            end
            if out ~= "ok" then
                os.remove(zip)
                local err = type(out) == "string" and out:match("^error\n(.*)$") or tostring(out)
                logger.warn("MDict: update download failed:", err)
                info(T(_("Could not download the update.\n\n%1"), err))
                return
            end
            local version, err = Update.stage(zip, Updater.pluginDir(), release.version)
            os.remove(zip)
            if not version then
                logger.warn("MDict: update install failed:", err)
                info(T(_("Could not install the update.\n\n%1"), err))
                return
            end
            logger.info("MDict: update", version, "staged; it is moved in at the next start")
            state.update_staged = version
            ask_restart(version)
        end)
    end)
end

local function show_notes(release, on_update)
    local TextViewer = require("ui/widget/textviewer")
    local viewer
    viewer = TextViewer:new{
        title = release.title or T(_("MDict dictionaries %1"), release.version),
        text = Update.plainNotes(release.notes) ~= "" and Update.plainNotes(release.notes) or release.url,
        buttons_table = {{
            { text = _("Close"), callback = function() UIManager:close(viewer) end },
            { text = _("Update"), callback = function()
                UIManager:close(viewer)
                on_update()
            end },
        }},
    }
    UIManager:show(viewer)
end

--- Offers to install release. auto: from an automatic check (offers "Skip this version").
function Updater.offer(release, auto)
    local ConfirmBox = require("ui/widget/confirmbox")
    local function update() Updater.install(release) end
    local row = {
        { text = _("What's new"), callback = function() show_notes(release, update) end },
    }
    if auto then
        row[#row + 1] = { text = _("Skip this version"), callback = function()
            settings().update_skip = release.tag
            save()
        end }
    end
    UIManager:show(ConfirmBox:new{
        text = T(_("A new version of MDict dictionaries is available.\n\nInstalled: %1\nAvailable: %2"),
            Updater.version(), release.version),
        ok_text = _("Update"),
        cancel_text = _("Not now"),
        ok_callback = update,
        other_buttons = { row },
        other_buttons_first = true,
    })
end

-- Automatic offers wait until the reader or the file browser is on top, so they do not land on
-- a dictionary popup or an open menu.
local function idle_ui()
    local top = UIManager.getTopmostVisibleWidget and UIManager:getTopmostVisibleWidget()
    if not top then return true end
    return top.name == "ReaderUI" or top.name == "filemanager"
end

function Updater.offerWhenIdle(release, tries)
    tries = tries or 0
    if state.update_staged then return end
    if idle_ui() or tries >= 30 then
        return Updater.offer(release, true)
    end
    UIManager:scheduleIn(PROMPT_RETRY, function() Updater.offerWhenIdle(release, tries + 1) end)
end

--- Automatic check: at most once a day, only when already connected, without any message unless
-- there is a new version the reader has not skipped.
function Updater.autoCheck(reason)
    if not state or not Updater.autoEnabled() or state.update_busy or state.update_staged then return end
    local s = settings()
    local now = os.time()
    if s.update_checked and now >= s.update_checked and now - s.update_checked < DAY then return end
    if state.update_failed_at and now - state.update_failed_at < RETRY_AFTER_FAILURE then return end
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isConnected() then return end
    state.update_busy = true
    logger.dbg("MDict: automatic update check,", reason)
    Updater.runInBackground(fetch_task, function(out, err)
        state.update_busy = nil
        local release
        if out then release, err = Updater.parseResult(out) end
        if not release then
            state.update_failed_at = os.time()
            logger.info("MDict: automatic update check failed:", err)
            return
        end
        s.update_checked = os.time()
        save()
        logger.info("MDict: latest release", release.tag, "installed", Updater.version())
        if is_newer(release) and release.tag ~= s.update_skip then
            Updater.offerWhenIdle(release)
        end
    end)
end

--- "Check for updates" in the menu.
function Updater.checkNow()
    local staged = Update.stagedVersion(Updater.pluginDir())
    if staged and Update.compare(staged, Updater.version()) == 1 then
        ask_restart(staged)
        return
    end
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        local Trapper = require("ui/trapper")
        Trapper:wrap(function()
            local completed, out = Trapper:dismissableRunInSubprocess(fetch_task, _("Checking for updates…"), true)
            if not completed then return end
            local release, err = Updater.parseResult(out)
            if not release then
                logger.warn("MDict: update check failed:", err)
                info(T(_("Could not check for updates.\n\n%1"), err))
                return
            end
            settings().update_checked = os.time()
            save()
            if is_newer(release) then
                Updater.offer(release, false)
            else
                info(T(_("MDict dictionaries %1 is the latest version."), Updater.version()), 3)
            end
        end)
    end)
end

--- Once per start: tells the reader when the plugin was updated since the last start.
function Updater.announceVersion()
    local s = settings()
    local version, before = Updater.version(), s.version_seen
    if before == version then return end
    s.version_seen = version
    save()
    if before and Update.compare(version, before) == 1 then
        UIManager:scheduleIn(2, function()
            local Notification = require("ui/widget/notification")
            UIManager:show(Notification:new{ text = T(_("MDict dictionaries updated to %1."), version) })
        end)
    end
end

function Updater.menuItem()
    return {
        text_func = function() return T(_("Updates (version %1)"), Updater.version()) end,
        sub_item_table = {
            {
                text = _("Check for updates"),
                keep_menu_open = true,
                callback = function() Updater.checkNow() end,
            },
            {
                text = _("Check for updates automatically"),
                help_text = _("Once a day, look for a new version of the plugin and offer to install it. "
                    .. "Checks only when the device is already connected: Wi-Fi is never turned on for this."),
                checked_func = Updater.autoEnabled,
                callback = function()
                    local s = settings()
                    if s.auto_update == false then s.auto_update = nil else s.auto_update = false end
                    save()
                end,
            },
        },
    }
end

return Updater
