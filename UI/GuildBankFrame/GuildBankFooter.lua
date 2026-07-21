local addonName, ns = ...

local GuildBankFooter = {}
ns:RegisterModule("GuildBankFrame.GuildBankFooter", GuildBankFooter)

local Constants = ns.Constants
local L = ns.L

local frame = nil
local mainGuildBankFrame = nil

local GuildBankScanner = nil
local Money = nil
local Database = nil

local function LoadComponents()
    GuildBankScanner = ns:GetModule("GuildBankScanner")
    Money = ns:GetModule("Footer.Money")
    Database = ns:GetModule("Database")
end

function GuildBankFooter:Init(parent)
    LoadComponents()

    -- Store reference to main GuildBankFrame
    mainGuildBankFrame = parent

    -- Extended footer with two rows
    local FOOTER_HEIGHT = 40  -- Two rows

    frame = CreateFrame("Frame", "GudaGuildBankFooter", parent)
    frame:SetHeight(FOOTER_HEIGHT)
    frame:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", Constants.FRAME.PADDING, Constants.FRAME.PADDING - 2)
    frame:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -Constants.FRAME.PADDING, Constants.FRAME.PADDING - 2)

    -- === TOP ROW ===

    -- Deposit button (left side)
    local depositBtn = CreateFrame("Button", "GudaGuildBankDepositBtn", frame, "UIPanelButtonTemplate")
    depositBtn:SetSize(70, 22)
    depositBtn:SetPoint("LEFT", frame, "LEFT", 0, 8)
    depositBtn:SetText(L["DEPOSIT"] or "Deposit")
    depositBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(L["GUILD_BANK_DEPOSIT"] or "Deposit Money")
        if not GuildBankScanner or not GuildBankScanner:IsGuildBankOpen() then
            GameTooltip:AddLine(L["GUILD_BANK_OFFLINE"] or "Guild bank must be open", 1, 0.3, 0.3, true)
        end
        GameTooltip:Show()
    end)
    depositBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    depositBtn:SetScript("OnClick", function()
        if GuildBankScanner and GuildBankScanner:IsGuildBankOpen() then
            StaticPopup_Show("GUILDBANK_DEPOSIT")
        end
    end)
    frame.depositBtn = depositBtn

    -- Withdraw button (after deposit)
    local withdrawBtn = CreateFrame("Button", "GudaGuildBankWithdrawBtn", frame, "UIPanelButtonTemplate")
    withdrawBtn:SetSize(70, 22)
    withdrawBtn:SetPoint("LEFT", depositBtn, "RIGHT", 4, 0)
    withdrawBtn:SetText(L["WITHDRAW"] or "Withdraw")
    withdrawBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(L["GUILD_BANK_WITHDRAW"] or "Withdraw Money")
        if GuildBankScanner and GuildBankScanner:IsGuildBankOpen() then
            local withdrawLimit = GetGuildBankWithdrawMoney and GetGuildBankWithdrawMoney() or 0
            -- Some Classic builds return MIN_INT64 for "unlimited", which can wrap to a
            -- huge positive in Lua arithmetic and overflow %d formatting. Treat negative
            -- or absurdly-large values as unlimited.
            if withdrawLimit < 0 or withdrawLimit > 1e11 then
                GameTooltip:AddLine(L["GUILD_BANK_WITHDRAW_UNLIMITED"] or "Unlimited withdrawals", 1, 1, 1, true)
            elseif withdrawLimit > 0 then
                local gold = math.floor(withdrawLimit / 10000)
                GameTooltip:AddLine(string.format(L["GUILD_BANK_WITHDRAW_REMAINING"] or "Remaining today: %dg", gold), 1, 1, 1, true)
            else
                GameTooltip:AddLine(L["GUILD_BANK_WITHDRAW_NONE"] or "No withdrawal limit remaining", 1, 0.3, 0.3, true)
            end
        else
            GameTooltip:AddLine(L["GUILD_BANK_OFFLINE"] or "Guild bank must be open", 1, 0.3, 0.3, true)
        end
        GameTooltip:Show()
    end)
    withdrawBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    withdrawBtn:SetScript("OnClick", function()
        if GuildBankScanner and GuildBankScanner:IsGuildBankOpen() then
            StaticPopup_Show("GUILDBANK_WITHDRAW")
        end
    end)
    frame.withdrawBtn = withdrawBtn

    -- Slot counter (after withdraw button)
    local slotInfoFrame = CreateFrame("Frame", nil, frame)
    slotInfoFrame:SetPoint("LEFT", withdrawBtn, "RIGHT", 8, 0)
    slotInfoFrame:SetSize(50, 16)
    local slotInfo = slotInfoFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    slotInfo:SetPoint("LEFT", slotInfoFrame, "LEFT", 0, 0)
    slotInfo:SetTextColor(0.8, 0.8, 0.8)
    slotInfo:SetShadowOffset(1, -1)
    slotInfo:SetShadowColor(0, 0, 0, 1)
    frame.slotInfo = slotInfo
    frame.slotInfoFrame = slotInfoFrame
    slotInfoFrame:SetScript("OnEnter", function(self)
        if frame.tabSlotData then
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine("Guild Bank", 1, 1, 1)
            GameTooltip:AddLine(" ")

            -- Show per-tab slot info
            for tabIndex, data in pairs(frame.tabSlotData) do
                local used = data.total - data.free
                local tabName = data.name or string.format("Tab %d", tabIndex)
                GameTooltip:AddDoubleLine(tabName .. ":", string.format("%d/%d", used, data.total), 0, 0.8, 0.4, 0.8, 0.8, 0.8)
            end

            GameTooltip:Show()
        end
    end)
    slotInfoFrame:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- Center buttons container (Log | Money Log | Info) - bottom row center
    local centerBtns = CreateFrame("Frame", nil, frame)
    centerBtns:SetSize(220, 22)
    centerBtns:SetPoint("CENTER", frame, "CENTER", 0, -13)
    centerBtns:Hide()  -- Hidden by default, shown when guild bank is open
    frame.centerBtns = centerBtns

    -- Log button
    local logBtn = CreateFrame("Button", "GudaGuildBankLogBtn", centerBtns)
    logBtn:SetSize(24, 18)
    logBtn:SetPoint("LEFT", centerBtns, "LEFT", 0, 0)
    local logText = logBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    logText:SetPoint("LEFT")
    logText:SetText("Log")
    logText:SetTextColor(1, 0.82, 0)  -- Gold
    logBtn.text = logText
    logBtn:SetScript("OnEnter", function(self)
        self.text:SetTextColor(1, 1, 0.6)  -- Brighter gold
    end)
    logBtn:SetScript("OnLeave", function(self)
        self.text:SetTextColor(1, 0.82, 0)  -- Gold
    end)
    logBtn:SetScript("OnClick", function()
        local scanner = ns:GetModule("GuildBankScanner")
        if scanner and scanner:IsGuildBankOpen() then
            GuildBankFooter:ShowLogPopup()
        end
    end)
    frame.logBtn = logBtn

    -- Separator 1
    local sep1 = centerBtns:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sep1:SetPoint("LEFT", logBtn, "RIGHT", 4, 0)
    sep1:SetText("|")
    sep1:SetTextColor(0.7, 0.6, 0)  -- Darker gold
    frame.sep1 = sep1

    -- Money Log button
    local moneyLogBtn = CreateFrame("Button", "GudaGuildBankMoneyLogBtn", centerBtns)
    moneyLogBtn:SetSize(70, 18)
    moneyLogBtn:SetPoint("LEFT", sep1, "RIGHT", 4, 0)
    moneyLogBtn:EnableMouse(true)
    moneyLogBtn:RegisterForClicks("AnyUp")
    local moneyLogText = moneyLogBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    moneyLogText:SetPoint("CENTER")
    moneyLogText:SetText("Money Log")
    moneyLogText:SetTextColor(1, 0.82, 0)  -- Gold
    moneyLogBtn.text = moneyLogText
    moneyLogBtn:SetScript("OnEnter", function(self)
        self.text:SetTextColor(1, 1, 0.6)  -- Brighter gold
    end)
    moneyLogBtn:SetScript("OnLeave", function(self)
        self.text:SetTextColor(1, 0.82, 0)  -- Gold
    end)
    moneyLogBtn:SetScript("OnClick", function(self, button)
        ns:Debug("Money Log button clicked!")
        local scanner = ns:GetModule("GuildBankScanner")
        ns:Debug("Scanner:", scanner and "found" or "nil", "IsOpen:", scanner and scanner:IsGuildBankOpen())
        if scanner and scanner:IsGuildBankOpen() then
            ns:Debug("Calling ShowMoneyLogPopup")
            GuildBankFooter:ShowMoneyLogPopup()
        end
    end)
    frame.moneyLogBtn = moneyLogBtn

    -- Separator 2
    local sep2 = centerBtns:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sep2:SetPoint("LEFT", moneyLogBtn, "RIGHT", 4, 0)
    sep2:SetText("|")
    sep2:SetTextColor(0.7, 0.6, 0)  -- Darker gold
    frame.sep2 = sep2

    -- Info button
    local infoBtn = CreateFrame("Button", "GudaGuildBankInfoBtn", centerBtns)
    infoBtn:SetSize(30, 18)
    infoBtn:SetPoint("LEFT", sep2, "RIGHT", 4, 0)
    local infoText = infoBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    infoText:SetPoint("CENTER")
    infoText:SetText("Info")
    infoText:SetTextColor(1, 0.82, 0)  -- Gold
    infoBtn.text = infoText
    infoBtn:SetScript("OnEnter", function(self)
        self.text:SetTextColor(1, 1, 0.6)  -- Brighter gold
    end)
    infoBtn:SetScript("OnLeave", function(self)
        self.text:SetTextColor(1, 0.82, 0)  -- Gold
    end)
    infoBtn:SetScript("OnClick", function()
        local scanner = ns:GetModule("GuildBankScanner")
        if scanner and scanner:IsGuildBankOpen() then
            GuildBankFooter:ShowInfoPopup()
        end
    end)
    frame.infoBtn = infoBtn

    -- Guild money display (guild bank balance) - top row right
    local moneyText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    moneyText:SetPoint("RIGHT", frame, "RIGHT", 0, 8)
    moneyText:SetTextColor(1, 0.82, 0)
    moneyText:SetShadowOffset(1, -1)
    moneyText:SetShadowColor(0, 0, 0, 1)
    frame.moneyText = moneyText

    -- === BOTTOM ROW (money info) ===

    -- Money withdrawal info display - bottom row left
    local moneyWithdrawInfo = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    moneyWithdrawInfo:SetPoint("LEFT", frame, "LEFT", 0, -13)
    moneyWithdrawInfo:SetTextColor(0.8, 0.8, 0.8)
    moneyWithdrawInfo:SetShadowOffset(1, -1)
    moneyWithdrawInfo:SetShadowColor(0, 0, 0, 1)
    moneyWithdrawInfo:Hide()  -- Hidden by default, shown when guild bank is open
    frame.moneyWithdrawInfo = moneyWithdrawInfo

    -- Items info (right side of bottom row)
    local itemWithdrawInfo = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    itemWithdrawInfo:SetPoint("RIGHT", frame, "RIGHT", 0, -13)
    itemWithdrawInfo:SetTextColor(0.8, 0.8, 0.8)
    itemWithdrawInfo:SetShadowOffset(1, -1)
    itemWithdrawInfo:SetShadowColor(0, 0, 0, 1)
    itemWithdrawInfo:Hide()  -- Hidden by default, shown when guild bank is open
    frame.itemWithdrawInfo = itemWithdrawInfo

    -- Responsive layout based on parent width
    local currentMode = "wide"

    local function UpdateLayout()
        if not frame or not mainGuildBankFrame then return end
        local width = mainGuildBankFrame:GetWidth()
        local newMode = width < 400 and "narrow" or "wide"
        if newMode == currentMode then return end
        currentMode = newMode

        if currentMode == "narrow" then
            -- 3-row layout
            frame:SetHeight(60)
            frame.currentHeight = 60

            -- Row 1 (top): Deposit, Withdraw, SlotInfo
            frame.depositBtn:ClearAllPoints()
            frame.depositBtn:SetPoint("LEFT", frame, "LEFT", 0, 18)

            -- Row 2: withdraw info
            frame.moneyWithdrawInfo:ClearAllPoints()
            frame.moneyWithdrawInfo:SetPoint("LEFT", frame, "LEFT", 0, 0)
            frame.itemWithdrawInfo:ClearAllPoints()
            frame.itemWithdrawInfo:SetPoint("RIGHT", frame, "RIGHT", 0, 0)

            -- Row 3: Log | Money Log | Info left, Money right
            frame.centerBtns:ClearAllPoints()
            frame.centerBtns:SetPoint("LEFT", frame, "LEFT", 0, -18)
            frame.moneyText:ClearAllPoints()
            frame.moneyText:SetPoint("RIGHT", frame, "RIGHT", 0, -18)
        else
            -- 2-row layout (default)
            frame:SetHeight(40)
            frame.currentHeight = 40

            -- Row 1: Deposit left, Money right
            frame.depositBtn:ClearAllPoints()
            frame.depositBtn:SetPoint("LEFT", frame, "LEFT", 0, 8)

            frame.moneyText:ClearAllPoints()
            frame.moneyText:SetPoint("RIGHT", frame, "RIGHT", 0, 8)

            -- Row 2: withdraw info + center buttons
            frame.moneyWithdrawInfo:ClearAllPoints()
            frame.moneyWithdrawInfo:SetPoint("LEFT", frame, "LEFT", 0, -13)
            frame.itemWithdrawInfo:ClearAllPoints()
            frame.itemWithdrawInfo:SetPoint("RIGHT", frame, "RIGHT", 0, -13)
            frame.centerBtns:ClearAllPoints()
            frame.centerBtns:SetPoint("CENTER", frame, "CENTER", 0, -13)
        end
    end

    frame.currentHeight = 40

    -- Hook parent resize to update layout
    mainGuildBankFrame:HookScript("OnSizeChanged", function(self, width)
        UpdateLayout()
    end)

    return frame
