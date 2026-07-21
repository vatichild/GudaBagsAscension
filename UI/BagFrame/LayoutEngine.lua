local addonName, ns = ...

local LayoutEngine = {}
ns:RegisterModule("BagFrame.LayoutEngine", LayoutEngine)

local Constants = ns.Constants

-- Check if an interaction window is open (bank, trade, mail, merchant, auction)
-- When these are open, items should be shown ungrouped for easier interaction
local function IsInteractionWindowOpen()
    -- Bank - check native Blizzard frame first (more reliable timing)
    -- BankFrame is the default UI bank frame that's shown when interacting with bank NPC
    if _G.BankFrame and _G.BankFrame:IsShown() then
        return true
    end

    -- Also check our custom BankFrame module
    local GudaBankFrame = ns:GetModule("BankFrame")
    if GudaBankFrame and GudaBankFrame:IsShown() then
        return true
    end

    -- Guild Bank - check native Blizzard frame
    if _G.GuildBankFrame and _G.GuildBankFrame:IsShown() then
        return true
    end

    -- Also check our custom GuildBankFrame module
    local GudaGuildBankFrame = ns:GetModule("GuildBankFrame")
    if GudaGuildBankFrame and GudaGuildBankFrame:IsShown() then
        return true
    end

    -- Trade window
    if TradeFrame and TradeFrame:IsShown() then
        return true
    end

    -- Mail window
    if MailFrame and MailFrame:IsShown() then
        return true
    end

    -- Merchant/Vendor window
    if MerchantFrame and MerchantFrame:IsShown() then
        return true
    end

    -- Auction house (Classic)
    if AuctionFrame and AuctionFrame:IsShown() then
        return true
    end

    -- Auction house (Retail)
    if AuctionHouseFrame and AuctionHouseFrame:IsShown() then
        return true
    end

    -- Item Socketing UI
    if ItemSocketingFrame and ItemSocketingFrame:IsShown() then
        return true
    end

    return false
end

-- Build display order from classified bags
-- Returns array of {bagID, needsSpacing, isKeyring, isSoulBag, isQuiverBag}
-- bags parameter is optional, used to check cached keyring data
-- showSoulBag parameter controls whether soul bags are included (default true)
-- showQuiverBag parameter controls whether quiver/ammo bags are included (default true)
function LayoutEngine:BuildDisplayOrder(classifiedBags, showKeyring, bags, showSoulBag, showQuiverBag)
    local bagsToShow = {}

    -- Regular bags first (no spacing)
    for _, bagID in ipairs(classifiedBags.regular or {}) do
        table.insert(bagsToShow, {bagID = bagID, needsSpacing = false})
    end

    -- Reagent bags (Retail only, with spacing)
    for i, bagID in ipairs(classifiedBags.reagent or {}) do
        table.insert(bagsToShow, {bagID = bagID, needsSpacing = (i == 1), isReagentBag = true})
    end

    -- Profession bags (with spacing before first bag of each type)
    local professionTypes = {"enchant", "herb", "engineering", "mining", "gem", "leatherworking", "inscription"}
    for _, bagType in ipairs(professionTypes) do
        local typeBags = classifiedBags[bagType] or {}
        for i, bagID in ipairs(typeBags) do
            table.insert(bagsToShow, {bagID = bagID, needsSpacing = (i == 1)})
        end
    end

    -- Soul bags (only if showSoulBag is true or not specified)
    if showSoulBag ~= false then
        for i, bagID in ipairs(classifiedBags.soul or {}) do
            table.insert(bagsToShow, {bagID = bagID, needsSpacing = (i == 1), isSoulBag = true})
        end
    end

    -- Quiver/Ammo bags (Hunter only, gated by showQuiverBag toggle)
    if showQuiverBag ~= false then
        for i, bagID in ipairs(classifiedBags.quiver or {}) do
            table.insert(bagsToShow, {bagID = bagID, needsSpacing = (i == 1), isQuiverBag = true})
        end
        for i, bagID in ipairs(classifiedBags.ammo or {}) do
            table.insert(bagsToShow, {bagID = bagID, needsSpacing = (i == 1), isQuiverBag = true})
        end
    end

    -- Keyring (if shown)
    if showKeyring then
        local keyringID = Constants.KEYRING_BAG_ID
        local numKeyringSlots = 0

        -- Check cached data first, then live data
        if bags and bags[keyringID] then
            numKeyringSlots = bags[keyringID].numSlots or 0
        else
            numKeyringSlots = C_Container.GetContainerNumSlots(keyringID) or 0
        end

        if numKeyringSlots > 0 then
            table.insert(bagsToShow, {bagID = keyringID, needsSpacing = true, isKeyring = true})
        end
    end

    return bagsToShow
end

