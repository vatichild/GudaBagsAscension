local addonName, ns = ...

local BankFrame = {}
ns:RegisterModule("BankFrame", BankFrame)

local Constants = ns.Constants
local Database = ns:GetModule("Database")
local Events = ns:GetModule("Events")
local Font = ns:GetModule("Font")
local BankScanner = ns:GetModule("BankScanner")
local ItemButton = ns:GetModule("ItemButton")
local SearchBar = ns:GetModule("SearchBar")
local BagClassifier = ns:GetModule("BagFrame.BagClassifier")
local LayoutEngine = ns:GetModule("BagFrame.LayoutEngine")
local Utils = ns:GetModule("Utils")
local CategoryHeaderPool = ns:GetModule("CategoryHeaderPool")
local Theme = ns:GetModule("Theme")

local BankHeader = nil
local BankFooter = nil
local RetailBankScanner = nil

local frame
local searchBar
local itemButtons = {}
local categoryHeaders = {}
local viewingCharacter = nil

-- Combat lockdown handling
-- ContainerFrameItemButtonTemplate is a secure template that cannot be created during combat
local pendingAction = nil  -- "show" or nil
local combatLockdownRegistered = false

-- Layout caching for incremental updates (same pattern as BagFrame)
local buttonsBySlot = {}  -- Key: "bagID:slot" -> button reference
local buttonsByBag = {}   -- Key: bagID -> { slot -> button } for fast bag-specific lookups
local cachedItemData = {} -- Key: "bagID:slot" -> previous itemID (for comparison)
local cachedItemCount = {} -- Key: "bagID:slot" -> previous count (for stack updates)
local cachedItemCategory = {} -- Key: "bagID:slot" -> previous categoryId (for category view)
-- cachedItemCharges values: number (charges remaining), false (scanned, no charges), nil (unknown)
-- The `false` sentinel lets reused-button refresh skip GetCharges for non-charge items.
local cachedItemCharges = {} -- Key: "bagID:slot" -> previous charges value
local layoutCached = false -- True when layout is cached and can do incremental updates
local lastLayoutSettings = nil  -- Delta tracking for layout recalculation

-- In-place button reuse across a single/split refresh (tab switch, type switch).
-- Instead of releasing every button and re-acquiring (the expensive teardown +
-- Masque re-register churn), we keep the buttons and re-drive them via SetItem.
-- Surplus buttons (when a tab has fewer slots) are "parked" — hidden but kept
-- acquired — so the next refresh reuses them with no ResetButton/Masque churn on
-- either shrink or grow. Parked buttons are fully released only on a full teardown
-- (category view, view-type change) or on Hide.
local bankRecycle = nil      -- array of buttons available to reuse this refresh
local bankRecycleIdx = 0      -- how many have been handed out
local bankParked = {}         -- hidden surplus buttons kept for reuse
local lastRefreshViewType = nil  -- force a full release when the view type changes

-- Persist-across-close: keep the rendered bank view when the banker closes so the
-- next open is a smooth incremental update instead of a full rebuild (first open
-- still rebuilds). Released when stale or when another pool consumer needs the
-- shared buttons. Mirrors the bag frame's heldHidden/CanFastReopen/ReleaseHeld.
local bankHeld = false             -- frame hidden but buttons/layout retained
local bankDirtyWhileHidden = false -- view/settings changed since being hidden
local lastRenderSig = nil          -- view signature (viewType:bankType:tab) last rendered

-- Signature of the currently-intended view: a retained layout is only reusable
-- when the view type, bank type (character/warband) and selected tab all match
-- what was last rendered. On reopen the banker resets to character/All, so a fast
-- reopen happens when the user left it in that (default) state.
local function ComputeBankRenderSig()
    local viewType = Database:GetSetting("bankViewType") or "single"
    local bankType = (BankFooter and BankFooter:GetCurrentBankType()) or "character"
    local selectedTab = (ns.IsRetail and RetailBankScanner and RetailBankScanner:GetSelectedTab()) or 0
    return viewType .. ":" .. bankType .. ":" .. tostring(selectedTab)
end

-- Category View: Item-key-based button tracking
local buttonsByItemKey = {}
local categoryViewItems = {}
local lastCategoryLayout = nil
local lastButtonByCategory = {} -- Key: categoryId -> last item button (for drop indicator anchor)
local pseudoItemButtons = {} -- Track Empty/Soul pseudo-item buttons for proper release
                             -- Keys are "Empty:<categoryId>" or "Soul:<categoryId>" to avoid overwrites in merged groups
local lastTotalItemCount = 0 -- Track item count to detect Empty/Soul category changes

-- Helper to find a pseudo-item button by type (Empty or Soul)
local function FindPseudoItemButton(pseudoType)
    local prefix = pseudoType .. ":"
    for key, button in pairs(pseudoItemButtons) do
        if string.sub(key, 1, #prefix) == prefix then
            return button
        end
    end
    return nil
end

-- Use shared utility functions for key generation
local function GetItemKey(itemData)
    return Utils:GetItemKey(itemData)
end

local function GetSlotKey(bagID, slot)
    return Utils:GetSlotKey(bagID, slot)
end

-- Lazily resolved TooltipScanner reference, cached after first lookup.
local _tooltipScannerCached
local function GetTooltipScanner()
    if _tooltipScannerCached == nil then
        _tooltipScannerCached = ns:GetModule("TooltipScanner") or false
    end
    return _tooltipScannerCached or nil
end

-- Populate cachedItemCharges for a slot whose button was just (re)rendered via
-- ItemButton:SetItem. Stores number, false (scanned/no charges), or nil (cleared).
local function CacheChargesForSlot(slotKey, bagID, slot)
    if not Database:GetSetting("showCharges") then
        cachedItemCharges[slotKey] = nil
        return
    end
    local TS = GetTooltipScanner()
    if not TS then
        cachedItemCharges[slotKey] = nil
        return
    end
    cachedItemCharges[slotKey] = TS:GetCharges(bagID, slot) or false
end

-- Refresh the chargesText overlay on a button whose item didn't change identity
-- but may have had its charge count change. Short-circuits if the slot is known
-- to have no charges, so this is free for non-charge items.
local function RefreshChargesForReusedButton(button, bagID, slot, slotKey)
    local cachedCharges = cachedItemCharges[slotKey]
    if cachedCharges == false then return end
    if not Database:GetSetting("showCharges") then return end
    local TS = GetTooltipScanner()
    if not TS then return end
    local newCharges = TS:GetCharges(bagID, slot) or false
    if newCharges == cachedCharges then return end
    cachedItemCharges[slotKey] = newCharges
    if button.chargesText then
        if type(newCharges) == "number" and newCharges > 0 then
            button.chargesText:SetText("x" .. newCharges)
            button.chargesText:Show()
        else
            button.chargesText:Hide()
        end
    end
end

-- Hidden frame to reparent Blizzard bank UI
local hiddenParent = CreateFrame("Frame")
hiddenParent:Hide()

local function LoadComponents()
    BankHeader = ns:GetModule("BankFrame.BankHeader")
    BankFooter = ns:GetModule("BankFrame.BankFooter")
    if ns.IsRetail then
        RetailBankScanner = ns:GetModule("RetailBankScanner")
    end
end

-------------------------------------------------
-- Category Header Pool (uses shared CategoryHeaderPool module)
-------------------------------------------------

local function AcquireCategoryHeader(parent)
    return CategoryHeaderPool:Acquire(parent)
end

local function ReleaseAllCategoryHeaders()
    if frame and frame.container then
        CategoryHeaderPool:ReleaseAll(frame.container)  -- Pass owner to release only this frame's headers
    end
    categoryHeaders = {}
end

-------------------------------------------------
-- Container Drop Handling (empty space acts as drop zone)
-------------------------------------------------

-- Handle drops on empty space in the bank container
function BankFrame:HandleContainerDrop()
    local infoType, itemID = GetCursorInfo()
    if infoType ~= "item" or not itemID then return end

    -- Determine which bank type we're viewing (character or warband)
    local currentBankType = BankFooter and BankFooter:GetCurrentBankType() or "character"
    local isWarband = currentBankType == "warband"

    -- Find an empty bank slot and place the item there
    -- Build bank bag list based on game version and bank type
    local bankBags = {}

    if isWarband and Constants.WARBAND_BANK_TAB_IDS and #Constants.WARBAND_BANK_TAB_IDS > 0 then
        -- Warband bank tabs
        for _, tabID in ipairs(Constants.WARBAND_BANK_TAB_IDS) do
            table.insert(bankBags, tabID)
        end
    elseif Constants.CHARACTER_BANK_TAB_IDS and #Constants.CHARACTER_BANK_TAB_IDS > 0 then
        -- Modern Retail (12.0+) Character Bank Tabs
        for _, tabID in ipairs(Constants.CHARACTER_BANK_TAB_IDS) do
            table.insert(bankBags, tabID)
        end
    elseif Enum and Enum.BagIndex and Enum.BagIndex.Bank then
        -- Older Retail fallback
        table.insert(bankBags, Enum.BagIndex.Bank)
        if Enum.BagIndex.BankBag_1 then
            for i = Enum.BagIndex.BankBag_1, Enum.BagIndex.BankBag_7 do
                table.insert(bankBags, i)
            end
        end
    else
        -- Classic fallback
        if BANK_CONTAINER then
            table.insert(bankBags, BANK_CONTAINER)
        end
        if NUM_BANKBAGSLOTS then
            for i = NUM_BAG_SLOTS + 1, NUM_BAG_SLOTS + NUM_BANKBAGSLOTS do
                table.insert(bankBags, i)
            end
        end
    end

    local placed = false
    for _, bagID in ipairs(bankBags) do
        local numSlots = C_Container.GetContainerNumSlots(bagID)
        if numSlots and numSlots > 0 then
            for slot = 1, numSlots do
                local itemInfo = C_Container.GetContainerItemInfo(bagID, slot)
                if not itemInfo then
                    -- Empty slot found, place item here
                    C_Container.PickupContainerItem(bagID, slot)
                    placed = true
                    break
                end
            end
        end
        if placed then break end
    end

    -- If no empty slot found, just clear cursor
    if not placed then
        ClearCursor()
    end
end

local UpdateFrameAppearance
local SaveFramePosition
local RestoreFramePosition
local RegisterCombatEndCallback

-- Transient search bar visibility (header toggle). Resets on Hide().
-- Installs IsSearchBarVisible / ToggleSearchBar / ResetSearchToggle methods on BankFrame.
ns:GetModule("SearchBarToggle"):Apply(BankFrame, {
    getFrame = function() return frame end,
    onChanged = function()
        UpdateFrameAppearance(true)  -- Refresh below restyles buttons
        BankFrame:Refresh()
    end,
})

local function CreateBankFrame()
    local f = CreateFrame("Frame", "GudaBankFrame", UIParent, "BackdropTemplate")
    f:SetSize(400, 300)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("HIGH")
    f:SetFrameLevel(Constants.FRAME_LEVELS.BASE)
    f:EnableMouse(true)

    -- Raise frame above BagFrame when clicked
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
            -- Also lower BagFrame's secure container (it's parented to UIParent, not BagFrame)
            if bagFrame.container then
                bagFrame.container:SetFrameLevel(Constants.FRAME_LEVELS.BASE + Constants.FRAME_LEVELS.CONTAINER)
                ItemButton:SyncFrameLevels(bagFrame.container)
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
    tinsert(UISpecialFrames, "GudaBankFrame")

    -- Close bank interaction and reset character when frame is hidden
    f:SetScript("OnHide", function()
        if ns.IsRetail then
            if C_PlayerInteractionManager and C_PlayerInteractionManager.ClearInteraction then
                C_PlayerInteractionManager.ClearInteraction(Enum.PlayerInteractionType.Banker)
            end
        else
            if CloseBankFrame then
                CloseBankFrame()
            end
        end
        -- Clear search bar text and filters
        SearchBar:Clear(f)
        -- Reset to current character when bank closes
        if viewingCharacter then
            viewingCharacter = nil
            BankHeader:SetViewingCharacter(nil, nil)
        end
        -- Close any open character dropdown
        local BankCharactersModule = ns:GetModule("BankFrame.BankCharacters")
        if BankCharactersModule then
            BankCharactersModule:Hide()
        end
    end)

    f.titleBar = BankHeader:Init(f)
    BankHeader:SetDragCallback(SaveFramePosition)

    searchBar = SearchBar:Init(f)
    SearchBar:SetSearchCallback(f, function(text)
        BankFrame:Refresh()
    end)
    f.searchBar = searchBar

    -- Transfer button callbacks (bank → bags)
    SearchBar:SetTransferTargetCallback(f, function()
        return {type = "bags", label = ns.L["TRANSFER_TO_BAGS"]}
    end)

    SearchBar:SetTransferCallback(f, function()
        BankFrame:TransferMatchedItems()
    end)

    -- Create scroll frame for large bank contents
    local scrollFrame = CreateFrame("ScrollFrame", "GudaBankScrollFrame", f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", Constants.FRAME.PADDING, -(Constants.FRAME.TITLE_HEIGHT + SearchBar:GetTotalHeight(f) + Constants.FRAME.PADDING + 6))
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -Constants.FRAME.PADDING - 20, Constants.FRAME.FOOTER_HEIGHT + Constants.FRAME.PADDING)
    f.scrollFrame = scrollFrame

    -- Style the scroll bar
    local scrollBar = scrollFrame.ScrollBar or _G[scrollFrame:GetName() and (scrollFrame:GetName() .. "ScrollBar")]
    if scrollBar then
        scrollBar:SetAlpha(0.7)
    end

    -- Create container as scroll child
    local container = CreateFrame("Frame", "GudaBankContainer", scrollFrame)
    container:SetSize(1, 1)  -- Will be resized based on content
    scrollFrame:SetScrollChild(container)
    f.container = container
    f.container.masqueGroup = "Bank"

    -- Enable container as drop zone for empty space
    container:EnableMouse(true)

    container:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
            BankFrame:HandleContainerDrop()
        end
    end)

    container:SetScript("OnReceiveDrag", function(self)
        BankFrame:HandleContainerDrop()
    end)

    local emptyMessage = CreateFrame("Frame", nil, f)
    emptyMessage:SetAllPoints(scrollFrame)
    emptyMessage:Hide()

    local emptyText = emptyMessage:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    emptyText:SetPoint("CENTER", emptyMessage, "CENTER", 0, 10)
    emptyText:SetTextColor(0.6, 0.6, 0.6)
    emptyText:SetText(ns.L["BANK_NO_DATA"])
    emptyMessage.text = emptyText

    local emptyHint = emptyMessage:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    emptyHint:SetPoint("TOP", emptyText, "BOTTOM", 0, -8)
    emptyHint:SetTextColor(0.5, 0.5, 0.5)
    emptyHint:SetText(ns.L["BANK_VISIT_BANKER"])
    emptyMessage.hint = emptyHint

    f.emptyMessage = emptyMessage

    -- Purchase tab prompt (shown when "+" tab is clicked)
    if ns.IsRetail then
        local purchasePrompt = CreateFrame("Frame", nil, f)
        purchasePrompt:SetAllPoints(scrollFrame)
        purchasePrompt:Hide()

        -- Title (Bank or Warband Bank)
        local promptTitle = purchasePrompt:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        promptTitle:SetPoint("CENTER", purchasePrompt, "CENTER", 0, 80)
        promptTitle:SetTextColor(1, 0.82, 0)
        purchasePrompt.promptTitle = promptTitle

        -- Description text
        local promptDesc = purchasePrompt:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        promptDesc:SetPoint("TOP", promptTitle, "BOTTOM", 0, -16)
        promptDesc:SetTextColor(0.8, 0.8, 0.8)
        promptDesc:SetWidth(350)
        promptDesc:SetJustifyH("CENTER")
        purchasePrompt.promptDesc = promptDesc

        -- "Do you wish to purchase this tab?"
        local promptQuestion = purchasePrompt:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        promptQuestion:SetPoint("TOP", promptDesc, "BOTTOM", 0, -16)
        promptQuestion:SetTextColor(0.9, 0.9, 0.9)
        promptQuestion:SetText(ns.L["BANK_PURCHASE_PROMPT"])
        purchasePrompt.promptQuestion = promptQuestion

        -- Tabs purchased counter
        local tabsText = purchasePrompt:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        tabsText:SetPoint("TOP", promptQuestion, "BOTTOM", 0, -12)
        tabsText:SetTextColor(0.8, 0.8, 0.8)
        purchasePrompt.tabsText = tabsText

        -- Cost display
        local costFrame = CreateFrame("Frame", nil, purchasePrompt)
        costFrame:SetSize(100, 24)
        costFrame:SetPoint("TOP", tabsText, "BOTTOM", -40, -16)
        purchasePrompt.costFrame = costFrame

        local costLabel = costFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        costLabel:SetPoint("LEFT", costFrame, "LEFT", 0, 0)
        costLabel:SetTextColor(0.8, 0.8, 0.8)
        costLabel:SetText(ns.L["BANK_PURCHASE_COST"])
        purchasePrompt.costLabel = costLabel

        local costValue = costFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        costValue:SetPoint("LEFT", costLabel, "RIGHT", 8, 0)
        costValue:SetTextColor(1, 1, 1)
        purchasePrompt.costValue = costValue

        -- Purchase button (uses Blizzard's secure template to call protected C_Bank.PurchaseBankTab)
        local purchaseBtn = CreateFrame("Button", "GudaBankPurchaseBtn", purchasePrompt, "UIPanelButtonTemplate,BankPanelPurchaseButtonScriptTemplate")
        purchaseBtn:SetSize(120, 28)
        purchaseBtn:SetPoint("LEFT", costFrame, "RIGHT", 15, 0)
        purchaseBtn:SetText(ns.L["BANK_PURCHASE_TAB"])
        purchaseBtn:RegisterForClicks("AnyUp")
        purchasePrompt.purchaseBtn = purchaseBtn

        purchaseBtn:SetScript("OnEnter", function(self)
            if self.insufficientFunds then
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:SetText(ns.L["BANK_PURCHASE_NOT_ENOUGH_GOLD"], 1, 0.3, 0.3)
                GameTooltip:Show()
            end
        end)
        purchaseBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

        f.purchasePrompt = purchasePrompt
    end

    f.footer = BankFooter:Init(f)
    BankFooter:SetBackCallback(function()
        BankFrame:ViewCharacter(nil, nil)
    end)

    -- Set bank character callback (for characters dropdown in BankHeader)
    BankHeader:SetCharacterCallback(function(fullName, charData)
        if not BankFrame:IsShown() then
            BankFrame:Show()
        end
        BankFrame:ViewCharacter(fullName, charData)
    end)

    -- Create side tab bar for Retail bank tabs (vertical, on right side outside frame)
    if ns.IsRetail then
        local sideTabBar = CreateFrame("Frame", "GudaBankSideTabBar", f)
        sideTabBar:SetPoint("TOPLEFT", f, "TOPRIGHT", 0, -55)
        sideTabBar:SetSize(32, 200)  -- Will resize based on tabs
        sideTabBar:Hide()  -- Hidden until tabs are shown
        f.sideTabBar = sideTabBar
        f.sideTabs = {}
    end

    -- Create bottom bank type tabs (Bank | Warband) - Retail only
    if ns.IsRetail and Constants.WARBAND_BANK_ACTIVE then
        f.bottomTabs = {}
        f.bottomTabBar = CreateFrame("Frame", "GudaBankBottomTabBar", f)
        f.bottomTabBar:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 8, 0)
        f.bottomTabBar:SetSize(200, 28)
        f.bottomTabBar:Hide()
    end

    Font:RegisterFrame(f)
    return f