end

function GuildBankFooter:GetHeight()
    if frame and frame.currentHeight then
        return frame.currentHeight
    end
    return 40
end

function GuildBankFooter:Show()
    if not frame then return end
    frame:Show()
    self:Update()
end

function GuildBankFooter:Hide()
    if not frame then return end
    frame:Hide()
end

function GuildBankFooter:Update()
    if not frame then return end

    -- Update button states based on whether guild bank is open
    local isOpen = GuildBankScanner and GuildBankScanner:IsGuildBankOpen() or false
    self:UpdateButtonStates(isOpen)

    -- Update slot count
    if GuildBankScanner then
        local total, free = GuildBankScanner:GetTotalSlots()
        local used = total - free
        frame.slotInfo:SetText(string.format("%d/%d", used, total))

        -- Build per-tab data for tooltip
        frame.tabSlotData = {}
        local cachedBank = GuildBankScanner:GetCachedGuildBank()
        if cachedBank then
            for tabIndex, tabData in pairs(cachedBank) do
                frame.tabSlotData[tabIndex] = {
                    name = tabData.name,
                    total = tabData.numSlots or 0,
                    free = tabData.freeSlots or 0,
                }
            end
        end
    else
        frame.slotInfo:SetText("0/0")
    end

    -- Update guild money display
    self:UpdateMoney()

    -- Update withdrawal info
    self:UpdateWithdrawInfo()
