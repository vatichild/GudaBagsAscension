local addonName, ns = ...

local RuleEngine = ns:GetModule("RuleEngine")

-------------------------------------------------
-- Quality Rule (Exact Match)
-- 0=Poor, 1=Common, 2=Uncommon, 3=Rare, 4=Epic, 5=Legendary
-------------------------------------------------

RuleEngine:RegisterEvaluator("quality", function(ruleValue, itemData, context)
    return itemData.quality == ruleValue
end)

-------------------------------------------------
-- Quality Min Rule (Minimum Quality)
-- Item quality must be >= ruleValue
-------------------------------------------------

RuleEngine:RegisterEvaluator("qualityMin", function(ruleValue, itemData, context)
    return (itemData.quality or 0) >= ruleValue
end)
