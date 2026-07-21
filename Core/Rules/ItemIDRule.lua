local addonName, ns = ...

local RuleEngine = ns:GetModule("RuleEngine")

-------------------------------------------------
-- Item ID Rule
-- Matches specific item ID or array of IDs
-------------------------------------------------

RuleEngine:RegisterEvaluator("itemID", function(ruleValue, itemData, context)
    if not itemData.itemID then
        return false
    end

    -- Handle array of IDs
    if type(ruleValue) == "table" then
        for _, id in ipairs(ruleValue) do
            if itemData.itemID == id then
                return true
            end
        end
        return false
    end

    -- Single ID match
    return itemData.itemID == ruleValue
end)