end

-------------------------------------------------
-- Side Tab Bar (Retail Bank Tabs - Vertical on Right)
-------------------------------------------------

local TAB_SIZE = 36
local TAB_SPACING = 2
local showingPurchasePrompt = false

local function CreateSideTab(parent, index, isAllTab)
    local button = CreateFrame("Button", "GudaBankSideTab" .. (isAllTab and "All" or index), parent, "BackdropTemplate")
    button:SetSize(TAB_SIZE, TAB_SIZE)
    button.tabIndex = isAllTab and 0 or index

    button:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = {left = 3, right = 3, top = 3, bottom = 3},
    })
    button:SetBackdropColor(0.15, 0.15, 0.15, 0.9)
    button:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.7)

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(TAB_SIZE - 6, TAB_SIZE - 6)
    icon:SetPoint("CENTER")
    if isAllTab then
        icon:SetTexture("Interface\\AddOns\\GudaBags\\Assets\\bags.tga")
    else
        icon:SetTexture("Interface\\Icons\\INV_Misc_Bag_10")
    end
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)  -- Crop icon border
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

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        local scanner = ns:GetModule("RetailBankScanner")

        if self.tabIndex == 0 then
            -- "All Tabs" - show combined total
            GameTooltip:SetText(ns.L["TOOLTIP_BANK_ALL_TABS"] or "All Tabs")
            if scanner then
                local totalSlots, occupiedSlots = 0, 0
                local bankType = scanner:GetCurrentBankType()
                local tabs = scanner:GetBankTabs(bankType)
                if tabs then
                    for _, tab in ipairs(tabs) do
                        local containerID = scanner:GetTabContainerID(tab.tabIndex, bankType)
                        if containerID then
                            local numSlots = C_Container.GetContainerNumSlots(containerID)
                            totalSlots = totalSlots + numSlots
                            for slot = 1, numSlots do
                                local itemInfo = C_Container.GetContainerItemInfo(containerID, slot)
                                if itemInfo then
                                    occupiedSlots = occupiedSlots + 1
                                end
                            end
                        end
                    end
                end
                if totalSlots > 0 then
                    GameTooltip:AddLine(string.format("%d / %d", occupiedSlots, totalSlots), 0.7, 0.7, 0.7)
                end
            end
        else
            -- Specific tab - show that tab's slots
            if self.tabName then
                GameTooltip:SetText(self.tabName)
            else
                GameTooltip:SetText(string.format(ns.L["TOOLTIP_BANK_TAB"] or "Tab %d", self.tabIndex))
            end
            if scanner then
                local containerID = scanner:GetTabContainerID(self.tabIndex)
                if containerID then
                    local numSlots = C_Container.GetContainerNumSlots(containerID)
                    local occupiedSlots = 0
                    for slot = 1, numSlots do
                        local itemInfo = C_Container.GetContainerItemInfo(containerID, slot)
                        if itemInfo then
                            occupiedSlots = occupiedSlots + 1
                        end
                    end
                    GameTooltip:AddLine(string.format("%d / %d", occupiedSlots, numSlots), 0.7, 0.7, 0.7)
                end
            end
        end
        -- Right-click hint for non-All tabs when bank is open
        if self.tabIndex > 0 and RetailBankScanner and RetailBankScanner:IsBankOpen() then
            GameTooltip:AddLine(ns.L["GUILD_BANK_RIGHT_CLICK_EDIT"] or "Right-click to edit", 0.5, 0.5, 0.5)
        end
        GameTooltip:Show()

        -- Skip hover highlighting if a specific tab is already selected (not "All")
        local scanner = ns:GetModule("RetailBankScanner")
        local selectedTab = scanner and scanner:GetSelectedTab() or 0
        if selectedTab ~= 0 then
            return  -- A single tab is already shown, no need to highlight
        end

        -- Highlight items from this tab (only when viewing "All" tabs)
        local ItemButton = ns:GetModule("ItemButton")
        if ItemButton and scanner and frame and frame.container and self.tabIndex > 0 then
            -- Convert tab index to container ID for retail bank (uses scanner's current bank type)
            local containerID = scanner:GetTabContainerID(self.tabIndex)
            if containerID then
                ItemButton:HighlightBagSlots(containerID, frame.container)
            end
        end
    end)

    button:SetScript("OnLeave", function(self)
        GameTooltip:Hide()

        -- Reset item highlighting (only if we were highlighting)
        local scanner = ns:GetModule("RetailBankScanner")
        local selectedTab = scanner and scanner:GetSelectedTab() or 0
        if selectedTab ~= 0 then
            return  -- A single tab is already shown, nothing to reset
        end

        local ItemButton = ns:GetModule("ItemButton")
        if ItemButton and frame and frame.container then
            ItemButton:ResetAllAlpha(frame.container)
        end
    end)

    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:SetScript("OnClick", function(self, mouseButton)
        -- Reset purchase prompt state when clicking on regular tabs
        showingPurchasePrompt = false

        if RetailBankScanner then
            -- Right-click on purchased tab: toggle Blizzard tab settings (icon/name/deposit)
            if mouseButton == "RightButton" and self.tabIndex > 0 then
                ns:Debug("Right-click on tab", self.tabIndex, "containerID:", self.containerID, "bankOpen:", RetailBankScanner:IsBankOpen())
                if self.containerID and RetailBankScanner:IsBankOpen() then
                    if frame.tabSettingsMenu and frame.tabSettingsMenu:IsShown() and frame.tabSettingsMenu.currentContainerID == self.containerID then
                        frame.tabSettingsMenu:Hide()
                    else
                        BankFrame:OpenTabSettings(self.containerID, self.tabIndex)
                    end
                end
                return
            end

            local currentTab = RetailBankScanner:GetSelectedTab()
            if currentTab == self.tabIndex then
                -- Clicking same tab - show all
                if self.tabIndex ~= 0 then
                    RetailBankScanner:SetSelectedTab(0)
                end
            else
                RetailBankScanner:SetSelectedTab(self.tabIndex)
            end
            -- SetSelectedTab fires ns.OnRetailBankTabChanged which already updates the
            -- tab selection visuals and refreshes — no direct Refresh here (it would be
            -- a second full rebuild). UpdateSideTabSelection covers the no-op edge case
            -- (clicking "All" while already on All, where SetSelectedTab isn't called).
            BankFrame:UpdateSideTabSelection()
        end
    end)

    return button
end

-- Tab icons
local TAB_ICON_DEFAULT = "Interface\\Icons\\INV_Misc_Bag_10"  -- Default fallback icon

-- Purchase tab button for buying new bank/warband tabs
local function CreatePurchaseTab(parent, bankTypeEnum)
    local button = CreateFrame("Button", "GudaBankPurchaseTab", parent, "BackdropTemplate")
    button:SetSize(TAB_SIZE, TAB_SIZE)
    button.isPurchaseTab = true

    button:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = {left = 3, right = 3, top = 3, bottom = 3},
    })
    button:SetBackdropColor(0.15, 0.15, 0.15, 0.9)
    button:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.7)

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(TAB_SIZE - 8, TAB_SIZE - 8)
    icon:SetPoint("CENTER")
    icon:SetTexture("Interface\\AddOns\\GudaBags\\Assets\\plus.tga")
    button.icon = icon

    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    highlight:SetBlendMode("ADD")

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText(ns.L["TOOLTIP_PURCHASE_TAB"] or "Purchase New Tab")
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    button:SetScript("OnClick", function(self)
        showingPurchasePrompt = true
        if RetailBankScanner then
            RetailBankScanner:SetSelectedTab(0)
        end
        BankFrame:UpdateSideTabSelection()
        BankFrame:ShowPurchasePrompt(self.bankTypeEnum)
    end)

    return button
end

-- Show purchase prompt page (replaces bank content with purchase UI)
function BankFrame:ShowPurchasePrompt(bankTypeEnum)
    if not frame or not frame.purchasePrompt then return end

    -- Hide normal content
    frame.container:Hide()
    frame.emptyMessage:Hide()
    frame.scrollFrame:EnableMouseWheel(false)

    local prompt = frame.purchasePrompt
    -- Both sides are nil where Enum.BankType doesn't exist (3.3.5a), and nil ==
    -- nil is true -- which wrongly labelled the character bank as a warband bank.
    local accountBankType = Enum and Enum.BankType and Enum.BankType.Account
    local isWarband = accountBankType ~= nil and bankTypeEnum == accountBankType

    -- Set title and description based on bank type
    if isWarband then
        prompt.promptTitle:SetText(ns.L["BANK_TITLE_WARBAND"])
        prompt.promptDesc:SetText(ns.L["BANK_DESC_WARBAND"])
    else
        prompt.promptTitle:SetText(ns.L["BANK_TITLE_CHARACTER"])
        prompt.promptDesc:SetText(ns.L["BANK_DESC_CHARACTER"])
    end

    -- Update tabs purchased counter
    local scanner = ns:GetModule("RetailBankScanner")
    if prompt.tabsText then
        local numPurchased = scanner and scanner:GetNumPurchasedTabs(bankTypeEnum) or 0
        local maxTabs = isWarband
            and #(Constants.WARBAND_BANK_TAB_IDS or {})
            or #(Constants.CHARACTER_BANK_TAB_IDS or {})
        if maxTabs == 0 then maxTabs = isWarband and 5 or 6 end
        prompt.tabsText:SetText(string.format(ns.L["BANK_TABS_PURCHASED"], numPurchased, maxTabs))
    end

    -- Get cost (use newer FetchNextPurchasableBankTabData API with fallback)
    local cost
    if C_Bank and C_Bank.FetchNextPurchasableBankTabData then
        local tabData = C_Bank.FetchNextPurchasableBankTabData(bankTypeEnum)
        cost = tabData and tabData.tabCost
    elseif scanner then
        cost = scanner:GetTabPurchaseCost(bankTypeEnum)
    end
    local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:12|t"

    -- Set the bank type attribute for the secure purchase button template
    prompt.purchaseBtn:SetAttribute("overrideBankType", bankTypeEnum)

    if cost and cost > 0 then
        local gold = math.floor(cost / 10000)
        prompt.costValue:SetText(string.format("%s %s", gold, GOLD_ICON))
        prompt.costFrame:Show()
        prompt.purchaseBtn:ClearAllPoints()
        prompt.purchaseBtn:SetPoint("LEFT", prompt.costFrame, "RIGHT", 20, 0)

        local playerMoney = GetMoney and GetMoney() or 0
        prompt.purchaseBtn.insufficientFunds = playerMoney < cost

        if playerMoney < cost then
            prompt.costValue:SetTextColor(1, 0.3, 0.3)
            prompt.purchaseBtn:Disable()
        else
            prompt.costValue:SetTextColor(1, 1, 1)
            prompt.purchaseBtn:Enable()
        end

        prompt.purchaseBtn:Show()
    else
        -- Cost not available yet or API returned nil — still show button
        prompt.costFrame:Hide()
        prompt.purchaseBtn:ClearAllPoints()
        prompt.purchaseBtn:SetPoint("TOP", prompt.tabsText or prompt.promptQuestion, "BOTTOM", 0, -20)
        prompt.purchaseBtn.insufficientFunds = false
        prompt.purchaseBtn:Enable()
        prompt.purchaseBtn:Show()
    end

    -- Select the purchase tab visually
    prompt:Show()

    -- Set frame to minimum size for purchase prompt
    frame:SetSize(math.max(frame:GetWidth(), 380), math.max(frame:GetHeight(), (ns.IsRetail and Constants.FRAME.BANK_MIN_HEIGHT_RETAIL or Constants.FRAME.BANK_MIN_HEIGHT)))
end

-- Hide purchase prompt and restore normal content
function BankFrame:HidePurchasePrompt()
    showingPurchasePrompt = false
    if not frame then return end
    if frame.purchasePrompt then
        frame.purchasePrompt:Hide()
    end
    if frame.purchaseTab then
        frame.purchaseTab:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.7)
    end
    -- Restore scroll frame state
    if frame.scrollFrame then
        frame.scrollFrame:EnableMouseWheel(true)
    end
end

