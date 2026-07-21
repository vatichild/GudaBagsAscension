local addonName, ns = ...

local EquipmentSets = {}
ns:RegisterModule("EquipmentSets", EquipmentSets)

local Events = ns:GetModule("Events")

-- Lookup table: itemID -> { setName1 = true, setName2 = true, ... }
local itemSets = {}

-- Track which sources are available
local hasItemRack = false
local hasOutfitter = false
local hasBlizzardSets = false

-------------------------------------------------
-- Rebuild helpers
-------------------------------------------------

local function WipeTable(t)
    for k in pairs(t) do
        t[k] = nil
    end
end

local function AddItem(itemID, setName)
    if not itemID or itemID == 0 then return end
    if not itemSets[itemID] then
        itemSets[itemID] = {}
    end
    itemSets[itemID][setName] = true
end

-------------------------------------------------
-- ItemRack (Classic Era / TBC)
-------------------------------------------------

local function ScanItemRack()
    if not ItemRackUser or not ItemRackUser.Sets then return end

    for setName, details in pairs(ItemRackUser.Sets) do
        -- Skip internal sets (prefixed with ~)
        if not setName:find("^~") and details.equip then
            for _, itemRef in pairs(details.equip) do
                -- ItemRack stores items as "itemID:enchant:gem1:gem2:..." strings
                -- or as numbers depending on version
                local itemID
                if type(itemRef) == "number" then
                    itemID = itemRef
                elseif type(itemRef) == "string" then
                    itemID = tonumber(itemRef:match("^(%d+)"))
                end
                if itemID and itemID > 0 then
                    AddItem(itemID, setName)
                end
            end
        end
    end
end

-------------------------------------------------
-- Outfitter
-------------------------------------------------

local function ScanOutfitter()
    if not Outfitter_GetCategoryOrder or not Outfitter_GetOutfitsByCategoryID then return end

    local categories = Outfitter_GetCategoryOrder()
    if not categories then return end

    for _, catID in ipairs(categories) do
        local outfits = Outfitter_GetOutfitsByCategoryID(catID)
        if outfits then
            for _, outfit in ipairs(outfits) do
                local name = outfit.GetName and outfit:GetName() or outfit.Name or "Outfit"
                local items = outfit.GetItems and outfit:GetItems()
                if items then
                    for _, item in pairs(items) do
                        if item and item.Code then
                            local code = tonumber(item.Code)
                            if code and code > 0 then
                                AddItem(code, name)
                            end
                        end
                    end
                end
            end
        end
    end
end

-------------------------------------------------
-- Blizzard Equipment Manager (Retail / Wrath+)
-------------------------------------------------

local function ScanBlizzardSets()
    if not C_EquipmentSet then return end

    local setIDs = C_EquipmentSet.GetEquipmentSetIDs()
    if not setIDs then return end

    for _, setID in ipairs(setIDs) do
        local name = C_EquipmentSet.GetEquipmentSetInfo(setID)
        if name then
            local itemIDs = C_EquipmentSet.GetItemIDs(setID)
            if itemIDs then
                for _, itemID in pairs(itemIDs) do
                    if itemID and itemID > 0 then
                        AddItem(itemID, name)
                    end
                end
            end
        end
    end
end

-------------------------------------------------
-- Full rebuild from all sources
-------------------------------------------------

local function RebuildAll()
    WipeTable(itemSets)

    if hasItemRack then
        ScanItemRack()
    end
    if hasOutfitter then
        ScanOutfitter()
    end
    if hasBlizzardSets then
        ScanBlizzardSets()
    end

    -- Prune stale set protection exceptions
    local Database = ns:GetModule("Database")
    if Database then
        Database:PruneSetProtectionExceptions(function(itemID)
            return itemSets[itemID] ~= nil
        end)
    end

    -- Sync persisted equipment set categories and invalidate caches
    local CategoryManager = ns:GetModule("CategoryManager")
    if CategoryManager then
        CategoryManager:SyncEquipmentSetCategories()
        CategoryManager:ClearCategoryCache()
        CategoryManager:InvalidatePriorityCache()
    end
    Events:Fire("CATEGORIES_UPDATED")
end

-------------------------------------------------
-- Public API
-------------------------------------------------

function EquipmentSets:IsInSet(itemID)
    if not itemID then return false end
    return itemSets[itemID] ~= nil
