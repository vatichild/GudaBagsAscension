local addonName, ns = ...

-- Guild Bank is available in TBC and later (check feature flag)
local Constants = ns.Constants
if not Constants or not Constants.FEATURES or not Constants.FEATURES.GUILD_BANK then
    return
end

local GuildBankScanner = {}
ns:RegisterModule("GuildBankScanner", GuildBankScanner)

local Constants = ns.Constants
local Database = ns:GetModule("Database")
local Events = ns:GetModule("Events")


-- Cache for scanned guild bank data
local cachedGuildBank = {}
local cachedTabInfo = {}  -- Tab name, icon, permissions
local isGuildBankOpen = false
local selectedTabIndex = 0  -- 0 = all tabs, 1+ = specific tab
local currentGuildName = nil

-- Dirty tracking for incremental updates
local dirtyTabs = {}
local pendingUpdate = false
local saveTimer = nil
local SAVE_DELAY = 1.0

-- Create frame for OnUpdate batching
local updateFrame = CreateFrame("Frame")
updateFrame:Hide()

-- Server denies QueryGuildBankTab on tabs the player cannot view, producing
-- "You don't have permission to do that" chat spam. Skip those tabs.
local function QueryViewableTab(tabIndex)
    local _, _, isViewable = GetGuildBankTabInfo(tabIndex)
    if isViewable then
        QueryGuildBankTab(tabIndex)
    end
end

-------------------------------------------------
-- Guild Bank State
-------------------------------------------------

function GuildBankScanner:IsGuildBankOpen()
    return isGuildBankOpen
end

function GuildBankScanner:GetCurrentGuildName()
    if currentGuildName then
        return currentGuildName
    end
    -- Get guild name from API
    local guildName = GetGuildInfo("player")
    return guildName
end

-------------------------------------------------
-- Tab Management
-------------------------------------------------

function GuildBankScanner:GetNumTabs()
    return GetNumGuildBankTabs() or 0
end

function GuildBankScanner:GetTabInfo(tabIndex)
    if not tabIndex or tabIndex < 1 then return nil end

    -- Try cached info first
    if cachedTabInfo[tabIndex] then
        return cachedTabInfo[tabIndex]
    end

    -- Get from API
    local name, icon, isViewable, canDeposit, numWithdrawals, remainingWithdrawals = GetGuildBankTabInfo(tabIndex)
    if not name or name == "" then
        name = string.format("Tab %d", tabIndex)
    end

    return {
        index = tabIndex,
        name = name,
        icon = icon or "Interface\\Icons\\INV_Misc_Bag_10",
        isViewable = isViewable,
        canDeposit = canDeposit,
        numWithdrawals = numWithdrawals,
        remainingWithdrawals = remainingWithdrawals,
    }
end

function GuildBankScanner:GetAllTabInfo()
    local tabs = {}
    local numTabs = self:GetNumTabs()

    for i = 1, numTabs do
        local tabInfo = self:GetTabInfo(i)
        if tabInfo then
            table.insert(tabs, tabInfo)
        end
    end

    return tabs
end

function GuildBankScanner:CacheTabInfo()
    cachedTabInfo = {}
    local numTabs = self:GetNumTabs()

    for i = 1, numTabs do
        cachedTabInfo[i] = self:GetTabInfo(i)
    end

    return cachedTabInfo
end

function GuildBankScanner:GetCachedTabInfo()
    return cachedTabInfo
end

-- Tab selection for viewing
function GuildBankScanner:GetSelectedTab()
    return selectedTabIndex
end

function GuildBankScanner:SetSelectedTab(tabIndex)
    selectedTabIndex = tabIndex or 0
    -- Fire callback for UI refresh
    if ns.OnGuildBankTabChanged then
        ns.OnGuildBankTabChanged(selectedTabIndex)
    end
end

-------------------------------------------------
-- Scanning
-------------------------------------------------

