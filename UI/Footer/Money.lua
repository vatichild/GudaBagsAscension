local addonName, ns = ...

local Money = {}
ns:RegisterModule("Footer.Money", Money)

local L = ns.L
local Utils = ns:GetModule("Utils")
local Database = ns:GetModule("Database")
local Font = ns:GetModule("Font")

local moneyFrame = nil

local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:10|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:10|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:10|t"

local function FormatGoldWithCommas(n)
    local formatted = tostring(n)
    while true do
        local k
        formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", "%1,%2")
        if k == 0 then break end
    end
    return formatted
end

local function FormatMoney(amount)
    local gold = math.floor(amount / 10000)
    local silver = math.floor((amount % 10000) / 100)
    local copper = amount % 100

    local result = ""
    if gold > 0 then
        result = string.format("%s %s ", FormatGoldWithCommas(gold), GOLD_ICON)
    end
    if silver > 0 or gold > 0 then
        result = result .. string.format("%d %s ", silver, SILVER_ICON)
    end
    result = result .. string.format("%d %s", copper, COPPER_ICON)
    return result
end

-- NOTE: The gold tooltip used to shrink GameTooltip's lines to size 11 via a
-- raw SetFont on the shared GameTooltipTextLeft/Right font strings, restored on
-- leave. Mutating those shared (Blizzard-owned) font objects from insecure code
-- is a taint vector, so it was removed — the tooltip now renders at the default
-- size. (See docs/RULES.md and the MoneyFrame "secret number value" taint fix.)

-- Filter out gold-blacklisted characters from a character list
local function FilterBlacklisted(chars)
    local blacklist = GudaBags_DB and GudaBags_DB.goldBlacklist
    if not blacklist then return chars end
    local filtered = {}
    for _, char in ipairs(chars) do
        if not blacklist[char.fullName] then
            table.insert(filtered, char)
        end
    end
    return filtered
end

local function AddCharacterLine(char)
    local classColor = RAID_CLASS_COLORS[char.class]
    local colorR, colorG, colorB = 0.7, 0.7, 0.7
    if classColor then
        colorR, colorG, colorB = classColor.r, classColor.g, classColor.b
    end
    local raceIcon = Utils:GetRaceIcon(char.race, char.sex)
    local name = raceIcon .. " " .. char.name
    GameTooltip:AddDoubleLine(name, FormatMoney(char.money), colorR, colorG, colorB, 1, 1, 1)
end

local function ShowMoneyTooltip(frame)
    if not frame then return end

    GameTooltip:SetOwner(frame, "ANCHOR_TOPRIGHT", 0, frame:GetHeight() + 4)
    GameTooltip:ClearLines()

    local allRealms = Database:GetSetting("goldTrackAllRealms")

    -- Get warband gold (Retail only)
    local warbandMoney = 0
    if ns.IsRetail and C_Bank and C_Bank.FetchDepositedMoney then
        warbandMoney = Money:GetWarbandMoney() or 0
    end

    if allRealms then
        -- Cross-realm view: group by realm with subtotals
        local chars = FilterBlacklisted(Database:GetAllCharacters(false, false))
        local totalMoney = 0
        for _, c in ipairs(chars) do totalMoney = totalMoney + c.money end

        GameTooltip:AddDoubleLine(L["TOOLTIP_ACCOUNT_GOLD"], FormatMoney(totalMoney + warbandMoney), 1, 0.82, 0, 1, 1, 1)
        GameTooltip:AddLine(" ")

        -- Group characters by realm
        local realms = {}
        local realmOrder = {}
        for _, char in ipairs(chars) do
            local realm = char.realm
            if not realms[realm] then
                realms[realm] = { chars = {}, total = 0 }
                table.insert(realmOrder, realm)
            end
            table.insert(realms[realm].chars, char)
            realms[realm].total = realms[realm].total + char.money
        end
        table.sort(realmOrder)

        for i, realm in ipairs(realmOrder) do
            local realmData = realms[realm]
            if i > 1 then GameTooltip:AddLine(" ") end
            GameTooltip:AddDoubleLine(realm, FormatMoney(realmData.total), 0.6, 0.6, 0.6, 1, 1, 1)
            for _, char in ipairs(realmData.chars) do
                AddCharacterLine(char)
            end
        end
    else
        -- Same-realm view (original behavior)
        local chars = FilterBlacklisted(Database:GetAllCharacters(false, true))
        local totalMoney = 0
        for _, c in ipairs(chars) do totalMoney = totalMoney + c.money end

        GameTooltip:AddDoubleLine(L["TOOLTIP_REALM_GOLD"], FormatMoney(totalMoney + warbandMoney), 1, 0.82, 0, 1, 1, 1)
        GameTooltip:AddLine(" ")

        for _, char in ipairs(chars) do
            AddCharacterLine(char)
        end
    end

    -- Warband gold line (Retail only)
    if warbandMoney > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddDoubleLine(L["TOOLTIP_WARBAND_GOLD"] or "Warband gold:", FormatMoney(warbandMoney), 0, 0.8, 0.8, 1, 1, 1)
    end

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(L["TOOLTIP_RIGHT_CLICK_GOLD"], 0.5, 0.5, 0.5)

    GameTooltip:Show()
