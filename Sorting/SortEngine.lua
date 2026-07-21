-- GudaBags Sort Engine
-- Single-pass snapshot-based sorting algorithm for Classic expansions

local addonName, ns = ...

local SortEngine = {}
ns:RegisterModule("SortEngine", SortEngine)

local Constants = ns.Constants
local Database = ns:GetModule("Database")
local Events = ns:GetModule("Events")
local Expansion = ns:GetModule("Expansion")

-- Cached globals
local InCombatLockdown = InCombatLockdown
local ClearCursor = ClearCursor
local C_Container_GetContainerItemInfo = C_Container.GetContainerItemInfo
local C_Container_GetContainerNumSlots = C_Container.GetContainerNumSlots
local C_Container_GetContainerNumFreeSlots = C_Container.GetContainerNumFreeSlots
local C_Container_PickupContainerItem = C_Container.PickupContainerItem
local C_Container_SplitContainerItem = C_Container.SplitContainerItem
local C_Item_GetItemFamily = C_Item.GetItemFamily
local GetItemInfo = GetItemInfo
local bit_band = bit.band
local table_sort = table.sort
local string_find = string.find
local string_lower = string.lower
local tostring = tostring
local tonumber = tonumber
local math_min = math.min
local ipairs = ipairs
local pairs = pairs
local wipe = wipe
local debugprofilestop = debugprofilestop
local GetTime = GetTime
local coroutine_yield = coroutine.yield
local coroutine_create = coroutine.create
local coroutine_resume = coroutine.resume
local coroutine_status = coroutine.status

-- Frame budget for coroutine-based sorting (microseconds)
local FRAME_BUDGET_US = 10000      -- 10ms for player bags
local FRAME_BUDGET_BANK_US = 14000 -- 14ms for bank (more lenient)
local frameStartTime = 0
local currentFrameBudget = FRAME_BUDGET_US

local function StartFrameTimer()
    frameStartTime = debugprofilestop()
end

local function IsFrameBudgetExceeded()
    return (debugprofilestop() - frameStartTime) > currentFrameBudget
end

-- Sorting state
local sortInProgress = false
local sortCoroutine = nil
local currentPass = 0
local maxPasses = 5  -- 1 main + up to 4 verification/retry passes
local soundsMuted = false

-- Event-driven lock waiting
local waitingForLocks = false
local locksCleared = true

-- Targeted lock checking: only poll slots involved in recent moves
local pendingLockSlots = {}  -- flat array: {bagID1, slot1, bagID2, slot2, ...}
local pendingLockCount = 0   -- number of pairs (actual array length = count * 2)
local pendingLockSet = {}    -- set: bagID*1000+slot → true (O(1) dependency check)

local function ClearPendingLocks()
    pendingLockCount = 0
    wipe(pendingLockSet)
end

local function AddPendingLock(bagID, slot)
    local idx = pendingLockCount * 2
    pendingLockSlots[idx + 1] = bagID
    pendingLockSlots[idx + 2] = slot
    pendingLockCount = pendingLockCount + 1
    pendingLockSet[bagID * 1000 + slot] = true
end

-- Performance: Cache computed sort keys by itemID across passes
local sortKeyCache = {}
-- Performance: Cache GetItemInfo results by itemID (static data, never changes)
local itemInfoCache = {}

-- Performance tracking (debug)
local perfStats = {
    sortKeyComputes = 0,
    sortKeyCacheHits = 0,
}

-- Use pickup sound IDs from Constants
--
-- MuteSoundFile/UnmuteSoundFile are Legion 7.x. On 3.3.5a there is no
-- equivalent, so muting is skipped entirely -- sorting is simply audible.
-- These MUST be guarded here and not only polyfilled: an error raised in
-- UnmutePickupSounds kills FinishSort before it prints its result message,
-- which turns a failed sort into a silent one-item no-op.
-- Both must exist, or we do not mute at all: muting with no way to unmute
-- would silence pickup sounds permanently for the rest of the session.
local canMuteSounds = type(MuteSoundFile) == "function"
                  and type(UnmuteSoundFile) == "function"

local function MutePickupSounds()
    if not canMuteSounds then return end
    for _, soundID in ipairs(Constants.PICKUP_SOUND_IDS) do
        MuteSoundFile(soundID)
    end
end

local function UnmutePickupSounds()
    if not canMuteSounds then return end
    for _, soundID in ipairs(Constants.PICKUP_SOUND_IDS) do
        UnmuteSoundFile(soundID)
    end
end

--===========================================================================
-- SORT KEY DEFINITIONS
--===========================================================================

-- Priority items (Hearthstone and similar always first, mounts second)
local PRIORITY_ITEMS = {
    [6948] = 1,    -- Hearthstone
    [260221] = 1,  -- Naaru's Embrace
}

-- Item class ordering (maps WoW item classID to sort order)
local CLASS_ORDER = {
    [0] = 2,   -- Consumable
    [1] = 12,  -- Container (Bags)
    [2] = 5,   -- Weapon
    [3] = 8,   -- Gem
    [4] = 6,   -- Armor
    [5] = 3,   -- Reagent
    [6] = 4,   -- Projectile
    [7] = 10,  -- Trade Goods
    [8] = 9,   -- Item Enhancement (not in TBC but for future)
    [9] = 11,  -- Recipe
    [10] = 16, -- Money (obsolete)
    [11] = 7,  -- Quiver
    [12] = 13, -- Quest
    [13] = 14, -- Key
    [14] = 17, -- Permanent (obsolete)
    [15] = 15, -- Miscellaneous
    [16] = 18, -- Glyph (not in TBC)
    [17] = 19, -- Battle Pet (not in TBC)
    [18] = 1,  -- WoW Token (not in TBC)
}

-- Weapon subclass ordering
local WEAPON_SUBCLASS_ORDER = {
    [0] = 1,   -- One-Handed Axes
    [1] = 10,  -- Two-Handed Axes
    [2] = 2,   -- Bows
    [3] = 13,  -- Guns
    [4] = 3,   -- One-Handed Maces
    [5] = 11,  -- Two-Handed Maces
    [6] = 12,  -- Polearms
    [7] = 4,   -- One-Handed Swords
    [8] = 14,  -- Two-Handed Swords
    [9] = 20,  -- Obsolete
    [10] = 15, -- Staves
    [11] = 20, -- One-Handed Exotics
    [12] = 20, -- Two-Handed Exotics
    [13] = 16, -- Fist Weapons
    [14] = 17, -- Miscellaneous (wands in classic)
    [15] = 5,  -- Daggers
    [16] = 18, -- Thrown
    [17] = 19, -- Spears
    [18] = 6,  -- Crossbows
    [19] = 7,  -- Wands
    [20] = 8,  -- Fishing Poles
}

-- Armor subclass ordering
local ARMOR_SUBCLASS_ORDER = {
    [0] = 10,  -- Miscellaneous
    [1] = 4,   -- Cloth
    [2] = 3,   -- Leather
    [3] = 2,   -- Mail
    [4] = 1,   -- Plate
    [5] = 11,  -- Cosmetic
    [6] = 5,   -- Shields
    [7] = 6,   -- Librams
    [8] = 7,   -- Idols
    [9] = 8,   -- Totems
    [10] = 9,  -- Sigils
}

-- Equipment slot ordering
local EQUIP_SLOT_ORDER = {
    ["INVTYPE_WEAPONMAINHAND"] = 1,
    ["INVTYPE_WEAPON"] = 2,
    ["INVTYPE_2HWEAPON"] = 3,
    ["INVTYPE_WEAPONOFFHAND"] = 4,
    ["INVTYPE_SHIELD"] = 5,
    ["INVTYPE_HOLDABLE"] = 6,
    ["INVTYPE_RANGED"] = 7,
    ["INVTYPE_RANGEDRIGHT"] = 8,
    ["INVTYPE_THROWN"] = 9,
    ["INVTYPE_HEAD"] = 10,
    ["INVTYPE_NECK"] = 11,
    ["INVTYPE_SHOULDER"] = 12,
    ["INVTYPE_CLOAK"] = 13,
    ["INVTYPE_CHEST"] = 14,
    ["INVTYPE_ROBE"] = 14,
    ["INVTYPE_BODY"] = 15,
    ["INVTYPE_TABARD"] = 16,
    ["INVTYPE_WRIST"] = 17,
    ["INVTYPE_HAND"] = 18,
    ["INVTYPE_WAIST"] = 19,
    ["INVTYPE_LEGS"] = 20,
    ["INVTYPE_FEET"] = 21,
    ["INVTYPE_FINGER"] = 22,
    ["INVTYPE_TRINKET"] = 23,
    ["INVTYPE_RELIC"] = 24,
    ["INVTYPE_BAG"] = 25,
    ["INVTYPE_QUIVER"] = 26,
    ["INVTYPE_AMMO"] = 27,
}

