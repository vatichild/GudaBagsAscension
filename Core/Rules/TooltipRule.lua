local addonName, ns = ...

local RuleEngine = ns:GetModule("RuleEngine")
local Utils = ns:GetModule("Utils")
local Constants = ns.Constants

-------------------------------------------------
-- Bind on Equip Rule
-- Requires tooltip scan (not available for other characters)
-------------------------------------------------

RuleEngine:RegisterEvaluator("isBoE", function(ruleValue, itemData, context)
    -- Can't scan tooltips for other characters
    if context.isOtherChar then
        return false
    end

    local TooltipScanner = ns:GetModule("TooltipScanner")
    if not TooltipScanner then
        return false
    end

    local isBoE = TooltipScanner:IsBindOnEquip(context.bagID, context.slotID, itemData)
    return isBoE == ruleValue
end)

-------------------------------------------------
-- Warbound Rule (Retail only)
-- Requires tooltip scan (not available for other characters)
-------------------------------------------------

if ns.IsRetail then
    RuleEngine:RegisterEvaluator("isWarbound", function(ruleValue, itemData, context)
        -- Can't scan tooltips for other characters
        if context.isOtherChar then
            return false
        end

        local TooltipScanner = ns:GetModule("TooltipScanner")
        if not TooltipScanner then
            return false
        end

        local isWarbound = TooltipScanner:IsWarbound(context.bagID, context.slotID)
        return isWarbound == ruleValue
    end)
end

-------------------------------------------------
-- Restore Tag Rule (Food/Drink/Restore)
-- Requires tooltip scan
-------------------------------------------------

RuleEngine:RegisterEvaluator("restoreTag", function(ruleValue, itemData, context)
    -- Can't scan tooltips for other characters
    if context.isOtherChar then
        return false
    end

    local TooltipScanner = ns:GetModule("TooltipScanner")
    if not TooltipScanner then
        return false
    end

    local tag = TooltipScanner:GetRestoreTag(context.bagID, context.slotID, itemData)
    return tag == ruleValue
end)

-------------------------------------------------
-- Junk Item Rule
-- Gray quality OR white equippable without special properties
-------------------------------------------------

RuleEngine:RegisterEvaluator("isJunk", function(ruleValue, itemData, context)
    -- Skip items with incomplete data (GetItemInfo not cached yet)
    if not itemData.name or itemData.name == "" then
        return false == ruleValue
    end

    -- User-marked junk overrides quality, profession-tool protection, and
    -- special-properties checks. Mark state is per-character (CharDB), so
    -- only honored when not viewing another character's bags.
    if not context.isOtherChar and itemData.itemID then
        local Database = ns:GetModule("Database")
        if Database and Database:IsItemMarkedJunk(itemData.itemID) then
            return true == ruleValue
        end
    end

    -- For other characters, only check quality
    if context.isOtherChar then
        return (itemData.quality == 0) == ruleValue
    end

    -- Profession tools are never junk
    if Utils:IsProfessionTool(itemData) then
        return false == ruleValue
    end

    -- Gray items are always junk
    if itemData.quality == 0 then
        return true == ruleValue
    end

    -- White equippable items might be junk (only if setting is enabled)
    if itemData.quality == 1 then
        local Database = ns:GetModule("Database")
        local whiteItemsJunk = Database and Database:GetSetting("whiteItemsJunk") or false

        if whiteItemsJunk and (itemData.itemType == "Armor" or itemData.itemType == "Weapon") then
            local equipSlot = itemData.equipSlot
            if equipSlot and equipSlot ~= "" then
                -- Trinkets, rings, necks, shirts, tabards, off-hands, relics are never junk
                if Constants.VALUABLE_EQUIP_SLOTS[equipSlot] then
                    return false == ruleValue
                end

                -- Check for special properties using TooltipScanner
                local TooltipScanner = ns:GetModule("TooltipScanner")
                if TooltipScanner and context.bagID and context.slotID then
                    if TooltipScanner:HasSpecialProperties(context.bagID, context.slotID) then
                        return false == ruleValue
                    end
                end

                -- White equippable without special properties = junk
                return true == ruleValue
            end
        end
    end

    return false == ruleValue
end)
