local addonName, ns = ...

-- Guild Bank is available in TBC and later (check feature flag)
if not ns.Constants or not ns.Constants.FEATURES or not ns.Constants.FEATURES.GUILD_BANK then
    return
end

local GuildBankFrame = {}
ns:RegisterModule("GuildBankFrame", GuildBankFrame)

local Constants = ns.Constants
local L = ns.L
local Database = ns:GetModule("Database")
local Events = ns:GetModule("Events")
local Font = ns:GetModule("Font")
local ItemButton = ns:GetModule("ItemButton")
local SearchBar = ns:GetModule("SearchBar")
local LayoutEngine = ns:GetModule("BagFrame.LayoutEngine")
local Utils = ns:GetModule("Utils")
local CategoryHeaderPool = ns:GetModule("CategoryHeaderPool")
local Theme = ns:GetModule("Theme")

local GuildBankHeader = nil
local GuildBankFooter = nil
local GuildBankScanner = nil

local frame
local searchBar
local itemButtons = {}
local categoryHeaders = {}

-- Layout caching
local buttonsBySlot = {}
local cachedItemData = {}
local cachedItemCount = {}
local layoutCached = false

-- Persist-across-close: keep the ~588 buttons when the guild bank closes (walk away)
-- instead of releasing them, so closing is instant and reopening reuses them (the
-- Refresh already reuses buttons in place, so reopen just re-fills them — no teardown
-- or re-acquire). Released when another pool consumer (bags/bank/mail) opens or on
-- combat start, since they share the ItemButton pool.
local guildBankHeld = false

-- View signature (selectedTab:numTabs) of the last completed render. On reopen, if the
-- retained layout still matches this signature we skip the full Refresh and just
-- reconcile changed slots (IncrementalUpdate) — the same fast-reopen the bank uses.
-- numTabs guards against a tab being purchased while away (which IncrementalUpdate,
-- working slot-by-slot on the existing layout, can't add).
local guildBankLastRenderSig = nil
local function ComputeGuildBankRenderSig()
    local selectedTab = (GuildBankScanner and GuildBankScanner:GetSelectedTab()) or 0
    local numTabs = (GuildBankScanner and GuildBankScanner:GetNumTabs()) or 0
    return tostring(selectedTab) .. ":" .. tostring(numTabs)
end

-- Progressive ("All Tabs" can be ~588 buttons) rendering. Refresh places the
-- first chunk synchronously for an instant paint, then this driver places the
-- rest across frames under a per-frame time budget so no single frame stutters.
local RENDER_BUDGET_MS = 8       -- per-frame budget for placing buttons
local renderState                -- nil when idle; table while a render runs
local renderDriver = CreateFrame("Frame")  -- one-time, drives chunked render
renderDriver:Hide()
-- Forward declaration: the frame's OnHide handler (defined earlier in the file)
-- calls CancelRender, which is assigned below.
local CancelRender


-- Hidden frame to reparent Blizzard guild bank UI (used by some versions)
local hiddenParent = CreateFrame("Frame")
hiddenParent:Hide()

local function LoadComponents()
    GuildBankHeader = ns:GetModule("GuildBankFrame.GuildBankHeader")
    GuildBankFooter = ns:GetModule("GuildBankFrame.GuildBankFooter")
    GuildBankScanner = ns:GetModule("GuildBankScanner")
end

-------------------------------------------------
-- Category Header Pool
-------------------------------------------------

local function AcquireCategoryHeader(parent)
    return CategoryHeaderPool:Acquire(parent)
end

local function ReleaseAllCategoryHeaders()
    if frame and frame.container then
        CategoryHeaderPool:ReleaseAll(frame.container)
    end
    categoryHeaders = {}
end

-------------------------------------------------
-- Frame Position
-------------------------------------------------

local function SaveFramePosition()
    if not frame then return end

    local point, _, relativePoint, x, y = frame:GetPoint()
    Database:SetSetting("guildBankFramePoint", point)
    Database:SetSetting("guildBankFrameRelativePoint", relativePoint)
    Database:SetSetting("guildBankFrameX", x)
    Database:SetSetting("guildBankFrameY", y)
end

local function RestoreFramePosition()
    if not frame then return end

    local point = Database:GetSetting("guildBankFramePoint")
    local relativePoint = Database:GetSetting("guildBankFrameRelativePoint")
    local x = Database:GetSetting("guildBankFrameX")
    local y = Database:GetSetting("guildBankFrameY")

    if point and relativePoint and x and y then
        frame:ClearAllPoints()
        frame:SetPoint(point, UIParent, relativePoint, x, y)
    end
end

-------------------------------------------------
-- Frame Appearance
-------------------------------------------------

-- skipButtonRestyle: skip the per-button ApplyThemeTextures loop (it iterates every
-- active button). Redundant on opens/refreshes — Acquire/SetItem already theme each
-- button — so callers that follow with Refresh pass true. Only the appearance
-- SETTING_CHANGED path (which doesn't rebuild) needs the restyle.
local function UpdateFrameAppearance(skipButtonRestyle)
    if not frame then return end

    local bgAlpha = Database:GetSetting("bgAlpha") / 100
    local showBorders = Database:GetSetting("showBorders")

    -- Apply theme background (ButtonFrameTemplate for Blizzard, backdrop for Guda)
    Theme:ApplyFrameBackground(frame, bgAlpha, showBorders)

    if not skipButtonRestyle then
        local ItemButton = ns:GetModule("ItemButton")
        if ItemButton then ItemButton:ApplyThemeTextures() end
    end

    GuildBankHeader:SetBackdropAlpha(bgAlpha)

    local showSearchBar = GuildBankFrame:IsSearchBarVisible()
    local showFilterChips = Database:GetSetting("showFilterChips")
    local showFooter = Database:GetSetting("showFooter")

    -- Update search bar visibility (use SearchBar module API to handle filter chips)
    local SearchBar = ns:GetModule("SearchBar")
    if SearchBar then
        if showSearchBar then
            SearchBar:Show(frame)
            searchBar:SetPoint("TOPLEFT", frame, "TOPLEFT", Constants.FRAME.PADDING, -(Constants.FRAME.TITLE_HEIGHT + Constants.FRAME.PADDING))
            searchBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -Constants.FRAME.PADDING, -(Constants.FRAME.TITLE_HEIGHT + Constants.FRAME.PADDING))
        else
            SearchBar:Hide(frame)
        end
    end

    -- Update scroll frame positioning
    local chipHeight = (showSearchBar and showFilterChips) and (Constants.FRAME.CHIP_STRIP_HEIGHT + 1) or 0
    local topOffset = showSearchBar
        and (Constants.FRAME.TITLE_HEIGHT + Constants.FRAME.SEARCH_BAR_HEIGHT + chipHeight + Constants.FRAME.PADDING + 6)
        or (Constants.FRAME.TITLE_HEIGHT + Constants.FRAME.PADDING + 2)
    local footerHeight = GuildBankFooter:GetHeight()
    local bottomOffset = showFooter
        and (footerHeight + Constants.FRAME.PADDING + 6)
        or Constants.FRAME.PADDING

    frame.scrollFrame:ClearAllPoints()
    frame.scrollFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", Constants.FRAME.PADDING, -topOffset)
    frame.scrollFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -Constants.FRAME.PADDING - 20, bottomOffset)

    -- Update footer visibility
    if showFooter then
        GuildBankFooter:Show()
    else
        GuildBankFooter:Hide()
    end

end

-- Transient search bar visibility (header toggle). Resets on Hide().
-- Installs IsSearchBarVisible / ToggleSearchBar / ResetSearchToggle methods on GuildBankFrame.
ns:GetModule("SearchBarToggle"):Apply(GuildBankFrame, {
    getFrame = function() return frame end,
    onChanged = function()
        UpdateFrameAppearance(true)  -- Refresh below restyles buttons
        GuildBankFrame:Refresh()
    end,
})

-------------------------------------------------
-- Side Tab Bar (Vertical tabs on RIGHT side)
-------------------------------------------------

local TAB_SIZE = 36
local TAB_SPACING = 2
local showingPurchasePrompt = false  -- Track when purchase tab is selected

