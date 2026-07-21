local addonName, ns = ...

local DragFlyoutBar = {}
ns:RegisterModule("DragFlyoutBar", DragFlyoutBar)

-------------------------------------------------
-- Layout
-------------------------------------------------

local BUTTON_SIZE = 36
local BUTTON_SPACING = 6
local BAR_PADDING = 3
local BAR_GAP = 2

local TARGETS = { "track", "lock", "pin", "junk" }

local function IsTargetEnabled(targetType)
    if targetType == "pin" then
        if ns.IsRetail then
            local Database = ns:GetModule("Database")
            if Database and not Database:GetSetting("gudaSort") then
                return false
            end
        end
    end
    return true
end

local TARGET_ICONS = {
    track = "Interface\\AddOns\\GudaBags\\Assets\\fav.tga",
    lock  = "Interface\\AddOns\\GudaBags\\Assets\\lock.tga",
    pin   = "Interface\\AddOns\\GudaBags\\Assets\\pin.tga",
    junk  = "Interface\\Buttons\\UI-GroupLoot-Coin-Up",
}

-- Per-target visual nudges (some Blizzard textures have asymmetric padding)
local TARGET_ICON_Y_OFFSET = {
    junk = -3,
}

-------------------------------------------------
-- State
-------------------------------------------------

local bar = nil
local buttons = {}
local dropCooldown = false
local currentItemID = nil
local currentBagID = nil
local currentSlot = nil

-------------------------------------------------
-- Forward declarations
-------------------------------------------------

local UpdateButtonState

-------------------------------------------------
-- Orbit-streak glow (matches search match animation in ItemButton.lua)
-------------------------------------------------

local STREAK_COUNT     = 4
local STREAK_PERIOD    = 3.2
local STREAK_SIZE      = 4
local TRAIL_PER_STREAK = 2
local TRAIL_PHASE_STEP = 0.035
local ORBIT_INSET      = 7
local ROUND_MASK       = "Interface\\CharacterFrame\\TempPortraitAlphaMask"

local function UpdateOrbitStreaks(glow, elapsed)
    glow.orbitPhase = ((glow.orbitPhase or 0) + elapsed / STREAK_PERIOD) % 1
    local fw, fh = glow:GetSize()
    local w, h = fw - 2 * ORBIT_INSET, fh - 2 * ORBIT_INSET
    if w <= 0 or h <= 0 then return end
    local perim = 2 * (w + h)
    local phase = glow.orbitPhase
    for _, streak in ipairs(glow.streaks) do
        local p = (phase + streak.phaseOffset) % 1
        local d = p * perim
        local x, y
        if d < w then
            x, y = d, 0
        elseif d < w + h then
            x, y = w, -(d - w)
        elseif d < 2 * w + h then
            x, y = w - (d - w - h), -h
        else
            x, y = 0, -(perim - d)
        end
        streak:SetPoint("CENTER", glow, "TOPLEFT", ORBIT_INSET + x, -ORBIT_INSET + y)
    end
end

