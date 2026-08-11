local addonName, ns = ...

local Utils = {}
ns:RegisterModule("Utils", Utils)

local CreateFrame = ns.CreateFrame or CreateFrame

-------------------------------------------------
-- Widget call-shape helpers
--
-- 3.3.5a HAS these methods, but with a pre-modern signature. The shim used to
-- wrap them on the SHARED widget metatables, which put GudaBags on the call
-- path of every Blizzard widget in the client and leaked taint into secure
-- code (see the note in Compatibility\Shim335.lua section 11c). They are our
-- call-shape problems, so they are fixed at our call sites instead.
-------------------------------------------------

-- Pre-Legion GetChecked returns 1 or nil, modern code expects true/false.
-- This matters beyond tidiness: Database:SetSetting writes the value straight
-- into the settings table, and assigning nil DELETES the key -- so unticking
-- any checkbox silently fell back to its default.
function Utils:GetChecked(button)
    if not button or not button.GetChecked then return false end
    local v = button:GetChecked()
    return (v and v ~= 0) and true or false
end

-- Pre-10.0 SetGradient takes (orientation, r1,g1,b1, r2,g2,b2) -- seven loose
-- numbers, no alpha. The addon calls the 10.0 form (orientation, color, color).
-- Accept the modern form and route to whatever this client implements.
function Utils:SetGradient(texture, orientation, a, b, ...)
    if not texture then return end

    if type(a) == "table" then
        local c1, c2 = a, b
        if not (c1 and c2) then return end
        if texture.SetGradientAlpha then
            return texture:SetGradientAlpha(orientation,
                c1.r or 0, c1.g or 0, c1.b or 0, c1.a == nil and 1 or c1.a,
                c2.r or 0, c2.g or 0, c2.b or 0, c2.a == nil and 1 or c2.a)
        elseif texture.SetGradient then
            return texture:SetGradient(orientation,
                c1.r or 0, c1.g or 0, c1.b or 0,
                c2.r or 0, c2.g or 0, c2.b or 0)
        end
        -- No gradient support at all: approximate with the end stop.
        return texture:SetVertexColor(c2.r or 0, c2.g or 0, c2.b or 0,
                                      c2.a == nil and 1 or c2.a)
    end

    -- Legacy numeric form: hand straight through.
    if texture.SetGradient then return texture:SetGradient(orientation, a, b, ...) end
end

-- Note: SetObeyStepOnDrag needs no helper. The shim no longer writes a no-op
-- into the shared Slider metatable to fake it, and both call sites
-- (UI\Controls\Slider.lua, UI\CategoryEditor.lua) already nil-guard it -- which
-- is the correct shape, since pre-Cata sliders snap to SetValueStep anyway.

-- SetEnabled (MoP 5.0) expressed with the Enable/Disable pair WotLK does have.
--
-- Used to be polyfilled onto the shared Frame and Button metatables. That is a
-- worse deal than it looks on a client whose FrameXML is part retail port: a
-- ported Blizzard file calling button:SetEnabled() would find OUR function and
-- run addon Lua inside Blizzard's own execution, tainting it. Every widget on
-- the stance bar, the world map and the action bars is a Button.
function Utils:SetEnabled(widget, enabled)
    if not widget then return end
    if widget.SetEnabled then return widget:SetEnabled(enabled) end   -- native
    if enabled then
        if widget.Enable then widget:Enable() end
    else
        if widget.Disable then widget:Disable() end
    end
end

-- Alpha animations: retail sets absolute endpoints (SetFromAlpha/SetToAlpha),
-- WotLK expresses the same thing as a single SetChange(delta) applied to the
-- region's current alpha. Same reasoning as above -- the Alpha metatable is
-- shared with every animation in the client, so the conversion lives here
-- rather than on it.
function Utils:SetAnimAlphaRange(anim, from, to)
    if not anim then return end
    if anim.SetFromAlpha and anim.SetToAlpha then                     -- native
        anim:SetFromAlpha(from)
        anim:SetToAlpha(to)
        return
    end
    if anim.SetChange then anim:SetChange(to - from) end
end

-- StaticPopup dialogs expose their hasEditBox widget under a different field
-- per client: modern retail as `EditBox`, 3.3.5a/Ascension as `editBox` (plus
-- the named global <dialog>EditBox). Hardcoding either one nils out on the
-- other, which is how profile import died on 3.3.5. Read-only lookup on a
-- Blizzard-owned frame -- nothing is written back onto the dialog.
function Utils:GetPopupEditBox(popup)
    if not popup then return nil end
    local box = popup.editBox or popup.EditBox
    if not box and popup.GetName and popup:GetName() then
        box = _G[popup:GetName() .. "EditBox"]
    end
    return box
end

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
-- Per-item GUIDs (Ascension only)
-------------------------------------------------

-- Stock 3.3.5a has no item GUIDs; Ascension's custom layer adds
-- GetContainerItemGUID (docs/ASCENSION-API.md section 4). Verified on this client
-- with `/guda diag guid`: the value is unique per stack and follows the item across
-- slot moves, which makes it a valid identity key for per-item locking.
--
-- Resolved once at load. On a client without it every caller gets nil, which
-- makes the lock code fall back to the legacy itemID-wide store automatically --
-- no feature flag to thread through, no behaviour change off Ascension.
--
-- NOT valid for guild bank slots: those pass a tabIndex where a bagID belongs.
-- Guild bank item records never carry a guid, so they take the fallback path.
local GetContainerItemGUID_ = _G.GetContainerItemGUID
local hasItemGUID = type(GetContainerItemGUID_) == "function"

function Utils:GetItemGUID(bagID, slot)
    if not hasItemGUID or bagID == nil or slot == nil then return nil end
    return GetContainerItemGUID_(bagID, slot)
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