function BankFrame:ShowSideTabs(characterFullName, bankType)
    if not frame or not frame.sideTabBar then return end
    if not ns.IsRetail then return end

    -- Get bank type from footer if not specified
    bankType = bankType or (BankFooter and BankFooter:GetCurrentBankType()) or "character"
    local isWarband = bankType == "warband"

    ns:Debug("ShowSideTabs - bankType:", bankType, "isWarband:", tostring(isWarband))

    local tabs = {}

    -- Get the appropriate tab container IDs based on bank type
    local tabContainerIDs = isWarband and Constants.WARBAND_BANK_TAB_IDS or Constants.CHARACTER_BANK_TAB_IDS
    local tabsActive = isWarband and Constants.WARBAND_BANK_ACTIVE or Constants.CHARACTER_BANK_TABS_ACTIVE

    ns:Debug("  tabContainerIDs count:", tabContainerIDs and #tabContainerIDs or 0)
    ns:Debug("  tabsActive:", tostring(tabsActive))

    -- Try to get cached tabs from RetailBankScanner first
    if RetailBankScanner then
        local bankTypeEnum = isWarband and Enum.BankType.Account or Enum.BankType.Character
        local cachedTabs = RetailBankScanner:GetCachedBankTabs(bankTypeEnum)
        if cachedTabs and #cachedTabs > 0 then
            for _, tabData in ipairs(cachedTabs) do
                table.insert(tabs, {
                    index = tabData.index,
                    containerID = tabData.containerID,
                    name = tabData.name or (isWarband and string.format("Warband Tab %d", tabData.index) or string.format(ns.L["TOOLTIP_BANK_TAB"] or "Tab %d", tabData.index)),
                    icon = tabData.icon or TAB_ICON_DEFAULT,  -- Use tab's actual icon
                })
            end
            ns:Debug("  Got", #tabs, "tabs from RetailBankScanner cache")
        end
    end

    -- Fallback: For character bank, try Database
    if #tabs == 0 and not isWarband then
        tabs = Database:GetBankTabs(characterFullName) or {}
    end

    -- Fallback: For warband bank, try Database
    if #tabs == 0 and isWarband then
        local warbandTabs = Database:GetWarbandBankTabs()
        if warbandTabs and #warbandTabs > 0 then
            for _, tabData in ipairs(warbandTabs) do
                table.insert(tabs, {
                    index = tabData.index,
                    containerID = tabData.containerID,
                    name = tabData.name or string.format("Warband Tab %d", tabData.index),
                    icon = tabData.icon or TAB_ICON_DEFAULT,  -- Use tab's actual icon
                })
            end
            ns:Debug("  Got", #tabs, "tabs from Database warband cache")
        end
    end

    -- Fallback: For warband bank, try C_Bank.FetchPurchasedBankTabData directly
    if #tabs == 0 and isWarband and C_Bank and C_Bank.FetchPurchasedBankTabData then
        -- Check if warband bank is accessible (not locked)
        local warbandLocked = C_Bank.FetchBankLockedReason and C_Bank.FetchBankLockedReason(Enum.BankType.Account)
        ns:Debug("  Warband FetchBankLockedReason:", tostring(warbandLocked))
        if warbandLocked == nil then
            local tabData = C_Bank.FetchPurchasedBankTabData(Enum.BankType.Account)
            ns:Debug("  FetchPurchasedBankTabData returned:", tabData and #tabData or 0, "tabs")
            if tabData then
                for i, tab in ipairs(tabData) do
                    local containerID = Constants.WARBAND_BANK_TAB_IDS and Constants.WARBAND_BANK_TAB_IDS[i]
                    table.insert(tabs, {
                        index = i,
                        containerID = containerID,
                        name = tab.name or string.format("Warband Tab %d", i),
                        icon = tab.icon or TAB_ICON_DEFAULT,  -- Use tab's actual icon
                    })
                end
                ns:Debug("  Got", #tabs, "tabs from C_Bank.FetchPurchasedBankTabData")
            end
        end
    end

    -- Fallback: Generate tabs based on which containers have data (live check)
    if #tabs == 0 and tabsActive and tabContainerIDs then
        for i, containerID in ipairs(tabContainerIDs) do
            -- Check if this container has slots (either from live data or cached)
            local numSlots = C_Container.GetContainerNumSlots(containerID)
            ns:Debug("  Container", containerID, "numSlots:", numSlots or 0)

            if numSlots and numSlots > 0 then
                table.insert(tabs, {
                    index = i,
                    containerID = containerID,
                    name = isWarband
                        and string.format("Warband Tab %d", i)
                        or string.format(ns.L["TOOLTIP_BANK_TAB"] or "Tab %d", i),
                    icon = TAB_ICON_DEFAULT,
                })
            end
        end
    end

    -- Fallback: check normalized bank data if no live data (character bank only)
    if #tabs == 0 and not isWarband then
        local bankData = Database:GetNormalizedBank(characterFullName)
        if bankData and tabContainerIDs then
            for i, containerID in ipairs(tabContainerIDs) do
                if bankData[containerID] and bankData[containerID].numSlots and bankData[containerID].numSlots > 0 then
                    table.insert(tabs, {
                        index = i,
                        containerID = containerID,
                        name = string.format(ns.L["TOOLTIP_BANK_TAB"] or "Tab %d", i),
                        icon = TAB_ICON_DEFAULT,
                    })
                end
            end
        end
    end

    -- Fallback: check normalized warband bank data if no live data
    if #tabs == 0 and isWarband then
        local warbandData = Database:GetNormalizedWarbandBank()
        if warbandData and tabContainerIDs then
            for i, containerID in ipairs(tabContainerIDs) do
                if warbandData[containerID] and warbandData[containerID].numSlots and warbandData[containerID].numSlots > 0 then
                    table.insert(tabs, {
                        index = i,
                        containerID = containerID,
                        name = string.format("Warband Tab %d", i),
                        icon = TAB_ICON_DEFAULT,
                    })
                end
            end
        end
    end

    ns:Debug("  Final tabs count:", #tabs)

    local bankTypeEnum = isWarband
        and (Enum and Enum.BankType and Enum.BankType.Account)
        or (Enum and Enum.BankType and Enum.BankType.Character)
    local canPurchaseMore = bankTypeEnum
        and C_Bank and C_Bank.CanPurchaseBankTab and C_Bank.CanPurchaseBankTab(bankTypeEnum)
        and not (C_Bank.HasMaxBankTabs and C_Bank.HasMaxBankTabs(bankTypeEnum))

    -- No purchased tabs: show only purchase tab and auto-show purchase prompt
    if (not tabs or #tabs == 0) and RetailBankScanner and RetailBankScanner:IsBankOpen() and canPurchaseMore then
        -- Hide "All" tab and any existing side tabs
        if frame.sideTabs[0] then frame.sideTabs[0]:Hide() end
        for i = 1, #frame.sideTabs do
            if frame.sideTabs[i] then frame.sideTabs[i]:Hide() end
        end

        -- Show only the purchase tab
        if frame.purchaseTab and frame.purchaseTab.bankTypeEnum ~= bankTypeEnum then
            frame.purchaseTab:Hide()
            frame.purchaseTab = nil
        end
        if not frame.purchaseTab then
            frame.purchaseTab = CreatePurchaseTab(frame.sideTabBar, bankTypeEnum)
        end
        frame.purchaseTab.bankTypeEnum = bankTypeEnum
        frame.purchaseTab:SetAttribute("overrideBankType", bankTypeEnum)
        frame.purchaseTab:ClearAllPoints()
        frame.purchaseTab:SetPoint("TOP", frame.sideTabBar, "TOP", 0, 0)
        frame.purchaseTab:Show()

        frame.sideTabBar:SetSize(TAB_SIZE, TAB_SIZE + TAB_SPACING)
        frame.sideTabBar:Show()

        -- Auto-show purchase prompt
        showingPurchasePrompt = true
        self:UpdateSideTabSelection()
        self:ShowPurchasePrompt(bankTypeEnum)
        return
    end

    -- Default single tab if nothing found (offline/cached view)
    if not tabs or #tabs == 0 then
        tabs = {{
            index = 1,
            name = isWarband and "Warband Tab 1" or string.format(ns.L["TOOLTIP_BANK_TAB"] or "Tab %d", 1),
            icon = TAB_ICON_DEFAULT,
        }}
    end

    -- Hide side tabs if only 1 character bank tab AND no more can be purchased
    if #tabs <= 1 and not isWarband and not canPurchaseMore then
        frame.sideTabBar:Hide()
        return
    end

    -- Create "All" tab button first
    if not frame.sideTabs[0] then
        frame.sideTabs[0] = CreateSideTab(frame.sideTabBar, 0, true)
    end
    frame.sideTabs[0]:ClearAllPoints()
    frame.sideTabs[0]:SetPoint("TOP", frame.sideTabBar, "TOP", 0, 0)
    frame.sideTabs[0]:Show()

    local prevButton = frame.sideTabs[0]

    -- Create/update tab buttons
    for i, tabData in ipairs(tabs) do
        if not frame.sideTabs[i] then
            frame.sideTabs[i] = CreateSideTab(frame.sideTabBar, i, false)
        end

        local button = frame.sideTabs[i]
        button.tabIndex = i
        button.tabName = tabData.name
        button.containerID = tabData.containerID
        if tabData.icon then
            button.icon:SetTexture(tabData.icon)
            button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        end

        button:ClearAllPoints()
        button:SetPoint("TOP", prevButton, "BOTTOM", 0, -TAB_SPACING)
        button:Show()

        prevButton = button
    end

    -- Hide excess tabs
    for i = #tabs + 1, #frame.sideTabs do
        if frame.sideTabs[i] then
            frame.sideTabs[i]:Hide()
        end
    end

    -- Add "+" purchase tab if bank is open and more tabs can be purchased
    local tabCount = #tabs + 1  -- +1 for "All" tab
    if RetailBankScanner and RetailBankScanner:IsBankOpen() and canPurchaseMore then
        -- Recreate if bank type changed (secure template needs correct type at creation)
        if frame.purchaseTab and frame.purchaseTab.bankTypeEnum ~= bankTypeEnum then
            frame.purchaseTab:Hide()
            frame.purchaseTab = nil
        end
        if not frame.purchaseTab then
            frame.purchaseTab = CreatePurchaseTab(frame.sideTabBar, bankTypeEnum)
        end
        frame.purchaseTab.bankTypeEnum = bankTypeEnum
        if frame.purchaseTab.SetAttribute then
            frame.purchaseTab:SetAttribute("overrideBankType", bankTypeEnum)
        end
        frame.purchaseTab:ClearAllPoints()
        frame.purchaseTab:SetPoint("TOP", prevButton, "BOTTOM", 0, -TAB_SPACING)
        frame.purchaseTab:Show()
        tabCount = tabCount + 1
    else
        if frame.purchaseTab then frame.purchaseTab:Hide() end
    end

    -- Resize tab bar
    local totalHeight = (TAB_SIZE + TAB_SPACING) * tabCount
    frame.sideTabBar:SetSize(TAB_SIZE, totalHeight)

    -- Reset selection to "All"
    if RetailBankScanner then
        RetailBankScanner:SetSelectedTab(0)
    end

    frame.sideTabBar:Show()
    self:UpdateSideTabSelection()
end

function BankFrame:HideSideTabs()
    if frame and frame.sideTabBar then
        frame.sideTabBar:Hide()
        if frame.purchaseTab then frame.purchaseTab:Hide() end
    end
end

function BankFrame:UpdateSideTabSelection()
    if not frame or not frame.sideTabs then return end

    local selectedTab = RetailBankScanner and RetailBankScanner:GetSelectedTab() or 0

    for i, button in pairs(frame.sideTabs) do
        if button and button:IsShown() then
            if i == selectedTab and not showingPurchasePrompt then
                button:SetBackdropBorderColor(1, 0.82, 0, 1)
            else
                button:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.7)
            end
        end
    end

    -- Update purchase tab selection
    if frame.purchaseTab and frame.purchaseTab:IsShown() then
        if showingPurchasePrompt then
            frame.purchaseTab:SetBackdropBorderColor(0.3, 0.8, 0.3, 1)
        else
            frame.purchaseTab:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.7)
        end
    end
end

-- Open Blizzard's tab settings popup (icon/name/deposit flags) for a bank tab
function BankFrame:OpenTabSettings(containerID, tabIndex)
    if not frame then return end

    ns:Debug("OpenTabSettings - containerID:", containerID, "tabIndex:", tabIndex)

    -- Create the settings menu frame once (BankPanelTabSettingsMenuTemplate is an XML template)
    if not frame.tabSettingsMenu then
        local ok, menu = pcall(CreateFrame, "Frame", "GudaBankTabSettingsMenu", UIParent, "BankPanelTabSettingsMenuTemplate")
        if not ok or not menu then
            ns:Debug("OpenTabSettings - BankPanelTabSettingsMenuTemplate not available")
            return
        end
        menu:SetClampedToScreen(true)
        menu:SetFrameStrata("DIALOG")
        menu:Hide()
        frame.tabSettingsMenu = menu
    end

    local menu = frame.tabSettingsMenu
    local bankType = (BankFooter and BankFooter:GetCurrentBankType()) or "character"
    local isWarband = bankType == "warband"
    local bankTypeEnum = isWarband and Enum.BankType.Account or Enum.BankType.Character

    ns:Debug("OpenTabSettings - bankType:", bankType, "bankTypeEnum:", tostring(bankTypeEnum))

    -- Get tab info from scanner
    local scanner = ns:GetModule("RetailBankScanner")
    local cachedTabs = scanner and scanner:GetCachedBankTabs(bankTypeEnum)
    local tabInfo
    if cachedTabs then
        for _, t in ipairs(cachedTabs) do
            if t.containerID == containerID or t.index == tabIndex then
                tabInfo = t
                break
            end
        end
    end

    ns:Debug("OpenTabSettings - tabInfo found:", tabInfo ~= nil, "icon:", tabInfo and tabInfo.icon or "nil")

    -- Provide GetBankPanel/GetBankFrame so the template can read tab data
    local function makeBankPanel()
        return {
            GetTabData = function(tabID)
                return {
                    ID = containerID,
                    icon = tabInfo and tabInfo.icon or TAB_ICON_DEFAULT,
                    name = tabInfo and tabInfo.name or string.format("Tab %d", tabIndex),
                    depositFlags = tabInfo and tabInfo.depositFlags or 0,
                    bankType = bankTypeEnum,
                }
            end
        }
    end
    menu.GetBankPanel = makeBankPanel
    menu.GetBankFrame = makeBankPanel

    -- Track which tab is being edited for toggle support
    menu.currentContainerID = containerID

    -- Position next to the bank frame
    menu:ClearAllPoints()
    menu:SetPoint("LEFT", frame, "RIGHT", 30, 0)

    ns:Debug("OpenTabSettings - calling OnOpenTabSettingsRequested, menu methods:", menu.OnOpenTabSettingsRequested ~= nil, menu.OnNewBankTabSelected ~= nil)

    if menu:IsShown() then
        if menu.OnNewBankTabSelected then
            menu:OnNewBankTabSelected(containerID)
        end
    else
        if menu.OnOpenTabSettingsRequested then
            menu:OnOpenTabSettingsRequested(containerID)
        else
            ns:Debug("OpenTabSettings - OnOpenTabSettingsRequested not available on menu")
        end
    end
end

-------------------------------------------------
-- Bottom Bank Type Tabs (Bank | Warband - Below Frame)
-------------------------------------------------

local BOTTOM_TAB_WIDTH = 100
local BOTTOM_TAB_HEIGHT = 32
local BOTTOM_TAB_SPACING = 2

local function CreateBottomBankTypeTab(parent, bankType, label)
    local button = CreateFrame("Button", "GudaBankBottomTab" .. bankType, parent, "BackdropTemplate")
    button:SetSize(BOTTOM_TAB_WIDTH, BOTTOM_TAB_HEIGHT)
    button.bankType = bankType

    -- Create rounded bottom corners using a custom backdrop
    button:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = {left = 3, right = 3, top = 0, bottom = 3},
    })
    button:SetBackdropColor(0.08, 0.08, 0.08, 0.95)
    button:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

    -- Mask the top edge to blend with frame (create seamless connection)
    local topMask = button:CreateTexture(nil, "OVERLAY")
    topMask:SetPoint("TOPLEFT", button, "TOPLEFT", 1, 0)
    topMask:SetPoint("TOPRIGHT", button, "TOPRIGHT", -1, 0)
    topMask:SetHeight(3)
    topMask:SetColorTexture(0.08, 0.08, 0.08, 0.95)
    button.topMask = topMask

    -- Tab label
    local text = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("CENTER", 0, -1)
    text:SetText(label)
    text:SetTextColor(0.8, 0.8, 0.8)
    button.text = text

    -- Highlight
    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetPoint("TOPLEFT", 2, -2)
    highlight:SetPoint("BOTTOMRIGHT", -2, 2)
    highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    highlight:SetBlendMode("ADD")
    highlight:SetAlpha(0.3)

    -- Selection indicator (bottom glow)
    local selected = button:CreateTexture(nil, "BACKGROUND")
    selected:SetPoint("TOPLEFT", 2, -2)
    selected:SetPoint("BOTTOMRIGHT", -2, 2)
    selected:SetColorTexture(1, 0.82, 0, 0.2)
    selected:Hide()
    button.selected = selected

    button:SetScript("OnClick", function(self)
        local currentBankType = BankFooter and BankFooter:GetCurrentBankType() or "character"
        if currentBankType ~= self.bankType then
            if BankFooter then
                BankFooter:SetCurrentBankType(self.bankType)
            end
            BankFrame:UpdateBottomTabSelection()
            -- Notify BankFrame to refresh with new bank type
            if ns.OnBankTypeChanged then
                ns.OnBankTypeChanged(self.bankType)
            end
        end
    end)

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        if self.bankType == "character" then
            GameTooltip:SetText("Character Bank")
        else
            GameTooltip:SetText("Warband Bank")
        end
        GameTooltip:Show()
    end)

    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    return button
end

function BankFrame:ShowBottomTabs()
    if not frame or not frame.bottomTabBar then return end
    if not ns.IsRetail or not Constants.WARBAND_BANK_ACTIVE then return end

    -- Create tabs if they don't exist
    if not frame.bottomTabs.character then
        frame.bottomTabs.character = CreateBottomBankTypeTab(frame.bottomTabBar, "character", "Bank")
        frame.bottomTabs.character:SetPoint("TOPLEFT", frame.bottomTabBar, "TOPLEFT", 0, 0)
    end

    if not frame.bottomTabs.warband then
        frame.bottomTabs.warband = CreateBottomBankTypeTab(frame.bottomTabBar, "warband", "Warband")
        frame.bottomTabs.warband:SetPoint("LEFT", frame.bottomTabs.character, "RIGHT", BOTTOM_TAB_SPACING, 0)
    end

    frame.bottomTabs.character:Show()
    frame.bottomTabs.warband:Show()
    frame.bottomTabBar:Show()

    self:UpdateBottomTabSelection()
end

function BankFrame:HideBottomTabs()
    if not frame or not frame.bottomTabBar then return end

    if frame.bottomTabs.character then
        frame.bottomTabs.character:Hide()
    end
    if frame.bottomTabs.warband then
        frame.bottomTabs.warband:Hide()
    end
    frame.bottomTabBar:Hide()
end

function BankFrame:UpdateBottomTabSelection()
    if not frame or not frame.bottomTabs then return end

    local currentBankType = BankFooter and BankFooter:GetCurrentBankType() or "character"
    local bgAlpha = Database:GetSetting("bgAlpha") / 100

    for bankType, button in pairs(frame.bottomTabs) do
        if button then
            if bankType == currentBankType then
                button.selected:Show()
                button:SetBackdropBorderColor(1, 0.82, 0, 1)
                button:SetBackdropColor(0.08, 0.08, 0.08, bgAlpha)
                button.text:SetTextColor(1, 0.82, 0)
                button.topMask:SetColorTexture(0.08, 0.08, 0.08, bgAlpha)
            else
                button.selected:Hide()
                button:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
                button:SetBackdropColor(0.05, 0.05, 0.05, 0.9)
                button.text:SetTextColor(0.6, 0.6, 0.6)
                button.topMask:SetColorTexture(0.05, 0.05, 0.05, 0.9)
            end
        end
    end
end

local function HasBankData(bank)
    if not bank then return false end
    for bagID, bagData in pairs(bank) do
        if bagData.numSlots and bagData.numSlots > 0 then
            return true
        end
    end
    return false
end

-- Filter bank data to only show containers from a specific tab (Retail only)
-- In modern Retail (TWW+), each bank tab IS a separate container
-- tabIndex: 1-based tab index (0 = all tabs)
-- isWarbandView: optional, if true use warband tab IDs
function BankFrame:FilterBankByTab(bank, tabIndex, isWarbandView)
    if not bank or not tabIndex or tabIndex < 1 then
        return bank
    end

    -- Determine which tab IDs to use based on bank type
    local currentBankType = BankFooter and BankFooter:GetCurrentBankType() or "character"
    local isWarband = isWarbandView or (currentBankType == "warband")

    -- For modern Retail with container-based tabs (character or warband)
    if Constants.CHARACTER_BANK_TABS_ACTIVE or isWarband then
        local filtered = {}

        -- Get the container ID for this specific tab
        local tabContainerIDs = isWarband and Constants.WARBAND_BANK_TAB_IDS or Constants.CHARACTER_BANK_TAB_IDS
        local tabContainerID = tabContainerIDs and tabContainerIDs[tabIndex]

        ns:Debug("FilterBankByTab: tabIndex=", tabIndex, "isWarband=", tostring(isWarband), "containerID=", tostring(tabContainerID))

        if not tabContainerID then
            return bank  -- No valid tab container, return all
        end

        -- Only include the container that matches this tab
        for bagID, bagData in pairs(bank) do
            if bagID == tabContainerID then
                filtered[bagID] = bagData
                ns:Debug("FilterBankByTab: found matching container", bagID)
            end
        end

        return filtered
    end

    -- Legacy Retail (pre-TWW): slot-range based filtering
    -- Each tab has 98 slots in the main bank container
    local SLOTS_PER_TAB = 98
    local startSlot = ((tabIndex - 1) * SLOTS_PER_TAB) + 1
    local endSlot = tabIndex * SLOTS_PER_TAB

    local filtered = {}

    for bagID, bagData in pairs(bank) do
        -- Only filter the main bank container (bagID -1 or Enum.BagIndex.Bank)
        local mainBankID = Enum and Enum.BagIndex and Enum.BagIndex.Bank or -1
        if bagID == mainBankID or bagID == -1 then
            local filteredBag = {
                bagID = bagData.bagID,
                numSlots = 0,
                freeSlots = 0,
                bagType = bagData.bagType,
                containerItemID = bagData.containerItemID,
                containerTexture = bagData.containerTexture,
                slots = {},
            }

            if bagData.slots then
                for slot, slotData in pairs(bagData.slots) do
                    if slot >= startSlot and slot <= endSlot then
                        local displaySlot = slot - startSlot + 1
                        filteredBag.slots[displaySlot] = slotData
                        filteredBag.numSlots = math.max(filteredBag.numSlots, displaySlot)
                    end
                end
            end

            filteredBag.numSlots = math.min(SLOTS_PER_TAB, (bagData.numSlots or 0) - startSlot + 1)
            if filteredBag.numSlots < 0 then filteredBag.numSlots = 0 end

            for slot = 1, filteredBag.numSlots do
                if not filteredBag.slots[slot] then
                    filteredBag.freeSlots = filteredBag.freeSlots + 1
                end
            end

            if filteredBag.numSlots > 0 then
                filtered[bagID] = filteredBag
            end
        else
            filtered[bagID] = bagData
        end
    end

    return filtered
end

function BankFrame:RefreshPinIcons()
    for _, button in pairs(buttonsBySlot) do
        ItemButton:UpdatePinIcon(button)
    end
end

function BankFrame:RefreshLockIcons()
    for _, button in pairs(buttonsBySlot) do
        ItemButton:UpdateUserLockIcon(button)
    end
end

-- Acquire a button for the bank render. Reuses one from the recycle pool (a
-- button kept/parked from the previous refresh) when available, else acquires a
-- fresh one. SetItem/SetEmpty fully reset a reused button's visual state, so no
-- ResetButton teardown is needed between uses. Parked buttons were hidden, so
-- ensure the reused button is shown.
local function AcquireBankButton()
    if bankRecycle then
        bankRecycleIdx = bankRecycleIdx + 1
        local b = bankRecycle[bankRecycleIdx]
        if b then
            b:SetShown(true)
            if b.wrapper then b.wrapper:SetShown(true) end
            return b
        end
    end
    ns:ProfileStart("bank.acquire")
    local b = ItemButton:Acquire(frame.container)
    ns:ProfileStop("bank.acquire")
    return b
end

-- Park any recycle-pool buttons that weren't reused this refresh (the slot count
-- shrank): hide them and keep them acquired for reuse next refresh. This avoids
-- the ResetButton + Masque-remove cost of releasing, and the re-acquire cost when
-- the count grows back. Called after the view builders run.
local function ParkBankRecycleLeftovers()
    if not bankRecycle then return end
    for i = bankRecycleIdx + 1, #bankRecycle do
        local b = bankRecycle[i]
        b:SetShown(false)
        if b.wrapper then b.wrapper:SetShown(false) end
        bankParked[#bankParked + 1] = b
    end
    bankRecycle = nil
    bankRecycleIdx = 0
end

-------------------------------------------------
-- Progressive (per-tab) render for the All-Tabs view
--
-- The All-Tabs overview materialises ~hundreds of buttons; doing it in one frame
-- is a visible hitch even with everything pre-warmed/recycled. We render whole
-- tabs until a per-frame time budget, then place the remaining (off-screen) tabs
-- across the next frames. Because the deferred tabs are scrolled out of view, they
-- fill in invisibly — no per-item pop-in. Mirrors the guild bank's render driver.
-------------------------------------------------
local BANK_RENDER_BUDGET_MS = 8
local bankRenderDriver = CreateFrame("Frame")
bankRenderDriver:Hide()
local bankRenderState = nil
local bankRenderInFlight = false
local bankRenderNeedsRerender = false  -- a bank update arrived mid-render; re-refresh once at finish

-- Build the flat render-op list for the All-Tabs view: a header op per tab, then
-- one op per slot, each with its precomputed Y (used to decide what's on-screen).
local function BuildBankRenderOps(tabLayouts, iconSize, spacing, columns)
    local ops = {}
    for _, layout in ipairs(tabLayouts) do
        ops[#ops + 1] = { isHeader = true, layout = layout, y = layout.headerY }
        for i, slotInfo in ipairs(layout.section.slots) do
            local row = math.floor((i - 1) / columns)
            ops[#ops + 1] = {
                slotInfo = slotInfo,
                layout = layout,
                i = i,
                y = layout.slotsStartY - (row * (iconSize + spacing)),
            }
        end
    end
    return ops
end

-- Render one op (a tab header or a single slot). Per-op granularity lets the driver
-- yield mid-tab so no single frame hitches even for large tabs.
local function RenderOneBankOp(op, st)
    local layout = op.layout
    if op.isHeader then
        local section = layout.section
        local header = AcquireCategoryHeader(frame.container)
        header:SetWidth(st.contentWidth)
        header:ClearAllPoints()
        header:SetPoint("TOPLEFT", frame.container, "TOPLEFT", 0, layout.headerY)
        header.icon:Hide()
        header.text:ClearAllPoints()
        header.text:SetPoint("LEFT", header, "LEFT", 0, 0)
        header.text:SetText(section.name)
        local _, _, fontFlags = header.text:GetFont()
        if st.iconSize < Constants.CATEGORY_ICON_SIZE_THRESHOLD then
            Font:Apply(header.text, Constants.CATEGORY_FONT_SMALL, fontFlags)
        else
            Font:Apply(header.text, Constants.CATEGORY_FONT_LARGE, fontFlags)
        end
        header.line:Show()
        header.categoryId = "Tab_" .. section.tabIndex
        header:EnableMouse(false)
        table.insert(categoryHeaders, header)
        return
    end

    local slotInfo = op.slotInfo
    local iconSize, spacing, columns = st.iconSize, st.spacing, st.columns
    local isReadOnly, hasSearch = st.isReadOnly, st.hasSearch
    local button = AcquireBankButton()
    local slotKey = slotInfo.bagID .. ":" .. slotInfo.slot

    if slotInfo.itemData then
        ItemButton:SetItem(button, slotInfo.itemData, iconSize, isReadOnly)
        if hasSearch then
            ItemButton:SetSearchState(button, SearchBar:ItemMatchesFilters(frame, slotInfo.itemData))
        else
            ItemButton:ClearSearchState(button)
        end
        cachedItemData[slotKey] = slotInfo.itemData.itemID
        cachedItemCount[slotKey] = slotInfo.itemData.count
        CacheChargesForSlot(slotKey, slotInfo.bagID, slotInfo.slot)
    else
        ItemButton:SetEmpty(button, slotInfo.bagID, slotInfo.slot, iconSize, isReadOnly)
        if hasSearch then
            ItemButton:SetSearchState(button, false)
        else
            ItemButton:ClearSearchState(button)
        end
        cachedItemData[slotKey] = nil
        cachedItemCount[slotKey] = nil
        cachedItemCharges[slotKey] = nil
    end

    local i = op.i
    local col = (i - 1) % columns
    local x = col * (iconSize + spacing)
    button.wrapper:ClearAllPoints()
    button.wrapper:SetPoint("TOPLEFT", frame.container, "TOPLEFT", x, op.y)

    buttonsBySlot[slotKey] = button
    table.insert(itemButtons, button)
    if not buttonsByBag[slotInfo.bagID] then
        buttonsByBag[slotInfo.bagID] = {}
    end
    buttonsByBag[slotInfo.bagID][slotInfo.slot] = button
end

-- Finalize a deferred render: park leftover recycle buttons, mark layout cached.
local function FinishBankRender()
    bankRenderState = nil
    bankRenderInFlight = false
    bankRenderDriver:Hide()
    ParkBankRecycleLeftovers()
    layoutCached = true
    -- Font: no per-render sweep needed. The frame is registered once via
    -- Font:RegisterFrame; item buttons (Font:Apply) and headers (Font:Override)
    -- self-register on create, and a font-family change re-sweeps via ReapplyAll.
    -- Re-walking every bank button here cost ~tens of ms per render for nothing.
    -- A bank update arrived while rendering — apply it now with one incremental pass.
    if bankRenderNeedsRerender then
        bankRenderNeedsRerender = false
        if frame and frame:IsShown() and not viewingCharacter then
            BankFrame:IncrementalUpdate(nil)
        end
    end
end

-- Stop an in-flight render (tab switch, view change, close). Park whatever the
-- cancelled render didn't consume so the next refresh's recycle starts clean.
local function CancelBankRender()
    if not bankRenderInFlight then return end
    bankRenderState = nil
    bankRenderInFlight = false
    bankRenderNeedsRerender = false  -- the upcoming full refresh supersedes it
    bankRenderDriver:Hide()
    ParkBankRecycleLeftovers()
end

-- Place whole tabs until the frame-time budget is spent, then yield to next frame.
local function ProcessBankRenderChunk()
    local st = bankRenderState
    if not st then bankRenderDriver:Hide() return end
    -- If combat began mid-render, finish in one frame rather than spreading secure
    -- ops across combat frames. (The bank is only opened out of combat.)
    local drainAll = InCombatLockdown()
    local startT = debugprofilestop()
    local ops = st.ops
    local n = #ops
    while st.cursor <= n do
        RenderOneBankOp(ops[st.cursor], st)
        st.cursor = st.cursor + 1
        -- Check budget every few ops to amortise the timer call.
        if not drainAll and (st.cursor % 8 == 0) and debugprofilestop() - startT > BANK_RENDER_BUDGET_MS then
            return
        end
    end
    FinishBankRender()
end
bankRenderDriver:SetScript("OnUpdate", ProcessBankRenderChunk)

function BankFrame:Refresh()
    if not frame then return end

    -- Stop any in-flight progressive render before rebuilding.
    CancelBankRender()

    -- If purchase prompt is active, don't rebuild bank content
    if showingPurchasePrompt then
        return
    end

    -- Hide purchase prompt if it was left visible (cleanup on return to normal view)
    if frame.purchasePrompt and frame.purchasePrompt:IsShown() then
        frame.purchasePrompt:Hide()
    end
    -- Ensure container and scroll are in normal state
    frame.container:Show()
    if frame.scrollFrame then
        frame.scrollFrame:EnableMouseWheel(true)
    end

    -- Teardown strategy: single/split views reuse buttons in place across a refresh
    -- (tab/type switch) instead of releasing+re-acquiring — SetItem fully resets each
    -- reused button and it keeps its Masque registration (no re-add churn). Category
    -- view keeps the full release; its own buttonsByItemKey/pseudo-slot reuse path is
    -- unchanged (RULES Rule 1). A view-type change forces a full release for a clean slate.
    local refreshViewType = Database:GetSetting("bankViewType") or "single"
    local viewChanged = lastRefreshViewType ~= nil and lastRefreshViewType ~= refreshViewType
    if (refreshViewType == "single" or refreshViewType == "split") and not viewChanged then
        -- Reuse last refresh's active buttons plus any parked (hidden) surplus.
        -- itemButtons is reset to {} below, so mutating it here is safe.
        bankRecycle = itemButtons
        for i = 1, #bankParked do bankRecycle[#bankRecycle + 1] = bankParked[i] end
        bankParked = {}
        bankRecycleIdx = 0
    else
        -- Full teardown (category view or view-type change) — releases active AND
        -- parked buttons (all owned by frame.container), so clear the parked list.
        ns:ProfileStart("BankRefresh.releaseall")
        ItemButton:ReleaseAll(frame.container)
        ns:ProfileStop("BankRefresh.releaseall")
        bankParked = {}
        bankRecycle = nil
    end
    lastRefreshViewType = refreshViewType
    ReleaseAllCategoryHeaders()
    itemButtons = {}

    -- Clear layout cache for full refresh
    buttonsBySlot = {}
    buttonsByBag = {}
    cachedItemData = {}
    cachedItemCount = {}
    cachedItemCharges = {}
    cachedItemCategory = {}
    buttonsByItemKey = {}
    categoryViewItems = {}
    lastCategoryLayout = nil
    lastTotalItemCount = 0
    pseudoItemButtons = {}
    layoutCached = false
    lastLayoutSettings = nil

    local isViewingCached = viewingCharacter ~= nil
    local isBankOpen = BankScanner:IsBankOpen()
    local bank
    local selectedTab = 0  -- 0 = all tabs

    -- Check if we're viewing warband bank (Retail only)
    local currentBankType = BankFooter and BankFooter:GetCurrentBankType() or "character"
    local isWarbandView = ns.IsRetail and currentBankType == "warband"

    ns:Debug("Refresh - currentBankType:", currentBankType, "isWarbandView:", tostring(isWarbandView))

    if isWarbandView then
        -- Get warband bank data
        if RetailBankScanner then
            bank = RetailBankScanner:GetCachedBank(Enum.BankType.Account) or {}
            -- Normalize the cached data
            if bank then
                local normalized = {}
                for bagID, bagData in pairs(bank) do
                    normalized[bagID] = bagData
                end
                bank = normalized
            end
            selectedTab = RetailBankScanner:GetSelectedTab()
        end
        -- Fallback to database
        if not bank or not next(bank) then
            bank = Database:GetNormalizedWarbandBank() or {}
        end
        ns:Debug("  Warband bank data bags:", bank and next(bank) and "has data" or "empty")
    elseif isViewingCached then
        bank = Database:GetNormalizedBank(viewingCharacter) or {}
        -- On Retail, get selected tab for filtering
        if ns.IsRetail and RetailBankScanner then
            selectedTab = RetailBankScanner:GetSelectedTab()
        end
    elseif isBankOpen then
        bank = BankScanner:GetCachedBank()
        -- On Retail, get selected tab for filtering live bank
        if ns.IsRetail and RetailBankScanner then
            selectedTab = RetailBankScanner:GetSelectedTab()
        end
    else
        bank = Database:GetNormalizedBank() or {}
        -- On Retail, get selected tab for filtering cached bank
        if ns.IsRetail and RetailBankScanner then
            selectedTab = RetailBankScanner:GetSelectedTab()
        end
    end

    -- Filter bank data by selected tab (Retail only)
    if selectedTab > 0 and ns.IsRetail then
        bank = self:FilterBankByTab(bank, selectedTab, isWarbandView)
    end

    local hasBankData = isBankOpen or HasBankData(bank)

    if not hasBankData then
        frame.container:Hide()
        frame.emptyMessage:Show()

        if isViewingCached then
            frame.emptyMessage.text:SetText(ns.L["BANK_NO_DATA"])
            frame.emptyMessage.hint:SetText(ns.L["BANK_NOT_VISITED"])
        else
            frame.emptyMessage.text:SetText(ns.L["BANK_NO_DATA"])
            frame.emptyMessage.hint:SetText(ns.L["BANK_VISIT_BANKER"])
        end

        local columns = Database:GetSetting("bankColumns")
        local iconSize = Database:GetSetting("iconSize")
        local spacing = Database:GetSetting("iconSpacing")
        local minWidth = (iconSize * columns) + (Constants.FRAME.PADDING * 2)
        local minHeight = math.max((6 * iconSize) + (5 * spacing) + 80, (ns.IsRetail and Constants.FRAME.BANK_MIN_HEIGHT_RETAIL or Constants.FRAME.BANK_MIN_HEIGHT))

        frame:SetSize(math.max(minWidth, 250), minHeight)
        BankFooter:UpdateSlotInfo(0, 0)
        -- No items to render: park the whole recycle pool (nothing was reused).
        ParkBankRecycleLeftovers()
        return
    end

    frame.emptyMessage:Hide()
    frame.container:Show()

    local iconSize = Database:GetSetting("iconSize")
    local spacing = Database:GetSetting("iconSpacing")
    local columns = Database:GetSetting("bankColumns")
    local hasSearch = SearchBar:HasActiveFilters(frame)
    local viewType = Database:GetSetting("bankViewType") or "single"

    -- Pre-calculate expected frame width for responsive modes
    local expectedWidth = (iconSize * columns) + (spacing * (columns - 1)) + (Constants.FRAME.PADDING * 2)
    expectedWidth = math.max(expectedWidth, Constants.FRAME.MIN_WIDTH)
    local isCompact = expectedWidth < 260
    local isNarrow = expectedWidth < 220

    SearchBar:SetNarrowMode(frame, isCompact, isNarrow)
    BankFooter:SetNarrowMode(isNarrow)

    -- The All-Tabs view (single view, tab 0, multiple tabs) builds its sections
    -- straight from the bank containers and never uses bagsToShow — so skip the
    -- classify + display-order pass for it (expensive on a big warband bank, and
    -- it was the bulk of the per-tab-switch cost beyond the actual render).
    local allTabsContainerIDs = isWarbandView and Constants.WARBAND_BANK_TAB_IDS or Constants.CHARACTER_BANK_TAB_IDS
    local isAllTabsView = viewType ~= "category" and viewType ~= "split"
        and ns.IsRetail and selectedTab == 0
        and (Constants.CHARACTER_BANK_TABS_ACTIVE or isWarbandView)
        and allTabsContainerIDs and #allTabsContainerIDs > 1

    local bagsToShow
    if isAllTabsView then
        bagsToShow = {}  -- unused by RefreshSingleViewWithTabs
    else
        ns:ProfileStart("BankRefresh.classify")
        local bagIDsToUse = isWarbandView and Constants.WARBAND_BANK_TAB_IDS or Constants.BANK_BAG_IDS
        local classifiedBags = BagClassifier:ClassifyBags(bank, isViewingCached or not isBankOpen, bagIDsToUse)
        bagsToShow = LayoutEngine:BuildDisplayOrder(classifiedBags, false)
        ns:ProfileStop("BankRefresh.classify")
    end

    local showSearchBar = BankFrame:IsSearchBarVisible()
    local showFilterChips = Database:GetSetting("showFilterChips")
    local showFooterSetting = Database:GetSetting("showFooter")
    local showFooter = showFooterSetting or isViewingCached or not isBankOpen
    local showCategoryCount = Database:GetSetting("showCategoryCount")
    local isReadOnly = isViewingCached or not isBankOpen
    local splitColumns = Database:GetSetting("splitBankColumns") or 2

    local settings = {
        columns = columns,
        iconSize = iconSize,
        spacing = spacing,
        showSearchBar = showSearchBar,
        showFilterChips = showFilterChips,
        showFooter = showFooter,
        showCategoryCount = showCategoryCount,
        splitColumns = splitColumns,
    }

    ns:ProfileStart("BankRefresh.render")
    if viewType == "category" then
        self:RefreshCategoryView(bank, bagsToShow, settings, hasSearch, isReadOnly)
    elseif viewType == "split" then
        self:RefreshSplitView(bank, bagsToShow, settings, hasSearch, isReadOnly)
    else
        self:RefreshSingleView(bank, bagsToShow, settings, hasSearch, isReadOnly)
    end
    -- Park any reused buttons left over when the slot count shrank (hide + keep).
    -- Skipped while a progressive render is still in flight — FinishBankRender parks
    -- once all the deferred tabs are placed.
    if not bankRenderInFlight then
        ns:ProfileStart("BankRefresh.park")
        ParkBankRecycleLeftovers()
        ns:ProfileStop("BankRefresh.park")
    end
    ns:ProfileStop("BankRefresh.render")

    if isViewingCached or not isBankOpen then
        local totalSlots = 0
        local usedSlots = 0
        for _, bagData in pairs(bank) do
            if bagData.numSlots then
                totalSlots = totalSlots + bagData.numSlots
                usedSlots = usedSlots + (bagData.numSlots - (bagData.freeSlots or 0))
            end
        end
        BankFooter:UpdateSlotInfo(usedSlots, totalSlots)
    elseif isWarbandView then
        -- Warband bank - calculate slots from bank data
        local totalSlots = 0
        local usedSlots = 0
        for _, bagData in pairs(bank) do
            if bagData.numSlots then
                totalSlots = totalSlots + bagData.numSlots
                usedSlots = usedSlots + (bagData.numSlots - (bagData.freeSlots or 0))
            end
        end
        BankFooter:UpdateSlotInfo(usedSlots, totalSlots)
    else
        local totalSlots, freeSlots = BankScanner:GetTotalSlots()
        local regularTotal, regularFree, specialBags = BankScanner:GetDetailedSlotCounts()
        BankFooter:UpdateSlotInfo(totalSlots - freeSlots, totalSlots, regularTotal, regularFree, specialBags)
    end

    if isBankOpen and not isViewingCached then
        BankFooter:Update()
    end

    -- Font: no per-render sweep (see FinishBankRender note). Dynamic content
    -- self-registers; a font-family change re-sweeps the frame via ReapplyAll.

    -- Record what view was rendered so a later persist-across-close reopen can tell
    -- whether the retained layout still matches the intended view.
    lastRenderSig = ComputeBankRenderSig()
end

function BankFrame:RefreshSingleView(bank, bagsToShow, settings, hasSearch, isReadOnly)
    local iconSize = settings.iconSize
    local spacing = settings.spacing
    local columns = settings.columns

    -- Check if we should show tab sections (Retail bank with multiple tabs, viewing "All")
    local selectedTab = RetailBankScanner and RetailBankScanner:GetSelectedTab() or 0
    local currentBankType = BankFooter and BankFooter:GetCurrentBankType() or "character"
    local isWarbandView = ns.IsRetail and currentBankType == "warband"
    local showTabSections = ns.IsRetail and selectedTab == 0 and (Constants.CHARACTER_BANK_TABS_ACTIVE or isWarbandView)

    -- Get tab info for headers
    local tabContainerIDs = isWarbandView and Constants.WARBAND_BANK_TAB_IDS or Constants.CHARACTER_BANK_TAB_IDS
    local cachedTabs = nil
    if showTabSections and RetailBankScanner then
        local bankTypeEnum = isWarbandView and Enum.BankType.Account or Enum.BankType.Character
        cachedTabs = RetailBankScanner:GetCachedBankTabs(bankTypeEnum)
    end

    if showTabSections and tabContainerIDs and #tabContainerIDs > 1 then
        -- Render with tab sections
        self:RefreshSingleViewWithTabs(bank, settings, hasSearch, isReadOnly, tabContainerIDs, cachedTabs, isWarbandView)
        return
    end

    -- Standard single view (no tab sections)
    -- On Retail, use unified order (sequential by bag ID) to match native sort behavior
    -- This ensures profession materials don't appear after junk from regular bags
    local unifiedOrder = ns.IsRetail and not isReadOnly
    local allSlots = LayoutEngine:CollectAllSlots(bagsToShow, bank, isReadOnly, unifiedOrder)

    -- Calculate content dimensions accounting for needsSpacing (soul bags, etc. start new rows)
    local numSlots = #allSlots
    local contentWidth = (iconSize * columns) + (spacing * (columns - 1))

    -- Count actual rows including spacing breaks (same logic as CalculateButtonPositions)
    local totalRows = 0
    local sectionCount = 0
    local col = 0
    for _, slotInfo in ipairs(allSlots) do
        if slotInfo.needsSpacing then
            if col > 0 then
                totalRows = totalRows + 1  -- Complete the partial row
                col = 0
            end
            sectionCount = sectionCount + 1
        end
        col = col + 1
        if col >= columns then
            col = 0
            totalRows = totalRows + 1
        end
    end
    if col > 0 then
        totalRows = totalRows + 1  -- Final partial row
    end
    if totalRows < 1 then totalRows = 1 end

    local actualContentHeight = (iconSize * totalRows) + (spacing * math.max(0, totalRows - 1)) + (Constants.SECTION_SPACING * sectionCount)

    -- Calculate frame chrome heights (must match scroll frame positioning in UpdateFrameAppearance)
    local showSearchBar = settings.showSearchBar
    local showFilterChips = settings.showFilterChips
    local showFooter = settings.showFooter
    local chipHeight = (showSearchBar and showFilterChips) and (Constants.FRAME.CHIP_STRIP_HEIGHT + 1) or 0
    -- Top offset: same as scroll frame SetPoint TOPLEFT
    local topOffset = showSearchBar
        and (Constants.FRAME.TITLE_HEIGHT + Constants.FRAME.SEARCH_BAR_HEIGHT + chipHeight + Constants.FRAME.PADDING + 6)
        or (Constants.FRAME.TITLE_HEIGHT + Constants.FRAME.PADDING + 2)
    -- Bottom offset: dynamic footer height for responsive layout
    local dynFooterHeight = BankFooter:GetHeight()
    local bottomOffset = showFooter
        and (dynFooterHeight + Constants.FRAME.PADDING)
        or Constants.FRAME.PADDING
    local chromeHeight = topOffset + bottomOffset

    -- Calculate frame dimensions
    local frameWidth = math.max(contentWidth + (Constants.FRAME.PADDING * 2), Constants.FRAME.MIN_WIDTH)
    local frameHeightNeeded = actualContentHeight + chromeHeight

    -- Apply minimum height (2 rows of icons + spacing + chrome, min 340)
    local minFrameHeight = math.max((2 * iconSize) + (1 * spacing) + chromeHeight, (ns.IsRetail and Constants.FRAME.BANK_MIN_HEIGHT_RETAIL or Constants.FRAME.BANK_MIN_HEIGHT))
    local adjustedFrameHeight = math.max(frameHeightNeeded, minFrameHeight)

    -- Check screen limits
    local screenHeight = UIParent:GetHeight()
    local maxFrameHeight = screenHeight - 100

    -- Determine actual frame height (limited by screen)
    local actualFrameHeight = math.min(adjustedFrameHeight, maxFrameHeight)

    -- Calculate available scroll area height
    local scrollAreaHeight = actualFrameHeight - chromeHeight

    -- Need scroll only if content is taller than available scroll area
    local needsScroll = actualContentHeight > scrollAreaHeight + 5  -- 5px tolerance

    -- Set frame size (add scrollbar width only if needed)
    local scrollbarWidth = needsScroll and 20 or 0
    frame:SetSize(frameWidth + scrollbarWidth, actualFrameHeight)

    -- Adjust scroll frame right edge based on whether scroll is needed
    frame.scrollFrame:ClearAllPoints()
    frame.scrollFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", Constants.FRAME.PADDING, -topOffset)
    frame.scrollFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -Constants.FRAME.PADDING - scrollbarWidth, bottomOffset)

    -- Set container size to match actual content
    frame.container:SetSize(contentWidth, math.max(actualContentHeight, 1))

    -- Force hide scrollbar and disable scrolling when not needed
    -- Must be done AFTER setting container size to override template's auto-show behavior
    local scrollBar = frame.scrollFrame.ScrollBar or _G[frame.scrollFrame:GetName() and (frame.scrollFrame:GetName() .. "ScrollBar")]
    if needsScroll then
        if scrollBar then scrollBar:Show() end
        frame.scrollFrame:EnableMouseWheel(true)
    else
        if scrollBar then scrollBar:Hide() end
        frame.scrollFrame:SetVerticalScroll(0)
        frame.scrollFrame:EnableMouseWheel(false)
        -- Double-check hide after a frame to catch template's auto-show
        C_Timer.After(0, function()
            if scrollBar and not needsScroll then
                scrollBar:Hide()
                frame.scrollFrame:SetVerticalScroll(0)
            end
        end)
    end

    local positions = LayoutEngine:CalculateButtonPositions(allSlots, settings)

    for i, slotInfo in ipairs(allSlots) do
        local button = AcquireBankButton()
        local slotKey = slotInfo.bagID .. ":" .. slotInfo.slot

        if slotInfo.itemData then
            ItemButton:SetItem(button, slotInfo.itemData, iconSize, isReadOnly)
            if hasSearch then
                ItemButton:SetSearchState(button, SearchBar:ItemMatchesFilters(frame, slotInfo.itemData))
            else
                ItemButton:ClearSearchState(button)
            end
            -- Cache item data for incremental updates
            cachedItemData[slotKey] = slotInfo.itemData.itemID
            cachedItemCount[slotKey] = slotInfo.itemData.count
            CacheChargesForSlot(slotKey, slotInfo.bagID, slotInfo.slot)
        else
            ItemButton:SetEmpty(button, slotInfo.bagID, slotInfo.slot, iconSize, isReadOnly)
            if hasSearch then
                ItemButton:SetSearchState(button, false)
            else
                ItemButton:ClearSearchState(button)
            end
            cachedItemData[slotKey] = nil
            cachedItemCount[slotKey] = nil
            cachedItemCharges[slotKey] = nil
        end

        local pos = positions[i]
        button.wrapper:ClearAllPoints()
        button.wrapper:SetPoint("TOPLEFT", frame.container, "TOPLEFT", pos.x, pos.y)

        -- Store button by slot key for incremental updates
        buttonsBySlot[slotKey] = button
        table.insert(itemButtons, button)

        -- Store by bagID for fast bag-specific lookups
        local bagID = slotInfo.bagID
        if not buttonsByBag[bagID] then
            buttonsByBag[bagID] = {}
        end
        buttonsByBag[bagID][slotInfo.slot] = button
    end

    layoutCached = true
end

function BankFrame:RefreshSplitView(bank, bagsToShow, settings, hasSearch, isReadOnly)
    local iconSize = settings.iconSize
    local spacing = settings.spacing

    local layout = LayoutEngine:BuildSplitViewLayout(bagsToShow, bank, settings, isReadOnly)

    -- Calculate chrome heights for scroll frame positioning
    local showSearchBar = settings.showSearchBar
    local showFilterChips = settings.showFilterChips
    local showFooter = settings.showFooter
    local chipHeight = (showSearchBar and showFilterChips) and (Constants.FRAME.CHIP_STRIP_HEIGHT + 1) or 0
    local topOffset = showSearchBar
        and (Constants.FRAME.TITLE_HEIGHT + Constants.FRAME.SEARCH_BAR_HEIGHT + chipHeight + Constants.FRAME.PADDING + 6)
        or (Constants.FRAME.TITLE_HEIGHT + Constants.FRAME.PADDING + 2)
    local dynFooterHeight = BankFooter:GetHeight()
    local bottomOffset = showFooter
        and (dynFooterHeight + Constants.FRAME.PADDING)
        or Constants.FRAME.PADDING
    local chromeHeight = topOffset + bottomOffset

    local contentWidth = layout.contentWidth
    local containerHeight = layout.contentHeight

    local frameWidth = math.max(contentWidth + (Constants.FRAME.PADDING * 2), Constants.FRAME.MIN_WIDTH)
    local frameHeightNeeded = containerHeight + chromeHeight
    local minFrameHeight = (2 * iconSize) + (1 * spacing) + chromeHeight
    local adjustedFrameHeight = math.max(frameHeightNeeded, minFrameHeight)

    local screenHeight = UIParent:GetHeight()
    local maxFrameHeight = screenHeight - 100
    local actualFrameHeight = math.min(adjustedFrameHeight, maxFrameHeight)
    local scrollAreaHeight = actualFrameHeight - chromeHeight
    local needsScroll = containerHeight > scrollAreaHeight + 5

    frame:SetSize(frameWidth, actualFrameHeight)

    frame.scrollFrame:ClearAllPoints()
    frame.scrollFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", Constants.FRAME.PADDING, -topOffset)
    frame.scrollFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -Constants.FRAME.PADDING, bottomOffset)
    frame.container:SetSize(contentWidth, math.max(containerHeight, 1))

    local scrollBar = frame.scrollFrame.ScrollBar or _G[frame.scrollFrame:GetName() and (frame.scrollFrame:GetName() .. "ScrollBar")]
    if needsScroll then
        if scrollBar then
            scrollBar:ClearAllPoints()
            scrollBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -topOffset - 16)
            scrollBar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -4, bottomOffset + 16)
            scrollBar:Show()
        end
        frame.scrollFrame:EnableMouseWheel(true)
    else
        if scrollBar then scrollBar:Hide() end
        frame.scrollFrame:SetVerticalScroll(0)
        frame.scrollFrame:EnableMouseWheel(false)
        C_Timer.After(0, function()
            if scrollBar and not needsScroll then
                scrollBar:Hide()
                frame.scrollFrame:SetVerticalScroll(0)
            end
        end)
    end

    for _, section in ipairs(layout.sections) do
        -- Create header with bag icon + name
        local header = AcquireCategoryHeader(frame.container)
        header:SetWidth(section.width)
        header:ClearAllPoints()
        header:SetPoint("TOPLEFT", frame.container, "TOPLEFT", section.x, section.headerY)

        if section.displayInfo.icon then
            header.icon:SetTexture(section.displayInfo.icon)
            header.icon:SetSize(12, 12)
            header.icon:Show()
            header.text:ClearAllPoints()
            header.text:SetPoint("LEFT", header.icon, "RIGHT", 4, 0)
        else
            header.icon:Hide()
            header.text:ClearAllPoints()
            header.text:SetPoint("LEFT", header, "LEFT", 0, 0)
        end
        header.text:SetText(section.displayInfo.name or "")

        local _, _, fontFlags = header.text:GetFont()
        if iconSize < Constants.CATEGORY_ICON_SIZE_THRESHOLD then
            Font:Apply(header.text, Constants.CATEGORY_FONT_SMALL, fontFlags)
        else
            Font:Apply(header.text, Constants.CATEGORY_FONT_LARGE, fontFlags)
        end

        header.line:Show()
        header:EnableMouse(false)
        table.insert(categoryHeaders, header)

        -- Render item slots for this bag
        local bagID = section.bagID
        local bagData = bank[bagID]
        local sectionColumns = section.columns
        local numSlots = section.numSlots

        for slot = 1, numSlots do
            local itemData = bagData and bagData.slots and bagData.slots[slot]
            local button = AcquireBankButton()
            local slotKey = bagID .. ":" .. slot

            if itemData then
                ItemButton:SetItem(button, itemData, iconSize, isReadOnly)
                if hasSearch then
                    ItemButton:SetSearchState(button, SearchBar:ItemMatchesFilters(frame, itemData))
                else
                    ItemButton:ClearSearchState(button)
                end
                cachedItemData[slotKey] = itemData.itemID
                cachedItemCount[slotKey] = itemData.count
                CacheChargesForSlot(slotKey, bagID, slot)
            else
                ItemButton:SetEmpty(button, bagID, slot, iconSize, isReadOnly)
                if hasSearch then
                    ItemButton:SetSearchState(button, false)
                else
                    ItemButton:ClearSearchState(button)
                end
                cachedItemData[slotKey] = nil
                cachedItemCount[slotKey] = nil
                cachedItemCharges[slotKey] = nil
            end

            local col = (slot - 1) % sectionColumns
            local row = math.floor((slot - 1) / sectionColumns)
            local x = section.x + col * (iconSize + spacing)
            local y = section.slotsStartY - (row * (iconSize + spacing))

            button.wrapper:ClearAllPoints()
            button.wrapper:SetPoint("TOPLEFT", frame.container, "TOPLEFT", x, y)

            buttonsBySlot[slotKey] = button
            table.insert(itemButtons, button)

            if not buttonsByBag[bagID] then
                buttonsByBag[bagID] = {}
            end
            buttonsByBag[bagID][slot] = button
        end
    end

    layoutCached = true