end

-- Right-click dropdown menu for gold options
local goldDropdown = CreateFrame("Frame", "GudaBagsGoldDropdown", UIParent, "UIDropDownMenuTemplate")

-- Click-away overlay to close dropdown when clicking outside
local clickAwayOverlay = CreateFrame("Button", nil, UIParent)
clickAwayOverlay:SetAllPoints(UIParent)
clickAwayOverlay:SetFrameStrata("DIALOG")
clickAwayOverlay:EnableMouse(true)
clickAwayOverlay:RegisterForClicks("AnyUp")
clickAwayOverlay:Hide()
clickAwayOverlay:SetScript("OnClick", function()
    CloseDropDownMenus()
    clickAwayOverlay:Hide()
end)

goldDropdown:HookScript("OnHide", function()
    clickAwayOverlay:Hide()
end)

local function CloseGoldMenu()
    if UIDROPDOWNMENU_OPEN_MENU == goldDropdown then
        CloseDropDownMenus()
    end
end

-- Reposition level 2 submenu to open to the left of level 1, clamped to screen
local function RepositionSubmenu()
    local list2 = _G["DropDownList2"]
    local list1 = _G["DropDownList1"]
    if list2 and list1 and list2:IsShown() then
        list2:ClearAllPoints()
        list2:SetPoint("TOPRIGHT", list1, "TOPLEFT", 0, 0)

        -- Clamp to screen bottom
        local screenHeight = UIParent:GetHeight()
        local bottom = list2:GetBottom()
        if bottom and bottom < 0 then
            list2:ClearAllPoints()
            list2:SetPoint("BOTTOMRIGHT", list1, "BOTTOMLEFT", 0, 0)
        end
    end
end

local function ShowGoldMenu(frame)
    UIDropDownMenu_Initialize(goldDropdown, function(self, level)
        level = level or 1
        if level == 1 then
            -- Toggle: Track all realms
            local info = UIDropDownMenu_CreateInfo()
            info.text = L["GOLD_TRACK_ALL_REALMS"]
            info.isNotRadio = true
            info.keepShownOnClick = true
            info.checked = Database:GetSetting("goldTrackAllRealms")
            info.func = function()
                Database:SetSetting("goldTrackAllRealms", not Database:GetSetting("goldTrackAllRealms"))
                ShowMoneyTooltip(frame)
            end
            UIDropDownMenu_AddButton(info, level)

            -- Submenu: Exclude characters
            info = UIDropDownMenu_CreateInfo()
            info.text = L["GOLD_EXCLUDE_CHARACTER"]
            info.hasArrow = true
            info.notCheckable = true
            info.value = "blacklist"
            UIDropDownMenu_AddButton(info, level)
        elseif level == 2 then
            -- Character blacklist submenu (show all characters, including blacklisted)
            local allChars = Database:GetAllCharacters(false, false)
            for _, char in ipairs(allChars) do
                local info = UIDropDownMenu_CreateInfo()
                local classColor = RAID_CLASS_COLORS[char.class]
                local label = char.name .. " - " .. char.realm
                if classColor and classColor.WrapTextInColorCode then
                    info.text = classColor:WrapTextInColorCode(label)
                elseif classColor and classColor.colorStr then
                    -- Pre-Legion RAID_CLASS_COLORS entries are plain tables with
                    -- a colorStr field and no ColorMixin methods.
                    info.text = "|c" .. classColor.colorStr .. label .. "|r"
                else
                    info.text = label
                end
                info.isNotRadio = true
                info.keepShownOnClick = true
                info.checked = not Database:IsGoldBlacklisted(char.fullName)
                info.func = function()
                    Database:ToggleGoldBlacklist(char.fullName)
                    ShowMoneyTooltip(frame)
                end
                UIDropDownMenu_AddButton(info, level)
            end
            -- Reposition submenu to the left after WoW finishes layout
            C_Timer.After(0, RepositionSubmenu)
        end
    end, "MENU")
    ToggleDropDownMenu(1, nil, goldDropdown, frame, 0, frame:GetHeight())
    clickAwayOverlay:Show()
    clickAwayOverlay:SetFrameLevel(goldDropdown:GetFrameLevel() - 1)
end

local moneyFrameCount = 0
local ICON_SIZE = 11
local FONT_SIZE = 14

