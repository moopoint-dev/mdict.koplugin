local helper = require("spec.helper")

describe("shipped .koidx indexes", function()
    local Reader = require("mdict/reader")
    local Index = require("mdict/index")
    local Dictionary = require("mdict/dictionary")
    local zlib = require("mdict/zlib")
    local fs = require("mdict/fs")
    local bit = require("bit")
    local fx = helper.fixtures()
    local py = os.getenv("MDICT_PYTHON") or "python3"

    local function read(path)
        local f = assert(io.open(path, "rb"))
        local s = f:read("*a")
        f:close()
        return s
    end
    local function write(path, s)
        local f = assert(io.open(path, "wb"))
        f:write(s)
        f:close()
    end
    local function be32(n)
        return string.char(bit.band(bit.rshift(n, 24), 255), bit.band(bit.rshift(n, 16), 255),
            bit.band(bit.rshift(n, 8), 255), bit.band(n, 255))
    end
    local function rd32(s, i)
        local a, b, c, d = s:byte(i, i + 3)
        return ((a * 256 + b) * 256 + c) * 256 + d
    end

    -- tools/koidx.py writes `volume`.koidx
    local function build(volume)
        local ok = os.execute(string.format("%s '%s/tools/koidx.py' build '%s' >/dev/null", py, helper.root, volume))
        assert(ok == 0 or ok == true, "koidx.py failed on " .. volume)
    end

    -- a fixture copied into a folder of its own, with its .koidx beside it
    local function shipped(name, from)
        local dir = helper.tmpdir("koidx")
        write(dir .. "/" .. name, read(fx .. "/" .. name))
        if from then
            write(dir .. "/" .. from, read(fx .. "/" .. from))
            build(dir .. "/" .. from)
            write(dir .. "/" .. name .. ".koidx", read(dir .. "/" .. from .. ".koidx"))
        else
            build(dir .. "/" .. name)
        end
        return dir .. "/" .. name
    end

    -- rewrites a .koidx: edit(s) returns the changed file; the header CRC (and, with body,
    -- the body CRC) are put right again, so only the change itself is wrong
    local function tamper(path, edit, body)
        local s = edit(read(path))
        if body then
            s = s:sub(1, 88) .. be32(zlib.crc32(0, s:sub(129))) .. s:sub(93)
        end
        s = s:sub(1, 124) .. be32(zlib.crc32(0, s:sub(1, 124))) .. s:sub(129)
        write(path, s)
    end

    local function all_found(idx, reader, spec)
        local norm = Index.normalizer(spec)
        reader:eachKey(function(k, ord)
            local found = false
            for _, o in ipairs(idx:find(norm(k))) do
                if o == ord then found = true end
            end
            assert.is_true(found, k)
        end)
    end

    it("computes zlib's CRC-32 in Lua too", function()
        assert.equal(0xCBF43926, zlib.crc32(0, "123456789"))
        assert.equal(0xCBF43926, zlib._lua_crc32(0, "123456789"))
        local s = {}
        for i = 1, 5000 do s[i] = string.char((i * 7919) % 256) end
        s = table.concat(s)
        assert.equal(zlib.crc32(0, s), zlib._lua_crc32(0, s))
        assert.equal(zlib.crc32(0, s), zlib._lua_crc32(zlib._lua_crc32(0, s:sub(1, 1234)), s:sub(1235)))
    end)

    it("is built by koidx.py with the plugin's own pages, for every fixture", function()
        for _, name in ipairs({ "basic.mdx", "unsorted.mdx", "v12.mdx", "utf16.mdx", "raw.mdx", "multi.mdx",
                                "repeats.mdx", "order-utf-8.mdx", "order-utf-16.mdx", "basic.mdd" }) do
            local p = shipped(name)
            local reader = assert(Reader.open(p))
            local spec = reader.is_mdd and "res-1" or "kosort-1"
            local own = helper.tmpdir("own") .. "/own.idx"
            Index.buildSidecar(reader, own, spec, {})
            local file = read(p .. ".koidx")
            assert.equal(read(own):sub(65), file:sub(129), name)
            local h = assert(Index.parseShippedHeader(file:sub(1, 128)))
            assert.equal(spec, h.spec)
            assert.equal(reader.num_entries, h.count)
            assert.equal(reader.kb_fpos[reader.num_key_blocks], h.source_len)
            assert.equal(zlib.crc32(0, read(p):sub(1, h.source_len)), h.source_crc32)
            local idx = assert(Index.openSidecar(p .. ".koidx", spec, { format = 2 }))
            assert.is_true(Index.checkShipped(idx, reader))
            all_found(idx, reader, spec)
            idx:close()
            assert.is_true(Index.verifyShipped(p .. ".koidx", p, spec))
            reader:close()
        end
    end)

    it("is used at once, checked in the background, then trusted", function()
        local old = Dictionary.MEMORY_INDEX_MAX
        Dictionary.MEMORY_INDEX_MAX = 0
        local p = shipped("unsorted.mdx")
        local cache = helper.tmpdir("kcache")
        local jobs = {}
        local builder = function(job, done) jobs[#jobs + 1] = { job, done } end
        local d = Dictionary.new({ path = p, cache_dir = cache, builder = builder })
        assert.equal("Apple", assert(d:lookup("Apple"))[1].key)
        assert.equal("shipped (checking)", d:indexStates()[1].state)
        assert.equal(1, #jobs)
        assert.equal("verify", jobs[1][1].mode)
        assert.is_true(Dictionary.buildIndexJob(jobs[1][1]).verified)
        jobs[1][2](true)
        assert.equal("shipped", d:indexStates()[1].state)
        assert.is_nil(fs.stat(jobs[1][1].sidecar)) -- nothing built
        d:close()
        assert.equal("shipped", d:storedIndexState())
        assert.equal("Apple", assert(d:lookup("apple"))[1].key)
        assert.equal("shipped", d:indexStates()[1].state)
        assert.equal(1, #jobs)
        d:close()
        Dictionary.MEMORY_INDEX_MAX = old
    end)

    it("is checked again when either file is replaced but its size and mtime look unchanged", function()
        local json = require("mdict/json")
        local old = Dictionary.MEMORY_INDEX_MAX
        Dictionary.MEMORY_INDEX_MAX = 0
        local p = shipped("unsorted.mdx")
        local cache = helper.tmpdir("kcache5")
        local jobs = {}
        local builder = function(job, done) jobs[#jobs + 1] = { job, done } end
        local function session()
            local d = Dictionary.new({ path = p, cache_dir = cache, builder = builder })
            d:lookup("Apple")
            local st = d:indexStates()[1]
            d:close()
            return st
        end
        local function verdict_path(d)
            return cache .. "/idx/" .. d.id .. ".mdx.koidx.verdict"
        end
        local probe = Dictionary.new({ path = p, cache_dir = cache })
        local vpath = verdict_path(probe)
        -- as the file system would report the replaced file: the old size and mtime
        local function same_times(v)
            local size, mtime = fs.stat(p)
            local ksize, kmtime = fs.stat(p .. ".koidx")
            v.size, v.mtime, v.koidx_size, v.koidx_mtime = size, mtime, ksize, kmtime
            write(vpath, json.encode(v))
        end
        assert.equal("shipped (checking)", session().state)
        Dictionary.buildIndexJob(jobs[1][1])
        local good = json.decode(read(vpath))
        assert.is_true(good.ok)
        assert.truthy(good.keys and good.keys_end and good.koidx_crc)
        assert.equal("shipped", session().state)
        assert.equal(1, #jobs)
        -- a verdict from 0.4.0 (no key count, key-section length or header CRC) holds, and is completed
        write(vpath, json.encode({ spec = good.spec, size = good.size, mtime = good.mtime,
            koidx_size = good.koidx_size, koidx_mtime = good.koidx_mtime, ok = true }))
        assert.equal("shipped", session().state)
        assert.equal(good.koidx_crc, json.decode(read(vpath)).koidx_crc)
        assert.equal(1, #jobs)
        -- another index under the old name (basic.mdx has as many keys): its header CRC differs
        local saved = read(p .. ".koidx")
        local other = shipped("basic.mdx")
        write(p .. ".koidx", read(other .. ".koidx"))
        same_times(good)
        local st = session()
        assert.is_nil(st.state:find("^shipped"))
        assert.equal("built for another file", st.shipped_problem)
        -- another volume under the old name: its key-section length differs
        write(p .. ".koidx", saved)
        local mdx = read(p)
        write(p, read(other))
        same_times(good)
        st = session()
        assert.is_nil(st.state:find("^shipped"))
        assert.equal("built for another file", st.shipped_problem)
        write(p, mdx)
        Dictionary.MEMORY_INDEX_MAX = old
    end)

    it("is not used for another file, which is indexed as before", function()
        local old = Dictionary.MEMORY_INDEX_MAX
        Dictionary.MEMORY_INDEX_MAX = 0
        -- basic.mdx and unsorted.mdx hold the same number of keys
        local p = shipped("unsorted.mdx", "basic.mdx")
        local jobs = {}
        local d = Dictionary.new({ path = p, cache_dir = helper.tmpdir("kcache2"),
            builder = function(job, done) jobs[#jobs + 1] = { job, done } end })
        local r, err = d:lookup("Apple")
        assert.is_nil(r)
        assert.equal("indexing", err)
        assert.truthy(d:indexStates()[1].shipped_problem)
        assert.is_nil(jobs[1][1].mode)
        Dictionary.buildIndexJob(jobs[1][1])
        jobs[1][2](true)
        assert.equal("Apple", assert(d:lookup("Apple"))[1].key)
        assert.equal("sidecar", d:indexStates()[1].state)
        d:close()
        Dictionary.MEMORY_INDEX_MAX = old
    end)

    it("is set aside when the background check finds it was built for another version", function()
        local old = Dictionary.MEMORY_INDEX_MAX
        Dictionary.MEMORY_INDEX_MAX = 0
        local p = shipped("unsorted.mdx")
        tamper(p .. ".koidx", function(s) -- source_crc32 at offset 76
            return s:sub(1, 76) .. be32(bit.bxor(rd32(s, 77), 1)) .. s:sub(81)
        end)
        local cache = helper.tmpdir("kcache3")
        local jobs = {}
        local builder = function(job, done) jobs[#jobs + 1] = { job, done } end
        local d = Dictionary.new({ path = p, cache_dir = cache, builder = builder })
        assert.truthy(d:lookup("Apple")) -- the cheap checks pass
        assert.equal("shipped (checking)", d:indexStates()[1].state)
        local stats = Dictionary.buildIndexJob(jobs[1][1]) -- fails the check, builds the usual index
        assert.is_nil(stats.verified)
        assert.is_false(stats.sorted)
        jobs[1][2](true)
        assert.equal("Apple", assert(d:lookup("Apple"))[1].key)
        assert.equal("sidecar", d:indexStates()[1].state)
        assert.equal("built for another version of the file", d:indexStates()[1].shipped_problem)
        d:close()
        -- a later session goes straight to the built index
        os.remove(jobs[1][1].sidecar)
        local d2 = Dictionary.new({ path = p, cache_dir = cache, builder = builder })
        assert.is_nil(d2:lookup("Apple"))
        assert.equal("built for another version of the file", d2:indexStates()[1].shipped_problem)
        assert.equal(2, #jobs)
        assert.is_nil(jobs[2][1].mode)
        d2:close()
        Dictionary.MEMORY_INDEX_MAX = old
    end)

    it("is checked against sampled keys, its body CRC and its header", function()
        local p = shipped("unsorted.mdx")
        local reader = assert(Reader.open(p))
        local good = read(p .. ".koidx")
        -- a key in the first page that differs, CRCs put right: only the sampled key shows it
        tamper(p .. ".koidx", function(s)
            local at = 129
            local n = s:byte(at) * 256 + s:byte(at + 1)
            local i = at + 2
            for k = 1, math.floor((n + 1) / 2) do
                local len = s:byte(i)
                if len >= 128 then len, i = len - 128 + s:byte(i + 1) * 128, i + 2 else i = i + 1 end
                if k == math.floor((n + 1) / 2) then
                    local last = i + len - 1
                    return s:sub(1, last - 1) .. string.char(s:byte(last) == 122 and 121 or s:byte(last) + 1)
                        .. s:sub(last + 1)
                end
                i = i + len + 4
            end
        end, true)
        local idx = assert(Index.openSidecar(p .. ".koidx", "kosort-1", { format = 2 }))
        local ok, why = Index.checkShipped(idx, reader)
        assert.is_nil(ok)
        assert.truthy(why:find("not the one indexed"))
        idx:close()
        -- a damaged body: found by the background check
        write(p .. ".koidx", good:sub(1, 2000) .. string.char((good:byte(2001) + 1) % 256) .. good:sub(2002))
        local vok, vwhy = Index.verifyShipped(p .. ".koidx", p, "kosort-1")
        assert.is_nil(vok)
        assert.equal("the index file is damaged", vwhy)
        -- headers
        write(p .. ".koidx", good:sub(1, 20) .. "x" .. good:sub(22))
        assert.equal("header checksum mismatch", select(2, Index.openSidecar(p .. ".koidx", "kosort-1")))
        write(p .. ".koidx", good)
        tamper(p .. ".koidx", function(s) return s:sub(1, 12) .. be32(0x10000) .. s:sub(17) end)
        assert.truthy(select(2, Index.openSidecar(p .. ".koidx", "kosort-1")):find("newer plugin"))
        write(p .. ".koidx", good)
        tamper(p .. ".koidx", function(s) return s:sub(1, 12) .. be32(1) .. s:sub(17) end) -- optional bit
        local opened = assert(Index.openSidecar(p .. ".koidx", "kosort-1"))
        opened:close()
        write(p .. ".koidx", good)
        tamper(p .. ".koidx", function(s) return s:sub(1, 32) .. be32(500) .. s:sub(37) end)
        assert.truthy(select(2, Index.openSidecar(p .. ".koidx", "kosort-1")):find("cuts at 1000"))
        write(p .. ".koidx", good)
        assert.equal("built for kosort-1", select(2, Index.openSidecar(p .. ".koidx", "res-1")))
        assert.equal("format 2, expected 1", select(2, Index.openSidecar(p .. ".koidx", "kosort-1", { format = 1 })))
        reader:close()
    end)

    it("is checked by koidx.py check as the plugin checks it", function()
        local p = shipped("unsorted.mdx", "basic.mdx")
        local cmd = string.format("%s '%s/tools/koidx.py' check '%s' >/dev/null", py, helper.root, p)
        local status = os.execute(cmd)
        assert.is_false(status == 0 or status == true)
        build(p)
        status = os.execute((cmd:gsub(" check ", " check --deep ")))
        assert.is_true(status == 0 or status == true)
    end)
end)
