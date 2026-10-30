-- Stub of KOReader's dbg
local dbg = { is_on = false }
function dbg.guard() end
function dbg.dassert(x) return x end
setmetatable(dbg, { __call = function() end })
return dbg