function GuildBankScanner:ScanSlot(tabIndex, slotIndex)
    local texture, itemCount, locked, isFiltered, quality = GetGuildBankItemInfo(tabIndex, slotIndex)

    if not texture then
        return nil
    end

    local itemLink = GetGuildBankItemLink(tabIndex, slotIndex)
    if not itemLink then
        return nil
    end

    -- NOT GetItemInfoInstant(itemLink): on Ascension that global is the client's
    -- own DBC lookup, which takes an itemID (not a link) and returns a TABLE.
    -- Passing a link returned nil here, so every guild bank slot was skipped.
    -- Parsing the link is correct on every flavour.
    local itemID = tonumber(itemLink:match("item:(%d+)"))
    if not itemID then
        return nil
    end

    local itemName, _, itemQuality, itemLevel, itemMinLevel, itemType, itemSubType,
          itemStackCount, itemEquipLoc, itemTexture, sellPrice, classID, subclassID = GetItemInfo(itemLink)
    -- 3.3.5a's GetItemInfo has no 12th/13th return, and this site stores the raw
    -- value with no default -- so without this the guild bank stores nil classIDs.
    if classID == nil and ns.Compat then
        classID, subclassID = ns.Compat.ResolveItemClassIDs(itemType, itemSubType, itemID)
    end

    return {
        itemID = itemID,
        itemLink = itemLink,
        name = itemName or "",
        texture = texture or itemTexture,
        count = itemCount or 1,
        quality = quality or itemQuality or 0,
        locked = locked,
        itemType = itemType,
        itemSubType = itemSubType,
        itemEquipLoc = itemEquipLoc,
        sellPrice = sellPrice,
        classID = classID,
        subclassID = subclassID,
        tabIndex = tabIndex,
        slotIndex = slotIndex,
    }
end

function GuildBankScanner:ScanTab(tabIndex)
    if not isGuildBankOpen then
        ns:Debug("ScanTab: Guild bank not open, returning cached for tab", tabIndex)
        return cachedGuildBank[tabIndex]
    end

    if not tabIndex or tabIndex < 1 then
        ns:Debug("ScanTab: Invalid tabIndex", tabIndex)
        return nil
    end

    local tabInfo = self:GetTabInfo(tabIndex)
    ns:Debug("ScanTab: tab", tabIndex, "tabInfo =", tabInfo and tabInfo.name or "nil", "viewable =", tabInfo and tabInfo.isViewable)

    if not tabInfo or not tabInfo.isViewable then
        ns:Debug("ScanTab: Tab not viewable, skipping")
        return nil
    end

    local tabData = {
        tabIndex = tabIndex,
        name = tabInfo.name,
        icon = tabInfo.icon,
        numSlots = Constants.GUILD_BANK_SLOTS_PER_TAB,
        freeSlots = 0,
        slots = {},
    }

    local itemCount = 0
    for slot = 1, Constants.GUILD_BANK_SLOTS_PER_TAB do
        local itemData = self:ScanSlot(tabIndex, slot)
        if itemData then
            tabData.slots[slot] = itemData
            itemCount = itemCount + 1
        else
            tabData.freeSlots = tabData.freeSlots + 1
        end
    end

    ns:Debug("ScanTab: tab", tabIndex, "scanned", itemCount, "items,", tabData.freeSlots, "free slots")

    -- Cache the result
    cachedGuildBank[tabIndex] = tabData

    return tabData
end

