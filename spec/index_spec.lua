local helper = require("spec.helper")

describe("index", function()
    local Reader = require("mdict/reader")
    local Index = require("mdict/index")
    local fx = helper.fixtures()

    local function all_keys(d)
        local t = {}
        d:eachKey(function(k, ord) t[#t + 1] = { k, ord } end)
        return t
    end

    local function check(idx, d)
        local norm = Index.normalizer("kosort-1")
        for _, kv in ipairs(all_keys(d)) do
            local found = false
            for _, o in ipairs(idx:find(norm(kv[1]))) do
                if o == kv[2] then found = true end
            end
            assert.is_true(found, kv[1])
        end
        assert.are.same({}, idx:find(norm("no such word here")))
    end

    it("detects unsorted files cheaply and builds a working sidecar", function()
        local d = assert(Reader.open(fx .. "/unsorted.mdx"))
        assert.is_false(Index.boundariesOrdered(d, "kosort-1"))
        local path = helper.tmpdir("idx") .. "/unsorted.idx"
        local stats = Index.buildSidecar(d, path, "kosort-1", { source_size = 123, source_mtime = 456 })
        assert.is_false(stats.sorted)
        assert.are.equal(d.num_entries, stats.keys)
        local idx = assert(Index.openSidecar(path, "kosort-1", { size = 123, mtime = 456 }))
        check(idx, d)
        assert.is_nil(Index.openSidecar(path, "kosort-1", { size = 999 }))
        -- normalised matches
        local hits = idx:find(Index.normalizer("kosort-1")("LOOK-UP"))
        assert.are.equal(2, #hits) -- "look up" and "lookup"
        assert.are.equal(1, #idx:find(Index.normalizer("kosort-1")("らーめん")))
        local pre = idx:prefix(Index.normalizer("kosort-1")("lookup"), 10)
        assert.is_true(#pre >= 2)
        idx:close()
        d:close()
    end)

    it("builds with an external merge of several runs", function()
        local d = assert(Reader.open(fx .. "/basic.mdx"))
        local path = helper.tmpdir("idx2") .. "/basic.idx"
        -- force small runs
        local saved_page, saved_chunk = Index.PAGE_SIZE, Index.CHUNK
        Index.PAGE_SIZE, Index.CHUNK = 512, 400
        local stats = Index.buildSidecar(d, path, "kosort-1", {})
        Index.PAGE_SIZE, Index.CHUNK = saved_page, saved_chunk
        assert.is_true(stats.pages > 10)
        local idx = assert(Index.openSidecar(path, "kosort-1"))
        check(idx, d)
        idx:close()
        d:close()
    end)

    it("searches a verified file directly", function()
        -- write a file in kosort-1 order
        local dir = helper.tmpdir("ko")
        local py = os.getenv("MDICT_PYTHON") or "python3"
        local script = string.format([[
import sys; sys.path.insert(0, '%s/tools')
import mkmdx, kosort
d = mkmdx.basic_entries()
items = sorted(d.items(), key=lambda kv: (kosort.sort_key(kv[0])))
mkmdx.write('%s/ko.mdx', items, sort=False, header_extra={'KOReaderKeyOrder': 'kosort-1'}, key_block_bytes=2048)
]], helper.root, dir)
        local f = io.open(dir .. "/gen.py", "w"); f:write(script); f:close()
        assert.is_truthy(os.execute(py .. " " .. dir .. "/gen.py"))
        local d = assert(Reader.open(dir .. "/ko.mdx"))
        assert.are.equal("kosort-1", d.header.KOReaderKeyOrder)
        assert.is_true(Index.boundariesOrdered(d, "kosort-1"))
        local sorted, inv = Index.verifyOrder(d, "kosort-1")
        assert.is_true(sorted)
        assert.are.equal(0, inv)
        local idx = Index.openFileOrder(d, "kosort-1")
        check(idx, d)
        assert.is_true(#idx:prefix(Index.normalizer("kosort-1")("lookup"), 5) >= 2)
        d:close()
    end)

    it("normalises resource paths", function()
        local n = Index.normalizer("res-1")
        assert.are.equal("\\img\\icon.png", n("img/Icon.PNG"))
        assert.are.equal("\\a.css", n("\\a.css"))
    end)
end)