function Money:Init(parent)
    moneyFrameCount = moneyFrameCount + 1
    local frameName = "GudaBagsMoneyFrame" .. moneyFrameCount

    moneyFrame = CreateFrame("Frame", frameName, parent, "SmallMoneyFrameTemplate")
    moneyFrame:SetPoint("RIGHT", parent, "RIGHT", 14, 0)
    moneyFrame.frameName = frameName
    moneyFrame:EnableMouse(true)

    moneyFrame:SetScript("OnEnter", function(self)
        ShowMoneyTooltip(self)
    end)

    moneyFrame:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    moneyFrame:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" then
            ShowGoldMenu(self)
        end
    end)

    -- Set absolute sizes for money frame icons and font
    local coinButtons = {"GoldButton", "SilverButton", "CopperButton"}
    for _, buttonName in ipairs(coinButtons) do
        local coinButton = _G[frameName .. buttonName]
        if coinButton then
            coinButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            coinButton:SetScript("OnEnter", function(self)
                ShowMoneyTooltip(self:GetParent())
            end)
            coinButton:SetScript("OnLeave", function()
                GameTooltip:Hide()
            end)
            coinButton:SetScript("OnClick", function(self, button)
                if button == "RightButton" then
                    ShowGoldMenu(self:GetParent())
                end
            end)

            -- Set absolute icon size
            local icon = _G[frameName .. buttonName .. "Texture"]
            if icon then
                icon:SetSize(ICON_SIZE, ICON_SIZE)
            end

            -- Set absolute font size
            local text = coinButton:GetFontString()
            if text then
                local _, _, fontFlags = text:GetFont()
                Font:Apply(text, FONT_SIZE, fontFlags)
            end
        end
    end

    return moneyFrame
end

function Money:Show()
    if moneyFrame then
        moneyFrame:Show()
    end
end

function Money:Hide()
    CloseGoldMenu()
    if moneyFrame then
        moneyFrame:Hide()
    end
end

function Money:Update()
    if not moneyFrame then return end
    local money = GetMoney()
    MoneyFrame_Update(moneyFrame.frameName, money)
end

function Money:SetFontSize(size)
    if not moneyFrame then return end
    local coinButtons = {"GoldButton", "SilverButton", "CopperButton"}
    for _, buttonName in ipairs(coinButtons) do
        local coinButton = _G[moneyFrame.frameName .. buttonName]
        if coinButton then
            local text = coinButton:GetFontString()
            if text then
                local _, _, fontFlags = text:GetFont()
                Font:Apply(text, size, fontFlags)
            end
        end
    end
end

function Money:GetFrame()
    return moneyFrame
end

function Money:UpdateCached(characterFullName)
    if not moneyFrame then return end
    local money = Database:GetMoney(characterFullName)
    MoneyFrame_Update(moneyFrame.frameName, money)
end

-- Update with Warband bank money (Retail only)
function Money:UpdateWarband()
    if not moneyFrame then return end
    local money = 0
    -- Try different APIs to get Warband bank money
    if C_Bank then
        -- Try FetchDepositedMoney first
        if C_Bank.FetchDepositedMoney then
            money = C_Bank.FetchDepositedMoney(Enum.BankType.Account) or 0
            ns:Debug("Warband money via FetchDepositedMoney:", money)
        end
        -- Try GetBankMoney if available
        if money == 0 and C_Bank.GetBankMoney then
            money = C_Bank.GetBankMoney(Enum.BankType.Account) or 0
            ns:Debug("Warband money via GetBankMoney:", money)
        end
    end
    -- Try AccountBankPanel if available (Blizzard's UI)
    if money == 0 and AccountBankPanel then
        if AccountBankPanel.GetMoney then
            money = AccountBankPanel:GetMoney() or 0
            ns:Debug("Warband money via AccountBankPanel:GetMoney:", money)
        elseif AccountBankPanel.money then
            money = AccountBankPanel.money or 0
            ns:Debug("Warband money via AccountBankPanel.money:", money)
        end
    end
    -- Try C_CurrencyInfo for warbound gold
    if money == 0 and C_CurrencyInfo and C_CurrencyInfo.GetWarModeRewardBonus then
        -- This is a fallback - may not be the right API
    end
    ns:Debug("UpdateWarband called, final money:", money, "frameName:", moneyFrame.frameName)
    MoneyFrame_Update(moneyFrame.frameName, money)
    ns:Debug("MoneyFrame_Update called for Warband")
end

-- Get current Warband bank money amount
function Money:GetWarbandMoney()
    if C_Bank then
        if C_Bank.FetchDepositedMoney then
            local money = C_Bank.FetchDepositedMoney(Enum.BankType.Account)
            if money and money > 0 then return money end
        end
        if C_Bank.GetBankMoney then
            local money = C_Bank.GetBankMoney(Enum.BankType.Account)
            if money and money > 0 then return money end
        end
    end
    return 0
end
