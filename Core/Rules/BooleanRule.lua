local addonName, ns = ...

local RuleEngine = ns:GetModule("RuleEngine")
local Utils = ns:GetModule("Utils")

local function IsSoulShard(itemData)
    return itemData.itemID == 6265 or
           (itemData.name and itemData.name:find("Soul Shard"))
end

local function IsProjectile(itemData)
    return itemData.itemType == "Projectile" or
           itemData.itemSubType == "Arrow" or
           itemData.itemSubType == "Bullet"
end

-------------------------------------------------
-- Quest Item Rule
-- Uses isQuestItem flag from ItemScanner
-------------------------------------------------

RuleEngine:RegisterEvaluator("isQuestItem", function(ruleValue, itemData, context)
    return (itemData.isQuestItem == true) == ruleValue
end)

-------------------------------------------------
-- Profession Tool Rule
-- Fishing poles, mining picks, skinning knives, etc.
-------------------------------------------------

RuleEngine:RegisterEvaluator("isProfessionTool", function(ruleValue, itemData, context)
    return Utils:IsProfessionTool(itemData) == ruleValue
end)

-------------------------------------------------
-- Soul Shard Rule
-- Warlock soul shards (item ID 6265)
-------------------------------------------------

RuleEngine:RegisterEvaluator("isSoulShard", function(ruleValue, itemData, context)
    return IsSoulShard(itemData) == ruleValue
end)

-------------------------------------------------
-- Projectile Rule
-- Arrows and bullets
-------------------------------------------------

RuleEngine:RegisterEvaluator("isProjectile", function(ruleValue, itemData, context)
    return IsProjectile(itemData) == ruleValue
end)
