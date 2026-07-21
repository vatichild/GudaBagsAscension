local addonName, ns = ...

local CategoryDropIndicator = {}
ns:RegisterModule("CategoryDropIndicator", CategoryDropIndicator)

local Constants = ns.Constants

-------------------------------------------------
-- State
-------------------------------------------------

local indicator = nil
local currentCategoryId = nil
local currentHoveredButton = nil
local currentContainer = nil
local currentCursorSource = nil  -- Track cursor source when indicator appears
local dropCooldown = false  -- Prevents immediate re-show after a drop

-------------------------------------------------
-- Create Indicator (square, same size as icon, above hovered item)
-------------------------------------------------

local function CreateIndicator()
    if indicator then return indicator end

    -- Create a square indicator (same size as icon) above the hovered item
    local frame = CreateFrame("Frame", "GudaBagsCategoryDropIndicator", UIParent)
    frame:SetSize(36, 36)  -- Will be resized to match icon
    frame:SetFrameStrata("HIGH")
    frame:SetFrameLevel(100)

    -- Slot background texture (same as empty bag slot, with green tint)
    local slotBg = frame:CreateTexture(nil, "BACKGROUND")
    slotBg:SetPoint("TOPLEFT", frame, "TOPLEFT", -9, 9)
    slotBg:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 9, -9)
    slotBg:SetTexture("Interface\\Buttons\\UI-EmptySlot")
    slotBg:SetVertexColor(0.4, 0.8, 0.4, 0.9)  -- Green tint
    frame.slotBg = slotBg

    -- Plus icon centered (using texture)
    local plus = frame:CreateTexture(nil, "OVERLAY")
    plus:SetPoint("CENTER", frame, "CENTER", 0, 0)
    plus:SetTexture("Interface\\AddOns\\GudaBags\\Assets\\plus.tga")
    plus:SetSize(20, 20)  -- Will be resized based on icon size
    frame.plus = plus

    -- Make it clickable for dropping items
    frame:EnableMouse(true)

    frame:SetScript("OnMouseDown", function(self, button)
        ns:Debug("Indicator OnMouseDown:", button)
        if button == "LeftButton" then
            local success, err = pcall(function()
                CategoryDropIndicator:HandleDrop()
            end)
            if not success then
                ns:Debug("HandleDrop error:", err)
            end
        end
    end)

    frame:SetScript("OnReceiveDrag", function(self)
        ns:Debug("Indicator OnReceiveDrag")
        local success, err = pcall(function()
            CategoryDropIndicator:HandleDrop()
        end)
        if not success then
            ns:Debug("HandleDrop error:", err)
        end
    end)

    -- Show tooltip when hovering over the indicator
    frame:SetScript("OnEnter", function(self)
        if currentCategoryId then
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText("Add item to this category", 1, 1, 1)
            GameTooltip:AddLine("Drop here to permanently assign", 0.7, 0.7, 0.7)
            GameTooltip:AddLine("this item to \"" .. tostring(currentCategoryId) .. "\"", 0.5, 1, 0.5)
            GameTooltip:Show()
        end
    end)

    frame:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
        -- Hide when leaving the indicator (if not over an item button)
        C_Timer.After(0.05, function()
            if not CategoryDropIndicator:IsOverValidButton() then
                CategoryDropIndicator:Hide()
            end
        end)
    end)

    frame:Hide()
    indicator = frame
    return frame
end



-------------------------------------------------
-- Public API
-------------------------------------------------

