local addonName, ns = ...

-- Quiver/Ammo bags exist in Classic Era and TBC only (Hunter class feature).
-- Retail removed quivers, ammo pouches, and ammunition in Cataclysm (4.0).
local _, playerClass = UnitClass("player")
local Expansion = ns:GetModule("Expansion")
if playerClass ~= "HUNTER" or not (Expansion and Expansion.Features and Expansion.Features.HasQuiverBags) then
    -- Register empty stub module for non-Hunters / Retail
    ns:RegisterModule("Footer.QuiverBag", {
        Init = function() return nil end,
        Show = function() end,
        Hide = function() end,
        SetAnchor = function() end,
        SetCallback = function() end,
        IsVisible = function() return true end,
        GetButton = function() return nil end,
        UpdateState = function() end,
    })
    return
end

local QuiverBag = {}
ns:RegisterModule("Footer.QuiverBag", QuiverBag)

local Constants = ns.Constants
local L = ns.L

local Database = ns:GetModule("Database")

local button = nil
local onQuiverBagToggle = nil
local mainBagFrame = nil

-- Check if we're currently in category view
local function IsCategoryView()
    return (Database:GetSetting("bagViewType") or "single") == "category"
end

-- Check if quiver/ammo items are shown in category view
local function IsQuiverItemsVisible()
    return not Database:GetSetting("hideQuiverItems")
end

-- Get all quiver/ammo bag IDs from BagClassifier
local function GetQuiverBagIDs()
    local BagClassifier = ns:GetModule("BagFrame.BagClassifier")
    local BagScanner = ns:GetModule("BagScanner")
    if not BagClassifier or not BagScanner then return {} end

    local bags = BagScanner:GetCachedBags()
    local classified = BagClassifier:ClassifyBags(bags, false)
    local result = {}
    for _, bagID in ipairs(classified.quiver or {}) do
        table.insert(result, bagID)
    end
    for _, bagID in ipairs(classified.ammo or {}) do
        table.insert(result, bagID)
    end
    return result
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

-- Check if ANY quiver/ammo bag is visible (not hidden)
local function IsAnyQuiverBagVisible()
    local quiverBagIDs = GetQuiverBagIDs()
    if #quiverBagIDs == 0 then return false end

    local hiddenBags = GetHiddenBags()
    for _, bagID in ipairs(quiverBagIDs) do
        if not hiddenBags[bagID] then
            return true
        end
    end
    return false
end

-- Check if ALL quiver/ammo bags are hidden
local function AreAllQuiverBagsHidden()
    local quiverBagIDs = GetQuiverBagIDs()
    if #quiverBagIDs == 0 then return true end

    return not IsAnyQuiverBagVisible()
end

-- Hide all quiver/ammo bags
local function HideAllQuiverBags()
    local quiverBagIDs = GetQuiverBagIDs()
    local hiddenBags = GetHiddenBags()

    for _, bagID in ipairs(quiverBagIDs) do
        hiddenBags[bagID] = true
    end

    SetHiddenBags(hiddenBags)
end

-- Show all quiver/ammo bags (remove from hidden)
local function ShowAllQuiverBags()
    local quiverBagIDs = GetQuiverBagIDs()
    local hiddenBags = GetHiddenBags()

    for _, bagID in ipairs(quiverBagIDs) do
        hiddenBags[bagID] = nil
    end

    SetHiddenBags(hiddenBags)
end

-- Legacy compatibility: IsShowingQuiverBag now checks hiddenBags
local function IsShowingQuiverBag()
    return IsAnyQuiverBagVisible()
end

-- Legacy compatibility: SetShowingQuiverBag now modifies hiddenBags
local function SetShowingQuiverBag(value)
    if value then
        ShowAllQuiverBags()
    else
        HideAllQuiverBags()
    end
end

