local addonName, ns = ...

-- Guild Bank is available in TBC and later (check feature flag)
local Constants = ns.Constants

local CreateFrame = ns.CreateFrame or CreateFrame
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

-- Query suppression. Declared here rather than next to the
-- GUILDBANKBAGSLOTS_CHANGED handler because the OPEN path has to set them too:
-- the server's replies to the opening queries arrive as GUILDBANKBAGSLOTS_CHANGED,
-- and without this window each reply scheduled another full query-all + rescan-all
-- cycle -- the storm that made a cold open crawl.
local isQueryingTabs = false
local queryStartTime = 0

-- Set while Sorting\GuildBankSort.lua is moving items. The move events are its
-- clock, so the data handlers below stand down for the duration rather than
-- re-querying and re-rendering after every single swap.
local sortInProgress = false

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

--- Slots in one tab, asked of the CLIENT rather than hardcoded.
---
--- Constants.GUILD_BANK_SLOTS_PER_TAB is stock 3.3.5a's 98 (14x7). A server that
--- resizes its guild bank tabs also resizes the FrameXML constant its own guild
--- bank UI lays out from, so reading that first is what keeps the slot counter
--- honest here -- scanning 98 slots on a smaller tab counts the phantom ones as
--- free, which is how "11/294" happens.
function GuildBankScanner:GetSlotsPerTab()
    local clientValue = _G.MAX_GUILDBANK_SLOTS_PER_TAB
    if type(clientValue) == "number" and clientValue > 0 then
        return clientValue
    end
    return Constants.GUILD_BANK_SLOTS_PER_TAB
end

function GuildBankScanner:GetNumTabs()
    return GetNumGuildBankTabs() or 0
end

--- Sorting\GuildBankSort.lua flags its runs here so the data handlers ignore the
--- move traffic they would otherwise treat as "someone changed the bank".
function GuildBankScanner:SetSortInProgress(active)
    sortInProgress = active and true or false
end

function GuildBankScanner:IsSortInProgress()
    return sortInProgress
end

--- Ask the server for one tab's contents again.
---
--- Both data handlers stop querying while a sort runs (see SetSortInProgress), so
--- the sorter needs a way to nudge the client itself when a move has not shown up
--- in GetGuildBankItemLink yet. Same permission guard as every other query.
function GuildBankScanner:RequeryTab(tabIndex)
    if not isGuildBankOpen or not tabIndex or tabIndex < 1 then return end
    QueryViewableTab(tabIndex)
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

    -- Tell the CLIENT which tab we are showing, not just ourselves.
    --
    -- The server tracks a current guild bank tab, and Blizzard's own UI sets it
    -- whenever a tab is selected -- but we replace that UI (and now stop it
    -- loading at all), and the only SetCurrentGuildBankTab call left in the addon
    -- is on the side tabs' right-click menu. The Personal Bank hides those tabs
    -- entirely, so nothing was setting it there. Bagnon addresses every guild
    -- bank operation with GetCurrentGuildBankTab(), which is why its moves work.
    if selectedTabIndex > 0 and isGuildBankOpen and SetCurrentGuildBankTab then
        local _, _, isViewable = GetGuildBankTabInfo(selectedTabIndex)
        if isViewable then
            SetCurrentGuildBankTab(selectedTabIndex)
        end
    end

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
        -- Stored, not discarded: Sorting\GuildBankSort.lua's "ilvl" priority reads
        -- this, and without it every entry compares as itemLevel 0 and the setting
        -- silently degrades to quality-then-class.
        itemLevel = itemLevel or 0,
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

    local slotsPerTab = self:GetSlotsPerTab()
    local tabData = {
        tabIndex = tabIndex,
        name = tabInfo.name,
        icon = tabInfo.icon,
        numSlots = slotsPerTab,
        freeSlots = 0,
        slots = {},
    }

    local itemCount = 0
    for slot = 1, slotsPerTab do
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

--- Tabs worth querying and scanning, as a plain array.
---
--- The Personal Bank is displayed as tab 1 only (UI\GuildBankFrame.lua pins the
--- selection), but this client reports THREE tabs for it -- so scanning "all"
--- meant 3 server queries and 294 slot reads per pass to render 98 slots. The
--- guild bank still scans every tab: its All-Tabs view shows them, and its cache
--- feeds the offline view.
function GuildBankScanner:GetScanTabs()
    local numTabs = self:GetNumTabs()
    if numTabs == 0 then return {} end

    if self:GetSessionKind() == "personal" then
        return { 1 }
    end

    local tabs = {}
    for i = 1, numTabs do tabs[i] = i end
    return tabs
end