end

function GuildBankFooter:UpdateButtonStates(isOpen)
    if not frame then return end

    if isOpen then
        -- Enable buttons
        if frame.withdrawBtn then
            frame.withdrawBtn:Enable()
        end
        if frame.depositBtn then
            frame.depositBtn:Enable()
        end
        -- Show second row (center buttons and info)
        if frame.centerBtns then
            frame.centerBtns:Show()
        end
        if frame.moneyWithdrawInfo then
            frame.moneyWithdrawInfo:Show()
        end
        if frame.itemWithdrawInfo then
            frame.itemWithdrawInfo:Show()
        end
    else
        -- Disable buttons (but keep them visible for offline viewing)
        if frame.withdrawBtn then
            frame.withdrawBtn:Disable()
        end
        if frame.depositBtn then
            frame.depositBtn:Disable()
        end
        -- Hide second row in offline/view mode
        if frame.centerBtns then
            frame.centerBtns:Hide()
        end
        if frame.moneyWithdrawInfo then
            frame.moneyWithdrawInfo:Hide()
        end
        if frame.itemWithdrawInfo then
            frame.itemWithdrawInfo:Hide()
        end
    end
end

-------------------------------------------------
-- Popup Window with Tabs
-------------------------------------------------

local guildBankPopup = nil
local currentPopupTab = "log"
local currentGuildTab = 1  -- Selected guild bank tab for Log/Info

