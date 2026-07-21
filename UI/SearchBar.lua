local addonName, ns = ...

local SearchBar = {}
ns:RegisterModule("SearchBar", SearchBar)

local Constants = ns.Constants
local L = ns.L
local SearchParser = ns:GetModule("SearchParser")
local Database = ns:GetModule("Database")
local Font = ns:GetModule("Font")

local instances = {}
local searchOverlay = nil
-- True on clients that cannot support the full-screen click catcher; see
-- CreateSearchOverlay. Callers must treat searchOverlay as optional.
local overlayUnavailable = false

-- Debounce for the search-text notify. Each keystroke triggers a full bag/bank/guild
-- bank Refresh (~tens of ms), so firing per character makes fast typing lag. Coalesce
-- into one refresh shortly after the user stops typing. Clearing is exempt (immediate).
local SEARCH_DEBOUNCE = 0.2

-- Cached globals
local strfind = string.find
local strlower = string.lower
local pairs = pairs
local ipairs = ipairs
local next = next

-------------------------------------------------
-- Quality names for tooltips (indexed 0-7)
-------------------------------------------------
local QUALITY_NAMES = {
    [0] = "CHIP_QUALITY_POOR",
    [1] = "CHIP_QUALITY_COMMON",
    [2] = "CHIP_QUALITY_UNCOMMON",
    [3] = "CHIP_QUALITY_RARE",
    [4] = "CHIP_QUALITY_EPIC",
    [5] = "CHIP_QUALITY_LEGENDARY",
    [6] = "CHIP_QUALITY_ARTIFACT",
    [7] = "CHIP_QUALITY_HEIRLOOM",
}

-------------------------------------------------
-- Type chip definitions: {key, localeKey, itemType}
-------------------------------------------------
local TYPE_CHIPS = {
    {key = "Weapon",       localeKey = "CHIP_TYPE_WPN"},
    {key = "Armor",        localeKey = "CHIP_TYPE_ARM"},
    {key = "Consumable",   localeKey = "CHIP_TYPE_CON"},
    {key = "Trade Goods",  localeKey = "CHIP_TYPE_TRD"},
    {key = "Quest",        localeKey = "CHIP_TYPE_QST"},
    {key = "Junk",         localeKey = "CHIP_TYPE_JNK"},
}

-------------------------------------------------
-- Special chip definitions: {key, localeKey}
-------------------------------------------------
local SPECIAL_CHIPS = {
    {key = "boe", localeKey = "CHIP_SPECIAL_BOE"},
    {key = "new", localeKey = "CHIP_SPECIAL_NEW"},
    {key = "openable", localeKey = "CHIP_SPECIAL_OPENABLE"},
    {key = "learnable", localeKey = "CHIP_SPECIAL_LEARNABLE"},
}

-------------------------------------------------
-- Search Overlay (shared across instances)
-------------------------------------------------
local function CreateSearchOverlay()
    if searchOverlay then return end

    -- This is a FULL-SCREEN, mouse-enabled click catcher. It only works because
    -- SetPropagateMouseClicks/MouseMotion (Dragonflight 10.x) let the click pass
    -- THROUGH to whatever is underneath while still notifying us.
    --
    -- Without them the overlay simply eats every click in the game: you cannot
    -- cast, loot, turn the camera or click the world at all for as long as the
    -- search box has focus. Pre-10.x there is no way to make it behave, so on
    -- those clients we do not create it. Losing focus by pressing Escape/Enter,
    -- or clicking another edit box, still works -- only the click-anywhere-to-
    -- dismiss convenience is gone, which is a fair trade for a usable mouse.
    local probe = CreateFrame("Button", nil, UIParent)
    local canPropagate = probe.SetPropagateMouseClicks ~= nil
    probe:Hide()
    probe:EnableMouse(false)
    if not canPropagate then
        overlayUnavailable = true
        return
    end

    local overlay = CreateFrame("Button", "GudaBagsSearchOverlay", UIParent)
    overlay:SetAllPoints(UIParent)
    overlay:SetFrameStrata("FULLSCREEN_DIALOG")
    overlay:SetFrameLevel(100)
    overlay:EnableMouse(true)
    overlay:Hide()

    if overlay.SetPropagateMouseMotion then
        overlay:SetPropagateMouseMotion(true)
    else
        if overlay.SetMouseMotionEnabled then
            overlay:SetMouseMotionEnabled(false)
        end
    end

    if overlay.SetPropagateMouseClicks then
        overlay:SetPropagateMouseClicks(true)
    end

    overlay:SetScript("OnMouseDown", function()
        for _, instance in pairs(instances) do
            if instance.searchBox then
                instance.searchBox:ClearFocus()
            end
        end
        overlay:Hide()
    end)

    searchOverlay = overlay
end

-------------------------------------------------
-- Click-away without a full-screen overlay
-------------------------------------------------
-- The overlay above cannot be used pre-10.x: without SetPropagateMouseClicks a
-- screen-sized mouse-enabled frame swallows every click in the game. Rather than
-- lose click-to-dismiss entirely, get the same behaviour from events.
--
-- Purely event-driven -- no OnUpdate polling, per docs\RULES.md rule 2.

local function ClearAllSearchFocus()
    for _, instance in pairs(instances) do
        local box = instance.searchBox
        -- HasFocus() keeps this free on the overwhelmingly common path: these
        -- hooks fire on every world click.
        if box and box.HasFocus and box:HasFocus() then
            box:ClearFocus()
        end
    end
end

local worldClickAwayHooked = false

--- Dismiss search focus on a click outside the box.
--- Two sources cover the realistic cases:
---   * WorldFrame  -- clicking the 3D world, i.e. "click away" proper.
---   * the owning GudaBags frame -- clicking its background. Clicks that land on
---     a child (item button, control) are consumed by that child and correctly
---     do NOT dismiss, which matches how the overlay behaved.
--- HookScript is additive, so nothing existing is displaced and no input is
--- intercepted -- the click still reaches whatever it was aimed at.
local function InstallLegacyClickAway(parent)
    if searchOverlay then return end   -- real overlay is in use; nothing to do

    if not worldClickAwayHooked and WorldFrame and WorldFrame.HookScript then
        worldClickAwayHooked = true
        WorldFrame:HookScript("OnMouseDown", ClearAllSearchFocus)
    end

    if parent and parent.HookScript and not parent._gbSearchClickAway then
        parent._gbSearchClickAway = true
        parent:HookScript("OnMouseDown", ClearAllSearchFocus)
    end
end

-------------------------------------------------
-- Filter State (per instance)
-------------------------------------------------
local function CreateFilterState()
    return {
        qualities = {},   -- {[3]=true, [4]=true}
        types = {},       -- {["Weapon"]=true}
        specials = {},    -- {["boe"]=true}
        parsed = nil,     -- result of SearchParser:ParseSearchInput()
        equipSet = nil,   -- string: active equipment set name filter
    }
end

local function HasAnyFilter(state)
    if next(state.qualities) then return true end
    if next(state.types) then return true end
    if next(state.specials) then return true end
    if state.parsed then return true end
    if state.equipSet then return true end
    return false
end

-------------------------------------------------
-- Chip Strip UI
-------------------------------------------------

local function UpdateChipStripVisibility(searchBar)
    local state = searchBar.filterState
    local hasChips = next(state.qualities) or next(state.types) or next(state.specials)
    if searchBar.chipClearButton then
        if hasChips then
            searchBar.chipClearButton:Show()
        else
            searchBar.chipClearButton:Hide()
        end
    end
end

local function UpdateTransferButton(searchBar)
    local btn = searchBar.transferButton
    if not btn then return end

    local state = searchBar.filterState
    if not HasAnyFilter(state) then
        btn:Hide()
        return
    end

    if not searchBar.getTransferTarget then
        btn:Hide()
        return
    end

    local target = searchBar.getTransferTarget()
    if not target then
        btn:Hide()
        return
    end

    searchBar.transferTarget = target
    btn:Show()
end

