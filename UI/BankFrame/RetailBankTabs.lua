local addonName, ns = ...

-- Only load on Retail
if not ns.IsRetail then return end

local RetailBankTabs = {}
ns:RegisterModule("BankFrame.RetailBankTabs", RetailBankTabs)

local Constants = ns.Constants

local frame = nil
local bankTypeButtons = {}
local onBankTypeChanged = nil
local RetailBankScanner = nil

local BANK_TYPE_CHARACTER = Enum.BankType.Character
local BANK_TYPE_ACCOUNT = Enum.BankType.Account

local function LoadComponents()
    RetailBankScanner = ns:GetModule("RetailBankScanner")
end

local function CreateBankTypeButton(parent, bankType, name, icon, index)
    local button = CreateFrame("Button", nil, parent, "BackdropTemplate")
    button:SetSize(80, 24)
    button.bankType = bankType

    button:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 },
    })

    -- Icon
    local iconTex = button:CreateTexture(nil, "ARTWORK")
    iconTex:SetSize(16, 16)
    iconTex:SetPoint("LEFT", button, "LEFT", 4, 0)
    iconTex:SetTexture(icon)
    iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    button.icon = iconTex

    -- Text
    local text = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("LEFT", iconTex, "RIGHT", 4, 0)
    text:SetPoint("RIGHT", button, "RIGHT", -4, 0)
    text:SetText(name)
    text:SetJustifyH("LEFT")
    button.text = text

    -- Highlight
    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetTexture("Interface\\Buttons\\WHITE8x8")
    highlight:SetVertexColor(1, 1, 1, 0.1)

    button:SetScript("OnClick", function(self)
        RetailBankTabs:SetActiveBankType(self.bankType)
        if onBankTypeChanged then
            onBankTypeChanged(self.bankType)
        end
    end)

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(name)
        if bankType == BANK_TYPE_ACCOUNT then
            GameTooltip:AddLine("Shared storage across all characters", 0.8, 0.8, 0.8, true)
        else
            GameTooltip:AddLine("Personal character bank", 0.8, 0.8, 0.8, true)
        end
        GameTooltip:Show()
    end)

    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    return button
end

local function UpdateButtonAppearance(button, isActive)
    if isActive then
        button:SetBackdropColor(0.2, 0.4, 0.6, 0.9)
        button:SetBackdropBorderColor(0.4, 0.6, 0.8, 1)
        button.text:SetTextColor(1, 1, 1)
    else
        button:SetBackdropColor(0.1, 0.1, 0.1, 0.7)
        button:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.7)
        button.text:SetTextColor(0.7, 0.7, 0.7)
    end
end

function RetailBankTabs:Init(parent)
    LoadComponents()

    frame = CreateFrame("Frame", "GudaBankTypeTabs", parent)
    frame:SetHeight(28)
    frame:SetPoint("TOPLEFT", parent, "TOPLEFT", Constants.FRAME.PADDING, -Constants.FRAME.TITLE_HEIGHT - 2)
    frame:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -Constants.FRAME.PADDING, -Constants.FRAME.TITLE_HEIGHT - 2)

    -- Create bank type buttons
    local bankTypes = RetailBankScanner:GetAvailableBankTypes()
    local xOffset = 0

    for i, bankTypeInfo in ipairs(bankTypes) do
        local button = CreateBankTypeButton(frame, bankTypeInfo.type, bankTypeInfo.name, bankTypeInfo.icon, i)
        button:SetPoint("LEFT", frame, "LEFT", xOffset, 0)
        table.insert(bankTypeButtons, button)
        xOffset = xOffset + button:GetWidth() + 4
    end

    -- Set initial state
    self:SetActiveBankType(BANK_TYPE_CHARACTER)

    return frame
end

function RetailBankTabs:SetActiveBankType(bankType)
    if not RetailBankScanner then
        LoadComponents()
    end

    RetailBankScanner:SetCurrentBankType(bankType)

    -- Update button appearances
    for _, button in ipairs(bankTypeButtons) do
        UpdateButtonAppearance(button, button.bankType == bankType)
    end
end

function RetailBankTabs:GetActiveBankType()
    if not RetailBankScanner then
        LoadComponents()
    end
    return RetailBankScanner:GetCurrentBankType()
end

function RetailBankTabs:SetOnBankTypeChanged(callback)
    onBankTypeChanged = callback
end

function RetailBankTabs:Show()
    if frame then
        frame:Show()
    end
end

function RetailBankTabs:Hide()
    if frame then
        frame:Hide()
    end
end

function RetailBankTabs:IsVisible()
    return frame and frame:IsShown()
end

function RetailBankTabs:GetHeight()
    return frame and frame:GetHeight() or 0
end

function RetailBankTabs:GetFrame()
    return frame
end

-- Refresh available bank types (call when bank opens)
function RetailBankTabs:Refresh()
    if not frame or not RetailBankScanner then return end

    -- Clear existing buttons
    for _, button in ipairs(bankTypeButtons) do
        button:Hide()
        button:SetParent(nil)
    end
    wipe(bankTypeButtons)

    -- Recreate buttons based on available types
    local bankTypes = RetailBankScanner:GetAvailableBankTypes()
    local xOffset = 0

    for i, bankTypeInfo in ipairs(bankTypes) do
        local button = CreateBankTypeButton(frame, bankTypeInfo.type, bankTypeInfo.name, bankTypeInfo.icon, i)
        button:SetPoint("LEFT", frame, "LEFT", xOffset, 0)
        table.insert(bankTypeButtons, button)
        xOffset = xOffset + button:GetWidth() + 4
    end

    -- Update active state
    self:SetActiveBankType(RetailBankScanner:GetCurrentBankType())
end
