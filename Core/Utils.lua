local addonName, ns = ...

local Utils = {}
ns:RegisterModule("Utils", Utils)

-------------------------------------------------
-- Item Key Generation
-- Creates a unique key for an item based on its properties
-- Used for button reuse optimization in category view
-------------------------------------------------

-- Generate unique key for an item (for button reuse in category view)
-- Items with same key can share buttons
function Utils:GetItemKey(itemData)
    if not itemData then return nil end
    -- Key based on: itemLink (or itemID), quality, bound status
    -- This matches items that are visually identical
    local link = itemData.link or ""
    local quality = itemData.quality or 0
    local isBound = itemData.isBound and "1" or "0"
    return link .. ":" .. quality .. ":" .. isBound
end

-------------------------------------------------
-- Slot Key Generation
-- Creates a unique key for a bag slot position
-------------------------------------------------

-- Generate slot key for tracking (bagID:slot)
function Utils:GetSlotKey(bagID, slot)
    return bagID .. ":" .. slot
end

-------------------------------------------------
-- Table Utilities
-------------------------------------------------

-- Deep copy a table
function Utils:DeepCopy(orig)
    local copy
    if type(orig) == "table" then
        copy = {}
        for k, v in pairs(orig) do
            copy[self:DeepCopy(k)] = self:DeepCopy(v)
        end
        setmetatable(copy, self:DeepCopy(getmetatable(orig)))
    else
        copy = orig
    end
    return copy
end

-- Count entries in a table (for tables with non-numeric keys)
function Utils:TableCount(tbl)
    if not tbl then return 0 end
    local count = 0
    for _ in pairs(tbl) do
        count = count + 1
    end
    return count
end

-- Check if table is empty
function Utils:IsTableEmpty(tbl)
    if not tbl then return true end
    return next(tbl) == nil
end

-------------------------------------------------
-- Race Icons
-------------------------------------------------

local raceCorrections = {
    ["scourge"] = "undead",
    ["zandalaritroll"] = "zandalari",
    ["highmountaintauren"] = "highmountain",
    ["lightforgeddraenei"] = "lightforged",
    ["earthendwarf"] = "earthen",
}

local genders = {"unknown", "male", "female"}

-- Pre-Legion clients have no atlas system, so the "|A:atlas|a" escape below is
-- not parsed and renders as nothing. They do ship the race sprite sheet plus a
-- global RACE_ICON_TCOORDS table mapping "<RACETOKEN>_<GENDER>" to tex coords,
-- which "|T texture|t" markup can slice the same way.
local RACE_SHEET = "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Races"
local RACE_SHEET_SIZE = 256

-- Get inline race icon string for use in text
-- race: internal race token from select(2, UnitRace("player"))
-- sex: gender index from UnitSex("player") (1=unknown, 2=male, 3=female)
function Utils:GetRaceIcon(race, sex)
    if not race then return "" end

    if ns.IsWrath then
        -- Use the RAW token here: RACE_ICON_TCOORDS keys on the game's own race
        -- tokens (Undead is "SCOURGE"), not the retail atlas spellings that
        -- raceCorrections produces.
        local coords = RACE_ICON_TCOORDS
            and RACE_ICON_TCOORDS[race:upper() .. "_" .. (sex == 3 and "FEMALE" or "MALE")]
        -- Ascension's custom races simply are not on the sheet; no icon is the
        -- correct outcome, not a broken one.
        if not coords then return "" end
        return ("|T%s:13:13:0:0:%d:%d:%d:%d:%d:%d|t"):format(
            RACE_SHEET, RACE_SHEET_SIZE, RACE_SHEET_SIZE,
            coords[1] * RACE_SHEET_SIZE, coords[2] * RACE_SHEET_SIZE,
            coords[3] * RACE_SHEET_SIZE, coords[4] * RACE_SHEET_SIZE)
    end

    local raceLower = race:lower()
    raceLower = raceCorrections[raceLower] or raceLower
    local gender = genders[sex or 2] or "male"
    local prefix = ns.IsRetail and "raceicon128" or "raceicon"

    return "|A:" .. prefix .. "-" .. raceLower .. "-" .. gender .. ":13:13|a"
end

-------------------------------------------------
-- Money Formatting
-------------------------------------------------

local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:12|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:12|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:12|t"

-- Format money with gold and silver only (for inline/compact display)
function Utils:FormatMoneyShort(amount)
    if not amount or amount == 0 then return "" end

    local gold = math.floor(amount / 10000)
    local silver = math.floor((amount % 10000) / 100)

    local result = ""
    if gold > 0 then
        result = string.format("%d%s", gold, GOLD_ICON)
    end
    if silver > 0 then
        if result ~= "" then result = result .. " " end
        result = result .. string.format("%d%s", silver, SILVER_ICON)
    end
    return result
end

-------------------------------------------------
-- Item Border Creation
-- Creates quality border frame on item buttons
-- Used by ItemButton, QuestBar, TrackedBar
-------------------------------------------------

