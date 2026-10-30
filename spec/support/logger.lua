-- KOReader stub for specs
local M = { lines = {} }
for _, l in ipairs({ "dbg", "info", "warn", "err" }) do
    M[l] = function(...) table.insert(M.lines, { l, ... }) end
end
return M
