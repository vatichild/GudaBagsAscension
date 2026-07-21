local addonName, ns = ...

-- Feature guard
local Expansion = ns:GetModule("Expansion")
if not Expansion.Features.HasCurrency then
    ns:RegisterModule("Footer.Currency", {
        Init = function() return nil end,
        Show = function() end,
        Hide = function() end,
        Update = function() end,
        GetFrame = function() return nil end,
        UpdateTheme = function() end,
    })
    return
end

local Currency = {}
ns:RegisterModule("Footer.Currency", Currency)

local Tooltip = ns:GetModule("Tooltip")

local containerFrame = nil
local tokenButtons = {}
local MAX_TOKENS = 8

local isRetail = Expansion.IsRetail

-- API abstraction: Retail uses C_CurrencyInfo namespace, Classic uses globals
-- GetBackpackCurrencyInfo returns nil for out-of-range indices, so no count function needed
local GetTrackedCurrencyInfo, GetDetailedCurrencyInfo

-- Normalize result from GetBackpackCurrencyInfo: may return a table or multiple values
local function NormalizeBackpackInfo(result, ...)
    if type(result) == "table" then
        if not result.name then return nil end
        return result.name, result.quantity, result.iconFileID, result.currencyTypesID
    elseif result then
        -- Multi-return: name, count, icon, currencyID
        return result, ...
    end
    return nil
end

-- Normalize result from GetCurrencyInfo: may return a table or multiple values
local function NormalizeDetailedInfo(result, ...)
    if type(result) == "table" then
        if not result.name then return nil end
        return result.name, result.quantity, result.maxQuantity, result.totalEarned
    elseif result then
        -- Multi-return: name, currentAmount, texture, earnedThisWeek, weeklyMax, totalMax, ...
        local name = result
        local currentAmount, _, _, _, totalMax = ...
        return name, currentAmount, totalMax, nil
    end
    return nil
end

local _GetBackpackCurrencyInfo = (C_CurrencyInfo and C_CurrencyInfo.GetBackpackCurrencyInfo) or GetBackpackCurrencyInfo
local _GetCurrencyInfo = (C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo) or GetCurrencyInfo

if _GetBackpackCurrencyInfo then
    GetTrackedCurrencyInfo = function(index)
        return NormalizeBackpackInfo(_GetBackpackCurrencyInfo(index))
    end
else
    GetTrackedCurrencyInfo = function() return nil end
end

if _GetCurrencyInfo then
    GetDetailedCurrencyInfo = function(currencyID)
        return NormalizeDetailedInfo(_GetCurrencyInfo(currencyID))
    end
else
    GetDetailedCurrencyInfo = nil
end

local function ShowTokenTooltip(self)
    if not self.currencyID then return end

    GameTooltip:SetOwner(self, "ANCHOR_TOP")

    if GetDetailedCurrencyInfo then
        local name, quantity, maxQuantity, totalEarned = GetDetailedCurrencyInfo(self.currencyID)
        if name then
            GameTooltip:AddLine(name, 1, 1, 1)
            GameTooltip:AddLine(" ")
            GameTooltip:AddDoubleLine("Quantity:", BreakUpLargeNumbers(quantity), 0.8, 0.8, 0.8, 1, 1, 1)
            if maxQuantity and maxQuantity > 0 then
                GameTooltip:AddDoubleLine("Maximum:", BreakUpLargeNumbers(maxQuantity), 0.8, 0.8, 0.8, 1, 1, 1)
            end
            if totalEarned and totalEarned > 0 then
                GameTooltip:AddDoubleLine("Total Earned:", BreakUpLargeNumbers(totalEarned), 0.8, 0.8, 0.8, 1, 1, 1)
            end
        end
    else
        -- Fallback (TBC): show basic info from stored data
        if self.currencyName then
            GameTooltip:AddLine(self.currencyName, 1, 1, 1)
            GameTooltip:AddLine(" ")
            GameTooltip:AddDoubleLine("Quantity:", BreakUpLargeNumbers(self.currencyCount or 0), 0.8, 0.8, 0.8, 1, 1, 1)
        end
    end

    -- Cross-character "Owned by" breakdown. We build this tooltip manually (no
    -- Set*Currency call fires), so add the section directly and skip the dup guard.
    if Tooltip and Tooltip.AddCurrencySection then
        Tooltip:AddCurrencySection(GameTooltip, self.currencyID, true)
    end

    GameTooltip:Show()
