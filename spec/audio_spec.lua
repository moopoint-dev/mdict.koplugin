local helper = require("spec.helper")
local Library = require("mdict/library")
local Manager = require("renderers/manager")

describe("dictionary sounds", function()
    it("extracts the sound and hands it to the player", function()
        local lib = Library.new({ dirs = { helper.fixtures() }, cache_dir = helper.tmpdir("audio") })
        lib:scan()
        local played = {}
        Manager.renderer = { bridge = { playAudio = function(_, file) played[#played + 1] = file end } }
        local state = { library = lib, settings = {} }
        -- as the link arrives from the entry: percent-encoded
        assert.is_true(Manager.playSound(state, "Basic Test", "audio/run%23_gb_1.aac"))
        assert.equal(1, #played)
        assert.truthy(played[1]:find("/audio/run#_gb_1.aac", 1, true))
        local f = assert(io.open(played[1], "rb"))
        assert.equal("\255\241fake-adts", f:read("*a"))
        f:close()
        local ok, msg = Manager.playSound(state, "Basic Test", "audio/missing.mp3")
        assert.is_nil(ok)
        assert.truthy(msg:find("not found", 1, true))
        ok, msg = Manager.playSound(state, "Basic Test", "audio/x.spx")
        assert.is_nil(ok)
        assert.truthy(msg:find("Speex", 1, true))
        Manager.renderer = nil
    end)

    it("plays the first source of an audio player there is, else downloads the one on the web", function()
        local lib = Library.new({ dirs = { helper.fixtures() }, cache_dir = helper.tmpdir("audio-src") })
        lib:scan()
        local played = {}
        Manager.renderer = { bridge = { playAudio = function(_, file) played[#played + 1] = file end } }
        local state = { library = lib, settings = {} }
        local web = "https://example.org/sound/mean/6079.mp3?x=1"
        -- the dictionary's own copy wins
        assert.is_true(Manager.playSound(state, "Basic Test", "audio/missing.mp3",
            { "audio/missing.mp3", "audio/run%23_gb_1.aac", web }))
        assert.truthy(played[1]:find("/audio/run#_gb_1.aac", 1, true))
        -- none in the dictionary: the one on the web, downloaded once when online
        local requests, online = {}, 0
        local saved = {}
        local stubs = {
            ["ui/network/manager"] = { runWhenOnline = function(_, fn) online = online + 1; fn() end },
            ["socket"] = { skip = function(n, ...) return select(n + 1, ...) end },
            ["socketutil"] = {
                set_timeout = function() end, reset_timeout = function() end,
                file_sink = function(f) return function(chunk) if chunk then f:write(chunk) end return 1 end end,
            },
            ["socket.http"] = { request = function(req)
                requests[#requests + 1] = req.url
                req.sink("ID3fake-mp3")
                req.sink(nil)
                return 1, 200, {}, "HTTP/1.1 200 OK"
            end },
        }
        for name, mod in pairs(stubs) do saved[name] = package.loaded[name]; package.loaded[name] = mod end
        assert.is_true(Manager.playSound(state, "Basic Test", "audio/missing.mp3", { "audio/missing.mp3", web }))
        assert.is_true(Manager.playSound(state, "Basic Test", web, { web }))
        for name in pairs(stubs) do package.loaded[name] = saved[name] end
        assert.same({ web }, requests)
        assert.equal(1, online)
        assert.equal(3, #played)
        assert.equal(played[2], played[3])
        assert.truthy(played[2]:find("/sounds/", 1, true))
        local f = assert(io.open(played[2], "rb"))
        assert.equal("ID3fake-mp3", f:read("*a"))
        f:close()
        Manager.renderer = nil
    end)
end)