local function NotifyFilterChanged(searchBar)
    UpdateChipStripVisibility(searchBar)
    UpdateTransferButton(searchBar)
    -- Show/hide clear button based on any active filter
    if searchBar.clearButton then
        local hasText = searchBar.searchText and searchBar.searchText ~= ""
        if hasText or HasAnyFilter(searchBar.filterState) then
            searchBar.clearButton:Show()
        elseif not hasText then
            searchBar.clearButton:Hide()
        end
    end
    -- Update equip set button color when active
    if searchBar.equipSetButton then
        if searchBar.filterState.equipSet then
            searchBar.equipSetButton.icon:SetVertexColor(1, 0.82, 0)
        else
            searchBar.equipSetButton.icon:SetVertexColor(0.6, 0.6, 0.6)
        end
    end
    if searchBar.onSearchChanged then
        searchBar.onSearchChanged(searchBar.searchText or "")
    end
end

local function CreateQualityDot(chipStrip, qualityIndex, searchBar)
    local colors = Constants.QUALITY_COLORS[qualityIndex]
    if not colors then return nil end

    local size = Constants.FRAME.CHIP_SIZE
    local btn = CreateFrame("Button", nil, chipStrip)
    btn:SetSize(size, size)

    -- Color dot texture
    local dot = btn:CreateTexture(nil, "ARTWORK")
    dot:SetSize(size - 4, size - 4)
    dot:SetPoint("CENTER")
    dot:SetTexture("Interface\\Buttons\\WHITE8x8")
    dot:SetVertexColor(colors[1], colors[2], colors[3])
    btn.dot = dot

    -- Border highlight (visible when active)
    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetAllPoints()
    border:SetTexture("Interface\\Buttons\\WHITE8x8")
    border:SetVertexColor(colors[1], colors[2], colors[3], 0.6)
    border:Hide()
    btn.border = border

    -- Start inactive
    dot:SetAlpha(0.35)

    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        local nameKey = QUALITY_NAMES[qualityIndex]
        GameTooltip:SetText(L[nameKey] or nameKey, colors[1], colors[2], colors[3])
        GameTooltip:Show()
        if not searchBar.filterState.qualities[qualityIndex] then
            self.dot:SetAlpha(0.6)
        end
    end)

    btn:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
        if not searchBar.filterState.qualities[qualityIndex] then
            self.dot:SetAlpha(0.35)
        end
    end)

    btn:SetScript("OnClick", function(self)
        local state = searchBar.filterState
        if state.qualities[qualityIndex] then
            state.qualities[qualityIndex] = nil
            self.dot:SetAlpha(0.35)
            self.border:Hide()
        else
            state.qualities[qualityIndex] = true
            self.dot:SetAlpha(1.0)
            self.border:Show()
        end
        NotifyFilterChanged(searchBar)
    end)

    btn.qualityIndex = qualityIndex
    return btn
end

local function CreateFilterChip(chipStrip, chipDef, searchBar, filterCategory, activeColor)
    local btn = CreateFrame("Button", nil, chipStrip)
    local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    Font:Override(label)
    label:SetPoint("CENTER", 0, 0)
    label:SetText(L[chipDef.localeKey] or chipDef.key)
    btn.label = label

    local textWidth = label:GetStringWidth() or 20
    btn:SetSize(textWidth + 10, Constants.FRAME.CHIP_SIZE)

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture("Interface\\Buttons\\WHITE8x8")
    bg:SetVertexColor(0.15, 0.15, 0.15, 0.8)
    btn.bg = bg

    label:SetTextColor(0.55, 0.55, 0.55)

    btn:SetScript("OnEnter", function(self)
        if not searchBar.filterState[filterCategory][chipDef.key] then
            self.bg:SetVertexColor(0.25, 0.25, 0.25, 0.8)
        end
    end)

    btn:SetScript("OnLeave", function(self)
        if not searchBar.filterState[filterCategory][chipDef.key] then
            self.bg:SetVertexColor(0.15, 0.15, 0.15, 0.8)
        end
    end)

    btn:SetScript("OnClick", function(self)
        local state = searchBar.filterState
        if state[filterCategory][chipDef.key] then
            state[filterCategory][chipDef.key] = nil
            self.label:SetTextColor(0.55, 0.55, 0.55)
            self.bg:SetVertexColor(0.15, 0.15, 0.15, 0.8)
        else
            state[filterCategory][chipDef.key] = true
            self.label:SetTextColor(1, 1, 1)
            self.bg:SetVertexColor(activeColor[1], activeColor[2], activeColor[3], activeColor[4])
        end
        NotifyFilterChanged(searchBar)
    end)

    btn.chipKey = chipDef.key
    return btn
end

local TYPE_CHIP_COLOR = {0.7, 0.55, 0.0, 0.9}
local SPECIAL_CHIP_COLOR = {0.2, 0.6, 0.8, 0.9}

local function CreateTypeChip(chipStrip, chipDef, searchBar)
    return CreateFilterChip(chipStrip, chipDef, searchBar, "types", TYPE_CHIP_COLOR)
end

local function CreateSpecialChip(chipStrip, chipDef, searchBar)
    return CreateFilterChip(chipStrip, chipDef, searchBar, "specials", SPECIAL_CHIP_COLOR)
end

-- Forward declaration (defined later with dropdown logic)
local UpdateDropdownLabel

local function ResetChipVisuals(searchBar)
    -- Reset quality dots
    if searchBar.qualityDots then
        for _, dot in ipairs(searchBar.qualityDots) do
            dot.dot:SetAlpha(0.35)
            dot.border:Hide()
        end
    end
    -- Reset type chips
    if searchBar.typeChips then
        for _, chip in ipairs(searchBar.typeChips) do
            chip.label:SetTextColor(0.55, 0.55, 0.55)
            chip.bg:SetVertexColor(0.15, 0.15, 0.15, 0.8)
        end
    end
    -- Reset special chips
    if searchBar.specialChips then
        for _, chip in ipairs(searchBar.specialChips) do
            chip.label:SetTextColor(0.55, 0.55, 0.55)
            chip.bg:SetVertexColor(0.15, 0.15, 0.15, 0.8)
        end
    end
    -- Reset dropdown label
    if searchBar.typesDropdown then
        UpdateDropdownLabel(searchBar)
    end
end

local function ClearEquipSetFilter(searchBar)
    if searchBar.equipSetButton then
        searchBar.equipSetButton.activeText:SetText("")
        searchBar.equipSetButton.activeText:Hide()
        searchBar.equipSetButton.icon:SetVertexColor(0.6, 0.6, 0.6)
        if searchBar.searchIcon then
            searchBar.searchIcon:ClearAllPoints()
            searchBar.searchIcon:SetPoint("LEFT", searchBar.equipSetButton, "RIGHT", 4, 0)
        end
    end
    -- Restore placeholder if no text
    if searchBar.searchBox and searchBar.searchBox:GetText() == "" then
        if searchBar.searchBox.placeholder then
            searchBar.searchBox.placeholder:Show()
        end
    end
end

-------------------------------------------------
-- Chip Layout Overflow — collapse type/special chips into dropdown
-------------------------------------------------
local typesDropdownMenu = nil  -- shared dropdown menu frame

UpdateDropdownLabel = function(searchBar)
    local dropdown = searchBar.typesDropdown
    if not dropdown then return end

    local activeCount = 0
    local state = searchBar.filterState
    for _ in pairs(state.types) do activeCount = activeCount + 1 end
    for _ in pairs(state.specials) do activeCount = activeCount + 1 end

    local iconWidth = dropdown.icon and (dropdown.icon:GetWidth() + 3) or 0
    if activeCount > 0 then
        dropdown.label:SetText((L["CHIP_TYPES_DROPDOWN"] or "Types") .. " (" .. activeCount .. ")")
        dropdown.label:SetTextColor(1, 1, 1)
        dropdown.bg:SetVertexColor(0.7, 0.55, 0.0, 0.9)
        if dropdown.icon then dropdown.icon:SetVertexColor(1, 1, 1) end
    else
        dropdown.label:SetText((L["CHIP_TYPES_DROPDOWN"] or "Types") .. "")
        dropdown.label:SetTextColor(0.55, 0.55, 0.55)
        dropdown.bg:SetVertexColor(0.15, 0.15, 0.15, 0.8)
        if dropdown.icon then dropdown.icon:SetVertexColor(0.55, 0.55, 0.55) end
    end
    dropdown:SetWidth(iconWidth + dropdown.label:GetStringWidth() + 10)