-- Collect all slots from bags in display order
-- Returns array of {bagID, slot, itemData, needsSpacing}
-- If unifiedOrder is true (for Retail Single View), collect all slots sequentially by bag ID
-- without bag type separation, which matches Blizzard's native sorted display order
function LayoutEngine:CollectAllSlots(bagsToShow, bags, isViewingCached, unifiedOrder)
    local allSlots = {}

    -- On Retail Single View, collect all non-special bags in sequential order (0, 1, 2, 3, 4)
    -- This matches how C_Container.SortBags() organizes items across all bags
    -- Special bags (reagent, keyring) are shown separately with spacing
    if unifiedOrder then
        -- Collect unique bag IDs (excluding keyring and reagent bag) and sort them
        local bagIDs = {}
        local seenBags = {}
        local keyringInfo = nil
        local reagentBagInfo = nil

        for _, bagInfo in ipairs(bagsToShow) do
            if bagInfo.isKeyring then
                keyringInfo = bagInfo  -- Save keyring for later
            elseif bagInfo.isReagentBag then
                reagentBagInfo = bagInfo  -- Save reagent bag for later
            elseif not seenBags[bagInfo.bagID] then
                seenBags[bagInfo.bagID] = true
                table.insert(bagIDs, bagInfo.bagID)
            end
        end
        table.sort(bagIDs)

        -- Collect slots in bag ID order (no section spacing)
        for _, bagID in ipairs(bagIDs) do
            local bagData = bags[bagID]
            if bagData then
                for slot = 1, bagData.numSlots do
                    table.insert(allSlots, {
                        bagID = bagID,
                        slot = slot,
                        itemData = bagData.slots[slot],
                        needsSpacing = false,
                    })
                end
            end
        end

        -- Add reagent bag with spacing (if present)
        if reagentBagInfo then
            local bagID = reagentBagInfo.bagID
            local bagData = bags[bagID]
            if bagData then
                for slot = 1, bagData.numSlots do
                    local needsSpacing = (slot == 1)
                    table.insert(allSlots, {
                        bagID = bagID,
                        slot = slot,
                        itemData = bagData.slots[slot],
                        needsSpacing = needsSpacing,
                    })
                end
            end
        end

        -- Add keyring at the end with spacing (if present)
        if keyringInfo then
            local bagID = keyringInfo.bagID
            local bagData = bags[bagID]
            if isViewingCached and bagData then
                for slot = 1, bagData.numSlots do
                    local needsSpacing = (slot == 1)
                    table.insert(allSlots, {
                        bagID = bagID,
                        slot = slot,
                        itemData = bagData.slots[slot],
                        needsSpacing = needsSpacing,
                    })
                end
            else
                local numSlots = C_Container.GetContainerNumSlots(bagID)
                if numSlots and numSlots > 0 then
                    for slot = 1, numSlots do
                        local needsSpacing = (slot == 1)
                        local itemInfo = C_Container.GetContainerItemInfo(bagID, slot)
                        local itemData = nil
                        if itemInfo then
                            local itemName, _, itemQuality, _, _, itemType, itemSubType = GetItemInfo(itemInfo.hyperlink or "")
                            itemData = {
                                bagID = bagID,
                                slot = slot,
                                link = itemInfo.hyperlink,
                                texture = itemInfo.iconFileID,
                                count = itemInfo.stackCount or 1,
                                quality = itemInfo.quality or 0,
                                name = itemName or "",
                                itemType = itemType or "",
                                itemSubType = itemSubType or "",
                                locked = itemInfo.isLocked,
                            }
                        end
                        table.insert(allSlots, {
                            bagID = bagID,
                            slot = slot,
                            itemData = itemData,
                            needsSpacing = needsSpacing,
                        })
                    end
                end
            end
        end

        return allSlots
    end

    -- Original behavior: collect in display order with bag type separation
    for _, bagInfo in ipairs(bagsToShow) do
        local bagID = bagInfo.bagID
        local bagData = bags[bagID]

        -- Handle keyring - use cached data if viewing cached character, otherwise live data
        if bagInfo.isKeyring then
            if isViewingCached and bagData then
                -- Use cached keyring data
                for slot = 1, bagData.numSlots do
                    local needsSpacing = bagInfo.needsSpacing and (slot == 1)
                    table.insert(allSlots, {
                        bagID = bagID,
                        slot = slot,
                        itemData = bagData.slots[slot],
                        needsSpacing = needsSpacing,
                    })
                end
            else
                -- Use live keyring data
                local numSlots = C_Container.GetContainerNumSlots(bagID)
                if numSlots and numSlots > 0 then
                    for slot = 1, numSlots do
                        local needsSpacing = bagInfo.needsSpacing and (slot == 1)
                        local itemInfo = C_Container.GetContainerItemInfo(bagID, slot)
                        local itemData = nil
                        if itemInfo then
                            local itemName, _, itemQuality, _, _, itemType, itemSubType = GetItemInfo(itemInfo.hyperlink or "")
                            itemData = {
                                bagID = bagID,
                                slot = slot,
                                link = itemInfo.hyperlink,
                                texture = itemInfo.iconFileID,
                                count = itemInfo.stackCount or 1,
                                quality = itemInfo.quality or 0,
                                name = itemName or "",
                                itemType = itemType or "",
                                itemSubType = itemSubType or "",
                                locked = itemInfo.isLocked,
                            }
                        end
                        table.insert(allSlots, {
                            bagID = bagID,
                            slot = slot,
                            itemData = itemData,
                            needsSpacing = needsSpacing,
                        })
                    end
                end
            end
        elseif bagData then
            for slot = 1, bagData.numSlots do
                local needsSpacing = bagInfo.needsSpacing and (slot == 1)
                table.insert(allSlots, {
                    bagID = bagID,
                    slot = slot,
                    itemData = bagData.slots[slot],
                    needsSpacing = needsSpacing,
                })
            end
        end
    end

    return allSlots
end

-- Calculate frame dimensions based on slots and settings
-- Returns frameWidth, frameHeight
function LayoutEngine:CalculateFrameSize(allSlots, settings)
    local columns = settings.columns
    local iconSize = settings.iconSize
    local spacing = settings.spacing
    local showSearchBar = settings.showSearchBar
    local showFilterChips = settings.showFilterChips
    local showFooter = settings.showFooter

    -- Calculate actual row count and section count for spacing
    -- Count rows directly to avoid overcounting with section breaks
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

    -- Account for final partial row
    if col > 0 then
        totalRows = totalRows + 1
    end
    if totalRows < 1 then totalRows = 1 end

    local contentWidth = (iconSize * columns) + (spacing * (columns - 1))
    local contentHeight = (iconSize * totalRows) + (spacing * (totalRows - 1)) + (Constants.SECTION_SPACING * sectionCount)

    local searchBarHeight = showSearchBar and ((settings.searchBarHeight or (Constants.FRAME.SEARCH_BAR_HEIGHT + ((showFilterChips and Constants.FRAME.CHIP_STRIP_HEIGHT + 1) or 0))) + 4) or 0
    local dynFooterHeight = settings.footerHeight or Constants.FRAME.FOOTER_HEIGHT
    local footerHeight = showFooter and (dynFooterHeight + Constants.FRAME.PADDING + 3) or Constants.FRAME.PADDING

    local frameWidth = math.max(contentWidth + (Constants.FRAME.PADDING * 2), Constants.FRAME.MIN_WIDTH)
    local frameHeight = math.max(
        contentHeight + (settings.headerHeight or Constants.FRAME.TITLE_HEIGHT) + searchBarHeight + footerHeight + Constants.FRAME.PADDING + 4,
        Constants.FRAME.MIN_HEIGHT
    )

    return frameWidth, frameHeight
end

-- Calculate position for each slot button
-- Returns array of {x, y} positions corresponding to allSlots indices
function LayoutEngine:CalculateButtonPositions(allSlots, settings)
    local columns = settings.columns
    local iconSize = settings.iconSize
    local spacing = settings.spacing

    local positions = {}
    local row = 0
    local col = 0
    local currentSectionOffset = 0

    for i, slotInfo in ipairs(allSlots) do
        -- Start new row for specialized bag sections with extra spacing
        if slotInfo.needsSpacing then
            if col > 0 then
                row = row + 1
                col = 0
            end
            currentSectionOffset = currentSectionOffset + Constants.SECTION_SPACING
        end

        local x = col * (iconSize + spacing)
        local y = -(row * (iconSize + spacing)) - currentSectionOffset

        positions[i] = {x = x, y = y}

        col = col + 1
        if col >= columns then
            col = 0
            row = row + 1
        end
    end

    return positions
end

-- Get section spacing constant
function LayoutEngine:GetSectionSpacing()
    return Constants.SECTION_SPACING
end

-------------------------------------------------
-- Category View Support
-------------------------------------------------

