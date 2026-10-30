-- Trimmed model of KOReader's DictQuickLookup widget switching.
local DictQuickLookup = {}
DictQuickLookup.__index = DictQuickLookup

function DictQuickLookup:new(o)
    o = setmetatable(o or {}, self)
    o.dict_index = 1
    o.definition_widget = {}
    o:_instantiateScrollWidget()
    return o
end

function DictQuickLookup:_instantiateScrollWidget()
    local r = self.results[self.dict_index]
    if r.is_html then
        self.shw_widget = { kind = "html", body = r.definition, free = function() end }
        self.text_widget = self.shw_widget
    else
        self.stw_widget = { kind = "text", text = r.definition, free = function() end }
        self.text_widget = self.stw_widget
    end
end

function DictQuickLookup:update()
    if self.text_widget and self.text_widget.free then self.text_widget:free() end
    local r = self.results[self.dict_index]
    if r.is_html and self.shw_widget then
        self.shw_widget.body = r.definition
    elseif not r.is_html and self.stw_widget then
        self.stw_widget.text = r.definition
    else
        self:_instantiateScrollWidget()
        self.definition_widget[1] = self.text_widget
        if r.is_html then self.stw_widget = nil else self.shw_widget = nil end
    end
end

function DictQuickLookup:changeDictionary(i)
    self.dict_index = i
    self:update()
end

return DictQuickLookup
