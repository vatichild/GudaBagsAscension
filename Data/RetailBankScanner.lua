local addonName, ns = ...

-- Only load on Retail
if not ns.IsRetail then return end

local RetailBankScanner = {}
ns:RegisterModule("RetailBankScanner", RetailBankScanner)

local Constants = ns.Constants
local Database = ns:GetModule("Database")
local Events = ns:GetModule("Events")
local ItemScanner = ns:GetModule("ItemScanner")

-- Bank types
local BANK_TYPE_CHARACTER = Enum.BankType.Character
local BANK_TYPE_ACCOUNT = Enum.BankType.Account  -- Warband Bank

-- Cache for scanned bank data
local cachedCharacterBank = {}
local cachedWarbandBank = {}
local cachedBankTabs = {}  -- Cached tab info for offline viewing
local cachedWarbandTabs = {}
local isBankOpen = false
local currentBankType = BANK_TYPE_CHARACTER  -- Which bank type is currently being viewed
local selectedTabIndex = 0  -- 0 = all tabs, 1+ = specific tab

-- In modern Retail (TWW+), each bank tab is a separate container
-- Enum.BagIndex.CharacterBankTab_1 through CharacterBankTab_6

-- Dirty tracking for incremental updates
local dirtyBags = {}
local pendingUpdate = false
local saveTimer = nil
local SAVE_DELAY = 1.0

-- Create frame for OnUpdate batching
local updateFrame = CreateFrame("Frame")
updateFrame:Hide()

-------------------------------------------------
-- Bank Type Management
-------------------------------------------------

function RetailBankScanner:GetCurrentBankType()
    return currentBankType
end

function RetailBankScanner:SetCurrentBankType(bankType)
    currentBankType = bankType
end

function RetailBankScanner:GetBankTypeName(bankType)
    if bankType == BANK_TYPE_ACCOUNT then
        return "Warband Bank"
    end
    return "Bank"
end

function RetailBankScanner:GetAvailableBankTypes()
    local types = {
        { type = BANK_TYPE_CHARACTER, name = "Bank", icon = "Interface\\Icons\\INV_Misc_Bag_10_Blue" },
    }

    -- Warband bank is available at level 10+
    if C_Bank and C_Bank.CanUseBank and C_Bank.CanUseBank(BANK_TYPE_ACCOUNT) then
        table.insert(types, {
            type = BANK_TYPE_ACCOUNT,
            name = "Warband Bank",
            icon = "Interface\\Icons\\INV_Misc_Bag_17",
        })
    end

    return types
end

-------------------------------------------------
-- Tab Management
-------------------------------------------------