end

local function CreateTokenButton(parent)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(60, 16)
    btn:EnableMouse(true)

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(14, 14)
    icon:SetPoint("RIGHT", btn, "RIGHT", 0, 0)
    btn.icon = icon

    local text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("RIGHT", icon, "LEFT", -2, 0)
    text:SetTextColor(0.8, 0.8, 0.8)
    text:SetShadowOffset(1, -1)
    text:SetShadowColor(0, 0, 0, 1)
    btn.text = text

    btn:SetScript("OnEnter", ShowTokenTooltip)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    btn:Hide()
    return btn
end

function Currency:Init(parent)
    containerFrame = CreateFrame("Frame", "GudaBagsCurrencyFrame", parent)
    containerFrame:SetHeight(16)
    containerFrame:SetWidth(1)

    for i = 1, MAX_TOKENS do
        tokenButtons[i] = CreateTokenButton(containerFrame)
    end

    containerFrame:RegisterEvent("CURRENCY_DISPLAY_UPDATE")
    containerFrame:SetScript("OnEvent", function()
        Currency:Update()
    end)

    -- Hook SetCurrencyBackpack / C_CurrencyInfo.SetCurrencyBackpack for tracking toggles
    -- These don't fire CURRENCY_DISPLAY_UPDATE on all versions
    if C_CurrencyInfo and C_CurrencyInfo.SetCurrencyBackpack then
        hooksecurefunc(C_CurrencyInfo, "SetCurrencyBackpack", function()
            C_Timer.After(0.1, function() Currency:Update() end)
        end)
    elseif SetCurrencyBackpack then
        hooksecurefunc("SetCurrencyBackpack", function()
            C_Timer.After(0.1, function() Currency:Update() end)
        end)
    end

    return containerFrame
end

function Currency:Update()
    if not containerFrame then return end

    local totalWidth = 0
    local activeCount = 0
    local needsLayout = false

    for i = 1, MAX_TOKENS do
        local btn = tokenButtons[i]
        local name, quantity, iconFileID, currencyID = GetTrackedCurrencyInfo(i)
        if name then
            activeCount = i
            btn.currencyID = currencyID
            btn.currencyName = name
            btn.currencyCount = quantity
            btn.icon:SetTexture(iconFileID)

            local quantityText = BreakUpLargeNumbers(quantity)
            btn.text:SetText(quantityText)

            -- GetStringWidth returns 0 before the frame has been rendered
            local textWidth = btn.text:GetStringWidth()
            if textWidth == 0 then
                needsLayout = true
                -- Estimate: ~7px per character for GameFontNormalSmall
                textWidth = #quantityText * 7
            end

            local btnWidth = textWidth + 14 + 2
            btn:SetWidth(btnWidth)

            btn:ClearAllPoints()
            btn:SetPoint("RIGHT", containerFrame, "RIGHT", -totalWidth, 0)

            totalWidth = totalWidth + btnWidth + 8
            btn:Show()
        else
            btn:Hide()
        end
    end

    if totalWidth > 0 then
        containerFrame:SetWidth(totalWidth)
    else
        containerFrame:SetWidth(1)
    end

    -- Re-layout once text has been rendered for accurate widths
    if needsLayout and containerFrame:IsVisible() then
        C_Timer.After(0, function()
            if containerFrame and containerFrame:IsVisible() then
                Currency:Update()
            end
        end)
    end
end

function Currency:Show()
    if containerFrame then
        containerFrame:Show()
        self:Update()
    end
end

function Currency:Hide()
    if containerFrame then
        containerFrame:Hide()
    end
end

function Currency:GetFrame()
    return containerFrame
end

function Currency:UpdateTheme()
    -- Token text uses standard colors, no theme-specific updates needed
end
