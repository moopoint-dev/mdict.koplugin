local helper = require("spec.helper")
local Dictionary = require("mdict/dictionary")
local Library = require("mdict/library")
local fs = require("mdict/fs")

describe("dictionary", function()
    local fx, cache
    setup(function()
        fx = helper.fixtures()
        cache = helper.tmpdir("dictcache")
    end)

    local function open(name, extra)
        local o = { path = fx .. "/" .. name, cache_dir = cache }
        for k, v in pairs(extra or {}) do o[k] = v end
        return Dictionary.new(o)
    end

    it("derives a host-safe id and finds its resource files", function()
        local d = open("basic.mdx")
        assert.matches("^basic%-%x+$", d.id)
        assert.same({ fx .. "/basic.mdd" }, d.mdd_paths)
    end)

    it("looks up words, exact spelling first, following links", function()
        local d = open("basic.mdx")
        local r = assert(d:lookup("apples"))
        assert.equal(1, #r)
        assert.equal("Apple", r[1].key)
        assert.matches("a round fruit", r[1].record)
        -- kosort folds case, spaces and kana
        r = assert(d:lookup("LOOKUP"))
        assert.equal(2, #r)
        r = assert(d:lookup("らーめん"))
        assert.equal("ラーメン", r[1].key)
        assert.same({}, d:lookup("nonexistentword"))
        d:close()
    end)

    it("ranks the exact spelling and keeps anchors", function()
        local d = open("multi.mdx")
        local r = assert(d:lookup("Bank#top"))
        assert.equal(3, #r)
        assert.equal("Bank", r[1].key)
        assert.equal("top", r[1].anchor)
        d:close()
    end)

    it("offers prefix matches when fuzzy and nothing matches", function()
        local d = open("basic.mdx")
        assert.same({}, d:lookup("lookupx"))
        local r = assert(d:lookup("looku", { fuzzy = true }))
        assert.is_true(#r >= 1)
        assert.is_true(r[1].fuzzy)
        d:close()
    end)

    it("extracts resources from the mdd into the cache", function()
        local d = open("basic.mdx")
        local css = assert(d:resource("basic.css"))
        assert.equal(cache .. "/res/" .. d.id .. "/basic.css", css)
        assert.matches("font%-weight:bold", fs.readAll(css))
        assert.truthy(d:resource("img/icon.png"))
        assert.is_nil(d:resource("missing.png"))
        assert.is_nil(d:resource("../../etc/passwd"))
        local html = d:entryHtml(d:lookup("Apple")[1].record)
        assert.matches('href="bword://apples"', html)
        local dir = d:prefetch('<link rel="stylesheet" href="basic.css"><img src="img/icon.png">')
        assert.truthy(fs.isFile(dir .. "/fonts/t.ttf"))
        -- @import chains are followed
        d:prefetch('<link rel="stylesheet" href="chain/a.css">')
        assert.truthy(fs.isFile(dir .. "/chain/b.css"))
        d:close()
    end)

    it("builds a sidecar for large unsorted files, then uses it", function()
        local old = Dictionary.MEMORY_INDEX_MAX
        Dictionary.MEMORY_INDEX_MAX = 0
        local jobs = {}
        local d = open("unsorted.mdx", { builder = function(job, done) jobs[#jobs + 1] = { job, done } end })
        local r, err = d:lookup("Apple")
        assert.is_nil(r)
        assert.equal("indexing", err)
        assert.equal(1, #jobs)
        local stats = Dictionary.buildIndexJob(jobs[1][1])
        assert.is_false(stats.sorted)
        jobs[1][2](true)
        r = assert(d:lookup("Apple"))
        assert.equal("Apple", r[1].key)
        assert.equal("sidecar", d:indexStates()[1].state)
        d:close()
        assert.equal("sidecar", d:storedIndexState())
        assert.is_nil(open("multi.mdx"):storedIndexState())
        -- a sorted file keeps no sidecar, only a verdict
        local s = open("basic.mdx")
        local job
        s.builder = function(j, done) job = j; Dictionary.buildIndexJob(j); done(true) end
        assert.is_nil(s:lookup("Apple"))
        assert.is_nil(fs.stat(job.sidecar))
        -- basic.mdx is sorted by lowercase, not kosort-1, unless the keys happen to agree
        local again = assert(s:lookup("Apple"))
        assert.equal("Apple", again[1].key)
        Dictionary.MEMORY_INDEX_MAX = old
        d:close()
        s:close()
    end)
end)

describe("per-dictionary overrides", function()
    it("applies <name>.koreader.lua and .koreader.css", function()
        local dir = helper.tmpdir("override")
        os.execute(string.format("cp '%s/basic.mdx' '%s/'", helper.fixtures(), dir))
        local d = Dictionary.new({ path = dir .. "/basic.mdx", cache_dir = helper.tmpdir("ocache") })
        local record = d:lookup("Apple")[1].record
        assert.falsy(d:entryHtml(record):find("FIXED", 1, true))
        assert.is_nil(d:userCss())
        fs.writeAtomic(dir .. "/basic.koreader.lua", [[
            return function(html) return (html:gsub("round fruit", "FIXED fruit")) end
        ]])
        fs.writeAtomic(dir .. "/basic.koreader.css", ".hw{color:red}")
        assert.truthy(d:entryHtml(record):find("FIXED fruit", 1, true))
        assert.equal(".hw{color:red}", d:userCss())
        -- the fixer cannot reach the system
        fs.writeAtomic(dir .. "/basic.koreader.lua", "return function(html) return os.getenv('HOME') end")
        os.execute("touch -d '+1 minute' '" .. dir .. "/basic.koreader.lua'")
        local html = d:entryHtml(record)
        assert.truthy(html:find("round fruit", 1, true))
        d:close()
    end)

    it("applies shared mdict.koreader.* files from the library folder down", function()
        local root = helper.tmpdir("shared")
        os.execute(string.format("mkdir -p '%s/a/b' && cp '%s/basic.mdx' '%s/a/b/'", root, helper.fixtures(), root))
        local d = Dictionary.new({ path = root .. "/a/b/basic.mdx", root = root, cache_dir = helper.tmpdir("scache") })
        local record = d:lookup("Apple")[1].record
        fs.writeAtomic(root .. "/mdict.koreader.lua", [[
            return function(html) return (html:gsub("round", "ROUND")) end
        ]])
        fs.writeAtomic(root .. "/a/b/basic.koreader.lua", [[
            return function(html) return (html:gsub("ROUND fruit", "FIXED fruit")) end
        ]])
        fs.writeAtomic(root .. "/mdict.koreader.css", ".a{}")
        fs.writeAtomic(root .. "/a/mdict.koreader.css", ".b{}")
        fs.writeAtomic(root .. "/a/b/basic.koreader.css", ".c{}")
        assert.truthy(d:entryHtml(record):find("FIXED fruit", 1, true))
        assert.equal(".a{}\n.b{}\n.c{}", d:userCss())
        -- outside the library folder nothing is shared
        local alone = Dictionary.new({ path = root .. "/a/b/basic.mdx", cache_dir = helper.tmpdir("scache2") })
        assert.equal(".c{}", alone:userCss())
        d:close()
        alone:close()
    end)
end)

describe("library", function()
    it("finds dictionaries, caches titles and keeps titles unique", function()
        local fx = helper.fixtures()
        local cache = helper.tmpdir("libcache")
        local lib = Library.new({ dirs = { fx }, cache_dir = cache })
        local dicts = lib:scan({ ["Multi"] = true })
        assert.truthy(lib:byTitle("Basic Test"))
        assert.truthy(lib:byTitle("Multi (multi.mdx)"))
        assert.truthy(fs.isFile(cache .. "/titles.json"))
        local again = lib:scan({ ["Multi"] = true })
        assert.equal(#dicts, #again)
        assert.equal(lib:byTitle("Basic Test"), again[1].title == "Basic Test" and again[1] or lib:byTitle("Basic Test"))
        assert.equal(lib:byId(lib:byTitle("Basic Test").id), lib:byTitle("Basic Test"))
        lib:closeAll()
    end)

    it("reports files it cannot read and trims titles", function()
        local dir = helper.tmpdir("libbad")
        local f = assert(io.open(dir .. "/broken.mdx", "wb"))
        f:write("\0\0\0\4junk")
        f:close()
        local lib = Library.new({ dirs = { dir }, cache_dir = helper.tmpdir("libbadcache") })
        assert.same({}, lib:scan())
        assert.equal(1, #lib.unreadable)
        assert.equal(dir .. "/broken.mdx", lib.unreadable[1].path)
        -- titles cached by an older version lose their spaces too
        local cache = helper.tmpdir("libtrim")
        local size, mtime = fs.stat(dir .. "/broken.mdx")
        fs.writeAtomic(cache .. "/titles.json",
            string.format('{"%s/broken.mdx":{"size":%d,"mtime":%d,"title":"Spaced "}}', dir, size, mtime))
        local lib3 = Library.new({ dirs = { dir }, cache_dir = cache })
        lib3:scan()
        assert.truthy(lib3:byTitle("Spaced"))
    end)
end)

describe("base forms", function()
    it("undoes common English inflections", function()
        local function has(list, w) for _, x in ipairs(list) do if x == w then return true end end return false end
        assert.is_true(has(Dictionary.baseForms("apples"), "apple"))
        assert.is_true(has(Dictionary.baseForms("running"), "run"))
        assert.is_true(has(Dictionary.baseForms("making"), "make"))
        assert.is_true(has(Dictionary.baseForms("studied"), "study"))
        assert.is_true(has(Dictionary.baseForms("stopped"), "stop"))
        assert.is_true(has(Dictionary.baseForms("happier"), "happy"))
        assert.is_true(has(Dictionary.baseForms("dog's"), "dog"))
        assert.same({}, Dictionary.baseForms("日本"))
    end)
end)