function Utils:CreateItemBorder(button)
    local Constants = ns.Constants
    local BORDER_THICKNESS = Constants.ICON.BORDER_THICKNESS

    local borderFrame = CreateFrame("Frame", nil, button, "BackdropTemplate")
    borderFrame:SetPoint("TOPLEFT", button, "TOPLEFT", -BORDER_THICKNESS, BORDER_THICKNESS)
    borderFrame:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", BORDER_THICKNESS, -BORDER_THICKNESS)
    borderFrame:SetFrameLevel(button:GetFrameLevel() + Constants.FRAME_LEVELS.BORDER)

    borderFrame:SetBackdrop({
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = {left = 2, right = 2, top = 2, bottom = 2},
    })
    borderFrame:Hide()

    borderFrame.SetVertexColor = function(self, r, g, b, a)
        self:SetBackdropBorderColor(r, g, b, a)
    end

    return borderFrame
end

-------------------------------------------------
-- Masque-aware NormalTexture hiding
-- Used by ItemButton, TrackedBar, QuestBar
-------------------------------------------------

function Utils:HideNormalTexture(button)
    local MasqueModule = ns:GetModule("Masque")
    local masqueActive = MasqueModule and MasqueModule:IsActive()
    local normalTex = button:GetNormalTexture()
    if normalTex then
        if masqueActive then
            normalTex:Hide()
        else
            normalTex:SetTexture(nil)
            normalTex:Hide()
        end
    end
    if masqueActive then
        button.SetNormalTexture = function() end
    end
end

-------------------------------------------------
-- Inner shadow/glow creation
-- Used by ItemButton, QuestBar
-------------------------------------------------

function Utils:CreateInnerShadow(button, shadowSize)
    local innerShadow = {
        top = button:CreateTexture(nil, "ARTWORK", nil, 1),
        bottom = button:CreateTexture(nil, "ARTWORK", nil, 1),
        left = button:CreateTexture(nil, "ARTWORK", nil, 1),
        right = button:CreateTexture(nil, "ARTWORK", nil, 1),
    }
    -- Top edge
    innerShadow.top:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
    innerShadow.top:SetPoint("TOPRIGHT", button, "TOPRIGHT", 0, 0)
    innerShadow.top:SetHeight(shadowSize)
    innerShadow.top:SetTexture("Interface\\Buttons\\WHITE8x8")
    innerShadow.top:SetGradient("VERTICAL", CreateColor(0, 0, 0, 0), CreateColor(0, 0, 0, 0.6))
    -- Bottom edge
    innerShadow.bottom:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0)
    innerShadow.bottom:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, 0)
    innerShadow.bottom:SetHeight(shadowSize)
    innerShadow.bottom:SetTexture("Interface\\Buttons\\WHITE8x8")
    innerShadow.bottom:SetGradient("VERTICAL", CreateColor(0, 0, 0, 0.6), CreateColor(0, 0, 0, 0))
    -- Left edge
    innerShadow.left:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
    innerShadow.left:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0)
    innerShadow.left:SetWidth(shadowSize)
    innerShadow.left:SetTexture("Interface\\Buttons\\WHITE8x8")
    innerShadow.left:SetGradient("HORIZONTAL", CreateColor(0, 0, 0, 0.6), CreateColor(0, 0, 0, 0))
    -- Right edge
    innerShadow.right:SetPoint("TOPRIGHT", button, "TOPRIGHT", 0, 0)
    innerShadow.right:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, 0)
    innerShadow.right:SetWidth(shadowSize)
    innerShadow.right:SetTexture("Interface\\Buttons\\WHITE8x8")
    innerShadow.right:SetGradient("HORIZONTAL", CreateColor(0, 0, 0, 0), CreateColor(0, 0, 0, 0.6))
    -- Hide by default
    for _, tex in pairs(innerShadow) do tex:Hide() end
    return innerShadow
end

-------------------------------------------------
-- Profession Tool Detection
-- Fishing poles, mining picks, skinning knives, etc.
-------------------------------------------------

function Utils:IsProfessionTool(itemData)
    -- Check by item ID first
    local Constants = ns.Constants
    if itemData.itemID and Constants.PROFESSION_TOOL_IDS[itemData.itemID] then
        return true
    end

    -- Check fishing poles by subtype
    local subtype = itemData.itemSubType
    if subtype == "Fishing Poles" or subtype == "Fishing Pole" then
        return true
    end

    -- Check by name patterns
    local name = itemData.name
    if name then
        if name:find("Mining Pick") or name:find("Skinning Knife") or
           name:find("Blacksmith Hammer") or name:find("Runed.*Rod") or
           name:find("Philosopher's Stone") or name:find("Alchemist") or
           name:find("Spanner") or name:find("Gyromatic") then
            return true
        end
    end

    return false
end

-- Format money with all denominations (for totals/summaries)
function Utils:FormatMoneyFull(amount)
    if not amount or amount == 0 then return "" end

    local gold = math.floor(amount / 10000)
    local silver = math.floor((amount % 10000) / 100)
    local copper = amount % 100

    local result = ""
    if gold > 0 then
        result = string.format("%d%s", gold, GOLD_ICON)
    end
    if silver > 0 then
        if result ~= "" then result = result .. " " end
        result = result .. string.format("%d%s", silver, SILVER_ICON)
    end
    if copper > 0 or result == "" then
        if result ~= "" then result = result .. " " end
        result = result .. string.format("%d%s", copper, COPPER_ICON)
    end
    return result
end