local function CreateGuildBankPopup()
    local popup = CreateFrame("Frame", "GudaGuildBankPopup", UIParent, "BackdropTemplate")
    popup:SetSize(450, 380)
    popup:SetPoint("CENTER", UIParent, "CENTER", 0, 100)
    popup:SetMovable(true)
    popup:EnableMouse(true)
    popup:SetClampedToScreen(true)
    popup:SetFrameStrata("DIALOG")
    popup:SetFrameLevel(100)

    popup:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14,
        insets = {left = 3, right = 3, top = 3, bottom = 3},
    })
    popup:SetBackdropColor(0.08, 0.08, 0.08, 0.95)
    popup:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

    -- Title bar (leave room for close button on right)
    local titleBar = CreateFrame("Frame", nil, popup)
    titleBar:SetHeight(24)
    titleBar:SetPoint("TOPLEFT", popup, "TOPLEFT", 4, -4)
    titleBar:SetPoint("TOPRIGHT", popup, "TOPRIGHT", -28, -4)  -- Leave space for close button
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() popup:StartMoving() end)
    titleBar:SetScript("OnDragStop", function() popup:StopMovingOrSizing() end)

    local titleText = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleText:SetPoint("LEFT", titleBar, "LEFT", 4, 0)
    titleText:SetText("Guild Bank")
    titleText:SetTextColor(1, 0.82, 0)
    popup.titleText = titleText

    -- Close button (smaller, matching other close buttons in the addon)
    local closeBtn = CreateFrame("Button", nil, popup, "UIPanelCloseButton")
    closeBtn:SetSize(24, 24)
    closeBtn:SetPoint("TOPRIGHT", popup, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() popup:Hide() end)

    -- Internal footer for guild tab buttons (inside the popup)
    local internalFooter = CreateFrame("Frame", nil, popup)
    internalFooter:SetHeight(28)
    internalFooter:SetPoint("BOTTOMLEFT", popup, "BOTTOMLEFT", 8, 8)
    internalFooter:SetPoint("BOTTOMRIGHT", popup, "BOTTOMRIGHT", -8, 8)
    popup.internalFooter = internalFooter
    internalFooter:Hide()  -- Hidden by default, shown for Log/Info

    -- Scroll frame for content (leaves room for internal footer when visible)
    local scrollFrame = CreateFrame("ScrollFrame", "GudaGuildBankPopupScrollFrame", popup, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", popup, "TOPLEFT", 8, -32)
    scrollFrame:SetPoint("BOTTOMRIGHT", popup, "BOTTOMRIGHT", -28, 10)
    popup.scrollFrame = scrollFrame

    local content = CreateFrame("Frame", "GudaGuildBankPopupContent", scrollFrame)
    content:SetSize(410, 1)
    scrollFrame:SetScrollChild(content)
    popup.content = content
    popup.scrollFrame = scrollFrame

    -- Bottom tab bar (below the frame, like Bank | Warband tabs)
    local TAB_WIDTH = 90
    local TAB_HEIGHT = 26
    local TAB_SPACING = 2

    local tabBar = CreateFrame("Frame", nil, popup)
    tabBar:SetHeight(TAB_HEIGHT)
    tabBar:SetPoint("TOPLEFT", popup, "BOTTOMLEFT", 8, 0)
    tabBar:SetWidth(TAB_WIDTH * 3 + TAB_SPACING * 2)
    popup.tabBar = tabBar

    -- Tab buttons (same style as Bank | Warband bottom tabs)
    local function CreateTabButton(tabName, label)
        local btn = CreateFrame("Button", "GudaGuildBankPopupTab" .. tabName, tabBar, "BackdropTemplate")
        btn:SetSize(TAB_WIDTH, TAB_HEIGHT)
        btn:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 10,
            insets = {left = 2, right = 2, top = 2, bottom = 2},
        })
        btn:SetBackdropColor(0.08, 0.08, 0.08, 0.95)
        btn:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
        btn.tabName = tabName

        local text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        text:SetPoint("CENTER", 0, 0)
        text:SetText(label)
        text:SetTextColor(0.8, 0.8, 0.8)
        btn.text = text

        local highlight = btn:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetAllPoints()
        highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
        highlight:SetBlendMode("ADD")

        -- Selection indicator (gold, like Bank | Warband)
        local selected = btn:CreateTexture(nil, "BACKGROUND", nil, 1)
        selected:SetPoint("TOPLEFT", 2, -2)
        selected:SetPoint("BOTTOMRIGHT", -2, 2)
        selected:SetColorTexture(1, 0.82, 0, 0.15)
        selected:Hide()
        btn.selected = selected

        btn:SetScript("OnClick", function(self)
            currentPopupTab = self.tabName
            GuildBankFooter:UpdatePopupContent()
            GuildBankFooter:UpdatePopupTabs()
        end)

        return btn
    end

    -- Create tabs
    local logTab = CreateTabButton("log", "Log")
    local moneyLogTab = CreateTabButton("moneyLog", "Money Log")
    local infoTab = CreateTabButton("info", "Info")

    -- Position tabs side by side at bottom
    logTab:SetPoint("LEFT", tabBar, "LEFT", 0, 0)
    moneyLogTab:SetPoint("LEFT", logTab, "RIGHT", TAB_SPACING, 0)
    infoTab:SetPoint("LEFT", moneyLogTab, "RIGHT", TAB_SPACING, 0)

    popup.tabs = {
        log = logTab,
        moneyLog = moneyLogTab,
        info = infoTab,
    }

    -- Guild tab buttons (inside internal footer, shown for Log/Info)
    popup.guildTabButtons = {}
    local GUILD_TAB_SIZE = 26

    local function CreateGuildTabButton(index)
        local btn = CreateFrame("Button", nil, internalFooter, "BackdropTemplate")
        btn:SetSize(GUILD_TAB_SIZE, GUILD_TAB_SIZE)
        btn:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 8,
            insets = {left = 1, right = 1, top = 1, bottom = 1},
        })
        btn:SetBackdropColor(0.12, 0.12, 0.12, 0.95)
        btn:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
        btn.tabIndex = index

        local text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        text:SetPoint("CENTER")
        text:SetText(tostring(index))
        text:SetTextColor(0.7, 0.7, 0.7)
        btn.text = text

        btn:SetScript("OnClick", function(self)
            currentGuildTab = self.tabIndex
            GuildBankFooter:UpdateGuildTabSelection()
            GuildBankFooter:UpdatePopupContent()
        end)

        btn:SetScript("OnEnter", function(self)
            local scanner = ns:GetModule("GuildBankScanner")
            local tabInfo = scanner and scanner:GetTabInfo(self.tabIndex)
            if tabInfo and tabInfo.name then
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:SetText(tabInfo.name)
                GameTooltip:Show()
            end
        end)

        btn:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        return btn
    end

    -- Create up to 8 guild tab buttons
    for i = 1, 8 do
        local btn = CreateGuildTabButton(i)
        if i == 1 then
            btn:SetPoint("LEFT", internalFooter, "LEFT", 0, 0)
        else
            btn:SetPoint("LEFT", popup.guildTabButtons[i-1], "RIGHT", 2, 0)
        end
        popup.guildTabButtons[i] = btn
    end

    popup:Hide()
    tinsert(UISpecialFrames, "GudaGuildBankPopup")

    return popup
