--[[--
Small JSON codec for the renderer bridge. Uses KOReader's rapidjson when it is
available, otherwise a plain Lua implementation (tests, tools).

JSON null decodes to json.null. Tables encode as arrays when they have a
non-empty array part (or are marked with json.array), otherwise as objects.
]]

local M = {}

local ok, rapidjson = pcall(require, "rapidjson")
if ok and type(rapidjson) == "table" and rapidjson.decode then
    M.null = rapidjson.null
    M.backend = "rapidjson"
    function M.decode(s)
        local v, err = rapidjson.decode(s)
        if v == nil and err then error("json: " .. tostring(err)) end
        return v
    end
    function M.encode(v) return rapidjson.encode(v) end
    function M.array(t) return rapidjson.array(t or {}) end
    return M
end

M.backend = "lua"
M.null = setmetatable({}, { __tostring = function() return "null" end })
local array_mt = {}
function M.array(t) return setmetatable(t or {}, array_mt) end

local byte, char, sub, find, format = string.byte, string.char, string.sub, string.find, string.format
local concat = table.concat

local function utf8_char(c)
    if c < 0x80 then return char(c) end
    if c < 0x800 then return char(0xC0 + math.floor(c / 64), 0x80 + c % 64) end
    if c < 0x10000 then
        return char(0xE0 + math.floor(c / 4096), 0x80 + math.floor(c / 64) % 64, 0x80 + c % 64)
    end
    return char(0xF0 + math.floor(c / 262144), 0x80 + math.floor(c / 4096) % 64,
        0x80 + math.floor(c / 64) % 64, 0x80 + c % 64)
end

local escapes = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local function decode_error(s, i, what)
    error(format("json: %s at position %d", what, i), 0)
end

local decode_value

local function skip_ws(s, i)
    local _, e = find(s, "^[ \t\r\n]*", i)
    return e + 1
end

local function decode_string(s, i)
    -- s[i] is the opening quote
    local parts, n = {}, 0
    local j = i + 1
    while true do
        local a = find(s, '["\\]', j)
        if not a then decode_error(s, i, "unterminated string") end
        if a > j then n = n + 1; parts[n] = sub(s, j, a - 1) end
        if byte(s, a) == 34 then
            return concat(parts), a + 1
        end
        local e = sub(s, a + 1, a + 1)
        if e == "u" then
            local hex = sub(s, a + 2, a + 5)
            local c = tonumber(hex, 16)
            if not c or #hex ~= 4 then decode_error(s, a, "bad unicode escape") end
            local nexti = a + 6
            if c >= 0xD800 and c <= 0xDBFF and sub(s, nexti, nexti + 1) == "\\u" then
                local lo = tonumber(sub(s, nexti + 2, nexti + 5), 16)
                if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                    c = 0x10000 + (c - 0xD800) * 0x400 + (lo - 0xDC00)
                    nexti = nexti + 6
                end
            end
            n = n + 1; parts[n] = utf8_char(c)
            j = nexti
        else
            local r = escapes[e]
            if not r then decode_error(s, a, "bad escape") end
            n = n + 1; parts[n] = r
            j = a + 2
        end
    end
end

function decode_value(s, i)
    i = skip_ws(s, i)
    local c = byte(s, i)
    if c == 123 then -- {
        local obj = {}
        i = skip_ws(s, i + 1)
        if byte(s, i) == 125 then return obj, i + 1 end
        while true do
            i = skip_ws(s, i)
            if byte(s, i) ~= 34 then decode_error(s, i, "expected key") end
            local k
            k, i = decode_string(s, i)
            i = skip_ws(s, i)
            if byte(s, i) ~= 58 then decode_error(s, i, "expected ':'") end
            local v
            v, i = decode_value(s, i + 1)
            obj[k] = v
            i = skip_ws(s, i)
            c = byte(s, i)
            if c == 125 then return obj, i + 1 end
            if c ~= 44 then decode_error(s, i, "expected ',' or '}'") end
            i = i + 1
        end
    elseif c == 91 then -- [
        local arr, n = M.array(), 0
        i = skip_ws(s, i + 1)
        if byte(s, i) == 93 then return arr, i + 1 end
        while true do
            local v
            v, i = decode_value(s, i)
            n = n + 1
            arr[n] = v
            i = skip_ws(s, i)
            c = byte(s, i)
            if c == 93 then return arr, i + 1 end
            if c ~= 44 then decode_error(s, i, "expected ',' or ']'") end
            i = i + 1
        end
    elseif c == 34 then
        return decode_string(s, i)
    elseif find(s, "^true", i) then
        return true, i + 4
    elseif find(s, "^false", i) then
        return false, i + 5
    elseif find(s, "^null", i) then
        return M.null, i + 4
    else
        local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
        if not num or num == "" then decode_error(s, i, "unexpected character") end
        return tonumber(num), i + #num
    end
end

function M.decode(s)
    local v, i = decode_value(s, 1)
    i = skip_ws(s, i)
    if i <= #s then decode_error(s, i, "trailing data") end
    return v
end

local function encode_string(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' elseif c == "\\" then return "\\\\"
        elseif c == "\n" then return "\\n" elseif c == "\r" then return "\\r" elseif c == "\t" then return "\\t" end
        return format("\\u%04x", byte(c))
    end) .. '"'
end

local function encode(v, out)
    local t = type(v)
    if v == nil or v == M.null then
        out[#out + 1] = "null"
    elseif t == "boolean" then
        out[#out + 1] = v and "true" or "false"
    elseif t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then
            out[#out + 1] = "null"
        elseif v == math.floor(v) and math.abs(v) < 2^53 then
            out[#out + 1] = format("%d", v)
        else
            out[#out + 1] = format("%.17g", v)
        end
    elseif t == "string" then
        out[#out + 1] = encode_string(v)
    elseif t == "table" then
        if getmetatable(v) == array_mt or #v > 0 then
            out[#out + 1] = "["
            for k = 1, #v do
                if k > 1 then out[#out + 1] = "," end
                encode(v[k], out)
            end
            out[#out + 1] = "]"
        else
            out[#out + 1] = "{"
            local first = true
            local keys = {}
            for k in pairs(v) do keys[#keys + 1] = tostring(k) end
            table.sort(keys)
            for _, k in ipairs(keys) do
                local val = v[k]
                if val == nil then val = v[tonumber(k)] end
                if not first then out[#out + 1] = "," end
                first = false
                out[#out + 1] = encode_string(k)
                out[#out + 1] = ":"
                encode(val, out)
            end
            out[#out + 1] = "}"
        end
    else
        error("json: cannot encode " .. t)
    end
end

function M.encode(v)
    local out = {}
    encode(v, out)
    return concat(out)
end

return M