function CategoryDropIndicator:Show(hoveredButton)
    if not hoveredButton or not hoveredButton.containerFrame then
        return
    end

    local categoryId = hoveredButton.categoryId
    if not categoryId or categoryId == "Empty" or categoryId == "Home" or categoryId == "Recent" or categoryId == "Soul" or categoryId == "Quiver" then
        return
    end

    -- Need layout coordinates
    if not hoveredButton.layoutX or not hoveredButton.layoutY then
        return
    end

    local ind = CreateIndicator()
    local container = hoveredButton.containerFrame
    local iconSize = hoveredButton.iconSize or 36

    -- Size the indicator to match icon size
    ind:SetSize(iconSize, iconSize)

    -- Update plus icon size based on icon size (60% of icon size)
    if ind.plus then
        local plusSize = math.max(16, iconSize * 0.6)
        ind.plus:SetSize(plusSize, plusSize)
    end

    -- Parent to UIParent to avoid scroll frame clipping
    ind:SetParent(UIParent)
    ind:SetFrameStrata("FULLSCREEN_DIALOG")
    ind:SetFrameLevel(500)

    -- Position indicator BELOW the hovered item using screen coordinates
    -- This avoids overlap with tooltips which appear above/right of items
    local buttonLeft, buttonBottom
    if hoveredButton.wrapper then
        buttonLeft = hoveredButton.wrapper:GetLeft()
        buttonBottom = hoveredButton.wrapper:GetBottom()
    else
        buttonLeft = hoveredButton:GetLeft()
        buttonBottom = hoveredButton:GetBottom()
    end

    local barGap = 2
    ind:ClearAllPoints()
    if buttonLeft and buttonBottom then
        ind:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", buttonLeft, buttonBottom - barGap)
    end

    currentCategoryId = categoryId
    currentHoveredButton = hoveredButton
    currentContainer = container
    -- Capture cursor source NOW while item is being dragged (more reliable than checking at drop time)
    currentCursorSource = self:GetCursorItemSource()
    ns:Debug("Show: captured cursorSource=", currentCursorSource)
    ind:Show()
end

function CategoryDropIndicator:Hide(fromDrop)
    if indicator then
        indicator:Hide()
        indicator:SetParent(UIParent)
    end

    currentCategoryId = nil
    currentHoveredButton = nil
    currentContainer = nil
    currentCursorSource = nil

    -- Set cooldown after a drop to prevent immediate re-show
    if fromDrop then
        dropCooldown = true
        C_Timer.After(0.2, function()
            dropCooldown = false
        end)
    end
end

function CategoryDropIndicator:IsShown()
    return indicator and indicator:IsShown()
end

function CategoryDropIndicator:GetCategoryId()
    return currentCategoryId
end

function CategoryDropIndicator:GetHoveredButton()
    return currentHoveredButton
end

-- Check if mouse is over a valid item button or the indicator itself
function CategoryDropIndicator:IsOverValidButton()
    if indicator and indicator:IsMouseOver() then
        return true
    end
    if currentHoveredButton and currentHoveredButton:IsMouseOver() then
        return true
    end
    return false
end

-- Called when hovering over an item button while dragging
function CategoryDropIndicator:OnItemButtonEnter(button)
    if dropCooldown then return end  -- Don't show during cooldown after drop
    if not self:CursorHasItem() then return end
    if not button.categoryId or button.categoryId == "Empty" or button.categoryId == "Home" or button.categoryId == "Recent" or button.categoryId == "Soul" or button.categoryId == "Quiver" then return end

    -- Don't show indicator if dragged item is already in this category
    if self:IsDraggedItemInCategory(button.categoryId) then return end

    self:Show(button)
end

-- Called when cursor moves within the item button (to update position)
function CategoryDropIndicator:OnItemButtonUpdate(button)
    if not self:CursorHasItem() then
        self:Hide()
        return
    end
    if not button.categoryId or button.categoryId == "Empty" or button.categoryId == "Home" or button.categoryId == "Recent" or button.categoryId == "Soul" or button.categoryId == "Quiver" then return end

    -- Don't show indicator if dragged item is already in this category
    if self:IsDraggedItemInCategory(button.categoryId) then
        self:Hide()
        return
    end

    -- Don't update if cursor is over the indicator itself
    if indicator and indicator:IsMouseOver() then
        return
    end

    -- Only update if button changed
    if currentHoveredButton == button then
        return
    end

    self:Show(button)
end

-- Called when leaving an item button
function CategoryDropIndicator:OnItemButtonLeave()
    -- Delay hide to check if cursor moved to indicator
    C_Timer.After(0.05, function()
        if not self:IsOverValidButton() then
            self:Hide()
        end
    end)
end