function GuildBankScanner:ScanAllTabs()
    if not isGuildBankOpen then
        ns:Debug("ScanAllTabs: Guild bank not open, returning cached data")
        return cachedGuildBank
    end

    local numTabs = self:GetNumTabs()
    ns:Debug("ScanAllTabs: numTabs =", numTabs)

    if numTabs == 0 then
        ns:Debug("ScanAllTabs: No tabs found")
        return cachedGuildBank
    end

    -- Query all tabs to request data from server
    for i = 1, numTabs do
        ns:Debug("ScanAllTabs: Querying tab", i)
        QueryViewableTab(i)
    end

    -- Scan each tab (data may not be fully loaded yet, but scan what's available)
    for i = 1, numTabs do
        self:ScanTab(i)
    end

    ns:Debug("ScanAllTabs: Complete, cached tabs =", self:CountCachedTabs())
    return cachedGuildBank
end

function GuildBankScanner:CountCachedTabs()
    local count = 0
    for _ in pairs(cachedGuildBank) do
        count = count + 1
    end
    return count
end

function GuildBankScanner:GetCachedGuildBank()
    return cachedGuildBank
end

function GuildBankScanner:GetCachedTab(tabIndex)
    return cachedGuildBank[tabIndex]
end

-------------------------------------------------
-- Slot Counts
-------------------------------------------------

function GuildBankScanner:GetTotalSlots()
    local total = 0
    local free = 0

    for tabIndex, tabData in pairs(cachedGuildBank) do
        total = total + (tabData.numSlots or 0)
        free = free + (tabData.freeSlots or 0)
    end

    return total, free
end

function GuildBankScanner:GetTabSlots(tabIndex)
    local tabData = cachedGuildBank[tabIndex]
    if not tabData then return 0, 0 end

    return tabData.numSlots or 0, tabData.freeSlots or 0
end

-------------------------------------------------
-- Database
-------------------------------------------------

function GuildBankScanner:SaveToDatabase()
    local guildName = self:GetCurrentGuildName()
    if not guildName then
        ns:Debug("GuildBankScanner: Cannot save - no guild name")
        return
    end

    local tabCount = self:CountCachedTabs()
    ns:Debug("SaveToDatabase: guildName =", guildName, "cachedTabs =", tabCount)

    if tabCount == 0 then
        ns:Debug("SaveToDatabase: No tabs to save, skipping")
        return
    end

    local guildBankData = {
        guildName = guildName,
        tabs = cachedGuildBank,
        tabInfo = cachedTabInfo,
        lastUpdate = time(),
    }

    Database:SaveGuildBank(guildName, guildBankData)
    ns:Debug("Guild bank saved for:", guildName, "with", tabCount, "tabs")
end

function GuildBankScanner:LoadFromDatabase(guildName)
    guildName = guildName or self:GetCurrentGuildName()
    if not guildName then
        ns:Debug("LoadFromDatabase: No guild name")
        return
    end

    ns:Debug("LoadFromDatabase: Looking for guild:", guildName)

    -- Debug: Show all stored guild names
    local allGuilds = Database:GetAllGuildBanks()
    if allGuilds then
        for storedName, _ in pairs(allGuilds) do
            ns:Debug("LoadFromDatabase: Found stored guild:", storedName)
        end
    else
        ns:Debug("LoadFromDatabase: No guild banks stored in database")
    end

    local guildBankData = Database:GetGuildBank(guildName)
    if guildBankData and guildBankData.tabs then
        -- Normalize tab data (numeric keys may be stored as strings in SavedVariables)
        cachedGuildBank = {}
        for tabKey, tabData in pairs(guildBankData.tabs) do
            if type(tabData) == "table" then
                local normalizedTabIndex = tonumber(tabKey) or tabKey
                local normalizedTab = {
                    tabIndex = tabData.tabIndex,
                    name = tabData.name,
                    icon = tabData.icon,
                    numSlots = tabData.numSlots,
                    freeSlots = tabData.freeSlots,
                    slots = {},
                }
                if tabData.slots then
                    for slotKey, slotData in pairs(tabData.slots) do
                        normalizedTab.slots[tonumber(slotKey) or slotKey] = slotData
                    end
                end
                cachedGuildBank[normalizedTabIndex] = normalizedTab
            end
        end

        -- Normalize tab info as well
        cachedTabInfo = {}
        if guildBankData.tabInfo then
            for tabKey, tabInfo in pairs(guildBankData.tabInfo) do
                local normalizedIndex = tonumber(tabKey) or tabKey
                cachedTabInfo[normalizedIndex] = tabInfo
            end
        end

        ns:Debug("Loaded cached guild bank for:", guildName, "tabs =", self:CountCachedTabs())
    else
        ns:Debug("No guild bank data found in database for:", guildName)
    end
end

-------------------------------------------------
-- Deferred Save
-------------------------------------------------

local function ScheduleDeferredSave()
    if saveTimer then
        saveTimer:Cancel()
    end
    saveTimer = C_Timer.NewTimer(SAVE_DELAY, function()
        GuildBankScanner:SaveToDatabase()
        saveTimer = nil
        ns:Debug("Deferred guild bank database save complete")
    end)
end

-------------------------------------------------
-- Batched Updates
-------------------------------------------------

local function ProcessBatchedUpdates()
    if not pendingUpdate then return end
    if not isGuildBankOpen then
        pendingUpdate = false
        updateFrame:Hide()
        return
    end

    local tabsToScan = dirtyTabs
    dirtyTabs = {}
    pendingUpdate = false
    updateFrame:Hide()

    for tabIndex in pairs(tabsToScan) do
        GuildBankScanner:ScanTab(tabIndex)
    end

    ScheduleDeferredSave()

    ns:Debug("Guild bank batched scan complete")

    if ns.OnGuildBankUpdated then
        ns.OnGuildBankUpdated(tabsToScan)
    end
end

updateFrame:SetScript("OnUpdate", ProcessBatchedUpdates)

local function OnGuildBankUpdate(tabIndex)
    if not isGuildBankOpen then return end

    if tabIndex then
        dirtyTabs[tabIndex] = true
    end

    if not pendingUpdate then
        pendingUpdate = true
        updateFrame:Show()
    end
end

-------------------------------------------------
-- Event Handlers
-------------------------------------------------

-- Common handler for guild bank opened (used by multiple detection methods)
local function HandleGuildBankOpened()
    if isGuildBankOpen then
        ns:Debug("HandleGuildBankOpened: Already open, skipping")
        return
    end

    isGuildBankOpen = true
    currentGuildName = GetGuildInfo("player")
    selectedTabIndex = 0  -- Reset to show all tabs

    ns:Debug("Guild bank opened for:", currentGuildName or "unknown")

    -- Cache tab info
    GuildBankScanner:CacheTabInfo()

    -- Query all tabs to request data
    local numTabs = GuildBankScanner:GetNumTabs()
    ns:Debug("  numTabs =", numTabs)
    for i = 1, numTabs do
        QueryViewableTab(i)
    end

    -- Initial scan (may have partial data)
    GuildBankScanner:ScanAllTabs()

    -- Show the frame immediately (GUILDBANKBAGSLOTS_CHANGED will trigger refresh when data arrives)
    if ns.OnGuildBankOpened then
        ns.OnGuildBankOpened()
    end

    -- Save initial data to database
    GuildBankScanner:SaveToDatabase()
end

-- Common handler for guild bank closed
local function HandleGuildBankClosed()
    if not isGuildBankOpen then
        ns:Debug("HandleGuildBankClosed: Already closed, skipping")
        return
    end

    isGuildBankOpen = false
    dirtyTabs = {}

    ns:Debug("Guild bank closed")

    if ns.OnGuildBankClosed then
        ns.OnGuildBankClosed()
    end
end

-- Try to register GUILDBANKFRAME_OPENED/CLOSED events (works on some versions)
Events:Register("GUILDBANKFRAME_OPENED", function()
    ns:Debug("GUILDBANKFRAME_OPENED event fired")
    HandleGuildBankOpened()
end, GuildBankScanner)

Events:Register("GUILDBANKFRAME_CLOSED", function()
    ns:Debug("GUILDBANKFRAME_CLOSED event fired")
    HandleGuildBankClosed()
end, GuildBankScanner)

-- TBC/Classic fallback: Hook into Blizzard's GuildBankFrame when it loads
-- The GUILDBANKFRAME_OPENED event doesn't exist in TBC, so we hook the frame
local blizzardFrameHooked = false
local blizzardOnShowScript = nil
local blizzardOnHideScript = nil
local weAreHidingBlizzardFrame = false  -- Flag to track when WE hide vs Blizzard hides

local function HookBlizzardGuildBankFrame()
    if blizzardFrameHooked then return end

    local blizzFrame = _G.GuildBankFrame
    if not blizzFrame then
        ns:Debug("HookBlizzardGuildBankFrame: GuildBankFrame not found")
        return
    end

    ns:Debug("Hooking Blizzard GuildBankFrame OnShow/OnHide")
    blizzardFrameHooked = true

    -- Use HookScript instead of SetScript to avoid tainting Blizzard's secure frame state
    blizzFrame:HookScript("OnShow", function(self)
        ns:Debug("Blizzard GuildBankFrame OnShow triggered")

        -- Make Blizzard frame invisible but keep it "shown"
        -- This prevents OnHide from firing unexpectedly
        self:SetAlpha(0)
        self:ClearAllPoints()
        self:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -10000, 10000)
        self:EnableMouse(false)  -- Prevent mouse interaction

        -- Now handle our guild bank open
        HandleGuildBankOpened()
    end)

    blizzFrame:HookScript("OnHide", function(self)
        ns:Debug("Blizzard GuildBankFrame OnHide triggered")

        -- Restore for next time
        self:SetAlpha(1)
        self:EnableMouse(true)

        -- Close our frame
        HandleGuildBankClosed()
    end)
