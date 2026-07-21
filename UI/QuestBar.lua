local addonName, ns = ...

local QuestBar = {}
ns:RegisterModule("QuestBar", QuestBar)

local Constants = ns.Constants
local Database = ns:GetModule("Database")
local Events = ns:GetModule("Events")
local Font = ns:GetModule("Font")
local Utils = ns:GetModule("Utils")

-- Iterate backpack + 4 bag slots + reagent bag (Retail only — Constants.REAGENT_BAG is nil on Classic).
local MAX_PLAYER_BAG = Constants.REAGENT_BAG or Constants.PLAYER_BAG_MAX

-- Local state
local frame = nil
local mainButton = nil
local flyout = nil
local flyoutButtons = {}
local gridButtons = {}  -- Buttons for multi-column grid layout
local isDragging = false
local questItems = {}  -- Current usable quest items
local knownItemIDs = {}  -- Track known quest item IDs to detect new loot
local activeItemIndex = 1
local pendingRefresh = false
local initialized = false
local infoRefreshScheduled = false

-- Constants
local PADDING = 0
local MAX_FLYOUT_ITEMS = 8
local MAX_GRID_ITEMS = 40  -- Max items in grid layout (5 columns * 8 rows)
local FLYOUT_HIDE_DELAY = 0.4  -- seconds of continuous non-hover before hiding the flyout

