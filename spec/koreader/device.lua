-- Stub of KOReader's Device for widget specs
local Screen = {}
function Screen:scaleBySize(x) return x end
function Screen:getWidth() return 1200 end
function Screen:getHeight() return 1600 end
function Screen:isColorEnabled() return false end
function Screen:getDPI() return 300 end
local Device = { screen = Screen, input = { group = { PgFwd = {}, PgBack = {} } } }
function Device:isTouchDevice() return true end
function Device:hasKeys() return false end
function Device:hasEinkScreen() return true end
function Device:hasDPad() return false end
function Device:hasKeyboard() return false end
function Device:isKindle() return false end
return Device
