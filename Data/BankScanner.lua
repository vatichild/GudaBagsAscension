local addonName, ns = ...

local BankScanner = {}
ns:RegisterModule("BankScanner", BankScanner)

-------------------------------------------------
-- Retail Delegation Helper
-- On Retail, some functions delegate to RetailBankScanner
-------------------------------------------------
local function GetRetailScanner()
    if ns.IsRetail then
        return ns:GetModule("RetailBankScanner")
    end
    return nil
end

-------------------------------------------------
-- Classic Bank Implementation
-------------------------------------------------

local Constants = ns.Constants
local Database = ns:GetModule("Database")
local Events = ns:GetModule("Events")
local ItemScanner = ns:GetModule("ItemScanner")

local cachedBank = {}
local isBankOpen = false
local dirtyBags = {}           -- Set of bagIDs that need scanning
local pendingUpdate = false    -- True when OnUpdate is scheduled
local saveTimer = nil          -- Timer handle for deferred database save
local SAVE_DELAY = 1.0         -- Seconds to wait before saving to database

-- Create frame for OnUpdate batching (same pattern as BagScanner)
local updateFrame = CreateFrame("Frame")
updateFrame:Hide()

function BankScanner:ScanAllBank()
    if not isBankOpen then
        return cachedBank
    end

    local allBank = {}

    for _, bagID in ipairs(Constants.BANK_BAG_IDS) do
        local bagData = ItemScanner:ScanContainer(bagID)
        if bagData then
            allBank[bagID] = bagData
        end
    end

    cachedBank = allBank
    return allBank
end

-- Scan only specific bags that are marked dirty
-- Optimized: only scans slots that actually changed, not the entire bag
function BankScanner:ScanDirtyBags(bagIDs)
    if not isBankOpen then
        return cachedBank
    end

    for bagID in pairs(bagIDs) do
        local numSlots = C_Container.GetContainerNumSlots(bagID)
        if not numSlots or numSlots == 0 then
            -- Bag was removed or emptied
            if cachedBank[bagID] then
                cachedBank[bagID] = nil
            end
        else
            local existingBag = cachedBank[bagID]
            if not existingBag then
                -- New bag, do full scan
                local bagData = ItemScanner:ScanContainer(bagID)
                if bagData then
                    cachedBank[bagID] = bagData
                end
            else
                -- Existing bag - only scan slots that changed
                local freeSlots = 0
                for slot = 1, numSlots do
                    local itemInfo = C_Container.GetContainerItemInfo(bagID, slot)
                    local cachedItem = existingBag.slots[slot]

                    -- Check if slot changed by comparing itemID
                    local currentItemID = itemInfo and itemInfo.itemID
                    local cachedItemID = cachedItem and cachedItem.itemID

                    if currentItemID ~= cachedItemID then
                        -- Slot changed
                        if itemInfo then
                            -- Try fast path first (uses cached tooltip data)
                            -- This avoids tooltip scan when item just moved slots
                            local itemData = ItemScanner:ScanSlotFast(bagID, slot)
                            if not itemData then
                                -- No cached data, need full scan (new item)
                                itemData = ItemScanner:ScanSlot(bagID, slot)
                            end
                            existingBag.slots[slot] = itemData
                        else
                            existingBag.slots[slot] = nil
                        end
                    elseif itemInfo and cachedItem then
                        -- Same item, but check if count changed (for stacks)
                        if itemInfo.stackCount ~= cachedItem.count then
                            cachedItem.count = itemInfo.stackCount
                        end
                        -- Check if locked state changed
                        if itemInfo.isLocked ~= cachedItem.locked then
                            cachedItem.locked = itemInfo.isLocked
                        end
                    end

                    -- Count free slots (empty slots)
                    if not itemInfo then
                        freeSlots = freeSlots + 1
                    end
                end

                -- Update free slots count
                existingBag.freeSlots = freeSlots
                existingBag.numSlots = numSlots
            end
        end
    end
    return cachedBank