end

-- Render single view with tab sections (headers and spacing between tabs)
function BankFrame:RefreshSingleViewWithTabs(bank, settings, hasSearch, isReadOnly, tabContainerIDs, cachedTabs, isWarbandView)
    local iconSize = settings.iconSize
    local spacing = settings.spacing
    local columns = settings.columns

    local TAB_HEADER_HEIGHT = 18
    local TAB_SECTION_SPACING = 12

    -- Collect slots grouped by tab
    local tabSections = {}
    for tabIndex, containerID in ipairs(tabContainerIDs) do
        local bagData = bank[containerID]
        if bagData and bagData.numSlots and bagData.numSlots > 0 then
            local slots = {}
            for slot = 1, bagData.numSlots do
                local itemData = bagData.slots and bagData.slots[slot]
                table.insert(slots, {
                    bagID = containerID,
                    slot = slot,
                    itemData = itemData,
                })
            end

            -- Get tab name
            local tabName = string.format("Tab %d", tabIndex)
            if cachedTabs and cachedTabs[tabIndex] then
                tabName = cachedTabs[tabIndex].name or tabName
            elseif isWarbandView then
                tabName = string.format("Warband Tab %d", tabIndex)
            end

            table.insert(tabSections, {
                tabIndex = tabIndex,
                containerID = containerID,
                name = tabName,
                slots = slots,
            })
        end
    end

    -- Calculate layout
    local contentWidth = (iconSize * columns) + (spacing * (columns - 1))
    local currentY = 0
    local tabLayouts = {}

    for _, section in ipairs(tabSections) do
        local numSlots = #section.slots
        local rows = math.ceil(numSlots / columns)
        local sectionHeight = TAB_HEADER_HEIGHT + (rows * (iconSize + spacing))

        table.insert(tabLayouts, {
            section = section,
            y = currentY,
            headerY = currentY,
            slotsStartY = currentY - TAB_HEADER_HEIGHT,
            rows = rows,
        })

        currentY = currentY - sectionHeight - TAB_SECTION_SPACING
    end

    local containerHeight = -currentY
    local frameWidth = contentWidth + Constants.FRAME.PADDING * 2

    -- Calculate chrome heights (must match scroll frame positioning)
    -- For tab sections view, search bar and footer are always shown
    local showFilterChips = settings.showFilterChips
    local chipHeight = showFilterChips and (Constants.FRAME.CHIP_STRIP_HEIGHT + 1) or 0
    local topOffset = Constants.FRAME.TITLE_HEIGHT + Constants.FRAME.SEARCH_BAR_HEIGHT + chipHeight + Constants.FRAME.PADDING + 6
    local dynFooterHeight = BankFooter:GetHeight()
    local bottomOffset = dynFooterHeight + Constants.FRAME.PADDING
    local chromeHeight = topOffset + bottomOffset
    local frameHeightNeeded = containerHeight + chromeHeight

    -- Apply minimum height (2 rows of icons + spacing + chrome, min 340)
    local minFrameHeight = math.max((2 * iconSize) + (1 * spacing) + chromeHeight, (ns.IsRetail and Constants.FRAME.BANK_MIN_HEIGHT_RETAIL or Constants.FRAME.BANK_MIN_HEIGHT))
    local adjustedFrameHeight = math.max(frameHeightNeeded, minFrameHeight)

    -- Check screen limits
    local screenHeight = UIParent:GetHeight()
    local maxFrameHeight = screenHeight - 100

    -- Determine actual frame height (limited by screen)
    local actualFrameHeight = math.min(adjustedFrameHeight, maxFrameHeight)

    -- Calculate available scroll area height
    local scrollAreaHeight = actualFrameHeight - chromeHeight

    -- Need scroll only if content is taller than available scroll area
    local needsScroll = containerHeight > scrollAreaHeight + 5  -- 5px tolerance

    -- Set frame size (add scrollbar width only if needed)
    local scrollbarWidth = needsScroll and 20 or 0
    frame:SetSize(frameWidth + scrollbarWidth, actualFrameHeight)

    -- Adjust scroll frame right edge based on whether scroll is needed
    frame.scrollFrame:ClearAllPoints()
    frame.scrollFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", Constants.FRAME.PADDING, -topOffset)
    frame.scrollFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -Constants.FRAME.PADDING - scrollbarWidth, bottomOffset)

    -- Set container size
    frame.container:SetSize(contentWidth, math.max(containerHeight, 1))

    -- Force hide scrollbar and disable scrolling when not needed
    -- Must be done AFTER setting container size to override template's auto-show behavior
    local scrollBar = frame.scrollFrame.ScrollBar or _G[frame.scrollFrame:GetName() and (frame.scrollFrame:GetName() .. "ScrollBar")]
    if needsScroll then
        if scrollBar then scrollBar:Show() end
        frame.scrollFrame:EnableMouseWheel(true)
    else
        if scrollBar then scrollBar:Hide() end
        frame.scrollFrame:SetVerticalScroll(0)
        frame.scrollFrame:EnableMouseWheel(false)
        -- Double-check hide after a frame to catch template's auto-show
        C_Timer.After(0, function()
            if scrollBar and not needsScroll then
                scrollBar:Hide()
                frame.scrollFrame:SetVerticalScroll(0)
            end
        end)
    end

    -- Progressive render: place everything in the visible viewport synchronously
    -- (so the first paint is complete — no pop-in), then defer the off-screen
    -- remainder to the render driver across the next frames (it fills in invisibly).
    local ops = BuildBankRenderOps(tabLayouts, iconSize, spacing, columns)
    local st = {
        ops = ops,
        cursor = 1,
        iconSize = iconSize,
        spacing = spacing,
        columns = columns,
        contentWidth = contentWidth,
        isReadOnly = isReadOnly,
        hasSearch = hasSearch,
    }
    -- Ops are ordered top-to-bottom; render while still within the viewport (+1 row
    -- buffer). The first op past the cutoff (and all after it) are off-screen.
    local visibleCutoff = -(scrollAreaHeight + iconSize + spacing)
    local n = #ops
    while st.cursor <= n and ops[st.cursor].y >= visibleCutoff do
        RenderOneBankOp(ops[st.cursor], st)
        st.cursor = st.cursor + 1
    end
    if st.cursor > n then
        -- Whole view fit on-screen (short bank) — done synchronously.
        layoutCached = true
    else
        ns:ProfileBump("Bank.progressive")  -- deferred the off-screen remainder
        bankRenderState = st
        bankRenderInFlight = true
        bankRenderDriver:Show()
    end
