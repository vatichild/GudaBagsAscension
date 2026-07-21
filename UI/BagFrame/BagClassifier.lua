local addonName, ns = ...

local BagClassifier = {}
ns:RegisterModule("BagFrame.BagClassifier", BagClassifier)

local Constants = ns.Constants

-- Map bag container subClassID to bag type string
local subClassToBagType = {
    [0] = "regular",
    [1] = "soul",
    [2] = "herb",
    [3] = "enchant",
    [4] = "engineering",
    [5] = "gem",
    [6] = "mining",
    [7] = "leatherworking",
    [8] = "inscription",
}

-- All supported bag types for classification
local BAG_TYPES = {
    "regular", "reagent", "enchant", "herb", "soul", "quiver", "ammo",
    "engineering", "mining", "gem", "leatherworking", "inscription"
}

-- Get bag type from container item ID (for cached bags)
function BagClassifier:GetBagTypeFromItemID(itemID)
    if not itemID then
        return "regular"
    end

    local _, _, _, _, _, classID, subClassID = C_Item.GetItemInfoInstant(itemID)

    -- If item info isn't available, default to regular
    if not classID then
        return "regular"
    end

    -- Numeric literals rather than Enum.ItemClass: Enum does not exist on 3.3.5a
    -- and the shim's stub yields nil for every field, which made both of these
    -- comparisons silently unreachable (number == nil).
    local ITEM_CLASS_CONTAINER, ITEM_CLASS_QUIVER = 1, 11

    -- Quiver class items
    if classID == ITEM_CLASS_QUIVER then
        return "quiver"
    end

    -- Only apply subclass mapping to Container class items
    if classID == ITEM_CLASS_CONTAINER and subClassID then
        return subClassToBagType[subClassID] or "regular"
    end

    return "regular"
end

-- Get specialized bag type for live bags
function BagClassifier:GetBagType(bagID)
    -- Backpack and main bank are always regular
    if bagID == Constants.PLAYER_BAG_MIN or bagID == Constants.BANK_MAIN_BAG then
        return "regular"
    end

    -- Retail: Reagent bag is always bag ID 5
    if Constants.REAGENT_BAG and bagID == Constants.REAGENT_BAG then
        return "reagent"
    end

    -- Try using bagFamily from container API first (most reliable when container is open)
    local numSlots = C_Container.GetContainerNumSlots(bagID)
    if numSlots and numSlots > 0 then
        local numFreeSlots, bagFamily = C_Container.GetContainerNumFreeSlots(bagID)
        if bagFamily and bagFamily > 0 then
            if bit.band(bagFamily, 1) ~= 0 then return "quiver" end
            if bit.band(bagFamily, 2) ~= 0 then return "ammo" end
            if bit.band(bagFamily, 4) ~= 0 then return "soul" end
            if bit.band(bagFamily, 8) ~= 0 then return "leatherworking" end
            if bit.band(bagFamily, 16) ~= 0 then return "inscription" end
            if bit.band(bagFamily, 32) ~= 0 then return "herb" end
            if bit.band(bagFamily, 64) ~= 0 then return "enchant" end
            if bit.band(bagFamily, 128) ~= 0 then return "engineering" end
            if bit.band(bagFamily, 512) ~= 0 then return "gem" end
            if bit.band(bagFamily, 1024) ~= 0 then return "mining" end
        end
    end

    -- Fallback: try using item info (for when container isn't open)
    -- Use C_Container.ContainerIDToInventoryID which works for both player bags and bank bags in all versions
    local invSlot = nil
    if (bagID >= 1 and bagID <= Constants.PLAYER_BAG_MAX) or
       (bagID >= Constants.BANK_BAG_MIN and bagID <= Constants.BANK_BAG_MAX) then
        invSlot = C_Container.ContainerIDToInventoryID(bagID)
    end

    if invSlot then
        local itemID = GetInventoryItemID("player", invSlot)
        if itemID then
            return self:GetBagTypeFromItemID(itemID)
        end
    end

    return "regular"
end

-- Get bag type for a bag (works for both live and cached)
function BagClassifier:GetBagTypeForBag(bagID, bagData, isViewingCached)
    if isViewingCached and bagData then
        -- Prefer containerItemID method, fallback to stored bagType
        if bagData.containerItemID then
            return self:GetBagTypeFromItemID(bagData.containerItemID)
        end
        return bagData.bagType or "regular"
    end
    return self:GetBagType(bagID)
end

-- Classify all bags into categories
-- Returns a table with bag type as key and array of bagIDs as value
-- bagIDs parameter is optional, defaults to Constants.BAG_IDS
function BagClassifier:ClassifyBags(bags, isViewingCached, bagIDs)
    local classified = {}
    for _, bagType in ipairs(BAG_TYPES) do
        classified[bagType] = {}
    end

    -- Guard against nil bags (can happen during loading or race conditions)
    if not bags then
        return classified
    end

    bagIDs = bagIDs or Constants.BAG_IDS

    for _, bagID in ipairs(bagIDs) do
        local bagData = bags[bagID]
        if bagData or not isViewingCached then
            local bagType = self:GetBagTypeForBag(bagID, bagData, isViewingCached)

            if not classified[bagType] then
                classified[bagType] = {}
            end

            if bagData or not isViewingCached then
                table.insert(classified[bagType], bagID)
            end
        end
    end

    return classified
end

-- Get bag types list (for iteration)
function BagClassifier:GetBagTypes()
    return BAG_TYPES
end
