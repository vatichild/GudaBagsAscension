local addonName, ns = ...

local BagSlots = {}
ns:RegisterModule("Footer.BagSlots", BagSlots)

local Constants = ns.Constants
local Theme = ns:GetModule("Theme")

local Database = ns:GetModule("Database")

local frame = nil
local bagFlyout = nil
local bagFlyoutExpanded = false
local mainBagFrame = nil
local viewingCharacter = nil
local onBagVisibilityChanged = nil  -- Callback when bag visibility changes

-- Helper to get hidden bags from database
local function GetHiddenBags()
    return Database:GetSetting("hiddenBags") or {}
end

-- Helper to set hidden bags in database
local function SetHiddenBags(hiddenBags)
    Database:SetSetting("hiddenBags", hiddenBags)
end

-- Check if a bag is hidden
local function IsBagHidden(bagID)
    local hiddenBags = GetHiddenBags()
    return hiddenBags[bagID] == true
end

-- Toggle bag visibility
local function ToggleBagVisibility(bagID)
    local hiddenBags = GetHiddenBags()
    if hiddenBags[bagID] then
        hiddenBags[bagID] = nil
    else
        hiddenBags[bagID] = true
    end
    SetHiddenBags(hiddenBags)
    return not hiddenBags[bagID]  -- Return new visibility state (true = visible)
end

local function CreateBagSlotButton(parent, bagID, bagSlotSize)
    local bagSlot = CreateFrame("Button", "GudaBagsBagSlot" .. bagID, parent, "BackdropTemplate")
    bagSlot:SetSize(bagSlotSize, bagSlotSize)
    bagSlot:EnableMouse(true)
    bagSlot:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    bagSlot.bagID = bagID

    bagSlot:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8,
        insets = {left = 2, right = 2, top = 2, bottom = 2},
    })
    local fbBg = Theme:GetValue("footerButtonBg")
    local fbBorder = Theme:GetValue("footerButtonBorder")
    bagSlot:SetBackdropColor(fbBg[1], fbBg[2], fbBg[3], fbBg[4])
    bagSlot:SetBackdropBorderColor(fbBorder[1], fbBorder[2], fbBorder[3], fbBorder[4])

    local icon = bagSlot:CreateTexture(nil, "ARTWORK")
    icon:SetSize(bagSlotSize - 2, bagSlotSize - 2)
    icon:SetPoint("CENTER")
    bagSlot.icon = icon

    local highlight = bagSlot:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    highlight:SetBlendMode("ADD")

    bagSlot:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        if self.bagID == 0 then
            GameTooltip:SetText(BACKPACK_TOOLTIP)
        else
            GameTooltip:SetInventoryItem("player", C_Container.ContainerIDToInventoryID(self.bagID))
        end

        -- Show right-click hint for hiding bags (only in single view mode, not backpack)
        local viewType = Database:GetSetting("bagViewType") or "single"
        if viewType == "single" and not viewingCharacter and self.bagID ~= 0 then
            local isHidden = IsBagHidden(self.bagID)
            if isHidden then
                GameTooltip:AddLine(ns.L["RIGHT_CLICK_SHOW_BAG"] or "Right-click to show bag", 0.7, 0.7, 0.7)
            else
                GameTooltip:AddLine(ns.L["RIGHT_CLICK_HIDE_BAG"] or "Right-click to hide bag", 0.7, 0.7, 0.7)
            end
        end
        GameTooltip:Show()

        local ItemButton = ns:GetModule("ItemButton")
        if ItemButton and mainBagFrame and mainBagFrame.container then
            ItemButton:HighlightBagSlots(self.bagID, mainBagFrame.container)
        end
    end)

    bagSlot:SetScript("OnLeave", function(self)
        GameTooltip:Hide()

        local ItemButton = ns:GetModule("ItemButton")
        if ItemButton and mainBagFrame and mainBagFrame.container then
            ItemButton:ResetAllAlpha(mainBagFrame.container)
        end
    end)

    bagSlot:SetScript("OnClick", function(self, button)
        -- Right-click to toggle bag visibility (only in single view mode, not for backpack)
        if button == "RightButton" then
            local viewType = Database:GetSetting("bagViewType") or "single"
            if viewType == "single" and not viewingCharacter and self.bagID ~= 0 then
                ToggleBagVisibility(self.bagID)
                BagSlots:UpdateBagVisualState(self)

                -- Check if this is a soul/quiver bag and update footer toggle state
                local BagClassifier = ns:GetModule("BagFrame.BagClassifier")
                if BagClassifier then
                    local bagType = BagClassifier:GetBagType(self.bagID)
                    if bagType == "soul" then
                        local SoulBag = ns:GetModule("Footer.SoulBag")
                        if SoulBag then
                            SoulBag:UpdateState()
                        end
                    elseif bagType == "quiver" or bagType == "ammo" then
                        local QuiverBag = ns:GetModule("Footer.QuiverBag")
                        if QuiverBag then
                            QuiverBag:UpdateState()
                        end
                    end
                end

                if onBagVisibilityChanged then
                    onBagVisibilityChanged()
                end
            end
            return
        end

        -- Left-click: pickup bag (not backpack)
        if self.bagID ~= 0 then
            local invID = C_Container.ContainerIDToInventoryID(self.bagID)
            if IsModifiedClick("PICKUPITEM") then
                PickupBagFromSlot(invID)
            end
        end
    end)

    -- Enable drag for bag swapping
    if bagID ~= 0 then
        bagSlot:RegisterForDrag("LeftButton")
        bagSlot:SetScript("OnDragStart", function(self)
            local invID = C_Container.ContainerIDToInventoryID(self.bagID)
            PickupBagFromSlot(invID)
        end)
        bagSlot:SetScript("OnReceiveDrag", function(self)
            local invID = C_Container.ContainerIDToInventoryID(self.bagID)
            PutItemInBag(invID)
        end)
    end

    return bagSlot
