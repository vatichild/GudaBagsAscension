local addonName, ns = ...

local TrackedBar = {}
ns:RegisterModule("TrackedBar", TrackedBar)

local Constants = ns.Constants
local L = ns.L
local Database = ns:GetModule("Database")
local Events = ns:GetModule("Events")
local Font = ns:GetModule("Font")
local Utils = ns:GetModule("Utils")

-- Local state
local frame = nil
local itemButtons = {}
local isDragging = false
local pendingResize = false
local pendingRefresh = false

-- Constants
local PADDING = 5
local MAX_BUTTONS = 12  -- Maximum possible buttons (for button pool)
-- Iterate backpack + 4 bag slots + reagent bag (Retail only — Constants.REAGENT_BAG is nil on Classic).
local MAX_PLAYER_BAG = Constants.REAGENT_BAG or Constants.PLAYER_BAG_MAX

local function GetButtonSize()
    return Database:GetSetting("trackedBarSize") or 36
end

local function GetButtonSpacing()
    return Database:GetSetting("trackedBarSpacing") or 3
end

local function GetMaxColumns()
    return Database:GetSetting("trackedBarColumns") or 12
end

-------------------------------------------------
-- Item Helper Functions (must be before CreateItemButton)
-------------------------------------------------

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
-- Button Pool
-------------------------------------------------

