-- KOReader stub for specs (only what the plugin uses outside KOReader-only modules)
local M = {}
function M.template(s, ...)
    local args = { ... }
    return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
end
return M
