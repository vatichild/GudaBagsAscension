local addonName, ns = ...

local TooltipScanner = {}
ns:RegisterModule("TooltipScanner", TooltipScanner)

-------------------------------------------------
-- Tooltip Management
-------------------------------------------------

local scanningTooltip = nil
local TOOLTIP_NAME = "GudaBagsScanningTooltip"

function TooltipScanner:GetTooltip()
    if not scanningTooltip then
        scanningTooltip = CreateFrame("GameTooltip", TOOLTIP_NAME, nil, "GameTooltipTemplate")
        scanningTooltip:SetOwner(WorldFrame, "ANCHOR_NONE")
    end
    return scanningTooltip
end

function TooltipScanner:SetBagItem(bagID, slotID)
    if not bagID or not slotID then return false end

    local tooltip = self:GetTooltip()
    tooltip:SetOwner(WorldFrame, "ANCHOR_NONE")
    tooltip:ClearLines()

    if bagID == -1 then
        -- BANK_CONTAINER's 28 main slots use inventory slot IDs, not bag/slot.
        -- tooltip:SetBagItem(-1, slot) does not reliably return per-slot data
        -- (e.g. "X Charges") in Classic. Mirrors UI/Tooltip.lua:208-219.
        local invSlot = BankButtonIDToInvSlotID and BankButtonIDToInvSlotID(slotID)
        if invSlot then
            tooltip:SetInventoryItem("player", invSlot)
        end
    else
        tooltip:SetBagItem(bagID, slotID)
    end

    return tooltip:NumLines() and tooltip:NumLines() > 0
end

function TooltipScanner:SetHyperlink(link)
    if not link then return false end

    local tooltip = self:GetTooltip()
    tooltip:SetOwner(WorldFrame, "ANCHOR_NONE")
    tooltip:ClearLines()
    tooltip:SetHyperlink(link)

    return tooltip:NumLines() and tooltip:NumLines() > 0
end

-------------------------------------------------
-- Line Access
-------------------------------------------------

function TooltipScanner:GetLineText(lineNumber)
    local tooltip = self:GetTooltip()
    local leftText = _G[TOOLTIP_NAME .. "TextLeft" .. lineNumber]

    if leftText and leftText:IsShown() then
        return leftText:GetText()
    end
    return nil
end

function TooltipScanner:GetNumLines()
    local tooltip = self:GetTooltip()
    return tooltip:NumLines() or 0
end

-------------------------------------------------
-- Scanning Functions
-------------------------------------------------

-- Scan tooltip lines and call callback for each line
-- callback(lineNumber, text) - return true to stop scanning
function TooltipScanner:ScanLines(callback, maxLines)
    local numLines = self:GetNumLines()
    if not numLines or numLines == 0 then return nil end

    maxLines = maxLines or numLines

    for i = 1, math.min(numLines, maxLines) do
        local text = self:GetLineText(i)
        if text then
            local result = callback(i, text)
            if result then
                return result
            end
        end
    end

    return nil
end

-- Find first matching pattern in tooltip
-- Returns: matchedPattern, fullText, lineNumber
function TooltipScanner:FindText(patterns, maxLines)
    if type(patterns) == "string" then
        patterns = {patterns}
    end

    local result = nil
    self:ScanLines(function(lineNum, text)
        for _, pattern in ipairs(patterns) do
            if text:find(pattern) then
                result = {pattern = pattern, text = text, line = lineNum}
                return true
            end
        end
    end, maxLines)

    return result
end

-- Check if any pattern exists in tooltip
function TooltipScanner:HasText(patterns, maxLines)
    return self:FindText(patterns, maxLines) ~= nil
end

-------------------------------------------------
-- Common Item Checks
-------------------------------------------------

-- Check if item is Bind on Equip
function TooltipScanner:IsBindOnEquip(bagID, slotID, itemData)
    if not bagID or not slotID then return false end

    -- Only weapons and armor can be BoE
    if itemData and itemData.itemType ~= "Weapon" and itemData.itemType ~= "Armor" then
        return false
    end

    if not self:SetBagItem(bagID, slotID) then
        return false
    end

    -- Check first 6 lines for binding info
    local isBoE = false
    self:ScanLines(function(lineNum, text)
        if text == ITEM_BIND_ON_EQUIP or text:find("Binds when equipped") then
            isBoE = true
            return true
        end
        if text == ITEM_SOULBOUND or text:find("Soulbound") then
            isBoE = false
            return true
        end
        if text == ITEM_BIND_ON_PICKUP or text:find("Binds when picked up") then
            isBoE = false
            return true
        end
    end, 6)

    return isBoE
end