local function CreateSideTab(parent, index, isAllTab)
    local button = CreateFrame("Button", "GudaGuildBankSideTab" .. (isAllTab and "All" or index), parent, "BackdropTemplate")
    button:SetSize(TAB_SIZE, TAB_SIZE)
    button.tabIndex = isAllTab and 0 or index

    button:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8,
        insets = {left = 2, right = 2, top = 2, bottom = 2},
    })
    button:SetBackdropColor(0.1, 0.1, 0.1, 0.95)
    button:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(TAB_SIZE - 6, TAB_SIZE - 6)
    icon:SetPoint("CENTER")
    -- Use chest icon for "All" tab, default bag icon for specific tabs
    if isAllTab then
        icon:SetTexture("Interface\\AddOns\\GudaBags\\Assets\\chest.tga")
    else
        icon:SetTexture("Interface\\Icons\\INV_Misc_Bag_10")
    end
    button.icon = icon

    -- Tab number text (for non-All tabs)
    if not isAllTab then
        local numText = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        numText:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -2, 2)
        numText:SetText(tostring(index))
        numText:SetTextColor(0.8, 0.8, 0.8)
        button.numText = numText
    end

    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    highlight:SetBlendMode("ADD")

    -- Selection indicator
    local selected = button:CreateTexture(nil, "OVERLAY")
    selected:SetAllPoints()
    selected:SetColorTexture(0, 0.8, 0.4, 0.3)  -- Green-ish for guild
    selected:Hide()
    button.selected = selected

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        if self.tabIndex == 0 then
            GameTooltip:SetText(ns.L["TOOLTIP_GUILD_ALL_TABS"] or "All Tabs")
        elseif self.tabName then
            GameTooltip:SetText(self.tabName)
            -- Show right-click hint if player can edit this tab
            if GuildBankScanner and GuildBankScanner:IsGuildBankOpen() then
                if CanEditGuildBankTabInfo and CanEditGuildBankTabInfo(self.tabIndex) then
                    GameTooltip:AddLine(ns.L["GUILD_BANK_RIGHT_CLICK_EDIT"] or "Right-click to edit", 0.5, 0.5, 0.5)
                end
            end
        else
            GameTooltip:SetText(string.format(ns.L["TOOLTIP_GUILD_TAB"] or "Tab %d", self.tabIndex))
        end
        GameTooltip:Show()

        -- Skip hover highlighting if a specific tab is already selected (not "All")
        local selectedTab = GuildBankScanner and GuildBankScanner:GetSelectedTab() or 0
        if selectedTab ~= 0 then
            return  -- A single tab is already shown, no need to highlight
        end

        -- Highlight items from this tab (only when viewing "All" tabs)
        local ItemButton = ns:GetModule("ItemButton")
        if ItemButton and frame and frame.container and self.tabIndex > 0 then
            -- For guild bank, bagID equals tabIndex
            ItemButton:HighlightBagSlots(self.tabIndex, frame.container)
        end
    end)

    button:SetScript("OnLeave", function(self)
        GameTooltip:Hide()

        -- Reset item highlighting (only if we were highlighting)
        local selectedTab = GuildBankScanner and GuildBankScanner:GetSelectedTab() or 0
        if selectedTab ~= 0 then
            return  -- A single tab is already shown, nothing to reset
        end

        local ItemButton = ns:GetModule("ItemButton")
        if ItemButton and frame and frame.container then
            -- Re-apply search filter state instead of blindly resetting alpha
            local hasSearch = SearchBar:HasActiveFilters(frame)
            if hasSearch then
                for btn in ItemButton:GetActiveButtons() do
                    if btn.owner == frame.container then
                        if btn.itemData and btn.itemData.itemID then
                            ItemButton:SetSearchState(btn, SearchBar:ItemMatchesFilters(frame, btn.itemData))
                        else
                            ItemButton:SetSearchState(btn, false)
                        end
                    end
                end
            else
                ItemButton:ResetAllAlpha(frame.container)
            end
        end
    end)

    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:SetScript("OnClick", function(self, mouseButton)
        if GuildBankScanner then
            -- Reset purchase prompt when clicking on regular tabs
            showingPurchasePrompt = false

            if mouseButton == "RightButton" and self.tabIndex > 0 then
                -- Right-click on purchased tab: open Blizzard icon selection popup
                -- First set the current guild bank tab
                if SetCurrentGuildBankTab then
                    SetCurrentGuildBankTab(self.tabIndex)
                end

                if GuildBankPopupFrame then
                    GuildBankPopupFrame:Hide()
                end

                if not CanEditGuildBankTabInfo or not CanEditGuildBankTabInfo(self.tabIndex) then
                    UIErrorsFrame:AddMessage(ns.L["GUILD_BANK_NO_EDIT_PERMISSION"] or "You do not have permission to edit this tab", 1.0, 0.1, 0.1, 1.0)
                    return
                end

                -- For Retail, set the mode
                if IconSelectorPopupFrameModes and GuildBankPopupFrame then
                    GuildBankPopupFrame.mode = IconSelectorPopupFrameModes.Edit
                end

                if GuildBankPopupFrame then
                    GuildBankPopupFrame:Show()

                    -- For Classic/TBC, call Update after Show
                    local Expansion = ns:GetModule("Expansion")
                    if Expansion and not Expansion.IsRetail then
                        if GuildBankPopupFrame.Update then
                            GuildBankPopupFrame:Update()
                        end
                    end

                    -- Position the popup
                    GuildBankPopupFrame:SetParent(UIParent)
                    GuildBankPopupFrame:ClearAllPoints()
                    GuildBankPopupFrame:SetClampedToScreen(true)
                    GuildBankPopupFrame:SetFrameLevel(999)
                    GuildBankPopupFrame:SetPoint("LEFT", frame, "RIGHT", 10, 0)
                end
                return
            end

            local currentTab = GuildBankScanner:GetSelectedTab()
            if currentTab == self.tabIndex then
                -- Clicking same tab - show all
                if self.tabIndex ~= 0 then
                    GuildBankScanner:SetSelectedTab(0)
                end
            else
                GuildBankScanner:SetSelectedTab(self.tabIndex)
            end
            -- SetSelectedTab fires ns.OnGuildBankTabChanged, which already updates the
            -- tab visuals and refreshes — no direct Refresh here (it would be a second
            -- full render). UpdateSideTabSelection covers the no-op edge case (clicking
            -- "All" while already on All, where SetSelectedTab isn't called).
            GuildBankFrame:UpdateSideTabSelection()
        end
    end)

    return button
end

local function CreatePurchaseTab(parent)
    local button = CreateFrame("Button", "GudaGuildBankPurchaseTab", parent, "BackdropTemplate")
    button:SetSize(TAB_SIZE, TAB_SIZE)
    button.isPurchaseTab = true

    button:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8,
        insets = {left = 2, right = 2, top = 2, bottom = 2},
    })
    button:SetBackdropColor(0.1, 0.1, 0.1, 0.95)
    button:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)

    -- Plus icon
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(TAB_SIZE - 6, TAB_SIZE - 6)
    icon:SetPoint("CENTER")
    icon:SetTexture("Interface\\AddOns\\GudaBags\\Assets\\plus.tga")
    button.icon = icon

    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    highlight:SetBlendMode("ADD")

    -- Selection indicator
    local selected = button:CreateTexture(nil, "OVERLAY")
    selected:SetAllPoints()
    selected:SetColorTexture(0.3, 0.8, 0.3, 0.3)  -- Green for purchase
    selected:Hide()
    button.selected = selected

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText(ns.L["GUILD_BANK_PURCHASE_TAB"] or "Purchase New Tab")
        GameTooltip:Show()
    end)

    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    button:SetScript("OnClick", function()
        showingPurchasePrompt = true
        if GuildBankScanner then
            GuildBankScanner:SetSelectedTab(0)  -- Deselect current tab
        end
        GuildBankFrame:UpdateSideTabSelection()
        GuildBankFrame:RefreshPurchasePrompt()  -- Only refresh the purchase prompt, not full refresh
    end)

    return button
end