local CATEGORY_HEADER_HEIGHT = Constants.CATEGORY_UI.HEADER_HEIGHT

-- Collect items for category view (skips empty slots but counts them)
-- Returns array of {bagID, slot, itemData}, emptyCount, firstEmptySlot, soulEmptyCount, firstSoulEmptySlot
-- forceSoulVisible: if true, overrides hideSoulItems setting (used by bank view)
function LayoutEngine:CollectItemsForCategoryView(bagsToShow, bags, isViewingCached, forceSoulVisible, forceQuiverVisible)
    local items = {}
    local emptyCount = 0
    local firstEmptySlot = nil  -- {bagID, slot} of first empty slot found
    local soulEmptyCount = 0
    local firstSoulEmptySlot = nil  -- {bagID, slot} of first soul bag empty slot
    local quiverEmptyCount = 0
    local firstQuiverEmptySlot = nil  -- {bagID, slot} of first quiver/ammo bag empty slot

    -- Check if soul shard / quiver items should be hidden (category view toggles)
    -- Bank view always shows them (no toggle button in bank footer)
    local Database = ns:GetModule("Database")
    local hideSoulItems = not forceSoulVisible and Database and Database:GetSetting("hideSoulItems")
    local hideQuiverItems = not forceQuiverVisible and Database and Database:GetSetting("hideQuiverItems")

    -- Get BagClassifier for accurate bag type detection
    local BagClassifier = ns:GetModule("BagFrame.BagClassifier")

    for _, bagInfo in ipairs(bagsToShow) do
        local bagID = bagInfo.bagID
        local bagData = bags[bagID]
        -- Use bagInfo.isSoulBag if set, otherwise check via BagClassifier or bagData
        local isSoulBag = bagInfo.isSoulBag
        if isSoulBag == nil then
            if bagData and bagData.bagType then
                isSoulBag = (bagData.bagType == "soul")
            elseif BagClassifier then
                local bagType = BagClassifier:GetBagType(bagID)
                isSoulBag = (bagType == "soul")
            end
        end
        -- Quiver/ammo bag detection mirrors soul-bag detection (Hunter equivalent)
        local isQuiverBag = bagInfo.isQuiverBag
        if isQuiverBag == nil then
            if bagData and bagData.bagType then
                isQuiverBag = (bagData.bagType == "quiver" or bagData.bagType == "ammo")
            elseif BagClassifier then
                local bagType = BagClassifier:GetBagType(bagID)
                isQuiverBag = (bagType == "quiver" or bagType == "ammo")
            end
        end

        if bagInfo.isKeyring then
            if isViewingCached and bagData then
                for slot = 1, bagData.numSlots do
                    local itemData = bagData.slots[slot]
                    if itemData then
                        table.insert(items, {
                            bagID = bagID,
                            slot = slot,
                            itemData = itemData,
                        })
                    else
                        emptyCount = emptyCount + 1
                        if not firstEmptySlot then
                            firstEmptySlot = {bagID = bagID, slot = slot}
                        end
                    end
                end
            else
                local numSlots = C_Container.GetContainerNumSlots(bagID)
                if numSlots and numSlots > 0 then
                    for slot = 1, numSlots do
                        local itemInfo = C_Container.GetContainerItemInfo(bagID, slot)
                        if itemInfo then
                            local itemName, _, itemQuality, _, _, itemType, itemSubType = GetItemInfo(itemInfo.hyperlink or "")
                            local itemData = {
                                bagID = bagID,
                                slot = slot,
                                link = itemInfo.hyperlink,
                                texture = itemInfo.iconFileID,
                                count = itemInfo.stackCount or 1,
                                quality = itemInfo.quality or 0,
                                name = itemName or "",
                                itemType = itemType or "",
                                itemSubType = itemSubType or "",
                                locked = itemInfo.isLocked,
                            }
                            table.insert(items, {
                                bagID = bagID,
                                slot = slot,
                                itemData = itemData,
                            })
                        else
                            emptyCount = emptyCount + 1
                            if not firstEmptySlot then
                                firstEmptySlot = {bagID = bagID, slot = slot}
                            end
                        end
                    end
                end
            end
        elseif bagData then
            for slot = 1, bagData.numSlots do
                local itemData = bagData.slots[slot]
                if itemData then
                    -- Mark soul shards from soul bags for special display
                    if isSoulBag then
                        itemData.isInSoulBag = true
                    end
                    -- Mark arrows/bullets from quiver/ammo bags for special display
                    if isQuiverBag then
                        itemData.isInQuiverBag = true
                    end
                    -- Skip soul/quiver bag items when hidden via footer toggle (empty slots still counted below)
                    if not (isSoulBag and hideSoulItems) and not (isQuiverBag and hideQuiverItems) then
                        table.insert(items, {
                            bagID = bagID,
                            slot = slot,
                            itemData = itemData,
                            isInSoulBag = isSoulBag,
                            isInQuiverBag = isQuiverBag,
                        })
                    end
                else
                    if isSoulBag then
                        soulEmptyCount = soulEmptyCount + 1
                        if not firstSoulEmptySlot then
                            firstSoulEmptySlot = {bagID = bagID, slot = slot}
                        end
                    elseif isQuiverBag then
                        quiverEmptyCount = quiverEmptyCount + 1
                        if not firstQuiverEmptySlot then
                            firstQuiverEmptySlot = {bagID = bagID, slot = slot}
                        end
                    else
                        emptyCount = emptyCount + 1
                        if not firstEmptySlot then
                            firstEmptySlot = {bagID = bagID, slot = slot}
                        end
                    end
                end
            end
        elseif not isViewingCached then
            -- No cached bag data but not viewing cached - use live data for empty count
            local numSlots = C_Container.GetContainerNumSlots(bagID)
            if numSlots and numSlots > 0 then
                for slot = 1, numSlots do
                    local itemInfo = C_Container.GetContainerItemInfo(bagID, slot)
                    if not itemInfo then
                        if isSoulBag then
                            soulEmptyCount = soulEmptyCount + 1
                            if not firstSoulEmptySlot then
                                firstSoulEmptySlot = {bagID = bagID, slot = slot}
                            end
                        elseif isQuiverBag then
                            quiverEmptyCount = quiverEmptyCount + 1
                            if not firstQuiverEmptySlot then
                                firstQuiverEmptySlot = {bagID = bagID, slot = slot}
                            end
                        else
                            emptyCount = emptyCount + 1
                            if not firstEmptySlot then
                                firstEmptySlot = {bagID = bagID, slot = slot}
                            end
                        end
                    end
                end
            end
        end
    end

    -- When not viewing cached data, recalculate empty counts using LIVE data
    -- This ensures counts are accurate even if cache is stale
    if not isViewingCached then
        emptyCount = 0
        soulEmptyCount = 0
        quiverEmptyCount = 0
        firstEmptySlot = nil
        firstSoulEmptySlot = nil
        firstQuiverEmptySlot = nil

        -- Get BagClassifier for accurate bag type detection
        local BagClassifier = ns:GetModule("BagFrame.BagClassifier")

        for _, bagInfo in ipairs(bagsToShow) do
            local bagID = bagInfo.bagID
            -- Use bagInfo.isSoulBag if set, otherwise check via BagClassifier
            local isSoulBag = bagInfo.isSoulBag
            local isQuiverBag = bagInfo.isQuiverBag
            if (isSoulBag == nil or isQuiverBag == nil) and BagClassifier then
                local bagType = BagClassifier:GetBagType(bagID)
                if isSoulBag == nil then isSoulBag = (bagType == "soul") end
                if isQuiverBag == nil then isQuiverBag = (bagType == "quiver" or bagType == "ammo") end
            end

            if not bagInfo.isKeyring then  -- Keyring already uses live data above
                local numSlots = C_Container.GetContainerNumSlots(bagID)
                if numSlots and numSlots > 0 then
                    for slot = 1, numSlots do
                        local itemInfo = C_Container.GetContainerItemInfo(bagID, slot)
                        if not itemInfo then
                            if isSoulBag then
                                soulEmptyCount = soulEmptyCount + 1
                                if not firstSoulEmptySlot then
                                    firstSoulEmptySlot = {bagID = bagID, slot = slot}
                                end
                            elseif isQuiverBag then
                                quiverEmptyCount = quiverEmptyCount + 1
                                if not firstQuiverEmptySlot then
                                    firstQuiverEmptySlot = {bagID = bagID, slot = slot}
                                end
                            else
                                emptyCount = emptyCount + 1
                                if not firstEmptySlot then
                                    firstEmptySlot = {bagID = bagID, slot = slot}
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return items, emptyCount, firstEmptySlot, soulEmptyCount, firstSoulEmptySlot, quiverEmptyCount, firstQuiverEmptySlot
end