function CategoryDropIndicator:HandleDrop()
    if InCombatLockdown() then return false end
    ns:Debug("HandleDrop called")
    local infoType, itemID, itemLink = GetCursorInfo()

    ns:Debug("HandleDrop: infoType=", infoType, "itemID=", itemID)
    if infoType ~= "item" or not itemID then
        self:Hide(true)
        return false
    end

    if not currentCategoryId then
        self:Hide(true)
        return false
    end

    -- Don't allow dropping to Empty category
    if currentCategoryId == "Empty" then
        ClearCursor()
        self:Hide(true)
        return false
    end

    -- Check if this is a cross-container drop
    -- Use pre-captured cursor source (captured when indicator was shown, more reliable)
    local cursorSource = currentCursorSource or self:GetCursorItemSource()
    local targetContainer = nil

    if currentHoveredButton and currentHoveredButton.containerFrame then
        local containerName = currentHoveredButton.containerFrame:GetName()
        if containerName == "GudaBagsSecureContainer" then
            targetContainer = "bag"
        elseif containerName == "GudaBankContainer" then
            targetContainer = "bank"
        end
    end

    -- If cursorSource is still nil, we can't determine cross-container vs same-container
    -- Log warning for debugging
    if not cursorSource then
        ns:Debug("HandleDrop: WARNING - could not detect cursor source, will fall through to same-container logic")
    end

    ns:Debug("HandleDrop: cursorSource=", cursorSource, "targetContainer=", targetContainer, "categoryId=", currentCategoryId)
    ns:Debug("HandleDrop: currentHoveredButton=", currentHoveredButton and "exists" or "nil")
    if currentHoveredButton then
        ns:Debug("HandleDrop: containerFrame=", currentHoveredButton.containerFrame and currentHoveredButton.containerFrame:GetName() or "nil")
    end

    -- Bank to Bag: cursor from bank, indicator on bag item
    if cursorSource == "bank" and targetContainer == "bag" then
        -- Assign item to category FIRST (before moving to bag)
        -- This ensures the item won't be categorized as "Recent"
        local CategoryManager = ns:GetModule("CategoryManager")
        if CategoryManager then
            CategoryManager:AssignItemToCategory(itemID, currentCategoryId)
        end

        -- Find first empty bag slot and place item there
        for bagID = 0, NUM_BAG_SLOTS do
            local numSlots = C_Container.GetContainerNumSlots(bagID)
            for slot = 1, numSlots do
                local itemInfo = C_Container.GetContainerItemInfo(bagID, slot)
                if not itemInfo then
                    -- Empty slot found - place item here (moves from bank to bag)
                    C_Container.PickupContainerItem(bagID, slot)
                    self:Hide(true)
                    return true
                end
            end
        end
        -- No empty slot found
        ClearCursor()
        self:Hide(true)
        return false
    end

    -- Bag to Bank: cursor from bag, indicator on bank item
    if cursorSource == "bag" and targetContainer == "bank" then
        -- Assign item to category FIRST (before moving to bank)
        local CategoryManager = ns:GetModule("CategoryManager")
        if CategoryManager then
            CategoryManager:AssignItemToCategory(itemID, currentCategoryId)
        end

        -- Find first empty bank slot and place item there
        -- Build bank bag list based on game version
        local bankBags = {}

        -- On modern Retail (12.0+), use Character Bank Tabs
        if Constants.CHARACTER_BANK_TAB_IDS and #Constants.CHARACTER_BANK_TAB_IDS > 0 then
            for _, tabID in ipairs(Constants.CHARACTER_BANK_TAB_IDS) do
                table.insert(bankBags, tabID)
            end
        end

        -- Use BANK_BAG_IDS as fallback (works for older Retail and Classic)
        if #bankBags == 0 and Constants.BANK_BAG_IDS and #Constants.BANK_BAG_IDS > 0 then
            for _, bagID in ipairs(Constants.BANK_BAG_IDS) do
                table.insert(bankBags, bagID)
            end
        end

        for _, bagID in ipairs(bankBags) do
            local numSlots = C_Container.GetContainerNumSlots(bagID)
            if numSlots and numSlots > 0 then
                for slot = 1, numSlots do
                    local itemInfo = C_Container.GetContainerItemInfo(bagID, slot)
                    if not itemInfo then
                        -- Empty slot found - place item here (moves from bag to bank)
                        C_Container.PickupContainerItem(bagID, slot)
                        self:Hide(true)
                        return true
                    end
                end
            end
        end
        -- No empty slot found
        ClearCursor()
        self:Hide(true)
        return false
    end

    -- Regular drop (within same container) - just assign category
    -- For same-container, we only change the category assignment, item stays in place
    ns:Debug("HandleDrop: same-container drop, assigning category only")

    -- Clear cursor FIRST to put item back in its original slot
    ClearCursor()

    -- Then assign category (this won't move the item, just change its category)
    local CategoryManager = ns:GetModule("CategoryManager")
    if CategoryManager then
        local success = CategoryManager:AssignItemToCategory(itemID, currentCategoryId)
        ns:Debug("HandleDrop: AssignItemToCategory result:", success)
    end

    self:Hide(true)
    return true
end

-- Check if cursor has an item (for showing/hiding indicator)
function CategoryDropIndicator:CursorHasItem()
    local infoType = GetCursorInfo()
    return infoType == "item"
end

-- Find where the cursor item is coming from by checking locked slots
-- Returns "bag", "bank", or nil if unknown
function CategoryDropIndicator:GetCursorItemSource()
    ns:Debug("GetCursorItemSource: checking bags 0 to", NUM_BAG_SLOTS)

    -- Check player bags (0 to NUM_BAG_SLOTS) for locked slot
    for bagID = 0, NUM_BAG_SLOTS do
        local numSlots = C_Container.GetContainerNumSlots(bagID)
        for slot = 1, numSlots do
            local itemInfo = C_Container.GetContainerItemInfo(bagID, slot)
            if itemInfo and itemInfo.isLocked then
                ns:Debug("GetCursorItemSource: found locked in bag", bagID, slot)
                return "bag"
            end
        end
    end

    -- Check bank slots for locked slot
    -- Use Constants.BANK_BAG_IDS which is properly set for each game version
    local bankBags = {}

    -- First, add any Character Bank Tab IDs (Retail 12.0+)
    if Constants.CHARACTER_BANK_TAB_IDS and #Constants.CHARACTER_BANK_TAB_IDS > 0 then
        ns:Debug("GetCursorItemSource: using CHARACTER_BANK_TAB_IDS")
        for _, tabID in ipairs(Constants.CHARACTER_BANK_TAB_IDS) do
            table.insert(bankBags, tabID)
        end
    end

    -- Add Warband/Account bank tabs (Retail)
    if Constants.WARBAND_BANK_TAB_IDS and #Constants.WARBAND_BANK_TAB_IDS > 0 then
        ns:Debug("GetCursorItemSource: adding WARBAND_BANK_TAB_IDS")
        for _, tabID in ipairs(Constants.WARBAND_BANK_TAB_IDS) do
            table.insert(bankBags, tabID)
        end
    end

    -- Use BANK_BAG_IDS as fallback (works for older Retail and Classic)
    if #bankBags == 0 and Constants.BANK_BAG_IDS and #Constants.BANK_BAG_IDS > 0 then
        ns:Debug("GetCursorItemSource: using Constants.BANK_BAG_IDS")
        for _, bagID in ipairs(Constants.BANK_BAG_IDS) do
            table.insert(bankBags, bagID)
        end
    end

    ns:Debug("GetCursorItemSource: checking bank bags:", table.concat(bankBags, ", "))
    for _, bagID in ipairs(bankBags) do
        local numSlots = C_Container.GetContainerNumSlots(bagID)
        if numSlots and numSlots > 0 then
            for slot = 1, numSlots do
                local itemInfo = C_Container.GetContainerItemInfo(bagID, slot)
                if itemInfo and itemInfo.isLocked then
                    ns:Debug("GetCursorItemSource: found locked in bank", bagID, slot)
                    return "bank"
                end
            end
        end
    end

    ns:Debug("GetCursorItemSource: no locked slot found in any container")
    return nil
end

-- Check if the dragged item is already in the specified category
function CategoryDropIndicator:IsDraggedItemInCategory(categoryId)
    local infoType, itemID = GetCursorInfo()
    if infoType ~= "item" or not itemID then return false end

    local CategoryManager = ns:GetModule("CategoryManager")
    if not CategoryManager then return false end

    -- Get the item's current category
    -- We need itemData to categorize, so fetch it from the cursor item
    local itemName, itemLink, itemQuality, itemLevel, itemMinLevel, itemType, itemSubType,
          itemStackCount, itemEquipLoc, itemTexture = GetItemInfo(itemID)

    if not itemName then return false end

    -- Build minimal itemData for categorization
    local itemData = {
        itemID = itemID,
        name = itemName,
        link = itemLink,
        quality = itemQuality,
        itemType = itemType,
        itemSubType = itemSubType,
        equipSlot = itemEquipLoc,
    }

    local currentCategory = CategoryManager:CategorizeItem(itemData)
    return currentCategory == categoryId
end