end

function EquipmentSets:GetSetNames(itemID)
    if not itemID or not itemSets[itemID] then return nil end

    local names = {}
    for name in pairs(itemSets[itemID]) do
        names[#names + 1] = name
    end
    return names
end

function EquipmentSets:GetAllSetNames()
    local names = {}
    local seen = {}
    for _, sets in pairs(itemSets) do
        for name in pairs(sets) do
            if not seen[name] then
                seen[name] = true
                names[#names + 1] = name
            end
        end
    end
    table.sort(names)
    return names
end

-------------------------------------------------
-- Source initialization
-------------------------------------------------

local function InitOutfitter()
    if hasOutfitter then return end
    hasOutfitter = true

    RebuildAll()

    -- Listen for Outfitter's own change events
    if Outfitter_RegisterOutfitEvent then
        Outfitter_RegisterOutfitEvent("ADD_OUTFIT", RebuildAll)
        Outfitter_RegisterOutfitEvent("DELETE_OUTFIT", RebuildAll)
        Outfitter_RegisterOutfitEvent("EDIT_OUTFIT", RebuildAll)
        Outfitter_RegisterOutfitEvent("DID_RENAME_OUTFIT", RebuildAll)
    end
end

local function InitItemRack()
    if hasItemRack then return end
    hasItemRack = true

    RebuildAll()
end

-------------------------------------------------
-- Helper: check addon loaded (Classic vs Retail API)
-------------------------------------------------

local function CheckAddonLoaded(name)
    if C_AddOns and C_AddOns.IsAddOnLoaded then
        return C_AddOns.IsAddOnLoaded(name)
    elseif IsAddOnLoaded then
        return IsAddOnLoaded(name)
    end
    return false
end

-------------------------------------------------
-- Event registration
-------------------------------------------------

-- Blizzard Equipment Manager (available immediately if API exists)
if C_EquipmentSet and C_EquipmentSet.GetEquipmentSetIDs then
    hasBlizzardSets = true

    Events:Register("EQUIPMENT_SETS_CHANGED", function()
        RebuildAll()
    end, EquipmentSets)
end

-- Listen for addon loads (ItemRack, Outfitter may load after us)
Events:Register("ADDON_LOADED", function(event, loadedAddon)
    if loadedAddon == "ItemRack" then
        InitItemRack()
    elseif loadedAddon == "Outfitter" then
        -- Outfitter may not be fully initialized at ADDON_LOADED
        -- Must wait for OUTFITTER_INIT event before scanning
        if Outfitter_IsInitialized and Outfitter_IsInitialized() then
            InitOutfitter()
        elseif Outfitter_RegisterOutfitEvent then
            Outfitter_RegisterOutfitEvent("OUTFITTER_INIT", InitOutfitter)
        else
            InitOutfitter()
        end
    end
end, EquipmentSets)

-- On login, check if addons loaded before us (missed their ADDON_LOADED)
Events:OnPlayerLogin(function()
    if CheckAddonLoaded("ItemRack") and not hasItemRack then
        InitItemRack()
    end

    if CheckAddonLoaded("Outfitter") and not hasOutfitter then
        if Outfitter_IsInitialized and Outfitter_IsInitialized() then
            InitOutfitter()
        elseif Outfitter_RegisterOutfitEvent then
            Outfitter_RegisterOutfitEvent("OUTFITTER_INIT", InitOutfitter)
        else
            InitOutfitter()
        end
    end

    if hasBlizzardSets then
        RebuildAll()
    end
end, EquipmentSets)

-- Sync equipment set categories when the setting is toggled
Events:Register("SETTING_CHANGED", function(event, key, value)
    if key == "showEquipSetCategories" then
        local CategoryManager = ns:GetModule("CategoryManager")
        if CategoryManager then
            CategoryManager:SyncEquipmentSetCategories()
            CategoryManager:ClearCategoryCache()
            CategoryManager:InvalidatePriorityCache()
        end
        Events:Fire("CATEGORIES_UPDATED")
    end
end, EquipmentSets)

Events:Register("PROFILE_LOADED", function()
    local CategoryManager = ns:GetModule("CategoryManager")
    if CategoryManager then
        CategoryManager:SyncEquipmentSetCategories()
    end
end, EquipmentSets)