end

local function CreateBagFlyout(parent)
    local numExtraBags = #Constants.BAG_IDS - 1 -- bags 1-4
    local flyout = CreateFrame("Frame", "GudaBagsFlyout", parent, "BackdropTemplate")
    flyout:SetSize(Constants.FLYOUT_BAG_SIZE + 4, Constants.FLYOUT_BAG_SIZE * numExtraBags + 4)
    flyout:SetPoint("BOTTOMRIGHT", parent, "BOTTOMLEFT", -5, -9)
    flyout:SetFrameStrata("DIALOG")
    flyout:SetFrameLevel(150)

    flyout:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 10,
        insets = {left = 2, right = 2, top = 2, bottom = 2},
    })
    flyout:SetBackdropColor(0.12, 0.12, 0.12, 0.95)
    flyout:SetBackdropBorderColor(0.30, 0.30, 0.30, 1)

    flyout.bagSlots = {}

    -- Create bag slots 1-4 (not backpack) stacked vertically, bottom to top
    for i = 2, #Constants.BAG_IDS do
        local bagID = Constants.BAG_IDS[i]
        local slot = CreateBagSlotButton(flyout, bagID, Constants.FLYOUT_BAG_SIZE)

        if i == 2 then
            slot:SetPoint("BOTTOM", flyout, "BOTTOM", 0, 2)
        else
            slot:SetPoint("BOTTOM", flyout.bagSlots[i - 2], "TOP", 0, 0)
        end

        flyout.bagSlots[i - 1] = slot
    end

    flyout:Hide()
    return flyout
end

local function CreateAllBagSlots(parent)
    local bagSlots = {}
    local bagSlotSize = Constants.BAG_SLOT_SIZE

    for i, bagID in ipairs(Constants.BAG_IDS) do
        local bagSlot = CreateBagSlotButton(parent, bagID, bagSlotSize)

        if i == 1 then
            bagSlot:SetPoint("LEFT", parent, "LEFT", 0, 0)
        else
            bagSlot:SetPoint("LEFT", bagSlots[i-1], "RIGHT", 0, 0)
        end

        bagSlots[i] = bagSlot
    end

    return bagSlots
end