end

-- Listen for Blizzard_GuildBankUI addon loading (TBC loads it on demand)
Events:Register("ADDON_LOADED", function(event, addonName)
    if addonName == "Blizzard_GuildBankUI" then
        ns:Debug("Blizzard_GuildBankUI loaded, hooking frame")
        -- Hook immediately - no delay needed
        HookBlizzardGuildBankFrame()
    end
end, GuildBankScanner)

-- Also try to hook immediately if addon is already loaded
if IsAddOnLoaded and IsAddOnLoaded("Blizzard_GuildBankUI") then
    HookBlizzardGuildBankFrame()
end

-- Debounce timer for guild bank slot changes
local slotChangeTimer = nil
local scanTimer = nil
local isQueryingTabs = false  -- Track when we initiated queries (to ignore resulting events)
local queryStartTime = 0

Events:Register("GUILDBANKBAGSLOTS_CHANGED", function()
    if not isGuildBankOpen then return end

    local now = GetTime()
    ns:Debug("GUILDBANKBAGSLOTS_CHANGED fired, querying:", isQueryingTabs, "elapsed:", now - queryStartTime)

    -- If this event is from our own query (within 0.5s), ignore it
    if isQueryingTabs and (now - queryStartTime) < 0.5 then
        ns:Debug("  Ignoring event from our own query")
        return
    end

    -- Cancel any pending timers
    if slotChangeTimer then
        slotChangeTimer:Cancel()
        slotChangeTimer = nil
    end
    if scanTimer then
        scanTimer:Cancel()
        scanTimer = nil
    end

    -- First phase: Query all tabs to request fresh data from server
    slotChangeTimer = C_Timer.NewTimer(0.1, function()
        slotChangeTimer = nil

        if not isGuildBankOpen then return end

        local numTabs = GuildBankScanner:GetNumTabs()
        ns:Debug("  Querying", numTabs, "tabs for fresh data")

        isQueryingTabs = true
        queryStartTime = GetTime()

        -- Query all tabs
        for i = 1, numTabs do
            QueryViewableTab(i)
        end

        -- Second phase: After queries, scan the data
        scanTimer = C_Timer.NewTimer(0.3, function()
            scanTimer = nil
            isQueryingTabs = false

            if not isGuildBankOpen then return end

            ns:Debug("  Scanning", numTabs, "tabs after query")

            -- Scan all tabs
            for i = 1, numTabs do
                GuildBankScanner:ScanTab(i)
            end

            -- Save to database
            ScheduleDeferredSave()

            -- Notify UI to refresh
            if ns.OnGuildBankUpdated then
                ns.OnGuildBankUpdated()
            end
        end)
    end)
end, GuildBankScanner)

