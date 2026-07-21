local addonName, ns = ...

local RuleEngine = ns:GetModule("RuleEngine")

-------------------------------------------------
-- Name Pattern Rule
-- Lua pattern match on item name (case-insensitive)
-------------------------------------------------

RuleEngine:RegisterEvaluator("namePattern", function(ruleValue, itemData, context)
    if not itemData.name then
        return false
    end

    -- Case-insensitive search
    return itemData.name:lower():find(ruleValue:lower()) ~= nil
end)

-------------------------------------------------
-- Tooltip Contains Rule
-- Case-insensitive plain-substring search across all tooltip lines.
-- Unlike namePattern, this scans the full hidden tooltip (flavor text,
-- Use/Equip effects, class restrictions, set bonuses, etc.).
-------------------------------------------------

RuleEngine:RegisterEvaluator("tooltipPattern", function(ruleValue, itemData, context)
    if not ruleValue or ruleValue == "" then
        return false
    end

    local TooltipScanner = ns:GetModule("TooltipScanner")
    if not TooltipScanner then
        return false
    end

    -- Prefer hyperlink (also works for cached/cross-character views). Fall back
    -- to the bag slot when link isn't yet populated during initial scans.
    local loaded = false
    local link = itemData.link or itemData.itemLink
    if link then
        loaded = TooltipScanner:SetHyperlink(link)
    elseif context and context.bagID ~= nil and context.slotID then
        loaded = TooltipScanner:SetBagItem(context.bagID, context.slotID)
    end
    if not loaded then
        return false
    end

    local needle = ruleValue:lower()
    local match = false
    TooltipScanner:ScanLines(function(_, text)
        if text and text:lower():find(needle, 1, true) then
            match = true
            return true  -- stop scan
        end
    end)
    return match
end)

-------------------------------------------------
-- Texture Pattern Rule
-- Pattern match on icon texture path
-------------------------------------------------

RuleEngine:RegisterEvaluator("texturePattern", function(ruleValue, itemData, context)
    if not itemData.texture then
        return false
    end

    local texturePath = tostring(itemData.texture)
    return texturePath:find(ruleValue) ~= nil
end)
