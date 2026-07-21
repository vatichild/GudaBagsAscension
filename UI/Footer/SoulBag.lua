local addonName, ns = ...

-- Soul bags exist in Classic Era and TBC (Warlock class feature)
-- Check if player is a Warlock
local _, playerClass = UnitClass("player")
if playerClass ~= "WARLOCK" then
    -- Register empty stub module for non-Warlocks
    ns:RegisterModule("Footer.SoulBag", {
        Init = function() return nil end,
        Show = function() end,
        Hide = function() end,
        SetAnchor = function() end,
        SetCallback = function() end,
        IsVisible = function() return true end,  -- Default to showing soul bags when not a warlock (no toggle needed)
        GetButton = function() return nil end,
        UpdateState = function() end,
    })
    return
end

local SoulBag = {}
ns:RegisterModule("Footer.SoulBag", SoulBag)

local Constants = ns.Constants
local L = ns.L

local Database = ns:GetModule("Database")

local button = nil
local onSoulBagToggle = nil
local mainBagFrame = nil

-- Check if we're currently in category view
local function IsCategoryView()
    return (Database:GetSetting("bagViewType") or "single") == "category"
end

-- Check if soul shard items are shown in category view
local function IsSoulItemsVisible()
    return not Database:GetSetting("hideSoulItems")
end

-- Get all soul bag IDs from BagClassifier
local function GetSoulBagIDs()
    local BagClassifier = ns:GetModule("BagFrame.BagClassifier")
    local BagScanner = ns:GetModule("BagScanner")
    if not BagClassifier or not BagScanner then return {} end

    local bags = BagScanner:GetCachedBags()
    local classified = BagClassifier:ClassifyBags(bags, false)
    return classified.soul or {}
end

-- Get hidden bags from database
local function GetHiddenBags()
    return Database:GetSetting("hiddenBags") or {}
end

-- Set hidden bags in database
local function SetHiddenBags(hiddenBags)
    Database:SetSetting("hiddenBags", hiddenBags)
end

-- Check if a specific bag is hidden
local function IsBagHidden(bagID)
    local hiddenBags = GetHiddenBags()
    return hiddenBags[bagID] == true
end

-- Check if ANY soul bag is visible (not hidden)
-- Returns true if at least one soul bag is visible
local function IsAnySoulBagVisible()
    local soulBagIDs = GetSoulBagIDs()
    if #soulBagIDs == 0 then return false end

    local hiddenBags = GetHiddenBags()
    for _, bagID in ipairs(soulBagIDs) do
        if not hiddenBags[bagID] then
            return true  -- At least one soul bag is visible
        end
    end
    return false  -- All soul bags are hidden
end

-- Check if ALL soul bags are hidden
local function AreAllSoulBagsHidden()
    local soulBagIDs = GetSoulBagIDs()
    if #soulBagIDs == 0 then return true end

    return not IsAnySoulBagVisible()
end

-- Hide all soul bags
local function HideAllSoulBags()
    local soulBagIDs = GetSoulBagIDs()
    local hiddenBags = GetHiddenBags()

    for _, bagID in ipairs(soulBagIDs) do
        hiddenBags[bagID] = true
    end

    SetHiddenBags(hiddenBags)
end

-- Show all soul bags (remove from hidden)
local function ShowAllSoulBags()
    local soulBagIDs = GetSoulBagIDs()
    local hiddenBags = GetHiddenBags()

    for _, bagID in ipairs(soulBagIDs) do
        hiddenBags[bagID] = nil
    end

    SetHiddenBags(hiddenBags)
end

-- Legacy compatibility: IsShowingSoulBag now checks hiddenBags
local function IsShowingSoulBag()
    return IsAnySoulBagVisible()
end

-- Legacy compatibility: SetShowingSoulBag now modifies hiddenBags
local function SetShowingSoulBag(value)
    if value then
        ShowAllSoulBags()
    else
        HideAllSoulBags()
    end
end