function GuildBankFrame:ShowSideTabs()
    if not frame or not frame.sideTabBar then return end

    local tabs = {}

    -- Get tabs from scanner
    if GuildBankScanner then
        local cachedTabInfo = GuildBankScanner:GetCachedTabInfo()
        if cachedTabInfo then
            for i, tabInfo in pairs(cachedTabInfo) do
                table.insert(tabs, {
                    index = tabInfo.index or i,
                    name = tabInfo.name,
                    icon = tabInfo.icon or "Interface\\Icons\\INV_Misc_Bag_10",
                })
            end
        end
    end

    -- If no tabs, try getting count
    if #tabs == 0 then
        local numTabs = GuildBankScanner and GuildBankScanner:GetNumTabs() or 0
        for i = 1, numTabs do
            table.insert(tabs, {
                index = i,
                name = string.format(ns.L["TOOLTIP_GUILD_TAB"] or "Tab %d", i),
                icon = "Interface\\Icons\\INV_Misc_Bag_10",
            })
        end
    end

    -- Sort tabs by index
    table.sort(tabs, function(a, b) return a.index < b.index end)

    -- Hide if no tabs and guild bank not open (offline mode)
    local isGuildBankOpen = GuildBankScanner and GuildBankScanner:IsGuildBankOpen() or false
    if #tabs == 0 and not isGuildBankOpen then
        frame.sideTabBar:Hide()
        return
    end

    -- Create "All" tab button first (only if we have tabs)
    local prevButton = nil
    if #tabs > 0 then
        if not frame.sideTabs[0] then
            frame.sideTabs[0] = CreateSideTab(frame.sideTabBar, 0, true)
        end
        frame.sideTabs[0]:ClearAllPoints()
        frame.sideTabs[0]:SetPoint("TOP", frame.sideTabBar, "TOP", 0, 0)
        frame.sideTabs[0]:Show()
        prevButton = frame.sideTabs[0]
    else
        -- Hide "All" tab if no tabs exist
        if frame.sideTabs[0] then
            frame.sideTabs[0]:Hide()
        end
    end

    -- Create/update tab buttons
    for i, tabData in ipairs(tabs) do
        if not frame.sideTabs[i] then
            frame.sideTabs[i] = CreateSideTab(frame.sideTabBar, i, false)
        end

        local button = frame.sideTabs[i]
        button.tabIndex = tabData.index
        button.tabName = tabData.name
        if tabData.icon then
            button.icon:SetTexture(tabData.icon)
        end

        button:ClearAllPoints()
        if prevButton then
            button:SetPoint("TOP", prevButton, "BOTTOM", 0, -TAB_SPACING)
        else
            button:SetPoint("TOP", frame.sideTabBar, "TOP", 0, 0)
        end
        button:Show()

        prevButton = button
    end

    -- Hide excess tabs
    for i = #tabs + 1, #frame.sideTabs do
        if frame.sideTabs[i] then
            frame.sideTabs[i]:Hide()
        end
    end

    -- Add "+" purchase tab if guild bank is open and not all tabs purchased
    local numPurchasedTabs = GetNumGuildBankTabs and GetNumGuildBankTabs() or 0
    local maxTabs = Constants.GUILD_BANK_MAX_TABS or 6
    local tabCost = GetGuildBankTabCost and GetGuildBankTabCost() or 0

    if isGuildBankOpen and numPurchasedTabs < maxTabs and tabCost > 0 then
        if not frame.purchaseTab then
            frame.purchaseTab = CreatePurchaseTab(frame.sideTabBar)
        end
        frame.purchaseTab:ClearAllPoints()
        if prevButton then
            frame.purchaseTab:SetPoint("TOP", prevButton, "BOTTOM", 0, -TAB_SPACING)
        else
            frame.purchaseTab:SetPoint("TOP", frame.sideTabBar, "TOP", 0, 0)
        end
        frame.purchaseTab:Show()
        prevButton = frame.purchaseTab
    else
        if frame.purchaseTab then
            frame.purchaseTab:Hide()
        end
    end

    -- Calculate total height
    local tabCount = #tabs
    if #tabs > 0 then
        tabCount = tabCount + 1  -- Add 1 for "All" tab
    end
    if isGuildBankOpen and numPurchasedTabs < maxTabs and tabCost > 0 then
        tabCount = tabCount + 1  -- Add 1 for "+" tab
    end

    -- Resize tab bar
    local totalHeight = (TAB_SIZE + TAB_SPACING) * tabCount
    frame.sideTabBar:SetSize(TAB_SIZE, math.max(totalHeight, TAB_SIZE))

    frame.sideTabBar:Show()
    self:UpdateSideTabSelection()
end

function GuildBankFrame:HideSideTabs()
    if frame and frame.sideTabBar then
        frame.sideTabBar:Hide()
    end
end

function GuildBankFrame:UpdateSideTabSelection()
    if not frame or not frame.sideTabs then return end

    local selectedTab = GuildBankScanner and GuildBankScanner:GetSelectedTab() or 0

    for i, button in pairs(frame.sideTabs) do
        if button and button:IsShown() then
            if i == selectedTab and not showingPurchasePrompt then
                button.selected:Show()
                button:SetBackdropBorderColor(0, 0.8, 0.4, 1)  -- Green
            else
                button.selected:Hide()
                button:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
            end
        end
    end

    -- Update purchase tab selection
    if frame.purchaseTab and frame.purchaseTab:IsShown() then
        if showingPurchasePrompt then
            frame.purchaseTab.selected:Show()
            frame.purchaseTab:SetBackdropBorderColor(0.3, 0.8, 0.3, 1)  -- Green
        else
            frame.purchaseTab.selected:Hide()
            frame.purchaseTab:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
        end
    end
end

-- Refresh only the purchase prompt (without hiding side tabs)
function GuildBankFrame:RefreshPurchasePrompt()
    if not frame then return end

    local numTabs = GetNumGuildBankTabs and GetNumGuildBankTabs() or 0
    local tabCost = GetGuildBankTabCost and GetGuildBankTabCost() or 0

    -- Hide normal content, show purchase prompt
    frame.container:Hide()
    frame.emptyMessage:Hide()

    -- Hide scrollbar and buttons when showing purchase prompt
    local scrollBar = frame.scrollFrame.ScrollBar or _G[frame.scrollFrame:GetName() and (frame.scrollFrame:GetName() .. "ScrollBar")]
    local scrollUpButton = _G[frame.scrollFrame:GetName() .. "ScrollBarScrollUpButton"]
    local scrollDownButton = _G[frame.scrollFrame:GetName() .. "ScrollBarScrollDownButton"]
    if scrollBar then scrollBar:Hide() end
    if scrollUpButton then scrollUpButton:Hide() end
    if scrollDownButton then scrollDownButton:Hide() end
    frame.scrollFrame:SetVerticalScroll(0)
    frame.scrollFrame:EnableMouseWheel(false)

    if frame.purchasePrompt then
        -- Update tabs count text
        frame.purchasePrompt.tabsText:SetText(string.format(
            ns.L["GUILD_BANK_TABS_PURCHASED"] or "(%d/%d tabs purchased)",
            numTabs,
            Constants.GUILD_BANK_MAX_TABS or 6
        ))

        -- Update cost display
        if tabCost > 0 then
            local gold = math.floor(tabCost / 10000)
            local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:12|t"
            frame.purchasePrompt.costValue:SetText(gold .. GOLD_ICON)

            local playerMoney = GetMoney and GetMoney() or 0
            frame.purchasePrompt.purchaseBtn:Show()
            frame.purchasePrompt.noPermText:Hide()

            if playerMoney >= tabCost then
                frame.purchasePrompt.purchaseBtn:Enable()
            else
                frame.purchasePrompt.purchaseBtn:Disable()
            end
        else
            frame.purchasePrompt.costValue:SetText("-")
            frame.purchasePrompt.purchaseBtn:Hide()
            frame.purchasePrompt.noPermText:Show()
        end

        frame.purchasePrompt:Show()
    end

    GuildBankFooter:UpdateSlotInfo(0, 0)
end

-------------------------------------------------
-- Frame Creation
-------------------------------------------------

