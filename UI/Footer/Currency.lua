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

local L = ns.L
local API = ns:GetModule("Compatibility.API")
local Tooltip = ns:GetModule("Tooltip")

local containerFrame = nil
local tokenButtons = {}

-- Resolved once, at file scope: Init creates exactly this many buttons at login
-- and never creates another. Rule 3 -- nothing that draws in the bag frame may
-- be created after combat can start. WotLK caps the tracked set at 3.
local MAX_TOKENS = (type(MAX_WATCHED_TOKENS) == "number" and MAX_WATCHED_TOKENS) or 8

local isWotLK = Expansion.CurrencyAPI == "wotlk"

-- Detailed per-currency info is a retail/MoP call. It does not exist on 3.3.5a,
-- where the token's own item tooltip carries the same information.
local _GetCurrencyInfo = (C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo) or GetCurrencyInfo

local function GetDetailedCurrencyInfo(currencyID)
    if not _GetCurrencyInfo then return nil end
    local result, currentAmount, _, _, _, totalMax = _GetCurrencyInfo(currencyID)
    if type(result) == "table" then
        if not result.name then return nil end
        return result.name, result.quantity, result.maxQuantity, result.totalEarned
    elseif result then
        return result, currentAmount, totalMax, nil
    end
    return nil
end

-- Honor and arena rows have no itemID, so there is no item tooltip to borrow and
-- no icon in the info tuple either. Fall back to the client's own PvP currency art.
local function GetExtraCurrencyIcon(extraType)
    local faction = UnitFactionGroup("player")
    if faction ~= "Alliance" and faction ~= "Horde" then return nil end
    if extraType == 1 then
        return "Interface\\PVPFrame\\PVPCurrency-Honor-" .. faction
    elseif extraType == 2 then
        return "Interface\\PVPFrame\\PVPCurrency-Arena-" .. faction
    end
    return nil
end

local function GetExtraCurrencyMax(extraType)
    if extraType == 1 and GetHonorCurrency then
        local _, maxHonor = GetHonorCurrency()
        return maxHonor
    elseif extraType == 2 and GetMaxArenaCurrency then
        return GetMaxArenaCurrency()
    end
    return nil
end