end

function GuildBankFooter:UpdatePopupTabs()
    ns:Debug("UpdatePopupTabs called")
    if not guildBankPopup then
        ns:Debug("UpdatePopupTabs: no popup")
        return
    end
    if not guildBankPopup.tabs then
        ns:Debug("UpdatePopupTabs: no tabs table")
        return
    end

    for name, btn in pairs(guildBankPopup.tabs) do
        ns:Debug("UpdatePopupTabs: processing tab", name)
        if name == currentPopupTab then
            btn.selected:Show()
            btn:SetBackdropColor(0.12, 0.12, 0.12, 0.95)  -- Slightly lighter background
            btn:SetBackdropBorderColor(1, 0.82, 0, 1)  -- Gold border
            btn.text:SetTextColor(1, 0.82, 0)  -- Gold text
        else
            btn.selected:Hide()
            btn:SetBackdropColor(0.08, 0.08, 0.08, 0.95)
            btn:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
            btn.text:SetTextColor(0.7, 0.7, 0.7)
        end
    end

    -- Show/hide guild tab bar based on current popup tab
    self:UpdateGuildTabBar()
    ns:Debug("UpdatePopupTabs done")
end

function GuildBankFooter:UpdateGuildTabBar()
    if not guildBankPopup or not guildBankPopup.guildTabButtons then return end

    -- Show guild tab buttons only for Log and Info tabs
    local showGuildTabs = (currentPopupTab == "log" or currentPopupTab == "info")

    -- Get available tabs from scanner
    local scanner = ns:GetModule("GuildBankScanner")
    local numTabs = 0
    if scanner then
        local cachedTabInfo = scanner:GetCachedTabInfo()
        if cachedTabInfo then
            for tabIndex, _ in pairs(cachedTabInfo) do
                if type(tabIndex) == "number" and tabIndex > numTabs then
                    numTabs = tabIndex
                end
            end
        end
    end

    -- Default to at least 1 tab if none found
    if numTabs == 0 then numTabs = 1 end

    -- Show/hide internal footer and adjust scroll frame
    if guildBankPopup.internalFooter and guildBankPopup.scrollFrame then
        if showGuildTabs and numTabs > 1 then
            guildBankPopup.internalFooter:Show()
            guildBankPopup.scrollFrame:SetPoint("BOTTOMRIGHT", guildBankPopup, "BOTTOMRIGHT", -28, 38)
        else
            guildBankPopup.internalFooter:Hide()
            guildBankPopup.scrollFrame:SetPoint("BOTTOMRIGHT", guildBankPopup, "BOTTOMRIGHT", -28, 10)
        end
    end

    -- Show/hide tab buttons
    for i, btn in ipairs(guildBankPopup.guildTabButtons) do
        if showGuildTabs and i <= numTabs then
            btn:Show()
        else
            btn:Hide()
        end
    end

    -- Update selection
    self:UpdateGuildTabSelection()
end

function GuildBankFooter:UpdateGuildTabSelection()
    if not guildBankPopup or not guildBankPopup.guildTabButtons then return end

    for i, btn in ipairs(guildBankPopup.guildTabButtons) do
        if i == currentGuildTab then
            btn:SetBackdropColor(0.15, 0.15, 0.15, 0.95)
            btn:SetBackdropBorderColor(1, 0.82, 0, 1)  -- Gold border
            btn.text:SetTextColor(1, 0.82, 0)  -- Gold text
        else
            btn:SetBackdropColor(0.1, 0.1, 0.1, 0.9)
            btn:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.8)
            btn.text:SetTextColor(0.7, 0.7, 0.7)
        end
    end
end

function GuildBankFooter:UpdatePopupContent()
    ns:Debug("UpdatePopupContent called, currentPopupTab:", currentPopupTab)
    if not guildBankPopup then
        ns:Debug("UpdatePopupContent: no popup")
        return
    end

    -- Clear content
    local content = guildBankPopup.content
    if not content then
        ns:Debug("UpdatePopupContent: no content frame")
        return
    end

    for _, region in pairs({content:GetRegions()}) do
        region:Hide()
    end
    for _, child in pairs({content:GetChildren()}) do
        child:Hide()
    end

    if currentPopupTab == "log" then
        ns:Debug("Populating log content")
        self:PopulateLogContent(content)
    elseif currentPopupTab == "moneyLog" then
        ns:Debug("Populating money log content")
        self:PopulateMoneyLogContent(content)
    elseif currentPopupTab == "info" then
        ns:Debug("Populating info content")
        self:PopulateInfoContent(content)
    end
    ns:Debug("UpdatePopupContent done")
