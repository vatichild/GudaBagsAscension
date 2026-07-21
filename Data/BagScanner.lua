local addonName, ns = ...

local BagScanner = {}
ns:RegisterModule("BagScanner", BagScanner)

local Constants = ns.Constants
local Database = ns:GetModule("Database")
local Events = ns:GetModule("Events")
local ItemScanner = ns:GetModule("ItemScanner")

local cachedBags = {}

-- Track all itemIDs currently in bags (for detecting truly new items)
local knownItemIDs = {}  -- { [itemID] = count }

-- Event batching: collect dirty bags and process after delay
local dirtyBags = {}           -- Set of bagIDs that need scanning
local pendingUpdate = false    -- True when OnUpdate is scheduled
local saveTimer = nil          -- Timer handle for deferred database save
local SAVE_DELAY = 1.0         -- Seconds to wait before saving to database

-- Create frame for OnUpdate batching
local updateFrame = CreateFrame("Frame")
updateFrame:Hide()

function BagScanner:ScanAllBags()
    ns:ProfileStart("ScanAllBags")
    local allBags = {}

    for _, bagID in ipairs(Constants.BAG_IDS) do
        local bagData = ItemScanner:ScanContainer(bagID)
        if bagData then
            allBags[bagID] = bagData
        end
    end

    -- Also scan keyring (TBC only)
    if Constants.KEYRING_BAG_ID then
        local keyringData = ItemScanner:ScanContainer(Constants.KEYRING_BAG_ID)
        if keyringData then
            allBags[Constants.KEYRING_BAG_ID] = keyringData
        end
    end

    cachedBags = allBags

    -- Build known item IDs from all bags (for tracking new items)
    knownItemIDs = {}
    for bagID, bagData in pairs(allBags) do
        if bagData.slots then
            for slot, itemData in pairs(bagData.slots) do
                if itemData and itemData.itemID then
                    knownItemIDs[itemData.itemID] = (knownItemIDs[itemData.itemID] or 0) + 1
                end
            end
        end
    end

    ns:ProfileStop("ScanAllBags")
    return allBags
end