end

function BankScanner:GetDirtyBags()
    return dirtyBags
end

function BankScanner:GetCachedBank()
    local retailScanner = GetRetailScanner()
    if retailScanner then
        return retailScanner:GetCachedBank()
    end
    return cachedBank
end

function BankScanner:GetTotalSlots()
    local retailScanner = GetRetailScanner()
    if retailScanner then
        return retailScanner:GetTotalSlots()
    end

    local total = 0
    local free = 0

    for _, bagData in pairs(cachedBank) do
        total = total + bagData.numSlots
        free = free + bagData.freeSlots
    end

    return total, free
end

-- Get slot counts separated by bag type (regular vs special bags)
-- Returns: regularTotal, regularFree, specialBags table
-- specialBags format: { [bagType] = { total = N, free = N, name = "Bag Name" }, ... }
function BankScanner:GetDetailedSlotCounts()
    local retailScanner = GetRetailScanner()
    if retailScanner then
        return retailScanner:GetDetailedSlotCounts()
    end

    local regularTotal = 0
    local regularFree = 0
    local specialBags = {}

    for bagID, bagData in pairs(cachedBank) do
        local numSlots = bagData.numSlots or 0
        local freeSlots = bagData.freeSlots or 0

        -- Get bag family to determine type
        local bagFamily = 0
        if bagID >= 5 and bagID <= 11 then
            -- Bank bag slots (5-11)
            local _, family = C_Container.GetContainerNumFreeSlots(bagID)
            bagFamily = family or 0
        end
        -- Main bank (-1) is always regular

        if bagFamily == 0 then
            -- Regular bag (including main bank)
            regularTotal = regularTotal + numSlots
            regularFree = regularFree + freeSlots
        else
            -- Special bag - determine type
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

-- Helper to get bag type from family (matches BagClassifier logic)
function BankScanner:GetBagTypeFromFamily(bagFamily)
    if bagFamily == 0 then return "regular" end
    if bit.band(bagFamily, 1) ~= 0 then return "Quiver" end
    if bit.band(bagFamily, 2) ~= 0 then return "Ammo Pouch" end
    if bit.band(bagFamily, 4) ~= 0 then return "Soul Bag" end
    if bit.band(bagFamily, 8) ~= 0 then return "Leatherworking Bag" end
    if bit.band(bagFamily, 16) ~= 0 then return "Inscription Bag" end
    if bit.band(bagFamily, 32) ~= 0 then return "Herb Bag" end
    if bit.band(bagFamily, 64) ~= 0 then return "Enchanting Bag" end
    if bit.band(bagFamily, 128) ~= 0 then return "Engineering Bag" end
    if bit.band(bagFamily, 512) ~= 0 then return "Gem Bag" end
    if bit.band(bagFamily, 1024) ~= 0 then return "Mining Bag" end
    return "Special Bag"
end

function BankScanner:GetAllItems()
    local items = {}

    for bagID, bagData in pairs(cachedBank) do
        for slot, itemData in pairs(bagData.slots) do
            table.insert(items, itemData)
        end
    end

    return items
end

function BankScanner:SaveToDatabase()
    Database:SaveBank(cachedBank)
end

function BankScanner:IsBankOpen()
    local retailScanner = GetRetailScanner()
    if retailScanner then
        return retailScanner:IsBankOpen()
    end
    return isBankOpen
end

function BankScanner:GetPurchasedBankSlots()
    -- Classic uses GetNumBankSlots(), Retail (TWW+) moved this to C_Bank
    if GetNumBankSlots then
        return GetNumBankSlots()
    end
    -- Retail: Try C_Bank API if available
    if C_Bank and C_Bank.FetchNumPurchasedBankSlots then
        return C_Bank.FetchNumPurchasedBankSlots()
    end
    -- Fallback for Retail: assume all slots purchased (disables purchase UI)
    return 7