end

function BankFrame:RefreshCategoryView(bank, bagsToShow, settings, hasSearch, isReadOnly)
    local iconSize = settings.iconSize

    -- Bank always shows soul bag items (no toggle button in bank footer)
    local items, emptyCount, firstEmptySlot, soulEmptyCount, firstSoulEmptySlot, quiverEmptyCount, firstQuiverEmptySlot = LayoutEngine:CollectItemsForCategoryView(bagsToShow, bank, isReadOnly, true, true)

    local sections = LayoutEngine:BuildCategorySections(items, isReadOnly, emptyCount, firstEmptySlot, soulEmptyCount, firstSoulEmptySlot, true, nil, quiverEmptyCount, firstQuiverEmptySlot)

    local frameWidth, frameHeight = LayoutEngine:CalculateCategoryFrameSize(sections, settings)

    -- Calculate chrome heights for scroll frame positioning
    local showSearchBar = settings.showSearchBar
    local showFilterChips = settings.showFilterChips
    local showFooter = settings.showFooter
    local chipHeight = (showSearchBar and showFilterChips) and (Constants.FRAME.CHIP_STRIP_HEIGHT + 1) or 0
    local topOffset = showSearchBar
        and (Constants.FRAME.TITLE_HEIGHT + Constants.FRAME.SEARCH_BAR_HEIGHT + chipHeight + Constants.FRAME.PADDING + 6)
        or (Constants.FRAME.TITLE_HEIGHT + Constants.FRAME.PADDING + 2)
    -- Dynamic footer height for responsive layout
    local dynFooterHeight = BankFooter:GetHeight()
    local bottomOffset = showFooter
        and (dynFooterHeight + Constants.FRAME.PADDING)
        or Constants.FRAME.PADDING
    local chromeHeight = topOffset + bottomOffset

    -- Derive actual content height using LayoutEngine's chrome calculation (different from scroll positioning)
    local layoutSearchBarHeight = showSearchBar and (Constants.FRAME.SEARCH_BAR_HEIGHT + chipHeight + 4) or 0
    local layoutFooterHeight = showFooter and (dynFooterHeight + 6) or Constants.FRAME.PADDING
    local layoutChrome = Constants.FRAME.TITLE_HEIGHT + layoutSearchBarHeight + layoutFooterHeight + Constants.FRAME.PADDING + 4
    local contentHeight = frameHeight - layoutChrome

    -- Recalculate frame height using our scroll frame chrome (may differ from LayoutEngine)
    local correctFrameHeight = contentHeight + chromeHeight

    -- Apply minimum frame height (2 rows of icons + chrome, min 340)
    local minFrameHeight = math.max((2 * iconSize) + chromeHeight, (ns.IsRetail and Constants.FRAME.BANK_MIN_HEIGHT_RETAIL or Constants.FRAME.BANK_MIN_HEIGHT))
    local adjustedFrameHeight = math.max(correctFrameHeight, minFrameHeight)

    -- Check screen limits
    local screenHeight = UIParent:GetHeight()
    local maxFrameHeight = screenHeight - 100

    -- Determine actual frame height (limited by screen)
    local actualFrameHeight = math.min(adjustedFrameHeight, maxFrameHeight)

    -- Calculate available scroll area height
    local scrollAreaHeight = actualFrameHeight - chromeHeight

    -- Need scroll only if content is taller than available scroll area
    local needsScroll = contentHeight > scrollAreaHeight + 5  -- 5px tolerance

    -- Set frame size (add scrollbar width only if needed)
    local scrollbarWidth = needsScroll and 20 or 0
    frame:SetSize(frameWidth + scrollbarWidth, actualFrameHeight)

    -- Adjust scroll frame right edge based on whether scroll is needed
    frame.scrollFrame:ClearAllPoints()
    frame.scrollFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", Constants.FRAME.PADDING, -topOffset)
    frame.scrollFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -Constants.FRAME.PADDING - scrollbarWidth, bottomOffset)

    -- Set container (scroll child) size to actual content height
    frame.container:SetSize(frameWidth - Constants.FRAME.PADDING * 2, math.max(contentHeight, 1))

    -- Force hide scrollbar and disable scrolling when not needed
    -- Must be done AFTER setting container size to override template's auto-show behavior
    local scrollBar = frame.scrollFrame.ScrollBar or _G[frame.scrollFrame:GetName() and (frame.scrollFrame:GetName() .. "ScrollBar")]
    if needsScroll then
        if scrollBar then scrollBar:Show() end
        frame.scrollFrame:EnableMouseWheel(true)
    else
        if scrollBar then scrollBar:Hide() end
        frame.scrollFrame:SetVerticalScroll(0)
        frame.scrollFrame:EnableMouseWheel(false)
        -- Double-check hide after a frame to catch template's auto-show
        C_Timer.After(0, function()
            if scrollBar and not needsScroll then
                scrollBar:Hide()
                frame.scrollFrame:SetVerticalScroll(0)
            end
        end)
    end

    local layout = LayoutEngine:CalculateCategoryPositions(sections, settings)

    for _, headerInfo in ipairs(layout.headers) do
        local header = AcquireCategoryHeader(frame.container)
        header:SetWidth(headerInfo.width)
        header:ClearAllPoints()
        header:SetPoint("TOPLEFT", frame.container, "TOPLEFT", headerInfo.x, headerInfo.y)

        -- No icons in category headers
        header.icon:Hide()
        header.text:ClearAllPoints()
        header.text:SetPoint("LEFT", header, "LEFT", 0, 0)

        -- Adjust font size based on icon size
        local _, _, fontFlags = header.text:GetFont()
        if iconSize < Constants.CATEGORY_ICON_SIZE_THRESHOLD then
            Font:Apply(header.text, Constants.CATEGORY_FONT_SMALL, fontFlags)
        else
            Font:Apply(header.text, Constants.CATEGORY_FONT_LARGE, fontFlags)
        end

        -- Responsive text truncation based on available width
        local displayName = headerInfo.section.categoryName
        local numItems = #headerInfo.section.items
        -- Show count unless disabled OR only 1 item (redundant to show "(1)")
        local showCount = settings.showCategoryCount and numItems > 1
        local countSuffix = showCount and (" (" .. numItems .. ")") or ""
        header.fullName = displayName
        header.isShortened = false

        -- When not showing count, truncate based on item count
        -- 1 item: max 6 chars, 2+ items: max 13 chars
        if not showCount then
            local maxChars = numItems == 1 and 6 or 13
            if string.len(displayName) > maxChars then
                header.isShortened = true
                header.text:SetText(string.sub(displayName, 1, maxChars) .. "...")
            else
                header.text:SetText(displayName)
            end
        else
            -- Calculate available width (header width minus line spacing)
            local availableWidth = headerInfo.width - 10

            -- Set full text first to measure
            header.text:SetText(displayName .. countSuffix)
            local textWidth = header.text:GetStringWidth()

            -- Truncate if text is too wide (only for names longer than 4 characters)
            if textWidth > availableWidth and string.len(displayName) > 4 then
                header.isShortened = true
                -- Binary search for best fit
                local maxChars = string.len(displayName)
                while textWidth > availableWidth and maxChars > 1 do
                    maxChars = maxChars - 1
                    header.text:SetText(string.sub(displayName, 1, maxChars) .. "..." .. countSuffix)
                    textWidth = header.text:GetStringWidth()
                end
            end
        end

        -- Hide separator line for single-item categories
        if numItems <= 1 then
            header.line:Hide()
        else
            header.line:Show()
        end

        -- Store category info on header for drag-drop
        header.categoryId = headerInfo.section.categoryId
        header:EnableMouse(true)

        -- Add tooltip for shortened names
        header:SetScript("OnEnter", function(self)
            if self.isShortened then
                GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
                GameTooltip:SetText(self.fullName)
                GameTooltip:Show()
            end
        end)
        header:SetScript("OnLeave", function(self)
            GameTooltip:Hide()
        end)

        -- Handle click for Empty category: place item in first empty bank slot
        header:SetScript("OnMouseDown", function(self, button)
            if button == "LeftButton" and self.categoryId == "Empty" then
                local cursorType = GetCursorInfo()
                if cursorType == "item" then
                    -- Find first empty bank slot (main bank first, then bank bags)
                    local bankBags = { BANK_CONTAINER }
                    for i = NUM_BAG_SLOTS + 1, NUM_BAG_SLOTS + NUM_BANKBAGSLOTS do
                        table.insert(bankBags, i)
                    end
                    for _, bagID in ipairs(bankBags) do
                        local numSlots = C_Container.GetContainerNumSlots(bagID)
                        for slot = 1, numSlots do
                            local itemInfo = C_Container.GetContainerItemInfo(bagID, slot)
                            if not itemInfo then
                                -- Empty slot found, place item here
                                C_Container.PickupContainerItem(bagID, slot)
                                return
                            end
                        end
                    end
                end
            end
        end)

        table.insert(categoryHeaders, header)
    end

    -- Reset last button tracking for drop indicator
    lastButtonByCategory = {}

    for index, itemInfo in ipairs(layout.items) do
        local button = AcquireBankButton()
        local itemData = itemInfo.item.itemData
        local slotKey = itemData.bagID .. ":" .. itemData.slot

        -- Store category info before SetItem so it can use it for display logic
        button.categoryId = itemInfo.categoryId

        ItemButton:SetItem(button, itemData, iconSize, isReadOnly)

        -- Apply spotlight search highlighting
        if hasSearch then
            ItemButton:SetSearchState(button, SearchBar:ItemMatchesFilters(frame, itemData))
        else
            ItemButton:ClearSearchState(button)
        end

        -- Store layout position for drag-drop indicator
        button.iconSize = iconSize
        button.layoutX = itemInfo.x
        button.layoutY = itemInfo.y
        button.layoutIndex = index
        button.containerFrame = frame.container

        button.wrapper:ClearAllPoints()
        button.wrapper:SetPoint("TOPLEFT", frame.container, "TOPLEFT", itemInfo.x, itemInfo.y)

        -- Track Empty/Soul/Quiver pseudo-item buttons separately
        -- Use a unique key combining pseudo-item type and categoryId to avoid overwrites
        -- when multiple pseudo-items (Empty, Soul, Quiver) are in the same merged group
        if itemData.isEmptySlots then
            local prefix
            if itemData.isSoulSlots then
                prefix = "Soul:"
            elseif itemData.isQuiverSlots then
                prefix = "Quiver:"
            else
                prefix = "Empty:"
            end
            local pseudoKey = prefix .. itemInfo.categoryId
            pseudoItemButtons[pseudoKey] = button
        else
            -- Store button by slot key for incremental updates (not for pseudo-items)
            buttonsBySlot[slotKey] = button
            cachedItemData[slotKey] = itemData.itemID
            cachedItemCount[slotKey] = itemData.count
            cachedItemCategory[slotKey] = itemInfo.categoryId
            CacheChargesForSlot(slotKey, itemData.bagID, itemData.slot)

            -- Store by bagID for fast bag-specific lookups
            local bagID = itemData.bagID
            if not buttonsByBag[bagID] then
                buttonsByBag[bagID] = {}
            end
            buttonsByBag[bagID][itemData.slot] = button
        end

        table.insert(itemButtons, button)

        -- Track last button per category (for drop indicator anchor)
        if itemInfo.categoryId then
            lastButtonByCategory[itemInfo.categoryId] = button
        end
    end

    layoutCached = true