-- Item lock changed (item picked up or placed down)
Events:Register("GUILDBANK_ITEM_LOCK_CHANGED", function(event, tabIndex, slotIndex)
    if not isGuildBankOpen then return end

    ns:Debug("GUILDBANK_ITEM_LOCK_CHANGED fired, tab:", tabIndex, "slot:", slotIndex)

    -- This event is more specific - we know exactly which tab changed
    -- Cancel existing timers and start fresh
    if slotChangeTimer then
        slotChangeTimer:Cancel()
        slotChangeTimer = nil
    end
    if scanTimer then
        scanTimer:Cancel()
        scanTimer = nil
    end

    local targetTab = tabIndex

    -- Query the specific tab, then scan
    slotChangeTimer = C_Timer.NewTimer(0.1, function()
        slotChangeTimer = nil

        if not isGuildBankOpen then return end

        -- Query the specific tab
        if targetTab and QueryGuildBankTab then
            ns:Debug("  Querying tab", targetTab, "after item lock change")
            isQueryingTabs = true
            queryStartTime = GetTime()
            QueryViewableTab(targetTab)
        end

        -- Scan after query
        scanTimer = C_Timer.NewTimer(0.2, function()
            scanTimer = nil
            isQueryingTabs = false

            if not isGuildBankOpen then return end

            -- Rescan all tabs
            local numTabs = GuildBankScanner:GetNumTabs()
            ns:Debug("  Scanning", numTabs, "tabs after lock change")

            for i = 1, numTabs do
                GuildBankScanner:ScanTab(i)
            end

            -- Save to database
            ScheduleDeferredSave()

            -- Notify UI to refresh
            if ns.OnGuildBankUpdated then
                ns.OnGuildBankUpdated()
            end
        end)
    end)
end, GuildBankScanner)