local function CreateGuildBankFrame()
    local f = CreateFrame("Frame", "GudaGuildBankFrame", UIParent, "BackdropTemplate")
    f:SetSize(400, 300)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("HIGH")
    f:SetFrameLevel(Constants.FRAME_LEVELS.BASE)
    f:EnableMouse(true)

    -- Raise frame above others when clicked
    f:SetScript("OnMouseDown", function(self)
        self:SetFrameLevel(Constants.FRAME_LEVELS.RAISED)
        Theme:SyncBlizzardBgLevel(self)
        if self.container then
            ItemButton:SyncFrameLevels(self.container)
        end
        local BagFrameModule = ns:GetModule("BagFrame")
        if BagFrameModule and BagFrameModule:GetFrame() then
            local bagFrame = BagFrameModule:GetFrame()
            bagFrame:SetFrameLevel(Constants.FRAME_LEVELS.BASE)
            Theme:SyncBlizzardBgLevel(bagFrame)
            if bagFrame.container then
                bagFrame.container:SetFrameLevel(Constants.FRAME_LEVELS.BASE + Constants.FRAME_LEVELS.CONTAINER)
                ItemButton:SyncFrameLevels(bagFrame.container)
            end
        end
        local BankFrameModule = ns:GetModule("BankFrame")
        if BankFrameModule and BankFrameModule:GetFrame() then
            local bankFrame = BankFrameModule:GetFrame()
            bankFrame:SetFrameLevel(Constants.FRAME_LEVELS.BASE)
            Theme:SyncBlizzardBgLevel(bankFrame)
            if bankFrame.container then
                ItemButton:SyncFrameLevels(bankFrame.container)
            end
        end
    end)

    local backdrop = Theme:GetValue("backdrop")
    if backdrop then
        f:SetBackdrop(backdrop)
        local bgAlpha = Database:GetSetting("bgAlpha") / 100
        local bg = Theme:GetValue("frameBg")
        f:SetBackdropColor(bg[1], bg[2], bg[3], bgAlpha)
        local border = Theme:GetValue("frameBorder")
        f:SetBackdropBorderColor(border[1], border[2], border[3], border[4])
    end
    f:Hide()

    -- Register for Escape key to close
    tinsert(UISpecialFrames, "GudaGuildBankFrame")

    -- Close guild bank interaction when frame is hidden by user (Escape, close button, etc.)
    f:SetScript("OnHide", function()
        ns:Debug("GudaGuildBankFrame OnHide triggered")

        -- Persist-across-close lives here (not only in GuildBankFrame:Hide) so it engages
        -- for EVERY close path. On Anniversary the GUILDBANKFRAME_CLOSED event is
        -- unreliable, so relying on ns.OnGuildBankClosed -> Hide left guildBankHeld unset
        -- on many closes — every reopen then did a full re-render instead of fast-reopen.
        guildBankHeld = true

        -- Deliberately do NOT CancelRender here. We keep (don't release) the buttons on
        -- close, so an in-flight progressive render is safe to finish in the background
        -- while the frame is hidden. Letting it complete sets layoutCached = true, which
        -- the fast reopen requires; cancelling it left the layout permanently uncached.
        -- (A reopen that lands mid-render just falls back to a full Refresh, which
        -- cancels and restarts cleanly.)

        local scanner = ns:GetModule("GuildBankScanner")
        local wasOpen = scanner and scanner:IsGuildBankOpen() or false
        ns:Debug("  wasOpen:", wasOpen)

        -- Only close the interaction if it's still open (user closed our frame)
        -- Don't close if the game already closed it (walked away, etc.)
        if wasOpen then
            C_Timer.After(0.05, function()
                -- Check again in case state changed
                if scanner and scanner:IsGuildBankOpen() then
                    ns:Debug("  Closing guild bank interaction")
                    if C_PlayerInteractionManager and C_PlayerInteractionManager.ClearInteraction and Enum and Enum.PlayerInteractionType then
                        C_PlayerInteractionManager.ClearInteraction(Enum.PlayerInteractionType.GuildBanker)
                    elseif CloseGuildBankFrame then
                        CloseGuildBankFrame()
                    end
                end
            end)
        end
        -- Close any open character dropdown
        local BankCharactersModule = ns:GetModule("BankFrame.BankCharacters")
        if BankCharactersModule then
            BankCharactersModule:Hide()
        end
    end)

    -- Header
    f.titleBar = GuildBankHeader:Init(f)
    GuildBankHeader:SetDragCallback(SaveFramePosition)

    -- Search bar
    searchBar = SearchBar:Init(f)
    SearchBar:SetSearchCallback(f, function(text)
        GuildBankFrame:Refresh()
    end)
    f.searchBar = searchBar

    -- Transfer button callbacks (guild bank → bags)
    SearchBar:SetTransferTargetCallback(f, function()
        if GuildBankScanner and GuildBankScanner:IsGuildBankOpen() then
            return {type = "bags", label = L["TRANSFER_TO_BAGS"]}
        end
        return nil
    end)

    SearchBar:SetTransferCallback(f, function()
        GuildBankFrame:TransferMatchedItems()
    end)

    -- Scroll frame
    local scrollFrame = CreateFrame("ScrollFrame", "GudaGuildBankScrollFrame", f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", Constants.FRAME.PADDING, -(Constants.FRAME.TITLE_HEIGHT + SearchBar:GetTotalHeight(f) + Constants.FRAME.PADDING + 6))
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -Constants.FRAME.PADDING - 20, GuildBankFooter:GetHeight() + Constants.FRAME.PADDING + 6)
    f.scrollFrame = scrollFrame

    -- Style the scroll bar and hide initially (Refresh will show if needed)
    local scrollBar = scrollFrame.ScrollBar or _G[scrollFrame:GetName() and (scrollFrame:GetName() .. "ScrollBar")]
    if scrollBar then
        scrollBar:SetAlpha(0.7)
        scrollBar:Hide()
    end
    local scrollUpButton = _G[scrollFrame:GetName() .. "ScrollBarScrollUpButton"]
    local scrollDownButton = _G[scrollFrame:GetName() .. "ScrollBarScrollDownButton"]
    if scrollUpButton then scrollUpButton:Hide() end
    if scrollDownButton then scrollDownButton:Hide() end
    scrollFrame:SetVerticalScroll(0)
    scrollFrame:EnableMouseWheel(false)

    -- Container as scroll child
    local container = CreateFrame("Frame", "GudaGuildBankContainer", scrollFrame)
    container:SetSize(1, 1)
    scrollFrame:SetScrollChild(container)
    f.container = container
    f.container.masqueGroup = "Guild Bank"

    -- Empty message
    local emptyMessage = CreateFrame("Frame", nil, f)
    emptyMessage:SetAllPoints(scrollFrame)
    emptyMessage:Hide()

    local emptyText = emptyMessage:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    emptyText:SetPoint("CENTER", emptyMessage, "CENTER", 0, 10)
    emptyText:SetTextColor(0.6, 0.6, 0.6)
    emptyText:SetText(ns.L["GUILD_BANK_NO_DATA"] or "No guild bank data")
    emptyMessage.text = emptyText

    local emptyHint = emptyMessage:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    emptyHint:SetPoint("TOP", emptyText, "BOTTOM", 0, -8)
    emptyHint:SetTextColor(0.5, 0.5, 0.5)
    emptyHint:SetText(ns.L["GUILD_BANK_VISIT"] or "Visit your guild vault to cache items")
    emptyMessage.hint = emptyHint

    f.emptyMessage = emptyMessage

    -- Purchase tab prompt (shown when guild bank is open but no tabs purchased)
    local purchasePrompt = CreateFrame("Frame", nil, f)
    purchasePrompt:SetAllPoints(scrollFrame)
    purchasePrompt:Hide()

    -- Main prompt text
    local promptText = purchasePrompt:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    promptText:SetPoint("CENTER", purchasePrompt, "CENTER", 0, 60)
    promptText:SetTextColor(1, 0.82, 0)  -- Gold
    promptText:SetText(ns.L["GUILD_BANK_PURCHASE_PROMPT"] or "Do you wish to purchase this tab?")
    purchasePrompt.promptText = promptText

    -- Tabs purchased text
    local tabsText = purchasePrompt:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    tabsText:SetPoint("TOP", promptText, "BOTTOM", 0, -12)
    tabsText:SetTextColor(0.8, 0.8, 0.8)
    purchasePrompt.tabsText = tabsText

    -- Cost display frame (to hold icon and text together)
    local costFrame = CreateFrame("Frame", nil, purchasePrompt)
    costFrame:SetSize(200, 24)
    costFrame:SetPoint("TOP", tabsText, "BOTTOM", 0, -16)
    purchasePrompt.costFrame = costFrame

    local costLabel = costFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    costLabel:SetPoint("RIGHT", costFrame, "CENTER", -4, 0)
    costLabel:SetTextColor(0.8, 0.8, 0.8)
    costLabel:SetText(ns.L["GUILD_BANK_COST"] or "Cost:")
    purchasePrompt.costLabel = costLabel

    local costValue = costFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    costValue:SetPoint("LEFT", costFrame, "CENTER", 4, 0)
    costValue:SetTextColor(1, 1, 1)  -- White
    purchasePrompt.costValue = costValue

    -- Purchase button
    local purchaseBtn = CreateFrame("Button", "GudaGuildBankPurchaseBtn", purchasePrompt, "UIPanelButtonTemplate")
    purchaseBtn:SetSize(120, 28)
    purchaseBtn:SetPoint("TOP", costFrame, "BOTTOM", 0, -20)
    purchaseBtn:SetText(ns.L["GUILD_BANK_PURCHASE"] or "Purchase")
    purchaseBtn:SetScript("OnClick", function()
        -- Call the purchase function
        if BuyGuildBankTab then
            BuyGuildBankTab()
        end
    end)
    purchaseBtn:SetScript("OnEnter", function(self)
        local tabCost = GetGuildBankTabCost and GetGuildBankTabCost() or 0
        local playerMoney = GetMoney and GetMoney() or 0
        if tabCost > 0 and playerMoney < tabCost then
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(ns.L["GUILD_BANK_NOT_ENOUGH_GOLD"] or "Not enough gold", 1, 0.3, 0.3)
            GameTooltip:Show()
        end
    end)
    purchaseBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    purchasePrompt.purchaseBtn = purchaseBtn

    -- No permission text (shown instead of button when player can't purchase)
    local noPermText = purchasePrompt:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    noPermText:SetPoint("TOP", costFrame, "BOTTOM", 0, -20)
    noPermText:SetTextColor(1, 0.3, 0.3)  -- Red
    noPermText:SetText(ns.L["GUILD_BANK_NO_PERMISSION"] or "You don't have permission to purchase tabs")
    noPermText:Hide()
    purchasePrompt.noPermText = noPermText

    f.purchasePrompt = purchasePrompt

    -- Footer
    f.footer = GuildBankFooter:Init(f)

    -- Side tab bar (vertical, on right side outside frame)
    local sideTabBar = CreateFrame("Frame", "GudaGuildBankSideTabBar", f)
    sideTabBar:SetPoint("TOPLEFT", f, "TOPRIGHT", 0, -55)
    sideTabBar:SetSize(32, 200)
    sideTabBar:Hide()
    f.sideTabBar = sideTabBar
    f.sideTabs = {}

    Font:RegisterFrame(f)
    return f
end

-------------------------------------------------
-- Refresh / Display
-------------------------------------------------

local function HasGuildBankData(guildBank)
    if not guildBank then return false end
    for tabIndex, tabData in pairs(guildBank) do
        if tabData.numSlots and tabData.numSlots > 0 then
            return true
        end
    end
    return false
end

function GuildBankFrame:CountTabs(guildBank)
    if not guildBank then return 0 end
    local count = 0
    for _ in pairs(guildBank) do
        count = count + 1
    end
    return count
end

-- Release every guild-bank item button + header and forget per-slot tracking.
-- Used by the purchase-prompt / empty branches and on close, where there is no
-- progressive render to reuse buttons in place.
local function ReleaseAllGuildBankItems()
    if frame and frame.container then
        ItemButton:ReleaseAll(frame.container)
    end
    ReleaseAllCategoryHeaders()  -- also resets categoryHeaders = {}
    buttonsBySlot = {}
    itemButtons = {}
    cachedItemData = {}
    cachedItemCount = {}
end

-- Place a single header or item slot. Mutates st.currentY / st.currentCol the
-- same way the original inline Refresh loop did. Buttons/headers are reused in
-- place across refreshes (by slot key / by index) so a re-render updates content
-- without a visible blank; leftovers are released in FinishRender.
local function RenderOneSlot(slotInfo, st)
    if slotInfo.isHeader then
        -- Start new row if needed
        if st.currentCol > 0 then
            st.currentY = st.currentY - st.iconSize - st.spacing
            st.currentCol = 0
        end

        -- Reuse the header at this position if one already exists, else acquire.
        st.usedHeaders = st.usedHeaders + 1
        local header = categoryHeaders[st.usedHeaders]
        if not header then
            header = AcquireCategoryHeader(frame.container)
            categoryHeaders[st.usedHeaders] = header
        end
        header.text:SetText(slotInfo.tabName or "Tab")
        if slotInfo.tabIcon then
            header.icon:SetTexture(slotInfo.tabIcon)
            header.icon:Show()
        else
            header.icon:Hide()
        end
        header:ClearAllPoints()
        header:SetPoint("TOPLEFT", frame.container, "TOPLEFT", 0, st.currentY)
        header:SetWidth(st.contentWidth)
        header:Show()

        st.currentY = st.currentY - st.headerHeight
    else
        -- Regular slot
        local x = st.currentCol * (st.iconSize + st.spacing)
        local y = st.currentY

        local slotKey = slotInfo.tabIndex .. ":" .. slotInfo.slot
        -- Reuse the existing button for this slot (no hide/re-show flicker) or
        -- acquire a fresh one. Unmark from the stale set so it survives cleanup.
        local button = buttonsBySlot[slotKey]
        if button then
            st.stale[slotKey] = nil
        else
            button = ItemButton:Acquire(frame.container)
            buttonsBySlot[slotKey] = button
        end

        if slotInfo.itemData then
            -- Adapt item data for ItemButton (needs bagID and slot)
            local adaptedData = {}
            for k, v in pairs(slotInfo.itemData) do
                adaptedData[k] = v
            end
            adaptedData.bagID = slotInfo.tabIndex
            adaptedData.slot = slotInfo.slot
            adaptedData.isGuildBank = true

            ItemButton:SetItem(button, adaptedData, st.iconSize, st.isReadOnly)

            if st.hasSearch then
                ItemButton:SetSearchState(button, SearchBar:ItemMatchesFilters(frame, slotInfo.itemData))
            else
                ItemButton:ClearSearchState(button)
            end

            cachedItemData[slotKey] = slotInfo.itemData.itemID
            cachedItemCount[slotKey] = slotInfo.itemData.count
        else
            -- Empty slot - pass isGuildBank flag for depositing
            ItemButton:SetEmpty(button, slotInfo.tabIndex, slotInfo.slot, st.iconSize, st.isReadOnly, true)
            if st.hasSearch then
                ItemButton:SetSearchState(button, false)
            else
                ItemButton:ClearSearchState(button)
            end
            cachedItemData[slotKey] = nil
            cachedItemCount[slotKey] = nil
        end

        button.wrapper:ClearAllPoints()
        button.wrapper:SetPoint("TOPLEFT", frame.container, "TOPLEFT", x, y)

        table.insert(itemButtons, button)

        -- Advance position
        st.currentCol = st.currentCol + 1
        if st.currentCol >= st.columns then
            st.currentCol = 0
            st.currentY = st.currentY - st.iconSize - st.spacing
        end
    end
end

-- Finalize once every slot is placed: release leftovers, then footer + font.
local function FinishRender(st)
    layoutCached = true

    -- Release buttons for slots that no longer exist (reused ones were unmarked).
    if st.stale then
        for key in pairs(st.stale) do
            local button = buttonsBySlot[key]
            if button then
                ItemButton:Release(button)
                buttonsBySlot[key] = nil
            end
        end
    end

    -- Release headers beyond the count this render used (reused in place by index).
    for i = #categoryHeaders, st.usedHeaders + 1, -1 do
        CategoryHeaderPool:Release(categoryHeaders[i])
        categoryHeaders[i] = nil
    end

    -- Update footer
    local totalSlots = 0
    local freeSlots = 0
    for _, tabData in pairs(st.guildBank) do
        totalSlots = totalSlots + (tabData.numSlots or 0)
        freeSlots = freeSlots + (tabData.freeSlots or 0)
    end
    GuildBankFooter:UpdateSlotInfo(totalSlots - freeSlots, totalSlots)
    GuildBankFooter:Update()

    -- Font: nothing to sweep here. The frame's static chrome is registered once via
    -- Font:RegisterFrame at creation, and every region created during a render
    -- self-applies the font and registers itself: item buttons (Font:Apply on
    -- create/SetItem) and category headers (Font:Override on create). A font-family
    -- change re-sweeps the whole frame via ReapplyAll. Re-walking all ~600 buttons
    -- every render (the old Font:ApplyToRegions(frame) here) cost ~100-150ms per
    -- render for nothing.

    renderState = nil
    renderDriver:Hide()
end

-- Stop an in-flight render (tab switch, data update, or frame close).
CancelRender = function()
    renderState = nil
    renderDriver:Hide()
end

-- Place buttons from the cursor until the frame budget is spent, then yield.
local function ProcessRenderChunk()
    local st = renderState
    if not st then renderDriver:Hide(); return end

    -- Guild bank is never reachable in combat, but if combat somehow began,
    -- finish synchronously rather than spread secure ops across frames.
    local drainAll = InCombatLockdown()

    local startTime = debugprofilestop()
    local slots = st.allSlots
    local n = #slots
    local i = st.cursor
    while i <= n do
        RenderOneSlot(slots[i], st)
        i = i + 1
        if not drainAll and (debugprofilestop() - startTime) > RENDER_BUDGET_MS then
            break
        end
    end
    st.cursor = i

    if i > n then
        FinishRender(st)
    end
end
renderDriver:SetScript("OnUpdate", ProcessRenderChunk)

function GuildBankFrame:Refresh()
    if not frame then return end

    ns:Debug("GuildBankFrame:Refresh called")

    CancelRender()

    -- Do NOT release/clear buttons here. The progressive renderer reuses the
    -- existing buttons in place (keyed by slot) so a re-render updates content
    -- without a visible blank, and releases only leftovers when it finishes.
    -- The purchase-prompt / empty branches below release explicitly instead.
    layoutCached = false

    local isGuildBankOpen = GuildBankScanner and GuildBankScanner:IsGuildBankOpen() or false
    ns:Debug("  isGuildBankOpen =", isGuildBankOpen)

    -- Check if we need to show the purchase tab prompt
    -- This happens when: guild bank is open AND (no tabs purchased OR purchase tab is selected)
    local numTabs = GetNumGuildBankTabs and GetNumGuildBankTabs() or 0
    local tabCost = GetGuildBankTabCost and GetGuildBankTabCost() or 0
    ns:Debug("  numTabs =", numTabs, "tabCost =", tabCost, "showingPurchasePrompt =", showingPurchasePrompt)

    if isGuildBankOpen and (numTabs == 0 or showingPurchasePrompt) then
        ns:Debug("  Showing purchase prompt")
        ReleaseAllGuildBankItems()
        frame.container:Hide()
        frame.emptyMessage:Hide()

        -- Hide scrollbar and buttons when showing purchase prompt
        local scrollBar = frame.scrollFrame.ScrollBar or _G[frame.scrollFrame:GetName() and (frame.scrollFrame:GetName() .. "ScrollBar")]
        local scrollUpButton = _G[frame.scrollFrame:GetName() .. "ScrollBarScrollUpButton"]
        local scrollDownButton = _G[frame.scrollFrame:GetName() .. "ScrollBarScrollDownButton"]
        if scrollBar then scrollBar:Hide() end
        if scrollUpButton then scrollUpButton:Hide() end
        if scrollDownButton then scrollDownButton:Hide() end
        frame.scrollFrame:SetVerticalScroll(0)
        frame.scrollFrame:EnableMouseWheel(false)

        -- Only hide side tabs if no tabs exist at all
        if numTabs == 0 then
            self:HideSideTabs()
        end

        -- Update purchase prompt content
        if frame.purchasePrompt then
            -- Update tabs count text
            frame.purchasePrompt.tabsText:SetText(string.format(
                ns.L["GUILD_BANK_TABS_PURCHASED"] or "(%d/%d tabs purchased)",
                numTabs,
                Constants.GUILD_BANK_MAX_TABS or 6
            ))

            -- Update cost display
            if tabCost > 0 then
                -- Format cost as gold
                local gold = math.floor(tabCost / 10000)
                local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:12|t"
                frame.purchasePrompt.costValue:SetText(gold .. GOLD_ICON)

                -- Check if player has enough gold
                local playerMoney = GetMoney and GetMoney() or 0

                -- Show purchase button, hide no permission text
                frame.purchasePrompt.purchaseBtn:Show()
                frame.purchasePrompt.noPermText:Hide()

                -- Enable/disable button based on player gold
                if playerMoney >= tabCost then
                    frame.purchasePrompt.purchaseBtn:Enable()
                else
                    frame.purchasePrompt.purchaseBtn:Disable()
                end
            else
                -- Player can't purchase (no permission or all tabs bought)
                frame.purchasePrompt.costValue:SetText("-")
                frame.purchasePrompt.purchaseBtn:Hide()
                frame.purchasePrompt.noPermText:Show()
            end

            frame.purchasePrompt:Show()
        end

        -- Fixed size for purchase prompt (slightly wider for prompt text)
        frame:SetSize(Constants.FRAME.GUILD_BANK_MIN_WIDTH + 150, Constants.FRAME.GUILD_BANK_MIN_HEIGHT)
        GuildBankFooter:UpdateSlotInfo(0, 0)
        return
    end

    -- Hide purchase prompt if showing normal content
    if frame.purchasePrompt then
        frame.purchasePrompt:Hide()
    end

    -- Always use cached guild bank data (LoadFromDatabase populates this for offline mode)
    local guildBank = GuildBankScanner and GuildBankScanner:GetCachedGuildBank()
    ns:Debug("  Got cached guild bank, tabs =", guildBank and self:CountTabs(guildBank) or 0)

    local hasData = HasGuildBankData(guildBank)
    ns:Debug("  hasData =", hasData)

    if not hasData then
        ns:Debug("  No data, showing empty message")
        ReleaseAllGuildBankItems()
        frame.container:Hide()
        frame.emptyMessage:Show()
        self:HideSideTabs()

        frame:SetSize(Constants.FRAME.GUILD_BANK_MIN_WIDTH, Constants.FRAME.GUILD_BANK_MIN_HEIGHT)
        GuildBankFooter:UpdateSlotInfo(0, 0)
        return
    end

    frame.emptyMessage:Hide()
    frame.container:Show()

    -- Show side tabs
    ns:ProfileStart("gb.sidetabs")
    self:ShowSideTabs()
    ns:ProfileStop("gb.sidetabs")

    local iconSize = Database:GetSetting("iconSize")
    local spacing = Database:GetSetting("iconSpacing")
    local columns = Database:GetSetting("guildBankColumns")
    local hasSearch = SearchBar:HasActiveFilters(frame)
    local selectedTab = GuildBankScanner and GuildBankScanner:GetSelectedTab() or 0

    -- Collect all slots from guild bank
    ns:ProfileStart("gb.gather")
    local allSlots = {}
    local showTabSections = selectedTab == 0 and GuildBankScanner and GuildBankScanner:GetNumTabs() > 1

    -- Sort tabs by index
    local sortedTabs = {}
    for tabIndex, tabData in pairs(guildBank) do
        table.insert(sortedTabs, {index = tabIndex, data = tabData})
    end
    table.sort(sortedTabs, function(a, b) return a.index < b.index end)

    for _, tabEntry in ipairs(sortedTabs) do
        local tabIndex = tabEntry.index
        local tabData = tabEntry.data

        -- Skip if filtering by specific tab
        if selectedTab > 0 and tabIndex ~= selectedTab then
            -- Skip this tab
        elseif tabData and tabData.slots then
            -- Add tab header if showing all tabs
            if showTabSections then
                table.insert(allSlots, {
                    isHeader = true,
                    tabIndex = tabIndex,
                    tabName = tabData.name or string.format("Tab %d", tabIndex),
                    tabIcon = tabData.icon,
                })
            end

            -- Add slots from this tab
            for slot = 1, (tabData.numSlots or Constants.GUILD_BANK_SLOTS_PER_TAB) do
                local itemData = tabData.slots[slot]
                table.insert(allSlots, {
                    tabIndex = tabIndex,
                    slot = slot,
                    itemData = itemData,
                })
            end
        end
    end

    ns:ProfileStop("gb.gather")

    -- Calculate content dimensions
    local numSlots = 0
    local headerCount = 0
    for _, slotInfo in ipairs(allSlots) do
        if slotInfo.isHeader then
            headerCount = headerCount + 1
        else
            numSlots = numSlots + 1
        end
    end

    local itemRows = math.ceil(numSlots / columns)
    local contentWidth = (iconSize * columns) + (spacing * (columns - 1))
    local headerHeight = 20
    -- Calculate height: item rows + spacing between rows + headers (not double-counted)
    local actualContentHeight = (iconSize * itemRows) + (spacing * math.max(0, itemRows - 1)) + (headerCount * headerHeight)

    -- Calculate frame dimensions
    local showSearchBar = GuildBankFrame:IsSearchBarVisible()
    local showFilterChips = Database:GetSetting("showFilterChips")
    local showFooter = Database:GetSetting("showFooter")
    local chipHeight = (showSearchBar and showFilterChips) and (Constants.FRAME.CHIP_STRIP_HEIGHT + 1) or 0
    local topOffset = showSearchBar
        and (Constants.FRAME.TITLE_HEIGHT + Constants.FRAME.SEARCH_BAR_HEIGHT + chipHeight + Constants.FRAME.PADDING + 6)
        or (Constants.FRAME.TITLE_HEIGHT + Constants.FRAME.PADDING + 2)
    local footerHeight = GuildBankFooter:GetHeight()
    local bottomOffset = showFooter
        and (footerHeight + Constants.FRAME.PADDING + 6)
        or Constants.FRAME.PADDING
    local chromeHeight = topOffset + bottomOffset

    local frameWidth = math.max(contentWidth + (Constants.FRAME.PADDING * 2), Constants.FRAME.GUILD_BANK_MIN_WIDTH)
    local frameHeightNeeded = actualContentHeight + chromeHeight

    local adjustedFrameHeight = math.max(frameHeightNeeded, Constants.FRAME.GUILD_BANK_MIN_HEIGHT)

    local screenHeight = UIParent:GetHeight()
    local maxFrameHeight = screenHeight - 100
    local actualFrameHeight = math.min(adjustedFrameHeight, maxFrameHeight)

    local scrollAreaHeight = actualFrameHeight - chromeHeight
    local needsScroll = actualContentHeight > scrollAreaHeight + 5

    local scrollbarWidth = needsScroll and 20 or 0
    -- Pin the top edge across the resize. The frame is CENTER-anchored, so changing its
    -- height would otherwise grow/shrink symmetrically and move the top — very visible
    -- switching All Tabs <-> a single tab (big height change). Capture the current
    -- top-left and re-anchor by TOPLEFT so the frame only grows downward; the top stays
    -- put (matches the bank, whose per-tab height barely changes so it never looks off).
    local prevTop = frame:GetTop()
    local prevLeft = frame:GetLeft()
    frame:SetSize(frameWidth + scrollbarWidth, actualFrameHeight)
    if prevTop and prevLeft then
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", prevLeft, prevTop)
    end

    frame.scrollFrame:ClearAllPoints()
    frame.scrollFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", Constants.FRAME.PADDING, -topOffset)
    frame.scrollFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -Constants.FRAME.PADDING - scrollbarWidth, bottomOffset)

    frame.container:SetSize(contentWidth, math.max(actualContentHeight, 1))

    -- Force hide scrollbar and disable scrolling when not needed
    -- Must be done AFTER setting container size to override template's auto-show behavior
    local scrollBar = frame.scrollFrame.ScrollBar or _G[frame.scrollFrame:GetName() and (frame.scrollFrame:GetName() .. "ScrollBar")]
    local scrollUpButton = _G[frame.scrollFrame:GetName() .. "ScrollBarScrollUpButton"]
    local scrollDownButton = _G[frame.scrollFrame:GetName() .. "ScrollBarScrollDownButton"]
    if needsScroll then
        if scrollBar then scrollBar:Show() end
        if scrollUpButton then scrollUpButton:Show() end
        if scrollDownButton then scrollDownButton:Show() end
        frame.scrollFrame:EnableMouseWheel(true)
        -- Start at the top on every (re)render, e.g. a tab switch. Without this the
        -- scrollFrame keeps the previous tab's offset (clamped to the new content), so
        -- the new tab appears scrolled/centered instead of aligned to the top.
        frame.scrollFrame:SetVerticalScroll(0)
    else
        if scrollBar then scrollBar:Hide() end
        if scrollUpButton then scrollUpButton:Hide() end
        if scrollDownButton then scrollDownButton:Hide() end
        frame.scrollFrame:SetVerticalScroll(0)
        frame.scrollFrame:EnableMouseWheel(false)
        -- Double-check hide after a frame to catch template's auto-show
        C_Timer.After(0, function()
            if not needsScroll then
                if scrollBar then scrollBar:Hide() end
                if scrollUpButton then scrollUpButton:Hide() end
                if scrollDownButton then scrollDownButton:Hide() end
                frame.scrollFrame:SetVerticalScroll(0)
            end
        end)
    end

    -- Render items progressively: place the first chunk now (instant paint),
    -- then let renderDriver place the rest across frames within RENDER_BUDGET_MS.
    -- Frame size/scroll range above are derived from slot counts, so scrolling
    -- works fully even while later rows are still filling in.
    --
    -- Buttons are reused in place: every slot key currently present starts in
    -- the "stale" set; the renderer unmarks the ones it reuses and FinishRender
    -- releases whatever remains (slots that disappeared). This means a re-render
    -- (e.g. the second open refresh once server data arrives) updates buttons
    -- in place instead of hiding then re-showing them.
    local stale = {}
    for key in pairs(buttonsBySlot) do
        stale[key] = true
    end
    itemButtons = {}
    cachedItemData = {}
    cachedItemCount = {}

    renderState = {
        allSlots = allSlots,
        cursor = 1,
        currentY = 0,
        currentCol = 0,
        usedHeaders = 0,
        stale = stale,
        iconSize = iconSize,
        spacing = spacing,
        columns = columns,
        contentWidth = contentWidth,
        headerHeight = headerHeight,
        hasSearch = hasSearch,
        isReadOnly = not isGuildBankOpen,
        guildBank = guildBank,
    }
    -- Record the view this render produced so a later reopen can tell whether the
    -- retained layout still matches (→ fast IncrementalUpdate instead of full Refresh).
    guildBankLastRenderSig = ComputeGuildBankRenderSig()
    -- Render the visible viewport synchronously so nothing on-screen pops in, then
    -- defer the off-screen remainder to the driver (it fills in invisibly across
    -- frames). In combat, finish in one pass rather than spreading secure ops across
    -- combat frames. (currentY is the position of the next op; once it drops past the
    -- viewport, everything after is off-screen.)
    local st = renderState
    local n = #allSlots
    local drainAll = InCombatLockdown()
    local visibleCutoff = -(scrollAreaHeight + iconSize + spacing)
    ns:ProfileStart("GuildBankRender.sync")
    while st.cursor <= n do
        RenderOneSlot(allSlots[st.cursor], st)
        st.cursor = st.cursor + 1
        if not drainAll and st.currentY < visibleCutoff then
            break
        end
    end
    ns:ProfileStop("GuildBankRender.sync")
    if st.cursor > n then
        FinishRender(st)
    else
        renderDriver:Show()
    end
end

-- Update only the slots that actually changed in the given tabs, instead of
-- re-rendering the whole guild bank. The layout never changes on a deposit/withdraw
-- (a tab always has the same slot count), so this is safe. Falls back to a full
-- Refresh when there is no cached layout, a progressive render is in flight, or the
-- purchase/empty view is showing.
function GuildBankFrame:IncrementalUpdate(dirtyTabs)
    if not frame or not frame:IsShown() then return end
    if not layoutCached or renderState or showingPurchasePrompt then
        self:Refresh()
        return
    end
    local guildBank = GuildBankScanner and GuildBankScanner:GetCachedGuildBank()
    if not guildBank then return end

    ns:ProfileStart("GuildBank.incremental")

    local iconSize = Database:GetSetting("iconSize")
    local hasSearch = SearchBar:HasActiveFilters(frame)
    local isReadOnly = not (GuildBankScanner and GuildBankScanner:IsGuildBankOpen())

    -- No specific tabs given -> check them all.
    local tabsToCheck = dirtyTabs
    if not tabsToCheck or not next(tabsToCheck) then
        tabsToCheck = {}
        for tabIndex in pairs(guildBank) do tabsToCheck[tabIndex] = true end
    end

    for tabIndex in pairs(tabsToCheck) do
        local tabData = guildBank[tabIndex]
        local numSlots = (tabData and tabData.numSlots) or Constants.GUILD_BANK_SLOTS_PER_TAB
        for slot = 1, numSlots do
            local slotKey = tabIndex .. ":" .. slot
            local button = buttonsBySlot[slotKey]
            -- Only update slots that are currently rendered (their tab is visible).
            if button then
                local newItemData = tabData and tabData.slots and tabData.slots[slot]
                local newItemID = newItemData and newItemData.itemID or nil
                local newCount = newItemData and newItemData.count or nil
                if cachedItemData[slotKey] ~= newItemID or cachedItemCount[slotKey] ~= newCount then
                    if newItemData then
                        local adapted = {}
                        for k, v in pairs(newItemData) do adapted[k] = v end
                        adapted.bagID = tabIndex
                        adapted.slot = slot
                        adapted.isGuildBank = true
                        ItemButton:SetItem(button, adapted, iconSize, isReadOnly)
                        if hasSearch then
                            ItemButton:SetSearchState(button, SearchBar:ItemMatchesFilters(frame, newItemData))
                        else
                            ItemButton:ClearSearchState(button)
                        end
                        cachedItemData[slotKey] = newItemID
                        cachedItemCount[slotKey] = newCount
                    else
                        ItemButton:SetEmpty(button, tabIndex, slot, iconSize, isReadOnly, true)
                        if hasSearch then
                            ItemButton:SetSearchState(button, false)
                        else
                            ItemButton:ClearSearchState(button)
                        end
                        cachedItemData[slotKey] = nil
                        cachedItemCount[slotKey] = nil
                    end
                end
            end
        end
    end

    -- Keep the footer's used/free slot count accurate (the full render does this in
    -- FinishRender).
    local totalSlots, freeSlots = 0, 0
    for _, tabData in pairs(guildBank) do
        totalSlots = totalSlots + (tabData.numSlots or 0)
        freeSlots = freeSlots + (tabData.freeSlots or 0)
    end
    GuildBankFooter:UpdateSlotInfo(totalSlots - freeSlots, totalSlots)
    GuildBankFooter:Update()
    ns:ProfileStop("GuildBank.incremental")
