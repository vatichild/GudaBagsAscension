local addonName, ns = ...

local Expansion = ns:GetModule("Expansion")

-- Feature guard: the WoW currency system only exists on MoP/Retail. Register a
-- no-op stub elsewhere so callers don't need to guard.
if not (Expansion and Expansion.Features and Expansion.Features.HasCurrency) then
    ns:RegisterModule("CurrencyScanner", {
        ScanCurrencies = function() end,
        SaveToDatabase = function() end,
    })
    return
end

local CurrencyScanner = {}
ns:RegisterModule("CurrencyScanner", CurrencyScanner)

local Database = ns:GetModule("Database")
local Events = ns:GetModule("Events")

local cachedCurrencies = {}
local saveTimer = nil
local SAVE_DELAY = 1.0

-- API abstraction: Retail uses the C_CurrencyInfo namespace, MoP Classic uses globals.
local GetListSize = (C_CurrencyInfo and C_CurrencyInfo.GetCurrencyListSize) or GetCurrencyListSize
local GetListInfo = (C_CurrencyInfo and C_CurrencyInfo.GetCurrencyListInfo) or GetCurrencyListInfo
local GetListLink = (C_CurrencyInfo and C_CurrencyInfo.GetCurrencyListLink) or GetCurrencyListLink
local ExpandList = (C_CurrencyInfo and C_CurrencyInfo.ExpandCurrencyList) or ExpandCurrencyList

local function GetCurrencyIDFromLink(link)
    if not link then return nil end
    local id = link:match("currency:(%d+)")
    return id and tonumber(id)
end

-- Normalize GetCurrencyListInfo: a table on Retail, multiple returns on MoP.
-- Returns: name, isHeader, isExpanded, quantity
local function NormalizeListInfo(result, ...)
    if type(result) == "table" then
        return result.name, result.isHeader, result.isHeaderExpanded, result.quantity
    elseif result ~= nil then
        -- MoP: name, isHeader, isExpanded, isUnused, isWatched, count, ...
        local name = result
        local isHeader, isExpanded, _, _, count = ...
        return name, isHeader, isExpanded, count
    end
    return nil
end

function CurrencyScanner:ScanCurrencies()
    if not GetListSize or not GetListInfo then return end

    -- Collapsed headers hide their child currencies from the list API. Expand them
    -- all first. Iterate downward so expanding (which inserts rows AFTER index i)
    -- never invalidates a not-yet-visited index.
    if ExpandList then
        for i = (GetListSize() or 0), 1, -1 do
            local _, isHeader, isExpanded = NormalizeListInfo(GetListInfo(i))
            if isHeader and isExpanded == false then
                ExpandList(i, true)
            end
        end
    end

    local result = {}
    local size = GetListSize() or 0
    for i = 1, size do
        local name, isHeader, _, quantity = NormalizeListInfo(GetListInfo(i))
        if name and not isHeader then
            local currencyID = GetCurrencyIDFromLink(GetListLink and GetListLink(i))
            if currencyID and quantity and quantity > 0 then
                result[currencyID] = quantity
            end
        end
    end

    cachedCurrencies = result
    return result
end

function CurrencyScanner:SaveToDatabase()
    Database:SaveCurrencies(cachedCurrencies)
end

local function ScheduleDeferredSave()
    if saveTimer then
        saveTimer:Cancel()
    end
    saveTimer = C_Timer.NewTimer(SAVE_DELAY, function()
        CurrencyScanner:ScanCurrencies()
        CurrencyScanner:SaveToDatabase()
        saveTimer = nil
    end)
end

Events:Register("CURRENCY_DISPLAY_UPDATE", function()
    ScheduleDeferredSave()
end, CurrencyScanner)

Events:OnPlayerLogin(function()
    -- Scan immediately so the current character's data is available for tooltips
    -- right away (Database character data is initialized earlier in PLAYER_LOGIN).
    CurrencyScanner:ScanCurrencies()
    CurrencyScanner:SaveToDatabase()
end, CurrencyScanner)
