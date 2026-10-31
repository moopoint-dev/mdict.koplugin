-- Stub of KOReader's UIManager for widget specs: records scheduled tasks (and the delay
-- of each) and dirty regions
local UIManager = { tasks = {}, dirty = {}, delays = setmetatable({}, { __mode = "k" }) }
function UIManager:scheduleIn(seconds, fn)
    self.delays[fn] = seconds
    table.insert(self.tasks, fn)
end
function UIManager:nextTick(fn) table.insert(self.tasks, fn) end
function UIManager:unschedule(fn)
    for i = #self.tasks, 1, -1 do if self.tasks[i] == fn then table.remove(self.tasks, i) end end
end
function UIManager:runTasks()
    local t = self.tasks
    self.tasks = {}
    for _, fn in ipairs(t) do fn() end
end
function UIManager:setDirty(w, f) table.insert(self.dirty, { w, f }) end
function UIManager:getTime() return 0 end
function UIManager:show() end
function UIManager:close() end
return UIManager