function QuiverBag:Init(parent)
    -- Store reference to main BagFrame (parent's parent is the main frame)
    mainBagFrame = parent:GetParent()

    local bagSlotSize = Constants.BAG_SLOT_SIZE
    button = CreateFrame("Button", "GudaBagsQuiverBagButton", parent, "BackdropTemplate")
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
    icon:SetTexture("Interface\\AddOns\\GudaBags\\Assets\\quiver.tga")
    button.icon = icon

    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    highlight:SetBlendMode("ADD")

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(L["QUIVERBAG"] or "Quiver Bag")
        if IsCategoryView() then
            if IsQuiverItemsVisible() then
                GameTooltip:AddLine(L["CLICK_HIDE_QUIVER_CATEGORY"] or "Click to hide arrows/bullets", 0.7, 0.7, 0.7)
            else
                GameTooltip:AddLine(L["CLICK_SHOW_QUIVER_CATEGORY"] or "Click to show arrows/bullets", 0.7, 0.7, 0.7)
            end
        else
            if IsAnyQuiverBagVisible() then
                GameTooltip:AddLine(L["CLICK_HIDE_QUIVERBAG"] or "Click to hide all quiver bags", 0.7, 0.7, 0.7)
            else
                GameTooltip:AddLine(L["CLICK_SHOW_QUIVERBAG"] or "Click to show all quiver bags", 0.7, 0.7, 0.7)
            end
        end
        GameTooltip:Show()

        if not IsCategoryView() and IsAnyQuiverBagVisible() then
            local ItemButton = ns:GetModule("ItemButton")
            local BagClassifier = ns:GetModule("BagFrame.BagClassifier")
            if ItemButton and BagClassifier and mainBagFrame and mainBagFrame.container then
                local quiverBagIDs = GetQuiverBagIDs()
                for _, bagID in ipairs(quiverBagIDs) do
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
            -- In category view, toggle arrow/bullet item visibility
            local wasVisible = IsQuiverItemsVisible()
            Database:SetSetting("hideQuiverItems", wasVisible)
            QuiverBag:UpdateState()

            if onQuiverBagToggle then
                onQuiverBagToggle(not wasVisible)
            end
        else
            -- In single/split view, toggle quiver/ammo bag visibility
            local newValue = not IsAnyQuiverBagVisible()
            SetShowingQuiverBag(newValue)
            QuiverBag:UpdateState()

            -- Update BagSlots visual states for quiver bags
            local BagSlots = ns:GetModule("Footer.BagSlots")
            if BagSlots then
                BagSlots:UpdateAllVisualStates()
            end

            if onQuiverBagToggle then
                onQuiverBagToggle(newValue)
            end
        end
    end)

    return button
end

function QuiverBag:SetAnchor(anchorTo)
    if not button then return end
    button:ClearAllPoints()
    button:SetPoint("LEFT", anchorTo, "RIGHT", 1, 0)
end

function QuiverBag:Show()
    if button then
        button:Show()
    end
end

function QuiverBag:Hide()
    if button then
        button:Hide()
    end
end

function QuiverBag:UpdateState()
    if not button then return end
    local isActive
    if IsCategoryView() then
        isActive = IsQuiverItemsVisible()
    else
        isActive = IsAnyQuiverBagVisible()
    end

    if isActive then
        button:SetBackdropBorderColor(0.7, 0.5, 0.2, 1)  -- Brown/leather border when showing
        button.icon:SetDesaturated(false)
        button.icon:SetAlpha(1.0)
    else
        button:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.7)
        button.icon:SetDesaturated(true)
        button.icon:SetAlpha(0.4)
    end
end

function QuiverBag:SetCallback(callback)
    onQuiverBagToggle = callback
end

function QuiverBag:IsVisible()
    -- Always return bag-level visibility (used by BuildDisplayOrder to include quiver/ammo bags)
    -- In category view, quiver bags should always be included so empty slot counting works;
    -- item-level hiding is handled separately by the hideQuiverItems setting in LayoutEngine
    return IsShowingQuiverBag()
end

function QuiverBag:GetButton()
    return button
end