function BagSlots:Init(parent)
    -- Store reference to main BagFrame (parent's parent is the main frame)
    mainBagFrame = parent:GetParent()

    -- Clean up stale backpack hide entry (backpack should never be hidden)
    local hiddenBags = GetHiddenBags()
    if hiddenBags[0] then
        hiddenBags[0] = nil
        SetHiddenBags(hiddenBags)
    end

    frame = CreateFrame("Frame", "GudaBagsBagSlotsFrame", parent)
    frame:SetSize(Constants.BAG_SLOT_SIZE * #Constants.BAG_IDS, Constants.BAG_SLOT_SIZE)
    frame:SetPoint("LEFT", parent, "LEFT", 0, 0)

    -- Create all bag slots (used when Show All Bags is on)
    frame.bagSlots = CreateAllBagSlots(frame)

    -- Create main bag slot for collapsed mode (backpack only)
    local bagSlotSize = Constants.BAG_SLOT_SIZE
    frame.mainBagSlot = CreateBagSlotButton(frame, 0, bagSlotSize)
    frame.mainBagSlot:SetPoint("LEFT", frame, "LEFT", 0, 0)
    frame.mainBagSlot:Hide()

    -- Add click handler for main bag to toggle flyout
    frame.mainBagSlot:HookScript("OnClick", function(self, button)
        if button == "LeftButton" and not IsModifiedClick() then
            BagSlots:ToggleFlyout()
        end
    end)

    -- Create flyout for extra bags
    bagFlyout = CreateBagFlyout(frame.mainBagSlot)

    return frame
end

function BagSlots:Show()
    if not frame then return end
    frame:Show()

    local showAllBags = Database:GetSetting("hoverBagline")

    if showAllBags then
        -- Show all bag slots
        for _, bagSlot in ipairs(frame.bagSlots) do
            bagSlot:Show()
        end
        frame.mainBagSlot:Hide()
        if bagFlyout then
            bagFlyout:Hide()
        end
        bagFlyoutExpanded = false
        -- Reset border color when switching modes
        local fb = Theme:GetValue("footerButtonBorder"); frame.mainBagSlot:SetBackdropBorderColor(fb[1], fb[2], fb[3], fb[4])
    else
        -- Collapsed mode: show only main bag
        for _, bagSlot in ipairs(frame.bagSlots) do
            bagSlot:Hide()
        end
        frame.mainBagSlot:Show()

        if bagFlyout then
            bagFlyout:Hide()
        end
        bagFlyoutExpanded = false

        -- Reset border color when switching modes
        local fb = Theme:GetValue("footerButtonBorder"); frame.mainBagSlot:SetBackdropBorderColor(fb[1], fb[2], fb[3], fb[4])
    end

    self:Update()
end

function BagSlots:Hide()
    if not frame then return end
    frame:Hide()

    for _, bagSlot in ipairs(frame.bagSlots) do
        bagSlot:Hide()
    end
    if frame.mainBagSlot then
        frame.mainBagSlot:Hide()
    end
    if bagFlyout then
        bagFlyout:Hide()
    end
end

function BagSlots:Update()
    if not frame or not frame.bagSlots then return end

    -- Get cached bags if viewing another character
    local cachedBags = nil
    if viewingCharacter then
        cachedBags = Database:GetNormalizedBags(viewingCharacter)
    end

    for _, bagSlot in ipairs(frame.bagSlots) do
        local bagID = bagSlot.bagID
        if bagID == 0 then
            bagSlot.icon:SetTexture("Interface\\Buttons\\Button-Backpack-Up")
        else
            local texture = nil
            if viewingCharacter then
                -- Viewing cached character - only use cached data
                if cachedBags and cachedBags[bagID] and cachedBags[bagID].containerTexture then
                    texture = cachedBags[bagID].containerTexture
                end
                -- No fallback to current player - show empty bag if no cached texture
            else
                -- Current character - use live data
                local invID = C_Container.ContainerIDToInventoryID(bagID)
                texture = GetInventoryItemTexture("player", invID)
            end
            if texture then
                bagSlot.icon:SetTexture(texture)
            else
                bagSlot.icon:SetTexture("Interface\\PaperDoll\\UI-PaperDoll-Slot-Bag")
            end
        end
        -- Apply visual state for hidden bags
        self:UpdateBagVisualState(bagSlot)
    end

    -- Update main bag slot icon and visual state
    if frame.mainBagSlot then
        frame.mainBagSlot.icon:SetTexture("Interface\\AddOns\\GudaBags\\Assets\\bags.tga")
        self:UpdateBagVisualState(frame.mainBagSlot)
    end

    -- Also update flyout bag slots if visible
    if bagFlyout and bagFlyout:IsShown() then
        self:UpdateFlyout()
    end
end

function BagSlots:UpdateFlyout()
    if not bagFlyout or not bagFlyout.bagSlots then return end

    -- Get cached bags if viewing another character
    local cachedBags = nil
    if viewingCharacter then
        cachedBags = Database:GetNormalizedBags(viewingCharacter)
    end

    for _, bagSlot in ipairs(bagFlyout.bagSlots) do
        local bagID = bagSlot.bagID
        local texture = nil
        if viewingCharacter then
            -- Viewing cached character - only use cached data
            if cachedBags and cachedBags[bagID] and cachedBags[bagID].containerTexture then
                texture = cachedBags[bagID].containerTexture
            end
            -- No fallback to current player - show empty bag if no cached texture
        else
            -- Current character - use live data
            local invID = C_Container.ContainerIDToInventoryID(bagID)
            texture = GetInventoryItemTexture("player", invID)
        end
        if texture then
            bagSlot.icon:SetTexture(texture)
        else
            bagSlot.icon:SetTexture("Interface\\PaperDoll\\UI-PaperDoll-Slot-Bag")
        end
        -- Apply visual state for hidden bags
        self:UpdateBagVisualState(bagSlot)
    end
end

function BagSlots:SetViewingCharacter(fullName)
    viewingCharacter = fullName
end

function BagSlots:ToggleFlyout()
    if not bagFlyout then return end

    bagFlyoutExpanded = not bagFlyoutExpanded

    if bagFlyoutExpanded then
        self:UpdateFlyout()
        bagFlyout:Show()
        if frame.mainBagSlot then
            frame.mainBagSlot:SetBackdropBorderColor(1, 0.82, 0, 1)
        end
    else
        bagFlyout:Hide()
        if frame.mainBagSlot then
            local fb = Theme:GetValue("footerButtonBorder"); frame.mainBagSlot:SetBackdropBorderColor(fb[1], fb[2], fb[3], fb[4])
        end
    end
end

function BagSlots:GetAnchor()
    if not frame then return nil end

    local showAllBags = Database:GetSetting("hoverBagline")
    if showAllBags then
        return frame.bagSlots[#frame.bagSlots]
    else
        return frame.mainBagSlot
    end
end

function BagSlots:GetFrame()
    return frame
end

-- Update visual state for a bag slot based on hidden status
function BagSlots:UpdateBagVisualState(bagSlot)
    if not bagSlot then return end

    local viewType = Database:GetSetting("bagViewType") or "single"
    local isHidden = IsBagHidden(bagSlot.bagID)

    -- Only apply hidden visual in single view mode and when not viewing another character
    if viewType == "single" and not viewingCharacter and isHidden then
        bagSlot.icon:SetDesaturated(true)
        bagSlot.icon:SetAlpha(0.4)
    else
        bagSlot.icon:SetDesaturated(false)
        bagSlot.icon:SetAlpha(1.0)
    end
end

-- Update all bag slot visual states
function BagSlots:UpdateAllVisualStates()
    if not frame or not frame.bagSlots then return end

    for _, bagSlot in ipairs(frame.bagSlots) do
        self:UpdateBagVisualState(bagSlot)
    end

    -- Also update flyout if visible
    if bagFlyout and bagFlyout.bagSlots then
        for _, bagSlot in ipairs(bagFlyout.bagSlots) do
            self:UpdateBagVisualState(bagSlot)
        end
    end
end

-- Update theme colors on all bag slot buttons
function BagSlots:UpdateTheme()
    if not frame then return end
    local fbBg = Theme:GetValue("footerButtonBg")
    local fbBorder = Theme:GetValue("footerButtonBorder")

    local function applyColors(bagSlot)
        bagSlot:SetBackdropColor(fbBg[1], fbBg[2], fbBg[3], fbBg[4])
        bagSlot:SetBackdropBorderColor(fbBorder[1], fbBorder[2], fbBorder[3], fbBorder[4])
    end

    -- Main bag slots
    if frame.bagSlots then
        for _, bagSlot in ipairs(frame.bagSlots) do
            applyColors(bagSlot)
        end
    end

    -- Collapsed mode main bag slot
    if frame.mainBagSlot then
        applyColors(frame.mainBagSlot)
    end

    -- Flyout bag slots
    if bagFlyout and bagFlyout.bagSlots then
        for _, bagSlot in ipairs(bagFlyout.bagSlots) do
            applyColors(bagSlot)
        end
    end
end

-- Set callback for when bag visibility changes
function BagSlots:SetVisibilityCallback(callback)
    onBagVisibilityChanged = callback
end

-- Public: Check if a bag is hidden
function BagSlots:IsBagHidden(bagID)
    return IsBagHidden(bagID)
end

-- Public: Get all hidden bag IDs
function BagSlots:GetHiddenBags()
    return GetHiddenBags()
end