-- Debounce accumulator for flyout hide (driven by the flyout's OnUpdate)
local flyoutHideAccum = 0

-- Flyout visibility helpers
local function ShowFlyoutFrame()
    if not flyout then return end
    flyoutHideAccum = 0
    flyout:Show()
end

local function HideFlyoutFrame()
    if not flyout then return end
    flyout:Hide()
end

-- Battleground detection
local function IsInBattleground()
    local inInstance, instanceType = IsInInstance()
    return inInstance and instanceType == "pvp"
end

local function GetButtonSize()
    return Database:GetSetting("questBarSize") or 44
end

local function GetColumns()
    return Database:GetSetting("questBarColumns") or 1
end

local function GetButtonSpacing()
    return Database:GetSetting("questBarSpacing") or 2
end

-------------------------------------------------
-- Quest Item Detection
-------------------------------------------------

local function IsUsableItem(itemID)
    if not itemID then return false end
    local spellName = GetItemSpell(itemID)
    return spellName ~= nil
end

local function ScanForUsableQuestItems()
    local items = {}
    -- Use cached bag data instead of scanning
    local BagScanner = ns:GetModule("BagScanner")
    if not BagScanner then return items end

    local cachedBags = BagScanner:GetCachedBags()

    for bagID = Constants.PLAYER_BAG_MIN, MAX_PLAYER_BAG do
        local bagData = cachedBags[bagID]
        if bagData and bagData.slots then
            for slot, itemData in pairs(bagData.slots) do
                local isQuestBarItem = itemData and IsUsableItem(itemData.itemID) and (itemData.isQuestItem or itemData.hasDuration)
                if isQuestBarItem then
                    -- Check if we already have this itemID in the list
                    local found = false
                    for _, existing in ipairs(items) do
                        if existing.itemID == itemData.itemID then
                            found = true
                            break
                        end
                    end
                    if not found then
                        table.insert(items, {
                            itemID = itemData.itemID,
                            bagID = bagID,
                            slot = slot,
                            isQuestStarter = itemData.isQuestStarter,
                            texture = itemData.texture,
                            name = itemData.name,
                            count = itemData.count,
                        })
                    end
                    if #items >= MAX_FLYOUT_ITEMS + 1 then
                        return items
                    end
                end
            end
        end
    end

    return items
end

local function FindItemInBags(itemID)
    for bagID = Constants.PLAYER_BAG_MIN, MAX_PLAYER_BAG do
        local numSlots = C_Container.GetContainerNumSlots(bagID)
        for slot = 1, numSlots do
            local info = C_Container.GetContainerItemInfo(bagID, slot)
            if info and info.itemID == itemID then
                return bagID, slot, info
            end
        end
    end
    return nil, nil, nil
end

local function GetItemCount(itemID)
    local count = 0
    for bagID = Constants.PLAYER_BAG_MIN, MAX_PLAYER_BAG do
        local numSlots = C_Container.GetContainerNumSlots(bagID)
        for slot = 1, numSlots do
            local info = C_Container.GetContainerItemInfo(bagID, slot)
            if info and info.itemID == itemID then
                count = count + (info.stackCount or 1)
            end
        end
    end
    return count
end

-------------------------------------------------
-- Button Creation
-------------------------------------------------

-- Region map for Masque, used at both initial registration and on live resize
-- (UpdateSize re-registers each button at its new size to re-apply the skin).
local function GetMasqueRegions(button)
    return {
        Icon = button.icon,
        Cooldown = button.cooldown,
        Normal = button:GetNormalTexture(),
        Count = button.count,
        Highlight = button.highlight,
    }
end

local function CreateItemButton(parent, name, isMain)
    local buttonSize = GetButtonSize()

    local button
    if isMain then
        -- Main button uses SecureActionButtonTemplate for protected item usage during combat
        button = CreateFrame("Button", name, parent, "SecureActionButtonTemplate")
        button:SetAttribute("type", "item")
    else
        -- Flyout buttons are regular buttons (selection only, no item use)
        -- This keeps the flyout frame non-protected so Show/Hide work during combat
        button = CreateFrame("Button", name, parent)
    end
    button:SetSize(buttonSize, buttonSize)
    if isMain then
        button:RegisterForClicks("AnyDown", "AnyUp")
    else
        button:RegisterForClicks("AnyUp")
    end

    -- Prevent dragging items
    button:RegisterForDrag("LeftButton")
    button:SetScript("OnDragStart", function() end)
    button:SetScript("OnReceiveDrag", function() end)

    -- Hide template's NormalTexture (Masque-aware)
    Utils:HideNormalTexture(button)
    local MasqueModule = ns:GetModule("Masque")
    local masqueActive = MasqueModule and MasqueModule:IsActive()

    -- Background
    local bg = button:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture("Interface\\Buttons\\UI-EmptySlot-Disabled")
    bg:SetVertexColor(1, 1, 1, 0.5)
    button.bg = bg

    -- Icon
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    button.icon = icon

    -- Count text
    local count = button:CreateFontString(nil, "OVERLAY")
    local fontSize = Database:GetSetting("iconFontSize")
    Font:Apply(count, fontSize, "OUTLINE")
    count:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, 1)
    count:SetJustifyH("RIGHT")
    button.count = count

    -- Cooldown frame
    local cooldown = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
    cooldown:SetAllPoints(icon)
    cooldown:SetDrawEdge(false)
    button.cooldown = cooldown

    -- Highlight
    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    highlight:SetBlendMode("ADD")
    button.highlight = highlight

    -- Quality border
    local border = Utils:CreateItemBorder(button)
    button.border = border

    -- Inner shadow/glow for quest colors (inset effect with more spread)
    button.innerShadow = Utils:CreateInnerShadow(button, 8)

    -- Tooltip
    button:SetScript("OnEnter", function(self)
        if self.itemID then
            local bagID, slotID = FindItemInBags(self.itemID)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if bagID and slotID then
                GameTooltip:SetBagItem(bagID, slotID)
            elseif GameTooltip.SetItemByID then
                GameTooltip:SetItemByID(self.itemID)
            else
                -- SetItemByID is WoD 6.0; SetHyperlink is the pre-6.0 equivalent.
                local link = select(2, GetItemInfo(self.itemID))
                if link then GameTooltip:SetHyperlink(link) end
            end
            GameTooltip:Show()
        end

        -- Show flyout on hover (main button or grid buttons)
        if isMain and flyout then
            QuestBar:ShowFlyout()
        end
    end)

    button:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
        -- Don't hide flyout here - let the flyout frame handle it
    end)

    -- PreClick/PostClick only for main button (SecureActionButtonTemplate)
    if isMain then
        -- PreClick: allow item use on left/right click, but not when shift is held (shift+click = drag)
        button:SetScript("PreClick", function(self, mouseButton)
            if InCombatLockdown() then return end  -- Can't SetAttribute during combat
            if not IsShiftKeyDown() then
                self:SetAttribute("type", "item")
            else
                self:SetAttribute("type", nil)
            end
        end)

        -- PostClick: restore type
        button:SetScript("PostClick", function(self, mouseButton)
            if InCombatLockdown() then return end  -- Can't SetAttribute during combat
            self:SetAttribute("type", "item")
        end)
    end

    if isMain then
        -- Main button drag handling for moving the bar
        button:HookScript("OnMouseDown", function(self, mouseButton)
            if mouseButton == "LeftButton" and IsShiftKeyDown() and not CursorHasItem() and not InCombatLockdown() then
                isDragging = true
                frame:StartMoving()
            end
        end)

        button:HookScript("OnMouseUp", function(self, mouseButton)
            if mouseButton == "LeftButton" and isDragging then
                isDragging = false
                if not InCombatLockdown() then
                    frame:StopMovingOrSizing()
                end
                QuestBar:SavePosition()
            end
        end)
    end

    -- Register with Masque if active (reuse masqueActive from above)
    if masqueActive then
        MasqueModule:AddButton(button, "Quest Items", GetMasqueRegions(button))
    end

    return button