end

-------------------------------------------------
-- Public API
-------------------------------------------------

function GuildBankFrame:Toggle()
    LoadComponents()

    if not frame then
        frame = CreateGuildBankFrame()
        RestoreFramePosition()
    end

    if frame:IsShown() then
        frame:Hide()
    else
        if GuildBankScanner and GuildBankScanner:IsGuildBankOpen() then
            GuildBankScanner:ScanAllTabs()
        else
            -- Load from database for offline viewing
            local guildName = GuildBankScanner and GuildBankScanner:GetCurrentGuildName()
            if guildName then
                GuildBankScanner:LoadFromDatabase(guildName)
            end
        end
        self:Refresh()
        UpdateFrameAppearance(true)  -- Refresh above already styled buttons
        GuildBankHeader:UpdateTitle()
        frame:Show()
    end
end

-- True when a reopen can reuse the retained layout and just reconcile changed slots
-- (fast path) instead of doing a full Refresh. Mirrors BankFrame:CanFastReopen.
function GuildBankFrame:CanFastReopen()
    -- Deliberately NOT gated on guildBankHeld. Buttons are freed only by ReleaseHeld
    -- (bank/mail open, combat start), which ALSO clears layoutCached — so layoutCached
    -- already means "buttons retained and laid out". On Anniversary the guild-bank close
    -- detection is flaky, leaving guildBankHeld unreliable; trusting the layout/signature
    -- state instead is both correct and robust. frame-not-shown marks this as a reopen.
    return layoutCached
        and not renderState
        and not showingPurchasePrompt
        and frame and not frame:IsShown()
        and guildBankLastRenderSig ~= nil
        and guildBankLastRenderSig == ComputeGuildBankRenderSig()