function RetailBankScanner:GetBankTabs(bankType)
    bankType = bankType or currentBankType

    local tabs = {}

    if not C_Bank or not C_Bank.FetchPurchasedBankTabData then
        -- Fallback: generate tabs based on containers with slots
        if bankType == BANK_TYPE_CHARACTER and Constants.CHARACTER_BANK_TABS_ACTIVE then
            for i, containerID in ipairs(Constants.CHARACTER_BANK_TAB_IDS or {}) do
                if C_Container.GetContainerNumSlots(containerID) > 0 then
                    table.insert(tabs, {
                        index = i,
                        containerID = containerID,
                        name = "Tab " .. i,
                        icon = "Interface\\Icons\\INV_Misc_Bag_10",
                    })
                end
            end
        end
        return tabs
    end

    -- For warband bank, check if it's locked first
    if bankType == BANK_TYPE_ACCOUNT then
        local warbandLocked = C_Bank.FetchBankLockedReason and C_Bank.FetchBankLockedReason(BANK_TYPE_ACCOUNT)
        if warbandLocked ~= nil then
            ns:Debug("GetBankTabs: Warband bank is locked, reason:", tostring(warbandLocked))
            return tabs
        end
    end

    local tabData = C_Bank.FetchPurchasedBankTabData(bankType)
    ns:Debug("GetBankTabs: bankType=", bankType, "tabData count=", tabData and #tabData or 0)
    if not tabData then
        return tabs
    end

    for i, tab in ipairs(tabData) do
        local containerID = nil
        if bankType == BANK_TYPE_CHARACTER and Constants.CHARACTER_BANK_TAB_IDS then
            containerID = Constants.CHARACTER_BANK_TAB_IDS[i]
        elseif bankType == BANK_TYPE_ACCOUNT and Constants.WARBAND_BANK_TAB_IDS then
            containerID = Constants.WARBAND_BANK_TAB_IDS[i]
        end

        table.insert(tabs, {
            index = i,
            containerID = containerID,
            name = tab.name or ("Tab " .. i),
            icon = tab.icon or "Interface\\Icons\\INV_Misc_Bag_10",
            depositFlags = tab.depositFlags,
        })
    end

    ns:Debug("GetBankTabs: returning", #tabs, "tabs")
    return tabs
end

function RetailBankScanner:GetNumPurchasedTabs(bankType)
    local tabs = self:GetBankTabs(bankType)
    return #tabs
end

-- Get cached tabs for offline viewing
function RetailBankScanner:GetCachedBankTabs(bankType)
    bankType = bankType or currentBankType
    if bankType == BANK_TYPE_ACCOUNT then
        return cachedWarbandTabs
    end
    return cachedBankTabs
end

-- Save tab data for offline viewing
function RetailBankScanner:CacheBankTabs(bankType)
    bankType = bankType or currentBankType
    local tabs = self:GetBankTabs(bankType)

    if bankType == BANK_TYPE_ACCOUNT then
        cachedWarbandTabs = tabs
    else
        cachedBankTabs = tabs
    end

    return tabs
end

-- Tab selection for viewing
function RetailBankScanner:GetSelectedTab()
    return selectedTabIndex
end

function RetailBankScanner:SetSelectedTab(tabIndex)
    selectedTabIndex = tabIndex or 0
    -- Fire callback for UI refresh
    if ns.OnRetailBankTabChanged then
        ns.OnRetailBankTabChanged(selectedTabIndex)
    end
end

-- Check if a container belongs to a specific tab
-- In modern Retail, each tab IS a container, so we just check container IDs
function RetailBankScanner:ContainerBelongsToTab(containerID, tabIndex, bankType)
    bankType = bankType or currentBankType

    if tabIndex == 0 then
        return true  -- All tabs
    end

    local tabContainerID = self:GetTabContainerID(tabIndex, bankType)
    return containerID == tabContainerID
end

-- Check if bank tabs are active (modern Retail)
function RetailBankScanner:AreBankTabsActive()
    return Constants.CHARACTER_BANK_TABS_ACTIVE == true
end

function RetailBankScanner:CanPurchaseTab(bankType)
    if not C_Bank or not C_Bank.CanPurchaseBankTab then
        return false
    end
    return C_Bank.CanPurchaseBankTab(bankType)
end

function RetailBankScanner:GetTabPurchaseCost(bankType)
    if not C_Bank then return nil end
    -- Use newer API (TWW 11.1+) with fallback to older API
    if C_Bank.FetchNextPurchasableBankTabData then
        local tabData = C_Bank.FetchNextPurchasableBankTabData(bankType)
        return tabData and tabData.tabCost
    elseif C_Bank.FetchNextPurchasableBankTabCost then
        return C_Bank.FetchNextPurchasableBankTabCost(bankType)
    end
    return nil
end

function RetailBankScanner:PurchaseTab(bankType)
    if not C_Bank or not C_Bank.PurchaseBankTab then
        return false
    end
    if isBankOpen and self:CanPurchaseTab(bankType) then
        C_Bank.PurchaseBankTab(bankType)
        return true
    end
    return false
end

-------------------------------------------------
-- Container ID Mapping
-------------------------------------------------

-- Get the container IDs for a bank type
function RetailBankScanner:GetBankContainerIDs(bankType, tabIndex)
    bankType = bankType or currentBankType
    tabIndex = tabIndex or 0  -- 0 = all tabs

    local containerIDs = {}

    if bankType == BANK_TYPE_CHARACTER then
        if Constants.CHARACTER_BANK_TABS_ACTIVE then
            -- Modern Retail (TWW+): Each bank tab is a separate container
            if tabIndex > 0 then
                -- Specific tab - return just that container
                local tabContainerID = Constants.CHARACTER_BANK_TAB_IDS and Constants.CHARACTER_BANK_TAB_IDS[tabIndex]
                if tabContainerID and C_Container.GetContainerNumSlots(tabContainerID) > 0 then
                    table.insert(containerIDs, tabContainerID)
                end
            else
                -- All tabs - return all purchased tab containers
                for _, tabContainerID in ipairs(Constants.CHARACTER_BANK_TAB_IDS or {}) do
                    if C_Container.GetContainerNumSlots(tabContainerID) > 0 then
                        table.insert(containerIDs, tabContainerID)
                    end
                end
            end
        else
            -- Older Retail: traditional bank structure
            table.insert(containerIDs, Enum.BagIndex.Bank)
            for i = Constants.BANK_BAG_MIN, Constants.BANK_BAG_MAX do
                if C_Container.GetContainerNumSlots(i) > 0 then
                    table.insert(containerIDs, i)
                end
            end
        end
    elseif bankType == BANK_TYPE_ACCOUNT then
        -- Warband bank: uses AccountBankTab containers
        -- Note: C_Container.GetContainerNumSlots returns 0 for warband when not at bank
        -- So we use cached tab data to know which containers exist
        if tabIndex > 0 then
            -- Specific tab
            local tabContainerID = Constants.WARBAND_BANK_TAB_IDS and Constants.WARBAND_BANK_TAB_IDS[tabIndex]
            if tabContainerID then
                local numSlots = C_Container.GetContainerNumSlots(tabContainerID)
                if numSlots > 0 or (cachedWarbandBank[tabContainerID] and cachedWarbandBank[tabContainerID].numSlots) then
                    table.insert(containerIDs, tabContainerID)
                end
            end
        else
            -- All tabs - check both live data and cached data
            for i, tabContainerID in ipairs(Constants.WARBAND_BANK_TAB_IDS or {}) do
                local numSlots = C_Container.GetContainerNumSlots(tabContainerID)
                if numSlots > 0 then
                    table.insert(containerIDs, tabContainerID)
                elseif cachedWarbandTabs[i] then
                    -- Use cached tab info when not at bank
                    table.insert(containerIDs, tabContainerID)
                end
            end
        end
    end

    return containerIDs
end

-- Get the number of purchased bank tabs
function RetailBankScanner:GetPurchasedTabCount(bankType)
    bankType = bankType or currentBankType
    local count = 0

    if bankType == BANK_TYPE_CHARACTER then
        if Constants.CHARACTER_BANK_TABS_ACTIVE then
            for _, tabContainerID in ipairs(Constants.CHARACTER_BANK_TAB_IDS or {}) do
                if C_Container.GetContainerNumSlots(tabContainerID) > 0 then
                    count = count + 1
                end
            end
        end
    elseif bankType == BANK_TYPE_ACCOUNT then
        for _, tabContainerID in ipairs(Constants.WARBAND_BANK_TAB_IDS or {}) do
            if C_Container.GetContainerNumSlots(tabContainerID) > 0 then
                count = count + 1
            end
        end
    end

    return count
end

-- Get the container ID for a specific tab index
function RetailBankScanner:GetTabContainerID(tabIndex, bankType)
    bankType = bankType or currentBankType

    if bankType == BANK_TYPE_CHARACTER then
        if Constants.CHARACTER_BANK_TABS_ACTIVE and Constants.CHARACTER_BANK_TAB_IDS then
            return Constants.CHARACTER_BANK_TAB_IDS[tabIndex]
        end
    elseif bankType == BANK_TYPE_ACCOUNT then
        if Constants.WARBAND_BANK_TAB_IDS then
            return Constants.WARBAND_BANK_TAB_IDS[tabIndex]
        end
    end

    return nil
end

-------------------------------------------------
-- Scanning
-------------------------------------------------

function RetailBankScanner:ScanBank(bankType)
    if not isBankOpen then
        return bankType == BANK_TYPE_ACCOUNT and cachedWarbandBank or cachedCharacterBank
    end

    bankType = bankType or currentBankType
    local allBank = {}
    local containerIDs = self:GetBankContainerIDs(bankType)

    for _, bagID in ipairs(containerIDs) do
        local bagData = ItemScanner:ScanContainer(bagID)
        if bagData then
            allBank[bagID] = bagData
        end
    end

    -- Cache the result
    if bankType == BANK_TYPE_ACCOUNT then
        cachedWarbandBank = allBank
    else
        cachedCharacterBank = allBank
    end

    return allBank
end

function RetailBankScanner:ScanAllBank()
    ns:ProfileStart("Bank.ScanAllBank")
    -- Scan current bank type
    local result = self:ScanBank(currentBankType)
    ns:ProfileStop("Bank.ScanAllBank")
    return result
end

function RetailBankScanner:ScanDirtyBags(bagIDs)
    if not isBankOpen then
        return currentBankType == BANK_TYPE_ACCOUNT and cachedWarbandBank or cachedCharacterBank
    end

    local cache = currentBankType == BANK_TYPE_ACCOUNT and cachedWarbandBank or cachedCharacterBank

    for bagID in pairs(bagIDs) do
        local numSlots = C_Container.GetContainerNumSlots(bagID)
        if not numSlots or numSlots == 0 then
            if cache[bagID] then
                cache[bagID] = nil
            end
        else
            local existingBag = cache[bagID]
            if not existingBag then
                local bagData = ItemScanner:ScanContainer(bagID)
                if bagData then
                    cache[bagID] = bagData
                end
            else
                local freeSlots = 0
                for slot = 1, numSlots do
                    local itemInfo = C_Container.GetContainerItemInfo(bagID, slot)
                    local cachedItem = existingBag.slots[slot]

                    local currentItemID = itemInfo and itemInfo.itemID
                    local cachedItemID = cachedItem and cachedItem.itemID

                    if currentItemID ~= cachedItemID then
                        if itemInfo then
                            local itemData = ItemScanner:ScanSlotFast(bagID, slot)
                            if not itemData then
                                itemData = ItemScanner:ScanSlot(bagID, slot)
                            end
                            existingBag.slots[slot] = itemData
                        else
                            existingBag.slots[slot] = nil
                        end
                    elseif itemInfo and cachedItem then
                        if itemInfo.stackCount ~= cachedItem.count then
                            cachedItem.count = itemInfo.stackCount
                        end
                        if itemInfo.isLocked ~= cachedItem.locked then
                            cachedItem.locked = itemInfo.isLocked
                        end
                    end

                    if not itemInfo then
                        freeSlots = freeSlots + 1
                    end
                end

                existingBag.freeSlots = freeSlots
                existingBag.numSlots = numSlots
            end
        end
    end

    return cache
end

function RetailBankScanner:GetCachedBank(bankType)
    bankType = bankType or currentBankType
    if bankType == BANK_TYPE_ACCOUNT then
        return cachedWarbandBank
    end
    return cachedCharacterBank
end

function RetailBankScanner:GetDirtyBags()
    return dirtyBags
end

-------------------------------------------------
-- Slot Counts
-------------------------------------------------

function RetailBankScanner:GetTotalSlots(bankType)
    bankType = bankType or currentBankType
    local cache = bankType == BANK_TYPE_ACCOUNT and cachedWarbandBank or cachedCharacterBank

    local total = 0
    local free = 0

    for _, bagData in pairs(cache) do
        total = total + (bagData.numSlots or 0)
        free = free + (bagData.freeSlots or 0)
    end

    return total, free
end

function RetailBankScanner:GetDetailedSlotCounts(bankType)
    bankType = bankType or currentBankType
    local cache = bankType == BANK_TYPE_ACCOUNT and cachedWarbandBank or cachedCharacterBank

    local regularTotal = 0
    local regularFree = 0
    local specialBags = {}

    for bagID, bagData in pairs(cache) do
        local numSlots = bagData.numSlots or 0
        local freeSlots = bagData.freeSlots or 0

        -- Get bag family to determine type
        local bagFamily = 0
        local _, family = C_Container.GetContainerNumFreeSlots(bagID)
        bagFamily = family or 0

        if bagFamily == 0 then
            regularTotal = regularTotal + numSlots
            regularFree = regularFree + freeSlots
        else
            local bagType = self:GetBagTypeFromFamily(bagFamily)
            if not specialBags[bagType] then
                specialBags[bagType] = { total = 0, free = 0, name = bagType }
            end
            specialBags[bagType].total = specialBags[bagType].total + numSlots
            specialBags[bagType].free = specialBags[bagType].free + freeSlots
        end
    end

    return regularTotal, regularFree, specialBags
end

function RetailBankScanner:GetBagTypeFromFamily(bagFamily)
    if bagFamily == 0 then return "regular" end
    if bit.band(bagFamily, 8) ~= 0 then return "Leatherworking Bag" end
    if bit.band(bagFamily, 16) ~= 0 then return "Inscription Bag" end
    if bit.band(bagFamily, 32) ~= 0 then return "Herb Bag" end
    if bit.band(bagFamily, 64) ~= 0 then return "Enchanting Bag" end
    if bit.band(bagFamily, 128) ~= 0 then return "Engineering Bag" end
    if bit.band(bagFamily, 512) ~= 0 then return "Gem Bag" end
    if bit.band(bagFamily, 1024) ~= 0 then return "Mining Bag" end
    return "Special Bag"
end

-------------------------------------------------
-- Database
-------------------------------------------------

function RetailBankScanner:SaveToDatabase()
    -- Save character bank along with tab info
    local bankData = {
        containers = cachedCharacterBank,
        tabs = cachedBankTabs,
        isRetail = true,
    }
    Database:SaveBank(bankData)

    -- Save warband bank to account-wide storage
    if next(cachedWarbandBank) or #cachedWarbandTabs > 0 then
        local warbandData = {
            containers = cachedWarbandBank,
            tabs = cachedWarbandTabs,
            isWarband = true,
        }
        Database:SaveWarbandBank(warbandData)
        ns:Debug("Warband bank saved to database, tabs:", #cachedWarbandTabs)
    end
end

-- Load cached tab data from database
function RetailBankScanner:LoadCachedTabs(bankData)
    if bankData and bankData.tabs then
        cachedBankTabs = bankData.tabs
    end
end

-- Load cached warband bank data from database
function RetailBankScanner:LoadCachedWarbandBank()
    local warbandData = Database:GetWarbandBank()
    if warbandData then
        if warbandData.containers then
            cachedWarbandBank = warbandData.containers
        end
        if warbandData.tabs then
            cachedWarbandTabs = warbandData.tabs
        end
        ns:Debug("Loaded cached warband bank from database, tabs:", #cachedWarbandTabs)
    end
end

-- Load cached character bank data from database
function RetailBankScanner:LoadCachedCharacterBank(fullName)
    local bankData = Database:GetBank(fullName)
    if bankData then
        if bankData.containers then
            cachedCharacterBank = bankData.containers
        elseif not bankData.isRetail then
            -- Legacy format - direct container data
            cachedCharacterBank = bankData
        end
        if bankData.tabs then
            cachedBankTabs = bankData.tabs
        end
        ns:Debug("Loaded cached character bank from database, tabs:", #cachedBankTabs)
    end
end

function RetailBankScanner:IsBankOpen()
    return isBankOpen
end

-------------------------------------------------
-- Deposited Money (Warband Bank feature)
-------------------------------------------------

function RetailBankScanner:GetDepositedMoney(bankType)
    if not C_Bank or not C_Bank.FetchDepositedMoney then
        return 0
    end
    return C_Bank.FetchDepositedMoney(bankType or BANK_TYPE_ACCOUNT) or 0
end

function RetailBankScanner:DepositMoney(amount)
    if C_Bank and C_Bank.DepositMoney and isBankOpen then
        C_Bank.DepositMoney(BANK_TYPE_ACCOUNT, amount)
    end
end

function RetailBankScanner:WithdrawMoney(amount)
    if C_Bank and C_Bank.WithdrawMoney and isBankOpen then
        C_Bank.WithdrawMoney(BANK_TYPE_ACCOUNT, amount)
    end
end

-------------------------------------------------
-- Legacy Compatibility (for BankScanner delegation)
-------------------------------------------------

function RetailBankScanner:GetPurchasedBankSlots()
    -- In Retail, this concept is replaced by tabs
    -- Return the number of bank bag slots that have bags
    local count = 0
    for bagID = Constants.BANK_BAG_MIN, Constants.BANK_BAG_MAX do
        local numSlots = C_Container.GetContainerNumSlots(bagID)
        if numSlots and numSlots > 0 then
            count = count + 1
        end
    end
    return count
end

function RetailBankScanner:GetBankSlotCost()
    -- Retail doesn't use traditional bank slot purchasing
    return nil
end

function RetailBankScanner:CanPurchaseBankSlot()
    return false
end

function RetailBankScanner:PurchaseBankSlot()
    -- No-op on Retail
end

function RetailBankScanner:GetAllItems(bankType)
    bankType = bankType or currentBankType
    local cache = bankType == BANK_TYPE_ACCOUNT and cachedWarbandBank or cachedCharacterBank
    local items = {}

    for bagID, bagData in pairs(cache) do
        for slot, itemData in pairs(bagData.slots) do
            table.insert(items, itemData)
        end
    end

    return items
end

-------------------------------------------------
-- Deferred Save
-------------------------------------------------

local function ScheduleDeferredSave()
    if saveTimer then
        saveTimer:Cancel()
    end
    saveTimer = C_Timer.NewTimer(SAVE_DELAY, function()
        RetailBankScanner:SaveToDatabase()
        saveTimer = nil
        ns:Debug("Deferred retail bank database save complete")
    end)
end

-------------------------------------------------
-- Batched Updates
-------------------------------------------------

local function ProcessBatchedBankUpdates()
    if not pendingUpdate then return end
    if not isBankOpen then
        pendingUpdate = false
        updateFrame:Hide()
        return
    end

    local bagsToScan = dirtyBags
    dirtyBags = {}
    pendingUpdate = false
    updateFrame:Hide()

    RetailBankScanner:ScanDirtyBags(bagsToScan)
    ScheduleDeferredSave()

    ns:Debug("Retail bank batched scan complete")

    if ns.OnBankUpdated then
        ns.OnBankUpdated(bagsToScan)
    end
end

updateFrame:SetScript("OnUpdate", ProcessBatchedBankUpdates)

local function OnBankUpdate(bagID)
    if not isBankOpen then return end

    if bagID then
        dirtyBags[bagID] = true
    end

    if not pendingUpdate then
        pendingUpdate = true
        updateFrame:Show()
    end
end

-------------------------------------------------
-- Event Handlers
-------------------------------------------------

-- Determine if a bag ID belongs to character bank or warband bank
local function GetBankTypeForBagID(bagID)
    if bagID == Enum.BagIndex.Bank or (bagID >= Constants.BANK_BAG_MIN and bagID <= Constants.BANK_BAG_MAX) then
        return BANK_TYPE_CHARACTER
    end
    -- Check for AccountBankTab containers (Warband bank)
    if Enum.BagIndex.AccountBankTab_1 then
        for i = 1, 5 do
            local accountBagIndex = Enum.BagIndex["AccountBankTab_" .. i]
            if accountBagIndex and bagID == accountBagIndex then
                return BANK_TYPE_ACCOUNT
            end
        end
    end
    return nil
end

Events:OnBankOpened(function()
    isBankOpen = true
    currentBankType = BANK_TYPE_CHARACTER  -- Default to character bank
    selectedTabIndex = 0  -- Reset to show all tabs

    -- Cache tab data for offline viewing
    RetailBankScanner:CacheBankTabs(BANK_TYPE_CHARACTER)
    RetailBankScanner:ScanBank(BANK_TYPE_CHARACTER)
    ns:Debug("Retail character bank opened and scanned, tabs:", #cachedBankTabs)

    -- Also scan warband bank if available (use FetchBankLockedReason like Syndicator)
    local warbandLocked = C_Bank and C_Bank.FetchBankLockedReason and C_Bank.FetchBankLockedReason(BANK_TYPE_ACCOUNT)
    ns:Debug("Warband bank locked reason:", tostring(warbandLocked))
    if warbandLocked == nil then
        RetailBankScanner:CacheBankTabs(BANK_TYPE_ACCOUNT)
        RetailBankScanner:ScanBank(BANK_TYPE_ACCOUNT)
        ns:Debug("Retail warband bank scanned, tabs:", #cachedWarbandTabs)
    else
        ns:Debug("Warband bank is locked, skipping scan")
    end

    RetailBankScanner:SaveToDatabase()

    if ns.OnBankOpened then
        ns.OnBankOpened()
    end
end, RetailBankScanner)

local function HandleBankClosed(reason)
    isBankOpen = false
    dirtyBags = {}
    ns:Debug("Retail bank closed", reason or "")

    if ns.OnBankClosed then
        ns.OnBankClosed()
    end
end

Events:OnBankClosed(function()
    HandleBankClosed("BANKFRAME_CLOSED")
end, RetailBankScanner)

-- Modern Retail closes the bank through the interaction manager when the player
-- walks away from the banker; in that path BANKFRAME_CLOSED does not reliably
-- fire, so the GudaBags bank stayed open. Listen for the interaction-hide event
-- (filtered to the Banker interaction) and run the same close logic. This is
-- idempotent with BANKFRAME_CLOSED — ns.OnBankClosed only hides if still shown.
if Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.Banker then
    Events:Register("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", function(event, interactionType)
        if interactionType == Enum.PlayerInteractionType.Banker then
            HandleBankClosed("interaction-hide")
        end
    end, RetailBankScanner)
end

Events:Register("BAG_UPDATE", function(event, bagID)
    if not bagID then return end

    local bagBankType = GetBankTypeForBagID(bagID)
    if bagBankType then
        -- Only process if it's the current bank type being viewed
        if bagBankType == currentBankType then
            OnBankUpdate(bagID)
        end
    end
end, RetailBankScanner)

-- Legacy bank events (only for older Retail without Character Bank Tabs)
-- On Retail 12.0+, bank tabs are regular containers handled by BAG_UPDATE
if not Constants.CHARACTER_BANK_TABS_ACTIVE then
    -- Only register these if old bank system is active
    if Enum.BagIndex.Bank then
        Events:Register("PLAYERBANKSLOTS_CHANGED", function()
            if currentBankType == BANK_TYPE_CHARACTER then
                OnBankUpdate(Enum.BagIndex.Bank)
            end
        end, RetailBankScanner)

        Events:Register("PLAYERBANKBAGSLOTS_CHANGED", function()
            if currentBankType == BANK_TYPE_CHARACTER then
                for bagID = Constants.BANK_BAG_MIN, Constants.BANK_BAG_MAX do
                    dirtyBags[bagID] = true
                end
                OnBankUpdate(nil)
            end
        end, RetailBankScanner)
    end
end

-- Warband bank events
if C_Bank then
    Events:Register("ACCOUNT_MONEY", function()
        -- Warband bank money changed
        if ns.OnWarbandMoneyChanged then
            ns.OnWarbandMoneyChanged()
        end
    end, RetailBankScanner)

    Events:Register("BANK_TAB_SETTINGS_UPDATED", function(event, bankType)
        ns:Debug("Bank tab settings updated for", bankType)
        if isBankOpen then
            RetailBankScanner:CacheBankTabs(bankType)
            if ns.OnRetailBankTabsUpdated then
                ns.OnRetailBankTabsUpdated()
            end
        end
    end, RetailBankScanner)

    -- Warband bank tab slots changed
    Events:Register("PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED", function(event, tabIndex)
        ns:Debug("Warband bank tab slots changed, tab:", tabIndex)
        local warbandLocked = C_Bank.FetchBankLockedReason(BANK_TYPE_ACCOUNT)
        if isBankOpen and warbandLocked == nil and tabIndex then
            local containerID = Constants.WARBAND_BANK_TAB_IDS and Constants.WARBAND_BANK_TAB_IDS[tabIndex]
            if containerID then
                dirtyBags[containerID] = true
                OnBankUpdate(containerID)
            end
        end
    end, RetailBankScanner)

    -- Bank tabs changed (new tab purchased, etc.)
    Events:Register("BANK_TABS_CHANGED", function(event)
        ns:Debug("Bank tabs changed")
        if isBankOpen then
            RetailBankScanner:CacheBankTabs(BANK_TYPE_CHARACTER)
            local warbandLocked = C_Bank.FetchBankLockedReason(BANK_TYPE_ACCOUNT)
            if warbandLocked == nil then
                RetailBankScanner:CacheBankTabs(BANK_TYPE_ACCOUNT)
            end
            -- Rescan bank to pick up new tab slots
            RetailBankScanner:ScanAllBank()
            RetailBankScanner:SaveToDatabase()
            -- Notify UI to refresh (e.g., after purchasing a new tab)
            if ns.OnRetailBankTabsUpdated then
                ns.OnRetailBankTabsUpdated()
            end
        end
    end, RetailBankScanner)
end

-- Load cached bank data on player login
Events:OnPlayerLogin(function()
    -- Load cached warband bank (account-wide)
    RetailBankScanner:LoadCachedWarbandBank()

    -- Load cached character bank
    local fullName = Database:GetPlayerFullName()
    if fullName then
        RetailBankScanner:LoadCachedCharacterBank(fullName)
    end
end, RetailBankScanner)