end

local function ShowTypesDropdownMenu(searchBar, anchor)
    if not typesDropdownMenu then
        typesDropdownMenu = CreateFrame("Frame", "GudaBagsTypesDropdown", UIParent, "BackdropTemplate")
        typesDropdownMenu:SetFrameStrata("TOOLTIP")
        typesDropdownMenu:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 10,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        typesDropdownMenu:SetBackdropColor(0.1, 0.1, 0.1, 0.95)
        typesDropdownMenu:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.9)
        typesDropdownMenu:EnableMouse(true)  -- Block mouse from reaching items behind
        typesDropdownMenu:Hide()
        typesDropdownMenu.items = {}
    end

    -- If already showing for this searchBar, toggle off
    if typesDropdownMenu:IsShown() and typesDropdownMenu.owner == searchBar then
        typesDropdownMenu:Hide()
        return
    end
    typesDropdownMenu.owner = searchBar

    -- Clear old items
    for _, item in ipairs(typesDropdownMenu.items) do
        item:Hide()
    end

    local yOffset = -4
    local maxWidth = 0
    local itemIndex = 0

    -- Add type chips
    for _, chipDef in ipairs(TYPE_CHIPS) do
        itemIndex = itemIndex + 1
        local item = typesDropdownMenu.items[itemIndex]
        if not item then
            item = CreateFrame("Button", nil, typesDropdownMenu)
            item:SetHeight(18)
            local itemLabel = item:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            Font:Override(itemLabel)
            itemLabel:SetPoint("LEFT", 6, 0)
            item.label = itemLabel
            local itemBg = item:CreateTexture(nil, "BACKGROUND")
            itemBg:SetAllPoints()
            itemBg:SetTexture("Interface\\Buttons\\WHITE8x8")
            itemBg:SetVertexColor(0, 0, 0, 0)
            item.bg = itemBg
            typesDropdownMenu.items[itemIndex] = item
        end

        item.label:SetText(L[chipDef.localeKey] or chipDef.key)
        item.chipKey = chipDef.key
        item.chipCategory = "types"
        item:SetPoint("TOPLEFT", typesDropdownMenu, "TOPLEFT", 4, yOffset)
        item:SetPoint("TOPRIGHT", typesDropdownMenu, "TOPRIGHT", -4, yOffset)

        -- Set visual state
        if searchBar.filterState.types[chipDef.key] then
            item.label:SetTextColor(1, 1, 1)
            item.bg:SetVertexColor(0.7, 0.55, 0.0, 0.6)
        else
            item.label:SetTextColor(0.7, 0.7, 0.7)
            item.bg:SetVertexColor(0, 0, 0, 0)
        end

        item:SetScript("OnEnter", function(self)
            if not searchBar.filterState.types[self.chipKey] then
                self.bg:SetVertexColor(0.25, 0.25, 0.25, 0.8)
            end
        end)
        item:SetScript("OnLeave", function(self)
            if not searchBar.filterState.types[self.chipKey] then
                self.bg:SetVertexColor(0, 0, 0, 0)
            end
        end)
        item:SetScript("OnClick", function(self)
            local state = searchBar.filterState
            if state.types[self.chipKey] then
                state.types[self.chipKey] = nil
                self.label:SetTextColor(0.7, 0.7, 0.7)
                self.bg:SetVertexColor(0, 0, 0, 0)
            else
                state.types[self.chipKey] = true
                self.label:SetTextColor(1, 1, 1)
                self.bg:SetVertexColor(0.7, 0.55, 0.0, 0.6)
            end
            -- Also update inline chip visuals if they exist
            for _, chip in ipairs(searchBar.typeChips) do
                if chip.chipKey == self.chipKey then
                    if state.types[self.chipKey] then
                        chip.label:SetTextColor(1, 1, 1)
                        chip.bg:SetVertexColor(0.7, 0.55, 0.0, 0.9)
                    else
                        chip.label:SetTextColor(0.55, 0.55, 0.55)
                        chip.bg:SetVertexColor(0.15, 0.15, 0.15, 0.8)
                    end
                end
            end
            UpdateDropdownLabel(searchBar)
            NotifyFilterChanged(searchBar)
        end)

        local w = item.label:GetStringWidth() + 16
        if w > maxWidth then maxWidth = w end
        yOffset = yOffset - 18
        item:Show()
    end

    -- Add separator
    yOffset = yOffset - 4

    -- Add special chips
    for _, chipDef in ipairs(SPECIAL_CHIPS) do
        itemIndex = itemIndex + 1
        local item = typesDropdownMenu.items[itemIndex]
        if not item then
            item = CreateFrame("Button", nil, typesDropdownMenu)
            item:SetHeight(18)
            local itemLabel = item:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            Font:Override(itemLabel)
            itemLabel:SetPoint("LEFT", 6, 0)
            item.label = itemLabel
            local itemBg = item:CreateTexture(nil, "BACKGROUND")
            itemBg:SetAllPoints()
            itemBg:SetTexture("Interface\\Buttons\\WHITE8x8")
            itemBg:SetVertexColor(0, 0, 0, 0)
            item.bg = itemBg
            typesDropdownMenu.items[itemIndex] = item
        end

        item.label:SetText(L[chipDef.localeKey] or chipDef.key)
        item.chipKey = chipDef.key
        item.chipCategory = "specials"
        item:SetPoint("TOPLEFT", typesDropdownMenu, "TOPLEFT", 4, yOffset)
        item:SetPoint("TOPRIGHT", typesDropdownMenu, "TOPRIGHT", -4, yOffset)

        if searchBar.filterState.specials[chipDef.key] then
            item.label:SetTextColor(1, 1, 1)
            item.bg:SetVertexColor(0.2, 0.6, 0.8, 0.6)
        else
            item.label:SetTextColor(0.7, 0.7, 0.7)
            item.bg:SetVertexColor(0, 0, 0, 0)
        end

        item:SetScript("OnEnter", function(self)
            if not searchBar.filterState.specials[self.chipKey] then
                self.bg:SetVertexColor(0.25, 0.25, 0.25, 0.8)
            end
        end)
        item:SetScript("OnLeave", function(self)
            if not searchBar.filterState.specials[self.chipKey] then
                self.bg:SetVertexColor(0, 0, 0, 0)
            end
        end)
        item:SetScript("OnClick", function(self)
            local state = searchBar.filterState
            if state.specials[self.chipKey] then
                state.specials[self.chipKey] = nil
                self.label:SetTextColor(0.7, 0.7, 0.7)
                self.bg:SetVertexColor(0, 0, 0, 0)
            else
                state.specials[self.chipKey] = true
                self.label:SetTextColor(1, 1, 1)
                self.bg:SetVertexColor(0.2, 0.6, 0.8, 0.6)
            end
            for _, chip in ipairs(searchBar.specialChips) do
                if chip.chipKey == self.chipKey then
                    if state.specials[self.chipKey] then
                        chip.label:SetTextColor(1, 1, 1)
                        chip.bg:SetVertexColor(0.2, 0.6, 0.8, 0.9)
                    else
                        chip.label:SetTextColor(0.55, 0.55, 0.55)
                        chip.bg:SetVertexColor(0.15, 0.15, 0.15, 0.8)
                    end
                end
            end
            UpdateDropdownLabel(searchBar)
            NotifyFilterChanged(searchBar)
        end)

        local w = item.label:GetStringWidth() + 16
        if w > maxWidth then maxWidth = w end
        yOffset = yOffset - 18
        item:Show()
    end

    typesDropdownMenu:SetSize(math.max(maxWidth, 80), -yOffset + 4)
    typesDropdownMenu:ClearAllPoints()
    typesDropdownMenu:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
    typesDropdownMenu:Show()

    -- Close on click outside
    typesDropdownMenu:SetScript("OnUpdate", function(self)
        if not MouseIsOver(self) and not MouseIsOver(anchor) then
            if IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton") then
                self:Hide()
            end
        end
    end)
