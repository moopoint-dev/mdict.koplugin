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
end)