-- Scan only specific bags that are marked dirty
-- Optimized: only scans slots that actually changed, not the entire bag.
--
-- Recent-marker emission is deferred to the end of this function: a snapshot
-- of knownItemIDs is taken before per-slot diffs run, and only itemIDs whose
-- TOTAL slot occurrence count went 0→>0 (first appears) or >0→0 (last
-- vanishes) emit a marker. The per-slot path used to fire MarkRecent for any
-- item that landed in a previously-empty slot, which produced false positives
-- whenever a sort moved items between slots.
function BagScanner:ScanDirtyBags(bagIDs)
    -- Snapshot for the post-loop Recent diff. Shallow copy is enough because
    -- knownItemIDs values are numbers.
    local prevKnown = {}
    for itemID, count in pairs(knownItemIDs) do
        prevKnown[itemID] = count
    end

    for bagID in pairs(bagIDs) do
        local numSlots = C_Container.GetContainerNumSlots(bagID)
        if not numSlots or numSlots == 0 then
            -- Bag was removed or emptied - update known item counts.
            if cachedBags[bagID] and cachedBags[bagID].slots then
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
        else
            local existingBag = cachedBags[bagID]
            if not existingBag then
                -- New bag (newly equipped) - do full scan and update known counts.
                -- Recent emission is handled by the post-loop diff against prevKnown.
                local bagData = ItemScanner:ScanContainer(bagID)
                if bagData then
                    cachedBags[bagID] = bagData
                    if bagData.slots then
                        for slot, itemData in pairs(bagData.slots) do
                            if itemData and itemData.itemID then
                                knownItemIDs[itemData.itemID] = (knownItemIDs[itemData.itemID] or 0) + 1
                            end
                        end
                    end
                end
            else
                -- Existing bag - only scan slots that changed
                local freeSlots = 0
                for slot = 1, numSlots do
                    local itemInfo = C_Container.GetContainerItemInfo(bagID, slot)
                    local cachedItem = existingBag.slots[slot]

                    -- Check if slot changed by comparing itemID AND link.
                    -- Two items can share an itemID but differ in item level /
                    -- bonus IDs (e.g. swapping two "Warboots" of different ilvl);
                    -- the itemID is identical, so we must also compare the link
                    -- (which encodes ilvl/bonusIDs) or the swap is invisible here
                    -- and the slot keeps showing the old item until a full rescan.
                    local currentItemID = itemInfo and itemInfo.itemID
                    local cachedItemID = cachedItem and cachedItem.itemID
                    local currentLink = itemInfo and itemInfo.hyperlink
                    local cachedLink = cachedItem and cachedItem.link

                    if currentItemID ~= cachedItemID or currentLink ~= cachedLink then
                        -- Slot changed - update known item counts. Recent
                        -- emission is handled by the post-loop diff so that
                        -- items merely moving between slots (sort, restack,
                        -- manual rearrange) don't fire false markers.
                        if cachedItemID then
                            knownItemIDs[cachedItemID] = (knownItemIDs[cachedItemID] or 1) - 1
                            if knownItemIDs[cachedItemID] <= 0 then
                                knownItemIDs[cachedItemID] = nil
                            end
                        end

                        if itemInfo then
                            if currentItemID then
                                knownItemIDs[currentItemID] = (knownItemIDs[currentItemID] or 0) + 1
                            end

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

    -- Deferred Recent diff: emit MarkRecent only for itemIDs whose first slot
    -- just appeared, RemoveRecent only for those whose last slot just vanished.
    -- Skip entirely while a sort or restack is in progress — those operations
    -- preserve total item counts, so the post-sort scan will see no diff and
    -- correctly emit no markers. (Mid-sort scans can show transient cursor-
    -- pickup states where a count momentarily drops to 0; suppressing them
    -- avoids false marker churn.)
    local SortEngine = ns:GetModule("SortEngine")
    local sortActive = SortEngine and (SortEngine:IsSorting() or SortEngine:IsRestacking())
    if not sortActive then
        local RecentItems = ns:GetModule("RecentItems")
        if RecentItems then
            for itemID, count in pairs(knownItemIDs) do
                if count and count > 0 and not prevKnown[itemID] then
                    RecentItems:MarkRecent(itemID)
                end
            end
            for itemID, prevCount in pairs(prevKnown) do
                if prevCount > 0 and not knownItemIDs[itemID] then
                    RecentItems:RemoveRecent(itemID)
                end
            end
        end
    end

    return cachedBags
end

function BagScanner:GetCachedBags()
    return cachedBags
end

function BagScanner:GetDirtyBags()
    return dirtyBags
end

function BagScanner:GetTotalSlots()
    local total = 0
    local free = 0

    -- Only count regular bags, not keyring
    for bagID, bagData in pairs(cachedBags) do
        if bagID >= Constants.PLAYER_BAG_MIN and bagID <= Constants.PLAYER_BAG_MAX then
            total = total + bagData.numSlots
            free = free + bagData.freeSlots
        end
    end

    return total, free
end

-- Get slot counts separated by bag type (regular vs special bags)
-- Returns: regularTotal, regularFree, specialBags table
-- specialBags format: { [bagType] = { total = N, free = N, name = "Bag Name" }, ... }
function BagScanner:GetDetailedSlotCounts()
    local regularTotal = 0
    local regularFree = 0
    local specialBags = {}

    for bagID, bagData in pairs(cachedBags) do
        if bagID >= Constants.PLAYER_BAG_MIN and bagID <= Constants.PLAYER_BAG_MAX then
            local numSlots = bagData.numSlots or 0
            local freeSlots = bagData.freeSlots or 0

            -- Get bag family to determine type
            local bagFamily = 0
            if bagID > 0 then
                local _, family = C_Container.GetContainerNumFreeSlots(bagID)
                bagFamily = family or 0
            end

            if bagFamily == 0 then
                -- Regular bag (including backpack)
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
    end

    return regularTotal, regularFree, specialBags
end

-- Helper to get bag type from family (matches BagClassifier logic)
function BagScanner:GetBagTypeFromFamily(bagFamily)
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

function BagScanner:GetAllItems()
    local items = {}

    for bagID, bagData in pairs(cachedBags) do
        for slot, itemData in pairs(bagData.slots) do
            table.insert(items, itemData)
        end
    end

    return items
end

function BagScanner:SaveToDatabase()
    Database:SaveBags(cachedBags)
    Database:SaveMoney(GetMoney())