-- Build category sections from items
-- Returns { { categoryId, categoryName, categoryIcon, items = {} }, ... }
-- Groups with merge enabled show as single sections instead of individual categories
-- emptyCount: number of empty slots to show in "Empty" category
-- firstEmptySlot: {bagID, slot} of first empty slot for click handling
-- soulEmptyCount: number of soul bag empty slots
-- firstSoulEmptySlot: {bagID, slot} of first soul bag empty slot
-- showEmptyDropTargets: when true, append drop-target sections for empty enabled categories
function LayoutEngine:BuildCategorySections(items, isViewingCached, emptyCount, firstEmptySlot, soulEmptyCount, firstSoulEmptySlot, forceSoulVisible, showEmptyDropTargets, quiverEmptyCount, firstQuiverEmptySlot)
    local CategoryManager = ns:GetModule("CategoryManager")
    if not CategoryManager then
        return {{ categoryId = "All", categoryName = "All Items", categoryIcon = nil, items = items }}
    end

    local Database = ns:GetModule("Database")
    local mergedGroups = Database and Database:GetSetting("mergedGroups") or {}

    local categories = CategoryManager:GetCategories()
    local order = categories.order or {}

    -- Build category order index map for sorting
    local categoryOrderIndex = {}
    for i, catId in ipairs(order) do
        categoryOrderIndex[catId] = i
    end

    local sectionMap = {}
    local sections = {}
    local groupMap = {}  -- For merged groups

    for _, categoryId in ipairs(order) do
        local def = categories.definitions[categoryId]
        if def and def.enabled then
            local groupName = def.group
            local isGroupMerged = groupName and groupName ~= "" and mergedGroups[groupName]

            if isGroupMerged then
                -- This group is merged - combine categories into single section
                if groupMap[groupName] then
                    -- Add to existing group section
                    sectionMap[categoryId] = groupMap[groupName]
                else
                    -- Create new group section (use localized group name)
                    local localizedGroupName = ns.DefaultCategories:GetLocalizedGroupName(groupName)
                    local section = {
                        categoryId = "group_" .. groupName,
                        categoryName = localizedGroupName,
                        categoryIcon = def.icon,
                        items = {},
                        hideControls = def.hideControls,
                        isGroup = true,
                        group = groupName,
                    }
                    groupMap[groupName] = section
                    sectionMap[categoryId] = section
                    table.insert(sections, section)
                end
            else
                -- Category is not in a merged group - show as individual section
                -- Use localized name for built-in categories
                local displayName = def.isBuiltIn
                    and ns.DefaultCategories:GetLocalizedName(categoryId, def.name)
                    or def.name
                local section = {
                    categoryId = categoryId,
                    categoryName = displayName,
                    categoryIcon = def.icon,
                    items = {},
                    hideControls = def.hideControls,
                    group = groupName,  -- Include group for layout calculations
                }
                sectionMap[categoryId] = section
                table.insert(sections, section)
            end
        end
    end

    -- Categorize each item and store category order index for merged group sorting
    local soulCategoryEnabled = sectionMap["Soul"] ~= nil
    local quiverCategoryEnabled = sectionMap["Quiver"] ~= nil
    local hideSoulItems = not forceSoulVisible and Database and Database:GetSetting("hideSoulItems")
    for _, item in ipairs(items) do
        -- Quiver/ammo bag items go to the Quiver section when that category is enabled
        if quiverCategoryEnabled and item.isInQuiverBag then
            local quiverSection = sectionMap["Quiver"]
            if quiverSection then
                item.categoryOrderIndex = categoryOrderIndex["Quiver"] or 999
                table.insert(quiverSection.items, item)
            end
        -- Soul bag items go to the Soul section when that category is enabled
        elseif soulCategoryEnabled and item.isInSoulBag then
            -- Add soul bag items to the Soul section (unless hidden by footer toggle)
            if not hideSoulItems then
                local soulSection = sectionMap["Soul"]
                if soulSection then
                    item.categoryOrderIndex = categoryOrderIndex["Soul"] or 999
                    table.insert(soulSection.items, item)
                end
            end
        else
            local categoryId = CategoryManager:CategorizeItem(item.itemData, item.bagID, item.slot, isViewingCached)
            local section = sectionMap[categoryId]
            if section then
                -- Store category order index for sorting within merged groups
                item.categoryOrderIndex = categoryOrderIndex[categoryId] or 999
                table.insert(section.items, item)
            elseif sectionMap["Miscellaneous"] then
                item.categoryOrderIndex = categoryOrderIndex["Miscellaneous"] or 999
                table.insert(sectionMap["Miscellaneous"].items, item)
            end
        end
    end

    -- Add pseudo-item to "Empty" category if there are empty slots
    emptyCount = emptyCount or 0
    if emptyCount > 0 and sectionMap["Empty"] and firstEmptySlot then
        local emptySection = sectionMap["Empty"]
        -- Create a pseudo-item representing empty slots
        -- Use real bagID/slot so the button template's click handler works
        local emptyItem = {
            bagID = firstEmptySlot.bagID,
            slot = firstEmptySlot.slot,
            itemData = {
                bagID = firstEmptySlot.bagID,
                slot = firstEmptySlot.slot,
                isEmptySlots = true,
                emptyCount = emptyCount,
                texture = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Bag",
                count = emptyCount,
                name = "Empty Slots",
            },
        }
        table.insert(emptySection.items, emptyItem)
    end

    -- Add pseudo-item to "Soul" category if there are soul bag empty slots
    soulEmptyCount = soulEmptyCount or 0
    if soulEmptyCount > 0 and sectionMap["Soul"] and firstSoulEmptySlot then
        local soulSection = sectionMap["Soul"]
        -- Create a pseudo-item representing soul bag empty slots
        local soulItem = {
            bagID = firstSoulEmptySlot.bagID,
            slot = firstSoulEmptySlot.slot,
            itemData = {
                bagID = firstSoulEmptySlot.bagID,
                slot = firstSoulEmptySlot.slot,
                isEmptySlots = true,
                isSoulSlots = true,
                emptyCount = soulEmptyCount,
                texture = "Interface\\AddOns\\GudaBags\\Assets\\soul.tga",
                count = soulEmptyCount,
                name = "Soul Bag Slots",
            },
        }
        table.insert(soulSection.items, soulItem)
    end

    -- Add pseudo-item to "Quiver" category if there are quiver/ammo bag empty slots
    quiverEmptyCount = quiverEmptyCount or 0
    if quiverEmptyCount > 0 and sectionMap["Quiver"] and firstQuiverEmptySlot then
        local quiverSection = sectionMap["Quiver"]
        -- Create a pseudo-item representing quiver/ammo bag empty slots
        local quiverItem = {
            bagID = firstQuiverEmptySlot.bagID,
            slot = firstQuiverEmptySlot.slot,
            itemData = {
                bagID = firstQuiverEmptySlot.bagID,
                slot = firstQuiverEmptySlot.slot,
                isEmptySlots = true,
                isQuiverSlots = true,
                emptyCount = quiverEmptyCount,
                texture = "Interface\\AddOns\\GudaBags\\Assets\\quiver.tga",
                count = quiverEmptyCount,
                name = "Quiver/Ammo Slots",
            },
        }
        table.insert(quiverSection.items, quiverItem)
    end

    -- Group identical items into single slots with combined count (if setting enabled)
    -- Skip grouping when interaction windows are open (bank, trade, mail, etc.)
    -- so users can interact with individual stacks
    local Database = ns:GetModule("Database")
    local groupIdenticalItems = Database and Database:GetSetting("groupIdenticalItems")
    local shouldGroup = groupIdenticalItems and not IsInteractionWindowOpen()
    -- A/B suspect toggle: disable identical-item grouping to measure its cost.
    if ns.suspectDisabled and ns.suspectDisabled.grouping then
        shouldGroup = false
    end
    if shouldGroup then
        for _, section in ipairs(sections) do
            local itemsByID = {}  -- { [itemID] = { items } }
            local itemOrder = {}  -- Track order of first occurrence

            for _, item in ipairs(section.items) do
                local itemID = item.itemData and item.itemData.itemID
                if itemID then
                    if not itemsByID[itemID] then
                        itemsByID[itemID] = {}
                        table.insert(itemOrder, itemID)
                    end
                    table.insert(itemsByID[itemID], item)
                else
                    -- Items without itemID (like pseudo-items) go through as-is
                    if not itemsByID["_noID"] then
                        itemsByID["_noID"] = {}
                        table.insert(itemOrder, "_noID")
                    end
                    table.insert(itemsByID["_noID"], item)
                end
            end

            -- Rebuild section items with grouped items
            local newItems = {}
            for _, itemID in ipairs(itemOrder) do
                local items = itemsByID[itemID]
                if itemID == "_noID" then
                    -- Pass through items without itemID unchanged
                    for _, item in ipairs(items) do
                        table.insert(newItems, item)
                    end
                elseif #items == 1 then
                    -- Single item, no grouping needed
                    table.insert(newItems, items[1])
                else
                    -- Multiple identical items - consolidate into one
                    local firstItem = items[1]
                    local totalCount = 0
                    local locations = {}

                    for _, item in ipairs(items) do
                        totalCount = totalCount + (item.itemData.count or 1)
                        table.insert(locations, {
                            bagID = item.bagID,
                            slot = item.slot,
                        })
                    end

                    local consolidatedItem = {
                        bagID = firstItem.bagID,
                        slot = firstItem.slot,
                        categoryOrderIndex = firstItem.categoryOrderIndex,
                        itemData = {
                            bagID = firstItem.bagID,
                            slot = firstItem.slot,
                            itemID = itemID,
                            link = firstItem.itemData.link,
                            texture = firstItem.itemData.texture,
                            count = totalCount,
                            quality = firstItem.itemData.quality,
                            name = firstItem.itemData.name,
                            itemType = firstItem.itemData.itemType,
                            itemSubType = firstItem.itemData.itemSubType,
                            isGroupedStack = true,
                            groupedLocations = locations,
                        },
                    }
                    table.insert(newItems, consolidatedItem)
                end
            end
            section.items = newItems
        end
    end

    -- Remove empty sections (but keep empty custom categories so users can see them)
    local nonEmptySections = {}
    for _, section in ipairs(sections) do
        local def = categories.definitions[section.categoryId]
        local isCustomCategory = def and not def.isBuiltIn and not section.isGroup
        -- Also keep Empty/Soul/Quiver category if it has items (empty slots)
        local isEmptyCategory = section.categoryId == "Empty" and #section.items > 0
        local isSoulCategory = section.categoryId == "Soul" and #section.items > 0
        local isQuiverCategory = section.categoryId == "Quiver" and #section.items > 0
        if #section.items > 0 or isCustomCategory or isEmptyCategory or isSoulCategory or isQuiverCategory then
            table.insert(nonEmptySections, section)
        end
    end

    -- Append drop-target sections for empty categories when dragging an item
    if showEmptyDropTargets then
        -- Build set of categoryIds that already have items
        local populatedCategories = {}
        for _, section in ipairs(nonEmptySections) do
            if #section.items > 0 then
                populatedCategories[section.categoryId] = true
            end
            -- For merged groups, mark all member categories as populated
            if section.isGroup and section.group and #section.items > 0 then
                for _, catId in ipairs(order) do
                    local catDef = categories.definitions[catId]
                    if catDef and catDef.group == section.group then
                        populatedCategories[catId] = true
                    end
                end
            end
        end

        for _, categoryId in ipairs(order) do
            local def = categories.definitions[categoryId]
            if def and def.enabled
                and not populatedCategories[categoryId]
                and not def.hideControls
                and not def.isFallback
                and not def.isEquipSet
                and categoryId ~= "Recent"
                and categoryId ~= "Home"
                and categoryId ~= "Empty"
                and categoryId ~= "Soul"
                and categoryId ~= "Quiver"
                and categoryId ~= "Keyring"
                and categoryId ~= "Soul Bag"
                and categoryId ~= "Quiver Bag" then

                local displayName = def.isBuiltIn
                    and ns.DefaultCategories:GetLocalizedName(categoryId, def.name)
                    or def.name

                local dropTargetSection = {
                    categoryId = categoryId,
                    categoryName = displayName,
                    categoryIcon = def.icon,
                    items = {{
                        bagID = 0, slot = 0,
                        itemData = {
                            bagID = 0, slot = 0,
                            isDropTarget = true,
                            categoryId = categoryId,
                            texture = def.icon or "Interface\\AddOns\\GudaBags\\Assets\\plus.tga",
                            count = 0,
                            name = displayName,
                        },
                    }},
                    hideControls = true,
                    isDropTarget = true,
                }
                table.insert(nonEmptySections, dropTargetSection)
            end
        end
    end

    return nonEmptySections