end

local CHIP_COLLAPSE_WIDTH = 420

local function UpdateChipLayout(searchBar)
    local chipStrip = searchBar.chipStrip
    if not chipStrip or not chipStrip:IsShown() then return end
    -- Skip when narrow mode is active — SetNarrowMode handles layout
    if searchBar.isNarrowMode then return end

    local availableWidth = chipStrip:GetWidth()
    if availableWidth <= 0 then return end

    -- Collapse when the inline chips can't fit. Prefer the measured natural width
    -- (set when the chips were laid out) so adding/removing chips or switching
    -- locale never overflows; fall back to the constant if not measured yet.
    local collapseWidth = searchBar.chipsNaturalWidth or CHIP_COLLAPSE_WIDTH
    if availableWidth < collapseWidth then
        -- Collapse: hide type/special chips and separators, show dropdown
        for _, chip in ipairs(searchBar.typeChips) do chip:Hide() end
        for _, chip in ipairs(searchBar.specialChips) do chip:Hide() end
        if searchBar.chipSep1 then searchBar.chipSep1:Hide() end
        if searchBar.chipSep2 then searchBar.chipSep2:Hide() end

        local spacing = Constants.FRAME.CHIP_SPACING
        local chipSize = Constants.FRAME.CHIP_SIZE
        local qualityWidth = 4 + (#searchBar.qualityDots * (chipSize + spacing))
        local sepWidth = 2 + 1 + spacing

        local dropdown = searchBar.typesDropdown
        if dropdown then
            dropdown:ClearAllPoints()
            dropdown:SetPoint("LEFT", chipStrip, "LEFT", qualityWidth + sepWidth, 0)
            dropdown:Show()
            UpdateDropdownLabel(searchBar)
        end
    else
        -- Normal: show all chips as buttons, hide dropdown
        for _, chip in ipairs(searchBar.typeChips) do chip:Show() end
        for _, chip in ipairs(searchBar.specialChips) do chip:Show() end
        if searchBar.chipSep1 then searchBar.chipSep1:Show() end
        if searchBar.chipSep2 then searchBar.chipSep2:Show() end
        if searchBar.typesDropdown then searchBar.typesDropdown:Hide() end
    end
end

local function CreateChipStrip(searchBar, parent)
    local chipStrip = CreateFrame("Frame", nil, parent)
    chipStrip:SetHeight(Constants.FRAME.CHIP_STRIP_HEIGHT)
    chipStrip:SetPoint("TOPLEFT", searchBar, "BOTTOMLEFT", 0, -1)
    chipStrip:SetPoint("TOPRIGHT", searchBar, "BOTTOMRIGHT", 0, -1)

    local spacing = Constants.FRAME.CHIP_SPACING
    local xOffset = 4

    -- Quality dots (0-7)
    searchBar.qualityDots = {}
    for q = 0, 7 do
        local dot = CreateQualityDot(chipStrip, q, searchBar)
        if dot then
            dot:SetPoint("LEFT", chipStrip, "LEFT", xOffset, 0)
            xOffset = xOffset + Constants.FRAME.CHIP_SIZE + spacing
            searchBar.qualityDots[#searchBar.qualityDots + 1] = dot
        end
    end

    -- Small separator
    xOffset = xOffset + 2
    local sep1 = chipStrip:CreateTexture(nil, "ARTWORK")
    sep1:SetSize(1, Constants.FRAME.CHIP_SIZE - 2)
    sep1:SetPoint("LEFT", chipStrip, "LEFT", xOffset, 0)
    sep1:SetTexture("Interface\\Buttons\\WHITE8x8")
    sep1:SetVertexColor(0.3, 0.3, 0.3, 0.5)
    searchBar.chipSep1 = sep1
    xOffset = xOffset + 1 + spacing

    -- Type chips
    searchBar.typeChips = {}
    for _, chipDef in ipairs(TYPE_CHIPS) do
        local chip = CreateTypeChip(chipStrip, chipDef, searchBar)
        chip:SetPoint("LEFT", chipStrip, "LEFT", xOffset, 0)
        xOffset = xOffset + chip:GetWidth() + spacing
        searchBar.typeChips[#searchBar.typeChips + 1] = chip
    end

    -- Separator
    xOffset = xOffset + 2
    local sep2 = chipStrip:CreateTexture(nil, "ARTWORK")
    sep2:SetSize(1, Constants.FRAME.CHIP_SIZE - 2)
    sep2:SetPoint("LEFT", chipStrip, "LEFT", xOffset, 0)
    sep2:SetTexture("Interface\\Buttons\\WHITE8x8")
    sep2:SetVertexColor(0.3, 0.3, 0.3, 0.5)
    searchBar.chipSep2 = sep2
    xOffset = xOffset + 1 + spacing

    -- Special chips
    searchBar.specialChips = {}
    for _, chipDef in ipairs(SPECIAL_CHIPS) do
        local chip = CreateSpecialChip(chipStrip, chipDef, searchBar)
        chip:SetPoint("LEFT", chipStrip, "LEFT", xOffset, 0)
        xOffset = xOffset + chip:GetWidth() + spacing
        searchBar.specialChips[#searchBar.specialChips + 1] = chip
    end

    -- Width the inline chips actually need (plus a small right margin). Used as the
    -- collapse threshold so it self-adjusts to chip count and per-locale label widths.
    searchBar.chipsNaturalWidth = xOffset + 4

    -- Types dropdown button (hidden by default, shown on overflow)
    local typesDropdown = CreateFrame("Button", nil, chipStrip)
    typesDropdown:SetHeight(Constants.FRAME.CHIP_SIZE)
    -- Filter icon
    local dropIcon = typesDropdown:CreateTexture(nil, "ARTWORK")
    dropIcon:SetSize(10, 10)
    dropIcon:SetPoint("LEFT", typesDropdown, "LEFT", 4, 0)
    dropIcon:SetTexture("Interface\\AddOns\\GudaBags\\Assets\\categories.tga")
    dropIcon:SetVertexColor(0.55, 0.55, 0.55)
    typesDropdown.icon = dropIcon
    -- Label
    local dropLabel = typesDropdown:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    Font:Override(dropLabel)
    dropLabel:SetPoint("LEFT", dropIcon, "RIGHT", 3, 0)
    dropLabel:SetText((L["CHIP_TYPES_DROPDOWN"] or "Types") .. "")
    dropLabel:SetTextColor(0.55, 0.55, 0.55)
    typesDropdown.label = dropLabel
    local dropBg = typesDropdown:CreateTexture(nil, "BACKGROUND")
    dropBg:SetAllPoints()
    dropBg:SetTexture("Interface\\Buttons\\WHITE8x8")
    dropBg:SetVertexColor(0.15, 0.15, 0.15, 0.8)
    typesDropdown.bg = dropBg
    typesDropdown:SetWidth(dropIcon:GetWidth() + 3 + dropLabel:GetStringWidth() + 10)
    typesDropdown:Hide()
    typesDropdown:SetScript("OnEnter", function(self)
        local state = searchBar.filterState
        local hasActive = next(state.types) or next(state.specials)
        if not hasActive then
            self.bg:SetVertexColor(0.25, 0.25, 0.25, 0.8)
            if self.icon then self.icon:SetVertexColor(0.8, 0.8, 0.8) end
        end
    end)
    typesDropdown:SetScript("OnLeave", function(self)
        local state = searchBar.filterState
        local hasActive = next(state.types) or next(state.specials)
        if not hasActive then
            self.bg:SetVertexColor(0.15, 0.15, 0.15, 0.8)
            if self.icon then self.icon:SetVertexColor(0.55, 0.55, 0.55) end
        end
    end)
    typesDropdown:SetScript("OnClick", function(self)
        ShowTypesDropdownMenu(searchBar, self)
    end)
    searchBar.typesDropdown = typesDropdown

    -- Clear-all button at far right
    local clearAll = CreateFrame("Button", nil, chipStrip)
    clearAll:SetSize(12, 12)
    clearAll:SetPoint("RIGHT", chipStrip, "RIGHT", -4, 0)
    clearAll:Hide()

    local clearIcon = clearAll:CreateTexture(nil, "ARTWORK")
    clearIcon:SetAllPoints()
    clearIcon:SetTexture("Interface\\AddOns\\GudaBags\\Assets\\close.tga")
    clearIcon:SetVertexColor(0.5, 0.5, 0.5)
    clearAll.icon = clearIcon

    clearAll:SetScript("OnEnter", function(self)
        self.icon:SetVertexColor(0.8, 0.8, 0.8)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(L["CHIP_CLEAR_ALL"] or "Clear all filters")
        GameTooltip:Show()
    end)
    clearAll:SetScript("OnLeave", function(self)
        self.icon:SetVertexColor(0.5, 0.5, 0.5)
        GameTooltip:Hide()
    end)
    clearAll:SetScript("OnClick", function()
        local state = searchBar.filterState
        state.qualities = {}
        state.types = {}
        state.specials = {}
        ResetChipVisuals(searchBar)
        UpdateDropdownLabel(searchBar)
        -- Close dropdown menu if open
        if typesDropdownMenu and typesDropdownMenu:IsShown() then
            typesDropdownMenu:Hide()
        end
        NotifyFilterChanged(searchBar)
    end)

    searchBar.chipClearButton = clearAll
    searchBar.chipStrip = chipStrip

    -- Detect width changes and update chip layout (collapse/expand)
    chipStrip:SetScript("OnSizeChanged", function()
        UpdateChipLayout(searchBar)
    end)

    return chipStrip
end

-------------------------------------------------
-- Equipment Set Dropdown
-------------------------------------------------
local equipSetDropdown = nil

local function CreateEquipSetDropdown()
    if equipSetDropdown then return equipSetDropdown end

    local DROPDOWN_WIDTH = 150
    local ROW_HEIGHT = 20
    local PADDING = 6
    local MAX_VISIBLE_ROWS = 8

    local f = CreateFrame("Frame", "GudaBagsEquipSetDropdown", UIParent, "BackdropTemplate")
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(200)
    f:SetSize(DROPDOWN_WIDTH, 100)
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14,
        insets = {left = 3, right = 3, top = 3, bottom = 3},
    })
    f:SetBackdropColor(0.1, 0.1, 0.1, 0.95)
    f:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:Hide()

    f:SetScript("OnShow", function()
        -- GLOBAL_MOUSE_DOWN is Legion+; RegisterEvent RAISES on an unknown event

        -- name pre-Legion, so this must be guarded. Without it the dropdown

        -- simply stays open until clicked or toggled again.

        pcall(f.RegisterEvent, f, "GLOBAL_MOUSE_DOWN")
    end)
    f:SetScript("OnHide", function()
        pcall(f.UnregisterEvent, f, "GLOBAL_MOUSE_DOWN")
    end)
    f:SetScript("OnEvent", function(self, event)
        if event == "GLOBAL_MOUSE_DOWN" then
            if not self:IsMouseOver() then
                self:Hide()
            end
        end
    end)

    -- NAMED deliberately: pre-Cata the scroll bar exists only as the global
    -- $parentScrollBar, and the lookup below concatenates GetName().
    local scrollFrame = CreateFrame("ScrollFrame", "GudaBagsSearchHistoryScroll", f,
                                    "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", PADDING, -PADDING)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PADDING - 20, PADDING)
    f.scrollFrame = scrollFrame

    local scrollBar = scrollFrame.ScrollBar or _G[scrollFrame:GetName() and (scrollFrame:GetName() .. "ScrollBar")]
    if scrollBar then
        scrollBar:SetAlpha(0.7)
    end

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(DROPDOWN_WIDTH - PADDING * 2 - 20, 100)
    scrollFrame:SetScrollChild(content)
    f.content = content
    f.rows = {}
    f.searchBar = nil  -- set when showing

    local function CreateRow(parent, index)
        local row = CreateFrame("Button", nil, parent)
        row:SetHeight(ROW_HEIGHT)
        row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -((index - 1) * ROW_HEIGHT))
        row:SetPoint("RIGHT", parent, "RIGHT", 0, 0)

        local highlight = row:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetAllPoints()
        highlight:SetTexture("Interface\\Buttons\\WHITE8x8")
        highlight:SetVertexColor(1, 1, 1, 0.1)

        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetSize(14, 14)
        icon:SetPoint("LEFT", row, "LEFT", 2, 0)
        icon:SetTexture("Interface\\AddOns\\GudaBags\\Assets\\equipment.tga")
        icon:SetVertexColor(1, 0.82, 0)
        row.icon = icon

        local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        Font:Override(nameText)
        nameText:SetPoint("LEFT", icon, "RIGHT", 4, 0)
        nameText:SetPoint("RIGHT", row, "RIGHT", -2, 0)
        nameText:SetJustifyH("LEFT")
        row.nameText = nameText

        return row
    end

    function f:Populate(searchBar)
        f.searchBar = searchBar
        local EquipmentSets = ns:GetModule("EquipmentSets")
        if not EquipmentSets then return end

        local setNames = EquipmentSets:GetAllSetNames()
        if not setNames or #setNames == 0 then return end

        -- Build mark lookup from category definitions
        local CategoryManager = ns:GetModule("CategoryManager")
        local catDefs = CategoryManager and CategoryManager:GetCategories()
        local markBySet = {}
        if catDefs and catDefs.definitions then
            for _, setName in ipairs(setNames) do
                local def = catDefs.definitions["EquipSet:" .. setName]
                if def and def.categoryMark then
                    markBySet[setName] = def.categoryMark
                end
            end
        end

        local activeSet = searchBar.filterState.equipSet
        local rowCount = #setNames
        local contentHeight = rowCount * ROW_HEIGHT
        local visibleHeight = math.min(rowCount, MAX_VISIBLE_ROWS) * ROW_HEIGHT

        local needsScrollBar = rowCount > MAX_VISIBLE_ROWS
        local scrollBar = f.scrollFrame.ScrollBar or _G[f.scrollFrame:GetName() and (f.scrollFrame:GetName() .. "ScrollBar")]
        local scrollBarWidth = needsScrollBar and 20 or 0

        if scrollBar then
            if needsScrollBar then scrollBar:Show() else scrollBar:Hide() end
        end

        f.scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PADDING - scrollBarWidth, PADDING)
        local rowWidth = DROPDOWN_WIDTH - PADDING * 2 - scrollBarWidth

        f.content:SetHeight(contentHeight)
        f.content:SetWidth(rowWidth)
        f:SetHeight(visibleHeight + PADDING * 2)

        -- Create rows if needed
        while #f.rows < rowCount do
            local row = CreateRow(f.content, #f.rows + 1)
            table.insert(f.rows, row)
        end

        for i, row in ipairs(f.rows) do
            if i <= rowCount then
                row:SetPoint("TOPLEFT", f.content, "TOPLEFT", 0, -((i - 1) * ROW_HEIGHT))
                local setName = setNames[i]
                row.nameText:SetText(setName)

                -- Use category mark if available, otherwise default equipment icon
                local mark = markBySet[setName] or "Interface\\AddOns\\GudaBags\\Assets\\equipment.tga"
                row.icon:SetTexture(mark)

                if activeSet == setName then
                    row.nameText:SetTextColor(0, 1, 0)
                    row.icon:SetVertexColor(0, 1, 0)
                else
                    row.nameText:SetTextColor(0.9, 0.9, 0.9)
                    row.icon:SetVertexColor(1, 0.82, 0)
                end

                row:SetScript("OnClick", function()
                    f:Hide()
                    if activeSet == setName then
                        -- Deselect
                        searchBar.filterState.equipSet = nil
                        ClearEquipSetFilter(searchBar)
                    else
                        -- Select set
                        searchBar.filterState.equipSet = setName
                        searchBar.equipSetButton.activeText:SetText(setName)
                        searchBar.equipSetButton.activeText:Show()
                        searchBar.searchIcon:ClearAllPoints()
                        searchBar.searchIcon:SetPoint("LEFT", searchBar.equipSetButton.activeText, "RIGHT", 4, 0)
                        -- Hide placeholder since set name is shown
                        if searchBar.searchBox and searchBar.searchBox.placeholder then
                            searchBar.searchBox.placeholder:Hide()
                        end
                    end
                    NotifyFilterChanged(searchBar)
                end)
                row:Show()
            else
                row:Hide()
            end
        end
    end

    equipSetDropdown = f
    return f
end

-------------------------------------------------
-- CreateSearchBar (main factory)
-------------------------------------------------
local function CreateSearchBar(parent)
    CreateSearchOverlay()

    local searchBar = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    searchBar:SetHeight(Constants.FRAME.SEARCH_BAR_HEIGHT)
    searchBar:SetPoint("TOPLEFT", parent, "TOPLEFT", Constants.FRAME.PADDING, -(Constants.FRAME.TITLE_HEIGHT + Constants.FRAME.PADDING))
    searchBar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -Constants.FRAME.PADDING, -(Constants.FRAME.TITLE_HEIGHT + Constants.FRAME.PADDING))
    searchBar:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8,
        insets = {left = 2, right = 2, top = 2, bottom = 2},
    })
    searchBar:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
    searchBar:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.8)

    -- Equipment set dropdown button (left side of search bar)
    local equipSetButton = CreateFrame("Button", nil, searchBar)
    equipSetButton:SetSize(12, 12)
    equipSetButton:SetPoint("LEFT", searchBar, "LEFT", 8, 0)

    local equipSetIcon = equipSetButton:CreateTexture(nil, "ARTWORK")
    equipSetIcon:SetAllPoints()
    equipSetIcon:SetTexture("Interface\\AddOns\\GudaBags\\Assets\\equipment.tga")
    equipSetIcon:SetVertexColor(0.6, 0.6, 0.6)
    equipSetButton.icon = equipSetIcon

    -- Active set name label (shown after equip button when a set is selected)
    local activeSetText = equipSetButton:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    Font:Override(activeSetText)
    activeSetText:SetPoint("LEFT", equipSetButton, "RIGHT", 3, 0)
    activeSetText:SetTextColor(1, 0.82, 0)
    activeSetText:SetText("")
    activeSetText:Hide()
    equipSetButton.activeText = activeSetText

    equipSetButton:SetScript("OnEnter", function(self)
        self.icon:SetVertexColor(1, 0.82, 0)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(L["EQUIP_SET_DROPDOWN_TIP"] or "Equipment Sets")
        GameTooltip:Show()
    end)
    equipSetButton:SetScript("OnLeave", function(self)
        if not searchBar.filterState.equipSet then
            self.icon:SetVertexColor(0.6, 0.6, 0.6)
        end
        GameTooltip:Hide()
    end)
    equipSetButton:SetScript("OnClick", function(self)
        local EquipmentSets = ns:GetModule("EquipmentSets")
        if not EquipmentSets then return end
        local setNames = EquipmentSets:GetAllSetNames()
        if not setNames or #setNames == 0 then return end

        local dropdown = CreateEquipSetDropdown()
        if dropdown:IsShown() then
            dropdown:Hide()
            return
        end
        dropdown:Populate(searchBar)
        dropdown:ClearAllPoints()
        dropdown:SetPoint("TOPLEFT", searchBar, "BOTTOMLEFT", 0, -2)
        dropdown:Show()
    end)

    searchBar.equipSetButton = equipSetButton

    local searchIcon = searchBar:CreateTexture(nil, "OVERLAY")
    searchIcon:SetSize(12, 12)
    searchIcon:SetPoint("LEFT", equipSetButton, "RIGHT", 4, 0)
    searchIcon:SetTexture("Interface\\AddOns\\GudaBags\\Assets\\search.tga")
    searchIcon:SetVertexColor(0.6, 0.6, 0.6)
    searchBar.searchIcon = searchIcon

    -- Clear button at the right
    local clearButton = CreateFrame("Button", nil, searchBar)
    clearButton:SetSize(10, 10)
    clearButton:SetPoint("RIGHT", searchBar, "RIGHT", -8, 0)
    clearButton:Hide()

    local clearIcon = clearButton:CreateTexture(nil, "ARTWORK")
    clearIcon:SetAllPoints()
    clearIcon:SetTexture("Interface\\AddOns\\GudaBags\\Assets\\close.tga")
    clearIcon:SetVertexColor(0.4, 0.4, 0.4)
    clearButton.icon = clearIcon

    clearButton:SetScript("OnEnter", function(self)
        self.icon:SetVertexColor(0.7, 0.7, 0.7)
    end)
    clearButton:SetScript("OnLeave", function(self)
        self.icon:SetVertexColor(0.4, 0.4, 0.4)
    end)

    searchBar.clearButton = clearButton

    -- Transfer button (left of clear button)
    local transferButton = CreateFrame("Button", nil, searchBar)
    transferButton:SetSize(12, 12)
    transferButton:SetPoint("RIGHT", clearButton, "LEFT", -4, 0)
    transferButton:Hide()

    local transferIcon = transferButton:CreateTexture(nil, "ARTWORK")
    transferIcon:SetAllPoints()
    transferIcon:SetTexture("Interface\\AddOns\\GudaBags\\Assets\\transfer.tga")
    transferIcon:SetVertexColor(1, 0.82, 0)
    transferButton.icon = transferIcon

    transferButton:SetScript("OnEnter", function(self)
        self.icon:SetVertexColor(1, 1, 0.5)
        if searchBar.transferTarget then
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(searchBar.transferTarget.label or "Transfer")
            GameTooltip:Show()
        end
    end)
    transferButton:SetScript("OnLeave", function(self)
        self.icon:SetVertexColor(1, 0.82, 0)
        GameTooltip:Hide()
    end)
    transferButton:SetScript("OnClick", function()
        if searchBar.onTransfer then
            searchBar.onTransfer()
        end
    end)

    searchBar.transferButton = transferButton
    searchBar.transferTarget = nil
    searchBar.getTransferTarget = nil
    searchBar.onTransfer = nil

    local searchBox = CreateFrame("EditBox", nil, searchBar)
    searchBox:SetPoint("LEFT", searchIcon, "RIGHT", 6, 0)
    searchBox:SetPoint("RIGHT", transferButton, "LEFT", -4, 0)
    searchBox:SetHeight(18)
    searchBox:SetFontObject(GameFontHighlightSmall)
    Font:Override(searchBox)
    searchBox:SetAutoFocus(false)
    searchBox:SetMaxLetters(50)

    local placeholder = searchBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    Font:Override(placeholder)
    placeholder:SetPoint("LEFT", searchBox, "LEFT", 0, 0)
    placeholder:SetText(L["SEARCH_PLACEHOLDER"])
    searchBox.placeholder = placeholder

    searchBar.searchBox = searchBox
    searchBar.searchText = ""
    searchBar.onSearchChanged = nil
    searchBar.filterState = CreateFilterState()

    -- Create chip strip below search bar
    CreateChipStrip(searchBar, parent)

    clearButton:SetScript("OnClick", function()
        searchBox:SetText("")
        searchBox:ClearFocus()
        -- Also clear equipment set filter
        if searchBar.filterState.equipSet then
            searchBar.filterState.equipSet = nil
            ClearEquipSetFilter(searchBar)
            NotifyFilterChanged(searchBar)
        end
    end)

    searchBox:SetScript("OnTextChanged", function(self)
        local text = self:GetText()
        -- Only notify (→ a full bag/bank Refresh) when the text actually changed.
        -- A programmatic SetText to the same value (e.g. during a bank tab switch)
        -- still fires OnTextChanged and was triggering a redundant second Refresh.
        local searchChanged = text ~= searchBar.searchText
        local hasEquipSet = searchBar.filterState.equipSet ~= nil
        if text == "" and not hasEquipSet then
            placeholder:Show()
            searchIcon:SetVertexColor(0.6, 0.6, 0.6)
            clearButton:Hide()
        else
            if text ~= "" then placeholder:Hide() end
            searchIcon:SetVertexColor(1, 0.82, 0)
            clearButton:Show()
        end
        searchBar.searchText = text

        -- Parse search input through SearchParser
        if SearchParser then
            searchBar.filterState.parsed = SearchParser:ParseSearchInput(text)
        else
            searchBar.filterState.parsed = nil
        end

        UpdateTransferButton(searchBar)

        if searchChanged and searchBar.onSearchChanged then
            -- Cancel any pending notify; the latest keystroke supersedes it.
            if searchBar.searchDebounceTimer then
                searchBar.searchDebounceTimer:Cancel()
                searchBar.searchDebounceTimer = nil
            end
            if text == "" then
                -- Clearing: refresh immediately, and leave no timer that could fire
                -- after the frame closes (close clears the search via SetText "").
                searchBar.onSearchChanged(text)
            else
                -- Typing: debounce so fast typing coalesces into a single Refresh.
                -- Guard on parent:IsShown() so a delayed fire can't refresh a frame that
                -- was closed during the debounce window.
                searchBar.searchDebounceTimer = C_Timer.NewTimer(SEARCH_DEBOUNCE, function()
                    searchBar.searchDebounceTimer = nil
                    if searchBar.onSearchChanged and parent and parent:IsShown() then
                        searchBar.onSearchChanged(searchBar.searchText or "")
                    end
                end)
            end
        end
    end)

    searchBox:SetScript("OnEscapePressed", function(self)
        self:SetText("")
        self:ClearFocus()
        if searchBar.filterState.equipSet then
            searchBar.filterState.equipSet = nil
            ClearEquipSetFilter(searchBar)
            NotifyFilterChanged(searchBar)
        end
    end)

    searchBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)

    searchBox:HookScript("OnEditFocusGained", function()
        if searchOverlay then searchOverlay:Show() end
    end)
    -- No overlay on this client, so wire up the event-driven equivalent instead.
    InstallLegacyClickAway(parent)

    searchBox:HookScript("OnEditFocusLost", function(self)
        if searchOverlay then searchOverlay:Hide() end
        -- Clear search text when clicking outside all GudaBags frames
        local overAnyFrame = false
        for parent, _ in pairs(instances) do
            if parent:IsMouseOver() then
                overAnyFrame = true
                break
            end
        end
        if not overAnyFrame then
            self:SetText("")
        end
    end)

    return searchBar