end

-- Register for combat end event to execute pending actions and refresh open bank
RegisterCombatEndCallback = function()
    if combatLockdownRegistered then return end
    combatLockdownRegistered = true

    Events:Register("PLAYER_REGEN_ENABLED", function()
        if pendingAction then
            local action = pendingAction
            pendingAction = nil
            if action == "show" then
                BankFrame:Show()
            end
        elseif frame and frame:IsShown() then
            -- Bank was already open during combat - refresh to catch any changes
            if BankScanner:IsBankOpen() then
                BankScanner:ScanAllBank()
            end
            BankFrame:Refresh()
        end
    end, BankFrame)
end

-- Tear down the retained (held-while-hidden) layout: release buttons + parked
-- surplus back to the shared pool and clear caches. No-op unless held, so it is
-- safe to call from other pool consumers (bags/guild bank/mail) on open. Releasing
-- is SetShown/pool bookkeeping only — combat-safe; it never creates frames.
function BankFrame:ReleaseHeld()
    if not bankHeld then return end
    bankHeld = false
    bankDirtyWhileHidden = false
    if not frame then return end
    CancelBankRender()
    ItemButton:ReleaseAll(frame.container)
    bankParked = {}
    bankRecycle = nil
    bankRecycleIdx = 0
    ReleaseAllCategoryHeaders()
    buttonsBySlot = {}
    buttonsByBag = {}
    cachedItemData = {}
    cachedItemCount = {}
    cachedItemCharges = {}
    cachedItemCategory = {}
    buttonsByItemKey = {}
    categoryViewItems = {}
    lastCategoryLayout = nil
    lastTotalItemCount = 0
    pseudoItemButtons = {}
    itemButtons = {}
    layoutCached = false
    lastLayoutSettings = nil
    lastRenderSig = nil
end

-- True when the frame is hidden but still holds a valid layout matching the
-- current intended view, so reopen can incrementally update instead of rebuild.
function BankFrame:CanFastReopen()
    return bankHeld
        and layoutCached
        and not bankDirtyWhileHidden
        and not viewingCharacter
        and frame and not frame:IsShown()
        and lastRenderSig ~= nil
        and lastRenderSig == ComputeBankRenderSig()
end

function BankFrame:Toggle()
    LoadComponents()

    if not frame then
        frame = CreateBankFrame()
        RestoreFramePosition()
    end

    if frame:IsShown() then
        self:Hide()
    else
        ns:ProfileStart("Bank.Toggle")
        self:Show()
        ns:ProfileStop("Bank.Toggle")
    end
end

function BankFrame:Show()
    LoadComponents()

    -- Free the guild bank's retained buttons (it doesn't coexist with the bank, so
    -- this just returns its share of the shared ItemButton pool; no-op if it's open
    -- or not holding).
    --
    -- Do NOT release the bags' held buttons here: the bags auto-open *together* with
    -- the bank, so tearing down their persisted layout would force a full cold
    -- re-render right as they reopen (the "slow when bags were closed" case). Leaving
    -- them held lets the bag auto-open take its fast-reopen path. Pool headroom is
    -- fine (bank + bags fit under the prewarm target), and in-combat pool pressure is
    -- handled separately by PLAYER_REGEN_DISABLED releasing held buttons.
    local GuildBankFrameModule = ns:GetModule("GuildBankFrame")
    if GuildBankFrameModule and GuildBankFrameModule.ReleaseHeld then
        GuildBankFrameModule:ReleaseHeld()
    end

    if not frame then
        frame = CreateBankFrame()
        RestoreFramePosition()
    end

    ns:ProfileStart("Bank.Show")
    -- Decide the fast-reopen path BEFORE scanning. ScanAllBank fires ns.OnBankUpdated,
    -- and because the bank is still held/hidden at this point that handler sets
    -- bankDirtyWhileHidden = true — which would make CanFastReopen() return false on
    -- EVERY reopen, forcing a needless full render. The fast path's IncrementalUpdate
    -- below reconciles whatever the scan finds, so the scan's own update must not veto it.
    local canFast = self:CanFastReopen()
    if BankScanner:IsBankOpen() then
        BankScanner:ScanAllBank()
    end

    if canFast then
        -- Smooth reopen: reuse the retained layout and update only changed slots.
        -- (Bank contents rarely change while you're away; the scan above refreshed
        -- the cache and IncrementalUpdate reconciles any differences.)
        bankHeld = false
        ns:ProfileStart("Bank.fastreopen")
        UpdateFrameAppearance(true)
        frame:Show()
        self:IncrementalUpdate(nil)  -- requires frame shown; near-no-op when unchanged
        ns:ProfileStop("Bank.fastreopen")
    else
        -- First open, or the retained view is stale (view/bank-type/tab changed) —
        -- drop any held buttons and do a full rebuild.
        self:ReleaseHeld()
        bankHeld = false
        bankDirtyWhileHidden = false
        UpdateFrameAppearance(true)  -- Refresh below restyles buttons
        self:Refresh()               -- Then calculate layout with correct scroll positioning
        frame:Show()
    end
    ns:ProfileStop("Bank.Show")
end

function BankFrame:Hide()
    if not frame then return end
    ns:ProfileStart("Bank.Hide")
    CancelBankRender()

    -- Capture before frame:Hide(): the frame's OnHide hook clears the search and
    -- resets viewingCharacter, both of which would make a retained layout stale.
    -- A retained layout is only valid for the current character with no active search.
    local canHold = layoutCached
        and not viewingCharacter
        and not SearchBar:HasActiveFilters(frame)

    frame:Hide()
    -- Reset transient search toggle so next open starts collapsed
    self:ResetSearchToggle()

    bankHeld = true
    if canHold then
        -- Keep buttons + layout so the next open is a smooth incremental update.
        bankDirtyWhileHidden = false
    else
        -- Stale/invalid layout — tear it down so the next open rebuilds cleanly.
        self:ReleaseHeld()
    end
    ns:ProfileStop("Bank.Hide")
end

function BankFrame:IsShown()
    return frame and frame:IsShown()
end

function BankFrame:InvalidateLayout()
    layoutCached = false
end

function BankFrame:GetFrame()
    return frame
end

function BankFrame:GetViewingCharacter()
    return viewingCharacter
end

function BankFrame:ViewCharacter(fullName, charData)
    viewingCharacter = fullName
    BankHeader:SetViewingCharacter(fullName, charData)

    UpdateFrameAppearance(true)  -- Refresh below restyles buttons
    self:Refresh()
end

function BankFrame:IsViewingCached()
    return viewingCharacter ~= nil or not BankScanner:IsBankOpen()