local function CreateItemButton(parent, index)
    local buttonSize = GetButtonSize()

    -- Use SecureActionButtonTemplate for protected item usage
    local button = CreateFrame("Button", "GudaTrackedItem" .. index, parent, "SecureActionButtonTemplate")
    button:SetSize(buttonSize, buttonSize)
    button:RegisterForClicks("AnyDown")

    -- Set type to item - attributes will be set in UpdateButton
    button:SetAttribute("type", "item")

    -- Register for drag but set empty handlers to prevent any drag behavior
    button:RegisterForDrag("LeftButton")
    button:SetScript("OnDragStart", function() end)
    button:SetScript("OnReceiveDrag", function() end)

    -- Hide template's NormalTexture (Masque-aware)
    Utils:HideNormalTexture(button)

    -- Background (slot style)
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

    -- Count text (same font style as bag items)
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

    -- Quality border (same style as bag items)
    local border = Utils:CreateItemBorder(button)
    button.border = border

    -- Quest starter icon (top left corner) - exclamation mark for quest starter items
    -- Use a frame container to ensure it draws above the border
    local questStarterFrame = CreateFrame("Frame", nil, button)
    questStarterFrame:SetFrameLevel(button:GetFrameLevel() + Constants.FRAME_LEVELS.QUEST_ICON)
    questStarterFrame:SetSize(14, 14)
    questStarterFrame:SetPoint("TOPLEFT", button, "TOPLEFT", -4, 2)
    local questStarterIcon = questStarterFrame:CreateTexture(nil, "OVERLAY")
    questStarterIcon:SetAllPoints()
    questStarterIcon:SetTexture("Interface\\GossipFrame\\AvailableQuestIcon")
    questStarterFrame:Hide()
    button.questStarterIcon = questStarterFrame

    -- Quest item icon (top left corner) - question mark for regular quest items
    -- Use a frame container to ensure it draws above the border
    local questIconFrame = CreateFrame("Frame", nil, button)
    questIconFrame:SetFrameLevel(button:GetFrameLevel() + Constants.FRAME_LEVELS.QUEST_ICON)
    questIconFrame:SetSize(14, 14)
    questIconFrame:SetPoint("TOPLEFT", button, "TOPLEFT", -4, 2)
    local questIcon = questIconFrame:CreateTexture(nil, "OVERLAY")
    questIcon:SetAllPoints()
    questIcon:SetTexture("Interface\\GossipFrame\\ActiveQuestIcon")
    questIconFrame:Hide()
    button.questIcon = questIconFrame

    -- Override tooltip scripts (prevent template's tooltip from showing)
    button:SetScript("OnEnter", function(self)
        if self.itemID then
            local Tooltip = ns:GetModule("Tooltip")
            local bagID, slotID = FindItemInBags(self.itemID)

            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")

            -- Use SetBagItem if item is in bags (triggers hooks from other addons)
            -- Otherwise fall back to SetItemByID
            if bagID and slotID then
                GameTooltip:SetBagItem(bagID, slotID)
            else
                if GameTooltip.SetItemByID then
                    GameTooltip:SetItemByID(self.itemID)
                else
                    -- SetItemByID is WoD 6.0; SetHyperlink is the pre-6.0 equivalent.
                    local link = select(2, GetItemInfo(self.itemID))
                    if link then GameTooltip:SetHyperlink(link) end
                end
                -- Manually add inventory section since SetItemByID isn't hooked
                if Tooltip then
                    Tooltip:AddInventorySection(GameTooltip, self.itemID)
                end
            end

            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("|cFF00CCCCCtrl+Alt+Click|r to untrack", 0.7, 0.7, 0.7)
            GameTooltip:Show()
        end
    end)

    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- PreClick: only allow item use on right click
    button:SetScript("PreClick", function(self, mouseButton)
        if InCombatLockdown() then return end  -- Can't SetAttribute during combat
        if mouseButton == "RightButton" and not IsShiftKeyDown() and not (IsControlKeyDown() and IsAltKeyDown()) then
            self:SetAttribute("type", "item")
        else
            self:SetAttribute("type", nil)
        end
    end)

    -- PostClick: handle untrack and restore type
    button:SetScript("PostClick", function(self, mouseButton)
        if IsControlKeyDown() and IsAltKeyDown() and self.itemID then
            TrackedBar:UntrackItem(self.itemID)
        end
        -- Restore type for next click (skip during combat)
        if not InCombatLockdown() then
            self:SetAttribute("type", "item")
        end
    end)

    -- OnMouseDown: start bar movement if Shift is held
    button:HookScript("OnMouseDown", function(self, mouseButton)
        if mouseButton == "LeftButton" and IsShiftKeyDown() and not CursorHasItem() and not InCombatLockdown() then
            isDragging = true
            frame:StartMoving()
        end
    end)

    -- OnMouseUp: only handle bar movement stop
    button:HookScript("OnMouseUp", function(self, mouseButton)
        if mouseButton == "LeftButton" and isDragging then
            isDragging = false
            if not InCombatLockdown() then
                frame:StopMovingOrSizing()
            end
            TrackedBar:SavePosition()
        end
    end)

    return button
end

-------------------------------------------------
-- UI Creation
-------------------------------------------------

-- Region map for Masque, used at both initial registration and on live resize
-- (UpdateSize re-registers each button at its new size to re-apply the skin).
local function GetMasqueRegions(button)
    return {
        Icon = button.icon,
        Cooldown = button.cooldown,
        Count = button.count,
        Highlight = button.highlight,
        Normal = button:GetNormalTexture(),
    }
end

local function CreateTrackedBarFrame()
    local buttonSize = GetButtonSize()
    local f = CreateFrame("Frame", "GudaTrackedBar", UIParent, "BackdropTemplate")
    f:SetSize(PADDING * 2, PADDING * 2 + buttonSize)
    f:SetPoint("TOP", UIParent, "TOP", 0, -100)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("MEDIUM")
    f:SetFrameLevel(Constants.FRAME_LEVELS.BASE)

    f:SetBackdrop(nil)

    -- Create item buttons (pool of maximum possible buttons)
    local MasqueModule = ns:GetModule("Masque")
    local masqueActive = MasqueModule and MasqueModule:IsActive()
    for i = 1, MAX_BUTTONS do
        local button = CreateItemButton(f, i)
        button:SetPoint("LEFT", f, "LEFT", PADDING + (i - 1) * (buttonSize + GetButtonSpacing()), 0)
        button:Hide()
        itemButtons[i] = button

        -- Register with Masque if active
        if masqueActive then
            MasqueModule:AddButton(button, "Tracked Items", GetMasqueRegions(button))
        end
    end

    f:Hide()
    return f
end

-------------------------------------------------
-- Button Update
-------------------------------------------------

local function UpdateButton(button, itemID)
    if not itemID then
        button.itemID = nil
        button.border:Hide()
        if button.questStarterIcon then button.questStarterIcon:Hide() end
        if button.questIcon then button.questIcon:Hide() end
        if not InCombatLockdown() then
            button:Hide()
        end
        return
    end

    button.itemID = itemID

    local itemName, itemLink, itemQuality, _, _, _, _, _, _, itemTexture = GetItemInfo(itemID)
    local count = GetItemCount(itemID)

    -- Find item location for cooldown and quest detection
    local bagID, slot = FindItemInBags(itemID)

    -- Store on button for OnClick handler (like Guda does)
    button.bagID = bagID
    button.slotID = slot

    -- Store item name on button for reference
    button.itemName = itemName

    -- Set item attribute for SecureActionButton using item ID format
    -- SetAttribute fails during combat - skip it (button still displays, just can't click to use)
    if not InCombatLockdown() then
        if bagID and slot then
            button:SetAttribute("item", "item:" .. itemID)
        else
            button:SetAttribute("item", nil)
        end
    end

    if itemTexture then
        button.icon:SetTexture(itemTexture)
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

    -- Check for quest items (using cached data)
    local isQuestItem = false
    local isQuestStarter = false
    if bagID and slot then
        local BagScanner = ns:GetModule("BagScanner")
        if BagScanner then
            local cachedBags = BagScanner:GetCachedBags()
            local bagData = cachedBags[bagID]
            if bagData and bagData.slots and bagData.slots[slot] then
                local itemData = bagData.slots[slot]
                isQuestItem = itemData.isQuestItem
                isQuestStarter = itemData.isQuestStarter
            end
        end
    end

    -- Border: quest items get quest color, otherwise quality color (respects settings)
    local showBorder = false
    if itemQuality and itemQuality >= 2 then
        showBorder = Database:GetSetting("equipmentBorders")
    elseif itemQuality and itemQuality == 1 then
        showBorder = Database:GetSetting("otherBorders")
    end

    if isQuestItem then
        local questColor = isQuestStarter and Constants.COLORS.QUEST_STARTER or Constants.COLORS.QUEST
        button.border:SetVertexColor(questColor[1], questColor[2], questColor[3], 1)
        button.border:Show()
    elseif showBorder and itemQuality ~= nil then
        local color = Constants.QUALITY_COLORS[itemQuality]
        if color then
            button.border:SetVertexColor(color[1], color[2], color[3], 1)
            button.border:Show()
        else
            button.border:Hide()
        end
    else
        button.border:Hide()
    end

    -- Quest icons
    if button.questStarterIcon then
        if isQuestStarter then
            button.questStarterIcon:Show()
        else
            button.questStarterIcon:Hide()
        end
    end
    if button.questIcon then
        if isQuestItem and not isQuestStarter then
            button.questIcon:Show()
        else
            button.questIcon:Hide()
        end
    end

    -- Dim if not in bags
    if count == 0 then
        button.icon:SetDesaturated(true)
        button.icon:SetAlpha(0.5)
    else
        button.icon:SetDesaturated(false)
        button.icon:SetAlpha(1)
    end

    if not InCombatLockdown() then
        button:Show()
    end
end

-------------------------------------------------
-- Public API
-------------------------------------------------

function TrackedBar:Init()
    if frame then return end
    frame = CreateTrackedBarFrame()
    self:RestorePosition()
    self:Refresh()
end

function TrackedBar:Show()
    if not frame then self:Init() end
    local trackedItems = Database:GetTrackedItems()
    if #trackedItems > 0 then
        frame:Show()
    end
end

function TrackedBar:Hide()
    if frame then
        frame:Hide()
    end
end

function TrackedBar:Refresh()
    if not frame then return end

    local inCombat = InCombatLockdown()
    local trackedItems = Database:GetTrackedItems()
    local maxColumns = GetMaxColumns()
    local buttonSize = GetButtonSize()
    local visibleCount = math.min(#trackedItems, MAX_BUTTONS)

    -- Calculate rows and columns
    local numRows = math.ceil(visibleCount / maxColumns)
    local numCols = math.min(visibleCount, maxColumns)

    for i = 1, MAX_BUTTONS do
        local itemID = trackedItems[i]
        if itemID and i <= visibleCount then
            UpdateButton(itemButtons[i], itemID)

            -- Layout changes require no combat lockdown
            if not inCombat then
                -- Calculate row and column position (0-indexed)
                local col = (i - 1) % maxColumns
                local row = math.floor((i - 1) / maxColumns)

                -- Position button in grid
                itemButtons[i]:ClearAllPoints()
                itemButtons[i]:SetPoint("TOPLEFT", frame, "TOPLEFT",
                    PADDING + col * (buttonSize + GetButtonSpacing()),
                    -PADDING - row * (buttonSize + GetButtonSpacing()))
            end
        else
            if not inCombat then
                itemButtons[i]:Hide()
                itemButtons[i].itemID = nil
                if itemButtons[i].questStarterIcon then itemButtons[i].questStarterIcon:Hide() end
                if itemButtons[i].questIcon then itemButtons[i].questIcon:Hide() end
            end
        end
    end

    if not inCombat then
        if visibleCount > 0 then
            local width = PADDING * 2 + numCols * buttonSize + (numCols - 1) * GetButtonSpacing()
            local height = PADDING * 2 + numRows * buttonSize + (numRows - 1) * GetButtonSpacing()
            frame:SetWidth(width)
            frame:SetHeight(height)
            frame:Show()
        else
            frame:Hide()
        end
    end
end

function TrackedBar:TrackItem(itemID)
    if not itemID then return false end

    local trackedItems = Database:GetTrackedItems()

    -- Check if already tracked
    for _, id in ipairs(trackedItems) do
        if id == itemID then
            return false
        end
    end

    -- Check max limit (always allow up to MAX_BUTTONS regardless of column setting)
    if #trackedItems >= MAX_BUTTONS then
        ns:Print(string.format(L["TRACK_LIMIT"], MAX_BUTTONS))
        return false
    end

    -- Add to tracked items
    table.insert(trackedItems, itemID)
    Database:SetTrackedItems(trackedItems)

    local itemName = GetItemInfo(itemID)
    ns:Print(string.format(L["NOW_TRACKING"], itemName or L["ITEM"]))

    self:Refresh()

    -- Refresh bag view to show tracked icon
    local BagFrame = ns:GetModule("BagFrame")
    if BagFrame and BagFrame:IsShown() then
        BagFrame:Refresh()
    end

    return true
end

function TrackedBar:UntrackItem(itemID)
    if not itemID then return false end

    local trackedItems = Database:GetTrackedItems()

    for i, id in ipairs(trackedItems) do
        if id == itemID then
            table.remove(trackedItems, i)
            Database:SetTrackedItems(trackedItems)

            local itemName = GetItemInfo(itemID)
            ns:Print(string.format(L["STOPPED_TRACKING"], itemName or L["ITEM"]))

            self:Refresh()

            -- Refresh bag view to hide tracked icon
            local BagFrame = ns:GetModule("BagFrame")
            if BagFrame and BagFrame:IsShown() then
                BagFrame:Refresh()
            end

            return true
        end
    end

    return false
end

function TrackedBar:IsTracked(itemID)
    if not itemID then return false end

    local trackedItems = Database:GetTrackedItems()
    for _, id in ipairs(trackedItems) do
        if id == itemID then
            return true
        end
    end
    return false
end

function TrackedBar:UseItem(itemID)
    local bagID, slot = FindItemInBags(itemID)
    if bagID and slot then
        C_Container.UseContainerItem(bagID, slot)
    end
end

function TrackedBar:UseItemAtSlot(slot)
    local trackedItems = Database:GetTrackedItems()
    local itemID = trackedItems[slot]
    if itemID then
        self:UseItem(itemID)
    end
end

function TrackedBar:ToggleTrackItem(itemID)
    if self:IsTracked(itemID) then
        self:UntrackItem(itemID)
    else
        self:TrackItem(itemID)
    end
end

function TrackedBar:SavePosition()
    if not frame then return end
    local point, _, relPoint, x, y = frame:GetPoint()
    Database:SetSetting("trackedBarPoint", point)
    Database:SetSetting("trackedBarRelPoint", relPoint)
    Database:SetSetting("trackedBarX", x)
    Database:SetSetting("trackedBarY", y)
end

function TrackedBar:RestorePosition()
    if not frame then return end

    local point = Database:GetSetting("trackedBarPoint")
    local relPoint = Database:GetSetting("trackedBarRelPoint")
    local x = Database:GetSetting("trackedBarX")
    local y = Database:GetSetting("trackedBarY")

    if point and x and y then
        frame:ClearAllPoints()
        frame:SetPoint(point, UIParent, relPoint, x, y)
    end
end

function TrackedBar:UpdateFontSize()
    local fontSize = Database:GetSetting("iconFontSize")
    for _, button in ipairs(itemButtons) do
        if button.count then
            Font:Apply(button.count, fontSize, "OUTLINE")
        end
    end
end

function TrackedBar:UpdateSize()
    if not frame then return end
    if InCombatLockdown() then
        pendingResize = true
        return
    end

    local buttonSize = GetButtonSize()
    local questIconSize = math.max(12, math.floor(buttonSize * 0.38))

    local MasqueModule = ns:GetModule("Masque")
    local masqueActive = MasqueModule and MasqueModule:IsActive()

    -- Resize all buttons and re-anchor child elements
    for i, button in ipairs(itemButtons) do
        -- If Masque is active, unregister BEFORE resizing so we can re-register
        -- at the new size — same effect as /reload, where Masque skins each
        -- button at its current (new) size. Group:ReSkin alone is not enough:
        -- it preserves stale region sizing from the original registration.
        if masqueActive then
            MasqueModule:RemoveButton(button)
        end

        button:SetSize(buttonSize, buttonSize)

        -- Re-anchor icon and bg to fill resized button
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

        -- Scale quest indicator frames proportionally
        if button.questStarterIcon then
            button.questStarterIcon:SetSize(questIconSize, questIconSize)
        end
        if button.questIcon then
            button.questIcon:SetSize(questIconSize, questIconSize)
        end

        -- Re-register with Masque so it re-skins the button at its new size.
        if masqueActive then
            MasqueModule:AddButton(button, "Tracked Items", GetMasqueRegions(button))
        end
    end

    -- Refresh to update frame dimensions and reposition buttons
    self:Refresh()
end

-------------------------------------------------
-- Event Handlers
-------------------------------------------------

local function OnBagUpdate()
    if not frame then return end
    -- Skip refreshes during sort (will refresh once via BAGS_UPDATED when sort completes)
    local SortEngine = ns:GetModule("SortEngine")
    if SortEngine and (SortEngine:IsSorting() or SortEngine:IsRestacking()) then return end
    TrackedBar:Refresh()
    -- Schedule a full refresh after combat for layout/attribute updates
    if InCombatLockdown() then
        pendingRefresh = true
    end
end

local function OnCooldownUpdate()
    if not frame then return end
    TrackedBar:Refresh()
end

-------------------------------------------------
-- Initialization
-------------------------------------------------

Events:OnPlayerLogin(function()
    TrackedBar:Init()
    TrackedBar:Show()
end, TrackedBar)

-- Handle setting changes directly (don't rely on BagFrame which may not be open)
Events:Register("SETTING_CHANGED", function(key)
    if key == "trackedBarSize" or key == "trackedBarSpacing" or key == "trackedBarColumns" then
        TrackedBar:UpdateSize()
    elseif key == "iconFontSize" then
        TrackedBar:UpdateFontSize()
    elseif key == "equipmentBorders" or key == "otherBorders" then
        TrackedBar:Refresh()
    end
end, TrackedBar)

-- Apply deferred updates after combat ends
Events:Register("PLAYER_REGEN_ENABLED", function()
    if pendingResize then
        pendingResize = false
        TrackedBar:UpdateSize()
    elseif pendingRefresh then
        pendingRefresh = false
        TrackedBar:Refresh()
    end
end, TrackedBar)

Events:Register("BAG_UPDATE", OnBagUpdate, TrackedBar)
Events:Register("BAG_UPDATE_COOLDOWN", OnCooldownUpdate, TrackedBar)
Events:Register("BAGS_UPDATED", function()
    if frame then TrackedBar:Refresh() end
end, TrackedBar)