end

-------------------------------------------------
-- Public API
-------------------------------------------------

function SearchBar:Init(parent)
    local instance = CreateSearchBar(parent)
    instances[parent] = instance
    return instance
end

function SearchBar:GetInstance(parent)
    return instances[parent]
end

local function AreFilterChipsEnabled()
    if not Database then
        Database = ns:GetModule("Database")
    end
    return Database and Database:GetSetting("showFilterChips") or false
end

function SearchBar:Show(parent)
    local instance = instances[parent]
    if instance then
        instance:Show()
        if instance.chipStrip then
            if AreFilterChipsEnabled() then
                instance.chipStrip:Show()
            else
                instance.chipStrip:Hide()
                -- Clear chip filters when chips are disabled
                if instance.filterState then
                    instance.filterState.qualities = {}
                    instance.filterState.types = {}
                    instance.filterState.specials = {}
                    ResetChipVisuals(instance)
                    UpdateChipStripVisibility(instance)
                end
            end
        end
    end
end

function SearchBar:Hide(parent)
    local instance = instances[parent]
    if instance then
        -- Clear search text and filters when hiding
        if instance.searchBox then
            instance.searchBox:SetText("")
            instance.searchBox:ClearFocus()
        end
        if instance.filterState then
            instance.filterState.qualities = {}
            instance.filterState.types = {}
            instance.filterState.specials = {}
            instance.filterState.parsed = nil
            instance.filterState.equipSet = nil
            ResetChipVisuals(instance)
            UpdateChipStripVisibility(instance)
        end
        ClearEquipSetFilter(instance)
        if equipSetDropdown then equipSetDropdown:Hide() end
        instance:Hide()
        if instance.chipStrip then
            instance.chipStrip:Hide()
        end
    end
