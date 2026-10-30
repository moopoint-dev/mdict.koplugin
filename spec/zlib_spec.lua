local _ = require("spec.helper")

describe("zlib", function()
    local zlib = require("mdict/zlib")
    local ffi = require("ffi")

    it("computes Adler-32 without the library function", function()
        local samples = { "", "a", "Wikipedia", string.rep("\255", 20000) }
        local t = {}
        for i = 1, 70000 do t[i] = string.char((i * 7919) % 256) end
        samples[#samples + 1] = table.concat(t)
        for _, s in ipairs(samples) do
            local p = ffi.cast("const unsigned char *", s)
            assert.are.equal(zlib.adler32(s), zlib._lua_adler32(p, #s))
        end
        assert.are.equal(0x11E60398, zlib._lua_adler32(ffi.cast("const unsigned char *", "Wikipedia"), 9))
    end)
end)