end

-- Sort key cache for category view (avoid repeated GetItemInfo calls)
local categorySortKeyCache = {}

local function GetCategorySortKey(itemData)
    local itemID = itemData.itemID
    if not itemID then return nil end

    -- Check cache first
    if categorySortKeyCache[itemID] then
        return categorySortKeyCache[itemID]
    end

    -- Fetch classID, subClassID, and itemLevel from GetItemInfo
    local _, _, _, itemLevel, _, itemType, itemSubType, _, _, _, _, classID, subClassID = GetItemInfo(itemID)
    -- 3.3.5a's GetItemInfo stops at position 11; rebuild the class ids so the
    -- category-view sort comparator doesn't see Miscellaneous for everything.
    if classID == nil and ns.Compat then
        classID, subClassID = ns.Compat.ResolveItemClassIDs(itemType, itemSubType, itemID)
    end

    local sortKey = {
        classID = classID or 15,  -- Default to Miscellaneous
        subClassID = subClassID or 0,
        itemLevel = itemLevel or 0,
    }

    categorySortKeyCache[itemID] = sortKey
    return sortKey
end

-- Clear sort key cache (call on login or when needed)
function LayoutEngine:ClearSortKeyCache()
    wipe(categorySortKeyCache)
end

-- Sort items within a category section
-- For merged groups, items are sorted by category order first to maintain category grouping
function LayoutEngine:SortCategoryItems(items, isMergedGroup)
    local Database = ns:GetModule("Database")
    local sortPriority = Database:GetSetting("sortPriority") or "default"

    table.sort(items, function(a, b)
        -- For merged groups, sort by category order first
        if isMergedGroup then
            local aOrder = a.categoryOrderIndex or 999
            local bOrder = b.categoryOrderIndex or 999
            if aOrder ~= bOrder then
                return aOrder < bOrder
            end
        end

        local aData = a.itemData
        local bData = b.itemData
        local aQuality = aData.quality or 0
        local bQuality = bData.quality or 0
        local aKey = GetCategorySortKey(aData)
        local bKey = GetCategorySortKey(bData)
        local aLevel = aKey and aKey.itemLevel or 0
        local bLevel = bKey and bKey.itemLevel or 0

        if sortPriority == "ilvl" then
            -- Item level first (higher first)
            if aLevel ~= bLevel then return aLevel > bLevel end
            if aQuality ~= bQuality then return aQuality > bQuality end
        elseif sortPriority == "quality" then
            -- Quality first (higher first), then item level
            if aQuality ~= bQuality then return aQuality > bQuality end
            if aLevel ~= bLevel then return aLevel > bLevel end
        else
            -- Default: quality first, then class/subclass, then ilvl
            if aQuality ~= bQuality then return aQuality > bQuality end
        end

        if aKey and bKey then
            if aKey.classID ~= bKey.classID then
                return aKey.classID < bKey.classID
            end
            if aKey.subClassID ~= bKey.subClassID then
                return aKey.subClassID < bKey.subClassID
            end
            if sortPriority == "default" then
                if aLevel ~= bLevel then return aLevel > bLevel end
            end
        end

        -- Item type (fallback for items without classID)
        local aType = aData.itemType or ""
        local bType = bData.itemType or ""
        if aType ~= bType then
            return aType < bType
        end

        -- Item subtype
        local aSubType = aData.itemSubType or ""
        local bSubType = bData.itemSubType or ""
        if aSubType ~= bSubType then
            return aSubType < bSubType
        end

        -- Item ID
        local aID = aData.itemID or 0
        local bID = bData.itemID or 0
        if aID ~= bID then
            return aID < bID
        end

        -- Name
        local aName = aData.name or ""
        local bName = bData.name or ""
        if aName ~= bName then
            return aName < bName
        end

        -- Stack count (higher stacks first)
        return (aData.count or 1) > (bData.count or 1)
    end)
