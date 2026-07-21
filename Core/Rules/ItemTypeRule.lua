local addonName, ns = ...

local RuleEngine = ns:GetModule("RuleEngine")
local Utils = ns:GetModule("Utils")

-------------------------------------------------
-- Item Type Rule
-- Matches GetItemInfo itemType (Armor, Weapon, Consumable, etc.)
-------------------------------------------------

RuleEngine:RegisterEvaluator("itemType", function(ruleValue, itemData, context)
    -- Profession tools should not match Weapon category
    if ruleValue == "Weapon" and Utils:IsProfessionTool(itemData) then
        return false
    end
    return itemData.itemType == ruleValue
end)

-------------------------------------------------
-- Item Subtype Rule
-- Matches GetItemInfo itemSubType
-------------------------------------------------

RuleEngine:RegisterEvaluator("itemSubtype", function(ruleValue, itemData, context)
    local subtype = itemData.itemSubType or ""

    -- Check for exact match first
    if subtype == ruleValue then
        return true
    end

    -- Check for partial match (e.g., "Soul Bag" matching "Soul Bag")
    if subtype:find(ruleValue, 1, true) then
        return true
    end

    return false
end)

-------------------------------------------------
-- Reagent Rule (Crafting Materials)
-- Trade Goods (classID 7) excluding Explosives (2) and Devices (3)
-------------------------------------------------

RuleEngine:RegisterEvaluator("isReagent", function(ruleValue, itemData, context)
    -- Reagent = Trade Goods (classID 7) excluding Explosives (subClassID 2) and Devices (subClassID 3)
    if itemData.classID == 7 then
        return itemData.subClassID ~= 2 and itemData.subClassID ~= 3
    end
    return false
end)