end

function SearchBar:Clear(parent)
    local instance = instances[parent]
    if instance and instance.searchBox then
        instance.searchBox:SetText("")
        instance.searchBox:ClearFocus()
        -- Also clear chip filters
        if instance.filterState then
            instance.filterState.qualities = {}
            instance.filterState.types = {}
            instance.filterState.specials = {}
            instance.filterState.parsed = nil
            instance.filterState.equipSet = nil
            ResetChipVisuals(instance)
            UpdateChipStripVisibility(instance)
        end
        ClearEquipSetFilter(instance)
    end
end

function SearchBar:GetSearchText(parent)
    local instance = instances[parent]
    if instance then
        return instance.searchText or ""
    end
    return ""
end

function SearchBar:SetSearchCallback(parent, callback)
    local instance = instances[parent]
    if instance then
        instance.onSearchChanged = callback
    end
end

-- Returns true if any filter is active (chips or text)
function SearchBar:HasActiveFilters(parent)
    local instance = instances[parent]
    if not instance then return false end
    return HasAnyFilter(instance.filterState)
end

function SearchBar:ClearAllFilters(parent)
    local instance = instances[parent]
    if not instance then return end
    if instance.searchBox then
        instance.searchBox:SetText("")
    end
    if instance.filterState then
        instance.filterState.qualities = {}
        instance.filterState.types = {}
        instance.filterState.specials = {}
        instance.filterState.parsed = nil
        instance.filterState.equipSet = nil
        ResetChipVisuals(instance)
        UpdateChipStripVisibility(instance)
    end
    ClearEquipSetFilter(instance)