local function CreateOrbitGlow(button)
    local glow = CreateFrame("Frame", nil, button, "BackdropTemplate")
    glow:SetPoint("TOPLEFT", button, "TOPLEFT", -3, 3)
    glow:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 3, -3)
    glow:SetFrameLevel(button:GetFrameLevel() + 10)

    glow:SetBackdrop({
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 10,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    glow:SetBackdropBorderColor(1.0, 0.85, 0.2, 0.95)

    glow.streaks = {}
    for i = 1, STREAK_COUNT do
        local basePhase = (i - 1) / STREAK_COUNT

        local primary = glow:CreateTexture(nil, "OVERLAY")
        primary:SetSize(STREAK_SIZE, STREAK_SIZE)
        primary:SetTexture("Interface\\Buttons\\WHITE8x8")
        if primary.SetMask then primary:SetMask(ROUND_MASK) end
        primary:SetVertexColor(1.0, 0.95, 0.45, 1.0)
        primary:SetBlendMode("ADD")
        primary:SetPoint("CENTER", glow, "TOPLEFT", 0, 0)
        primary.phaseOffset = basePhase
        glow.streaks[#glow.streaks + 1] = primary

        for t = 1, TRAIL_PER_STREAK do
            local trail = glow:CreateTexture(nil, "OVERLAY")
            local size = math.max(2, STREAK_SIZE - t)
            trail:SetSize(size, size)
            trail:SetTexture("Interface\\Buttons\\WHITE8x8")
            if trail.SetMask then trail:SetMask(ROUND_MASK) end
            trail:SetVertexColor(1.0, 0.85, 0.2, 1.0)
            trail:SetBlendMode("ADD")
            trail:SetAlpha(0.65 - t * 0.18)
            trail:SetPoint("CENTER", glow, "TOPLEFT", 0, 0)
            trail.phaseOffset = (basePhase - t * TRAIL_PHASE_STEP) % 1
            glow.streaks[#glow.streaks + 1] = trail
        end
    end

    glow:SetScript("OnUpdate", UpdateOrbitStreaks)
    glow:SetScript("OnShow", function(self) self.orbitPhase = 0 end)
    return glow
end

-------------------------------------------------
-- Tooltip helpers (state-aware, reads cursor item state)
-------------------------------------------------

local function GetTooltipText(targetType)
    local L = ns.L

    if targetType == "track" then
        local TrackedBar = ns:GetModule("TrackedBar")
        local isOn = TrackedBar and currentItemID and TrackedBar:IsTracked(currentItemID)
        return isOn and L["TOOLTIP_FLYOUT_TRACK_ON"] or L["TOOLTIP_FLYOUT_TRACK_OFF"]
    elseif targetType == "lock" then
        local Database = ns:GetModule("Database")
        local isOn = Database and currentItemID and Database:IsItemLocked(currentItemID)
        return isOn and L["TOOLTIP_FLYOUT_LOCK_ON"] or L["TOOLTIP_FLYOUT_LOCK_OFF"]
    elseif targetType == "pin" then
        local Database = ns:GetModule("Database")
        local isOn = Database and currentBagID and currentSlot and Database:IsPinnedSlot(currentBagID, currentSlot)
        return isOn and L["TOOLTIP_FLYOUT_PIN_ON"] or L["TOOLTIP_FLYOUT_PIN_OFF"]
    elseif targetType == "junk" then
        local Database = ns:GetModule("Database")
        local isOn = Database and currentItemID and Database:IsItemMarkedJunk(currentItemID)
        return isOn and L["TOOLTIP_FLYOUT_JUNK_ON"] or L["TOOLTIP_FLYOUT_JUNK_OFF"]
    end
end

local function ShowButtonTooltip(button, targetType)
    local text = GetTooltipText(targetType)
    if not text then return end

    GameTooltip:SetOwner(button, "ANCHOR_TOP")
    GameTooltip:SetText(text, 1, 1, 1)

    if targetType == "junk" then
        local Database = ns:GetModule("Database")
        if Database and Database:GetSetting("autoVendorJunk") then
            GameTooltip:AddLine(ns.L["TOOLTIP_FLYOUT_JUNK_AUTOVENDOR"], 1, 0.82, 0)
        end
    end

    GameTooltip:Show()
end

-------------------------------------------------
-- Bar / button creation
-------------------------------------------------

local function CreateButton(targetType, index)
    local btn = CreateFrame("Button", nil, bar)
    btn:SetSize(BUTTON_SIZE, BUTTON_SIZE)

    local x = BAR_PADDING + (index - 1) * (BUTTON_SIZE + BUTTON_SPACING)
    btn:SetPoint("TOPLEFT", bar, "TOPLEFT", x, -BAR_PADDING)

    -- Slot background (matches CategoryDropIndicator style)
    local slotBg = btn:CreateTexture(nil, "BACKGROUND")
    slotBg:SetPoint("TOPLEFT", btn, "TOPLEFT", -9, 9)
    slotBg:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 9, -9)
    slotBg:SetTexture("Interface\\Buttons\\UI-EmptySlot")
    slotBg:SetVertexColor(0.6, 0.6, 0.6, 0.9)
    btn.slotBg = slotBg

    -- Icon
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("CENTER", btn, "CENTER", 0, TARGET_ICON_Y_OFFSET[targetType] or 0)
    icon:SetSize(BUTTON_SIZE * 0.7, BUTTON_SIZE * 0.7)
    icon:SetTexture(TARGET_ICONS[targetType])
    btn.icon = icon

    -- Highlight overlay
    local highlight = btn:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints(icon)
    highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    highlight:SetBlendMode("ADD")

    btn:EnableMouse(true)
    btn:RegisterForDrag("LeftButton")

    btn:SetScript("OnMouseDown", function(self, mouseButton)
        if mouseButton == "LeftButton" then
            pcall(function() DragFlyoutBar:HandleDrop(targetType) end)
        end
    end)

    btn:SetScript("OnReceiveDrag", function(self)
        pcall(function() DragFlyoutBar:HandleDrop(targetType) end)
    end)

    btn:SetScript("OnEnter", function(self)
        ShowButtonTooltip(self, targetType)
    end)

    btn:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
    end)

    btn.targetType = targetType
    btn.orbitGlow = CreateOrbitGlow(btn)
    return btn
end

local function CreateBar()
    if bar then return bar end

    local barWidth = BAR_PADDING * 2 + #TARGETS * BUTTON_SIZE + (#TARGETS - 1) * BUTTON_SPACING
    local barHeight = BAR_PADDING * 2 + BUTTON_SIZE

    bar = CreateFrame("Frame", "GudaBagsDragFlyoutBar", UIParent)
    bar:SetSize(barWidth, barHeight)
    bar:SetFrameStrata("FULLSCREEN_DIALOG")
    bar:SetFrameLevel(500)
    bar:SetScale(0.8)

    for i, targetType in ipairs(TARGETS) do
        buttons[targetType] = CreateButton(targetType, i)
    end

    bar:Hide()
    return bar
end

-------------------------------------------------
-- State updates (icon tint based on current toggle state)
-------------------------------------------------

UpdateButtonState = function()
    local Database = ns:GetModule("Database")
    local TrackedBar = ns:GetModule("TrackedBar")

    local function tint(targetType, isOn)
        local btn = buttons[targetType]
        if not btn then return end
        if isOn then
            btn.slotBg:SetVertexColor(0.4, 0.8, 0.4, 0.95)  -- green when active
        else
            btn.slotBg:SetVertexColor(0.6, 0.6, 0.6, 0.9)
        end
    end

    tint("track", TrackedBar and currentItemID and TrackedBar:IsTracked(currentItemID))
    tint("lock",  Database and currentItemID and Database:IsItemLocked(currentItemID))
    tint("pin",   Database and currentBagID and currentSlot and Database:IsPinnedSlot(currentBagID, currentSlot))
    tint("junk",  Database and currentItemID and Database:IsItemMarkedJunk(currentItemID))
end

-------------------------------------------------
-- Public API
-------------------------------------------------

function DragFlyoutBar:OnDragStart(itemID, bagID, slot, source)
    if dropCooldown then return end
    if source ~= "bag" then return end
    if not itemID then return end

    local Database = ns:GetModule("Database")
    if Database and not Database:GetSetting("showDragFlyout") then return end

    local BagFrame = ns:GetModule("BagFrame")
    if not BagFrame or not BagFrame:IsShown() then return end

    local frame = BagFrame:GetFrame()
    if not frame then return end

    CreateBar()

    currentItemID = itemID
    currentBagID = bagID
    currentSlot = slot

    local visibleCount = 0
    for _, targetType in ipairs(TARGETS) do
        local btn = buttons[targetType]
        if btn then
            if IsTargetEnabled(targetType) then
                visibleCount = visibleCount + 1
                local x = BAR_PADDING + (visibleCount - 1) * (BUTTON_SIZE + BUTTON_SPACING)
                btn:ClearAllPoints()
                btn:SetPoint("TOPLEFT", bar, "TOPLEFT", x, -BAR_PADDING)
                btn:Show()
            else
                btn:Hide()
            end
        end
    end

    if visibleCount == 0 then return end

    local barWidth = BAR_PADDING * 2 + visibleCount * BUTTON_SIZE + math.max(0, visibleCount - 1) * BUTTON_SPACING
    bar:SetWidth(barWidth)

    UpdateButtonState()

    bar:ClearAllPoints()
    bar:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 0, BAR_GAP)
    bar:Show()
end

function DragFlyoutBar:OnDragEnd()
    self:Hide(false)
end

function DragFlyoutBar:Hide(fromDrop)
    if bar then
        bar:Hide()
    end
    GameTooltip:Hide()

    currentItemID = nil
    currentBagID = nil
    currentSlot = nil

    if fromDrop then
        dropCooldown = true
        C_Timer.After(0.2, function()
            dropCooldown = false
        end)
    end
end

function DragFlyoutBar:IsShown()
    return bar and bar:IsShown()
end

-------------------------------------------------
-- Drop handling
-------------------------------------------------

function DragFlyoutBar:HandleDrop(targetType)
    if InCombatLockdown() then return end

    local infoType, itemID = GetCursorInfo()
    if infoType ~= "item" or not itemID then
        self:Hide(true)
        return
    end

    local BagFrame = ns:GetModule("BagFrame")
    local Database = ns:GetModule("Database")

    if targetType == "track" then
        ClearCursor()
        local TrackedBar = ns:GetModule("TrackedBar")
        if TrackedBar then
            TrackedBar:ToggleTrackItem(itemID)
        end

    elseif targetType == "lock" then
        ClearCursor()
        if Database then
            Database:ToggleItemLock(itemID)
        end
        if BagFrame then
            BagFrame:Refresh()
        end

    elseif targetType == "pin" then
        local bagID, slot
        if BagFrame and BagFrame.GetCursorBagSlot then
            bagID, slot = BagFrame:GetCursorBagSlot()
        end
        bagID = bagID or currentBagID
        slot = slot or currentSlot
        ClearCursor()
        if Database and bagID and slot then
            Database:TogglePinnedSlot(bagID, slot)
            if BagFrame and BagFrame.RefreshPinIcons then
                BagFrame:RefreshPinIcons()
            end
        end

    elseif targetType == "junk" then
        ClearCursor()
        if Database then
            Database:ToggleItemMarkedJunk(itemID)
            local CategoryManager = ns:GetModule("CategoryManager")
            if CategoryManager and CategoryManager.ClearCategoryCache then
                CategoryManager:ClearCategoryCache()
            end
        end
        if BagFrame then
            BagFrame:Refresh()
        end
    end

    self:Hide(true)
end

-------------------------------------------------
-- Combat hide
-------------------------------------------------

local Events = ns:GetModule("Events")
Events:Register("PLAYER_REGEN_DISABLED", function()
    if DragFlyoutBar:IsShown() then
        DragFlyoutBar:Hide(false)
    end
end, DragFlyoutBar)