end

-- Calculate gap between category blocks based on icon size
local function GetCategoryBlockGap(iconSize)
    if iconSize < Constants.CATEGORY_ICON_SIZE_THRESHOLD then
        return Constants.CATEGORY_GAP_SMALL_ICONS
    else
        return Constants.CATEGORY_GAP_LARGE_ICONS
    end
end

-- Shared layout iteration for both FrameSize and Positions
-- Calls visitor(section, blockCols, blockRows, blockWidth, blockHeight, x, y) for each block
local function IterateCategoryLayout(sections, settings, visitor)
    local columns = settings.columns
    local iconSize = settings.iconSize
    local spacing = settings.spacing
    local blockGap = GetCategoryBlockGap(iconSize)
    local totalWidth = (iconSize * columns) + (spacing * (columns - 1))

    local currentX = 0
    local currentY = 0
    local rowMaxHeight = 0
    local lastGroup = nil

    for _, section in ipairs(sections) do
        if #section.items > 0 then
            if section.group ~= lastGroup and currentX > 0 then
                currentX = 0
                currentY = currentY + rowMaxHeight
                rowMaxHeight = 0
            end
            lastGroup = section.group

            local blockCols = math.min(#section.items, columns)
            local blockRows = math.ceil(#section.items / columns)
            local blockWidth = (blockCols * iconSize) + (math.max(0, blockCols - 1) * spacing)
            local blockHeight = CATEGORY_HEADER_HEIGHT + (blockRows * iconSize) + (math.max(0, blockRows - 1) * spacing) + 5

            if currentX > 0 and currentX + blockWidth > totalWidth then
                currentX = 0
                currentY = currentY + rowMaxHeight
                rowMaxHeight = 0
            end

            visitor(section, blockCols, blockRows, blockWidth, blockHeight, currentX, currentY)

            if blockHeight > rowMaxHeight then rowMaxHeight = blockHeight end
            currentX = currentX + blockWidth + blockGap
        end
    end

    return currentY + rowMaxHeight
end

-- Calculate frame size for category view
function LayoutEngine:CalculateCategoryFrameSize(sections, settings)
    local showSearchBar = settings.showSearchBar
    local showFilterChips = settings.showFilterChips
    local showFooter = settings.showFooter
    local columns = settings.columns
    local iconSize = settings.iconSize
    local spacing = settings.spacing

    local contentHeight = IterateCategoryLayout(sections, settings, function() end)
    if contentHeight < iconSize then contentHeight = iconSize end

    local totalWidth = (iconSize * columns) + (spacing * (columns - 1))
    local searchBarHeight = showSearchBar and ((settings.searchBarHeight or (Constants.FRAME.SEARCH_BAR_HEIGHT + ((showFilterChips and Constants.FRAME.CHIP_STRIP_HEIGHT + 1) or 0))) + 4) or 0
    local dynFooterHeight = settings.footerHeight or Constants.FRAME.FOOTER_HEIGHT
    local footerHeight = showFooter and (dynFooterHeight + Constants.FRAME.PADDING + 3) or Constants.FRAME.PADDING

    local frameWidth = math.max(totalWidth + (Constants.FRAME.PADDING * 2), Constants.FRAME.MIN_WIDTH)
    local frameHeight = math.max(
        contentHeight + (settings.headerHeight or Constants.FRAME.TITLE_HEIGHT) + searchBarHeight + footerHeight + Constants.FRAME.PADDING + 4,
        Constants.FRAME.MIN_HEIGHT
    )

    return frameWidth, frameHeight
end

-- Calculate positions for category view
-- Returns { headers = { {section, x, y, width} }, items = { {item, x, y} } }
function LayoutEngine:CalculateCategoryPositions(sections, settings)
    local iconSize = settings.iconSize
    local spacing = settings.spacing

    local result = {
        headers = {},
        items = {},
    }

    local sortSelf = self
    IterateCategoryLayout(sections, settings, function(section, blockCols, blockRows, blockWidth, blockHeight, x, y)
        sortSelf:SortCategoryItems(section.items, section.isGroup)

        table.insert(result.headers, {
            section = section,
            x = x,
            y = -y,
            width = blockWidth,
        })

        local itemStartY = y + CATEGORY_HEADER_HEIGHT
        local col = 0
        local row = 0
        for _, item in ipairs(section.items) do
            table.insert(result.items, {
                item = item,
                x = x + (col * (iconSize + spacing)),
                y = -(itemStartY + (row * (iconSize + spacing))),
                categoryId = section.categoryId,
            })

            col = col + 1
            if col >= settings.columns then
                col = 0
                row = row + 1
            end
        end
    end)

    return result
end

function LayoutEngine:GetCategoryHeaderHeight()
    return CATEGORY_HEADER_HEIGHT
end

-------------------------------------------------
-- Split View Support
-------------------------------------------------

local SPLIT = Constants.SPLIT_VIEW

-- Get display info (name, icon) for a bag
function LayoutEngine:GetBagDisplayInfo(bagID, bagData, isViewingCached)
    local L = ns.L
    local name, icon

    -- Primary bags with known identities
    if bagID == Constants.PLAYER_BAG_MIN then
        name = L["BAG_NAME_BACKPACK"]
        icon = 130716 -- Interface\\Icons\\INV_Misc_Bag_07_Green (backpack)
    elseif bagID == Constants.BANK_MAIN_BAG then
        name = L["BAG_NAME_BANK"]
        icon = 130716
    elseif bagID == Constants.KEYRING_BAG_ID then
        name = L["BAG_NAME_KEYRING"]
        icon = 134237 -- Interface\\Icons\\INV_Misc_Key_04
    elseif Constants.REAGENT_BAG and bagID == Constants.REAGENT_BAG then
        name = L["BAG_NAME_REAGENT_BAG"]
        icon = 4548860 -- Reagent bag icon
    else
        -- Equipped bag - get info from containerItemID
        local containerItemID = bagData and bagData.containerItemID
        if containerItemID then
            local itemName, _, _, _, _, _, _, _, _, itemIcon = GetItemInfo(containerItemID)
            name = itemName
            icon = itemIcon or (C_Item.GetItemIconByID and C_Item.GetItemIconByID(containerItemID))
        end

        -- Fallback: try inventory slot for live bags
        if not name and not isViewingCached then
            local invSlot = nil
            if (bagID >= 1 and bagID <= Constants.PLAYER_BAG_MAX) or
               (bagID >= Constants.BANK_BAG_MIN and bagID <= Constants.BANK_BAG_MAX) then
                invSlot = C_Container.ContainerIDToInventoryID(bagID)
            end
            if invSlot then
                local itemID = GetInventoryItemID("player", invSlot)
                if itemID then
                    local itemName, _, _, _, _, _, _, _, _, itemIcon = GetItemInfo(itemID)
                    name = itemName
                    icon = itemIcon
                end
            end
        end

        -- Final fallback
        if not name then
            name = string.format("Bag %d", bagID)
        end
    end

    return { name = name, icon = icon }
end

-- Classify bags for split view into primary (full-width top), regular (multi-column), special (full-width bottom)
local function ClassifyBagsForSplitView(bagsToShow, bags, isViewingCached, settings)
    local BagClassifier = ns:GetModule("BagFrame.BagClassifier")
    local Database = ns:GetModule("Database")
    local fullWidthBackpack = Database:GetSetting("splitFullWidthBackpack") ~= false
    local fullWidthReagent = Database:GetSetting("splitFullWidthReagent") ~= false
    local fullWidthKeyring = Database:GetSetting("splitFullWidthKeyring") ~= false

    local primary = {}   -- Full-width at top (backpack, main bank)
    local regular = {}   -- Multi-column grid
    local special = {}   -- Full-width at bottom (keyring, reagent, soul, quiver, ammo, profession bags)

    for _, bagInfo in ipairs(bagsToShow) do
        local bagID = bagInfo.bagID
        local bagData = bags[bagID]

        -- Skip bags with no slots
        if bagData and bagData.numSlots and bagData.numSlots > 0 then
            if bagID == Constants.PLAYER_BAG_MIN or bagID == Constants.BANK_MAIN_BAG then
                if fullWidthBackpack then
                    table.insert(primary, bagInfo)
                else
                    table.insert(regular, bagInfo)
                end
            elseif bagInfo.isReagentBag then
                if fullWidthReagent then
                    table.insert(special, bagInfo)
                else
                    table.insert(regular, bagInfo)
                end
            elseif bagInfo.isKeyring then
                if fullWidthKeyring then
                    table.insert(special, bagInfo)
                else
                    table.insert(regular, bagInfo)
                end
            elseif bagInfo.isSoulBag then
                table.insert(special, bagInfo)
            else
                -- Check bag type for profession/quiver/ammo bags
                local bagType = "regular"
                if BagClassifier then
                    bagType = BagClassifier:GetBagTypeForBag(bagID, bagData, isViewingCached)
                end
                if bagType ~= "regular" then
                    table.insert(special, bagInfo)
                else
                    table.insert(regular, bagInfo)
                end
            end
        elseif not bagData and not isViewingCached then
            -- Live bag with no data yet - check if it has slots
            local numSlots = C_Container.GetContainerNumSlots(bagID)
            if numSlots and numSlots > 0 then
                if bagID == Constants.PLAYER_BAG_MIN or bagID == Constants.BANK_MAIN_BAG then
                    if fullWidthBackpack then
                        table.insert(primary, bagInfo)
                    else
                        table.insert(regular, bagInfo)
                    end
                else
                    table.insert(regular, bagInfo)
                end
            end
        end
    end

    return primary, regular, special
end

-- Build split view layout
-- Returns { sections = { {bagInfo, bagID, displayInfo, columns, rows, x, y, headerY, slotsStartY, isFullWidth} }, contentWidth, contentHeight }
function LayoutEngine:BuildSplitViewLayout(bagsToShow, bags, settings, isViewingCached)
    local iconSize = settings.iconSize
    local spacing = settings.spacing
    local columns = settings.columns

    local primary, regular, special = ClassifyBagsForSplitView(bagsToShow, bags, isViewingCached, settings)

    local splitColumns = settings.splitColumns or 2
    local contentWidth = (iconSize * columns) + (spacing * (columns - 1))
    local blockColumns = math.floor(columns / splitColumns)
    local blockWidth = (iconSize * blockColumns) + (spacing * math.max(0, blockColumns - 1))
    local blockGap = (contentWidth - (blockWidth * splitColumns)) / math.max(1, splitColumns - 1)
    if blockGap < SPLIT.BLOCK_GAP then
        blockGap = SPLIT.BLOCK_GAP
        -- Recalculate contentWidth so blocks + gaps fit with proper padding
        contentWidth = (blockWidth * splitColumns) + (blockGap * math.max(0, splitColumns - 1))
    end

    local sections = {}
    local currentY = 0

    -- Helper: add a full-width section
    local function AddFullWidthSection(bagInfo)
        local bagID = bagInfo.bagID
        local bagData = bags[bagID]
        local numSlots = bagData and bagData.numSlots or (not isViewingCached and C_Container.GetContainerNumSlots(bagID) or 0)
        if numSlots <= 0 then return end

        local displayInfo = self:GetBagDisplayInfo(bagID, bagData, isViewingCached)
        local rows = math.ceil(numSlots / columns)
        local sectionHeight = SPLIT.HEADER_HEIGHT + (rows * (iconSize + spacing))

        table.insert(sections, {
            bagInfo = bagInfo,
            bagID = bagID,
            displayInfo = displayInfo,
            columns = columns,
            rows = rows,
            numSlots = numSlots,
            x = 0,
            y = currentY,
            headerY = currentY,
            slotsStartY = currentY - SPLIT.HEADER_HEIGHT,
            isFullWidth = true,
            width = contentWidth,
        })

        currentY = currentY - sectionHeight - SPLIT.BLOCK_SPACING
    end

    -- Primary bags (full-width at top)
    for _, bagInfo in ipairs(primary) do
        AddFullWidthSection(bagInfo)
    end

    -- Regular bags (multi-column grid)
    local col = 0
    local rowStartY = currentY
    local rowMaxHeight = 0

    for _, bagInfo in ipairs(regular) do
        local bagID = bagInfo.bagID
        local bagData = bags[bagID]
        local numSlots = bagData and bagData.numSlots or (not isViewingCached and C_Container.GetContainerNumSlots(bagID) or 0)
        if numSlots > 0 then
            local displayInfo = self:GetBagDisplayInfo(bagID, bagData, isViewingCached)
            local rows = math.ceil(numSlots / blockColumns)
            local blockHeight = SPLIT.HEADER_HEIGHT + (rows * (iconSize + spacing))
            local x = col * (blockWidth + blockGap)

            table.insert(sections, {
                bagInfo = bagInfo,
                bagID = bagID,
                displayInfo = displayInfo,
                columns = blockColumns,
                rows = rows,
                numSlots = numSlots,
                x = x,
                y = rowStartY,
                headerY = rowStartY,
                slotsStartY = rowStartY - SPLIT.HEADER_HEIGHT,
                isFullWidth = false,
                width = blockWidth,
            })

            if blockHeight > rowMaxHeight then
                rowMaxHeight = blockHeight
            end

            col = col + 1
            if col >= splitColumns then
                col = 0
                rowStartY = rowStartY - rowMaxHeight - SPLIT.BLOCK_SPACING
                rowMaxHeight = 0
            end
        end
    end

    -- Complete the last partial row of regular bags
    if col > 0 then
        rowStartY = rowStartY - rowMaxHeight - SPLIT.BLOCK_SPACING
    end
    currentY = rowStartY

    -- Special bags (full-width at bottom)
    for _, bagInfo in ipairs(special) do
        AddFullWidthSection(bagInfo)
    end

    local containerHeight = -currentY
    if containerHeight < 1 then containerHeight = 1 end

    return {
        sections = sections,
        contentWidth = contentWidth,
        contentHeight = containerHeight,
    }
end

-- Calculate frame size for split view
function LayoutEngine:CalculateSplitFrameSize(layout, settings)
    local showSearchBar = settings.showSearchBar
    local showFilterChips = settings.showFilterChips
    local showFooter = settings.showFooter

    local searchBarHeight = showSearchBar and ((settings.searchBarHeight or (Constants.FRAME.SEARCH_BAR_HEIGHT + ((showFilterChips and Constants.FRAME.CHIP_STRIP_HEIGHT + 1) or 0))) + 4) or 0
    local dynFooterHeight = settings.footerHeight or Constants.FRAME.FOOTER_HEIGHT
    local footerHeight = showFooter and (dynFooterHeight + Constants.FRAME.PADDING + 3) or Constants.FRAME.PADDING

    local frameWidth = math.max(layout.contentWidth + (Constants.FRAME.PADDING * 2), Constants.FRAME.MIN_WIDTH)
    local frameHeight = math.max(
        layout.contentHeight + (settings.headerHeight or Constants.FRAME.TITLE_HEIGHT) + searchBarHeight + footerHeight + Constants.FRAME.PADDING + 4,
        Constants.FRAME.MIN_HEIGHT
    )

    return frameWidth, frameHeight
end