end

-- Returns the total height of search bar + chip strip when visible
function SearchBar:GetTotalHeight(parent)
    local instance = instances[parent]
    if not instance then return Constants.FRAME.SEARCH_BAR_HEIGHT end
    if AreFilterChipsEnabled() then
        local chipHeight = instance.isNarrowMode and 28 or Constants.FRAME.CHIP_STRIP_HEIGHT  -- isNarrowMode = < 220
        return Constants.FRAME.SEARCH_BAR_HEIGHT + chipHeight + 1
    end
    return Constants.FRAME.SEARCH_BAR_HEIGHT
end

function SearchBar:SetNarrowMode(parent, isCompact, isNarrow)
    local instance = instances[parent]
    if not instance then return end
    -- Default isNarrow to isCompact if not provided (backward compat)
    if isNarrow == nil then isNarrow = isCompact end
    if instance.isCompactMode == isCompact and instance.isNarrowMode == isNarrow then return end
    instance.isCompactMode = isCompact
    instance.isNarrowMode = isNarrow

    -- Update placeholder text (compact: < 260)
    if instance.searchBox and instance.searchBox.placeholder then
        if isCompact then
            instance.searchBox.placeholder:SetText("Search...")
        else
            instance.searchBox.placeholder:SetText(L["SEARCH_PLACEHOLDER"])
        end
    end

    -- Update chip strip layout
    if instance.chipStrip and AreFilterChipsEnabled() then
        local spacing = Constants.FRAME.CHIP_SPACING
        local chipSize = Constants.FRAME.CHIP_SIZE
        local smallChipSize = 10

        if isNarrow then
            -- < 220: 2-row chip strip with Types dropdown, smaller dots
            instance.chipStrip:SetHeight(28)

            local xOffset = 4
            for _, dot in ipairs(instance.qualityDots) do
                dot:SetSize(smallChipSize, smallChipSize)
                if dot.dot then dot.dot:SetSize(smallChipSize - 4, smallChipSize - 4) end
                dot:ClearAllPoints()
                dot:SetPoint("TOPLEFT", instance.chipStrip, "TOPLEFT", xOffset, -1)
                xOffset = xOffset + smallChipSize + spacing
            end

            if instance.chipClearButton then
                instance.chipClearButton:ClearAllPoints()
                instance.chipClearButton:SetPoint("TOPRIGHT", instance.chipStrip, "TOPRIGHT", -4, -1)
            end

            -- Hide inline chips, show Types dropdown on row 2
            if instance.chipSep1 then instance.chipSep1:Hide() end
            if instance.chipSep2 then instance.chipSep2:Hide() end
            for _, chip in ipairs(instance.typeChips) do chip:Hide() end
            for _, chip in ipairs(instance.specialChips) do chip:Hide() end

            if instance.typesDropdown then
                instance.typesDropdown:ClearAllPoints()
                instance.typesDropdown:SetPoint("BOTTOMLEFT", instance.chipStrip, "BOTTOMLEFT", 0, 2)
                instance.typesDropdown:Show()
                UpdateDropdownLabel(instance)
            end
        elseif isCompact then
            -- < 260 but >= 220: normal dots on single row, normal type chips
            instance.chipStrip:SetHeight(Constants.FRAME.CHIP_STRIP_HEIGHT)

            local xOffset = 4
            for _, dot in ipairs(instance.qualityDots) do
                dot:SetSize(chipSize, chipSize)
                if dot.dot then dot.dot:SetSize(chipSize - 4, chipSize - 4) end
                dot:ClearAllPoints()
                dot:SetPoint("LEFT", instance.chipStrip, "LEFT", xOffset, 0)
                xOffset = xOffset + chipSize + spacing
            end

            -- Separator 1
            if instance.chipSep1 then
                instance.chipSep1:ClearAllPoints()
                xOffset = xOffset + 2
                instance.chipSep1:SetPoint("LEFT", instance.chipStrip, "LEFT", xOffset, 0)
                instance.chipSep1:Show()
                xOffset = xOffset + 1 + spacing
            end

            -- Type chips
            for _, chip in ipairs(instance.typeChips) do
                chip:ClearAllPoints()
                chip:SetPoint("LEFT", instance.chipStrip, "LEFT", xOffset, 0)
                chip:Show()
                xOffset = xOffset + chip:GetWidth() + spacing
            end

            -- Separator 2
            if instance.chipSep2 then
                instance.chipSep2:ClearAllPoints()
                xOffset = xOffset + 2
                instance.chipSep2:SetPoint("LEFT", instance.chipStrip, "LEFT", xOffset, 0)
                instance.chipSep2:Show()
                xOffset = xOffset + 1 + spacing
            end

            -- Special chips
            for _, chip in ipairs(instance.specialChips) do
                chip:ClearAllPoints()
                chip:SetPoint("LEFT", instance.chipStrip, "LEFT", xOffset, 0)
                chip:Show()
                xOffset = xOffset + chip:GetWidth() + spacing
            end

            if instance.chipClearButton then
                instance.chipClearButton:ClearAllPoints()
                instance.chipClearButton:SetPoint("RIGHT", instance.chipStrip, "RIGHT", -4, 0)
            end

            -- Let UpdateChipLayout handle dropdown collapse if still too wide
            UpdateChipLayout(instance)
        else
            -- >= 260: full size dots, normal layout
            instance.chipStrip:SetHeight(Constants.FRAME.CHIP_STRIP_HEIGHT)

            local xOffset = 4
            for _, dot in ipairs(instance.qualityDots) do
                dot:SetSize(chipSize, chipSize)
                if dot.dot then dot.dot:SetSize(chipSize - 4, chipSize - 4) end
                dot:ClearAllPoints()
                dot:SetPoint("LEFT", instance.chipStrip, "LEFT", xOffset, 0)
                xOffset = xOffset + chipSize + spacing
            end

            if instance.chipSep1 then
                instance.chipSep1:ClearAllPoints()
                xOffset = xOffset + 2
                instance.chipSep1:SetPoint("LEFT", instance.chipStrip, "LEFT", xOffset, 0)
                instance.chipSep1:Show()
                xOffset = xOffset + 1 + spacing
            end

            for _, chip in ipairs(instance.typeChips) do
                chip:ClearAllPoints()
                chip:SetPoint("LEFT", instance.chipStrip, "LEFT", xOffset, 0)
                chip:Show()
                xOffset = xOffset + chip:GetWidth() + spacing
            end

            if instance.chipSep2 then
                instance.chipSep2:ClearAllPoints()
                xOffset = xOffset + 2
                instance.chipSep2:SetPoint("LEFT", instance.chipStrip, "LEFT", xOffset, 0)
                instance.chipSep2:Show()
                xOffset = xOffset + 1 + spacing
            end

            for _, chip in ipairs(instance.specialChips) do
                chip:ClearAllPoints()
                chip:SetPoint("LEFT", instance.chipStrip, "LEFT", xOffset, 0)
                chip:Show()
                xOffset = xOffset + chip:GetWidth() + spacing
            end

            if instance.chipClearButton then
                instance.chipClearButton:ClearAllPoints()
                instance.chipClearButton:SetPoint("RIGHT", instance.chipStrip, "RIGHT", -4, 0)
            end

            UpdateChipLayout(instance)
        end
    end