-- Trade Goods subclass ordering (TBC)
local TRADE_GOODS_SUBCLASS_ORDER = {
    [1] = 1,   -- Parts
    [2] = 2,   -- Explosives
    [3] = 3,   -- Devices
    [4] = 4,   -- Jewelcrafting
    [5] = 5,   -- Cloth
    [6] = 6,   -- Leather
    [7] = 7,   -- Metal & Stone
    [8] = 8,   -- Meat
    [9] = 9,   -- Herb
    [10] = 10, -- Elemental
    [11] = 11, -- Other
    [12] = 12, -- Enchanting
    [14] = 13, -- Inscription (not TBC)
}

-- Consumable subclass ordering
local CONSUMABLE_SUBCLASS_ORDER = {
    [0] = 1,   -- Consumable (generic)
    [1] = 2,   -- Potion
    [2] = 3,   -- Elixir
    [3] = 4,   -- Flask
    [4] = 5,   -- Scroll
    [5] = 6,   -- Food & Drink
    [6] = 7,   -- Item Enhancement
    [7] = 8,   -- Bandage
    [8] = 9,   -- Other
}

--===========================================================================
-- UTILITY FUNCTIONS
--===========================================================================

function SortEngine:ClearCache()
    -- Log performance stats before clearing (if any work was done)
    if perfStats.sortKeyComputes > 0 then
        local sortKeyHitRate = perfStats.sortKeyCacheHits / (perfStats.sortKeyComputes + perfStats.sortKeyCacheHits) * 100
        ns:Debug(string.format("Sort cache stats - SortKeys: %d computes, %d hits (%.0f%%)",
            perfStats.sortKeyComputes,
            perfStats.sortKeyCacheHits,
            sortKeyHitRate
        ))
    end
    wipe(sortKeyCache)
    wipe(itemInfoCache)
    perfStats.sortKeyComputes = 0
    perfStats.sortKeyCacheHits = 0
end

-------------------------------------------------
-- Check if item is a tool
-------------------------------------------------
local function IsTool(itemType, itemSubType, itemName)
    if not itemType then return false end

    local typeLower = string_lower(itemType)
    local subLower = itemSubType and string_lower(itemSubType) or ""
    local nameLower = itemName and string_lower(itemName) or ""

    if typeLower == "tools" or typeLower == "tool" then return true end
    if string_find(subLower, "fishing") then return true end
    if string_find(subLower, "mining") then return true end
    if string_find(nameLower, "mining pick") then return true end
    if string_find(nameLower, "fishing pole") then return true end
    if string_find(nameLower, "fishing rod") then return true end
    if string_find(nameLower, "skinning knife") then return true end
    if string_find(nameLower, "blacksmith hammer") then return true end
    if string_find(nameLower, "arclight spanner") then return true end

    return false
end

-------------------------------------------------
-- Bag family utilities
-------------------------------------------------
local function GetBagFamily(bagID)
    if bagID == 0 then return 0 end
    local numFreeSlots, bagFamily = C_Container_GetContainerNumFreeSlots(bagID)
    return bagFamily or 0
end

-- Internal marker for reagent bag (Retail only, not a real bagFamily value)
-- The reagent bag (ID 5) doesn't use standard bagFamily bits. We detect
-- reagent items via classID heuristics. This marker is used in bagFamilies
-- so GetBagTypeFromFamily and CanItemGoInBag can identify the reagent bag.
local REAGENT_BAG_MARKER = -1

-- Heuristic: is this item a crafting reagent that belongs in the reagent bag?
-- Uses classID 7 (Trade Goods) but excludes non-reagent subcategories.
-- subClassID 2 = Explosives, 3 = Devices (engineering gadgets, not reagents)
-- If a false positive slips through, ExecuteMoves_Yielding's safety net skips it.
local function IsReagentItem(itemID)
    if not itemID then return false end
    local cached = itemInfoCache[itemID]
    if not cached then return false end
    if cached.classID == 7 and cached.subClassID ~= 2 and cached.subClassID ~= 3 then
        return true
    end
    return false
end

local function CanItemGoInBag(itemID, bagFamily)
    if bagFamily == 0 then return true end
    if not itemID then return false end
    -- Reagent bag: use classID-based heuristic
    if bagFamily == REAGENT_BAG_MARKER then
        return IsReagentItem(itemID)
    end
    local cached = itemInfoCache[itemID]
    local itemFamily = cached and cached.itemFamily or C_Item_GetItemFamily(itemID)
    if not itemFamily then return false end
    return bit_band(itemFamily, bagFamily) ~= 0
end

local function GetBagTypeFromFamily(bagFamily)
    if bagFamily == 0 then return nil end
    if bagFamily == REAGENT_BAG_MARKER then return "reagent" end

    -- TBC-specific bag types (quiver/ammo only exist in TBC)
    if Expansion.IsTBC then
        if bit_band(bagFamily, 1) ~= 0 then return "quiver" end
        if bit_band(bagFamily, 2) ~= 0 then return "ammo" end
    end

    -- Common bag types (all Classic expansions)
    if bit_band(bagFamily, 4) ~= 0 then return "soul" end
    if bit_band(bagFamily, 8) ~= 0 then return "leatherworking" end
    if bit_band(bagFamily, 32) ~= 0 then return "herb" end
    if bit_band(bagFamily, 64) ~= 0 then return "enchant" end
    if bit_band(bagFamily, 128) ~= 0 then return "engineering" end
    if bit_band(bagFamily, 1024) ~= 0 then return "mining" end

    -- MoP-specific bag types
    if Expansion.IsMoP then
        if bit_band(bagFamily, 16) ~= 0 then return "inscription" end
        if bit_band(bagFamily, 512) ~= 0 then return "gem" end
    end

    return "specialized"
end

local function GetItemPreferredContainer(itemID)
    if not itemID then return nil end
    -- Retail: crafting reagents prefer the reagent bag
    if Expansion.IsRetail and Constants.REAGENT_BAG then
        if IsReagentItem(itemID) then
            return "reagent"
        end
    end
    local itemFamily = C_Item_GetItemFamily(itemID)
    if not itemFamily or itemFamily == 0 then return nil end
    return GetBagTypeFromFamily(itemFamily)
end

--===========================================================================
-- SORT KEY COMPUTATION
--===========================================================================

local function GetSortedClassID(classID)
    return CLASS_ORDER[classID] or 99
end

local function GetSortedSubClassID(classID, subClassID)
    if classID == 2 then -- Weapon
        return WEAPON_SUBCLASS_ORDER[subClassID] or 99
    elseif classID == 4 then -- Armor
        return ARMOR_SUBCLASS_ORDER[subClassID] or 99
    elseif classID == 7 then -- Trade Goods
        return TRADE_GOODS_SUBCLASS_ORDER[subClassID] or 99
    elseif classID == 0 then -- Consumable
        return CONSUMABLE_SUBCLASS_ORDER[subClassID] or 99
    end
    return subClassID or 99
end

local function GetEquipSlotOrder(equipLoc)
    return EQUIP_SLOT_ORDER[equipLoc] or 99
end

-- Numeric key for swap deduplication (avoids string concatenation garbage)
-- Offset bagIDs by 10 to handle negatives (-2..12 → 8..22), slots are 1-36
local function SlotPairKey(bag1, slot1, bag2, slot2)
    return ((bag1 + 10) * 100 + slot1) * 10000 + (bag2 + 10) * 100 + slot2