-- Guarded on the name, not on currencyKey: a row that yields no usable key (no
-- itemID and no extraCurrencyType) still has a name and a count worth showing.
local function ShowTokenTooltip(self)
    if not self.currencyName then return end

    GameTooltip:SetOwner(self, "ANCHOR_TOP")

    local handled = false

    if isWotLK and self.itemID and self.itemID > 0 then
        -- WotLK currencies are real items, so the client already has a full
        -- localized tooltip for them -- name, quality, cap text, the lot.
        --
        -- Only when the item is actually cached, though. An uncached item still
        -- produces a tooltip, but one that reads "Retrieving item information",
        -- which is worse than the hand-built lines below.
        if GetItemInfo(self.itemID) then
            GameTooltip:SetHyperlink("item:" .. self.itemID)
            handled = true
        end
    elseif not isWotLK then
        local name, quantity, maxQuantity, totalEarned = GetDetailedCurrencyInfo(self.currencyKey)
        if name then
            handled = true
            GameTooltip:AddLine(name, 1, 1, 1)
            GameTooltip:AddLine(" ")
            GameTooltip:AddDoubleLine(L["CURRENCY_QUANTITY"], BreakUpLargeNumbers(quantity), 0.8, 0.8, 0.8, 1, 1, 1)
            if maxQuantity and maxQuantity > 0 then
                GameTooltip:AddDoubleLine(L["CURRENCY_MAXIMUM"], BreakUpLargeNumbers(maxQuantity), 0.8, 0.8, 0.8, 1, 1, 1)
            end
            if totalEarned and totalEarned > 0 then
                GameTooltip:AddDoubleLine(L["CURRENCY_TOTAL_EARNED"], BreakUpLargeNumbers(totalEarned), 0.8, 0.8, 0.8, 1, 1, 1)
            end
        end
    end

    -- Honor/arena rows, and any token whose item is not in the client cache yet.
    -- The name comes from the client already localized, so it needs no key.
    if not handled then
        GameTooltip:AddLine(self.currencyName, 1, 1, 1)
        GameTooltip:AddLine(" ")
        GameTooltip:AddDoubleLine(L["CURRENCY_QUANTITY"], BreakUpLargeNumbers(self.currencyCount or 0), 0.8, 0.8, 0.8, 1, 1, 1)
        local maxQuantity = self.extraType ~= 0 and GetExtraCurrencyMax(self.extraType) or nil
        if maxQuantity and maxQuantity > 0 then
            GameTooltip:AddDoubleLine(L["CURRENCY_MAXIMUM"], BreakUpLargeNumbers(maxQuantity), 0.8, 0.8, 0.8, 1, 1, 1)
        end
    end

    -- Cross-character "Owned by" breakdown. We build this tooltip manually (no
    -- Set*Currency call fires), so add the section directly and skip the dup guard.
    if Tooltip and Tooltip.AddCurrencySection then
        Tooltip:AddCurrencySection(GameTooltip, self.currencyKey, true)
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

    -- Hook the tracking toggles. Ticking "show on backpack" does not reliably
    -- fire CURRENCY_DISPLAY_UPDATE, so without these the footer only catches up
    -- on the next amount change.
    if C_CurrencyInfo and C_CurrencyInfo.SetCurrencyBackpack then
        hooksecurefunc(C_CurrencyInfo, "SetCurrencyBackpack", function()
            C_Timer.After(0.1, function() Currency:Update() end)
        end)
    elseif SetCurrencyBackpack then
        hooksecurefunc("SetCurrencyBackpack", function()
            C_Timer.After(0.1, function() Currency:Update() end)
        end)
    end

    -- Ascension's own name for the same toggle (docs\ASCENSION-API.md section 5).
    if type(SetCurrencyShow) == "function" then
        hooksecurefunc("SetCurrencyShow", function()
            C_Timer.After(0.1, function() Currency:Update() end)
        end)
    end

    return containerFrame
end

-- Guard for the deferred re-layout below. Without a cap, a string width that
-- stays stubbornly at 0 schedules a fresh closure on every single Update -- an
-- unbounded allocation path in code that runs on every currency tick (Rule 2).
local relayoutPending = false
local relayoutRetries = 0
local MAX_RELAYOUT_RETRIES = 2

function Currency:Update()
    if not containerFrame then return end

    local totalWidth = 0
    local needsLayout = false

    for i = 1, MAX_TOKENS do
        local btn = tokenButtons[i]
        local name, quantity, extraType, icon, itemID = API:GetTrackedCurrency(i)
        if name then
            quantity = quantity or 0
            btn.currencyKey = API:GetCurrencyKey(itemID, extraType)
            btn.itemID = itemID or 0
            btn.extraType = extraType or 0
            btn.currencyName = name
            btn.currencyCount = quantity

            -- 3.3.5a hands back a texture PATH here; retail a fileID. SetTexture
            -- takes either.
            btn.icon:SetTexture(icon or GetExtraCurrencyIcon(btn.extraType))

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
    if not needsLayout then
        relayoutRetries = 0
    elseif not relayoutPending and relayoutRetries < MAX_RELAYOUT_RETRIES
        and containerFrame:IsVisible() then
        relayoutPending = true
        relayoutRetries = relayoutRetries + 1
        C_Timer.After(0, function()
            relayoutPending = false
            if containerFrame and containerFrame:IsVisible() then
                Currency:Update()
            end
        end)
    end
end

function Currency:Show()
    if containerFrame then
        containerFrame:Show()
        relayoutRetries = 0
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
    -- Nothing to do: Core\Theme.lua exposes no text or icon colour key that
    -- applies here, and the count deliberately matches the footer's other
    -- secondary text (slot counter, gold) at a fixed 0.8 grey.
end