end

-- Track if we're waiting for tab log data
local pendingTabLogRefresh = false

function GuildBankFooter:PopulateLogContent(content)
    local selectedTab = currentGuildTab or 1
    if selectedTab == 0 then selectedTab = 1 end

    QueryGuildBankLog(selectedTab)

    -- Schedule a refresh after data arrives (async query)
    if not pendingTabLogRefresh then
        pendingTabLogRefresh = true
        C_Timer.After(0.2, function()
            pendingTabLogRefresh = false
            if guildBankPopup and guildBankPopup:IsShown() and currentPopupTab == "log" then
                ns:Debug("Refreshing tab log after delay")
                GuildBankFooter:UpdatePopupContent()
            end
        end)
    end

    local scanner = ns:GetModule("GuildBankScanner")
    local tabInfo = scanner and scanner:GetTabInfo(selectedTab)
    local tabName = tabInfo and tabInfo.name or ("Tab " .. selectedTab)
    guildBankPopup.titleText:SetText("Guild Bank Log - " .. tabName)

    local numTransactions = GetNumGuildBankTransactions(selectedTab) or 0
    local yOffset = 0
    local entryHeight = 16

    if numTransactions == 0 then
        local noData = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        noData:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
        noData:SetText("No transactions found.")
        noData:SetTextColor(0.6, 0.6, 0.6)
        yOffset = -entryHeight
    else
        for i = numTransactions, 1, -1 do
            local transType, name, itemLink, count, tab1, tab2, year, month, day, hour = GetGuildBankTransaction(selectedTab, i)

            local entry = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            entry:SetPoint("TOPLEFT", content, "TOPLEFT", 0, yOffset)
            entry:SetWidth(400)
            entry:SetJustifyH("LEFT")

            -- Use Blizzard's RecentTimeDate for proper relative time formatting
            local timeStr
            if RecentTimeDate then
                timeStr = RecentTimeDate(year, month, day, hour)
            else
                timeStr = string.format("%02d/%02d %02d:00", month or 0, day or 0, hour or 0)
            end

            local actionStr = ""

            if transType == "deposit" then
                actionStr = string.format("|cff00ff00%s|r deposited %s", name or UNKNOWN or "Unknown", itemLink or "item")
                if count and count > 1 then actionStr = actionStr .. " x" .. count end
            elseif transType == "withdraw" then
                actionStr = string.format("|cffff0000%s|r withdrew %s", name or UNKNOWN or "Unknown", itemLink or "item")
                if count and count > 1 then actionStr = actionStr .. " x" .. count end
            elseif transType == "move" then
                actionStr = string.format("|cffffff00%s|r moved %s", name or UNKNOWN or "Unknown", itemLink or "item")
            else
                actionStr = string.format("%s: %s - %s", transType or "?", name or UNKNOWN or "Unknown", itemLink or "item")
            end

            entry:SetText(string.format("%s |cff888888%s|r", actionStr, timeStr))
            yOffset = yOffset - entryHeight
        end
    end

    content:SetHeight(math.abs(yOffset) + 10)
end

-- Track if we're waiting for log data
local pendingLogRefresh = false

function GuildBankFooter:PopulateMoneyLogContent(content)
    ns:Debug("PopulateMoneyLogContent called")
    -- Query money log using the correct API (tab index = MAX_GUILDBANK_TABS + 1 for money)
    local MAX_GUILDBANK_TABS = MAX_GUILDBANK_TABS or 8
    if QueryGuildBankLog then
        QueryGuildBankLog(MAX_GUILDBANK_TABS + 1)
        ns:Debug("Queried guild bank money log (tab", MAX_GUILDBANK_TABS + 1, ")")

        -- Schedule a refresh after data arrives (async query)
        if not pendingLogRefresh then
            pendingLogRefresh = true
            C_Timer.After(0.2, function()
                pendingLogRefresh = false
                if guildBankPopup and guildBankPopup:IsShown() and currentPopupTab == "moneyLog" then
                    ns:Debug("Refreshing money log after delay")
                    GuildBankFooter:UpdatePopupContent()
                end
            end)
        end
    end

    guildBankPopup.titleText:SetText("Guild Bank Money Log")

    local numTransactions = GetNumGuildBankMoneyTransactions and GetNumGuildBankMoneyTransactions() or 0
    ns:Debug("Number of money transactions:", numTransactions)
    local yOffset = 0
    local entryHeight = 16

    if numTransactions == 0 then
        local noData = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        noData:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
        noData:SetText("No money transactions found.")
        noData:SetTextColor(0.6, 0.6, 0.6)
        yOffset = -entryHeight
    else
        for i = numTransactions, 1, -1 do
            local transType, name, amount, year, month, day, hour = GetGuildBankMoneyTransaction(i)

            local entry = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            entry:SetPoint("TOPLEFT", content, "TOPLEFT", 0, yOffset)
            entry:SetWidth(400)
            entry:SetJustifyH("LEFT")

            -- Use Blizzard's RecentTimeDate for proper relative time formatting
            local timeStr
            if RecentTimeDate then
                timeStr = RecentTimeDate(year, month, day, hour)
            else
                -- Fallback formatting
                timeStr = string.format("%02d/%02d %02d:00", month or 0, day or 0, hour or 0)
            end

            -- Format money using GetDenominationsFromCopper if available, otherwise manual
            local moneyStr
            if GetDenominationsFromCopper then
                moneyStr = GetDenominationsFromCopper(amount or 0)
            else
                local gold = math.floor((amount or 0) / 10000)
                local silver = math.floor(((amount or 0) % 10000) / 100)
                local copper = (amount or 0) % 100
                moneyStr = ""
                if gold > 0 then moneyStr = gold .. "g " end
                if silver > 0 then moneyStr = moneyStr .. silver .. "s " end
                if copper > 0 or moneyStr == "" then moneyStr = moneyStr .. copper .. "c" end
            end

            local actionStr = ""
            if transType == "deposit" then
                actionStr = string.format("|cff00ff00%s|r deposited |cffffd700%s|r", name or UNKNOWN or "Unknown", moneyStr)
            elseif transType == "withdraw" then
                actionStr = string.format("|cffff0000%s|r withdrew |cffffd700%s|r", name or UNKNOWN or "Unknown", moneyStr)
            elseif transType == "repair" then
                actionStr = string.format("|cffffff00%s|r repaired for |cffffd700%s|r", name or UNKNOWN or "Unknown", moneyStr)
            elseif transType == "withdrawForTab" then
                actionStr = string.format("|cffff8800%s|r bought tab for |cffffd700%s|r", name or UNKNOWN or "Unknown", moneyStr)
            else
                actionStr = string.format("%s: %s - %s", transType or "?", name or UNKNOWN or "Unknown", moneyStr)
            end

            entry:SetText(string.format("%s |cff888888%s|r", actionStr, timeStr))
            yOffset = yOffset - entryHeight
        end
    end

    content:SetHeight(math.abs(yOffset) + 10)