end

-------------------------------------------------
-- Flyout Creation
-------------------------------------------------

local function CreateFlyout(parent)
    local buttonSize = GetButtonSize()
    local f = CreateFrame("Frame", "GudaQuestBarFlyout", parent, "BackdropTemplate")
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(100)

    f:SetBackdrop(nil)

    -- Create flyout buttons (vertical stack, top to bottom)
    for i = 1, MAX_FLYOUT_ITEMS do
        local button = CreateItemButton(f, "GudaQuestBarFlyoutItem" .. i, false)
        button:SetPoint("TOP", f, "TOP", 0, -PADDING - (i - 1) * (buttonSize + GetButtonSpacing()))
        button:Hide()
        button.flyoutIndex = i

        -- On click in flyout, set as active item and save
        button:SetScript("OnClick", function(self, mouseButton)
            if mouseButton == "LeftButton" and self.itemIndex then
                local columns = GetColumns()

                if columns > 1 then
                    -- Grid mode: swap clicked overflow item into the last visible slot
                    local clickedIndex = self.itemIndex
                    if clickedIndex > columns and clickedIndex <= #questItems then
                        questItems[columns], questItems[clickedIndex] = questItems[clickedIndex], questItems[columns]
                        -- Save visible item IDs so preference persists across refreshes
                        local pinnedIDs = {}
                        for i = 1, math.min(columns, #questItems) do
                            pinnedIDs[i] = questItems[i].itemID
                        end
                        Database:SetSetting("questBarPinnedItemIDs", pinnedIDs)
                    end
                else
                    -- Flyout mode: set as active item
                    activeItemIndex = self.itemIndex
                    local activeItem = questItems[activeItemIndex]
                    if activeItem then
                        Database:SetSetting("questBarActiveItemID", activeItem.itemID)
                    end
                end

                if InCombatLockdown() then
                    if columns == 1 then
                        -- Visual-only update of main button during combat (can't SetAttribute)
                        local activeItem = questItems[activeItemIndex]
                        if activeItem and mainButton then
                            local _, _, _, _, _, _, _, _, _, itemTexture = GetItemInfo(activeItem.itemID)
                            local count = GetItemCount(activeItem.itemID)
                            mainButton.itemID = activeItem.itemID
                            mainButton.icon:SetTexture(itemTexture or activeItem.texture)
                            if count > 1 then
                                mainButton.count:SetText(count)
                                mainButton.count:Show()
                            else
                                mainButton.count:Hide()
                            end
                            local bagID, slot = FindItemInBags(activeItem.itemID)
                            mainButton.bagID = bagID
                            mainButton.slotID = slot
                            if bagID and slot then
                                local start, duration, enable = C_Container.GetContainerItemCooldown(bagID, slot)
                                if start and duration and duration > 0 then
                                    mainButton.cooldown:SetCooldown(start, duration)
                                else
                                    mainButton.cooldown:Clear()
                                end
                            end
                        end
                    end
                    pendingRefresh = true
                    HideFlyoutFrame()
                else
                    QuestBar:Refresh()
                end
            end
        end)

        flyoutButtons[i] = button
    end

    -- Hiding is owned by the debounced OnUpdate below — do NOT hide instantly here.
    -- An immediate OnLeave hide is the main source of flicker when the cursor crosses
    -- the gap/dead-zone between the bar and a flyout item.

    f:SetScript("OnUpdate", function(self, elapsed)
        if not self:IsShown() then return end
        -- Mouse is "over" if it's on the main button, the flyout, the parent frame
        -- (grid buttons), or any visible flyout button.
        local parent = self:GetParent()
        local over = mainButton:IsMouseOver() or self:IsMouseOver() or parent:IsMouseOver()
        if not over then
            for _, btn in ipairs(flyoutButtons) do
                if btn:IsShown() and btn:IsMouseOver() then
                    over = true
                    break
                end
            end
        end

        if over then
            flyoutHideAccum = 0
        else
            -- Debounce: only hide after FLYOUT_HIDE_DELAY of continuous non-hover,
            -- so brief excursions across the gap between items don't close the flyout.
            flyoutHideAccum = flyoutHideAccum + elapsed
            if flyoutHideAccum >= FLYOUT_HIDE_DELAY then
                flyoutHideAccum = 0
                HideFlyoutFrame()
            end
        end
    end)

    f:Hide()
    return f
end

-------------------------------------------------
-- UI Creation
-------------------------------------------------

local function CreateQuestBarFrame()
    local buttonSize = GetButtonSize()
    local f = CreateFrame("Frame", "GudaQuestBar", UIParent, "BackdropTemplate")
    f:SetSize(buttonSize + PADDING * 2, buttonSize + PADDING * 2)
    f:SetPoint("TOP", UIParent, "TOP", 0, -150)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("MEDIUM")
    f:SetFrameLevel(Constants.FRAME_LEVELS.BASE)

    f:SetBackdrop(nil)

    -- Create main button (used in flyout mode / columns=1)
    mainButton = CreateItemButton(f, "GudaQuestBarMainButton", true)
    mainButton:SetPoint("CENTER", f, "CENTER", 0, 0)

    -- Create grid buttons for multi-column layout
    for i = 1, MAX_GRID_ITEMS do
        local button = CreateItemButton(f, "GudaQuestBarGridItem" .. i, true)
        button:Hide()
        button.gridIndex = i
        gridButtons[i] = button
    end

    -- Create flyout (to the right of the main bar, bottom-aligned)
    flyout = CreateFlyout(f)
    flyout:SetPoint("BOTTOMLEFT", f, "BOTTOMRIGHT", 0, 0)

    f:Hide()
    return f
end

-------------------------------------------------
-- Button Update
-------------------------------------------------

local function UpdateButton(button, itemData)
    if not itemData then
        button.itemID = nil
        button.border:Hide()
        if button.innerShadow then
            for _, tex in pairs(button.innerShadow) do tex:Hide() end
        end
        -- SetAttribute only exists on SecureActionButtonTemplate (main button)
        if button.SetAttribute then
            if not InCombatLockdown() then
                button:SetAttribute("item", nil)
            end
        end
        button:Hide()
        return
    end

    local itemID = itemData.itemID
    button.itemID = itemID

    local itemName, itemLink, itemQuality, _, _, _, _, _, _, itemTexture = GetItemInfo(itemID)
    local count = GetItemCount(itemID)

    local bagID, slot = FindItemInBags(itemID)

    button.bagID = bagID
    button.slotID = slot
    button.itemName = itemName

    -- SetAttribute only exists on SecureActionButtonTemplate (main button)
    if button.SetAttribute then
        if not InCombatLockdown() then
            if bagID and slot then
                button:SetAttribute("item", "item:" .. itemID)
            else
                button:SetAttribute("item", nil)
            end
        end
    end

    if itemTexture or itemData.texture then
        button.icon:SetTexture(itemTexture or itemData.texture)
        button.bg:Hide()
    else
        button.bg:Show()
    end

    if count > 1 then
        button.count:SetText(count)
        button.count:Show()
    else
        button.count:Hide()
    end

    -- Update cooldown
    if bagID and slot then
        local start, duration, enable = C_Container.GetContainerItemCooldown(bagID, slot)
        if start and duration and duration > 0 then
            button.cooldown:SetCooldown(start, duration)
        else
            button.cooldown:Clear()
        end
    else
        button.cooldown:Clear()
    end

    -- Sunny yellow-gold color for border and inner shadow
    -- Quality borders coexist with Masque's button chrome
    local sunnyR, sunnyG, sunnyB = 1.0, 0.85, 0.2
    button.border:SetVertexColor(sunnyR, sunnyG, sunnyB, 1)
    button.border:Show()

    -- Show inner shadow with sunny color
    if button.innerShadow then
        button.innerShadow.top:SetGradient("VERTICAL", CreateColor(sunnyR, sunnyG, sunnyB, 0), CreateColor(sunnyR, sunnyG, sunnyB, 0.6))
        button.innerShadow.bottom:SetGradient("VERTICAL", CreateColor(sunnyR, sunnyG, sunnyB, 0.6), CreateColor(sunnyR, sunnyG, sunnyB, 0))
        button.innerShadow.left:SetGradient("HORIZONTAL", CreateColor(sunnyR, sunnyG, sunnyB, 0.6), CreateColor(sunnyR, sunnyG, sunnyB, 0))
        button.innerShadow.right:SetGradient("HORIZONTAL", CreateColor(sunnyR, sunnyG, sunnyB, 0), CreateColor(sunnyR, sunnyG, sunnyB, 0.6))
        for _, tex in pairs(button.innerShadow) do tex:Show() end
    end

    -- Dim if not in bags
    if count == 0 then
        button.icon:SetDesaturated(true)
        button.icon:SetAlpha(0.5)
    else
        button.icon:SetDesaturated(false)
        button.icon:SetAlpha(1)
    end

    button:Show()
end

-------------------------------------------------
-- Public API
-------------------------------------------------

function QuestBar:Init()
    if frame then return end
    frame = CreateQuestBarFrame()
    self:RestorePosition()
    self:Refresh()
end

function QuestBar:Show()
    if not frame then self:Init() end
    local showQuestBar = Database:GetSetting("showQuestBar")
    if showQuestBar then
        self:Refresh()
    end
end

function QuestBar:Hide()
    if frame then
        frame:Hide()
    end
    HideFlyoutFrame()
end

function QuestBar:ShowFlyout()
    if not flyout then return end

    local columns = GetColumns()

    -- Determine if there are overflow items to show
    if columns == 1 then
        if #questItems <= 1 then return end
    else
        if #questItems <= columns then return end
    end

    if InCombatLockdown() then
        -- During combat, just show the pre-configured flyout frame
        ShowFlyoutFrame()
        return
    end

    local buttonSize = GetButtonSize()
    local otherItems = {}

    if columns == 1 then
        -- Flyout mode: collect items that are not the active one
        for i, item in ipairs(questItems) do
            if i ~= activeItemIndex then
                table.insert(otherItems, { data = item, index = i })
            end
        end
    else
        -- Grid mode: collect overflow items beyond visible columns
        for i = columns + 1, #questItems do
            table.insert(otherItems, { data = questItems[i], index = i })
        end
    end

    local visibleCount = math.min(#otherItems, MAX_FLYOUT_ITEMS)

    -- Update flyout buttons (vertical stack, top to bottom)
    for i = 1, MAX_FLYOUT_ITEMS do
        local otherItem = otherItems[i]
        if otherItem then
            flyoutButtons[i].itemIndex = otherItem.index
            UpdateButton(flyoutButtons[i], otherItem.data)
            flyoutButtons[i]:SetSize(buttonSize, buttonSize)
            flyoutButtons[i]:ClearAllPoints()
            flyoutButtons[i]:SetPoint("TOP", flyout, "TOP", 0, -PADDING - (i - 1) * (buttonSize + GetButtonSpacing()))
        else
            flyoutButtons[i]:Hide()
            flyoutButtons[i].itemIndex = nil
        end
    end

    if visibleCount > 0 then
        local height = PADDING * 2 + visibleCount * buttonSize + (visibleCount - 1) * GetButtonSpacing()
        local width = buttonSize + PADDING * 2
        flyout:SetSize(width, height)
        ShowFlyoutFrame()
    else
        HideFlyoutFrame()
    end
end

function QuestBar:HideFlyout()
    HideFlyoutFrame()
end

function QuestBar:Refresh()
    if not frame then return end

    if InCombatLockdown() then
        pendingRefresh = true
        return
    end

    local showQuestBar = Database:GetSetting("showQuestBar")
    local hideInBGs = Database:GetSetting("hideQuestBarInBGs")

    -- Hide if setting is off OR if in battleground with hide option enabled
    if not showQuestBar or (hideInBGs and IsInBattleground()) then
        frame:Hide()
        HideFlyoutFrame()
        return
    end

    -- Scan for usable quest items
    local previousItems = questItems
    questItems = ScanForUsableQuestItems()

    -- Detect newly looted items and switch to them
    local newItemIndex = nil
    for i, item in ipairs(questItems) do
        if not knownItemIDs[item.itemID] then
            newItemIndex = i
        end
    end

    -- Update known item IDs
    knownItemIDs = {}
    for _, item in ipairs(questItems) do
        knownItemIDs[item.itemID] = true
    end

    -- Reorder items based on pinned preference (grid mode)
    local columns = GetColumns()
    if columns > 1 then
        local pinnedIDs = Database:GetSetting("questBarPinnedItemIDs")
        if pinnedIDs and #pinnedIDs > 0 then
            local reordered = {}
            local used = {}
            -- First, add pinned items in their saved order
            for _, pinnedID in ipairs(pinnedIDs) do
                for i, item in ipairs(questItems) do
                    if item.itemID == pinnedID and not used[i] then
                        table.insert(reordered, item)
                        used[i] = true
                        break
                    end
                end
            end
            -- Then add remaining items in their original order
            for i, item in ipairs(questItems) do
                if not used[i] then
                    table.insert(reordered, item)
                end
            end
            questItems = reordered
        end
    end

    if newItemIndex and initialized then
        -- New item looted - make it active (skip on first refresh to restore saved state)
        activeItemIndex = newItemIndex
        Database:SetSetting("questBarActiveItemID", questItems[newItemIndex].itemID)
    else
        -- Restore saved active item by matching itemID
        local savedItemID = Database:GetSetting("questBarActiveItemID")
        if savedItemID then
            local found = false
            for i, item in ipairs(questItems) do
                if item.itemID == savedItemID then
                    activeItemIndex = i
                    found = true
                    break
                end
            end
            if not found then
                activeItemIndex = 1
            end
        end
    end

    -- Validate activeItemIndex
    if activeItemIndex > #questItems then
        activeItemIndex = 1
    end

    if #questItems > 0 then
        initialized = true
        local buttonSize = GetButtonSize()
        local columns = GetColumns()

        if columns == 1 then
            -- Flyout mode: single main button + flyout on hover
            -- Hide grid buttons
            for i = 1, MAX_GRID_ITEMS do
                gridButtons[i]:Hide()
            end

            frame:SetSize(buttonSize + PADDING * 2, buttonSize + PADDING * 2)
            mainButton:SetSize(buttonSize, buttonSize)
            mainButton:ClearAllPoints()
            mainButton:SetPoint("CENTER", frame, "CENTER", 0, 0)

            UpdateButton(mainButton, questItems[activeItemIndex])
            frame:Show()

            -- Pre-configure flyout buttons so they're ready for combat access
            if flyout and #questItems > 1 then
                local otherItems = {}
                for i, item in ipairs(questItems) do
                    if i ~= activeItemIndex then
                        table.insert(otherItems, { data = item, index = i })
                    end
                end
                local visibleCount = math.min(#otherItems, MAX_FLYOUT_ITEMS)
                for i = 1, MAX_FLYOUT_ITEMS do
                    local otherItem = otherItems[i]
                    if otherItem then
                        flyoutButtons[i].itemIndex = otherItem.index
                        UpdateButton(flyoutButtons[i], otherItem.data)
                        flyoutButtons[i]:SetSize(buttonSize, buttonSize)
                        flyoutButtons[i]:ClearAllPoints()
                        flyoutButtons[i]:SetPoint("TOP", flyout, "TOP", 0, -PADDING - (i - 1) * (buttonSize + GetButtonSpacing()))
                    else
                        flyoutButtons[i]:Hide()
                        flyoutButtons[i].itemIndex = nil
                    end
                end
                if visibleCount > 0 then
                    local height = PADDING * 2 + visibleCount * buttonSize + (visibleCount - 1) * GetButtonSpacing()
                    local width = buttonSize + PADDING * 2
                    flyout:SetSize(width, height)
                end
            else
                HideFlyoutFrame()
            end
        else
            -- Grid mode: show items in a single row, overflow to flyout
            mainButton:Hide()

            local visibleCount = math.min(#questItems, columns)
            local effectiveColumns = math.min(columns, visibleCount)
            local frameWidth = PADDING * 2 + effectiveColumns * buttonSize + (effectiveColumns - 1) * GetButtonSpacing()
            local frameHeight = PADDING * 2 + buttonSize
            frame:SetSize(frameWidth, frameHeight)

            for i = 1, MAX_GRID_ITEMS do
                if i <= visibleCount then
                    local x = PADDING + (i - 1) * (buttonSize + GetButtonSpacing())
                    local y = -PADDING

                    gridButtons[i]:SetSize(buttonSize, buttonSize)
                    gridButtons[i]:ClearAllPoints()
                    gridButtons[i]:SetPoint("TOPLEFT", frame, "TOPLEFT", x, y)
                    UpdateButton(gridButtons[i], questItems[i])
                else
                    gridButtons[i]:Hide()
                end
            end

            -- Pre-configure flyout for overflow items (for combat access)
            if #questItems > columns and flyout then
                local overflowItems = {}
                for i = columns + 1, #questItems do
                    table.insert(overflowItems, { data = questItems[i], index = i })
                end
                local flyoutCount = math.min(#overflowItems, MAX_FLYOUT_ITEMS)
                for i = 1, MAX_FLYOUT_ITEMS do
                    local item = overflowItems[i]
                    if item then
                        flyoutButtons[i].itemIndex = item.index
                        UpdateButton(flyoutButtons[i], item.data)
                        flyoutButtons[i]:SetSize(buttonSize, buttonSize)
                        flyoutButtons[i]:ClearAllPoints()
                        flyoutButtons[i]:SetPoint("TOP", flyout, "TOP", 0, -PADDING - (i - 1) * (buttonSize + GetButtonSpacing()))
                    else
                        flyoutButtons[i]:Hide()
                        flyoutButtons[i].itemIndex = nil
                    end
                end
                if flyoutCount > 0 then
                    local height = PADDING * 2 + flyoutCount * buttonSize + (flyoutCount - 1) * GetButtonSpacing()
                    local width = buttonSize + PADDING * 2
                    flyout:SetSize(width, height)
                end
            else
                HideFlyoutFrame()
            end

            frame:Show()
        end
    else
        frame:Hide()
        mainButton:Hide()
        for i = 1, MAX_GRID_ITEMS do
            gridButtons[i]:Hide()
        end
        HideFlyoutFrame()
    end
end

function QuestBar:SavePosition()
    if not frame then return end
    local point, _, relPoint, x, y = frame:GetPoint()
    Database:SetSetting("questBarPoint", point)
    Database:SetSetting("questBarRelPoint", relPoint)
    Database:SetSetting("questBarX", x)
    Database:SetSetting("questBarY", y)
end

function QuestBar:RestorePosition()
    if not frame then return end

    local point = Database:GetSetting("questBarPoint")
    local relPoint = Database:GetSetting("questBarRelPoint")
    local x = Database:GetSetting("questBarX")
    local y = Database:GetSetting("questBarY")

    if point and x and y then
        frame:ClearAllPoints()
        frame:SetPoint(point, UIParent, relPoint, x, y)
    end
end

function QuestBar:UpdateFontSize()
    local fontSize = Database:GetSetting("iconFontSize")
    if mainButton and mainButton.count then
        Font:Apply(mainButton.count, fontSize, "OUTLINE")
    end
    for _, button in ipairs(flyoutButtons) do
        if button.count then
            Font:Apply(button.count, fontSize, "OUTLINE")
        end
    end
    for _, button in ipairs(gridButtons) do
        if button.count then
            Font:Apply(button.count, fontSize, "OUTLINE")
        end
    end
end

function QuestBar:UpdateSize()
    if not frame then return end
    if InCombatLockdown() then
        pendingRefresh = true
        return
    end

    local buttonSize = GetButtonSize()
    local shadowSize = math.max(4, math.floor(buttonSize * 0.18))

    local MasqueModule = ns:GetModule("Masque")
    local masqueActive = MasqueModule and MasqueModule:IsActive()

    -- Helper to resize inner shadow on a button
    local function ResizeInnerShadow(button)
        if not button.innerShadow then return end
        button.innerShadow.top:SetHeight(shadowSize)
        button.innerShadow.bottom:SetHeight(shadowSize)
        button.innerShadow.left:SetWidth(shadowSize)
        button.innerShadow.right:SetWidth(shadowSize)
    end

    -- Helper to re-anchor child elements to fill resized button
    local function ReanchorChildren(button)
        if button.icon then
            button.icon:ClearAllPoints()
            button.icon:SetAllPoints(button)
        end
        if button.bg then
            button.bg:ClearAllPoints()
            button.bg:SetAllPoints(button)
        end
        if button.cooldown then
            button.cooldown:ClearAllPoints()
            button.cooldown:SetAllPoints(button.icon)
        end
        if button.highlight then
            button.highlight:ClearAllPoints()
            button.highlight:SetAllPoints(button)
        end
    end

    -- Unregister Masque BEFORE resize so AddButton re-skins at the new size.
    -- Mirrors TrackedBar:UpdateSize — Group:ReSkin alone preserves stale region
    -- geometry from the original registration.
    local function ResizeButton(button)
        if masqueActive then
            MasqueModule:RemoveButton(button)
        end
        button:SetSize(buttonSize, buttonSize)
        ReanchorChildren(button)
        ResizeInnerShadow(button)
        if masqueActive then
            MasqueModule:AddButton(button, "Quest Items", GetMasqueRegions(button))
        end
    end

    if mainButton then
        ResizeButton(mainButton)
    end

    for _, button in ipairs(gridButtons) do
        ResizeButton(button)
    end

    for i, button in ipairs(flyoutButtons) do
        ResizeButton(button)
        button:ClearAllPoints()
        button:SetPoint("TOP", flyout, "TOP", 0, -PADDING - (i - 1) * (buttonSize + GetButtonSpacing()))
    end

    self:Refresh()
end

function QuestBar:UseActiveItem()
    if #questItems == 0 then return end

    local activeItem = questItems[activeItemIndex]
    if not activeItem then return end

    local bagID, slot = FindItemInBags(activeItem.itemID)
    if bagID and slot then
        C_Container.UseContainerItem(bagID, slot)
    end
end

-------------------------------------------------
-- Event Handlers
-------------------------------------------------

local function OnBagUpdate()
    if not frame then return end
    -- Skip refreshes during sort (will refresh once via BAGS_UPDATED when sort completes)
    local SortEngine = ns:GetModule("SortEngine")
    if SortEngine and (SortEngine:IsSorting() or SortEngine:IsRestacking()) then return end
    QuestBar:Refresh()
end

local function OnCooldownUpdate()
    if not frame then return end
    QuestBar:Refresh()
end

local function OnQuestLogUpdate()
    if frame then
        QuestBar:Refresh()
    end
end

-- GET_ITEM_INFO_RECEIVED fires once per itemID as async item data finishes loading.
-- Freshly looted quest items often have nil GetItemSpell on the first scan and get
-- filtered out; this debounced refresh catches them once data lands.
local function OnItemInfoReceived()
    if not frame then return end
    if infoRefreshScheduled then return end
    infoRefreshScheduled = true
    C_Timer.After(0.1, function()
        infoRefreshScheduled = false
        if frame then QuestBar:Refresh() end
    end)
end

-------------------------------------------------
-- Initialization
-------------------------------------------------

Events:OnPlayerLogin(function()
    Database:ResolveFreshInstallDefaults()
    QuestBar:Init()
    QuestBar:Show()
end, QuestBar)

-- Handle setting changes directly (don't rely on BagFrame which may not be open)
Events:Register("SETTING_CHANGED", function(key)
    if key == "questBarSize" or key == "questBarColumns" or key == "questBarSpacing" then
        QuestBar:UpdateSize()
    elseif key == "iconFontSize" then
        QuestBar:UpdateFontSize()
    end
end, QuestBar)

-- Refresh after combat ends if we deferred during lockdown
Events:Register("PLAYER_REGEN_ENABLED", function()
    if pendingRefresh then
        pendingRefresh = false
        QuestBar:Refresh()
    end
end, QuestBar)

Events:Register("BAG_UPDATE", OnBagUpdate, QuestBar)
Events:Register("BAG_UPDATE_COOLDOWN", OnCooldownUpdate, QuestBar)
Events:Register("BAGS_UPDATED", function()
    if frame then QuestBar:Refresh() end
end, QuestBar)
Events:Register("QUEST_LOG_UPDATE", OnQuestLogUpdate, QuestBar)
Events:Register("QUEST_ACCEPTED", OnQuestLogUpdate, QuestBar)
Events:Register("QUEST_REMOVED", OnQuestLogUpdate, QuestBar)
Events:Register("GET_ITEM_INFO_RECEIVED", OnItemInfoReceived, QuestBar)

-- Refresh when entering/leaving battlegrounds
Events:Register("PLAYER_ENTERING_WORLD", function()
    if frame then
        QuestBar:Refresh()
    end
end, QuestBar)
Events:Register("ZONE_CHANGED_NEW_AREA", function()
    if frame then
        QuestBar:Refresh()
    end
end, QuestBar)