function SoulBag:Init(parent)
    -- Store reference to main BagFrame (parent's parent is the main frame)
    mainBagFrame = parent:GetParent()

    local bagSlotSize = Constants.BAG_SLOT_SIZE
    button = CreateFrame("Button", "GudaBagsSoulBagButton", parent, "BackdropTemplate")
    button:SetSize(bagSlotSize, bagSlotSize)
    button:EnableMouse(true)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    button:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8,
        insets = {left = 2, right = 2, top = 2, bottom = 2},
    })
    button:SetBackdropColor(0.15, 0.15, 0.15, 0.7)
    button:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.7)

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetPoint("CENTER")
    icon:SetTexture("Interface\\AddOns\\GudaBags\\Assets\\soul.tga")
    button.icon = icon

    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    highlight:SetBlendMode("ADD")

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(L["SOULBAG"] or "Soul Bag")
        if IsCategoryView() then
            if IsSoulItemsVisible() then
                GameTooltip:AddLine(L["CLICK_HIDE_SOUL_CATEGORY"] or "Click to hide soul shards", 0.7, 0.7, 0.7)
            else
                GameTooltip:AddLine(L["CLICK_SHOW_SOUL_CATEGORY"] or "Click to show soul shards", 0.7, 0.7, 0.7)
            end
        else
            if IsAnySoulBagVisible() then
                GameTooltip:AddLine(L["CLICK_HIDE_SOULBAG"] or "Click to hide all soul bags", 0.7, 0.7, 0.7)
            else
                GameTooltip:AddLine(L["CLICK_SHOW_SOULBAG"] or "Click to show all soul bags", 0.7, 0.7, 0.7)
            end
        end
        GameTooltip:Show()

        if not IsCategoryView() and IsAnySoulBagVisible() then
            local ItemButton = ns:GetModule("ItemButton")
            local BagClassifier = ns:GetModule("BagFrame.BagClassifier")
            if ItemButton and BagClassifier and mainBagFrame and mainBagFrame.container then
                -- Highlight all visible soul bag slots
                local soulBagIDs = GetSoulBagIDs()
                for _, bagID in ipairs(soulBagIDs) do
                    if not IsBagHidden(bagID) then
                        ItemButton:HighlightBagSlots(bagID, mainBagFrame.container)
                    end
                end
            end
        end
    end)

    button:SetScript("OnLeave", function()
        GameTooltip:Hide()

        local ItemButton = ns:GetModule("ItemButton")
        if ItemButton and mainBagFrame and mainBagFrame.container then
            ItemButton:ResetAllAlpha(mainBagFrame.container)
        end
    end)

    button:SetScript("OnClick", function(self)
        if IsCategoryView() then
            -- In category view, toggle soul shard item visibility
            local wasVisible = IsSoulItemsVisible()
            Database:SetSetting("hideSoulItems", wasVisible)
            SoulBag:UpdateState()

            if onSoulBagToggle then
                onSoulBagToggle(not wasVisible)
            end
        else
            -- In single/split view, toggle soul bag visibility
            local newValue = not IsAnySoulBagVisible()
            SetShowingSoulBag(newValue)
            SoulBag:UpdateState()

            -- Update BagSlots visual states for soul bags
            local BagSlots = ns:GetModule("Footer.BagSlots")
            if BagSlots then
                BagSlots:UpdateAllVisualStates()
            end

            if onSoulBagToggle then
                onSoulBagToggle(newValue)
            end
        end
    end)

    return button
end

function SoulBag:SetAnchor(anchorTo)
    if not button then return end
    button:ClearAllPoints()
    button:SetPoint("LEFT", anchorTo, "RIGHT", 1, 0)
end

function SoulBag:Show()
    if button then
        button:Show()
    end
end

function SoulBag:Hide()
    if button then
        button:Hide()
    end
end

function SoulBag:UpdateState()
    if not button then return end
    local isActive
    if IsCategoryView() then
        isActive = IsSoulItemsVisible()
    else
        isActive = IsAnySoulBagVisible()
    end

    if isActive then
        button:SetBackdropBorderColor(0.5, 0.3, 0.8, 1)  -- Purple border when showing
        button.icon:SetDesaturated(false)
        button.icon:SetAlpha(1.0)
    else
        button:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.7)
        button.icon:SetDesaturated(true)
        button.icon:SetAlpha(0.4)
    end
end

function SoulBag:SetCallback(callback)
    onSoulBagToggle = callback
end

function SoulBag:IsVisible()
    -- Always return bag-level visibility (used by BuildDisplayOrder to include soul bags)
    -- In category view, soul bags should always be included so empty slot counting works;
    -- item-level hiding is handled separately by the hideSoulItems setting in LayoutEngine
    return IsShowingSoulBag()
end

function SoulBag:GetButton()
    return button
end