end

function GuildBankFooter:PopulateInfoContent(content)
    local selectedTab = currentGuildTab or 1
    if selectedTab == 0 then selectedTab = 1 end

    QueryGuildBankText(selectedTab)

    local scanner = ns:GetModule("GuildBankScanner")
    local tabInfo = scanner and scanner:GetTabInfo(selectedTab)
    local tabName = tabInfo and tabInfo.name or ("Tab " .. selectedTab)
    guildBankPopup.titleText:SetText("Guild Bank Info - " .. tabName)

    local yOffset = 0
    local lineHeight = 18

    if tabInfo then
        local infoLine = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        infoLine:SetPoint("TOPLEFT", content, "TOPLEFT", 0, yOffset)
        infoLine:SetText("|cffffd700Tab Name:|r " .. (tabInfo.name or "Unknown"))
        yOffset = yOffset - lineHeight

        if tabInfo.canDeposit ~= nil then
            local depositLine = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            depositLine:SetPoint("TOPLEFT", content, "TOPLEFT", 0, yOffset)
            depositLine:SetText("Can Deposit: " .. (tabInfo.canDeposit and "|cff00ff00Yes|r" or "|cffff0000No|r"))
            yOffset = yOffset - lineHeight
        end

        if tabInfo.numWithdrawals then
            local withdrawLine = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            withdrawLine:SetPoint("TOPLEFT", content, "TOPLEFT", 0, yOffset)
            local remaining = tabInfo.remainingWithdrawals or 0
            local total = tabInfo.numWithdrawals or 0
            if total == -1 then
                withdrawLine:SetText("Withdrawals: |cff00ff00Unlimited|r")
            else
                withdrawLine:SetText(string.format("Withdrawals: %d remaining of %d", remaining, total))
            end
            yOffset = yOffset - lineHeight
        end
    end

    yOffset = yOffset - 10

    local tabText = GetGuildBankText(selectedTab)
    if tabText and tabText ~= "" then
        local descLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        descLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 0, yOffset)
        descLabel:SetText("|cffffd700Tab Description:|r")
        yOffset = yOffset - lineHeight

        local descText = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        descText:SetPoint("TOPLEFT", content, "TOPLEFT", 0, yOffset)
        descText:SetWidth(400)
        descText:SetJustifyH("LEFT")
        descText:SetText(tabText)
        descText:SetTextColor(0.9, 0.9, 0.9)
        yOffset = yOffset - (descText:GetStringHeight() + 10)
    else
        local noDesc = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        noDesc:SetPoint("TOPLEFT", content, "TOPLEFT", 0, yOffset)
        noDesc:SetText("No description set for this tab.")
        noDesc:SetTextColor(0.6, 0.6, 0.6)
        yOffset = yOffset - lineHeight
    end

    content:SetHeight(math.abs(yOffset) + 10)
end

function GuildBankFooter:ShowLogPopup()
    if not guildBankPopup then
        guildBankPopup = CreateGuildBankPopup()
    end
    -- Initialize guild tab from scanner if not set
    local scanner = ns:GetModule("GuildBankScanner")
    local selectedTab = scanner and scanner:GetSelectedTab() or 1
    if selectedTab > 0 then
        currentGuildTab = selectedTab
    end
    currentPopupTab = "log"
    self:UpdatePopupTabs()
    self:UpdatePopupContent()
    guildBankPopup:Show()
end

function GuildBankFooter:ShowMoneyLogPopup()
    ns:Debug("ShowMoneyLogPopup called")
    if not guildBankPopup then
        ns:Debug("Creating popup")
        local success, result = pcall(CreateGuildBankPopup)
        if success then
            guildBankPopup = result
            ns:Debug("Popup created:", guildBankPopup and "success" or "nil")
        else
            ns:Debug("ERROR creating popup:", result)
            return
        end
    end
    if not guildBankPopup then
        ns:Debug("ERROR: guildBankPopup is nil after creation!")
        return
    end
    currentPopupTab = "moneyLog"
    ns:Debug("currentPopupTab set to:", currentPopupTab)
    ns:Debug("Calling UpdatePopupTabs")
    local ok1, err1 = pcall(function() self:UpdatePopupTabs() end)
    if not ok1 then ns:Debug("ERROR in UpdatePopupTabs:", err1) return end
    ns:Debug("Calling UpdatePopupContent")
    local ok2, err2 = pcall(function() self:UpdatePopupContent() end)
    if not ok2 then ns:Debug("ERROR in UpdatePopupContent:", err2) return end
    ns:Debug("Calling Show on popup")
    guildBankPopup:Show()
    ns:Debug("Popup shown, IsShown:", guildBankPopup:IsShown())
