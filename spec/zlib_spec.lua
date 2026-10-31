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

    it("rejects a zlib block whose data is damaged", function()
        local decode = require("mdict/reader")._decode_block
        local function block(hex)
            local s = "\2\0\0\0\58\46\6\125" .. hex:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end)
            return ffi.cast("const uint8_t *", s), #s, s
        end
        local p, n, keep = block("789ccb48cdc9c957c84090003a2e067d")
        local out, len = decode(p, n, 17)
        assert.are.equal("hello hello hello", ffi.string(out, len))
        assert.is_truthy(keep)
        p, n, keep = block("789ccb48cdc9c957c84090003a2e067e") -- the stream's own sum is wrong
        assert.has_error(function() decode(p, n, 17) end)
        assert.is_truthy(keep)
    end)
end)
