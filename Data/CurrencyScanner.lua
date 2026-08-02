local addonName, ns = ...

local Expansion = ns:GetModule("Expansion")

-- Feature guard: a client without a currency system registers a no-op stub so
-- callers don't need to guard. On 3.3.5a the system does exist (addressed through
-- globals rather than C_CurrencyInfo), so this passes -- see Core\Expansion.lua.
if not (Expansion and Expansion.Features and Expansion.Features.HasCurrency) then
    ns:RegisterModule("CurrencyScanner", {
        ScanCurrencies = function() end,
        SaveToDatabase = function() end,
    })
    return
end

local CurrencyScanner = {}
ns:RegisterModule("CurrencyScanner", CurrencyScanner)

local API = ns:GetModule("Compatibility.API")
local Database = ns:GetModule("Database")
local Events = ns:GetModule("Events")
local ScannerBase = ns:GetModule("ScannerBase")

local cachedCurrencies = {}
local lastListSize = nil
local isScanning = false
local SAVE_DELAY = 1.0

-- Collapsed headers hide their child currencies from the list API, so the list
-- has to be fully expanded before it can be read.
--
-- This is not free and it is not idempotent-cheap: it walks the whole list and
-- it permanently changes the player's token-frame expansion state. It used to
-- run on every CURRENCY_DISPLAY_UPDATE -- which in a battleground is every honor
-- tick. Run it once, then only when the list length actually changes (a new
-- currency appearing is what adds rows).
local function ExpandAllHeaders()
    local size = API:GetCurrencyListSize()
    if size == 0 then return 0 end
    if lastListSize == size then return size end

    -- Iterate downward so expanding (which inserts rows AFTER index i) never
    -- invalidates a not-yet-visited index.
    for i = size, 1, -1 do
        local _, isHeader, isExpanded = API:GetCurrencyListInfo(i)
        if isHeader and isExpanded == false then
            API:ExpandCurrencyList(i)
        end
    end

    size = API:GetCurrencyListSize()
    lastListSize = size
    return size
end

function CurrencyScanner:ScanCurrencies()
    if isScanning then return cachedCurrencies end

    -- Expanding a header can itself fire CURRENCY_DISPLAY_UPDATE, which re-enters
    -- the deferred saver and back into here. Hold the door shut for the duration.
    isScanning = true

    local size = ExpandAllHeaders()

    local result = {}
    for i = 1, size do
        local name, isHeader, _, _, quantity, extraCurrencyType, _, itemID = API:GetCurrencyListInfo(i)
        if name and not isHeader then
            local key = API:GetCurrencyKey(itemID, extraCurrencyType)
            if key and quantity and quantity > 0 then
                result[key] = quantity
            end
        end
    end

    isScanning = false
    cachedCurrencies = result
    return result
end

function CurrencyScanner:SaveToDatabase()
    Database:SaveCurrencies(cachedCurrencies)
end

local saver = ScannerBase:CreateDeferredSaver(function()
    CurrencyScanner:ScanCurrencies()
    CurrencyScanner:SaveToDatabase()
end, SAVE_DELAY)

Events:Register("CURRENCY_DISPLAY_UPDATE", function()
    if isScanning then return end
    saver:Schedule()
end, CurrencyScanner)

Events:OnPlayerLogin(function()
    -- Scan immediately so the current character's data is available for tooltips
    -- right away (Database character data is initialized earlier in PLAYER_LOGIN).
    --
    -- The server may not have sent the currency list yet, in which case the list
    -- reads as empty. Don't treat that as "this character owns nothing" -- leave
    -- it to the first CURRENCY_DISPLAY_UPDATE, and let Database:SaveCurrencies
    -- refuse to overwrite good data with an empty table either way.
    CurrencyScanner:ScanCurrencies()
    if next(cachedCurrencies) then
        CurrencyScanner:SaveToDatabase()
    end
end, CurrencyScanner)