end

function GuildBankFrame:Show()
    LoadComponents()

    -- Idempotent open: Anniversary fires the open path twice (both GUILDBANKFRAME_OPENED
    -- and the Blizzard-frame OnShow hook route through HandleGuildBankOpened -> here). The
    -- first call already showed and reconciled the view; a second call while already shown
    -- must NOT tear it down and full-render again — just refresh data cheaply.
    if frame and frame:IsShown() then
        if GuildBankScanner and GuildBankScanner:IsGuildBankOpen() then
            GuildBankScanner:ScanAllTabs()
        end
        self:IncrementalUpdate(nil)
        return
    end

    -- Free the bank's retained buttons (it doesn't coexist with the guild bank, so
    -- this returns its share of the shared ItemButton pool; no-op if open / not holding).
    --
    -- Do NOT release the bags' held buttons: the bags auto-open *together* with the
    -- guild bank, so tearing down their persisted layout would force a full cold
    -- re-render right as they reopen. Leaving them held lets the bag auto-open take
    -- its fast-reopen path. In-combat pool pressure is handled by PLAYER_REGEN_DISABLED.
    local BankFrameModule = ns:GetModule("BankFrame")
    if BankFrameModule and BankFrameModule.ReleaseHeld then
        BankFrameModule:ReleaseHeld()
    end

    if not frame then
        frame = CreateGuildBankFrame()
        RestoreFramePosition()
    end

    if GuildBankScanner and GuildBankScanner:IsGuildBankOpen() then
        GuildBankScanner:ScanAllTabs()
    else
        -- Load from database for offline viewing
        local guildName = GuildBankScanner and GuildBankScanner:GetCurrentGuildName()
        if guildName then
            GuildBankScanner:LoadFromDatabase(guildName)
        end
    end

    -- Fast reopen (mirrors BankFrame): if the retained layout still matches the current
    -- view, just show it and reconcile changed slots instead of re-SetItem-ing every
    -- slot. Decide AFTER the scan so a newly purchased tab is reflected in the signature
    -- (the scan can't invalidate anything — OnGuildBankUpdated no-ops on a hidden frame).
    local canFast = self:CanFastReopen()
    guildBankHeld = false
    if canFast then
        frame:Show()
        UpdateFrameAppearance(true)
        GuildBankHeader:UpdateTitle()
        self:IncrementalUpdate(nil)  -- requires frame shown; near-no-op when unchanged
    else
        self:Refresh()
        UpdateFrameAppearance(true)  -- Refresh above already styled buttons
        GuildBankHeader:UpdateTitle()
        frame:Show()
    end
end

-- Tear down the retained (held-while-hidden) buttons: release them to the shared
-- pool and clear caches. No-op unless held, so it is safe to call from other pool
-- consumers (bags/bank/mail) on open and on combat start. Releasing is SetShown/
-- pool bookkeeping only — combat-safe; it never creates frames.
function GuildBankFrame:ReleaseHeld()
    if not guildBankHeld then return end
    guildBankHeld = false
    CancelRender()
    ReleaseAllGuildBankItems()
    layoutCached = false
end

function GuildBankFrame:Hide()
    if frame then
        -- Note: no CancelRender here. We keep the buttons on close and let any in-flight
        -- progressive render finish in the background so layoutCached stays valid for a
        -- fast reopen (see the frame's OnHide handler). frame:Hide() below also fires
        -- OnHide, which sets guildBankHeld for every close path.

        -- Clear search/chip filters on close
        SearchBar:ClearAllFilters(frame)

        frame:Hide()
        -- Reset transient search toggle so next open starts collapsed
        self:ResetSearchToggle()

        -- Keep the buttons + layout so the next open reuses them (no teardown freeze
        -- when walking away). Released later by ReleaseHeld if the pool is needed.
        guildBankHeld = true
    end
end

function GuildBankFrame:IsShown()
    return frame and frame:IsShown()
end

function GuildBankFrame:GetFrame()
    return frame
end

function GuildBankFrame:TransferMatchedItems()
    if InCombatLockdown() then
        UIErrorsFrame:AddMessage(L["TRANSFER_COMBAT"], 1.0, 0.1, 0.1, 1.0)
        return
    end
    if not frame or not GuildBankScanner or not GuildBankScanner:IsGuildBankOpen() then return end

    local guildBank = GuildBankScanner:GetCachedGuildBank()
    if not guildBank then return end

    for tabIndex, tabData in pairs(guildBank) do
        if tabData.slots then
            for slot, itemData in pairs(tabData.slots) do
                if itemData and itemData.itemID and SearchBar:ItemMatchesFilters(frame, itemData) then
                    AutoStoreGuildBankItem(tabIndex, slot)
                end
            end
        end
    end
end

-------------------------------------------------
-- Event Callbacks
-------------------------------------------------

-- Called when guild bank is opened
ns.OnGuildBankOpened = function()
    ns:Debug("OnGuildBankOpened callback triggered")
    LoadComponents()

    -- Auto open bags on guild bank interaction (before showing guild bank so it stays on top).
    -- Routes through BagFrame's smart-open helper so bagsAutoOpened tracking stays in sync
    -- with mail/merchant/AH/etc. (see UI/BagFrame.lua SmartAutoOpen).
    local BagFrameModule = ns:GetModule("BagFrame")
    if BagFrameModule then
        BagFrameModule:OnAutoInteractionOpen()
    end

    -- Show our guild bank frame (Blizzard's frame is hidden by GuildBankScanner)
    GuildBankFrame:Show()

    -- Raise guild bank above bags so interaction frame is always respected
    if BagFrameModule and BagFrameModule:IsShown() then
        local bagFrame = BagFrameModule:GetFrame()
        if bagFrame then
            bagFrame:SetFrameLevel(Constants.FRAME_LEVELS.BASE)
            Theme:SyncBlizzardBgLevel(bagFrame)
            if bagFrame.container then
                bagFrame.container:SetFrameLevel(Constants.FRAME_LEVELS.BASE + Constants.FRAME_LEVELS.CONTAINER)
                ItemButton:SyncFrameLevels(bagFrame.container)
            end
        end
    end
    if frame then
        frame:SetFrameLevel(Constants.FRAME_LEVELS.RAISED)
        Theme:SyncBlizzardBgLevel(frame)
        if frame.container then
            ItemButton:SyncFrameLevels(frame.container)
        end
    end

    -- Refresh bags to update stacking (unstack when interaction window opens).
    -- View-aware: only category view re-renders (single view has no grouping), so
    -- this no longer does a pointless full bag refresh on open in single view.
    if BagFrameModule and BagFrameModule:IsShown() then
        if BagFrameModule.RefreshForInteraction then
            BagFrameModule:RefreshForInteraction()
        end
        local bagFrame = BagFrameModule:GetFrame()
        if bagFrame then
            SearchBar:UpdateTransferState(bagFrame)
        end
    end
end

-- Called when guild bank is closed
ns.OnGuildBankClosed = function()
    ns:Debug("OnGuildBankClosed callback triggered")
    showingPurchasePrompt = false  -- Reset purchase prompt state
    GuildBankFrame:Hide()

    -- Auto close bags on guild bank interaction end.
    -- Routes through BagFrame's smart-close helper, which only closes the bags
    -- if the addon auto-opened them (and respects autoCloseBags).
    local BagFrameModule = ns:GetModule("BagFrame")
    if BagFrameModule then
        BagFrameModule:OnAutoInteractionClose()
    end

    -- Refresh bags to update stacking (re-stack when interaction window closes).
    -- View-aware: only category view re-renders; single view skips the full refresh.
    if BagFrameModule and BagFrameModule:IsShown() then
        if BagFrameModule.RefreshForInteraction then
            BagFrameModule:RefreshForInteraction()
        end
        local bagFrame = BagFrameModule:GetFrame()
        if bagFrame then
            SearchBar:UpdateTransferState(bagFrame)
        end
    end
end

-- Called when guild bank items change
ns.OnGuildBankUpdated = function(dirtyTabs)
    if frame and frame:IsShown() then
        -- Update only the changed slots; falls back to a full Refresh when needed.
        GuildBankFrame:IncrementalUpdate(dirtyTabs)
    end
end

-- Called when tab selection changes
ns.OnGuildBankTabChanged = function(tabIndex)
    if frame and frame:IsShown() then
        ns:ProfileStart("GuildBank.tabswitch")
        GuildBankFrame:UpdateSideTabSelection()
        GuildBankFrame:Refresh()
        ns:ProfileStop("GuildBank.tabswitch")
    end
end

-- Called when tab info updates (also when tabs are purchased)
ns.OnGuildBankTabsUpdated = function()
    if frame and frame:IsShown() then
        -- Reset purchase prompt state when tabs change (e.g., after purchase)
        showingPurchasePrompt = false
        -- Full refresh to handle purchase prompt visibility and tab changes
        GuildBankFrame:Refresh()
        GuildBankFrame:ShowSideTabs()
    end
end

-- Called when guild bank money changes
ns.OnGuildBankMoneyUpdated = function()
    if frame and frame:IsShown() then
        GuildBankFooter:UpdateMoney()
        GuildBankFooter:UpdateWithdrawInfo()
    end
end

-------------------------------------------------
-- Settings Change Handler
-------------------------------------------------

-- Settings that only need appearance update
local appearanceSettings = {
    bgAlpha = true,
    showBorders = true,
    theme = true,
    retailEmptySlots = true,
    minimalEmptySlots = true,
}

-- Handle setting changes (live update)
local function OnSettingChanged(event, key, value)
    if not frame or not frame:IsShown() then return end

    if appearanceSettings[key] then
        UpdateFrameAppearance()  -- no rebuild here, so restyle the buttons
    elseif key == "guildBankColumns" or key == "iconSize" or key == "iconSpacing" then
        -- Column/size changes need full refresh
        UpdateFrameAppearance(true)  -- Refresh below restyles buttons
        GuildBankFrame:Refresh()
    elseif key == "showFooter" or key == "showSearchBar" or key == "showFilterChips" then
        UpdateFrameAppearance(true)  -- Refresh below restyles buttons
        GuildBankFrame:Refresh()
    end
end

Events:Register("SETTING_CHANGED", OnSettingChanged, GuildBankFrame)

Events:Register("PROFILE_LOADED", function()
    if frame and frame:IsShown() then
        UpdateFrameAppearance(true)  -- Refresh below restyles buttons
        GuildBankFrame:Refresh()
    end
end, GuildBankFrame)

-- Combat start: release the retained (held-while-hidden) buttons so an in-combat bag
-- open can reuse the shared ItemButton pool without creating new secure frames
-- (forbidden in combat). Releasing uses SetShown — combat-safe. The guild bank is
-- only reopened out of combat, so it simply reuses/rebuilds next time.
Events:Register("PLAYER_REGEN_DISABLED", function()
    GuildBankFrame:ReleaseHeld()
end, "GuildBankFrame.CombatPoolRelease")
