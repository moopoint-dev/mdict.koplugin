-- Stub of KOReader's ui/bidi
local BD = {}
function BD.mirroredUILayout() return false end
function BD.flipIfMirroredUILayout(x) return x end
function BD.flipDirectionIfMirroredUILayout(d) return d end
return BD