end

-- Incremental update: only update changed slots without full layout recalculation
-- dirtyBags: optional table of {bagID = true} for bags that changed
function BankFrame:IncrementalUpdate(dirtyBags)
    if not frame or not frame:IsShown() then return end

    -- Never do incremental updates while viewing a cached character
    -- Live bank events should not affect cached character display
    if viewingCharacter then return end

    -- Recent items removal is now handled by ghost slots in incremental update
    -- Just clear the flag so it doesn't accumulate
    local RecentItems = ns:GetModule("RecentItems")
    if RecentItems then
        RecentItems:WasItemRemoved()  -- Clear the flag, but don't force refresh
    end

    if not layoutCached then
        -- No cached layout, do full refresh
        self:Refresh()
        return
    end

    local bank = BankScanner:GetCachedBank()
    -- Cache settings once at start (avoid repeated GetSetting calls)
    local iconSize = Database:GetSetting("iconSize")
    local hasSearch = SearchBar:HasActiveFilters(frame)
    local isReadOnly = viewingCharacter ~= nil or not BankScanner:IsBankOpen()
    local viewType = Database:GetSetting("bankViewType") or "single"
    local isCategoryView = viewType == "category"

    -- If no dirty bags specified, check all (fallback behavior)
    local checkAllBags = not dirtyBags or not next(dirtyBags)

    -- For category view: check if item's CATEGORY changed (not just itemID)
    -- If item moves within same category, do incremental update
    -- If item moves between categories or slot becomes empty/filled, do full refresh
    if isCategoryView then
        local CategoryManager = ns:GetModule("CategoryManager")
        local needsFullRefresh = false
        local itemUpdates = {}
        local countUpdates = {}
        local ghostSlots = {}

        -- Detect soul/quiver bags for category override (must match BuildCategorySections logic)
        -- Bank always shows soul items (forceSoulVisible)
        local soulCategoryEnabled = false
        local quiverCategoryEnabled = false
        if CategoryManager then
            local cats = CategoryManager:GetCategories()
            local soulDef = cats and cats.definitions and cats.definitions["Soul"]
            soulCategoryEnabled = soulDef and soulDef.enabled
            local quiverDef = cats and cats.definitions and cats.definitions["Quiver"]
            quiverCategoryEnabled = quiverDef and quiverDef.enabled
        end

        local function checkBag(bagID)
            local slotButtons = buttonsByBag[bagID] or {}
            local bagData = bank[bagID]

            -- Count cached buttons for this bag
            local cachedButtonCount = 0
            for _ in pairs(slotButtons) do
                cachedButtonCount = cachedButtonCount + 1
            end

            local currentItemCount = 0
            if bagData and bagData.slots then
                for _, itemData in pairs(bagData.slots) do
                    if itemData then
                        currentItemCount = currentItemCount + 1
                    end
                end
            end

            -- If no buttons cached for this bag but items exist now, new item appeared - need refresh
            if cachedButtonCount == 0 then
                if currentItemCount > 0 then
                    ns:Debug("Bank CategoryView REFRESH: bag", bagID, "was empty, now has", currentItemCount, "items")
                    needsFullRefresh = true
                end
                return
            end

            -- If MORE items than buttons, new item appeared - need refresh
            if currentItemCount > cachedButtonCount then
                ns:Debug("Bank CategoryView REFRESH: bag", bagID, "has MORE items", currentItemCount, ">", cachedButtonCount)
                needsFullRefresh = true
                return
            end
            -- If fewer items, some were removed - keep ghost slots (lazy approach)
            if currentItemCount < cachedButtonCount then
                ns:Debug("Bank CategoryView LAZY: bag", bagID, "has FEWER items", currentItemCount, "<", cachedButtonCount, "- keeping ghosts")
            end

            -- Detect soul/quiver bag for category override
            local bagType = BagClassifier and BagClassifier:GetBagType(bagID) or "regular"
            local isSoulBag = (bagType == "soul")
            local isQuiverBag = (bagType == "quiver" or bagType == "ammo")

            for slot, button in pairs(slotButtons) do
                local slotKey = bagID .. ":" .. slot
                local newItemData = bagData and bagData.slots and bagData.slots[slot]
                local oldItemID = cachedItemData[slotKey]
                local newItemID = newItemData and newItemData.itemID or nil
                local oldCategory = cachedItemCategory[slotKey]

                if oldItemID ~= newItemID then
                    if not newItemData then
                        -- Slot became empty - show empty texture but keep position (no layout refresh)
                        ns:Debug("Bank CategoryView GHOST: empty slot at", slotKey, "oldID=", oldItemID)
                        ItemButton:SetEmpty(button, bagID, slot, iconSize, isReadOnly)
                        cachedItemData[slotKey] = nil
                        cachedItemCount[slotKey] = nil
                        cachedItemCharges[slotKey] = nil
                        -- Keep cachedItemCategory so we know this slot existed
                        table.insert(ghostSlots, slotKey)
                    else
                        -- Quiver/Soul bag items use their pseudo-category overrides (same as BuildCategorySections)
                        local newCategory
                        if quiverCategoryEnabled and isQuiverBag then
                            newCategory = "Quiver"
                        elseif soulCategoryEnabled and isSoulBag then
                            newCategory = "Soul"
                        else
                            newCategory = CategoryManager and CategoryManager:CategorizeItem(newItemData, bagID, slot, isReadOnly) or "Miscellaneous"
                        end

                        if oldCategory ~= newCategory then
                            ns:Debug("Bank CategoryView REFRESH: category changed at", slotKey, "from", oldCategory, "to", newCategory)
                            needsFullRefresh = true
                            return
                        end

                        itemUpdates[slotKey] = {button = button, itemData = newItemData, category = newCategory}
                    end
                elseif newItemData then
                    local oldCount = cachedItemCount[slotKey]
                    if oldCount ~= newItemData.count then
                        countUpdates[slotKey] = {button = button, count = newItemData.count}
                    end
                    -- Item identity unchanged but charges may have decremented
                    RefreshChargesForReusedButton(button, bagID, slot, slotKey)
                end
            end

            -- Check for items in slots we don't have buttons for (new slots)
            if bagData and bagData.slots then
                for slot, itemData in pairs(bagData.slots) do
                    if itemData and not slotButtons[slot] then
                        ns:Debug("Bank CategoryView REFRESH: new item at untracked slot", bagID .. ":" .. slot)
                        needsFullRefresh = true
                        return
                    end
                end
            end
        end

        if checkAllBags then
            for bagID in pairs(buttonsByBag) do
                checkBag(bagID)
                if needsFullRefresh then break end
            end
        else
            for bagID in pairs(dirtyBags) do
                checkBag(bagID)
                if needsFullRefresh then break end
            end
        end

        if needsFullRefresh then
            ns:Debug("Bank CategoryView: FULL REFRESH triggered")
            self:Refresh()
            return
        end

        if #ghostSlots > 0 then
            ns:Debug("Bank CategoryView LAZY: kept", #ghostSlots, "ghost slots, no refresh")
        end

        for slotKey, update in pairs(itemUpdates) do
            ItemButton:SetItem(update.button, update.itemData, iconSize, isReadOnly)
            cachedItemData[slotKey] = update.itemData.itemID
            cachedItemCount[slotKey] = update.itemData.count
            cachedItemCategory[slotKey] = update.category
            CacheChargesForSlot(slotKey, update.itemData.bagID, update.itemData.slot)
            if hasSearch then
                ItemButton:SetSearchState(update.button, SearchBar:ItemMatchesFilters(frame, update.itemData))
            else
                ItemButton:ClearSearchState(update.button)
            end
        end

        for slotKey, update in pairs(countUpdates) do
            SetItemButtonCount(update.button, update.count)
            cachedItemCount[slotKey] = update.count
        end

        -- Calculate empty slot counts and first empty slots using LIVE data
        local emptyCount = 0
        local soulEmptyCount = 0
        local firstEmptyBagID, firstEmptySlot = nil, nil
        local firstSoulBagID, firstSoulSlot = nil, nil

        for bagID = Constants.BANK_MAIN_BAG, Constants.BANK_BAG_MAX do
            if bagID == Constants.BANK_MAIN_BAG or (bagID >= Constants.BANK_BAG_MIN and bagID <= Constants.BANK_BAG_MAX) then
                local numSlots = C_Container.GetContainerNumSlots(bagID)
                if numSlots and numSlots > 0 then
                    local bagType = BagClassifier and BagClassifier:GetBagType(bagID) or "regular"
                    local isSoulBag = (bagType == "soul")
                    for slot = 1, numSlots do
                        local itemInfo = C_Container.GetContainerItemInfo(bagID, slot)
                        if not itemInfo then
                            if isSoulBag then
                                soulEmptyCount = soulEmptyCount + 1
                                if not firstSoulBagID then
                                    firstSoulBagID, firstSoulSlot = bagID, slot
                                end
                            else
                                emptyCount = emptyCount + 1
                                if not firstEmptyBagID then
                                    firstEmptyBagID, firstEmptySlot = bagID, slot
                                end
                            end
                        end
                    end
                end
            end
        end

        -- Check if Empty/Soul categories need to appear or disappear
        local emptyButtonExists = FindPseudoItemButton("Empty") ~= nil
        local soulButtonExists = FindPseudoItemButton("Soul") ~= nil
        local emptyNeedsButton = emptyCount > 0
        local soulNeedsButton = soulEmptyCount > 0

        if (emptyNeedsButton and not emptyButtonExists) or (not emptyNeedsButton and emptyButtonExists) then
            ns:Debug("Bank CategoryView REFRESH: Empty category visibility changed")
            self:Refresh()
            return
        end
        if (soulNeedsButton and not soulButtonExists) or (not soulNeedsButton and soulButtonExists) then
            ns:Debug("Bank CategoryView REFRESH: Soul category visibility changed")
            self:Refresh()
            return
        end

        -- Update pseudo-item counters and slot references directly
        local emptyBtn = FindPseudoItemButton("Empty")
        if emptyBtn then
            SetItemButtonCount(emptyBtn, emptyCount)
            if emptyBtn.itemData then
                emptyBtn.itemData.emptyCount = emptyCount
                emptyBtn.itemData.count = emptyCount
                if firstEmptyBagID then
                    emptyBtn.itemData.bagID = firstEmptyBagID
                    emptyBtn.itemData.slot = firstEmptySlot
                    emptyBtn.wrapper:SetID(firstEmptyBagID)
                    emptyBtn:SetID(firstEmptySlot)
                end
            end
        end
        local soulBtn = FindPseudoItemButton("Soul")
        if soulBtn then
            SetItemButtonCount(soulBtn, soulEmptyCount)
            if soulBtn.itemData then
                soulBtn.itemData.emptyCount = soulEmptyCount
                soulBtn.itemData.count = soulEmptyCount
                if firstSoulBagID then
                    soulBtn.itemData.bagID = firstSoulBagID
                    soulBtn.itemData.slot = firstSoulSlot
                    soulBtn.wrapper:SetID(firstSoulBagID)
                    soulBtn:SetID(firstSoulSlot)
                end
            end
        end

        local totalSlots, freeSlots = BankScanner:GetTotalSlots()
        local regularTotal, regularFree, specialBags = BankScanner:GetDetailedSlotCounts()
        BankFooter:UpdateSlotInfo(totalSlots - freeSlots, totalSlots, regularTotal, regularFree, specialBags)
        if BankScanner:IsBankOpen() and not viewingCharacter then
            BankFooter:Update()
        end
        return
    end

    -- Single view: full incremental update (items stay in fixed slots)
    -- Optimized: Only iterate buttons in dirty bags using buttonsByBag index
    if checkAllBags then
        -- Fallback: check all bags
        for bagID, slotButtons in pairs(buttonsByBag) do
            local bagData = bank[bagID]
            for slot, button in pairs(slotButtons) do
                local slotKey = bagID .. ":" .. slot
                local newItemData = bagData and bagData.slots and bagData.slots[slot]
                local oldItemID = cachedItemData[slotKey]
                local newItemID = newItemData and newItemData.itemID or nil

                if oldItemID ~= newItemID then
                    if newItemData then
                        ItemButton:SetItem(button, newItemData, iconSize, isReadOnly)
                        cachedItemData[slotKey] = newItemID
                        cachedItemCount[slotKey] = newItemData.count
                        CacheChargesForSlot(slotKey, bagID, slot)
                        if hasSearch then
                            ItemButton:SetSearchState(button, SearchBar:ItemMatchesFilters(frame, newItemData))
                        else
                            ItemButton:ClearSearchState(button)
                        end
                    else
                        ItemButton:SetEmpty(button, bagID, slot, iconSize, isReadOnly)
                        cachedItemData[slotKey] = nil
                        cachedItemCount[slotKey] = nil
                        cachedItemCharges[slotKey] = nil
                        if hasSearch then
                            ItemButton:SetSearchState(button, false)
                        else
                            ItemButton:ClearSearchState(button)
                        end
                    end
                elseif newItemData then
                    -- Same item - only update if count changed (stacking)
                    local oldCount = cachedItemCount[slotKey]
                    if oldCount ~= newItemData.count then
                        SetItemButtonCount(button, newItemData.count)
                        cachedItemCount[slotKey] = newItemData.count
                    end
                    -- Item identity unchanged but charges may have decremented
                    RefreshChargesForReusedButton(button, bagID, slot, slotKey)
                end
            end
        end
    else
        -- Fast path: only check dirty bags (O(dirty bags) instead of O(all buttons))
        for bagID in pairs(dirtyBags) do
            local slotButtons = buttonsByBag[bagID]
            if slotButtons then
                local bagData = bank[bagID]
                for slot, button in pairs(slotButtons) do
                    local slotKey = bagID .. ":" .. slot
                    local newItemData = bagData and bagData.slots and bagData.slots[slot]
                    local oldItemID = cachedItemData[slotKey]
                    local newItemID = newItemData and newItemData.itemID or nil

                    if oldItemID ~= newItemID then
                        if newItemData then
                            ItemButton:SetItem(button, newItemData, iconSize, isReadOnly)
                            cachedItemData[slotKey] = newItemID
                            cachedItemCount[slotKey] = newItemData.count
                            CacheChargesForSlot(slotKey, bagID, slot)
                            if hasSearch then
                                ItemButton:SetSearchState(button, SearchBar:ItemMatchesFilters(frame, newItemData))
                            else
                                ItemButton:ClearSearchState(button)
                            end
                        else
                            ItemButton:SetEmpty(button, bagID, slot, iconSize, isReadOnly)
                            cachedItemData[slotKey] = nil
                            cachedItemCount[slotKey] = nil
                            cachedItemCharges[slotKey] = nil
                            if hasSearch then
                                ItemButton:SetSearchState(button, false)
                            else
                                ItemButton:ClearSearchState(button)
                            end
                        end
                    elseif newItemData then
                        -- Same item - only update if count changed (stacking)
                        local oldCount = cachedItemCount[slotKey]
                        if oldCount ~= newItemData.count then
                            SetItemButtonCount(button, newItemData.count)
                            cachedItemCount[slotKey] = newItemData.count
                        end
                        -- Item identity unchanged but charges may have decremented
                        RefreshChargesForReusedButton(button, bagID, slot, slotKey)
                    end
                end
            end
        end
    end

    -- Update footer slot info
    local totalSlots, freeSlots = BankScanner:GetTotalSlots()
    local regularTotal, regularFree, specialBags = BankScanner:GetDetailedSlotCounts()
    BankFooter:UpdateSlotInfo(totalSlots - freeSlots, totalSlots, regularTotal, regularFree, specialBags)
    if BankScanner:IsBankOpen() and not viewingCharacter then
        BankFooter:Update()
    end
end

-- Targeted charges-only refresh — walks already-rendered buttons and updates
-- chargesText for any slot whose charges differ from cache. Skips slots known
-- to have no charges (cache value `false`), so this is free for non-charge items.
function BankFrame:RefreshChargesOnly()
    if not frame or not frame:IsShown() then return end
    if viewingCharacter then return end
    if not Database:GetSetting("showCharges") then return end
    local TS = GetTooltipScanner()
    if not TS then return end

    for slotKey, button in pairs(buttonsBySlot) do
        if not button.isEmptySlotButton and button.itemData and button.itemData.bagID then
            local cachedCharges = cachedItemCharges[slotKey]
            if cachedCharges ~= false then
                local bagID = button.itemData.bagID
                local slot = button.itemData.slot
                local newCharges = TS:GetCharges(bagID, slot) or false
                if newCharges ~= cachedCharges then
                    cachedItemCharges[slotKey] = newCharges
                    if button.chargesText then
                        if type(newCharges) == "number" and newCharges > 0 then
                            button.chargesText:SetText("x" .. newCharges)
                            button.chargesText:Show()
                        else
                            button.chargesText:Hide()
                        end
                    end
                end
            end
        end
    end
end

-- dirtyBags: table of {bagID = true} for bags that were updated
ns.OnBankUpdated = function(dirtyBags)
    -- NOTE: we intentionally do NOT set bankDirtyWhileHidden on a content change here.
    -- Walking up to the banker fires BANKFRAME_OPENED → BAG_UPDATE for the bank bags
    -- *before* BankFrame:Show runs, so this handler would dirty the held layout on
    -- EVERY reopen and defeat the fast path entirely. Content changes are reconciled by
    -- the fast path's IncrementalUpdate(nil) (it re-scans all bank bags and updates only
    -- changed slots), so a full render isn't needed. Only layout-affecting setting
    -- changes (OnSettingChanged) and view/bank-type/tab changes (the render signature)
    -- still force a full rebuild on reopen.
    if not viewingCharacter and frame and frame:IsShown() then
        if bankRenderInFlight then
            -- A progressive render is mid-flight (layoutCached is intentionally false
            -- until it finishes). Don't restart it on every event — that doubled the
            -- per-tab-switch render cost. Mark dirty; FinishBankRender re-refreshes once.
            bankRenderNeedsRerender = true
        elseif layoutCached then
            BankFrame:IncrementalUpdate(dirtyBags)
        else
            BankFrame:Refresh()
        end
    end

    -- Also update bag frame if open (items may have moved between bank and bags)
    -- This is needed on Retail where BAG_UPDATE doesn't always fire for player bags
    -- when items are moved from Warband bank
    -- Use IncrementalUpdate to preserve ghost slots instead of full Refresh
    local BagFrame = ns:GetModule("BagFrame")
    local BagScanner = ns:GetModule("BagScanner")
    if BagFrame and BagFrame:IsShown() then
        BagScanner:ScanAllBags()
        -- Let IncrementalUpdate handle it (preserves ghost slots)
        -- If layout isn't cached yet, IncrementalUpdate will call Refresh internally
        BagFrame:IncrementalUpdate()
    end
end

-- Disable the default Blizzard bank frame completely
-- Must be called when bank opens since _G.BankFrame may not exist at addon load time
local blizzBankDisabled = false
local function HideDefaultBankFrame()
    if blizzBankDisabled then return end
    if _G.BankFrame then
        blizzBankDisabled = true
        _G.BankFrame:SetParent(hiddenParent)
        _G.BankFrame:UnregisterAllEvents()
    end