end

--===========================================================================
-- BAG CLASSIFICATION
--===========================================================================

local function ClassifyBags(bagIDs)
    local containers = {
        soul = {}, herb = {}, enchant = {},
        engineering = {}, mining = {}, leatherworking = {},
        specialized = {}, regular = {}
    }

    if Expansion.IsTBC then
        containers.quiver = {}
        containers.ammo = {}
    end

    if Expansion.IsMoP then
        containers.gem = {}
        containers.inscription = {}
    end

    if Expansion.IsRetail then
        containers.reagent = {}
    end

    local bagFamilies = {}

    for _, bagID in ipairs(bagIDs) do
        -- Retail: reagent bag identified by ID, uses marker for routing
        if Expansion.IsRetail and Constants.REAGENT_BAG and bagID == Constants.REAGENT_BAG then
            bagFamilies[bagID] = REAGENT_BAG_MARKER
            containers.reagent[#containers.reagent + 1] = bagID
        else
            local family = GetBagFamily(bagID)
            bagFamilies[bagID] = family
            local bagType = GetBagTypeFromFamily(family)
            if bagType and containers[bagType] then
                local ct = containers[bagType]
                ct[#ct + 1] = bagID
            elseif bagType then
                containers.specialized[#containers.specialized + 1] = bagID
            else
                containers.regular[#containers.regular + 1] = bagID
            end
        end
    end

    return containers, bagFamilies
end

--===========================================================================
-- SNAPSHOT-BASED SLOT MAP
-- Scans all slots ONCE, builds in-memory map for all subsequent computation
--===========================================================================

-- Pinned slots set, loaded once per sort pass
local currentPinnedSlots = {}
-- User-marked junk set, loaded once per sort pass. Kept outside sortKeyCache
-- so toggling a mark at runtime takes effect without invalidating the cache.
local currentMarkedJunk = {}

local function SnapshotSlots(bagIDs)
    local slotMap = {}  -- key: bagID*1000+slot → entry (or nil for empty)
    local items = {}
    local sequence = 0
    local whiteItemsJunk = Database:GetSetting("whiteItemsJunk") or false
    currentPinnedSlots = Database:GetPinnedSlotSet()
    currentMarkedJunk = Database:GetMarkedJunkSet()

    for _, bagID in ipairs(bagIDs) do
        local numSlots = C_Container_GetContainerNumSlots(bagID)
        for slot = 1, numSlots do
            local itemInfo = C_Container_GetContainerItemInfo(bagID, slot)
            if itemInfo and itemInfo.itemID then
                local itemID = itemInfo.itemID
                local stackCount = tonumber(itemInfo.stackCount) or 1

                -- Get or compute item info cache
                local info = itemInfoCache[itemID]
                if not info then
                    local itemLink = itemInfo.hyperlink
                    local itemName, _, itemQuality, itemLevel, _, itemType, itemSubType, _, itemEquipLoc, _, _, classID, subClassID = GetItemInfo(itemLink)
                    -- 3.3.5a's GetItemInfo stops at position 11, so classID and
                    -- subClassID come back nil and every item would fall to the
                    -- Miscellaneous/0 defaults below -- collapsing CLASS_ORDER.
                    -- Pure table lookup, no API call: safe inside the offline phase.
                    if classID == nil and ns.Compat then
                        classID, subClassID = ns.Compat.ResolveItemClassIDs(itemType, itemSubType, itemID)
                    end
                    info = {
                        itemName = itemName or "",
                        quality = tonumber(itemQuality or itemInfo.quality or 0) or 0,
                        itemLevel = tonumber(itemLevel or 0) or 0,
                        itemType = itemType or "Miscellaneous",
                        itemSubType = itemSubType or "",
                        equipLoc = itemEquipLoc or "",
                        classID = classID or 15,
                        subClassID = subClassID or 0,
                        itemFamily = C_Item_GetItemFamily(itemID) or 0,
                        isCraftingReagent = itemInfo.isCraftingReagent or false,
                    }
                    itemInfoCache[itemID] = info
                end

                -- Get or compute sort keys
                local sk = sortKeyCache[itemID]
                if not sk then
                    perfStats.sortKeyComputes = perfStats.sortKeyComputes + 1

                    local sortedClassID = GetSortedClassID(info.classID)
                    local isEquippable = (info.classID == 2 or info.classID == 4) and
                                        info.equipLoc ~= "" and info.equipLoc ~= "INVTYPE_BAG"

                    local shouldBeJunk = false
                    local isGrayItem = info.quality == 0
                    if info.itemName == "" then
                        -- Don't mark items with incomplete data as junk
                        shouldBeJunk = false
                    elseif isGrayItem then
                        shouldBeJunk = not IsTool(info.itemType, info.itemSubType, info.itemName)
                    elseif (info.quality == 1) and isEquippable and whiteItemsJunk then
                        local isValuableSlot = Constants.VALUABLE_EQUIP_SLOTS and Constants.VALUABLE_EQUIP_SLOTS[info.equipLoc]
                        if not isValuableSlot then
                            shouldBeJunk = not IsTool(info.itemType, info.itemSubType, info.itemName) and info.itemFamily == 0
                        end
                    end

                    if shouldBeJunk then
                        sortedClassID = 100
                    end

                    -- Mount items (classID 15, subClassID 5) sort right after priority items
                    local itemPriority = PRIORITY_ITEMS[itemID]
                    if not itemPriority then
                        if info.classID == 15 and info.subClassID == 5 then
                            itemPriority = 2  -- Mounts: after hearthstone (1), before everything else
                        else
                            itemPriority = 1000
                        end
                    end

                    sk = {
                        priority = itemPriority,
                        sortedClassID = sortedClassID,
                        sortedSubClassID = GetSortedSubClassID(info.classID, info.subClassID),
                        sortedEquipSlot = GetEquipSlotOrder(info.equipLoc),
                        isEquippable = isEquippable,
                        isJunk = shouldBeJunk,
                        invertedQuality = -info.quality,
                        invertedItemLevel = -info.itemLevel,
                        invertedItemID = -itemID,
                    }
                    sortKeyCache[itemID] = sk
                else
                    perfStats.sortKeyCacheHits = perfStats.sortKeyCacheHits + 1
                end

                sequence = sequence + 1
                local key = bagID * 1000 + slot
                local isPinned = currentPinnedSlots[key] or false
                -- User-mark override: applied here (not in sk cache) so toggles
                -- take effect on the next sort without cache invalidation.
                local userMarkedJunk = currentMarkedJunk[itemID] or false
                local effectiveIsJunk = sk.isJunk or userMarkedJunk
                local effectiveSortedClassID = userMarkedJunk and 100 or sk.sortedClassID
                local entry = {
                    bagID = bagID,
                    slot = slot,
                    itemID = itemID,
                    stackCount = stackCount,
                    itemName = info.itemName,
                    sequence = sequence,
                    isPinned = isPinned,
                    -- Inline sort keys (no separate table per item)
                    priority = sk.priority,
                    sortedClassID = effectiveSortedClassID,
                    sortedSubClassID = sk.sortedSubClassID,
                    sortedEquipSlot = sk.sortedEquipSlot,
                    isEquippable = sk.isEquippable,
                    isJunk = effectiveIsJunk,
                    invertedQuality = sk.invertedQuality,
                    invertedItemLevel = sk.invertedItemLevel,
                    invertedItemID = sk.invertedItemID,
                    invertedCount = -stackCount,
                }
                slotMap[key] = entry
                if not isPinned then
                    items[#items + 1] = entry
                end
            end
        end
    end

    return slotMap, items
end

-- Collect items from snapshot for specific bags
local function CollectItemsFromSnapshot(slotMap, bagIDs)
    local items = {}
    for _, bagID in ipairs(bagIDs) do
        local numSlots = C_Container_GetContainerNumSlots(bagID)
        for slot = 1, numSlots do
            local key = bagID * 1000 + slot
            local entry = slotMap[key]
            if entry and not entry.isPinned then
                items[#items + 1] = entry
            end
        end
    end
    return items
end

-- Collect junk items from snapshot for specific bags
local function CollectJunkFromSnapshot(slotMap, bagIDs)
    local junk = {}
    for _, bagID in ipairs(bagIDs) do
        local numSlots = C_Container_GetContainerNumSlots(bagID)
        for slot = 1, numSlots do
            local key = bagID * 1000 + slot
            local entry = slotMap[key]
            if entry and entry.isJunk and not entry.isPinned then
                junk[#junk + 1] = entry
            end
        end
    end
    return junk
end

--===========================================================================
-- SORT COMPARATOR
--===========================================================================

local currentReverseStackSort = false
local currentSortPriority = "default"

local function SortComparator(a, b)
    if a.priority ~= b.priority then return a.priority < b.priority end

    if currentSortPriority == "ilvl" then
        if a.invertedItemLevel ~= b.invertedItemLevel then return a.invertedItemLevel < b.invertedItemLevel end
        if a.invertedQuality ~= b.invertedQuality then return a.invertedQuality < b.invertedQuality end
        if a.sortedClassID ~= b.sortedClassID then return a.sortedClassID < b.sortedClassID end
        if a.isEquippable and b.isEquippable then
            if a.sortedEquipSlot ~= b.sortedEquipSlot then return a.sortedEquipSlot < b.sortedEquipSlot end
        end
        if a.sortedSubClassID ~= b.sortedSubClassID then return a.sortedSubClassID < b.sortedSubClassID end
    elseif currentSortPriority == "quality" then
        if a.invertedQuality ~= b.invertedQuality then return a.invertedQuality < b.invertedQuality end
        if a.invertedItemLevel ~= b.invertedItemLevel then return a.invertedItemLevel < b.invertedItemLevel end
        if a.sortedClassID ~= b.sortedClassID then return a.sortedClassID < b.sortedClassID end
        if a.isEquippable and b.isEquippable then
            if a.sortedEquipSlot ~= b.sortedEquipSlot then return a.sortedEquipSlot < b.sortedEquipSlot end
        end
        if a.sortedSubClassID ~= b.sortedSubClassID then return a.sortedSubClassID < b.sortedSubClassID end
    else
        if a.sortedClassID ~= b.sortedClassID then return a.sortedClassID < b.sortedClassID end
        if a.isEquippable and b.isEquippable then
            if a.sortedEquipSlot ~= b.sortedEquipSlot then return a.sortedEquipSlot < b.sortedEquipSlot end
        end
        if a.sortedSubClassID ~= b.sortedSubClassID then return a.sortedSubClassID < b.sortedSubClassID end
        if a.invertedItemLevel ~= b.invertedItemLevel then return a.invertedItemLevel < b.invertedItemLevel end
        if a.invertedQuality ~= b.invertedQuality then return a.invertedQuality < b.invertedQuality end
    end

    if a.itemName ~= b.itemName then return a.itemName < b.itemName end
    if a.invertedItemID ~= b.invertedItemID then return a.invertedItemID < b.invertedItemID end
    if a.invertedCount ~= b.invertedCount then
        if currentReverseStackSort then return a.stackCount < b.stackCount
        else return a.invertedCount < b.invertedCount end
    end
    return a.sequence < b.sequence
end

local function SortItems(items)
    currentReverseStackSort = Database:GetSetting("reverseStackSort")
    currentSortPriority = Database:GetSetting("sortPriority") or "default"
    table_sort(items, SortComparator)
    return items
end

--===========================================================================
-- TARGET POSITION BUILDERS
--===========================================================================

local function BuildTargetPositions(bagIDs, itemCount)
    local positions = {}
    local index = 1
    local rightToLeft = Database:GetSetting("sortRightToLeft")

    local bagOrder = {}
    for _, bagID in ipairs(bagIDs) do
        bagOrder[#bagOrder + 1] = bagID
    end

    if rightToLeft then
        local reversed = {}
        for i = #bagOrder, 1, -1 do
            reversed[#reversed + 1] = bagOrder[i]
        end
        bagOrder = reversed
    end

    for _, bagID in ipairs(bagOrder) do
        local numSlots = C_Container_GetContainerNumSlots(bagID)

        if rightToLeft then
            for slot = numSlots, 1, -1 do
                local key = bagID * 1000 + slot
                if index <= itemCount and not currentPinnedSlots[key] then
                    positions[index] = { bagID = bagID, slot = slot }
                    index = index + 1
                end
            end
        else
            for slot = 1, numSlots do
                local key = bagID * 1000 + slot
                if index <= itemCount and not currentPinnedSlots[key] then
                    positions[index] = { bagID = bagID, slot = slot }
                    index = index + 1
                end
            end
        end
    end

    return positions
end

local function BuildTailPositions(bagIDs, junkCount)
    local positions = {}
    if junkCount <= 0 then return positions end

    local rightToLeft = Database:GetSetting("sortRightToLeft")

    local bagOrder = {}
    for _, bagID in ipairs(bagIDs) do
        local numSlots = C_Container_GetContainerNumSlots(bagID)
        if numSlots > 0 then
            bagOrder[#bagOrder + 1] = { bagID = bagID, numSlots = numSlots }
        end
    end

    local tailSlots = {}

    if rightToLeft then
        for i = 1, #bagOrder do
            local info = bagOrder[i]
            for slot = 1, info.numSlots do
                local key = info.bagID * 1000 + slot
                if #tailSlots < junkCount and not currentPinnedSlots[key] then
                    tailSlots[#tailSlots + 1] = { bagID = info.bagID, slot = slot }
                end
            end
            if #tailSlots >= junkCount then break end
        end
    else
        for i = #bagOrder, 1, -1 do
            local info = bagOrder[i]
            for slot = info.numSlots, 1, -1 do
                local key = info.bagID * 1000 + slot
                if #tailSlots < junkCount and not currentPinnedSlots[key] then
                    tailSlots[#tailSlots + 1] = { bagID = info.bagID, slot = slot }
                end
            end
            if #tailSlots >= junkCount then break end
        end
    end

    table_sort(tailSlots, function(a, b)
        if a.bagID ~= b.bagID then return a.bagID < b.bagID end
        return a.slot < b.slot
    end)

    return tailSlots
end

local function SplitJunkItems(items)
    local nonJunk, junk = {}, {}
    for _, item in ipairs(items) do
        if item.isJunk then
            junk[#junk + 1] = item
        else
            nonJunk[#nonJunk + 1] = item
        end
    end
    return nonJunk, junk
end

--===========================================================================
-- OFFLINE MOVE COMPUTATION
-- Pure computation against slotMap — no API calls
--===========================================================================

-- Route specialized items to their preferred containers (offline)
local function RouteSpecializedItems_Offline(bagIDs, containers, bagFamilies, slotMap)
    local moves = {}

    -- Build free slot lists from snapshot (skip pinned slots)
    local freeSlotsByType = {}
    local freeSlotIdx = {}
    for bagType, bagList in pairs(containers) do
        if bagType ~= "regular" then
            local free = {}
            for _, targetBagID in ipairs(bagList) do
                local numSlots = C_Container_GetContainerNumSlots(targetBagID)
                for slot = 1, numSlots do
                    local key = targetBagID * 1000 + slot
                    if not slotMap[key] and not currentPinnedSlots[key] then
                        free[#free + 1] = targetBagID
                        free[#free + 1] = slot
                    end
                end
            end
            freeSlotsByType[bagType] = free
            freeSlotIdx[bagType] = 0
        end
    end

    for _, bagID in ipairs(bagIDs) do
        local numSlots = C_Container_GetContainerNumSlots(bagID)
        for slot = 1, numSlots do
            local key = bagID * 1000 + slot
            local entry = slotMap[key]
            if entry and not entry.isPinned then
                local preferredType = GetItemPreferredContainer(entry.itemID)
                local currentBagType = GetBagTypeFromFamily(bagFamilies[bagID] or 0)

                if preferredType and currentBagType ~= preferredType then
                    local freeList = freeSlotsByType[preferredType]
                    local idx = freeSlotIdx[preferredType]
                    if freeList and idx then
                        while (idx * 2 + 2) <= #freeList do
                            local targetBagID = freeList[idx * 2 + 1]
                            local targetSlot = freeList[idx * 2 + 2]
                            local targetBagFamily = bagFamilies[targetBagID] or 0
                            if CanItemGoInBag(entry.itemID, targetBagFamily) then
                                moves[#moves + 1] = {
                                    type = "move",
                                    sourceBag = bagID, sourceSlot = slot,
                                    targetBag = targetBagID, targetSlot = targetSlot,
                                    expectedItemID = entry.itemID,
                                }
                                -- Update slotMap in-memory
                                local targetKey = targetBagID * 1000 + targetSlot
                                slotMap[targetKey] = entry
                                slotMap[key] = nil
                                entry.bagID = targetBagID
                                entry.slot = targetSlot

                                idx = idx + 1
                                freeSlotIdx[preferredType] = idx
                                break
                            end
                            idx = idx + 1
                            freeSlotIdx[preferredType] = idx
                        end
                    end
                end
            end
        end
    end

    return moves
end

-- Consolidate stacks offline — compute merge moves against slotMap
local function ConsolidateStacks_Offline(bagIDs, slotMap)
    local moves = {}
    local itemGroups = {}

    -- Build groups from snapshot (skip pinned items)
    for _, bagID in ipairs(bagIDs) do
        local numSlots = C_Container_GetContainerNumSlots(bagID)
        for slot = 1, numSlots do
            local key = bagID * 1000 + slot
            local entry = slotMap[key]
            if entry and not entry.isPinned then
                local groupKey = entry.itemID
                if not itemGroups[groupKey] then
                    itemGroups[groupKey] = {}
                end
                local stacks = itemGroups[groupKey]
                stacks[#stacks + 1] = entry
            end
        end
    end

    for itemID, stacks in pairs(itemGroups) do
        if #stacks > 1 then
            local maxStack = 1
            local cached = itemInfoCache[itemID]
            if cached and cached.maxStack then
                maxStack = cached.maxStack
            else
                local _, _, _, _, _, _, _, stackSize = GetItemInfo(itemID)
                maxStack = tonumber(stackSize) or 1
                if cached then
                    cached.maxStack = maxStack
                end
            end

            if maxStack > 1 then
                -- Sort by count descending (fill bigger stacks first)
                table_sort(stacks, function(a, b)
                    return a.stackCount > b.stackCount
                end)

                for i = 1, #stacks do
                    local dest = stacks[i]
                    if dest.stackCount < maxStack and dest.stackCount > 0 then
                        for j = i + 1, #stacks do
                            local src = stacks[j]
                            if src.stackCount > 0 then
                                local spaceAvailable = maxStack - dest.stackCount
                                local amountToMove = math_min(spaceAvailable, src.stackCount)

                                if amountToMove > 0 then
                                    if amountToMove < src.stackCount then
                                        -- Partial split
                                        moves[#moves + 1] = {
                                            type = "split",
                                            sourceBag = src.bagID, sourceSlot = src.slot,
                                            targetBag = dest.bagID, targetSlot = dest.slot,
                                            expectedItemID = itemID,
                                            splitCount = amountToMove,
                                        }
                                    else
                                        -- Move whole stack
                                        moves[#moves + 1] = {
                                            type = "move",
                                            sourceBag = src.bagID, sourceSlot = src.slot,
                                            targetBag = dest.bagID, targetSlot = dest.slot,
                                            expectedItemID = itemID,
                                        }
                                    end

                                    -- Update snapshot in-memory
                                    dest.stackCount = dest.stackCount + amountToMove
                                    dest.invertedCount = -dest.stackCount
                                    src.stackCount = src.stackCount - amountToMove
                                    src.invertedCount = -src.stackCount

                                    -- If source is now empty, remove from slotMap
                                    if src.stackCount <= 0 then
                                        local srcKey = src.bagID * 1000 + src.slot
                                        slotMap[srcKey] = nil
                                    end

                                    if dest.stackCount >= maxStack then break end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return moves
end

-- Compute sort moves offline — assigns items to target positions via slotMap
local function ComputeMoves(items, targetPositions, bagFamilies, slotMap)
    local moves = {}
    local swappedSlots = {}

    for i, item in ipairs(items) do
        local target = targetPositions[i]
        if target then
            local targetFamily = bagFamilies[target.bagID] or 0
            local canGoInBag = (targetFamily == 0) or CanItemGoInBag(item.itemID, targetFamily)

            if canGoInBag and (item.bagID ~= target.bagID or item.slot ~= target.slot) then
                local targetKey = target.bagID * 1000 + target.slot
                local targetEntry = slotMap[targetKey]

                if not targetEntry then
                    -- Move to empty slot
                    moves[#moves + 1] = {
                        type = "move",
                        sourceBag = item.bagID, sourceSlot = item.slot,
                        targetBag = target.bagID, targetSlot = target.slot,
                        expectedItemID = item.itemID,
                    }
                    -- Update slotMap in-memory
                    local sourceKey = item.bagID * 1000 + item.slot
                    slotMap[sourceKey] = nil
                    slotMap[targetKey] = item
                    item.bagID = target.bagID
                    item.slot = target.slot
                else
                    -- Target occupied — check if items are interchangeable
                    if item.itemID == targetEntry.itemID and item.stackCount == targetEntry.stackCount then
                        -- Identical items, swap is a no-op
                    else
                        local sourceFamily = bagFamilies[item.bagID] or 0
                        local targetCanGoInSource = (sourceFamily == 0) or CanItemGoInBag(targetEntry.itemID, sourceFamily)

                        if targetCanGoInSource then
                            local reverseKey = SlotPairKey(target.bagID, target.slot, item.bagID, item.slot)
                            if not swappedSlots[reverseKey] then
                                local forwardKey = SlotPairKey(item.bagID, item.slot, target.bagID, target.slot)
                                swappedSlots[forwardKey] = true
                                moves[#moves + 1] = {
                                    type = "swap",
                                    sourceBag = item.bagID, sourceSlot = item.slot,
                                    targetBag = target.bagID, targetSlot = target.slot,
                                    expectedItemID = item.itemID,
                                }
                                -- Update slotMap: swap entries
                                local sourceKey = item.bagID * 1000 + item.slot
                                local oldBag, oldSlot = item.bagID, item.slot
                                slotMap[sourceKey] = targetEntry
                                slotMap[targetKey] = item
                                item.bagID = target.bagID
                                item.slot = target.slot
                                targetEntry.bagID = oldBag
                                targetEntry.slot = oldSlot
                            end
                        end
                    end
                end
            end
        end
    end

    return moves
end

--===========================================================================
-- MOVE EXECUTION
--===========================================================================

local function AnyItemsLocked()
    if pendingLockCount == 0 then return false end
    for i = 0, pendingLockCount - 1 do
        local bagID = pendingLockSlots[i * 2 + 1]
        local slot = pendingLockSlots[i * 2 + 2]
        local itemInfo = C_Container_GetContainerItemInfo(bagID, slot)
        if itemInfo and itemInfo.isLocked then return true end
    end
    return false
end

-- Execute pre-computed moves with API calls, yielding for budget/locks
local function ExecuteMoves_Yielding(moveList)
    local smoothSort = Database:GetSetting("smoothSort")
    ClearCursor()
    ClearPendingLocks()

    for idx, move in ipairs(moveList) do
        -- If source or target is involved in a pending move, wait for locks first
        if pendingLockCount > 0 then
            local srcKey = move.sourceBag * 1000 + move.sourceSlot
            local tgtKey = move.targetBag * 1000 + move.targetSlot
            if pendingLockSet[srcKey] or pendingLockSet[tgtKey] then
                coroutine_yield("wait_locks")
                StartFrameTimer()
                ClearPendingLocks()
            end
        end

        -- Verify source still has expected item
        local sourceInfo = C_Container_GetContainerItemInfo(move.sourceBag, move.sourceSlot)
        local canExecute = sourceInfo and sourceInfo.itemID == move.expectedItemID and not sourceInfo.isLocked

        -- For swaps, also verify target
        if canExecute and move.type == "swap" then
            local targetInfo = C_Container_GetContainerItemInfo(move.targetBag, move.targetSlot)
            if not targetInfo or targetInfo.isLocked then
                canExecute = false
            end
        end

        if canExecute then
            if move.type == "split" then
                C_Container_SplitContainerItem(move.sourceBag, move.sourceSlot, move.splitCount)
            else
                -- Both "move" and "swap" use pickup pattern
                C_Container_PickupContainerItem(move.sourceBag, move.sourceSlot)
            end
            C_Container_PickupContainerItem(move.targetBag, move.targetSlot)

            -- Verify move succeeded: if cursor still has an item, the target rejected it
            local cursorType = GetCursorInfo()
            if cursorType then
                -- Move failed (e.g., item incompatible with target bag) — put item back
                ClearCursor()
            else
                AddPendingLock(move.sourceBag, move.sourceSlot)
                AddPendingLock(move.targetBag, move.targetSlot)

                if not soundsMuted then
                    MutePickupSounds()
                    soundsMuted = true
                end
            end
        end

        -- Yield periodically for budget and locks (only in smooth sort mode)
        if smoothSort and idx % 12 == 0 and IsFrameBudgetExceeded() then
            if pendingLockCount > 0 then
                coroutine_yield("wait_locks")
                StartFrameTimer()
                ClearPendingLocks()
            else
                coroutine_yield("budget")
                StartFrameTimer()
            end
        end
    end

    -- Final lock wait if pending
    if pendingLockCount > 0 then
        coroutine_yield("wait_locks")
        StartFrameTimer()
        ClearPendingLocks()
    end
end

--===========================================================================
-- STACK CONSOLIDATION (for Restack API — uses direct API calls)
--===========================================================================

local function ConsolidateStacks(bagIDs, bagFamilies)
    local itemGroups = {}
    local pinnedSlots = Database:GetPinnedSlotSet()

    for _, bagID in ipairs(bagIDs) do
        local numSlots = C_Container_GetContainerNumSlots(bagID)
        for slot = 1, numSlots do
            local key = bagID * 1000 + slot
            if not pinnedSlots[key] then
                local itemInfo = C_Container_GetContainerItemInfo(bagID, slot)
                if itemInfo and itemInfo.itemID then
                    local groupKey = itemInfo.itemID
                    if not itemGroups[groupKey] then
                        itemGroups[groupKey] = { itemID = itemInfo.itemID, stacks = {} }
                    end
                    local stacks = itemGroups[groupKey].stacks
                    stacks[#stacks + 1] = {
                        bagID = bagID, slot = slot,
                        count = tonumber(itemInfo.stackCount) or 1
                    }
                end
            end
        end
    end

    local consolidationMoves = 0
    ClearPendingLocks()
    for _, group in pairs(itemGroups) do
        if #group.stacks > 1 then
            local maxStack = 1
            local cached = itemInfoCache[group.itemID]
            if cached and cached.maxStack then
                maxStack = cached.maxStack
            else
                local _, _, _, _, _, _, _, stackSize = GetItemInfo(group.itemID)
                maxStack = tonumber(stackSize) or 1
                -- Store in cache for reuse
                if cached then
                    cached.maxStack = maxStack
                end
            end

            if maxStack > 1 then
                table_sort(group.stacks, function(a, b)
                    return (tonumber(a.count) or 0) > (tonumber(b.count) or 0)
                end)

                for i = 1, #group.stacks do
                    local source = group.stacks[i]
                    if source.count < maxStack and source.count > 0 then
                        for j = i + 1, #group.stacks do
                            local target = group.stacks[j]
                            if target.count > 0 then
                                local spaceAvailable = maxStack - source.count
                                local amountToMove = math_min(spaceAvailable, target.count)

                                if amountToMove > 0 then
                                    local sourceInfo = C_Container_GetContainerItemInfo(source.bagID, source.slot)
                                    local targetInfo = C_Container_GetContainerItemInfo(target.bagID, target.slot)

                                    if sourceInfo and targetInfo and not sourceInfo.isLocked and not targetInfo.isLocked then
                                        if amountToMove < target.count then
                                            C_Container_SplitContainerItem(target.bagID, target.slot, amountToMove)
                                            C_Container_PickupContainerItem(source.bagID, source.slot)
                                        else
                                            C_Container_PickupContainerItem(target.bagID, target.slot)
                                            C_Container_PickupContainerItem(source.bagID, source.slot)
                                        end
                                        ClearCursor()
                                        AddPendingLock(source.bagID, source.slot)
                                        AddPendingLock(target.bagID, target.slot)

                                        if not soundsMuted then
                                            MutePickupSounds()
                                            soundsMuted = true
                                        end

                                        source.count = source.count + amountToMove
                                        target.count = target.count - amountToMove
                                        consolidationMoves = consolidationMoves + 1

                                        if source.count >= maxStack then break end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return consolidationMoves
end

-- Route specialized items (e.g. ammo→quiver, soul shards→soul bag) for the Restack API.
-- Snapshots once, plans moves via RouteSpecializedItems_Offline (the same offline planner
-- used by SortBags), then executes them with direct API calls in the same style as
-- ConsolidateStacks. Returns the number of moves executed.
local function RestackRouteSpecialized(bagIDs)
    local slotMap = SnapshotSlots(bagIDs)
    local containers, bagFamilies = ClassifyBags(bagIDs)
    local moves = RouteSpecializedItems_Offline(bagIDs, containers, bagFamilies, slotMap)

    if #moves == 0 then return 0 end

    ClearCursor()
    ClearPendingLocks()

    local executed = 0
    for _, move in ipairs(moves) do
        local srcInfo = C_Container_GetContainerItemInfo(move.sourceBag, move.sourceSlot)
        local tgtInfo = C_Container_GetContainerItemInfo(move.targetBag, move.targetSlot)

        -- Verify the world still matches the plan: source still holds the expected item,
        -- target is still empty, and neither slot is locked from a prior pickup.
        if srcInfo and srcInfo.itemID == move.expectedItemID and not srcInfo.isLocked
           and (not tgtInfo or not tgtInfo.itemID) then
            C_Container_PickupContainerItem(move.sourceBag, move.sourceSlot)
            C_Container_PickupContainerItem(move.targetBag, move.targetSlot)
            ClearCursor()

            AddPendingLock(move.sourceBag, move.sourceSlot)
            AddPendingLock(move.targetBag, move.targetSlot)

            if not soundsMuted then
                MutePickupSounds()
                soundsMuted = true
            end

            executed = executed + 1
        end
    end

    return executed
end

-- Cached specialized bag type list (initialized once on first use)
local cachedSpecializedTypes = nil
local function GetSpecializedTypes()
    if not cachedSpecializedTypes then
        cachedSpecializedTypes = {"soul", "herb", "enchant", "engineering", "mining", "leatherworking"}
        if Expansion.IsTBC then
            cachedSpecializedTypes[#cachedSpecializedTypes + 1] = "quiver"
            cachedSpecializedTypes[#cachedSpecializedTypes + 1] = "ammo"
        end
        if Expansion.IsMoP then
            cachedSpecializedTypes[#cachedSpecializedTypes + 1] = "gem"
            cachedSpecializedTypes[#cachedSpecializedTypes + 1] = "inscription"
        end
        if Expansion.IsRetail then
            cachedSpecializedTypes[#cachedSpecializedTypes + 1] = "reagent"
        end
    end
    return cachedSpecializedTypes
end

--===========================================================================
-- SORT COROUTINE (single-pass snapshot-based)
-- 1. Snapshot all slots once
-- 2. Compute ALL moves offline (route, consolidate, sort)
-- 3. Execute moves in single pass
--===========================================================================

local function SortCoroutineBody(bagIDs)
    local t0 = debugprofilestop()

    -- 1. Snapshot all slots (one scan — the ONLY full API scan)
    local slotMap = SnapshotSlots(bagIDs)
    local t1 = debugprofilestop()

    -- 2. Classify bags
    local containers, bagFamilies = ClassifyBags(bagIDs)
    local t2 = debugprofilestop()

    -- 3. Collect all moves
    local allMoves = {}
    local totalMoveCount = 0

    local function appendMoves(moves)
        for _, move in ipairs(moves) do
            totalMoveCount = totalMoveCount + 1
            allMoves[totalMoveCount] = move
        end
    end

    -- 4. Route specialized items (offline, updates slotMap)
    appendMoves(RouteSpecializedItems_Offline(bagIDs, containers, bagFamilies, slotMap))
    local t3 = debugprofilestop()

    -- 5. Consolidate stacks (offline, updates slotMap)
    appendMoves(ConsolidateStacks_Offline(bagIDs, slotMap))
    local t4 = debugprofilestop()

    -- 6. Sort specialized bags (from updated snapshot)
    local specializedTypes = GetSpecializedTypes()
    for _, bagType in ipairs(specializedTypes) do
        local specialBags = containers[bagType]
        if specialBags then
            for _, bagID in ipairs(specialBags) do
                local items = CollectItemsFromSnapshot(slotMap, {bagID})
                if #items > 0 then
                    SortItems(items)
                    local targets = BuildTargetPositions({bagID}, #items)
                    appendMoves(ComputeMoves(items, targets, bagFamilies, slotMap))
                end
            end
        end
    end
    local t5 = debugprofilestop()

    -- 7. Sort regular bags (non-junk forward, junk to tail)
    local regularBags = containers.regular
    if #regularBags > 0 then
        local allItems = CollectItemsFromSnapshot(slotMap, regularBags)
        if #allItems > 0 then
            SortItems(allItems)
            local nonJunk, junk = SplitJunkItems(allItems)

            if #nonJunk > 0 then
                local frontPositions = BuildTargetPositions(regularBags, #nonJunk)
                appendMoves(ComputeMoves(nonJunk, frontPositions, bagFamilies, slotMap))
            end

            if #junk > 0 then
                -- Junk positions tracked in slotMap (no API re-scan needed)
                local junkNow = CollectJunkFromSnapshot(slotMap, regularBags)
                if #junkNow > 0 then
                    local tailPositions = BuildTailPositions(regularBags, #junkNow)
                    appendMoves(ComputeMoves(junkNow, tailPositions, bagFamilies, slotMap))
                end
            end
        end
    end
    local t6 = debugprofilestop()

    ns:Debug(string.format(
        "Sort timing: snapshot=%.1fms classify=%.1fms route=%.1fms consolidate=%.1fms specSort=%.1fms regSort=%.1fms total=%.1fms moves=%d",
        (t1-t0)/1000, (t2-t1)/1000, (t3-t2)/1000, (t4-t3)/1000, (t5-t4)/1000, (t6-t5)/1000, (t6-t0)/1000, totalMoveCount
    ))

    -- 8. Execute all moves in single execution phase
    if totalMoveCount > 0 then
        ExecuteMoves_Yielding(allMoves)
    end

    return totalMoveCount
end

--===========================================================================
-- MAIN SORT FUNCTIONS
--===========================================================================

local sortFrame = CreateFrame("Frame")
local sortStartTime = 0
local sortTimeout = 30

local activeBagIDs = Constants.BAG_IDS

-- Helper to finalize sort (clean up state and notify)
local function FinishSort(message)
    local isBankSort = (activeBagIDs == Constants.BANK_BAG_IDS)
    sortInProgress = false
    sortCoroutine = nil
    soundsMuted = false
    waitingForLocks = false
    locksCleared = true
    activeBagIDs = Constants.BAG_IDS
    currentFrameBudget = FRAME_BUDGET_US
    ClearPendingLocks()
    UnmutePickupSounds()
    SortEngine:ClearCache()
    sortFrame:UnregisterEvent("ITEM_LOCK_CHANGED")
    if message then
        ns:Print(message)
    end
    -- Invalidate layout caches so the update triggers a full refresh
    local BagFrameModule = ns:GetModule("BagFrame")
    if BagFrameModule then BagFrameModule:InvalidateLayout() end
    local BankFrameModule = ns:GetModule("BankFrame")
    if BankFrameModule then BankFrameModule:InvalidateLayout() end
    local refreshStart = debugprofilestop()
    if isBankSort and ns.OnBankUpdated then
        ns.OnBankUpdated()
    else
        Events:Fire("BAGS_UPDATED")
    end
    local refreshTime = (debugprofilestop() - refreshStart) / 1000
    ns:Debug(string.format("Post-sort refresh: %.1fms", refreshTime))
end

-- Event handler for ITEM_LOCK_CHANGED (event-driven lock waiting)
sortFrame:SetScript("OnEvent", function(self, event)
    if event == "ITEM_LOCK_CHANGED" and sortInProgress and waitingForLocks then
        if not AnyItemsLocked() then
            locksCleared = true
        end
    end
end)

-- Coroutine-driven OnUpdate: resumes sort coroutine each frame within budget.
-- Single-pass architecture: snapshot once, compute moves offline, execute once.
-- After execution, one verification pass (re-snapshot, check if sorted).
sortFrame:SetScript("OnUpdate", function(self, elapsed)
    if not sortInProgress then return end

    -- Cancel sort immediately if combat starts mid-sort
    if InCombatLockdown() then
        ClearCursor()
        FinishSort("Sort cancelled: entered combat")
        return
    end

    -- Timeout check
    if GetTime() - sortStartTime > sortTimeout then
        FinishSort("Sort timed out")
        return
    end

    -- Wait for item locks to clear (event-driven)
    if waitingForLocks then
        if not locksCleared then return end
        waitingForLocks = false
    end

    -- Create new coroutine if needed (start of a new pass)
    if not sortCoroutine then
        currentPass = currentPass + 1
        if currentPass > maxPasses then
            FinishSort()
            return
        end
        sortCoroutine = coroutine_create(SortCoroutineBody)
    end

    -- Resume coroutine with frame budget
    StartFrameTimer()
    local passStart = debugprofilestop()
    local ok, result = coroutine_resume(sortCoroutine, activeBagIDs)
    local passTime = debugprofilestop() - passStart

    if not ok then
        -- Coroutine error
        ns:Debug(string.format("Sort pass %d error: %s", currentPass, tostring(result)))
        FinishSort("Sort error: " .. tostring(result))
        return
    end

    if coroutine_status(sortCoroutine) == "dead" then
        -- Coroutine completed this pass
        local moveCount = result or 0
        ns:Debug(string.format("Sort pass %d: %.2fms, %d moves", currentPass, passTime / 1000, moveCount))
        sortCoroutine = nil

        -- Sort is complete when a pass makes no moves
        if moveCount == 0 then
            FinishSort()
            return
        end

        -- More passes needed (verification), next frame creates new coroutine
    elseif result == "wait_locks" then
        -- Coroutine yielded to wait for locks — use event-driven waiting
        waitingForLocks = true
        locksCleared = not AnyItemsLocked()
    end
    -- If coroutine yielded "budget", it resumes next frame automatically
end)

-------------------------------------------------
-- Public API
-------------------------------------------------
function SortEngine:SortBags()
    if InCombatLockdown() then
        ns:Print("Cannot sort in combat")
        return false
    end

    if sortInProgress then
        ns:Print("Sort already in progress...")
        return false
    end

    -- Use native Blizzard sort API on retail (unless GudaBags sort is enabled)
    if Expansion.IsRetail and not Database:GetSetting("gudaSort") and C_Container and C_Container.SortBags then
        C_Container.SortBags()
        -- Fire event after a short delay to let the sort complete
        C_Timer.After(0.5, function()
            local BagFrameModule = ns:GetModule("BagFrame")
            if BagFrameModule then BagFrameModule:InvalidateLayout() end
            local BankFrameModule = ns:GetModule("BankFrame")
            if BankFrameModule then BankFrameModule:InvalidateLayout() end
            Events:Fire("BAGS_UPDATED")
        end)
        return true
    end

    -- Classic expansions use custom sort engine
    activeBagIDs = Constants.BAG_IDS
    currentFrameBudget = FRAME_BUDGET_US
    self:ClearCache()
    soundsMuted = false
    waitingForLocks = false
    locksCleared = true
    sortInProgress = true
    sortCoroutine = nil
    currentPass = 0

    sortStartTime = GetTime()
    sortFrame:RegisterEvent("ITEM_LOCK_CHANGED")

    return true
end

function SortEngine:IsSorting()
    return sortInProgress
end

function SortEngine:CancelSort()
    if sortInProgress then
        UnmutePickupSounds()
    end
    sortInProgress = false
    sortCoroutine = nil
    soundsMuted = false
    waitingForLocks = false
    locksCleared = true
    currentPass = 0
    ClearPendingLocks()
    sortFrame:UnregisterEvent("ITEM_LOCK_CHANGED")

    activeBagIDs = Constants.BAG_IDS
    currentFrameBudget = FRAME_BUDGET_US
    self:ClearCache()
end

function SortEngine:SortBank()
    if InCombatLockdown() then
        ns:Print("Cannot sort in combat")
        return false
    end

    local BankScanner = ns:GetModule("BankScanner")
    if not BankScanner or not BankScanner:IsBankOpen() then
        ns:Print("Cannot sort bank: not at banker")
        return false
    end

    if sortInProgress then
        ns:Print("Sort already in progress...")
        return false
    end

    -- Use native Blizzard sort API on retail (unless GudaBags sort is enabled)
    if Expansion.IsRetail and not Database:GetSetting("gudaSort") and C_Container and C_Container.SortBankBags then
        C_Container.SortBankBags()
        -- Fire event after a short delay to let the sort complete
        C_Timer.After(0.5, function()
            local BagFrameModule = ns:GetModule("BagFrame")
            if BagFrameModule then BagFrameModule:InvalidateLayout() end
            local BankFrameModule = ns:GetModule("BankFrame")
            if BankFrameModule then BankFrameModule:InvalidateLayout() end
            if ns.OnBankUpdated then
                ns.OnBankUpdated()
            else
                Events:Fire("BAGS_UPDATED")
            end
        end)
        return true
    end

    -- Classic expansions use custom sort engine
    activeBagIDs = Constants.BANK_BAG_IDS
    currentFrameBudget = FRAME_BUDGET_BANK_US
    self:ClearCache()
    soundsMuted = false
    waitingForLocks = false
    locksCleared = true
    sortInProgress = true
    sortCoroutine = nil
    currentPass = 0

    sortStartTime = GetTime()
    sortFrame:RegisterEvent("ITEM_LOCK_CHANGED")

    return true
end

function SortEngine:SortWarbandBank()
    if InCombatLockdown() then
        ns:Print("Cannot sort in combat")
        return false
    end

    local BankScanner = ns:GetModule("BankScanner")
    if not BankScanner or not BankScanner:IsBankOpen() then
        ns:Print("Cannot sort Warband bank: not at banker")
        return false
    end

    if sortInProgress then
        ns:Print("Sort already in progress...")
        return false
    end

    -- Warband bank sorting is only available on Retail
    if not Expansion.IsRetail then
        ns:Print("Warband bank is not available in this version")
        return false
    end

    -- Use native Blizzard sort API for Warband/Account bank
    if C_Container and C_Container.SortAccountBankBags then
        C_Container.SortAccountBankBags()
        -- Fire event after a short delay to let the sort complete
        C_Timer.After(0.5, function()
            local BagFrameModule = ns:GetModule("BagFrame")
            if BagFrameModule then BagFrameModule:InvalidateLayout() end
            local BankFrameModule = ns:GetModule("BankFrame")
            if BankFrameModule then BankFrameModule:InvalidateLayout() end
            if ns.OnBankUpdated then
                ns.OnBankUpdated()
            else
                Events:Fire("BAGS_UPDATED")
            end
        end)
        return true
    else
        ns:Print("Warband bank sorting not available")
        return false
    end
end

-------------------------------------------------
-- Restack Only (for Category View)
-- Consolidates stacks without sorting positions
-------------------------------------------------
local restackInProgress = false
local restackBagIDs = nil
local restackCallback = nil
local restackPassCount = 0
local restackMaxPasses = 4
local restackNextPassTime = 0
local restackPhase = nil  -- "route" then "consolidate"; nil when idle

local restackFrame = CreateFrame("Frame")
restackFrame:SetScript("OnUpdate", function(self, elapsed)
    if not restackInProgress then return end

    -- Cancel restack immediately if combat starts
    if InCombatLockdown() then
        ClearCursor()
        restackInProgress = false
        restackPhase = nil
        ClearPendingLocks()
        UnmutePickupSounds()
        ns:Print("Restack cancelled: entered combat")
        if restackCallback then
            restackCallback()
        end
        return
    end

    local now = GetTime()
    local isBankRestack = (restackBagIDs == Constants.BANK_BAG_IDS)

    -- Bank operations are server-side and need longer delays
    local lockWaitTime = isBankRestack and 0.3 or 0.1

    if now < restackNextPassTime then return end

    -- Check if any items are locked (uses targeted pendingLockSlots from prior pass)
    if AnyItemsLocked() then
        restackNextPassTime = now + lockWaitTime
        return
    end

    -- Phase 1 (one-shot): route specialized items into matching bags
    -- so Category View's "Clean Up" sends ammo→quiver, soul shards→soul bag, etc.
    if restackPhase == "route" then
        local routedMoves = RestackRouteSpecialized(restackBagIDs)
        restackPhase = "consolidate"
        if routedMoves > 0 then
            -- Defer next pass so the lock-wait check above gates execution
            restackNextPassTime = now + lockWaitTime
        end
        return
    end

    -- Phase 2: consolidate partial stacks (existing multi-pass loop)
    restackPassCount = restackPassCount + 1

    local _, bagFamilies = ClassifyBags(restackBagIDs)
    local moves = ConsolidateStacks(restackBagIDs, bagFamilies)

    if moves == 0 or restackPassCount >= restackMaxPasses then
        -- Done restacking - invalidate layouts so next update triggers full refresh
        restackInProgress = false
        restackPhase = nil
        ClearPendingLocks()
        UnmutePickupSounds()
        local BagFrameModule = ns:GetModule("BagFrame")
        if BagFrameModule then BagFrameModule:InvalidateLayout() end
        local BankFrameModule = ns:GetModule("BankFrame")
        if BankFrameModule then BankFrameModule:InvalidateLayout() end
        if restackCallback then
            restackCallback()
        end
    end
end)

function SortEngine:RestackBags(callback)
    if InCombatLockdown() then return false end

    if sortInProgress or restackInProgress then
        return false
    end

    restackInProgress = true
    restackBagIDs = Constants.BAG_IDS
    restackCallback = callback
    restackPassCount = 0
    restackNextPassTime = 0
    restackPhase = "route"

    MutePickupSounds()
    return true
end

function SortEngine:RestackBank(callback)
    if InCombatLockdown() then return false end

    local BankScanner = ns:GetModule("BankScanner")
    if not BankScanner or not BankScanner:IsBankOpen() then
        return false
    end

    if sortInProgress or restackInProgress then
        return false
    end

    restackInProgress = true
    restackBagIDs = Constants.BANK_BAG_IDS
    restackCallback = callback
    restackPassCount = 0
    restackNextPassTime = 0
    restackPhase = "consolidate"

    MutePickupSounds()
    return true
end

function SortEngine:RestackWarbandBank(callback)
    if InCombatLockdown() then return false end

    local BankScanner = ns:GetModule("BankScanner")
    if not BankScanner or not BankScanner:IsBankOpen() then
        return false
    end

    if not Expansion.IsRetail or not Constants.WARBAND_BANK_TAB_IDS then
        return false
    end

    if sortInProgress or restackInProgress then
        return false
    end

    restackInProgress = true
    restackBagIDs = Constants.WARBAND_BANK_TAB_IDS
    restackCallback = callback
    restackPassCount = 0
    restackNextPassTime = 0
    restackPhase = "consolidate"

    MutePickupSounds()
    return true
end

function SortEngine:IsRestacking()
    return restackInProgress
end