end

function GuildBankFooter:ShowInfoPopup()
    if not guildBankPopup then
        guildBankPopup = CreateGuildBankPopup()
    end
    -- Initialize guild tab from scanner if not set
    local scanner = ns:GetModule("GuildBankScanner")
    local selectedTab = scanner and scanner:GetSelectedTab() or 1
    if selectedTab > 0 then
        currentGuildTab = selectedTab
    end
    currentPopupTab = "info"
    self:UpdatePopupTabs()
    self:UpdatePopupContent()
    guildBankPopup:Show()
end

function GuildBankFooter:UpdateMoney()
    if not frame or not frame.moneyText then return end

    -- Get guild bank money (if available)
    local guildMoney = GetGuildBankMoney and GetGuildBankMoney() or 0

    if guildMoney > 0 then
        local gold = math.floor(guildMoney / 10000)
        local silver = math.floor((guildMoney % 10000) / 100)
        local copper = guildMoney % 100

        local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:12|t"
        local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:12|t"
        local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:12|t"

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

        frame.moneyText:SetText(result)
    else
        frame.moneyText:SetText("")
    end
end

function GuildBankFooter:UpdateWithdrawInfo()
    if not frame then return end

    local scanner = ns:GetModule("GuildBankScanner")
    local isOpen = scanner and scanner:IsGuildBankOpen() or false

    -- Update item withdrawal info
    if frame.itemWithdrawInfo then
        if isOpen then
            local selectedTab = scanner and scanner:GetSelectedTab() or 1
            if selectedTab == 0 then selectedTab = 1 end

            -- GetGuildBankTabInfo returns: name, icon, isViewable, canDeposit, numWithdrawals, remainingWithdrawals
            local _, _, _, canDeposit, numWithdrawals, remainingWithdrawals = GetGuildBankTabInfo(selectedTab)

            local withdrawText
            if remainingWithdrawals == -1 then
                withdrawText = "|cff00ff00Unlimited|r"  -- Green
            elseif remainingWithdrawals == 0 then
                withdrawText = "|cffff0000None|r"  -- Red
            else
                withdrawText = "|cffffffff" .. (remainingWithdrawals or 0) .. "|r"
            end

            local depositText = canDeposit and "|cff00ff00Yes|r" or "|cffff0000No|r"

            frame.itemWithdrawInfo:SetText("Items: " .. withdrawText .. " | Deposit: " .. depositText)
            frame.itemWithdrawInfo:Show()
        else
            frame.itemWithdrawInfo:SetText("")
            frame.itemWithdrawInfo:Hide()
        end
    end

    -- Update money withdrawal info
    if frame.moneyWithdrawInfo then
        if isOpen then
            local guildMoney = GetGuildBankMoney and GetGuildBankMoney() or 0
            local withdrawLimit = GetGuildBankWithdrawMoney and GetGuildBankWithdrawMoney() or 0

            -- Check if player can actually withdraw money
            local canWithdraw = CanWithdrawGuildBankMoney and CanWithdrawGuildBankMoney() or false

            -- Negative or absurdly-large values mean unlimited withdrawal rights
            -- (some Classic builds return MIN_INT64 which wraps to a huge positive in arithmetic)
            if withdrawLimit < 0 or withdrawLimit > 1e11 then
                -- Unlimited rights - total bank balance is already shown in the top-right
                frame.moneyWithdrawInfo:SetText("Available: |cff00ff00Unlimited|r")
            else
                -- Has a positive limit - cap at actual guild money
                local withdrawMoney = math.min(withdrawLimit, guildMoney)

                if not canWithdraw or withdrawMoney == 0 then
                    -- Cannot withdraw - either no permission or limit reached
                    local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:12|t"
                    frame.moneyWithdrawInfo:SetText("Available: |cffff00000|r " .. COPPER_ICON)
                else
                    -- Has a limit and can withdraw
                    local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:12|t"
                    local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:12|t"
                    local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:12|t"

                    local gold = math.floor(withdrawMoney / 10000)
                    local silver = math.floor((withdrawMoney % 10000) / 100)
                    local copper = withdrawMoney % 100

                    local moneyStr = ""
                    if gold > 0 then
                        moneyStr = gold .. GOLD_ICON
                    end
                    if silver > 0 then
                        if moneyStr ~= "" then moneyStr = moneyStr .. " " end
                        moneyStr = moneyStr .. silver .. SILVER_ICON
                    end
                    if copper > 0 or moneyStr == "" then
                        if moneyStr ~= "" then moneyStr = moneyStr .. " " end
                        moneyStr = moneyStr .. copper .. COPPER_ICON
                    end

                    frame.moneyWithdrawInfo:SetText("Available: " .. moneyStr)
                end
            end
            frame.moneyWithdrawInfo:Show()
        else
            frame.moneyWithdrawInfo:SetText("")
            frame.moneyWithdrawInfo:Hide()
        end
    end
end

function GuildBankFooter:UpdateSlotInfo(used, total)
    if not frame or not frame.slotInfo then return end
    frame.slotInfo:SetText(string.format("%d/%d", used, total))
end

function GuildBankFooter:GetFrame()
    return frame
end