-- Check if item is Warbound (account-bound in TWW)
function TooltipScanner:IsWarbound(bagID, slotID)
    if not bagID or not slotID then return false end

    if not self:SetBagItem(bagID, slotID) then
        return false
    end

    local isWarbound = false
    self:ScanLines(function(lineNum, text)
        -- Soulbound items are not warbound
        if text == ITEM_SOULBOUND or text:find("Soulbound") then
            isWarbound = false
            return true
        end
        -- Check warbound/account-bound globals (auto-localized by game client)
        if (ITEM_BNET_ACCOUNTBOUND_UNTIL_EQUIP and text == ITEM_BNET_ACCOUNTBOUND_UNTIL_EQUIP)
            or (ITEM_ACCOUNTBOUND and text == ITEM_ACCOUNTBOUND)
            or (ITEM_BNET_ACCOUNTBOUND and text == ITEM_BNET_ACCOUNTBOUND)
            or (ITEM_BIND_TO_BNETACCOUNT and text == ITEM_BIND_TO_BNETACCOUNT) then
            isWarbound = true
            return true
        end
    end, 6)

    return isWarbound
end

-- Get consumable restore type (eat/drink/restore)
function TooltipScanner:GetRestoreTag(bagID, slotID, itemData)
    if not bagID or not slotID then return nil end

    -- Only consumables have restore tags
    if itemData and itemData.itemType ~= "Consumable" then
        return nil
    end

    if not self:SetBagItem(bagID, slotID) then
        return nil
    end

    local hasHealth = false
    local hasMana = false
    local hasRestores = false
    local mustRemainSeated = false

    self:ScanLines(function(lineNum, text)
        local textLower = text:lower()

        if textLower:find("use: restores") or textLower:find("use: regenerates") then
            hasRestores = true
            if textLower:find("health") then hasHealth = true end
            if textLower:find("mana") then hasMana = true end
        end

        -- Buff food: "eating" or "well fed" implies food
        if textLower:find("eating") or textLower:find("well fed") then
            hasHealth = true
        end
        -- Buff drink: "drinking" implies drink
        if textLower:find("drinking") then
            hasMana = true
        end

        if textLower:find("must remain seated") then
            mustRemainSeated = true
        end
    end)

    if mustRemainSeated then
        if hasHealth and hasMana then
            return "restore"
        elseif hasHealth then
            return "eat"
        elseif hasMana then
            return "drink"
        end
    end

    return nil
end

-- Check if item has special properties (Use:, Equip:, Chance on hit)
function TooltipScanner:HasSpecialProperties(bagID, slotID)
    if not bagID or not slotID then return false end

    if not self:SetBagItem(bagID, slotID) then
        return false
    end

    return self:HasText({"Use:", "Equip:", "Chance on hit"})
end

-------------------------------------------------
-- Charges (Wizard Oil, Sharpening Stones, etc.)
-------------------------------------------------

-- Per-slot cache: charges depend on slot state (uses deplete a charge), not on the link.
-- Value = number (charges remaining), false (scanned, no charges), nil (not scanned yet)
local chargesCache = {}

function TooltipScanner:GetCharges(bagID, slotID)
    if not bagID or not slotID then return nil end
    local key = bagID * 1000 + slotID
    local cached = chargesCache[key]
    if cached ~= nil then
        if cached == false then return nil end
        return cached
    end

    if not self:SetBagItem(bagID, slotID) then
        return nil  -- tooltip not ready; don't poison cache
    end

    local charges = nil
    self:ScanLines(function(lineNum, text)
        local _, _, num = string.find(text:lower(), "^(%d+) charges?$")
        if num then
            charges = tonumber(num)
            return true
        end
    end, 10)

    chargesCache[key] = charges or false
    return charges
end

function TooltipScanner:InvalidateCharges(bagID)
    if bagID then
        local lo = bagID * 1000
        local hi = lo + 999
        for key in pairs(chargesCache) do
            if key >= lo and key <= hi then
                chargesCache[key] = nil
            end
        end
    else
        chargesCache = {}
    end
end

local Events = ns:GetModule("Events")
if Events then
    Events:Register("BAG_UPDATE", function(event, bagID)
        TooltipScanner:InvalidateCharges(bagID)
    end, "TooltipScanner_Charges")

    -- Applying oils, sharpening stones, scrolls, etc. fires UNIT_SPELLCAST_SUCCEEDED
    -- but does NOT reliably fire BAG_UPDATE in Classic — the slot's itemID and
    -- stackCount are unchanged, only the embedded charge count decremented.
    Events:Register("UNIT_SPELLCAST_SUCCEEDED", function(event, unit)
        if unit ~= "player" then return end
        TooltipScanner:InvalidateCharges()
    end, "TooltipScanner_Charges_Cast")
end
