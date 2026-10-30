local helper = require("spec.helper")

describe("kosort-1", function()
    local kosort = require("mdict/kosort")
    local function unhex(h) return (h:gsub("..", function(x) return string.char(tonumber(x, 16)) end)) end

    it("matches the shared test vectors", function()
        local n = 0
        for line in io.lines(helper.root .. "/spec/data/kosort-1.tsv") do
            if not line:find("^#") and line ~= "" then
                local a, b = line:match("^(%x*)\t(%x*)$")
                assert.are.equal(unhex(b), kosort.normalize(unhex(a)), unhex(a))
                n = n + 1
            end
        end
        assert.is_true(n > 50)
    end)

    it("folds case, width, kana and punctuation", function()
        assert.are.equal("lookup", kosort.normalize("Look-Up"))
        assert.are.equal("らーめん", kosort.normalize("ラーメン"))
        assert.are.equal("abc", kosort.normalize("ＡＢＣ"))
        assert.are.equal("がぎ", kosort.normalize("ｶﾞｷﾞ"))
        assert.are.equal("café", kosort.normalize("cafe\204\129"))
        assert.are.equal("$100", kosort.normalize("$100"))
    end)
end)
