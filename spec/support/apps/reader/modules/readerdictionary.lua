-- Trimmed model of KOReader's ReaderDictionary: the parts the plugin hooks, with
-- the same shapes (available_ifos as an upvalue, sdcv results, placeholders).
local available_ifos = nil

local ReaderDictionary = {}
ReaderDictionary.__index = ReaderDictionary

ReaderDictionary.sdcv_db = {} -- [dict name] = { [word] = definition }
ReaderDictionary.stardict = {} -- list of { name, file }

function ReaderDictionary:new(o)
    o = setmetatable(o or {}, self)
    o:init()
    return o
end

function ReaderDictionary:init()
    self.dicts_order = {}
    if not available_ifos then
        available_ifos = {}
        for _, s in ipairs(ReaderDictionary.stardict) do
            table.insert(available_ifos, { file = s.file, name = s.name, is_html = s.is_html })
        end
        self:sortAvailableIfos()
    end
    self:updateSdcvDictNamesOptions()
end

function ReaderDictionary.reset() available_ifos = nil end

function ReaderDictionary:sortAvailableIfos()
    table.sort(available_ifos, function(a, b)
        local la, lb = self.dicts_order[a.file], self.dicts_order[b.file]
        if la == lb then return a.name < b.name end
        return la ~= nil and (lb == nil or la < lb)
    end)
end

function ReaderDictionary:updateSdcvDictNamesOptions()
    self.enabled_dict_names = {}
    local disabled = G_reader_settings:readSetting("dicts_disabled") or {}
    for _, ifo in ipairs(available_ifos) do
        if not disabled[ifo.file] then table.insert(self.enabled_dict_names, ifo.name) end
    end
end

local function getAvailableIfoByName(name)
    for _, ifo in ipairs(available_ifos) do
        if ifo.name == name then return ifo end
    end
end

function ReaderDictionary.tidyMarkup(results)
    for _, r in ipairs(results) do
        local ifo = getAvailableIfoByName(r.dict)
        if ifo and ifo.is_html then
            r.is_html = true
            r.css = ifo.css
        else
            r.definition = (r.definition or ""):gsub("<[^>]*>", "")
        end
    end
    return results
end

function ReaderDictionary:rawSdcv(words, dict_names)
    if #ReaderDictionary.stardict == 0 then return false, nil end
    self.sdcv_calls = (self.sdcv_calls or 0) + 1
    self.last_sdcv_names = dict_names
    local all = {}
    for _, w in ipairs(words) do
        local res = {}
        for _, s in ipairs(ReaderDictionary.stardict) do
            local wanted = dict_names == nil
            for _, n in ipairs(dict_names or {}) do if n == s.name then wanted = true end end
            local def = wanted and ReaderDictionary.sdcv_db[s.name] and ReaderDictionary.sdcv_db[s.name][w]
            if def then table.insert(res, { dict = s.name, word = w, definition = def }) end
        end
        table.insert(all, res)
    end
    return false, all
end

function ReaderDictionary:startSdcv(word, dict_names, fuzzy_search)
    local lookup_cancelled, results = self:rawSdcv({ word }, dict_names, fuzzy_search)
    if results == nil then
        return { { dict = "", word = word, definition = "No dictionaries installed." } }
    end
    local flat = {}
    for _, term in ipairs(results) do
        for _, r in ipairs(term) do table.insert(flat, r) end
    end
    if #flat == 0 then
        flat = { { dict = "Not available", word = word, definition = "No results.", no_result = true,
                   lookup_cancelled = lookup_cancelled } }
    end
    return flat
end

function ReaderDictionary:stardictLookup(word, dict_names, fuzzy_search, boxes, link)
    local results = self:startSdcv(word, dict_names, fuzzy_search)
    self:showDict(word, ReaderDictionary.tidyMarkup(results), boxes, link)
end

function ReaderDictionary:showDict(word, results)
    self.shown = { word = word, results = results }
end

function ReaderDictionary:onHtmlDictionaryLinkTapped(dictionary, link)
    if not link.uri then return end
    local word
    if link.uri:sub(1, 8) == "bword://" then
        word = link.uri:sub(9)
    elseif link.uri:find("://") then
        return
    else
        word = link.uri
    end
    if word == "" then return end
    self:stardictLookup(word, { dictionary }, false, {}, nil)
end

return ReaderDictionary
