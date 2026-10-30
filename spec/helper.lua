-- Shared setup for the specs: module path and the generated fixture dictionaries.
local root = debug.getinfo(1, "S").source:match("^@(.*)/spec/helper%.lua$") or "."
package.path = root .. "/mdict.koplugin/?.lua;" .. root .. "/spec/support/?.lua;" .. package.path

local M = { root = root }

function M.fixtures()
    if M._fixtures then return M._fixtures end
    local dir = os.getenv("MDICT_FIXTURES") or ("/tmp/mdict-spec-fixtures-" .. tostring(os.time()))
    local py = os.getenv("MDICT_PYTHON") or "python3"
    -- python-lzo is optional; v12.mdx falls back to zlib without it
    local ok = os.execute(string.format("%s '%s/tools/mkmdx.py' fixtures '%s' >/dev/null", py, root, dir))
    assert(ok == 0 or ok == true, "fixture generation failed")
    M._fixtures = dir
    return dir
end

function M.tmpdir(name)
    local d = string.format("/tmp/mdict-spec-%s-%d-%d", name, os.time(), math.random(1e6))
    os.execute("mkdir -p '" .. d .. "'")
    return d
end

return M