end
HideDefaultBankFrame()

ns.OnBankOpened = function()
    HideDefaultBankFrame()
    LoadComponents()

    if not frame then
        frame = CreateBankFrame()
        RestoreFramePosition()
    end

    -- Always reset to current character's bank when opening the banker
    if viewingCharacter then
        viewingCharacter = nil
        BankHeader:SetViewingCharacter(nil, nil)
    end

    BankFrame:Show()
end

local closingBank = false  -- re-entrancy guard for ns.OnBankClosed (see below)
ns.OnBankClosed = function()
    if not frame or closingBank then return end
    -- Already closed and holding the retained layout — ignore a duplicate/late
    -- BANKFRAME_CLOSED. ClearInteraction(Banker) re-fires the event a frame later
    -- (async), after closingBank has reset; this skips that redundant second pass.
    if bankHeld and not frame:IsShown() then return end
    closingBank = true
    -- Save only when the bank was actually open (the scanner has fresh data then).
    if frame:IsShown() then
        BankScanner:SaveToDatabase()
    end
    -- Always run Hide so persist-across-close engages even when the frame was already
    -- hidden directly. ESC / the close button / UISpecialFrames hide the frame without
    -- going through BankFrame:Hide, so without this the layout is never retained
    -- (bankHeld stays false) and every reopen does a full render. Hide is a no-op on an
    -- already-hidden frame apart from the persist bookkeeping we need here.
    -- The guard above absorbs any re-entrant BANKFRAME_CLOSED that BankFrame:Hide ->
    -- frame:Hide() -> OnHide -> ClearInteraction(Banker) might fire back at us.
    BankFrame:Hide()
    closingBank = false
end

-- skipButtonRestyle: skip the per-button theme/font/alpha loops (they iterate every
-- active button). Redundant on opens/refreshes — Acquire/SetItem already style each
-- button — so callers that follow with Refresh pass true. Only the appearance/
-- hoverBagline SETTING_CHANGED paths (which don't rebuild) need the restyle.
UpdateFrameAppearance = function(skipButtonRestyle)
    if not frame then return end

    local isViewingCached = viewingCharacter ~= nil
    local isBankOpen = BankScanner:IsBankOpen()

    local bgAlpha = Database:GetSetting("bgAlpha") / 100
    local showBorders = Database:GetSetting("showBorders")

    -- Apply theme background (ButtonFrameTemplate for Blizzard, backdrop for Guda)
    Theme:ApplyFrameBackground(frame, bgAlpha, showBorders)

    BankHeader:SetBackdropAlpha(bgAlpha)

    if not skipButtonRestyle then
        ItemButton:UpdateSlotAlpha(bgAlpha)
        ItemButton:ApplyThemeTextures()
        ItemButton:UpdateFontSize()
        local TrackedBar = ns:GetModule("TrackedBar")
        if TrackedBar then
            TrackedBar:UpdateFontSize()
            TrackedBar:UpdateSize()
        end
        local QuestBar = ns:GetModule("QuestBar")
        if QuestBar then
            QuestBar:UpdateFontSize()
            QuestBar:UpdateSize()
        end
    end

    local showSearchBar = BankFrame:IsSearchBarVisible()
    local showFooter = Database:GetSetting("showFooter")

    -- Only toggle search bar visibility here - scroll frame positioning is handled by Refresh()
    -- This prevents overwriting the correct scrollbar width calculation from Refresh()
    if showSearchBar then
        SearchBar:Show(frame)
    else
        SearchBar:Hide(frame)
    end

    if isViewingCached then
        BankFooter:ShowCached(viewingCharacter)
        BankHeader:SetSortEnabled(false)
        -- Show side tabs and bottom tabs for Retail cached bank viewing
        if ns.IsRetail then
            BankFrame:ShowSideTabs(viewingCharacter)
            BankFrame:ShowBottomTabs()
        end
    elseif not isBankOpen then
        BankFooter:ShowCached(Database:GetPlayerFullName())
        BankHeader:SetSortEnabled(false)
        -- Show side tabs and bottom tabs for Retail cached bank viewing
        if ns.IsRetail then
            BankFrame:ShowSideTabs(Database:GetPlayerFullName())
            BankFrame:ShowBottomTabs()
        end
    elseif showFooter then
        BankHeader:SetSortEnabled(true)
        -- On Retail with bank open, show footer with action buttons and bottom tabs
        if ns.IsRetail then
            local currentBankType = BankFooter:GetCurrentBankType() or "character"
            BankFooter:ShowLive(currentBankType)
            BankFrame:ShowSideTabs(Database:GetPlayerFullName(), currentBankType)
            BankFrame:ShowBottomTabs()
        else
            BankFooter:Show()
            BankFrame:HideSideTabs()
            BankFrame:HideBottomTabs()
        end
    else
        BankFooter:Hide()
        BankHeader:SetSortEnabled(true)
        BankFrame:HideSideTabs()
        BankFrame:HideBottomTabs()
    end
end

local appearanceSettings = {
    bgAlpha = true,
    showBorders = true,
    iconFontSize = true,
    trackedBarSize = true,
    trackedBarColumns = true,
    questBarSize = true,
    questBarColumns = true,
    theme = true,
    retailEmptySlots = true,
    minimalEmptySlots = true,
}

local resizeSettings = {
    showFooter = true,
    showSearchBar = true,
    showFilterChips = true,
}

local function OnSettingChanged(event, key, value)
    -- A setting changed while holding a hidden layout invalidates the fast reopen
    -- (size/columns/view/appearance won't have been applied to the retained buttons).
    if bankHeld and not (frame and frame:IsShown()) then
        bankDirtyWhileHidden = true
    end

    if not frame or not frame:IsShown() then return end

    -- When changing view type while viewing another character, reset to current character
    if key == "bankViewType" and viewingCharacter then
        viewingCharacter = nil
        BankHeader:SetViewingCharacter(nil, nil)
    end

    if appearanceSettings[key] then
        UpdateFrameAppearance()
    elseif resizeSettings[key] then
        UpdateFrameAppearance(true)  -- Refresh below restyles buttons
        BankFrame:Refresh()
    elseif key == "hoverBagline" then
        -- Refresh footer bag slot mode (expanded vs collapsed)
        UpdateFrameAppearance()
    elseif key == "groupIdenticalItems" then
        -- Force full release when toggling item grouping to prevent visual artifacts
        -- Item structure changes fundamentally (grouped vs individual) but keys stay same
        ItemButton:ReleaseAll(frame.container)
        buttonsByItemKey = {}
        pseudoItemButtons = {}
        BankFrame:Refresh()
    else
        BankFrame:Refresh()
    end
end

SaveFramePosition = function()
    if not frame then return end
    local point, _, relativePoint, x, y = frame:GetPoint()
    Database:SetSetting("bankFramePoint", point)
    Database:SetSetting("bankFrameRelativePoint", relativePoint)
    Database:SetSetting("bankFrameX", x)
    Database:SetSetting("bankFrameY", y)
end

RestoreFramePosition = function()
    if not frame then return end
    local point = Database:GetSetting("bankFramePoint")
    local relativePoint = Database:GetSetting("bankFrameRelativePoint")
    local x = Database:GetSetting("bankFrameX")
    local y = Database:GetSetting("bankFrameY")

    frame:ClearAllPoints()
    if point and x and y then
        frame:SetPoint(point, UIParent, relativePoint, x, y)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
end

function BankFrame:TransferMatchedItems()
    if InCombatLockdown() then
        UIErrorsFrame:AddMessage(ns.L["TRANSFER_COMBAT"], 1.0, 0.1, 0.1, 1.0)
        return
    end
    if not frame or not BankScanner:IsBankOpen() then return end

    local currentBankType = BankFooter and BankFooter:GetCurrentBankType() or "character"
    local isWarbandView = ns.IsRetail and currentBankType == "warband"

    local bank, bagIDs
    if isWarbandView and RetailBankScanner then
        bank = RetailBankScanner:GetCachedBank(Enum.BankType.Account) or {}
        bagIDs = Constants.WARBAND_BANK_TAB_IDS
    else
        bank = BankScanner:GetCachedBank()
        bagIDs = Constants.BANK_BAG_IDS
    end

    if not bank or not bagIDs then return end

    for _, bagID in ipairs(bagIDs) do
        local bagData = bank[bagID]
        if bagData and bagData.slots then
            for slot, itemData in pairs(bagData.slots) do
                if itemData and itemData.itemID and SearchBar:ItemMatchesFilters(frame, itemData) then
                    C_Container.UseContainerItem(bagID, slot)
                end
            end
        end
    end
end

function BankFrame:SortBank()
    if not BankScanner:IsBankOpen() then
        ns:Print("Cannot sort bank: not at banker")
        return
    end

    local SortEngine = ns:GetModule("SortEngine")
    if SortEngine then
        -- Check if viewing Warband bank
        local currentBankType = BankFooter and BankFooter:GetCurrentBankType() or "character"
        if currentBankType == "warband" then
            SortEngine:SortWarbandBank()
        else
            SortEngine:SortBank()
        end
    else
        ns:Print("SortEngine not loaded")
    end
end

-- Restack items and clean ghost slots (for category view)
function BankFrame:RestackAndClean()
    if not frame or not frame:IsShown() then return end
    if not BankScanner:IsBankOpen() then
        ns:Print("Cannot restack bank: not at banker")
        return
    end

    -- Play sound feedback
    PlaySound(SOUNDKIT.IG_BACKPACK_OPEN)

    -- Use SortEngine's restack function (consolidates stacks without sorting)
    local SortEngine = ns:GetModule("SortEngine")
    if SortEngine then
        -- Check if viewing Warband bank
        local currentBankType = BankFooter and BankFooter:GetCurrentBankType() or "character"
        local restackFunc = currentBankType == "warband" and SortEngine.RestackWarbandBank or SortEngine.RestackBank
        restackFunc(SortEngine, function()
            -- Callback when restack is complete - now clean ghost slots
            C_Timer.After(0.1, function()
                if frame and frame:IsShown() then
                    -- Release all buttons first (they would be orphaned otherwise)
                    ItemButton:ReleaseAll(frame.container)

                    -- Clear all layout caches (removes ghost slots)
                    buttonsBySlot = {}
                    buttonsByBag = {}
                    cachedItemData = {}
                    cachedItemCount = {}
                    cachedItemCharges = {}
                    cachedItemCategory = {}
                    buttonsByItemKey = {}
                    categoryViewItems = {}
                    lastCategoryLayout = nil
                    lastTotalItemCount = 0
                    pseudoItemButtons = {}
                    layoutCached = false
                    lastLayoutSettings = nil

                    -- Rescan and refresh
                    BankScanner:ScanAllBank()
                    BankFrame:Refresh()
                end
            end)
        end)
    else
        -- Fallback if no SortEngine
        BankScanner:ScanAllBank()
        BankFrame:Refresh()
    end
end

Events:Register("SETTING_CHANGED", OnSettingChanged, BankFrame)

-- Refresh when categories are updated (reordered, grouped, etc.)
-- Force full refresh by releasing all buttons since category assignments changed
Events:Register("CATEGORIES_UPDATED", function()
    if frame and frame:IsShown() then
        -- Release all buttons to force full refresh (category assignments changed)
        ItemButton:ReleaseAll(frame.container)
        buttonsByItemKey = {}
        pseudoItemButtons = {}
        BankFrame:Refresh()
    end
end, BankFrame)

Events:Register("PLAYER_MONEY", function()
    if frame and frame:IsShown() then
        BankFooter:UpdateMoney()
    end
end, BankFrame)

-- Bank bag slot configuration changed (bag added/removed from bank bag slot)
-- Force re-scan + full refresh since the batched scanner may not have processed yet
if not ns.IsRetail then
    Events:Register("PLAYERBANKBAGSLOTS_CHANGED", function()
        if frame and frame:IsShown() and not viewingCharacter then
            ns:Debug("PLAYERBANKBAGSLOTS_CHANGED - forcing rescan + full refresh")
            BankScanner:ScanAllBank()
            layoutCached = false
            BankFrame:Refresh()
            BankFooter:RefreshFlyoutSlots()
        end
    end, BankFrame)
end

-- GET_ITEM_INFO_RECEIVED fires once per itemID as async item data finishes
-- loading. Bank items often arrive after BANKFRAME_OPENED returns; their initial
-- tooltip scan is incomplete and red-coloured "Requires …"/loading text wrongly
-- marks them as unusable. Repaint affected buttons once data lands so the false
-- red overlay clears without the user having to close+reopen the bank.
local pendingItemRefresh = {}
local itemRefreshTimer
local itemRefreshDeferred = false

local function ApplyItemInfoRefresh()
    itemRefreshTimer = nil
    if not (frame and frame:IsShown()) or viewingCharacter then
        wipe(pendingItemRefresh)
        return
    end
    if InCombatLockdown() then
        itemRefreshDeferred = true
        return
    end
    itemRefreshDeferred = false

    local ItemScanner = ns:GetModule("ItemScanner")
    if not ItemScanner then
        wipe(pendingItemRefresh)
        return
    end

    local iconSize = Database:GetSetting("iconSize")
    local hasSearch = SearchBar:HasActiveFilters(frame)
    local bank = BankScanner:GetCachedBank() or {}
    local isReadOnly = viewingCharacter ~= nil or not BankScanner:IsBankOpen()
    local repainted = 0
    for _, button in ipairs(itemButtons) do
        local oldData = button.itemData
        if oldData and oldData.itemID and pendingItemRefresh[oldData.itemID]
            and oldData.bagID and oldData.slot then
            local newData = ItemScanner:ScanSlot(oldData.bagID, oldData.slot)
            if newData and newData.itemID == oldData.itemID then
                local bagData = bank[oldData.bagID]
                if bagData and bagData.slots then
                    bagData.slots[oldData.slot] = newData
                end
                ItemButton:SetItem(button, newData, iconSize, isReadOnly)
                if hasSearch then
                    ItemButton:SetSearchState(button, SearchBar:ItemMatchesFilters(frame, newData))
                else
                    ItemButton:ClearSearchState(button)
                end
                repainted = repainted + 1
            end
        end
    end
    wipe(pendingItemRefresh)
    if repainted > 0 then
        ns:Debug("BankFrame: GET_ITEM_INFO_RECEIVED repainted", repainted, "buttons")
    end
end

local function ScheduleItemRefresh()
    if itemRefreshTimer then return end
    itemRefreshTimer = C_Timer.NewTimer(0.15, ApplyItemInfoRefresh)
end

Events:Register("GET_ITEM_INFO_RECEIVED", function(_, itemID, success)
    if not success or not itemID then return end
    if not (frame and frame:IsShown()) or viewingCharacter then return end
    pendingItemRefresh[itemID] = true
    ScheduleItemRefresh()
end, BankFrame)

Events:Register("PLAYER_REGEN_ENABLED", function()
    if itemRefreshDeferred and next(pendingItemRefresh) then
        ScheduleItemRefresh()
    end
end, "BankFrame.ItemInfoRefresh")

-- Combat start: release the bank's retained (held-while-hidden) buttons so an
-- in-combat bag open can reuse the shared ItemButton pool without creating new
-- secure frames (forbidden in combat). Releasing uses SetShown — combat-safe.
-- The bank is only reopened out of combat, so it simply rebuilds next time.
Events:Register("PLAYER_REGEN_DISABLED", function()
    BankFrame:ReleaseHeld()
end, "BankFrame.CombatPoolRelease")

-- Update item lock state (when picking up/putting down items)
Events:Register("ITEM_LOCK_CHANGED", function(event, bagID, slotID)
    -- Skip when viewing cached character - lock state is for current character only
    if viewingCharacter then return end
    if frame and frame:IsShown() and bagID and slotID then
        ItemButton:UpdateLockForItem(bagID, slotID)
    end
end, BankFrame)

-- Refresh charge counters after the player casts something. Mirrors BagFrame —
-- handles the case where bank-stored charge items (or items in bags while bank
-- is open) decrement charges without triggering BAG_UPDATE. The pending flag
-- coalesces rapid casts into a single refresh.
local chargesRefreshPending = false
Events:Register("UNIT_SPELLCAST_SUCCEEDED", function(event, unit)
    if unit ~= "player" then return end
    if not frame or not frame:IsShown() then return end
    if viewingCharacter then return end
    if chargesRefreshPending then return end
    chargesRefreshPending = true
    C_Timer.After(0.05, function()
        chargesRefreshPending = false
        BankFrame:RefreshChargesOnly()
    end)
end, BankFrame)

-- Callback for when Retail bank tab changes
ns.OnRetailBankTabChanged = function(tabIndex)
    if frame and frame:IsShown() then
        ns:ProfileStart("Bank.tabswitch")
        -- Update side tab selection visuals
        BankFrame:UpdateSideTabSelection()
        -- Refresh the display with the new tab filter
        BankFrame:Refresh()
        ns:ProfileStop("Bank.tabswitch")
    end
end

-- Callback for when bank tabs are purchased/changed
ns.OnRetailBankTabsUpdated = function()
    if frame and frame:IsShown() then
        BankFrame:HidePurchasePrompt()
        local bankType = BankFooter:GetCurrentBankType() or "character"
        BankFrame:ShowSideTabs(nil, bankType)
        BankFrame:Refresh()
    end
end

-- Callback for when bank type changes (Character Bank vs Warband Bank)
ns.OnBankTypeChanged = function(bankType)
    if frame and frame:IsShown() then
        ns:ProfileStart("Bank.typeswitch")
        -- Hide purchase prompt if it was showing
        if showingPurchasePrompt then
            BankFrame:HidePurchasePrompt()
            frame.container:Show()
        end

        ns:Debug("Bank type changed to:", bankType)

        -- Update RetailBankScanner's current bank type so BAG_UPDATE events are processed correctly
        if RetailBankScanner then
            local bankTypeEnum = bankType == "warband" and Enum.BankType.Account or Enum.BankType.Character
            RetailBankScanner:SetCurrentBankType(bankTypeEnum)
            RetailBankScanner:SetSelectedTab(0)  -- Reset tab selection to "All"
            -- Rescan the new bank type to get fresh data
            if BankScanner:IsBankOpen() then
                RetailBankScanner:ScanAllBank()
            end
        end

        -- Get the character being viewed
        local characterFullName = viewingCharacter or Database:GetPlayerFullName()

        -- Refresh side tabs for the new bank type
        BankFrame:ShowSideTabs(characterFullName, bankType)

        -- Update footer action buttons for the new bank type
        local isBankOpen = BankScanner and BankScanner:IsBankOpen()
        BankFooter:UpdateRetailActionButtons(isBankOpen, bankType)

        -- Refresh the display with the new bank type's data
        BankFrame:Refresh()
        ns:ProfileStop("Bank.typeswitch")
    end
end
