local addonName, ns = ...

local ScannerBase = {}
ns:RegisterModule("ScannerBase", ScannerBase)

local ItemScanner = ns:GetModule("ItemScanner")

-------------------------------------------------
-- Shared Scanner Logic
-- Common scanning functions used by BagScanner and BankScanner
-------------------------------------------------

-- Scan a single bag and update the cache
-- Parameters:
--   bagID: The bag ID to scan
--   cachedBags: Table of cached bag data
--   options: Optional table with:
--     - knownItemIDs: Table to track known item IDs (for BagScanner)
--     - isBank: Whether this is a bank scan
-- Returns: Updated cachedBags table
function ScannerBase:ScanDirtyBag(bagID, cachedBags, options)
    options = options or {}
    local knownItemIDs = options.knownItemIDs

    local numSlots = C_Container.GetContainerNumSlots(bagID)
    if not numSlots or numSlots == 0 then
        -- Bag was removed or emptied - update known item counts if tracking
        if knownItemIDs and cachedBags[bagID] and cachedBags[bagID].slots then
            for slot, itemData in pairs(cachedBags[bagID].slots) do
                if itemData and itemData.itemID then
                    knownItemIDs[itemData.itemID] = (knownItemIDs[itemData.itemID] or 1) - 1
                    if knownItemIDs[itemData.itemID] <= 0 then
                        knownItemIDs[itemData.itemID] = nil
                    end
                end
            end
        end
        cachedBags[bagID] = nil
        return
    end

    local existingBag = cachedBags[bagID]
    if not existingBag then
        -- New bag, do full scan
        local bagData = ItemScanner:ScanContainer(bagID)
        if bagData then
            cachedBags[bagID] = bagData
            -- Track item IDs from this bag if tracking enabled
            if knownItemIDs and bagData.slots then
                for slot, itemData in pairs(bagData.slots) do
                    if itemData and itemData.itemID then
                        knownItemIDs[itemData.itemID] = (knownItemIDs[itemData.itemID] or 0) + 1
                    end
                end
            end
        end
        return
    end

    -- Existing bag - only scan slots that changed
    local freeSlots = 0
    for slot = 1, numSlots do
        local itemInfo = C_Container.GetContainerItemInfo(bagID, slot)
        local cachedItem = existingBag.slots[slot]

        -- Check if slot changed by comparing itemID
        local currentItemID = itemInfo and itemInfo.itemID
        local cachedItemID = cachedItem and cachedItem.itemID

        if currentItemID ~= cachedItemID then
            -- Slot changed - update known item counts if tracking
            if knownItemIDs then
                if cachedItemID then
                    knownItemIDs[cachedItemID] = (knownItemIDs[cachedItemID] or 1) - 1
                    if knownItemIDs[cachedItemID] <= 0 then
                        knownItemIDs[cachedItemID] = nil
                    end
                end
                if currentItemID then
                    knownItemIDs[currentItemID] = (knownItemIDs[currentItemID] or 0) + 1
                end
            end

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

-- Count free slots in a bag
function ScannerBase:CountFreeSlots(bagID, numSlots)
    local freeSlots = 0
    for slot = 1, numSlots do
        local itemInfo = C_Container.GetContainerItemInfo(bagID, slot)
        if not itemInfo then
            freeSlots = freeSlots + 1
        end
    end
    return freeSlots
end

-- Create a deferred save scheduler
-- Parameters:
--   saveCallback: Function to call when save timer fires
--   delay: Delay in seconds before saving (default 1.0)
-- Returns: Table with Schedule() and Cancel() methods
function ScannerBase:CreateDeferredSaver(saveCallback, delay)
    delay = delay or 1.0
    local saver = {
        timer = nil,
        delay = delay,
        callback = saveCallback,
    }

    function saver:Schedule()
        if self.timer then
            self.timer:Cancel()
        end
        self.timer = C_Timer.NewTimer(self.delay, function()
            self.callback()
            self.timer = nil
        end)
    end

    function saver:Cancel()
        if self.timer then
            self.timer:Cancel()
            self.timer = nil
        end
    end

    return saver
end