Events:Register("GUILDBANK_UPDATE_TABS", function()
    if not isGuildBankOpen then return end

    -- Tab info changed (permissions, names, etc.)
    GuildBankScanner:CacheTabInfo()

    if ns.OnGuildBankTabsUpdated then
        ns.OnGuildBankTabsUpdated()
    end
end, GuildBankScanner)

Events:Register("GUILDBANK_UPDATE_TEXT", function(event, tabIndex)
    if not isGuildBankOpen then return end

    -- Tab info text updated
    if tabIndex then
        local tabInfo = GuildBankScanner:GetTabInfo(tabIndex)
        if tabInfo then
            cachedTabInfo[tabIndex] = tabInfo
        end
    end
end, GuildBankScanner)

-- Guild bank money changed (deposit/withdraw)
Events:Register("GUILDBANK_UPDATE_MONEY", function()
    if not isGuildBankOpen then return end

    ns:Debug("GUILDBANK_UPDATE_MONEY fired")

    -- Notify UI to update money display
    if ns.OnGuildBankMoneyUpdated then
        ns.OnGuildBankMoneyUpdated()
    end
end, GuildBankScanner)

-- PLAYER_INTERACTION_MANAGER for modern WoW (MoP Remix+, Retail, TWW)
-- This fires BEFORE Blizzard's frame shows, allowing preemptive hiding
local Expansion = ns:GetModule("Expansion")
if Expansion and Expansion.InterfaceVersion and Expansion.InterfaceVersion >= 50000 then
    -- Check if the enum exists (modern WoW only)
    if Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.GuildBanker then
        local GUILD_BANKER_TYPE = Enum.PlayerInteractionType.GuildBanker

        Events:Register("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(event, interactionType)
            if interactionType == GUILD_BANKER_TYPE then
                ns:Debug("PLAYER_INTERACTION_MANAGER_FRAME_SHOW: GuildBanker")

                -- Set state - guild bank is now open
                isGuildBankOpen = true
                currentGuildName = GetGuildInfo("player")
                selectedTabIndex = 0  -- Reset to show all tabs

                ns:Debug("  Guild bank opened for:", currentGuildName or "unknown")

                -- Cache tab info
                GuildBankScanner:CacheTabInfo()

                -- Query all tabs to request data
                local numTabs = GuildBankScanner:GetNumTabs()
                ns:Debug("  numTabs =", numTabs)
                for i = 1, numTabs do
                    QueryViewableTab(i)
                end

                -- Initial scan
                GuildBankScanner:ScanAllTabs()

                -- Preemptively hide Blizzard frame before it shows
                -- Note: OnGuildBankOpened will handle the detailed hiding

                -- Show our custom frame
                if ns.OnGuildBankOpened then
                    ns.OnGuildBankOpened()
                end

                -- Save to database
                GuildBankScanner:SaveToDatabase()
            end
        end, GuildBankScanner)

        Events:Register("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", function(event, interactionType)
            if interactionType == GUILD_BANKER_TYPE then
                ns:Debug("PLAYER_INTERACTION_MANAGER_FRAME_HIDE: GuildBanker")

                -- Set state - guild bank is now closed
                isGuildBankOpen = false
                dirtyTabs = {}

                -- Close our custom frame
                if ns.OnGuildBankClosed then
                    ns.OnGuildBankClosed()
                end
            end
        end, GuildBankScanner)

    end
end

-- Load cached guild bank on player login
Events:OnPlayerLogin(function()
    local guildName = GetGuildInfo("player")
    if guildName then
        currentGuildName = guildName
        GuildBankScanner:LoadFromDatabase(guildName)
    end
end, GuildBankScanner)