function GuildBankScanner:ScanAllTabs()
    if not isGuildBankOpen then
        ns:Debug("ScanAllTabs: Guild bank not open, returning cached data")
        return cachedGuildBank
    end

    local tabs = self:GetScanTabs()
    ns:Debug("ScanAllTabs: scanning", #tabs, "of", self:GetNumTabs(), "tabs")

    if #tabs == 0 then
        ns:Debug("ScanAllTabs: No tabs found")
        return cachedGuildBank
    end

    -- Query first, so the server is already answering while we scan what it sent
    -- last time. Marked as ours: the replies land as GUILDBANKBAGSLOTS_CHANGED,
    -- and each unsuppressed reply would otherwise schedule another full cycle.
    isQueryingTabs = true
    queryStartTime = GetTime()
    for _, i in ipairs(tabs) do
        ns:Debug("ScanAllTabs: Querying tab", i)
        QueryViewableTab(i)
    end

    -- Scan each tab (data may not be fully loaded yet, but scan what's available)
    for _, i in ipairs(tabs) do
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

--- Cache key for the Personal Bank: it belongs to the character, not the guild.
--- Same "Name-Realm" shape Database uses for its per-character records.
function GuildBankScanner:GetPersonalBankKey()
    local name = UnitName("player")
    if not name then return nil end
    local realm = GetRealmName and GetRealmName() or ""
    return realm ~= "" and (name .. "-" .. realm) or name
end

function GuildBankScanner:SaveToDatabase()
    local tabCount = self:CountCachedTabs()
    if tabCount == 0 then
        ns:Debug("SaveToDatabase: No tabs to save, skipping")
        return
    end

    -- The Personal Bank arrives over the guild bank API but is the character's
    -- own. Saving it under the guild name overwrote the guild bank's cached
    -- contents with personal ones on every visit.
    if self:GetSessionKind() == "personal" then
        local charKey = self:GetPersonalBankKey()
        if not charKey then
            ns:Debug("SaveToDatabase: Cannot save personal bank - no character name")
            return
        end
        Database:SavePersonalBank(charKey, {
            charKey = charKey,
            tabs = cachedGuildBank,
            tabInfo = cachedTabInfo,
            lastUpdate = time(),
        })
        ns:Debug("Personal bank saved for:", charKey, "with", tabCount, "tabs")
        return
    end

    local guildName = self:GetCurrentGuildName()
    if not guildName then
        ns:Debug("GuildBankScanner: Cannot save - no guild name")
        return
    end

    ns:Debug("SaveToDatabase: guildName =", guildName, "cachedTabs =", tabCount)

    local guildBankData = {
        guildName = guildName,
        tabs = cachedGuildBank,
        tabInfo = cachedTabInfo,
        lastUpdate = time(),
    }

    Database:SaveGuildBank(guildName, guildBankData)
    ns:Debug("Guild bank saved for:", guildName, "with", tabCount, "tabs")
end

--- Load the cached Personal Bank into the same caches the frame renders from,
--- so offline browsing needs no second render path.
function GuildBankScanner:LoadPersonalFromDatabase()
    local charKey = self:GetPersonalBankKey()
    if not charKey then return false end

    local tabs = Database:GetNormalizedPersonalBank(charKey)
    if not tabs then
        ns:Debug("No personal bank data stored for:", charKey)
        return false
    end

    cachedGuildBank = tabs
    cachedTabInfo = {}
    local storedInfo = Database:GetPersonalBankTabInfo(charKey)
    if storedInfo then
        for tabKey, tabInfo in pairs(storedInfo) do
            cachedTabInfo[tonumber(tabKey) or tabKey] = tabInfo
        end
    end

    -- Tab 1, not the merged "All Tabs" view: the offline copy is presented the
    -- same single-container way as a live personal session.
    selectedTabIndex = 1
    ns:Debug("Loaded cached personal bank for:", charKey, "tabs =", self:CountCachedTabs())
    return true
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
-- Guild Bank vs Ascension "Personal Bank"
-------------------------------------------------
-- Ascension's Personal Bank (item 110000 summons the "Personal Belongings"
-- object 46) is the guild bank system reused server-side: it sends guild bank
-- packets and fires GUILDBANKFRAME_OPENED exactly like a real guild bank, so the
-- event cannot tell them apart. What differs is the tab identity the server
-- sends with GUILDBANK_UPDATE_TABS -- which arrives AFTER the open, so the
-- classification has to wait for it.
--
-- Neither the tab name nor its icon exists anywhere in Extensions.dll or
-- Ascension.exe (checked), so both come over the wire and no client locale file
-- can rewrite them: "Personal Bank" is what a deDE client receives too.
--
-- The icon is the primary test rather than the name because it is immune to a
-- server-side rename AND to the player's guild rank. Permission-derived fields
-- (canDeposit, numWithdrawals, withdraw limit, money) are deliberately NOT used
-- to decide: a guild member with view-only rights on tab 1 has canDeposit = nil
-- on a real guild bank, which would misclassify their guild bank as personal.
local PERSONAL_BANK_ICON = "Interface\\Icons\\INV_Tabard_Awakening"
local PERSONAL_BANK_NAME = "personal bank"

--- "personal" | "guild" | "unknown" (tab identity has not arrived yet).
function GuildBankScanner:GetBankKind()
    -- A guildless character cannot open a guild bank at all, so anything that
    -- got this far is the personal one. Decided first because it needs no tab
    -- data and is therefore available immediately at open.
    if not GetGuildInfo("player") then
        return "personal"
    end

    local name, icon = GetGuildBankTabInfo(1)
    if not name or name == "" then
        return "unknown"
    end
    if icon == PERSONAL_BANK_ICON then
        return "personal"
    end
    if name:lower() == PERSONAL_BANK_NAME then
        return "personal"
    end
    return "guild"
end

function GuildBankScanner:IsPersonalBank()
    return self:GetSessionKind() == "personal"
end

-- Latched for the whole session, and the only thing the UI is allowed to read.
--
-- GetBankKind() re-derives from live tab data, which churns while a session is
-- open (tabs arrive, get re-queried, and briefly read back empty). The window
-- must not flip between personal and guild chrome underneath the player, so the
-- first non-"unknown" answer wins until the bank closes.
local sessionKind = nil

--- "personal" | "guild" | "unknown" -- the decided kind for the open session.
function GuildBankScanner:GetSessionKind()
    return sessionKind or "unknown"
end

--- Cached-browse override: the offline Personal Bank view has no session to
--- derive a kind from, so the frame states it explicitly.
function GuildBankScanner:SetSessionKind(kind)
    sessionKind = kind
end

local function ResolveBankKind()
    if not isGuildBankOpen then return end
    if sessionKind and sessionKind ~= "unknown" then return end
    local kind = GuildBankScanner:GetBankKind()
    if kind == "unknown" then return end
    sessionKind = kind
    -- Debug rather than Print: the window title names the bank now, and a
    -- permanent chat line would be user-facing text with no locale entry.
    ns:Debug(kind == "personal" and "Personal Bank Opened" or "Guild Bank Opened")
    if ns.OnGuildBankKindResolved then
        ns.OnGuildBankKindResolved(kind)
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
    sessionKind = nil

    -- Drop whatever the last session left here. cachedGuildBank survives in
    -- memory across opens, so a container with FEWER tabs than the last one
    -- inherited the extras: opening a 1-tab Personal Bank after a 3-tab guild
    -- bank kept 3 tabs' worth of slots in the cache, which is what the footer
    -- was summing. LoadFromDatabase repopulates it for the offline view.
    cachedGuildBank = {}

    ns:Debug("Guild bank opened for:", currentGuildName or "unknown")

    -- Cache tab info
    GuildBankScanner:CacheTabInfo()

    -- Only the guildless case can be decided this early; every other session is
    -- announced from GUILDBANK_UPDATE_TABS below, once the server sends the tabs.
    ResolveBankKind()

    -- Make sure the client has an active tab for this session. Blizzard's UI did
    -- this as part of showing itself; with that UI gone, an unset current tab
    -- leaves item moves addressing a tab the server does not consider active.
    if GuildBankScanner:GetNumTabs() > 0 and SetCurrentGuildBankTab then
        local current = GetCurrentGuildBankTab and GetCurrentGuildBankTab() or 0
        if not current or current < 1 then
            local _, _, isViewable = GetGuildBankTabInfo(1)
            if isViewable then
                ns:Debug("Setting current guild bank tab to 1 (was", tostring(current), ")")
                SetCurrentGuildBankTab(1)
            end
        end
    end

    ns:Debug("  numTabs =", GuildBankScanner:GetNumTabs())

    -- Initial scan. ScanAllTabs queries first and then scans, so the separate
    -- query loop that used to sit here was a second full round of server
    -- requests for the same data on every single open.
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
    sessionKind = nil

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

-- The tab identity that separates a real guild bank from Ascension's Personal
-- Bank arrives here, one or more events after the open. Fires repeatedly while
-- the window is open; ResolveBankKind latches the first real answer.
Events:Register("GUILDBANK_UPDATE_TABS", function()
    ResolveBankKind()

    -- Tabs are only known here, not at GUILDBANKFRAME_OPENED -- the server sends
    -- them afterwards. The current-tab set at open therefore runs with zero tabs
    -- and does nothing, so repeat it now that there is a tab to select.
    if isGuildBankOpen and SetCurrentGuildBankTab and GuildBankScanner:GetNumTabs() > 0 then
        local current = GetCurrentGuildBankTab and GetCurrentGuildBankTab() or 0
        if not current or current < 1 then
            local _, _, isViewable = GetGuildBankTabInfo(1)
            if isViewable then
                ns:Debug("Setting current guild bank tab to 1 from UPDATE_TABS (was",
                    tostring(current), ")")
                SetCurrentGuildBankTab(1)
            end
        end
    end
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
        --
        -- Only reachable on a client where something else loaded that UI: we
        -- block the loader outright at the bottom of this file, so normally
        -- GuildBankFrame never exists.
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
-- isQueryingTabs / queryStartTime are declared at the top of the file: the open
-- path sets them too, and re-declaring them here would shadow those, leaving the
-- opening queries' replies unsuppressed (each one then scheduling a full cycle).

Events:Register("GUILDBANKBAGSLOTS_CHANGED", function()
    if not isGuildBankOpen then return end
    -- Same reasoning as the lock handler: a sort generates this event per move
    -- and drives its own refresh when it finishes.
    if sortInProgress then return end

    -- Backstop for the announcement: if a session ever arrives without a
    -- GUILDBANK_UPDATE_TABS, the tab identity is still readable by the time slot
    -- data lands. Idempotent per session, so the usual path is a no-op here.
    ResolveBankKind()

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

        -- Only the displayed tabs, same rule as the open path: for the Personal
        -- Bank that is tab 1, not the three this client reports.
        local tabs = GuildBankScanner:GetScanTabs()
        ns:Debug("  Querying", #tabs, "tabs for fresh data")

        isQueryingTabs = true
        queryStartTime = GetTime()

        for _, i in ipairs(tabs) do
            QueryViewableTab(i)
        end

        -- Second phase: After queries, scan the data
        scanTimer = C_Timer.NewTimer(0.3, function()
            scanTimer = nil
            isQueryingTabs = false

            if not isGuildBankOpen then return end

            ns:Debug("  Scanning", #tabs, "tabs after query")

            for _, i in ipairs(tabs) do
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

    -- A sort in progress owns this event: it fires twice per swap, and the
    -- query + rescan + refresh below would run per move (~50 times for a full
    -- tab). The sorter steps on it instead and does one refresh at the end.
    if sortInProgress then
        local GuildBankSort = ns:GetModule("GuildBankSort")
        if GuildBankSort and GuildBankSort.OnLockChanged then
            GuildBankSort:OnLockChanged()
        end
        return
    end

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

            -- Rescan the displayed tabs only (see GetScanTabs)
            local tabs = GuildBankScanner:GetScanTabs()
            ns:Debug("  Scanning", #tabs, "tabs after lock change")

            for _, i in ipairs(tabs) do
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

                ns:Debug("  numTabs =", GuildBankScanner:GetNumTabs())

                -- Initial scan. ScanAllTabs queries the displayed tabs itself, so
                -- the query loop that used to sit here just doubled the requests.
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

-------------------------------------------------
-- Keep Blizzard's guild bank UI out of the way
-------------------------------------------------
-- On this client, showing Blizzard's own guild bank frame freezes the game for
-- several seconds the first time. Measured, not inferred: with GudaBags fully
-- DISABLED the default UI froze exactly the same way, while Bagnon opened the
-- same container instantly -- and our own Lua on that path totals ~320ms, with
-- the bank watch showing 4.6s in which no addon event fires at all.
--
-- Bagnon is fast because it never lets that UI exist: it replaces this FrameXML
-- loader (Bagnon\main.lua:CreateGuildBankLoader) so Blizzard_GuildBankUI is
-- never loaded. We do the same. GuildBankFrame then stays nil and Blizzard's
-- `ShowUIPanel(GuildBankFrame)` in UIParent's GUILDBANKFRAME_OPENED handler is a
-- no-op (ShowUIPanel returns early on a nil frame).
--
-- Safe here because this port drives everything from GUILDBANKFRAME_OPENED,
-- which is confirmed present on this client (Interface\AddOns\APIDocumentation
-- documents it, and the bank watch logs it on every open). The Blizzard-frame
-- HookScript fallback below stays for clients where the event is missing: it
-- simply never finds a frame to hook here.
if not ns.blizzardGuildBankBlocked and type(GuildBankFrame_LoadUI) == "function" then
    ns.blizzardGuildBankBlocked = true
    GuildBankFrame_LoadUI = function()
        ns:Debug("Blocked Blizzard_GuildBankUI load (GudaBags replaces that UI)")
    end
end