end

-- Check if an item matches all active filters (chips + text operators)
function SearchBar:ItemMatchesFilters(parent, itemData)
    local instance = instances[parent]
    if not instance then return true end

    local state = instance.filterState
    if not HasAnyFilter(state) then return true end
    if not itemData then return false end

    -- 0) Equipment set filter: only items in the selected set
    if state.equipSet then
        local EquipmentSets = ns:GetModule("EquipmentSets")
        if EquipmentSets and itemData.itemID then
            local setNames = EquipmentSets:GetSetNames(itemData.itemID)
            if not setNames then return false end
            local found = false
            for _, name in ipairs(setNames) do
                if name == state.equipSet then
                    found = true
                    break
                end
            end
            if not found then return false end
        else
            return false
        end
    end

    -- 1) Quality chips: OR within group
    if next(state.qualities) then
        if not state.qualities[itemData.quality or -1] then
            return false
        end
    end

    -- 2) Type chips: OR within group
    if next(state.types) then
        local itemType = itemData.itemType
        local matched = false
        if itemType then
            if state.types[itemType] then
                matched = true
            end
            -- "Junk" chip matches quality 0 items
            if not matched and state.types["Junk"] and (itemData.quality or -1) == 0 then
                matched = true
            end
        elseif state.types["Junk"] and (itemData.quality or -1) == 0 then
            matched = true
        end
        if not matched then return false end
    end

    -- 3) Special chips: AND (each active special must match)
    if next(state.specials) then
        local context = {
            tooltipScanner = ns:GetModule("TooltipScanner"),
            recentItems = ns:GetModule("RecentItems"),
        }
        for specialKey in pairs(state.specials) do
            if SearchParser and not SearchParser:MatchKeyword(specialKey, itemData, context) then
                return false
            end
        end
    end

    -- 4) Parsed operators + keywords + text from search box
    if state.parsed then
        local context = {
            tooltipScanner = ns:GetModule("TooltipScanner"),
            recentItems = ns:GetModule("RecentItems"),
        }
        if SearchParser and not SearchParser:MatchesParsed(state.parsed, itemData, context) then
            return false
        end
    end

    return true
end

-- Transfer button: set the callback that determines the transfer target
function SearchBar:SetTransferTargetCallback(parent, callback)
    local instance = instances[parent]
    if instance then
        instance.getTransferTarget = callback
    end
end

-- Transfer button: set the callback that performs the transfer
function SearchBar:SetTransferCallback(parent, callback)
    local instance = instances[parent]
    if instance then
        instance.onTransfer = callback
    end
end

-- Re-evaluate transfer button visibility (call when bank opens/closes)
function SearchBar:UpdateTransferState(parent)
    local instance = instances[parent]
    if instance then
        UpdateTransferButton(instance)
    end
end

-- Legacy compatibility: plain text matching
function SearchBar:ItemMatchesSearch(itemData, searchText)
    if not searchText or searchText == "" then
        return true
    end

    if not itemData then
        return false
    end

    local searchLower = strlower(searchText)

    if itemData.name and strfind(strlower(itemData.name), searchLower, 1, true) then
        return true
    end

    if itemData.itemType and strfind(strlower(itemData.itemType), searchLower, 1, true) then
        return true
    end

    if itemData.itemSubType and strfind(strlower(itemData.itemSubType), searchLower, 1, true) then
        return true
    end

    return false
end
