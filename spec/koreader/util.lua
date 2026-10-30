-- Stub of KOReader's util (only what the widget code paths use)
local util = {}
function util.bsearch_left(list, v)
    for i, x in ipairs(list) do if x >= v then return i end end
    return #list + 1
end
function util.bsearch_right(list, v)
    for i, x in ipairs(list) do if x > v then return i end end
    return #list + 1
end
function util.tableDeepCopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = util.tableDeepCopy(v) end
    return o
end
return util
