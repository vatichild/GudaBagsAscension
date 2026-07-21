local addonName, ns = ...

-- Classic Era and TBC feature guard
-- Keyring exists in Classic Era and TBC, removed in later expansions
local Expansion = ns:GetModule("Expansion")
if not Expansion.Features.HasKeyring then
    -- Register empty stub module for non-TBC expansions
    ns:RegisterModule("Footer.Keyring", {
        Init = function() return nil end,
        Show = function() end,
        Hide = function() end,
        SetAnchor = function() end,
        SetCallback = function() end,
        IsVisible = function() return false end,
        GetButton = function() return nil end,
        UpdateState = function() end,
        UpdateTheme = function() end,
    })
    return
end

local Keyring = {}
ns:RegisterModule("Footer.Keyring", Keyring)

local Constants = ns.Constants
local Theme = ns:GetModule("Theme")
local L = ns.L

local button = nil
local showKeyring = false
local onKeyringToggle = nil
local mainBagFrame = nil

function Keyring:Init(parent)
    -- Store reference to main BagFrame (parent's parent is the main frame)
    mainBagFrame = parent:GetParent()

    local bagSlotSize = Constants.BAG_SLOT_SIZE
    button = CreateFrame("Button", "GudaBagsKeyringButton", parent, "BackdropTemplate")
    button:SetSize(bagSlotSize, bagSlotSize)
    button:EnableMouse(true)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    button:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8,
        insets = {left = 2, right = 2, top = 2, bottom = 2},
    })
    local fbBg = Theme:GetValue("footerButtonBg")
    local fbBorder = Theme:GetValue("footerButtonBorder")
    button:SetBackdropColor(fbBg[1], fbBg[2], fbBg[3], fbBg[4])
    button:SetBackdropBorderColor(fbBorder[1], fbBorder[2], fbBorder[3], fbBorder[4])

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetPoint("CENTER")
    icon:SetTexture("Interface\\AddOns\\GudaBags\\Assets\\keyring.tga")
    button.icon = icon

    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    highlight:SetBlendMode("ADD")

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(KEYRING or L["KEYRING"])
        if showKeyring then
            GameTooltip:AddLine(L["CLICK_HIDE_KEYRING"], 0.7, 0.7, 0.7)
        else
            GameTooltip:AddLine(L["CLICK_SHOW_KEYRING"], 0.7, 0.7, 0.7)
        end
        GameTooltip:Show()

        if showKeyring then
            local ItemButton = ns:GetModule("ItemButton")
            if ItemButton and mainBagFrame and mainBagFrame.container then
                ItemButton:HighlightBagSlots(Constants.KEYRING_BAG_ID, mainBagFrame.container)
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
        showKeyring = not showKeyring
        Keyring:UpdateState()
        if onKeyringToggle then
            onKeyringToggle(showKeyring)
        end
    end)

    return button
end

function Keyring:SetAnchor(anchorTo)
    if not button then return end
    button:ClearAllPoints()
    button:SetPoint("LEFT", anchorTo, "RIGHT", 1, 0)
end

function Keyring:Show()
    if button then
        button:Show()
    end
end

function Keyring:Hide()
    if button then
        button:Hide()
    end
end

function Keyring:UpdateState()
    if not button then return end
    if showKeyring then
        button:SetBackdropBorderColor(1, 0.82, 0, 1)
    else
        local fb = Theme:GetValue("footerButtonBorder"); button:SetBackdropBorderColor(fb[1], fb[2], fb[3], fb[4])
    end
end

function Keyring:SetCallback(callback)
    onKeyringToggle = callback
end

function Keyring:IsVisible()
    return showKeyring
end

function Keyring:GetButton()
    return button
end

function Keyring:UpdateTheme()
    if not button then return end
    local fbBg = Theme:GetValue("footerButtonBg")
    local fbBorder = Theme:GetValue("footerButtonBorder")
    button:SetBackdropColor(fbBg[1], fbBg[2], fbBg[3], fbBg[4])
    button:SetBackdropBorderColor(fbBorder[1], fbBorder[2], fbBorder[3], fbBorder[4])
end