end

-- Deferred save: waits for updates to settle before saving
local function ScheduleDeferredSave()
    if saveTimer then
        saveTimer:Cancel()
    end
    saveTimer = C_Timer.NewTimer(SAVE_DELAY, function()
        BagScanner:SaveToDatabase()
        saveTimer = nil
        ns:Debug("Deferred database save complete")
    end)
end

-- Process batched bag updates (called from OnUpdate)
local function ProcessBatchedUpdates()
    if not pendingUpdate then return end

    -- Allow UI updates during sorting so items move visually in real-time

    -- Copy and clear dirty bags before processing
    local bagsToScan = dirtyBags
    dirtyBags = {}
    pendingUpdate = false
    updateFrame:Hide()

    ns:ProfileBump("event.batch")
    ns:ProfileStart("event.batchwork")

    -- Scan only the dirty bags
    BagScanner:ScanDirtyBags(bagsToScan)

    -- Schedule deferred save instead of immediate save
    ScheduleDeferredSave()

    -- Notify with list of updated bags for incremental updates
    if ns.OnBagsUpdated then
        ns.OnBagsUpdated(bagsToScan)
    end

    ns:ProfileStop("event.batchwork")
end

updateFrame:SetScript("OnUpdate", ProcessBatchedUpdates)

-- Check if bagID is a player bag (not bank)
local function IsPlayerBag(bagID)
    if not bagID then return false end
    -- Player bags: 0-4, Reagent Bag: 5 (Retail), Keyring: -2 (Classic)
    if bagID >= 0 and bagID <= 4 then return true end
    if Constants.REAGENT_BAG and bagID == Constants.REAGENT_BAG then return true end
    if Constants.KEYRING_BAG_ID and bagID == Constants.KEYRING_BAG_ID then return true end
    return false
end

-- Mark a bag as dirty and schedule batched processing
local function OnBagUpdate(event, bagID)
    -- Only handle player bags, not bank bags (bank has its own scanner)
    if not IsPlayerBag(bagID) then
        return
    end

    ns:ProfileBump("event.BAG_UPDATE")
    ns:Debug("BagScanner: BAG_UPDATE for bag", bagID, "pending:", pendingUpdate)
    dirtyBags[bagID] = true

    -- Schedule OnUpdate processing if not already pending
    if not pendingUpdate then
        pendingUpdate = true
        updateFrame:Show()
    end
end

Events:OnPlayerLogin(function()
    BagScanner:ScanAllBags()
    BagScanner:SaveToDatabase()
    ns:Debug("Initial bag scan complete")
end, BagScanner)

Events:OnBagUpdate(OnBagUpdate, BagScanner)

-- Removing a bag from a bag slot does not always produce a BAG_UPDATE for the
-- container that just went away on 3.3.5a -- BAG_CLOSED is the signal for that.
-- Route it through the same dirty-bag path: rescanning a bag that no longer
-- exists simply reports zero slots, which is exactly the state we want shown.
-- Registration is pcall-guarded upstream, so this is inert where the event
-- does not exist.
Events:Register("BAG_CLOSED", OnBagUpdate, BagScanner)

-- Handle BAGS_UPDATED event (fired after sort completes)
-- This ensures bags are rescanned and UI refreshed after sorting
Events:Register("BAGS_UPDATED", function()
    -- Use accumulated dirty bags if any, otherwise scan all player bags
    local bagsToScan = dirtyBags
    local bagCount = 0
    for _ in pairs(bagsToScan) do bagCount = bagCount + 1 end

    if bagCount == 0 then
        -- No dirty bags tracked, scan all player bags
        for _, bagID in ipairs(Constants.BAG_IDS) do
            bagsToScan[bagID] = true
        end
        bagCount = #Constants.BAG_IDS
    end

    ns:Debug(string.format("Post-sort refresh: %d dirty bags", bagCount))

    -- Clear state
    dirtyBags = {}
    pendingUpdate = false
    updateFrame:Hide()

    -- Scan only the dirty bags (faster than full rescan)
    BagScanner:ScanDirtyBags(bagsToScan)
    ScheduleDeferredSave()

    -- Notify UI with dirty bags for incremental update
    if ns.OnBagsUpdated then
        ns.OnBagsUpdated(bagsToScan)
    end
end, BagScanner)