end

function BankScanner:GetBankSlotCost()
    if not GetBankSlotCost then
        -- Retail doesn't have traditional bank slot purchasing
        return nil
    end
    local nextSlot = self:GetPurchasedBankSlots() + 1
    return GetBankSlotCost(nextSlot)
end

function BankScanner:CanPurchaseBankSlot()
    local cost = self:GetBankSlotCost()
    return cost and GetMoney() >= cost
end

function BankScanner:PurchaseBankSlot()
    if isBankOpen and self:CanPurchaseBankSlot() and PurchaseSlot then
        PurchaseSlot()
    end
end

-- Deferred save: waits for updates to settle before saving
local function ScheduleDeferredSave()
    if saveTimer then
        saveTimer:Cancel()
    end
    saveTimer = C_Timer.NewTimer(SAVE_DELAY, function()
        BankScanner:SaveToDatabase()
        saveTimer = nil
        ns:Debug("Deferred bank database save complete")
    end)
end

-- Process batched bank updates (called from OnUpdate)
local function ProcessBatchedBankUpdates()
    if not pendingUpdate then return end
    if not isBankOpen then
        pendingUpdate = false
        updateFrame:Hide()
        return
    end

    -- Copy and clear dirty bags before processing
    local bagsToScan = dirtyBags
    dirtyBags = {}
    pendingUpdate = false
    updateFrame:Hide()

    -- Scan only the dirty bags
    BankScanner:ScanDirtyBags(bagsToScan)

    -- Schedule deferred save instead of immediate save
    ScheduleDeferredSave()

    ns:Debug("Bank batched scan complete, bags:", table.concat((function()
        local keys = {}
        for k in pairs(bagsToScan) do table.insert(keys, tostring(k)) end
        return keys
    end)(), ","))

    if ns.OnBankUpdated then
        ns.OnBankUpdated(bagsToScan)
    end
end

updateFrame:SetScript("OnUpdate", ProcessBatchedBankUpdates)

local function OnBankUpdate(bagID)
    if not isBankOpen then return end

    -- Track which bag is dirty
    if bagID then
        dirtyBags[bagID] = true
    end

    -- Schedule OnUpdate processing if not already pending
    if not pendingUpdate then
        pendingUpdate = true
        updateFrame:Show()
    end
end

-- On Retail, RetailBankScanner handles all bank scanning
-- These event handlers are for Classic only
if not ns.IsRetail then
    Events:OnBankOpened(function()
        isBankOpen = true
        BankScanner:ScanAllBank()
        BankScanner:SaveToDatabase()
        ns:Debug("Bank opened and scanned")

        if ns.OnBankOpened then
            ns.OnBankOpened()
        end
    end, BankScanner)

    Events:OnBankClosed(function()
        isBankOpen = false
        -- Clear any pending dirty bags
        dirtyBags = {}
        ns:Debug("Bank closed")

        if ns.OnBankClosed then
            ns.OnBankClosed()
        end
    end, BankScanner)

    Events:Register("BAG_UPDATE", function(event, bagID)
        if bagID and bagID >= -1 and bagID <= 11 then
            local isBankBag = bagID == -1 or (bagID >= 5 and bagID <= 11)
            if isBankBag then
                OnBankUpdate(bagID)
            end
        end
    end, BankScanner)

    -- For these events, scan all bank bags since we don't know which specific bag changed
    Events:Register("PLAYERBANKSLOTS_CHANGED", function()
        -- Mark main bank bag as dirty (-1)
        OnBankUpdate(-1)
    end, BankScanner)

    Events:Register("PLAYERBANKBAGSLOTS_CHANGED", function()
        -- Bank bag slots changed, mark all bank bags dirty
        for _, bagID in ipairs(Constants.BANK_BAG_IDS) do
            dirtyBags[bagID] = true
        end
        OnBankUpdate(nil)
    end, BankScanner)
end  -- End of Classic-only event handlers
