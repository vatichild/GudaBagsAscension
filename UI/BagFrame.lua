local addonName, ns = ...

local BagFrame = {}
ns:RegisterModule("BagFrame", BagFrame)

local Constants = ns.Constants
local L = ns.L
local Database = ns:GetModule("Database")
local Events = ns:GetModule("Events")
local Font = ns:GetModule("Font")
local BagScanner = ns:GetModule("BagScanner")
local ItemButton = ns:GetModule("ItemButton")
local Footer = ns:GetModule("Footer")
local SearchBar = ns:GetModule("SearchBar")
local Header = ns:GetModule("Header")
local BagClassifier = ns:GetModule("BagFrame.BagClassifier")
local LayoutEngine = ns:GetModule("BagFrame.LayoutEngine")
local Utils = ns:GetModule("Utils")
local CategoryHeaderPool = ns:GetModule("CategoryHeaderPool")
local Theme = ns:GetModule("Theme")

local frame
local itemButtons = {}
local categoryHeaders = {}
local isInitialized = false
local viewingCharacter = nil -- nil = current character, or fullName string

-- Combat lockdown handling
-- ContainerFrameItemButtonTemplate is a secure template that cannot be created during combat
local pendingAction = nil  -- "show", "toggle", or nil
local combatLockdownRegistered = false

-- Smart auto-open/auto-close state (see SmartAutoOpen / SmartAutoClose below)
local bagsAutoOpened = false   -- Did the addon open the bags for the current interaction?
local inInteraction  = false   -- True between any interaction-open and its matching close

-- Persist-across-close: instead of tearing down all buttons on Hide and fully
-- rebuilding on the next Show (~110ms/cycle, the rapid open/close stutter), we
-- keep the buttons + layout and just hide the frame. A reopen with nothing
-- changed is then near-instant. The retained layout is released (ReleaseHeld)
-- when it goes stale: inventory/settings changed while hidden, or another frame
-- that shares the ItemButton pool (bank/guild bank/mail) opens.
local heldHidden = false        -- frame is hidden but buttons/layout retained
local dirtyWhileHidden = false  -- bags/settings changed since being hidden

-- Cached container anchor (UpdateFrameAppearance). Re-anchoring the container
-- moves the reference point for all ~190 child buttons, forcing a full relayout on
-- the next frame:Show(). We skip the SetPoint when the computed anchor is unchanged.
local lastContainerTop = nil
local lastContainerBottom = nil

-- Layout caching for incremental updates (Single View)
local buttonsBySlot = {}  -- Key: "bagID:slot" -> button reference
local buttonsByBag = {}   -- Key: bagID -> { slot -> button } for fast bag-specific lookups
local cachedItemData = {} -- Key: "bagID:slot" -> previous itemID (for comparison)
local cachedItemCount = {} -- Key: "bagID:slot" -> previous count (for stack updates)
local cachedItemCategory = {} -- Key: "bagID:slot" -> previous categoryId (for category view)
-- cachedItemCharges values: number (charges remaining), false (scanned, no charges), nil (unknown)
-- The `false` sentinel lets reused-button refresh skip GetCharges for non-charge items.
local cachedItemCharges = {} -- Key: "bagID:slot" -> previous charges value
local layoutCached = false -- True when layout is cached and can do incremental updates

-- Per-bag slot counts as of the currently cached layout.
--
-- Equipping or removing a bag changes how many slots the grid must show, and
-- NO incremental path can express that: they only repaint existing buttons or
-- convert them to ghost slots (Rule 1). The result is a grid that keeps showing
-- a removed bag's slots -- with no error, because nothing actually failed.
-- Detect the change here and fall back to a full rebuild.
local layoutBagSlots = {}

-- Returns true when the bag layout differs from the cached one, resyncing the
-- snapshot as it goes. A handful of GetContainerNumSlots calls per bag-update
-- batch, on a table that is never reallocated (Rule 2).
local function SyncBagSlotLayout()
    local changed = false
    for _, bagID in ipairs(Constants.BAG_IDS) do
        local numSlots = C_Container.GetContainerNumSlots(bagID) or 0
        if layoutBagSlots[bagID] ~= numSlots then
            layoutBagSlots[bagID] = numSlots
            changed = true
        end
    end
    if Constants.KEYRING_BAG_ID then
        local bagID = Constants.KEYRING_BAG_ID
        local numSlots = C_Container.GetContainerNumSlots(bagID) or 0
        if layoutBagSlots[bagID] ~= numSlots then
            layoutBagSlots[bagID] = numSlots
            changed = true
        end
    end
    return changed
end

-- Category View: Item-key-based button tracking for efficient reuse
-- This allows button reuse when items move, avoiding expensive SetItem calls
local buttonsByItemKey = {}  -- Key: itemKey -> {button1, button2, ...} (array for stacked items)
local buttonPositions = {}   -- Key: button -> {x, y, index} for reflow detection
local categoryViewItems = {} -- Array of {itemKey, bagID, slot, categoryId, count} for current layout
local lastCategoryLayout = nil -- Previous categoryViewItems for comparison
local lastButtonByCategory = {} -- Key: categoryId -> last item button (for drop indicator anchor)
local lastTotalItemCount = 0 -- Track item count to detect Empty/Soul category changes
local pseudoItemButtons = {} -- Track Empty/Soul/DropTarget pseudo-item buttons for proper release
                             -- Keys are "Empty:<categoryId>", "Soul:<categoryId>", or "DropTarget:<categoryId>"

-- Drag state tracking for showing empty category drop targets
local isDraggingItem = false
local dragCheckTicker = nil

-- Single authoritative teardown for an item drag.
--
-- isDraggingItem drives BOTH the flyout bar and (via BuildCategorySections'
-- showEmptyDropTargets argument) the empty-category drop-target sections. If it
-- is left true, the flyout outlives the bags and every enabled-but-empty
-- category stays on screen with a glowing drop slot in it.
--
-- The teardown used to be copy-pasted at three call sites (the cursor ticker,
-- BagFrame:Hide, the frame's OnHide), which is how they drifted. One function,
-- callable from anywhere, idempotent.
local function EndItemDrag()
    isDraggingItem = false
    if dragCheckTicker then
        dragCheckTicker:Cancel()
        dragCheckTicker = nil
    end
    local DragFlyoutBar = ns:GetModule("DragFlyoutBar")
    if DragFlyoutBar then
        DragFlyoutBar:OnDragEnd()
    end
end

-- Drop a drag whose end signal we missed. Cheap enough to call from the layout
-- entry points, which already only run on bag events -- no new polling (Rule 2).
local function HealStaleDragState()
    if isDraggingItem and not CursorHasItem() then
        ns:Debug("Stale drag state cleared (cursor is empty)")
        EndItemDrag()
    end
end

-- Helper to find a pseudo-item button by type (Empty or Soul)
local function FindPseudoItemButton(pseudoType)
    local prefix = pseudoType .. ":"
    for key, button in pairs(pseudoItemButtons) do
        if string.sub(key, 1, #prefix) == prefix then
            return button
        end
    end
    return nil
end

-- Delta layout tracking: Skip layout recalc if settings unchanged
local lastLayoutSettings = nil  -- { columns, iconSize, spacing, slotCount, viewType }

-- Use shared utility functions for key generation
local function GetItemKey(itemData)
    return Utils:GetItemKey(itemData)
end

local function GetSlotKey(bagID, slot)
    return Utils:GetSlotKey(bagID, slot)
end

-- Helper to count keys in a hash table (# only works for array tables)
local function TableCount(tbl)
    local count = 0
    for _ in pairs(tbl) do
        count = count + 1
    end
    return count
end

-- Lazily resolved (TooltipScanner registers its module at file load; ns:GetModule
-- once per addon load is fine, but we cache it to avoid repeated lookups in
-- per-button hot paths).
local _tooltipScannerCached
local function GetTooltipScanner()
    if _tooltipScannerCached == nil then
        _tooltipScannerCached = ns:GetModule("TooltipScanner") or false
    end
    return _tooltipScannerCached or nil
end

-- Populate cachedItemCharges for a slot whose button was just (re)rendered via
-- ItemButton:SetItem. Stores number, false (scanned/no charges), or nil (cleared).
local function CacheChargesForSlot(slotKey, bagID, slot)
    if not Database:GetSetting("showCharges") then
        cachedItemCharges[slotKey] = nil
        return
    end
    local TS = GetTooltipScanner()
    if not TS then
        cachedItemCharges[slotKey] = nil
        return
    end
    cachedItemCharges[slotKey] = TS:GetCharges(bagID, slot) or false
end

-- Refresh the chargesText overlay on a button whose item didn't change identity
-- but may have had its charge count decrement (Wizard Oil, Sharpening Stone, etc.).
-- Short-circuits if the slot is known to have no charges, so this is free for
-- non-charge items in dirty bags.
local function RefreshChargesForReusedButton(button, bagID, slot, slotKey)
    local cachedCharges = cachedItemCharges[slotKey]
    if cachedCharges == false then return end
    if not Database:GetSetting("showCharges") then return end
    local TS = GetTooltipScanner()
    if not TS then return end
    local newCharges = TS:GetCharges(bagID, slot) or false
    if newCharges == cachedCharges then return end
    cachedItemCharges[slotKey] = newCharges
    if button.chargesText then
        if type(newCharges) == "number" and newCharges > 0 then
            button.chargesText:SetText("x" .. newCharges)
            button.chargesText:Show()
        else
            button.chargesText:Hide()
        end
    end
end

-- Forward declarations
local UpdateFrameAppearance
local SaveFramePosition
local RestoreFramePosition
local RegisterCombatEndCallback

-- Transient search bar visibility (header toggle). Resets on Hide().
-- Installs IsSearchBarVisible / ToggleSearchBar / ResetSearchToggle methods on BagFrame.
-- Placed after forward declarations so UpdateFrameAppearance is an upvalue.
ns:GetModule("SearchBarToggle"):Apply(BagFrame, {
    getFrame = function() return frame end,
    onChanged = function()
        UpdateFrameAppearance(true)  -- Refresh below restyles buttons
        BagFrame:Refresh()
    end,
})

-------------------------------------------------
-- Category Header Pool (uses shared CategoryHeaderPool module)
-------------------------------------------------

local function AcquireCategoryHeader(parent)
    return CategoryHeaderPool:Acquire(parent)
end

local function ReleaseAllCategoryHeaders()
    if frame and frame.container then
        CategoryHeaderPool:ReleaseAll(frame.container)  -- Pass owner to release only this frame's headers
    end
    categoryHeaders = {}
end

-------------------------------------------------
-- Container Drop Handling (empty space acts as drop zone)
-------------------------------------------------

-- Handle drops on empty space in the bag container
function BagFrame:HandleContainerDrop()
    if InCombatLockdown() then return end
    local infoType, itemID = GetCursorInfo()
    if infoType ~= "item" or not itemID then return end

    -- Find first empty bag slot (bags 0 to NUM_BAG_SLOTS)
    for bagID = 0, NUM_BAG_SLOTS do
        local numSlots = C_Container.GetContainerNumSlots(bagID)
        for slot = 1, numSlots do
            local itemInfo = C_Container.GetContainerItemInfo(bagID, slot)
            if not itemInfo then
                -- Empty slot found, place item here
                C_Container.PickupContainerItem(bagID, slot)
                return
            end
        end
    end

    -- If no empty slot found, clear cursor
    ClearCursor()
end

-- Locate the cursor item's source slot by scanning for the locked slot.
-- Returns bagID, slot, source ("bag"|"bank") or nil if not found.
function BagFrame:GetCursorBagSlot()
    -- Player bags
    for bagID = 0, NUM_BAG_SLOTS do
        local numSlots = C_Container.GetContainerNumSlots(bagID)
        for slot = 1, numSlots do
            local itemInfo = C_Container.GetContainerItemInfo(bagID, slot)
            if itemInfo and itemInfo.isLocked then
                return bagID, slot, "bag"
            end
        end
    end

    -- Bank slots
    local bankBags = {}
    if Constants.CHARACTER_BANK_TAB_IDS and #Constants.CHARACTER_BANK_TAB_IDS > 0 then
        for _, tabID in ipairs(Constants.CHARACTER_BANK_TAB_IDS) do
            table.insert(bankBags, tabID)
        end
    end
    if Constants.WARBAND_BANK_TAB_IDS and #Constants.WARBAND_BANK_TAB_IDS > 0 then
        for _, tabID in ipairs(Constants.WARBAND_BANK_TAB_IDS) do
            table.insert(bankBags, tabID)
        end
    end
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
                if itemInfo and itemInfo.isLocked then
                    return bagID, slot, "bank"
                end
            end
        end
    end
end

-- Separate container for secure item buttons - NOT a child of the bag frame
-- This prevents the bag frame from becoming protected
local secureButtonContainer = nil

local function CreateBagFrame()
    local f = CreateFrame("Frame", "GudaBagsBagFrame", UIParent, "BackdropTemplate")
    f:SetSize(400, 300)
    f:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 20, 100)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("HIGH")
    f:SetFrameLevel(Constants.FRAME_LEVELS.BASE)
    f:EnableMouse(true)

    -- The drag flyout ("Track This Item", "Lock This Item", ...) is parented to
    -- UIParent and anchored above this frame, so hiding the frame does not hide
    -- it. BagFrame:Hide() cleans it up, but the frame can also be hidden without
    -- going through that method -- Escape via UISpecialFrames, CloseAllWindows,
    -- or any other addon calling frame:Hide() -- and then the bar was left
    -- floating on screen with no owner. OnHide fires for every one of those
    -- paths. The cleanup is idempotent, so the BagFrame:Hide() route running it
    -- twice is harmless.
    f:SetScript("OnHide", EndItemDrag)

    -- Raise frame above BankFrame when clicked
    f:SetScript("OnMouseDown", function(self)
        self:SetFrameLevel(Constants.FRAME_LEVELS.RAISED)
        Theme:SyncBlizzardBgLevel(self)
        -- Keep secure container above frame backdrop
        if self.container then
            self.container:SetFrameLevel(Constants.FRAME_LEVELS.RAISED + Constants.FRAME_LEVELS.CONTAINER)
            ItemButton:SyncFrameLevels(self.container)
        end

        local BankFrameModule = ns:GetModule("BankFrame")
        if BankFrameModule and BankFrameModule:GetFrame() then
            local bankFrame = BankFrameModule:GetFrame()
            bankFrame:SetFrameLevel(Constants.FRAME_LEVELS.BASE)
            Theme:SyncBlizzardBgLevel(bankFrame)
            if bankFrame.container then
                bankFrame.container:SetFrameLevel(Constants.FRAME_LEVELS.BASE + Constants.FRAME_LEVELS.CONTAINER)
                ItemButton:SyncFrameLevels(bankFrame.container)
            end
        end

        local GuildBankFrameModule = ns:GetModule("GuildBankFrame")
        if GuildBankFrameModule and GuildBankFrameModule.GetFrame and GuildBankFrameModule:GetFrame() then
            local guildFrame = GuildBankFrameModule:GetFrame()
            guildFrame:SetFrameLevel(Constants.FRAME_LEVELS.BASE)
            Theme:SyncBlizzardBgLevel(guildFrame)
            if guildFrame.container then
                guildFrame.container:SetFrameLevel(Constants.FRAME_LEVELS.BASE + Constants.FRAME_LEVELS.CONTAINER)
                ItemButton:SyncFrameLevels(guildFrame.container)
            end
        end
    end)

    -- Ensure container stays above frame backdrop when mouse enters
    f:SetScript("OnEnter", function(self)
        if self.container then
            self.container:SetFrameLevel(self:GetFrameLevel() + Constants.FRAME_LEVELS.CONTAINER)
        end
    end)
    local backdrop = Theme:GetValue("backdrop")
    if backdrop then
        f:SetBackdrop(backdrop)
        local bgAlpha = Database:GetSetting("bgAlpha") / 100
        local bg = Theme:GetValue("frameBg")
        f:SetBackdropColor(bg[1], bg[2], bg[3], bgAlpha)
        local border = Theme:GetValue("frameBorder")
        f:SetBackdropBorderColor(border[1], border[2], border[3], border[4])
    end
    f:Hide()

    -- Create separate secure button container as child of UIParent (not f)
    -- This prevents f from becoming protected when secure buttons are added
    if not secureButtonContainer then
        secureButtonContainer = CreateFrame("Frame", "GudaBagsSecureContainer", UIParent)
        secureButtonContainer:SetFrameStrata("HIGH")
        secureButtonContainer:SetFrameLevel(Constants.FRAME_LEVELS.BASE + Constants.FRAME_LEVELS.CONTAINER)
        secureButtonContainer:Hide()  -- Start hidden
    end

    -- Initialize header component
    f.titleBar = Header:Init(f)
    Header:SetDragCallback(SaveFramePosition)

    -- Initialize search bar component
    f.searchBar = SearchBar:Init(f)
    SearchBar:SetSearchCallback(f, function(text)
        BagFrame:Refresh()
    end)

    -- Transfer button callbacks
    SearchBar:SetTransferTargetCallback(f, function()
        local GuildBankScanner = ns:GetModule("GuildBankScanner")
        if GuildBankScanner and GuildBankScanner:IsGuildBankOpen() then
            return {type = "guildbank", label = L["TRANSFER_TO_GUILD_BANK"]}
        end
        local BankScannerModule = ns:GetModule("BankScanner")
        if BankScannerModule and BankScannerModule:IsBankOpen() then
            -- Check if warband view is active (Retail only)
            local BankFooter = ns:GetModule("BankFrame.BankFooter")
            if ns.IsRetail and BankFooter then
                local bankType = BankFooter:GetCurrentBankType()
                if bankType == "warband" then
                    return {type = "warband", label = L["TRANSFER_TO_WARBAND"]}
                end
            end
            return {type = "bank", label = L["TRANSFER_TO_BANK"]}
        end
        return nil
    end)

    SearchBar:SetTransferCallback(f, function()
        BagFrame:TransferMatchedItems()
    end)

    -- Use the separate secure button container instead of creating one as child of f
    -- This keeps f unprotected so it can be shown during combat
    secureButtonContainer:SetPoint("TOPLEFT", f, "TOPLEFT", Constants.FRAME.PADDING, -(Header:GetHeight() + SearchBar:GetTotalHeight(f) + Constants.FRAME.PADDING + 6))
    secureButtonContainer:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -Constants.FRAME.PADDING, Constants.FRAME.FOOTER_HEIGHT + Constants.FRAME.PADDING + 6)
    f.container = secureButtonContainer
    f.container.masqueGroup = "Bags"

    -- Sync secure container visibility with main frame
    f:HookScript("OnShow", function() secureButtonContainer:Show() end)
    f:HookScript("OnHide", function()
        secureButtonContainer:Hide()
        -- Any close (X button, B key, /script CloseAllBags, ProfileManager, etc.)
        -- clears the addon's auto-opened claim so the next interaction-close won't
        -- close bags the user has manually reopened.
        bagsAutoOpened = false
        -- Clear search bar text and filters
        SearchBar:Clear(f)
        -- Reset to current character when bag closes
        if viewingCharacter then
            viewingCharacter = nil
            Header:SetViewingCharacter(nil, nil)
        end
        -- Close any open character dropdown
        if Characters then
            Characters:Hide()
        end

        local ProfessionButton = ns:GetModule("Footer.ProfessionButton")
        if ProfessionButton and ProfessionButton.HideAllInstantly then
            ProfessionButton:HideAllInstantly()
        end
    end)

    -- Enable container as drop zone for empty space
    secureButtonContainer:EnableMouse(true)

    secureButtonContainer:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
            BagFrame:HandleContainerDrop()
        end
    end)

    secureButtonContainer:SetScript("OnReceiveDrag", function(self)
        BagFrame:HandleContainerDrop()
    end)

    -- Initialize footer component
    f.footer = Footer:Init(f)
    Footer:SetKeyringCallback(function(isVisible)
        BagFrame:Refresh()
    end)
    Footer:SetSoulBagCallback(function(isVisible)
        BagFrame:Refresh()
    end)
    Footer:SetQuiverBagCallback(function(isVisible)
        BagFrame:Refresh()
    end)
    Footer:SetBagVisibilityCallback(function()
        BagFrame:Refresh()
    end)
    Footer:SetBackCallback(function()
        BagFrame:ViewCharacter(nil, nil)
    end)

    -- Initialize character dropdown callback
    Header:SetCharacterCallback(function(fullName, charData)
        BagFrame:ViewCharacter(fullName, charData)
    end)

    -- Initialize bank character dropdown callback (used by both BagFrame and BankFrame headers)
    Header:SetBankCharacterCallback(function(fullName, charData)
        local BankFrameModule = ns:GetModule("BankFrame")
        if BankFrameModule:IsShown() then
            BankFrameModule:ViewCharacter(fullName, charData)
        else
            BankFrameModule:Show()
            BankFrameModule:ViewCharacter(fullName, charData)
        end
    end)

    -- Note: Responsive narrow mode is handled in Refresh() which pre-calculates
    -- expected frame width and applies narrow mode before sizing

    Font:RegisterFrame(f)
    return f
end

function BagFrame:RefreshPinIcons()
    for _, button in pairs(buttonsBySlot) do
        ItemButton:UpdatePinIcon(button)
    end
end

function BagFrame:RefreshLockIcons()
    for _, button in pairs(buttonsBySlot) do
        ItemButton:UpdateUserLockIcon(button)
    end
end

function BagFrame:Refresh()
    if not frame then return end

    -- Never lay out drop targets for a drag that already ended.
    HealStaleDragState()

    ns:ProfileStart("Refresh")

    local viewType = Database:GetSetting("bagViewType") or "single"

    -- Detect view type change - must release all buttons when switching views
    local lastViewType = lastLayoutSettings and lastLayoutSettings.viewType
    local viewTypeChanged = lastViewType and lastViewType ~= viewType

    -- For category view (staying in category), preserve buttonsByItemKey for reuse optimization
    -- RefreshCategoryView will handle selective release/acquire
    -- But if switching TO category from another view, release all first
    if viewType ~= "category" or viewTypeChanged then
        ItemButton:ReleaseAll(frame.container)
        buttonsByItemKey = {}
    end
    -- else: RefreshCategoryView handles button release/acquire with key-based reuse

    ReleaseAllCategoryHeaders()

    itemButtons = {}

    -- Release pseudo-item buttons BEFORE clearing the table
    for _, button in pairs(pseudoItemButtons) do
        ItemButton:Release(button)
    end

    -- Clear layout cache for full refresh
    buttonsBySlot = {}
    buttonsByBag = {}
    cachedItemData = {}
    cachedItemCount = {}
    cachedItemCharges = {}
    cachedItemCategory = {}
    -- Note: buttonsByItemKey preserved for category view reuse (unless view type changed)
    buttonPositions = {}
    categoryViewItems = {}
    lastCategoryLayout = nil
    lastTotalItemCount = 0
    pseudoItemButtons = {}
    layoutCached = false
    -- Note: lastLayoutSettings is preserved until end of Refresh to detect view type changes

    local isViewingCached = viewingCharacter ~= nil
    local bags

    if isViewingCached then
        bags = Database:GetNormalizedBags(viewingCharacter) or {}
    else
        bags = BagScanner:GetCachedBags()
    end

    local iconSize = Database:GetSetting("iconSize")
    local spacing = Database:GetSetting("iconSpacing")
    local columns = Database:GetSetting("bagColumns")
    local hasSearch = SearchBar:HasActiveFilters(frame)
    -- viewType already declared at top of function

    -- Pre-calculate expected frame width to determine responsive modes BEFORE sizing
    local expectedWidth = (iconSize * columns) + (spacing * (columns - 1)) + (Constants.FRAME.PADDING * 2)
    expectedWidth = math.max(expectedWidth, Constants.FRAME.MIN_WIDTH)
    -- < 260: visual compact (smaller chips, smaller font, shorter placeholder)
    -- < 220: layout reflow (footer 2-row, Types dropdown instead of chips)
    local isCompact = expectedWidth < 260
    local isNarrow = expectedWidth < 220

    -- Apply modes to all components before calculating heights
    Header:SetNarrowMode(isCompact)
    SearchBar:SetNarrowMode(frame, isCompact, isNarrow)
    Footer:SetNarrowMode(isNarrow)

    -- Calculate common settings
    local showSearchBar = BagFrame:IsSearchBarVisible()
    local showFooterSetting = Database:GetSetting("showFooter")
    local showFooter = showFooterSetting or isViewingCached
    local showCategoryCount = Database:GetSetting("showCategoryCount")

    local showFilterChips = Database:GetSetting("showFilterChips")

    local splitColumns = Database:GetSetting("splitBagColumns") or 2

    local settings = {
        columns = columns,
        iconSize = iconSize,
        spacing = spacing,
        showSearchBar = showSearchBar,
        showFilterChips = showFilterChips,
        showFooter = showFooter,
        showCategoryCount = showCategoryCount,
        splitColumns = splitColumns,
        footerHeight = Footer:GetHeight(),
        searchBarHeight = SearchBar:GetTotalHeight(frame),
        headerHeight = Header:GetHeight(),
    }

    -- Classify bags by type
    ns:ProfileStart("Refresh.classify")
    local classifiedBags = BagClassifier:ClassifyBags(bags, isViewingCached)
    ns:ProfileStop("Refresh.classify")

    -- Build display order
    local showKeyring = Footer:IsKeyringVisible()
    local showSoulBag = Footer:IsSoulBagVisible()
    local showQuiverBag = Footer:IsQuiverBagVisible()
    ns:ProfileStart("Refresh.buildorder")
    local bagsToShow = LayoutEngine:BuildDisplayOrder(classifiedBags, showKeyring, bags, showSoulBag, showQuiverBag)
    ns:ProfileStop("Refresh.buildorder")

    -- Filter out hidden bags in single/split view mode (not when viewing cached character)
    if (viewType == "single" or viewType == "split") and not isViewingCached then
        local BagSlots = ns:GetModule("Footer.BagSlots")
        if BagSlots then
            local filteredBags = {}
            for _, bagInfo in ipairs(bagsToShow) do
                -- bagsToShow contains objects like {bagID = 0, needsSpacing = false}
                if not BagSlots:IsBagHidden(bagInfo.bagID) then
                    table.insert(filteredBags, bagInfo)
                end
            end
            bagsToShow = filteredBags
        end
    end

    ns:ProfileStart("Refresh.render")
    if viewType == "category" then
        self:RefreshCategoryView(bags, bagsToShow, settings, hasSearch, isViewingCached)
    elseif viewType == "split" then
        self:RefreshSplitView(bags, bagsToShow, settings, hasSearch, isViewingCached)
    else
        self:RefreshSingleView(bags, bagsToShow, settings, hasSearch, isViewingCached)
    end
    ns:ProfileStop("Refresh.render")

    -- Update slot info (show regular bags only, special bags in tooltip)
    if isViewingCached then
        local totalSlots = 0
        local usedSlots = 0
        for _, bagData in pairs(bags) do
            if bagData.numSlots then
                totalSlots = totalSlots + bagData.numSlots
                usedSlots = usedSlots + (bagData.numSlots - (bagData.freeSlots or 0))
            end
        end
        Footer:UpdateSlotInfo(usedSlots, totalSlots)
    else
        local regularTotal, regularFree, specialBags = BagScanner:GetDetailedSlotCounts()
        local totalSlots, freeSlots = BagScanner:GetTotalSlots()
        Footer:UpdateSlotInfo(totalSlots - freeSlots, totalSlots, regularTotal, regularFree, specialBags)
    end

    -- Update footer (bag slots, hearthstone, money, keyring state)
    if not isViewingCached then
        Footer:Update()
    end

    -- Save current view type for detecting view switches
    lastLayoutSettings = { viewType = viewType }

    -- Font: no per-render sweep needed. The frame is registered once via
    -- Font:RegisterFrame; item buttons (Font:Apply) and headers (Font:Override)
    -- self-register on create, and a font-family change re-sweeps via ReapplyAll.
    -- Re-walking every bag button here cost ~tens of ms per Refresh for nothing.

    ns:ProfileStop("Refresh")
end

function BagFrame:RefreshSingleView(bags, bagsToShow, settings, hasSearch, isViewingCached)
    local iconSize = settings.iconSize

    -- Collect all slots
    -- On Retail, use unified order (sequential by bag ID) to match native sort behavior
    -- This ensures profession materials don't appear after junk from regular bags
    local unifiedOrder = ns.IsRetail and not isViewingCached
    local allSlots = LayoutEngine:CollectAllSlots(bagsToShow, bags, isViewingCached, unifiedOrder)

    -- Calculate frame size
    local frameWidth, frameHeight = LayoutEngine:CalculateFrameSize(allSlots, settings)
    frame:SetSize(frameWidth, frameHeight)

    -- Calculate button positions
    local positions = LayoutEngine:CalculateButtonPositions(allSlots, settings)

    -- Render buttons
    for i, slotInfo in ipairs(allSlots) do
        ns:ProfileStart("render.acquire")
        local button = ItemButton:Acquire(frame.container)
        ns:ProfileStop("render.acquire")
        local slotKey = slotInfo.bagID .. ":" .. slotInfo.slot

        if slotInfo.itemData then
            ns:ProfileStart("render.setitem")
            ItemButton:SetItem(button, slotInfo.itemData, iconSize, isViewingCached)
            ns:ProfileStop("render.setitem")
            if hasSearch then
                ItemButton:SetSearchState(button, SearchBar:ItemMatchesFilters(frame, slotInfo.itemData))
            else
                ItemButton:ClearSearchState(button)
            end
            -- Cache item data for incremental updates
            cachedItemData[slotKey] = slotInfo.itemData.itemID
            cachedItemCount[slotKey] = slotInfo.itemData.count
            CacheChargesForSlot(slotKey, slotInfo.bagID, slotInfo.slot)
        else
            ns:ProfileStart("render.setempty")
            ItemButton:SetEmpty(button, slotInfo.bagID, slotInfo.slot, iconSize, isViewingCached)
            ns:ProfileStop("render.setempty")
            if hasSearch then
                ItemButton:SetSearchState(button, false)
            else
                ItemButton:ClearSearchState(button)
            end
            cachedItemData[slotKey] = nil
            cachedItemCount[slotKey] = nil
            cachedItemCharges[slotKey] = nil
        end

        -- Position the wrapper frame
        local pos = positions[i]
        button.wrapper:ClearAllPoints()
        button.wrapper:SetPoint("TOPLEFT", frame.container, "TOPLEFT", pos.x, pos.y)

        -- Store button by slot key for incremental updates
        buttonsBySlot[slotKey] = button
        table.insert(itemButtons, button)

        -- Store by bagID for fast bag-specific lookups
        local bagID = slotInfo.bagID
        if not buttonsByBag[bagID] then
            buttonsByBag[bagID] = {}
        end
        buttonsByBag[bagID][slotInfo.slot] = button
    end

    layoutCached = true
end

function BagFrame:RefreshSplitView(bags, bagsToShow, settings, hasSearch, isViewingCached)
    local iconSize = settings.iconSize
    local spacing = settings.spacing

    local layout = LayoutEngine:BuildSplitViewLayout(bagsToShow, bags, settings, isViewingCached)
    local frameWidth, frameHeight = LayoutEngine:CalculateSplitFrameSize(layout, settings)
    frame:SetSize(frameWidth, frameHeight)

    for _, section in ipairs(layout.sections) do
        -- Create header with bag icon + name
        local header = AcquireCategoryHeader(frame.container)
        header:SetWidth(section.width)
        header:ClearAllPoints()
        header:SetPoint("TOPLEFT", frame.container, "TOPLEFT", section.x, section.headerY)

        if section.displayInfo.icon then
            header.icon:SetTexture(section.displayInfo.icon)
            header.icon:SetSize(12, 12)
            header.icon:Show()
            header.text:ClearAllPoints()
            header.text:SetPoint("LEFT", header.icon, "RIGHT", 4, 0)
        else
            header.icon:Hide()
            header.text:ClearAllPoints()
            header.text:SetPoint("LEFT", header, "LEFT", 0, 0)
        end
        header.text:SetText(section.displayInfo.name or "")

        local _, _, fontFlags = header.text:GetFont()
        if iconSize < Constants.CATEGORY_ICON_SIZE_THRESHOLD then
            Font:Apply(header.text, Constants.CATEGORY_FONT_SMALL, fontFlags)
        else
            Font:Apply(header.text, Constants.CATEGORY_FONT_LARGE, fontFlags)
        end

        header.line:Show()
        header:EnableMouse(false)
        table.insert(categoryHeaders, header)

        -- Render item slots for this bag
        local bagID = section.bagID
        local bagData = bags[bagID]
        local sectionColumns = section.columns
        local numSlots = section.numSlots

        for slot = 1, numSlots do
            local itemData = bagData and bagData.slots and bagData.slots[slot]
            local button = ItemButton:Acquire(frame.container)
            local slotKey = bagID .. ":" .. slot

            if itemData then
                ItemButton:SetItem(button, itemData, iconSize, isViewingCached)
                if hasSearch then
                    ItemButton:SetSearchState(button, SearchBar:ItemMatchesFilters(frame, itemData))
                else
                    ItemButton:ClearSearchState(button)
                end
                cachedItemData[slotKey] = itemData.itemID
                cachedItemCount[slotKey] = itemData.count
                CacheChargesForSlot(slotKey, bagID, slot)
            else
                ItemButton:SetEmpty(button, bagID, slot, iconSize, isViewingCached)
                if hasSearch then
                    ItemButton:SetSearchState(button, false)
                else
                    ItemButton:ClearSearchState(button)
                end
                cachedItemData[slotKey] = nil
                cachedItemCount[slotKey] = nil
                cachedItemCharges[slotKey] = nil
            end

            local col = (slot - 1) % sectionColumns
            local row = math.floor((slot - 1) / sectionColumns)
            local x = section.x + col * (iconSize + spacing)
            local y = section.slotsStartY - (row * (iconSize + spacing))

            button.wrapper:ClearAllPoints()
            button.wrapper:SetPoint("TOPLEFT", frame.container, "TOPLEFT", x, y)

            buttonsBySlot[slotKey] = button
            table.insert(itemButtons, button)

            if not buttonsByBag[bagID] then
                buttonsByBag[bagID] = {}
            end
            buttonsByBag[bagID][slot] = button
        end
    end

    layoutCached = true
end

function BagFrame:RefreshCategoryView(bags, bagsToShow, settings, hasSearch, isViewingCached)
    local iconSize = settings.iconSize

    -- Collect items and count empty slots (including soul bag slots)
    local items, emptyCount, firstEmptySlot, soulEmptyCount, firstSoulEmptySlot, quiverEmptyCount, firstQuiverEmptySlot = LayoutEngine:CollectItemsForCategoryView(bagsToShow, bags, isViewingCached)

    -- Note: Search filtering removed - now uses alpha dimming like Single View
    -- Items stay in layout, non-matching items are dimmed to 0.3 alpha

    -- Phase 4: Key-based button reuse
    -- Build map of new items by key
    local newItemsByKey = {}
    local newItemsKeyList = {}  -- Ordered list of keys
    for _, item in ipairs(items) do
        local key = GetItemKey(item.itemData)
        if key then
            if not newItemsByKey[key] then
                newItemsByKey[key] = {}
                table.insert(newItemsKeyList, key)
            end
            table.insert(newItemsByKey[key], item)
        end
    end

    -- Find buttons to keep vs release
    local buttonsToKeep = {}  -- key -> {button, ...}
    local buttonsToRelease = {}

    for key, buttons in pairs(buttonsByItemKey) do
        local needed = newItemsByKey[key] and #newItemsByKey[key] or 0
        local available = #buttons

        if needed > 0 then
            -- Keep up to 'needed' buttons
            buttonsToKeep[key] = {}
            for i = 1, math.min(needed, available) do
                table.insert(buttonsToKeep[key], buttons[i])
            end
            -- Release excess buttons
            for i = needed + 1, available do
                table.insert(buttonsToRelease, buttons[i])
            end
        else
            -- Item no longer exists, release all buttons
            for _, button in ipairs(buttons) do
                table.insert(buttonsToRelease, button)
            end
        end
    end

    -- Release unused buttons
    for _, button in ipairs(buttonsToRelease) do
        ItemButton:Release(button)
    end

    -- Note: pseudo-item buttons are released in Refresh() before calling this function
    -- Just clear the table to rebuild fresh
    pseudoItemButtons = {}

    -- Clear tracking (will rebuild below)
    buttonsBySlot = {}
    buttonsByBag = {}
    cachedItemData = {}
    cachedItemCount = {}
    cachedItemCharges = {}
    cachedItemCategory = {}
    buttonsByItemKey = {}
    buttonPositions = {}
    categoryViewItems = {}
    itemButtons = {}

    -- Build category sections (include empty slot count for "Empty" and "Soul" categories)
    -- When dragging an item, also show empty categories as drop targets
    local sections = LayoutEngine:BuildCategorySections(items, isViewingCached, emptyCount, firstEmptySlot, soulEmptyCount, firstSoulEmptySlot, nil, isDraggingItem, quiverEmptyCount, firstQuiverEmptySlot)

    -- Calculate frame size
    local frameWidth, frameHeight = LayoutEngine:CalculateCategoryFrameSize(sections, settings)
    frame:SetSize(frameWidth, frameHeight)

    -- Calculate positions
    local layout = LayoutEngine:CalculateCategoryPositions(sections, settings)

    -- Render category headers
    for _, headerInfo in ipairs(layout.headers) do
        local header = AcquireCategoryHeader(frame.container)
        header:SetWidth(headerInfo.width)
        header:ClearAllPoints()
        header:SetPoint("TOPLEFT", frame.container, "TOPLEFT", headerInfo.x, headerInfo.y)

        -- No icons in category headers
        header.icon:Hide()
        header.text:ClearAllPoints()
        header.text:SetPoint("LEFT", header, "LEFT", 0, 0)

        -- Adjust font size based on icon size
        local _, _, fontFlags = header.text:GetFont()
        if iconSize < Constants.CATEGORY_ICON_SIZE_THRESHOLD then
            Font:Apply(header.text, Constants.CATEGORY_FONT_SMALL, fontFlags)
        else
            Font:Apply(header.text, Constants.CATEGORY_FONT_LARGE, fontFlags)
        end

        -- Responsive text truncation based on available width
        local displayName = headerInfo.section.categoryName
        local numItems = #headerInfo.section.items
        -- Show count unless disabled OR only 1 item (redundant to show "(1)")
        local showCount = settings.showCategoryCount and numItems > 1
        local countSuffix = showCount and (" (" .. numItems .. ")") or ""
        header.fullName = displayName
        header.isShortened = false

        -- When not showing count, truncate based on item count
        -- 1 item: max 6 chars, 2+ items: max 13 chars
        if not showCount then
            local maxChars = numItems == 1 and 6 or 13
            if string.len(displayName) > maxChars then
                header.isShortened = true
                header.text:SetText(string.sub(displayName, 1, maxChars) .. "...")
            else
                header.text:SetText(displayName)
            end
        else
            -- Calculate available width (header width minus line spacing)
            local availableWidth = headerInfo.width - 10

            -- Set full text first to measure
            header.text:SetText(displayName .. countSuffix)
            local textWidth = header.text:GetStringWidth()

            -- Truncate if text is too wide (only for names longer than 4 characters)
            if textWidth > availableWidth and string.len(displayName) > 4 then
                header.isShortened = true
                -- Binary search for best fit
                local maxChars = string.len(displayName)
                while textWidth > availableWidth and maxChars > 1 do
                    maxChars = maxChars - 1
                    header.text:SetText(string.sub(displayName, 1, maxChars) .. "..." .. countSuffix)
                    textWidth = header.text:GetStringWidth()
                end
            end
        end

        -- Hide separator line for single-item categories
        if numItems <= 1 then
            header.line:Hide()
        else
            header.line:Show()
        end

        -- Store category info on header for drag-drop
        header.categoryId = headerInfo.section.categoryId
        header:EnableMouse(true)

        -- Add tooltip for shortened names
        header:SetScript("OnEnter", function(self)
            if self.isShortened then
                GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
                GameTooltip:SetText(self.fullName)
                GameTooltip:Show()
            end
        end)
        header:SetScript("OnLeave", function(self)
            GameTooltip:Hide()
        end)

        -- Handle click for Empty category: place item in first empty slot
        header:SetScript("OnMouseDown", function(self, button)
            if InCombatLockdown() then return end
            if button == "LeftButton" and self.categoryId == "Empty" then
                local cursorType = GetCursorInfo()
                if cursorType == "item" then
                    -- Find first empty bag slot
                    for bagID = 0, NUM_BAG_SLOTS do
                        local numSlots = C_Container.GetContainerNumSlots(bagID)
                        for slot = 1, numSlots do
                            local itemInfo = C_Container.GetContainerItemInfo(bagID, slot)
                            if not itemInfo then
                                -- Empty slot found, place item here
                                C_Container.PickupContainerItem(bagID, slot)
                                return
                            end
                        end
                    end
                end
            end
        end)

        table.insert(categoryHeaders, header)
    end

    -- Render item buttons with key-based reuse
    -- Track which kept buttons we've used per key
    local usedKeptButtons = {}
    for key in pairs(buttonsToKeep) do
        usedKeptButtons[key] = 0
    end

    local reusedCount = 0
    local acquiredCount = 0

    -- Reset last button tracking for drop indicator
    lastButtonByCategory = {}

    for index, itemInfo in ipairs(layout.items) do
        local itemData = itemInfo.item.itemData
        local slotKey = GetSlotKey(itemData.bagID, itemData.slot)
        local itemKey = GetItemKey(itemData)

        -- Try to reuse existing button for this item key
        local button
        if itemKey and buttonsToKeep[itemKey] then
            local used = usedKeptButtons[itemKey]
            if used < #buttonsToKeep[itemKey] then
                button = buttonsToKeep[itemKey][used + 1]
                usedKeptButtons[itemKey] = used + 1
                reusedCount = reusedCount + 1
            end
        end

        -- Acquire new button if no reusable one found
        if not button then
            button = ItemButton:Acquire(frame.container)
            acquiredCount = acquiredCount + 1
        end

        -- Store category info before SetItem so it can use it for display logic
        button.categoryId = itemInfo.categoryId

        ItemButton:SetItem(button, itemData, iconSize, isViewingCached)

        -- Apply spotlight search highlighting
        if hasSearch then
            ItemButton:SetSearchState(button, SearchBar:ItemMatchesFilters(frame, itemData))
        else
            ItemButton:ClearSearchState(button)
        end

        -- Store layout position for drag-drop indicator
        button.iconSize = iconSize
        button.layoutX = itemInfo.x
        button.layoutY = itemInfo.y
        button.layoutIndex = index
        button.containerFrame = frame.container

        button.wrapper:ClearAllPoints()
        button.wrapper:SetPoint("TOPLEFT", frame.container, "TOPLEFT", itemInfo.x, itemInfo.y)

        -- Don't track Empty/Soul category pseudo-item in incremental update structures
        -- It represents aggregated empty slots, not a real item slot
        -- But DO track it separately for proper release
        -- Use a unique key combining pseudo-item type and categoryId to avoid overwrites
        -- when multiple pseudo-items (Empty, Soul) are in the same merged group
        if itemData.isDropTarget then
            local pseudoKey = "DropTarget:" .. itemInfo.categoryId
            pseudoItemButtons[pseudoKey] = button
        elseif itemData.isEmptySlots then
            local prefix
            if itemData.isSoulSlots then
                prefix = "Soul:"
            elseif itemData.isQuiverSlots then
                prefix = "Quiver:"
            else
                prefix = "Empty:"
            end
            local pseudoKey = prefix .. itemInfo.categoryId
            pseudoItemButtons[pseudoKey] = button
        else
            -- Store button by slot key for incremental updates (legacy)
            buttonsBySlot[slotKey] = button
            cachedItemData[slotKey] = itemData.itemID
            cachedItemCount[slotKey] = itemData.count
            cachedItemCategory[slotKey] = itemInfo.categoryId
            CacheChargesForSlot(slotKey, itemData.bagID, itemData.slot)

            -- Store by bagID for fast bag-specific lookups
            local bagID = itemData.bagID
            if not buttonsByBag[bagID] then
                buttonsByBag[bagID] = {}
            end
            buttonsByBag[bagID][itemData.slot] = button

            -- Store by item key for smart button reuse
            if itemKey then
                if not buttonsByItemKey[itemKey] then
                    buttonsByItemKey[itemKey] = {}
                end
                table.insert(buttonsByItemKey[itemKey], button)
            end
        end

        -- Store button position for reflow detection
        buttonPositions[button] = {x = itemInfo.x, y = itemInfo.y, index = index}

        -- Store item info for incremental comparison
        table.insert(categoryViewItems, {
            itemKey = itemKey,
            bagID = itemData.bagID,
            slot = itemData.slot,
            slotKey = slotKey,
            categoryId = itemInfo.categoryId,
            count = itemData.count,
            x = itemInfo.x,
            y = itemInfo.y,
            index = index,
        })

        table.insert(itemButtons, button)

        -- Track last button per category (for drop indicator anchor)
        if itemInfo.categoryId then
            lastButtonByCategory[itemInfo.categoryId] = button
        end
    end

    ns:Debug(string.format("Category refresh: %d reused, %d acquired, %d released",
        reusedCount, acquiredCount, #buttonsToRelease))

    -- Save current layout for next incremental update comparison
    lastCategoryLayout = categoryViewItems
    -- Track item count to detect Empty/Soul category changes in incremental updates
    lastTotalItemCount = #categoryViewItems

    layoutCached = true
end

-- Register for combat end event to execute pending actions and refresh open bags
RegisterCombatEndCallback = function()
    if combatLockdownRegistered then return end
    combatLockdownRegistered = true

    Events:Register("PLAYER_REGEN_ENABLED", function()
        if pendingAction then
            local action = pendingAction
            pendingAction = nil
            if action == "show" then
                BagFrame:Show()
            elseif action == "toggle" then
                BagFrame:Toggle()
            end
        elseif frame and frame:IsShown() then
            -- Bags were already open during combat - refresh to catch any changes
            BagScanner:ScanAllBags()
            BagFrame:Refresh()
        end
    end, BagFrame)
end

function BagFrame:Toggle()
    if not frame then
        frame = CreateBagFrame()
        RestoreFramePosition()
    end

    ns:ProfileStart("Toggle")
    if frame:IsShown() then
        self:Hide()  -- keeps buttons for a fast reopen (see Hide)
    else
        self:Show()  -- takes the fast-reopen path when nothing changed
    end
    ns:ProfileStop("Toggle")
end

-- True when the frame is hidden but still holding a valid, unchanged layout, so
-- it can be re-shown without a scan/rebuild. Requires layoutCached (any layout
-- invalidation clears it) and no changes accumulated while hidden.
function BagFrame:CanFastReopen()
    return heldHidden
        and layoutCached
        and not dirtyWhileHidden
        and not viewingCharacter
        and frame and not frame:IsShown()
end

-- Tear down the retained (held-while-hidden) layout: release buttons back to the
-- shared pool and clear layout caches. No-op when the frame is shown or not held,
-- so it is safe to call from other pool consumers (bank/guild bank/mail) on open.
function BagFrame:ReleaseHeld()
    if not heldHidden then return end
    heldHidden = false
    dirtyWhileHidden = false
    if not frame then return end
    ItemButton:ReleaseAll(frame.container)
    ReleaseAllCategoryHeaders()
    buttonsBySlot = {}
    buttonsByBag = {}
    cachedItemData = {}
    cachedItemCount = {}
    cachedItemCharges = {}
    cachedItemCategory = {}
    buttonsByItemKey = {}
    buttonPositions = {}
    categoryViewItems = {}
    lastCategoryLayout = nil
    lastTotalItemCount = 0
    pseudoItemButtons = {}
    itemButtons = {}
    layoutCached = false
    lastLayoutSettings = nil
end

function BagFrame:Show()
    if not frame then
        frame = CreateBagFrame()
        RestoreFramePosition()
    end

    -- Fast reopen: the retained layout is still valid — just show it. This is the
    -- common rapid open/close case and skips the full scan + button rebuild.
    if self:CanFastReopen() then
        heldHidden = false
        -- Lightweight appearance pass: reconciles search-bar/container/footer state
        -- (cheap, ~4ms) while skipping the per-button restyle loops (already styled).
        ns:ProfileStart("fast.appearance")
        UpdateFrameAppearance(true)
        ns:ProfileStop("fast.appearance")
        ns:ProfileStart("fast.show")
        frame:Show()
        ns:ProfileStop("fast.show")
        return
    end

    -- Full path: drop any stale retained buttons, then rescan and rebuild.
    self:ReleaseHeld()
    heldHidden = false
    dirtyWhileHidden = false

    BagScanner:ScanAllBags()
    -- Clean up Recent items: both expired (time-based) and stale (no longer in bags)
    -- If any items were removed, force full button release to prevent texture artifacts
    local RecentItems = ns:GetModule("RecentItems")
    local needsFullRefresh = false
    if RecentItems then
        -- Pass true to skip event firing since we'll refresh manually
        if RecentItems:Cleanup(true) then needsFullRefresh = true end
        if RecentItems:CleanupStale() then needsFullRefresh = true end
    end
    if needsFullRefresh then
        ItemButton:ReleaseAll(frame.container)
        buttonsByItemKey = {}
    end
    self:Refresh()
    UpdateFrameAppearance(true)  -- Refresh already styled every button
    frame:Show()
end

function BagFrame:Hide()
    if not frame then return end
    ns:ProfileStart("Hide")

    -- Capture state BEFORE frame:Hide(): the frame's OnHide hook clears the search
    -- and resets viewingCharacter, both of which would make a retained layout stale.
    -- A retained layout is only valid for the current character with no active search.
    local canHold = layoutCached
        and not viewingCharacter
        and not SearchBar:HasActiveFilters(frame)

    frame:Hide()
    -- Reset transient search toggle so next open starts collapsed
    self:ResetSearchToggle()

    -- Cancel drag state tracking
    EndItemDrag()

    heldHidden = true
    if canHold then
        -- Keep buttons + layout so the next open is near-instant. Released later
        -- by ReleaseHeld if anything changes while hidden (see CanFastReopen).
        dirtyWhileHidden = false
    else
        -- Stale/invalid layout — tear it down so the next open rebuilds cleanly.
        self:ReleaseHeld()
    end
    ns:ProfileStop("Hide")
end

function BagFrame:IsShown()
    return frame and frame:IsShown()
end

function BagFrame:InvalidateLayout()
    layoutCached = false
end

function BagFrame:GetFrame()
    return frame
end

function BagFrame:GetViewingCharacter()
    return viewingCharacter
end

function BagFrame:ViewCharacter(fullName, charData)
    viewingCharacter = fullName
    Header:SetViewingCharacter(fullName, charData)

    UpdateFrameAppearance(true)  -- Refresh below restyles buttons
    self:Refresh()
end

function BagFrame:IsViewingCached()
    return viewingCharacter ~= nil
end

-- Incremental update: only update changed slots without full layout recalculation
-- dirtyBags: optional table of {bagID = true} for bags that changed
function BagFrame:IncrementalUpdate(dirtyBags)
    if not frame or not frame:IsShown() then return end

    -- Never do incremental updates while viewing a cached character
    -- Live bag events should not affect cached character display
    if viewingCharacter then return end

    -- Same guard as Refresh: a missed drag-end costs one stale frame, not a
    -- stuck UI.
    HealStaleDragState()

    -- Recent items removal is now handled by ghost slots in incremental update
    -- Just clear the flag so it doesn't accumulate
    local RecentItems = ns:GetModule("RecentItems")
    if RecentItems then
        RecentItems:WasItemRemoved()  -- Clear the flag, but don't force refresh
    end

    if not layoutCached then
        -- No cached layout, do full refresh
        self:Refresh()
        return
    end

    -- A bag was equipped or removed: the slot count changed, so the layout has
    -- to be rebuilt rather than repainted. Refresh resyncs the snapshot itself
    -- by way of the call above, so no bookkeeping is needed here.
    if SyncBagSlotLayout() then
        ns:Debug("IncrementalUpdate REFRESH: bag slot layout changed")
        self:Refresh()
        return
    end

    local bags = BagScanner:GetCachedBags()
    -- Cache settings once at start (avoid repeated GetSetting calls)
    local iconSize = Database:GetSetting("iconSize")
    local hasSearch = SearchBar:HasActiveFilters(frame)
    local viewType = Database:GetSetting("bagViewType") or "single"
    local isCategoryView = viewType == "category"

    -- If no dirty bags specified, check all (fallback behavior)
    local checkAllBags = not dirtyBags or not next(dirtyBags)

    -- Category view: Item-key-based button reuse for efficiency
    -- Buttons are tracked by item key, not by slot
    -- When items move, the SAME button follows - no expensive SetItem call needed
    if isCategoryView then
        local CategoryManager = ns:GetModule("CategoryManager")

        -- Build map of current items from bag data (by item key)
        local currentItemsByKey = {}   -- itemKey -> {itemData, bagID, slot, category}[]
        local currentItemsBySlot = {}  -- slotKey -> {itemData, itemKey, category}
        local totalCurrentItems = 0

        -- Check soul/quiver bag status for category override (must match BuildCategorySections logic)
        local BagClassifier = ns:GetModule("BagFrame.BagClassifier")
        local Database = ns:GetModule("Database")
        local hideSoulItems = Database and Database:GetSetting("hideSoulItems")
        local hideQuiverItems = Database and Database:GetSetting("hideQuiverItems")
        local soulCategoryEnabled = false
        local quiverCategoryEnabled = false
        if CategoryManager then
            local cats = CategoryManager:GetCategories()
            local soulDef = cats and cats.definitions and cats.definitions["Soul"]
            soulCategoryEnabled = soulDef and soulDef.enabled
            local quiverDef = cats and cats.definitions and cats.definitions["Quiver"]
            quiverCategoryEnabled = quiverDef and quiverDef.enabled
        end

        local bagsToShow = Constants.BAG_IDS  -- Player bags
        for _, bagID in ipairs(bagsToShow) do
            local bagData = bags[bagID]
            if bagData and bagData.slots then
                -- Detect soul/quiver bags for category override
                local bagType = BagClassifier and BagClassifier:GetBagType(bagID) or "regular"
                local isSoulBag = (bagType == "soul")
                local isQuiverBag = (bagType == "quiver" or bagType == "ammo")

                for slot, itemData in pairs(bagData.slots) do
                    if itemData then
                        local itemKey = GetItemKey(itemData)
                        local slotKey = GetSlotKey(bagID, slot)
                        -- Quiver/ammo and Soul bag items use their pseudo-category overrides
                        -- (same as BuildCategorySections)
                        local category
                        if quiverCategoryEnabled and isQuiverBag and not hideQuiverItems then
                            category = "Quiver"
                        elseif soulCategoryEnabled and isSoulBag and not hideSoulItems then
                            category = "Soul"
                        else
                            category = CategoryManager and CategoryManager:CategorizeItem(itemData, bagID, slot, false) or "Miscellaneous"
                        end

                        if not currentItemsByKey[itemKey] then
                            currentItemsByKey[itemKey] = {}
                        end
                        table.insert(currentItemsByKey[itemKey], {
                            itemData = itemData,
                            bagID = bagID,
                            slot = slot,
                            slotKey = slotKey,
                            category = category,
                        })
                        currentItemsBySlot[slotKey] = {
                            itemData = itemData,
                            itemKey = itemKey,
                            category = category,
                        }
                        totalCurrentItems = totalCurrentItems + 1
                    end
                end
            end
        end

        -- Count available ghost slots (buttons that are or will become empty)
        -- This includes:
        -- 1. Buttons already showing empty (cachedItemData is nil)
        -- 2. Buttons for slots that are NOW empty in currentItemsBySlot (item was removed)
        local ghostSlots = {}  -- Array of {slotKey, button} for reuse
        for slotKey, button in pairs(buttonsBySlot) do
            if not cachedItemData[slotKey] then
                -- This button is already showing empty (ghost) - available for reuse
                table.insert(ghostSlots, {slotKey = slotKey, button = button})
            elseif not currentItemsBySlot[slotKey] then
                -- This button's slot is now empty (item was removed) - will become ghost
                table.insert(ghostSlots, {slotKey = slotKey, button = button})
            end
        end

        -- Check if we need full refresh:
        -- 1. If any item changed categories
        -- 2. If more NEW items than available ghost slots
        -- 3. If unique item count increased beyond available buttons + ghosts
        local needsFullRefresh = false
        local newItemsNeedingButtons = {}  -- Items that need buttons (no existing key match)

        -- Count total cached buttons (excluding ghosts and slots that will become ghosts)
        local totalCachedButtons = 0
        for slotKey in pairs(buttonsBySlot) do
            if cachedItemData[slotKey] and currentItemsBySlot[slotKey] then
                -- Button has cached data AND slot still has an item (not becoming ghost)
                totalCachedButtons = totalCachedButtons + 1
            end
        end

        -- With item grouping, compare unique item types (keys) vs buttons, not slots vs buttons
        -- Multiple slots with same item share one button
        local uniqueItemCount = TableCount(currentItemsByKey)

        -- If more unique items than buttons + ghosts, need full refresh
        local totalAvailable = totalCachedButtons + #ghostSlots
        ns:Debug("CategoryView check: items=", totalCurrentItems, "unique=", uniqueItemCount, "cached=", totalCachedButtons, "ghosts=", #ghostSlots, "total=", totalAvailable)
        if uniqueItemCount > totalAvailable then
            ns:Debug("CategoryView REFRESH: more unique items", uniqueItemCount, "than available slots", totalAvailable)
            needsFullRefresh = true
        end

        -- Calculate empty slot counts and first empty slots using LIVE data (not cached)
        local BagClassifier = ns:GetModule("BagFrame.BagClassifier")
        local emptyCount = 0
        local soulEmptyCount = 0
        local quiverEmptyCount = 0
        local firstEmptyBagID, firstEmptySlot = nil, nil
        local firstSoulBagID, firstSoulSlot = nil, nil
        local firstQuiverBagID, firstQuiverSlot = nil, nil

        for bagID = 0, NUM_BAG_SLOTS do
            local numSlots = C_Container.GetContainerNumSlots(bagID)
            if numSlots and numSlots > 0 then
                local bagType = BagClassifier and BagClassifier:GetBagType(bagID) or "regular"
                local isSoulBag = (bagType == "soul")
                local isQuiverBag = (bagType == "quiver" or bagType == "ammo")
                for slot = 1, numSlots do
                    local itemInfo = C_Container.GetContainerItemInfo(bagID, slot)
                    if not itemInfo then
                        if isSoulBag then
                            soulEmptyCount = soulEmptyCount + 1
                            if not firstSoulBagID then
                                firstSoulBagID, firstSoulSlot = bagID, slot
                            end
                        elseif isQuiverBag then
                            quiverEmptyCount = quiverEmptyCount + 1
                            if not firstQuiverBagID then
                                firstQuiverBagID, firstQuiverSlot = bagID, slot
                            end
                        elseif bagType == "regular" or bagID == 0 then
                            emptyCount = emptyCount + 1
                            if not firstEmptyBagID then
                                firstEmptyBagID, firstEmptySlot = bagID, slot
                            end
                        end
                    end
                end
            end
        end

        -- Check if Empty/Soul/Quiver category needs to appear or disappear (requires full refresh)
        local emptyButtonExists = FindPseudoItemButton("Empty") ~= nil
        local emptyNeedsButton = emptyCount > 0

        if (emptyNeedsButton and not emptyButtonExists) or (not emptyNeedsButton and emptyButtonExists) then
            ns:Debug("CategoryView REFRESH: Empty category visibility changed")
            needsFullRefresh = true
        end

        local quiverButtonExists = FindPseudoItemButton("Quiver") ~= nil
        local quiverNeedsButton = quiverEmptyCount > 0
        if (quiverNeedsButton and not quiverButtonExists) or (not quiverNeedsButton and quiverButtonExists) then
            ns:Debug("CategoryView REFRESH: Quiver category visibility changed")
            needsFullRefresh = true
        end

        -- Detect items whose category has become Soul/Quiver since the last layout.
        -- Two cases need a full refresh:
        --   1. Brand-new slot: an item was looted into a previously empty soul/quiver bag slot
        --      (tracked only by the pseudo button before).
        --   2. Re-classified slot: BagClassifier returned "regular" on first render (live
        --      bagFamily not yet ready), the slot was placed under "Reagent"/"Miscellaneous"
        --      etc., then on a later BAG_UPDATE the bag is correctly classified as soul/quiver.
        --      Without this check the section would stay empty until a manual view toggle.
        if not needsFullRefresh and lastCategoryLayout then
            local prevSlotCategory = {}
            for _, prevItem in ipairs(lastCategoryLayout) do
                if prevItem.slotKey then
                    prevSlotCategory[prevItem.slotKey] = prevItem.categoryId
                end
            end
            for slotKey, currentSlot in pairs(currentItemsBySlot) do
                if currentSlot.category == "Soul" or currentSlot.category == "Quiver" then
                    local prev = prevSlotCategory[slotKey]
                    if prev == nil or prev ~= currentSlot.category then
                        ns:Debug("CategoryView REFRESH: slot", slotKey,
                            "category changed", tostring(prev), "->", currentSlot.category)
                        needsFullRefresh = true
                        break
                    end
                end
            end
        end

        -- Update pseudo-item counters and slot references directly (if no full refresh needed)
        if not needsFullRefresh then
            local emptyBtn = FindPseudoItemButton("Empty")
            if emptyBtn then
                SetItemButtonCount(emptyBtn, emptyCount)
                if emptyBtn.itemData then
                    emptyBtn.itemData.emptyCount = emptyCount
                    emptyBtn.itemData.count = emptyCount
                    if firstEmptyBagID then
                        emptyBtn.itemData.bagID = firstEmptyBagID
                        emptyBtn.itemData.slot = firstEmptySlot
                        emptyBtn.wrapper:SetID(firstEmptyBagID)
                        emptyBtn:SetID(firstEmptySlot)
                    end
                end
            end
            local soulBtn = FindPseudoItemButton("Soul")
            if soulBtn then
                SetItemButtonCount(soulBtn, soulEmptyCount)
                if soulBtn.itemData then
                    soulBtn.itemData.emptyCount = soulEmptyCount
                    soulBtn.itemData.count = soulEmptyCount
                    if firstSoulBagID then
                        soulBtn.itemData.bagID = firstSoulBagID
                        soulBtn.itemData.slot = firstSoulSlot
                        soulBtn.wrapper:SetID(firstSoulBagID)
                        soulBtn:SetID(firstSoulSlot)
                    end
                end
            end
            local quiverBtn = FindPseudoItemButton("Quiver")
            if quiverBtn then
                SetItemButtonCount(quiverBtn, quiverEmptyCount)
                if quiverBtn.itemData then
                    quiverBtn.itemData.emptyCount = quiverEmptyCount
                    quiverBtn.itemData.count = quiverEmptyCount
                    if firstQuiverBagID then
                        quiverBtn.itemData.bagID = firstQuiverBagID
                        quiverBtn.itemData.slot = firstQuiverSlot
                        quiverBtn.wrapper:SetID(firstQuiverBagID)
                        quiverBtn:SetID(firstQuiverSlot)
                    end
                end
            end
        end

        -- Update lastTotalItemCount for tracking
        lastTotalItemCount = totalCurrentItems

        -- Check for category changes in existing items
        if not needsFullRefresh and lastCategoryLayout then
            for _, prevItem in ipairs(lastCategoryLayout) do
                local currentSlot = currentItemsBySlot[prevItem.slotKey]
                if currentSlot then
                    if prevItem.categoryId ~= currentSlot.category then
                        ns:Debug("CategoryView REFRESH: category changed at", prevItem.slotKey)
                        needsFullRefresh = true
                        break
                    end
                end
            end
        end

        -- Check for new item types that need buttons
        if not needsFullRefresh then
            for itemKey, items in pairs(currentItemsByKey) do
                local existingButtons = buttonsByItemKey[itemKey]
                local hasButton = existingButtons and #existingButtons > 0
                if not hasButton then
                    local itemName = items[1] and items[1].itemData and items[1].itemData.name or "unknown"
                    ns:Debug("CategoryView: new itemKey needs button:", itemName)
                    table.insert(newItemsNeedingButtons, items[1])
                end
            end

            -- If more new item types than ghost slots available, need full refresh
            if #newItemsNeedingButtons > #ghostSlots then
                ns:Debug("CategoryView REFRESH: need", #newItemsNeedingButtons, "new buttons, only", #ghostSlots, "ghosts available")
                needsFullRefresh = true
            end
        end

        if needsFullRefresh then
            ns:Debug("CategoryView: full refresh needed — creating ghosts first")
            -- Create ghost slots for removed items BEFORE the full refresh.
            -- The ghosts are visible immediately at the item's old position.
            -- A deferred refresh runs after 1.5s to clean up the layout.
            for slotKey, button in pairs(buttonsBySlot) do
                if not button.isEmptySlotButton then
                    local currentSlot = currentItemsBySlot[slotKey]
                    local oldItemID = cachedItemData[slotKey]
                    if not currentSlot and oldItemID then
                        local bID, sID = slotKey:match("^(-?%d+):(%d+)$")
                        bID = tonumber(bID)
                        sID = tonumber(sID)
                        if bID and sID then
                            ItemButton:SetEmpty(button, bID, sID, iconSize, false)
                            cachedItemData[slotKey] = nil
                            cachedItemCount[slotKey] = nil
                            cachedItemCharges[slotKey] = nil
                        end
                    end
                end
            end
            -- Also handle grouped items that disappeared entirely
            for itemKey, buttons in pairs(buttonsByItemKey) do
                if not currentItemsByKey[itemKey] then
                    for _, button in ipairs(buttons) do
                        for slotKey, btn in pairs(buttonsBySlot) do
                            if btn == button and cachedItemData[slotKey] then
                                local bID, sID = slotKey:match("^(-?%d+):(%d+)$")
                                bID = tonumber(bID)
                                sID = tonumber(sID)
                                if bID and sID then
                                    ItemButton:SetEmpty(button, bID, sID, iconSize, false)
                                    cachedItemData[slotKey] = nil
                                    cachedItemCount[slotKey] = nil
                                    cachedItemCharges[slotKey] = nil
                                end
                                break
                            end
                        end
                    end
                end
            end
            -- Deferred full refresh to update layout structure (category changes,
            -- new items, etc.). Ghost slots stay visible until this fires.
            C_Timer.After(1.5, function()
                if frame and frame:IsShown() and not viewingCharacter then
                    self:Refresh()
                end
            end)
            -- Update footer and return
            local regularTotal, regularFree, specialBags = BagScanner:GetDetailedSlotCounts()
            local totalSlots, freeSlots = BagScanner:GetTotalSlots()
            Footer:UpdateSlotInfo(totalSlots - freeSlots, totalSlots, regularTotal, regularFree, specialBags)
            Footer:Update()
            return
        end

        -- No full refresh needed - do incremental updates
        ns:Debug("CategoryView: INCREMENTAL update starting, items=", totalCurrentItems, "ghosts=", #ghostSlots)
        local buttonsReused = 0
        local buttonsUpdated = 0
        local countUpdates = 0
        local ghostsCreated = 0
        local ghostsReused = 0

        -- First pass: Update existing slots (same slot, same or different item)
        for slotKey, button in pairs(buttonsBySlot) do
            -- Skip the Empty category pseudo-item button (it represents aggregated empty slots, not a real item)
            if not button.isEmptySlotButton then
                local currentSlot = currentItemsBySlot[slotKey]
                local oldItemID = cachedItemData[slotKey]

                if currentSlot then
                -- Slot has an item now
                local newItemData = currentSlot.itemData
                local newItemID = newItemData.itemID
                -- Same itemID can still be a different instance (ilvl/bonus swap);
                -- compare the displayed link so a same-name/different-ilvl swap
                -- isn't treated as "unchanged".
                local linkChanged = button.itemData and newItemData.link ~= button.itemData.link

                if oldItemID == newItemID and not linkChanged then
                    -- Same item - just check count
                    local oldCount = cachedItemCount[slotKey]
                    if oldCount ~= newItemData.count then
                        SetItemButtonCount(button, newItemData.count)
                        cachedItemCount[slotKey] = newItemData.count
                        countUpdates = countUpdates + 1
                    end
                    -- Item identity unchanged but charges may have decremented
                    -- (Wizard Oil, Sharpening Stone, scrolls, etc.)
                    RefreshChargesForReusedButton(button, newItemData.bagID, newItemData.slot, slotKey)
                    buttonsReused = buttonsReused + 1
                elseif oldItemID == nil then
                    -- Ghost slot getting an item back - update it
                    ItemButton:SetItem(button, newItemData, iconSize, false)
                    cachedItemData[slotKey] = newItemID
                    cachedItemCount[slotKey] = newItemData.count
                    cachedItemCategory[slotKey] = currentSlot.category
                    CacheChargesForSlot(slotKey, newItemData.bagID, newItemData.slot)
                    ghostsReused = ghostsReused + 1

                    if hasSearch then
                        ItemButton:SetSearchState(button, SearchBar:ItemMatchesFilters(frame, newItemData))
                    else
                        ItemButton:ClearSearchState(button)
                    end
                else
                    -- Different item - update button
                    ItemButton:SetItem(button, newItemData, iconSize, false)
                    cachedItemData[slotKey] = newItemID
                    cachedItemCount[slotKey] = newItemData.count
                    cachedItemCategory[slotKey] = currentSlot.category
                    CacheChargesForSlot(slotKey, newItemData.bagID, newItemData.slot)
                    buttonsUpdated = buttonsUpdated + 1

                    if hasSearch then
                        ItemButton:SetSearchState(button, SearchBar:ItemMatchesFilters(frame, newItemData))
                    else
                        ItemButton:ClearSearchState(button)
                    end
                end
            else
                -- Slot is now empty - item was removed (sold/moved/deleted)
                if oldItemID then
                    -- Show ghost slot instead of full refresh
                    -- Parse bagID and slot from slotKey (format: "bagID:slot", bagID can be negative)
                    local bagID, slot = slotKey:match("^(-?%d+):(%d+)$")
                    bagID = tonumber(bagID)
                    slot = tonumber(slot)
                    if bagID and slot then
                        ItemButton:SetEmpty(button, bagID, slot, iconSize, false)
                        cachedItemData[slotKey] = nil
                        cachedItemCount[slotKey] = nil
                        cachedItemCharges[slotKey] = nil
                        if hasSearch then
                            ItemButton:SetSearchState(button, false)
                        else
                            ItemButton:ClearSearchState(button)
                        end
                        ghostsCreated = ghostsCreated + 1
                    end
                end
            end
            end  -- end if not button.isEmptySlotButton
        end

        -- Second pass: Find buttons whose itemKey no longer exists (item completely removed)
        -- This handles grouped items where the primary slot wasn't the one removed
        for itemKey, buttons in pairs(buttonsByItemKey) do
            if not currentItemsByKey[itemKey] then
                -- This item type no longer exists - convert buttons to ghosts
                for _, button in ipairs(buttons) do
                    -- Find the slotKey for this button
                    for slotKey, btn in pairs(buttonsBySlot) do
                        if btn == button and cachedItemData[slotKey] then
                            local bagID, slot = slotKey:match("^(-?%d+):(%d+)$")
                            bagID = tonumber(bagID)
                            slot = tonumber(slot)
                            if bagID and slot then
                                ItemButton:SetEmpty(button, bagID, slot, iconSize, false)
                                cachedItemData[slotKey] = nil
                                cachedItemCount[slotKey] = nil
                                cachedItemCharges[slotKey] = nil
                                if hasSearch then
                                    ItemButton:SetSearchState(button, false)
                                else
                                    ItemButton:ClearSearchState(button)
                                end
                                ghostsCreated = ghostsCreated + 1
                            end
                            break
                        end
                    end
                end
            end
        end

        ns:Debug("CategoryView INCREMENTAL: reused=", buttonsReused, "updated=", buttonsUpdated, "counts=", countUpdates, "ghostsNew=", ghostsCreated, "ghostsReused=", ghostsReused)

        -- Update footer slot info (show regular bags only, special bags in tooltip)
        local regularTotal, regularFree, specialBags = BagScanner:GetDetailedSlotCounts()
        local totalSlots, freeSlots = BagScanner:GetTotalSlots()
        Footer:UpdateSlotInfo(totalSlots - freeSlots, totalSlots, regularTotal, regularFree, specialBags)
        Footer:Update()
        return
    end

    -- Single view: full incremental update (items stay in fixed slots)
    -- Optimized: Only iterate buttons in dirty bags using buttonsByBag index
    if checkAllBags then
        -- Fallback: check all bags
        for bagID, slotButtons in pairs(buttonsByBag) do
            local bagData = bags[bagID]
            for slot, button in pairs(slotButtons) do
                local slotKey = bagID .. ":" .. slot
                local newItemData = bagData and bagData.slots and bagData.slots[slot]
                local oldItemID = cachedItemData[slotKey]
                local newItemID = newItemData and newItemData.itemID or nil
                -- Same itemID can still be a different instance (ilvl/bonus swap);
                -- compare the displayed link too so an equip-swap of same-name,
                -- different-ilvl items repaints instead of being skipped.
                local linkChanged = newItemData and button.itemData and newItemData.link ~= button.itemData.link

                if oldItemID ~= newItemID or linkChanged then
                    if newItemData then
                        ItemButton:SetItem(button, newItemData, iconSize, false)
                        cachedItemData[slotKey] = newItemID
                        cachedItemCount[slotKey] = newItemData.count
                        CacheChargesForSlot(slotKey, bagID, slot)
                        if hasSearch then
                            ItemButton:SetSearchState(button, SearchBar:ItemMatchesFilters(frame, newItemData))
                        else
                            ItemButton:ClearSearchState(button)
                        end
                    else
                        ItemButton:SetEmpty(button, bagID, slot, iconSize, false)
                        cachedItemData[slotKey] = nil
                        cachedItemCount[slotKey] = nil
                        cachedItemCharges[slotKey] = nil
                        if hasSearch then
                            ItemButton:SetSearchState(button, false)
                        else
                            ItemButton:ClearSearchState(button)
                        end
                    end
                elseif newItemData then
                    -- Same item - only update if count changed (stacking)
                    local oldCount = cachedItemCount[slotKey]
                    if oldCount ~= newItemData.count then
                        SetItemButtonCount(button, newItemData.count)
                        cachedItemCount[slotKey] = newItemData.count
                    end
                    -- Item identity unchanged but charges may have decremented
                    RefreshChargesForReusedButton(button, bagID, slot, slotKey)
                end
            end
        end
    else
        -- Fast path: only check dirty bags (O(dirty bags) instead of O(all buttons))
        for bagID in pairs(dirtyBags) do
            local slotButtons = buttonsByBag[bagID]
            if slotButtons then
                local bagData = bags[bagID]
                for slot, button in pairs(slotButtons) do
                    local slotKey = bagID .. ":" .. slot
                    local newItemData = bagData and bagData.slots and bagData.slots[slot]
                    local oldItemID = cachedItemData[slotKey]
                    local newItemID = newItemData and newItemData.itemID or nil
                    -- Same itemID can still be a different instance (ilvl/bonus
                    -- swap); compare the displayed link too so an equip-swap of
                    -- same-name, different-ilvl items repaints instead of being
                    -- skipped as "unchanged".
                    local linkChanged = newItemData and button.itemData and newItemData.link ~= button.itemData.link

                    if oldItemID ~= newItemID or linkChanged then
                        -- Item actually changed - update button
                        if newItemData then
                            ItemButton:SetItem(button, newItemData, iconSize, false)
                            cachedItemData[slotKey] = newItemID
                            cachedItemCount[slotKey] = newItemData.count
                            CacheChargesForSlot(slotKey, bagID, slot)
                            if hasSearch then
                                ItemButton:SetSearchState(button, SearchBar:ItemMatchesFilters(frame, newItemData))
                            else
                                ItemButton:ClearSearchState(button)
                            end
                        else
                            ItemButton:SetEmpty(button, bagID, slot, iconSize, false)
                            cachedItemData[slotKey] = nil
                            cachedItemCount[slotKey] = nil
                            cachedItemCharges[slotKey] = nil
                            if hasSearch then
                                ItemButton:SetSearchState(button, false)
                            else
                                ItemButton:ClearSearchState(button)
                            end
                        end
                    elseif newItemData then
                        -- Same item - only update if count changed (stacking)
                        local oldCount = cachedItemCount[slotKey]
                        if oldCount ~= newItemData.count then
                            SetItemButtonCount(button, newItemData.count)
                            cachedItemCount[slotKey] = newItemData.count
                        end
                        -- Item identity unchanged but charges may have decremented
                        RefreshChargesForReusedButton(button, bagID, slot, slotKey)
                    end
                end
            end
        end
    end

    -- Update footer slot info (show regular bags only, special bags in tooltip)
    local regularTotal, regularFree, specialBags = BagScanner:GetDetailedSlotCounts()
    local totalSlots, freeSlots = BagScanner:GetTotalSlots()
    Footer:UpdateSlotInfo(totalSlots - freeSlots, totalSlots, regularTotal, regularFree, specialBags)
    Footer:Update()
end

-- Targeted charges-only refresh — walks already-rendered buttons and updates
-- chargesText for any slot whose charges differ from cache. Skips slots known
-- to have no charges (cache value `false`), so this is free for non-charge items.
-- Triggered by UNIT_SPELLCAST_SUCCEEDED for actions like applying Wizard Oil
-- where BAG_UPDATE may not fire reliably for charge-only state changes.
function BagFrame:RefreshChargesOnly()
    if not frame or not frame:IsShown() then return end
    if viewingCharacter then return end
    if not Database:GetSetting("showCharges") then return end
    local TS = GetTooltipScanner()
    if not TS then return end

    for slotKey, button in pairs(buttonsBySlot) do
        if not button.isEmptySlotButton and button.itemData and button.itemData.bagID then
            local cachedCharges = cachedItemCharges[slotKey]
            if cachedCharges ~= false then
                local bagID = button.itemData.bagID
                local slot = button.itemData.slot
                local newCharges = TS:GetCharges(bagID, slot) or false
                if newCharges ~= cachedCharges then
                    cachedItemCharges[slotKey] = newCharges
                    if button.chargesText then
                        if type(newCharges) == "number" and newCharges > 0 then
                            button.chargesText:SetText("x" .. newCharges)
                            button.chargesText:Show()
                        else
                            button.chargesText:Hide()
                        end
                    end
                end
            end
        end
    end
end

-- dirtyBags: table of {bagID = true} for bags that were updated
ns.OnBagsUpdated = function(dirtyBags)
    ns:Debug("OnBagsUpdated called, frame shown:", frame and frame:IsShown() or false)
    -- Inventory changed while holding a hidden layout — invalidate the fast reopen.
    if heldHidden and not (frame and frame:IsShown()) then
        dirtyWhileHidden = true
    end
    -- Only auto-refresh when viewing current character
    if not viewingCharacter then
        if frame and frame:IsShown() then
            local viewType = Database:GetSetting("bagViewType") or "single"
            ns:Debug("OnBagsUpdated refreshing, viewType:", viewType)
            -- Use incremental update if layout is cached (for both single and category view)
            -- This preserves ghost slots when items are removed
            -- Exception: when groupIdenticalItems is actively grouping (enabled + no interaction
            -- window open), incremental updates can't handle regrouping — force full refresh.
            -- When interaction window IS open, grouping is disabled, so incremental works fine
            -- and preserves ghost slots.
            local groupItems = Database:GetSetting("groupIdenticalItems")
            local groupingActive = viewType == "category" and groupItems
            if groupingActive then
                -- Check if any interaction window suppresses grouping
                local BankFrameModule = ns:GetModule("BankFrame")
                local GuildBankFrameModule = ns:GetModule("GuildBankFrame")
                if (BankFrameModule and BankFrameModule:IsShown())
                    or (GuildBankFrameModule and GuildBankFrameModule:IsShown())
                    or (MerchantFrame and MerchantFrame:IsShown())
                    or (MailFrame and MailFrame:IsShown())
                    or (TradeFrame and TradeFrame:IsShown())
                    or (AuctionFrame and AuctionFrame:IsShown())
                    or (AuctionHouseFrame and AuctionHouseFrame:IsShown())
                    or (ItemSocketingFrame and ItemSocketingFrame:IsShown()) then
                    groupingActive = false  -- Grouping suppressed, incremental is safe
                end
            end
            -- Simple removals (equip/sell/delete) don't need regrouping — allow
            -- incremental update to preserve ghost slots even with grouping active
            if groupingActive and layoutCached and lastTotalItemCount > 0 then
                local bags = BagScanner:GetCachedBags()
                local currentCount = 0
                for _, bagID in ipairs(Constants.BAG_IDS) do
                    local bagData = bags[bagID]
                    if bagData and bagData.slots then
                        for _, itemData in pairs(bagData.slots) do
                            if itemData then currentCount = currentCount + 1 end
                        end
                    end
                end
                if currentCount < lastTotalItemCount then
                    groupingActive = false  -- Removal only, incremental is safe
                end
            end
            if layoutCached and not groupingActive then
                BagFrame:IncrementalUpdate(dirtyBags)
            else
                BagFrame:Refresh()
            end
        end
    end
end

-- skipButtonRestyle: when true, skip the per-button theme/font/alpha loops. These
-- iterate every active button and are redundant on a normal open — a full rebuild
-- already styles each button in Acquire/SetItem, and a fast reopen retains styling.
-- Only the appearance/hoverBagline SETTING_CHANGED paths (which don't rebuild) need
-- the restyle, so they call this without the flag.
UpdateFrameAppearance = function(skipButtonRestyle)
    if not frame then return end

    local isViewingCached = viewingCharacter ~= nil

    -- Background alpha
    local bgAlpha = Database:GetSetting("bgAlpha") / 100
    local showBorders = Database:GetSetting("showBorders")

    -- Apply theme background (ButtonFrameTemplate for Blizzard, backdrop for Guda)
    Theme:ApplyFrameBackground(frame, bgAlpha, showBorders)

    Header:SetBackdropAlpha(bgAlpha)

    -- Per-button restyle (skipped on the hot open paths — see note above)
    if not skipButtonRestyle then
        -- Update slot background alpha (item icons stay fully visible)
        ItemButton:UpdateSlotAlpha(bgAlpha)
        ItemButton:ApplyThemeTextures()
    end

    -- Update footer button theme colors
    local Footer = ns:GetModule("Footer")
    if Footer then Footer:UpdateTheme() end

    -- Update icon font size and the Tracked/Quest bars. These bars self-update via
    -- their own SETTING_CHANGED handlers, so refreshing them here is only needed
    -- when an appearance setting actually changed (skipButtonRestyle = false).
    if not skipButtonRestyle then
        ItemButton:UpdateFontSize()
        local TrackedBar = ns:GetModule("TrackedBar")
        if TrackedBar then
            TrackedBar:UpdateFontSize()
            TrackedBar:UpdateSize()
        end
        local QuestBar = ns:GetModule("QuestBar")
        if QuestBar then
            QuestBar:UpdateFontSize()
            QuestBar:UpdateSize()
        end
    end

    -- Show/Hide search bar (always hide for cached views)
    local showSearchBar = BagFrame:IsSearchBarVisible()
    local showFooter = Database:GetSetting("showFooter")
    -- Always show footer space for cached views (money display)
    local dynamicFooterHeight = Footer:GetHeight()
    local footerHeight = (not showFooter and not isViewingCached) and Constants.FRAME.PADDING or (dynamicFooterHeight + Constants.FRAME.PADDING + 6)

    local topOffset
    if showSearchBar then
        SearchBar:Show(frame)
        topOffset = -(Header:GetHeight() + SearchBar:GetTotalHeight(frame) + Constants.FRAME.PADDING + 6)
    else
        SearchBar:Hide(frame)
        topOffset = -(Header:GetHeight() + Constants.FRAME.PADDING + 2)
    end
    -- Only re-anchor when the offsets actually changed — an identical SetPoint still
    -- dirties layout and forces frame:Show() to relayout every child button.
    if lastContainerTop ~= topOffset or lastContainerBottom ~= footerHeight then
        frame.container:ClearAllPoints()
        frame.container:SetPoint("TOPLEFT", frame, "TOPLEFT", Constants.FRAME.PADDING, topOffset)
        frame.container:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -Constants.FRAME.PADDING, footerHeight)
        lastContainerTop = topOffset
        lastContainerBottom = footerHeight
    end

    -- Footer visibility (always show money for cached views)
    if isViewingCached then
        Footer:ShowCached(viewingCharacter)
    elseif showFooter then
        Footer:Show()
    else
        Footer:Hide()
    end

end

-- Settings that only need appearance update (no full refresh)
local appearanceSettings = {
    bgAlpha = true,
    showBorders = true,
    iconFontSize = true,
    trackedBarSize = true,
    trackedBarColumns = true,
    trackedBarSpacing = true,
    questBarSize = true,
    questBarColumns = true,
    questBarSpacing = true,
    theme = true,
    retailEmptySlots = true,
    minimalEmptySlots = true,
}

-- Settings that need both appearance update AND resize
local resizeSettings = {
    showFooter = true,
    showSearchBar = true,
    showFilterChips = true,
}

-- Debounce state for QuestBar toggle
local questBarDebounceTimer = nil
local questBarLastValue = nil
local QUESTBAR_DEBOUNCE_DELAY = 0.2

local function OnSettingChanged(event, key, value)
    -- Handle QuestBar toggle instantly with debounce for rapid clicks
    if key == "showQuestBar" then
        local QuestBar = ns:GetModule("QuestBar")
        if not QuestBar then return end

        -- Cancel any pending debounce
        if questBarDebounceTimer then
            questBarDebounceTimer:Cancel()
            questBarDebounceTimer = nil
        end

        -- Show/hide instantly on first toggle
        if questBarLastValue == nil or questBarLastValue ~= value then
            if value then
                QuestBar:Show()
                QuestBar:Refresh()
            else
                QuestBar:Hide()
            end
            questBarLastValue = value
        end

        -- Debounce to reset state after rapid clicks settle
        questBarDebounceTimer = C_Timer.NewTimer(QUESTBAR_DEBOUNCE_DELAY, function()
            questBarDebounceTimer = nil
        end)
        return
    end

    -- A setting changed while holding a hidden layout invalidates the fast reopen
    -- (size/columns/view/appearance won't have been applied to the retained buttons).
    if heldHidden and not (frame and frame:IsShown()) then
        dirtyWhileHidden = true
    end

    if not frame or not frame:IsShown() then return end

    -- When changing view type while viewing another character, reset to current character
    if key == "bagViewType" and viewingCharacter then
        viewingCharacter = nil
        Header:SetViewingCharacter(nil, nil)
    end

    if appearanceSettings[key] then
        UpdateFrameAppearance()
    elseif resizeSettings[key] then
        UpdateFrameAppearance(true)  -- Refresh below restyles buttons
        BagFrame:Refresh()
    elseif key == "hoverBagline" then
        -- Refresh footer layout for hover bagline mode (preserves cached view state)
        UpdateFrameAppearance()
    elseif key == "groupIdenticalItems" then
        -- Force full release when toggling item grouping to prevent visual artifacts
        -- Item structure changes fundamentally (grouped vs individual) but keys stay same
        ItemButton:ReleaseAll(frame.container)
        buttonsByItemKey = {}
        BagFrame:Refresh()
    else
        BagFrame:Refresh()
    end
end

SaveFramePosition = function()
    if not frame then return end
    local point, _, relativePoint, x, y = frame:GetPoint()
    Database:SetSetting("framePoint", point)
    Database:SetSetting("frameRelativePoint", relativePoint)
    Database:SetSetting("frameX", x)
    Database:SetSetting("frameY", y)
end

RestoreFramePosition = function()
    if not frame then return end
    local point = Database:GetSetting("framePoint")
    local relativePoint = Database:GetSetting("frameRelativePoint")
    local x = Database:GetSetting("frameX")
    local y = Database:GetSetting("frameY")

    frame:ClearAllPoints()
    if point and x and y then
        frame:SetPoint(point, UIParent, relativePoint, x, y)
    else
        -- Default position: bottom-right corner
        frame:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -5, 5)
    end
end

-- Sort bags using SortEngine
function BagFrame:SortBags()
    local SortEngine = ns:GetModule("SortEngine")
    if SortEngine then
        SortEngine:SortBags()
    else
        ns:Print("SortEngine not loaded")
    end
end

-- Restack items and clean ghost slots (for category view)
-- This combines partial stacks without fully sorting the bags
function BagFrame:RestackAndClean()
    if not frame or not frame:IsShown() then return end

    -- Play sound feedback
    PlaySound(SOUNDKIT.IG_BACKPACK_OPEN)

    -- Use SortEngine's restack function (consolidates stacks without sorting)
    local SortEngine = ns:GetModule("SortEngine")
    if SortEngine then
        SortEngine:RestackBags(function()
            -- Callback when restack is complete - now clean ghost slots
            C_Timer.After(0.1, function()
                if frame and frame:IsShown() then
                    -- Release all buttons first (they would be orphaned otherwise)
                    ItemButton:ReleaseAll(frame.container)

                    -- Clear all layout caches (removes ghost slots)
                    buttonsBySlot = {}
                    buttonsByBag = {}
                    cachedItemData = {}
                    cachedItemCount = {}
                    cachedItemCharges = {}
                    cachedItemCategory = {}
                    buttonsByItemKey = {}
                    buttonPositions = {}
                    categoryViewItems = {}
                    lastCategoryLayout = nil
                    lastTotalItemCount = 0
                    pseudoItemButtons = {}
                    layoutCached = false
                    lastLayoutSettings = nil

                    -- Rescan and refresh
                    BagScanner:ScanAllBags()
                    BagFrame:Refresh()
                end
            end)
        end)
    else
        -- Fallback if no SortEngine
        BagScanner:ScanAllBags()
        BagFrame:Refresh()
    end
end

-- Clean ghost slots without restacking (used when items are removed externally, e.g., leaving BG)
function BagFrame:Clean()
    if not frame then return end

    -- Release all buttons (they would be orphaned otherwise)
    ItemButton:ReleaseAll(frame.container)

    -- Clear all layout caches (removes ghost slots)
    buttonsBySlot = {}
    buttonsByBag = {}
    cachedItemData = {}
    cachedItemCount = {}
    cachedItemCharges = {}
    cachedItemCategory = {}
    buttonsByItemKey = {}
    buttonPositions = {}
    categoryViewItems = {}
    lastCategoryLayout = nil
    lastTotalItemCount = 0
    pseudoItemButtons = {}
    layoutCached = false
    lastLayoutSettings = nil

    -- Rescan and refresh
    BagScanner:ScanAllBags()
    if frame:IsShown() then
        BagFrame:Refresh()
    end
end

function BagFrame:TransferMatchedItems()
    if InCombatLockdown() then
        UIErrorsFrame:AddMessage(L["TRANSFER_COMBAT"], 1.0, 0.1, 0.1, 1.0)
        return
    end
    if not frame then return end

    local bags = BagScanner:GetCachedBags()
    if not bags then return end

    -- Determine target bank type for UseContainerItem
    local bankType = nil
    if ns.IsRetail then
        local BankFooter = ns:GetModule("BankFrame.BankFooter")
        if BankFooter then
            local currentBankType = BankFooter:GetCurrentBankType()
            if currentBankType == "warband" then
                bankType = Enum.BankType.Account
            end
        end
    end

    for bagID, bagData in pairs(bags) do
        if bagData.slots then
            for slot, itemData in pairs(bagData.slots) do
                if itemData and itemData.itemID and SearchBar:ItemMatchesFilters(frame, itemData) then
                    C_Container.UseContainerItem(bagID, slot, nil, bankType)
                end
            end
        end
    end
end

Events:Register("SETTING_CHANGED", OnSettingChanged, BagFrame)

-- Refresh when categories are updated (reordered, grouped, etc.)
-- Force full refresh by releasing all buttons since category assignments changed
Events:Register("CATEGORIES_UPDATED", function()
    if frame and frame:IsShown() then
        -- Release all buttons to force full refresh (category assignments changed)
        ItemButton:ReleaseAll(frame.container)
        buttonsByItemKey = {}
        BagFrame:Refresh()
    end
end, BagFrame)

-- Update money display when money changes
Events:Register("PLAYER_MONEY", function()
    if frame and frame:IsShown() then
        Footer:UpdateMoney()
        Database:SaveMoney(GetMoney())
    end
end, BagFrame)

-- Refresh charge counters after the player casts something. Applying Wizard
-- Oil, Sharpening Stones, scrolls, etc. fires UNIT_SPELLCAST_SUCCEEDED but
-- does not always fire BAG_UPDATE for the charge-only state change. The 50ms
-- delay lets the local item record settle before the tooltip is re-scanned.
-- Heavy combat fires this event many times per second; the pending flag
-- coalesces all casts in a 50ms window into a single refresh pass.
local chargesRefreshPending = false
Events:Register("UNIT_SPELLCAST_SUCCEEDED", function(event, unit)
    if unit ~= "player" then return end
    if not frame or not frame:IsShown() then return end
    if viewingCharacter then return end
    if chargesRefreshPending then return end
    chargesRefreshPending = true
    C_Timer.After(0.05, function()
        chargesRefreshPending = false
        BagFrame:RefreshChargesOnly()
    end)
end, BagFrame)

-- Lock self-heal watcher.
--
-- On retail, equipping/swapping an item briefly locks its bag slot, but the
-- *unlock* often does NOT emit ITEM_LOCK_CHANGED for that slot (verified: the
-- slot unlocks ~0.25-0.5s later with no event). Because GudaBags drives the
-- lock visual from events (its custom OnUpdate doesn't poll isLocked like
-- Blizzard's stock button), the slot stays desaturated until the next full
-- refresh (bag toggle). When a slot locks, briefly poll it until it unlocks,
-- then reconcile the visual against the live API.
local lockWatchActive = {}
local function ReconcileSlot(bagID, slotID)
    if not (frame and frame:IsShown() and not viewingCharacter) then return end
    local BagScanner = ns:GetModule("BagScanner")
    if BagScanner then
        BagScanner:ScanDirtyBags({ [bagID] = true })
        if ns.OnBagsUpdated then ns.OnBagsUpdated({ [bagID] = true }) end
    end
    -- IncrementalUpdate skips SetItem when the itemID is unchanged, so repaint
    -- the lock visual explicitly for the same-item case.
    ItemButton:UpdateLockForItem(bagID, slotID)
end

local function StartLockWatch(bagID, slotID)
    -- Sorting/restacking lock many slots rapidly and have their own completion
    -- handling; don't spawn watchers for those.
    local SortEngine = ns:GetModule("SortEngine")
    if SortEngine and (SortEngine:IsSorting() or SortEngine:IsRestacking()) then return end

    local key = bagID .. ":" .. slotID
    if lockWatchActive[key] then return end
    lockWatchActive[key] = true

    local ticks = 0
    local stableTicks = 0
    local startInfo = C_Container.GetContainerItemInfo(bagID, slotID)
    local lastItem = startInfo and startInfo.itemID
    local lastLocked = startInfo and startInfo.isLocked or false
    local lastLink = startInfo and startInfo.hyperlink

    C_Timer.NewTicker(0.2, function(self)
        ticks = ticks + 1
        local info = C_Container.GetContainerItemInfo(bagID, slotID)
        local item = info and info.itemID
        local locked = info and info.isLocked or false
        local link = info and info.hyperlink

        -- Treat a link change as a change too: a same-itemID/different-ilvl
        -- equip-swap keeps the itemID but changes the link.
        local changed = (item ~= lastItem) or (locked ~= lastLocked) or (link ~= lastLink)
        if changed then
            lastItem, lastLocked, lastLink = item, locked, link
            stableTicks = 0
            -- Reconcile the UI to whatever the API now reports (covers both the
            -- silent unlock and a late content swap that fired no BAG_UPDATE).
            ReconcileSlot(bagID, slotID)
        else
            stableTicks = stableTicks + 1
        end

        -- Stop once the slot has been unlocked and unchanged for ~0.6s, or after
        -- a generous timeout (slow servers can take seconds to settle a swap).
        if (not locked and stableTicks >= 3) or ticks >= 75 then
            lockWatchActive[key] = nil
            self:Cancel()
        end
    end)
end

-- GET_ITEM_INFO_RECEIVED fires once per itemID as async item data finishes
-- loading. When an item arrives, its tooltip scan (isUsable, isQuestItem,
-- hasSpecialProperties) becomes reliable; repaint any open buttons that show
-- it so the false-positive red overlay clears.
local pendingItemRefresh = {}
local itemRefreshTimer
local itemRefreshDeferred = false

local function ApplyItemInfoRefresh()
    itemRefreshTimer = nil
    if not (frame and frame:IsShown()) or viewingCharacter then
        wipe(pendingItemRefresh)
        return
    end
    if InCombatLockdown() then
        -- PLAYER_REGEN_ENABLED already triggers a Refresh of open bags
        -- (see RegisterCombatEndCallback). Let it pick this up.
        itemRefreshDeferred = true
        return
    end
    itemRefreshDeferred = false

    local ItemScanner = ns:GetModule("ItemScanner")
    if not ItemScanner then
        wipe(pendingItemRefresh)
        return
    end

    local iconSize = Database:GetSetting("iconSize")
    local hasSearch = SearchBar:HasActiveFilters(frame)
    local bags = BagScanner:GetCachedBags() or {}
    local repainted = 0
    for _, button in ipairs(itemButtons) do
        local oldData = button.itemData
        if oldData and oldData.itemID and pendingItemRefresh[oldData.itemID]
            and oldData.bagID and oldData.slot then
            local newData = ItemScanner:ScanSlot(oldData.bagID, oldData.slot)
            if newData and newData.itemID == oldData.itemID then
                local bagData = bags[oldData.bagID]
                if bagData and bagData.slots then
                    bagData.slots[oldData.slot] = newData
                end
                ItemButton:SetItem(button, newData, iconSize, false)
                if hasSearch then
                    ItemButton:SetSearchState(button, SearchBar:ItemMatchesFilters(frame, newData))
                else
                    ItemButton:ClearSearchState(button)
                end
                repainted = repainted + 1
            end
        end
    end
    wipe(pendingItemRefresh)
    if repainted > 0 then
        ns:Debug("BagFrame: GET_ITEM_INFO_RECEIVED repainted", repainted, "buttons")
    end
end

local function ScheduleItemRefresh()
    if itemRefreshTimer then return end
    itemRefreshTimer = C_Timer.NewTimer(0.15, ApplyItemInfoRefresh)
end

Events:Register("GET_ITEM_INFO_RECEIVED", function(_, itemID, success)
    if not success or not itemID then return end
    if not (frame and frame:IsShown()) or viewingCharacter then return end
    pendingItemRefresh[itemID] = true
    ScheduleItemRefresh()
end, BagFrame)

-- Drain any deferred-during-combat refresh once combat ends. (PLAYER_REGEN_ENABLED
-- already does a broader Refresh, but only if pendingAction is set; piggyback so
-- the targeted repaint still runs when bags were already open during combat.)
Events:Register("PLAYER_REGEN_ENABLED", function()
    if itemRefreshDeferred and next(pendingItemRefresh) then
        ScheduleItemRefresh()
    end
end, "BagFrame.ItemInfoRefresh")

-- Update item lock state (when picking up/putting down items)
Events:Register("ITEM_LOCK_CHANGED", function(event, bagID, slotID)
    -- Skip when viewing cached character - lock state is for current character only
    if viewingCharacter then return end
    if frame and frame:IsShown() and bagID and slotID then
        ItemButton:UpdateLockForItem(bagID, slotID)
        -- Only watch when this is a lock (not an unlock); the unlock is what we
        -- may never be told about. No point watching while bags are closed.
        local info = C_Container.GetContainerItemInfo(bagID, slotID)
        if info and info.isLocked then
            StartLockWatch(bagID, slotID)
        end
    end

    -- Detect drag start for showing the flyout drop bar (all views) and the
    -- empty-category drop targets (category view only).
    -- Deferred by one frame to distinguish equip operations (cursor clears within
    -- the same frame) from actual user drags (cursor persists across frames).
    -- Without this, right-click equip triggers false drag detection because the
    -- WoW client briefly puts the item on the cursor during the internal swap,
    -- causing two full Refresh() calls that destroy ghost slots.
    if frame and frame:IsShown() and not viewingCharacter and not isDraggingItem then
        C_Timer.After(0, function()
            if isDraggingItem then return end
            if not frame or not frame:IsShown() then return end
            if viewingCharacter then return end
            -- Ignore lock events while the sort engine is moving items
            local SortEngine = ns:GetModule("SortEngine")
            if SortEngine and (SortEngine:IsSorting() or SortEngine:IsRestacking()) then
                return
            end
            local cursorType, cursorItemID = GetCursorInfo()
            if cursorType == "item" then
                isDraggingItem = true

                -- Install the teardown FIRST.
                --
                -- This ticker is the only thing that ends a drag. It used to be
                -- created last, after the flyout and the category-view Refresh
                -- below -- so if either of those raised, the callback aborted
                -- with isDraggingItem already true and no ticker to ever clear
                -- it. That is precisely why category view (which alone calls
                -- Refresh here) got stuck while single view did not. A cosmetic
                -- step must never be able to strand the state machine.
                dragCheckTicker = C_Timer.NewTicker(0.1, function()
                    if not CursorHasItem() then
                        EndItemDrag()
                        if frame and frame:IsShown() then
                            local viewType = Database:GetSetting("bagViewType") or "single"
                            if viewType == "category" then
                                BagFrame:Refresh()
                            end
                        end
                    end
                end)

                local sourceBag, sourceSlot, source = BagFrame:GetCursorBagSlot()

                local DragFlyoutBar = ns:GetModule("DragFlyoutBar")
                if DragFlyoutBar then
                    DragFlyoutBar:OnDragStart(cursorItemID, sourceBag, sourceSlot, source)
                end

                local viewType = Database:GetSetting("bagViewType") or "single"
                if viewType == "category" then
                    BagFrame:Refresh()
                end
            end
        end)
    end
end, BagFrame)

-- Clean ghost slots when entering world (leaving BG, instance, etc.)
-- This handles temporary items being removed (e.g., AV-only items when leaving AV)
Events:Register("PLAYER_ENTERING_WORLD", function()
    -- Small delay to let bag contents stabilize after zone transition
    C_Timer.After(0.5, function()
        BagFrame:Clean()
    end)
end, BagFrame)

-- Refresh when interaction windows open/close to toggle item grouping
-- Items are shown ungrouped when bank/trade/mail/merchant/auction is open
local function RefreshForInteractionWindow()
    if frame and frame:IsShown() then
        -- Defer during combat - PLAYER_REGEN_ENABLED will refresh open bags
        if InCombatLockdown() then
            RegisterCombatEndCallback()
            return
        end
        local viewType = Database:GetSetting("bagViewType") or "single"
        if viewType == "category" then
            -- Force full refresh since grouping state changed
            ItemButton:ReleaseAll(frame.container)
            buttonsByItemKey = {}
            BagFrame:Refresh()
        end
    end
end

-- Public entry point so external interaction modules (e.g. GuildBankFrame) route
-- through the same view-aware logic: only category view needs a re-render to
-- unstack/restack grouped items. In single view there is no grouping, so skipping
-- the refresh avoids a pointless ~80ms full bag render on every open/close.
function BagFrame:RefreshForInteraction()
    RefreshForInteractionWindow()
end

-- Trade window
Events:Register("TRADE_SHOW", RefreshForInteractionWindow, BagFrame)
Events:Register("TRADE_CLOSED", RefreshForInteractionWindow, BagFrame)

-- Mail window
Events:Register("MAIL_SHOW", RefreshForInteractionWindow, BagFrame)
Events:Register("MAIL_CLOSED", RefreshForInteractionWindow, BagFrame)

-- Merchant/Vendor window
Events:Register("MERCHANT_SHOW", RefreshForInteractionWindow, BagFrame)
Events:Register("MERCHANT_CLOSED", RefreshForInteractionWindow, BagFrame)

-- Auto-vendor items the category system classifies as "Junk".
-- Asks CategoryManager for the resolved category (which respects user
-- itemOverrides), so items the user manually moved to Junk get sold and items
-- they moved out of Junk are preserved — independent of the item's quality.
local function AutoVendorJunk()
    if not Database:GetSetting("autoVendorJunk") then return end

    local CategoryManager = ns:GetModule("CategoryManager")
    if not CategoryManager then return end

    local BagScanner = ns:GetModule("BagScanner")
    local cachedBags = BagScanner and BagScanner:GetCachedBags() or {}

    local totalPrice = 0
    local itemsSold = 0
    local EquipSets = ns:GetModule("EquipmentSets")
    local autoLockSets = Database:GetSetting("autoLockSetItems")

    for bagID = Constants.PLAYER_BAG_MIN, Constants.PLAYER_BAG_MAX do
        local numSlots = C_Container.GetContainerNumSlots(bagID)
        for slot = 1, numSlots do
            local itemInfo = C_Container.GetContainerItemInfo(bagID, slot)
            if itemInfo and not Database:IsItemLocked(itemInfo.itemID)
                and not (autoLockSets and EquipSets and EquipSets:IsInSet(itemInfo.itemID)) then
                -- Prefer the scanner's full itemData (rich fields for rule
                -- evaluation); fall back to a minimal inline build if the
                -- cache is missing or stale for this slot. itemOverrides
                -- only need itemID, so the fallback is enough for the
                -- user-assignment path even before the scanner catches up.
                local cachedSlots = cachedBags[bagID] and cachedBags[bagID].slots
                local itemData = cachedSlots and cachedSlots[slot]
                if not itemData or itemData.itemID ~= itemInfo.itemID then
                    itemData = {
                        itemID = itemInfo.itemID,
                        quality = itemInfo.quality,
                        hyperlink = itemInfo.hyperlink,
                    }
                end

                if CategoryManager:CategorizeItem(itemData, bagID, slot, false) == "Junk" then
                    local _, _, _, _, _, _, _, _, _, _, sellPrice = GetItemInfo(itemInfo.hyperlink)
                    if sellPrice and sellPrice > 0 then
                        C_Container.UseContainerItem(bagID, slot)
                        totalPrice = totalPrice + sellPrice * itemInfo.stackCount
                        itemsSold = itemsSold + 1
                    end
                end
            end
        end
    end

    if itemsSold > 0 then
        ns:Print(string.format(L["AUTO_VENDOR_SOLD"], itemsSold, GetCoinTextureString(totalPrice)))
    end
end
Events:Register("MERCHANT_SHOW", AutoVendorJunk, "AutoVendor")

-- Auto-repair at repair-capable merchants
local function AutoRepair()
    if not Database:GetSetting("autoRepair") then return end
    if not CanMerchantRepair() then return end

    local repairCost, canRepair = GetRepairAllCost()
    if canRepair and repairCost > 0 then
        if GetMoney() >= repairCost then
            RepairAllItems()
            ns:Print(string.format(L["AUTO_REPAIR_COST"], GetCoinTextureString(repairCost)))
        else
            ns:Print(string.format(L["AUTO_REPAIR_NO_MONEY"], GetCoinTextureString(repairCost)))
        end
    end
end
Events:Register("MERCHANT_SHOW", AutoRepair, "AutoRepair")

-- Auction house
Events:Register("AUCTION_HOUSE_SHOW", RefreshForInteractionWindow, BagFrame)
Events:Register("AUCTION_HOUSE_CLOSED", RefreshForInteractionWindow, BagFrame)

-- Auto open/close bags on interaction windows.
--
--   * If the addon opened the bags for an interaction, it closes them when the
--     interaction ends.
--   * If the user already had the bags open (or opens them mid-interaction with
--     B / X), the addon leaves them alone — bagsAutoOpened is cleared by the
--     frame's OnHide hook the moment the user closes the bags.
--
-- Blizzard's stock MailFrame/MerchantFrame/etc. OnEvent runs BEFORE our handler
-- in the same event dispatch. We rely on two cooperating pieces:
--   * The OpenAllBags / OpenBag / OpenBackpack overrides (further down) capture
--     frame:IsShown() BEFORE calling Show, so they can reliably tell whether
--     Blizzard's auto-call actually opened the bags (wasShown=false) or the
--     user had them open already (wasShown=true). They set bagsAutoOpened only
--     in the former case.
--   * inInteraction is set by SmartAutoOpen and cleared by SmartAutoClose, so
--     Blizzard's CloseAllBags during MAIL_CLOSED short-circuits and defers to
--     SmartAutoClose's "did the addon open this?" check.

local function SmartAutoOpen()
    inInteraction = true
    if not Database:GetSetting("autoOpenBags") then return end

    -- If Blizzard's MailFrame/MerchantFrame/etc. already called OpenAllBags in
    -- this same event dispatch, our override has already shown the bag and
    -- (if it was previously closed) set bagsAutoOpened. Nothing left to do.
    -- Otherwise (e.g. Blizzard's "Open Bags Automatically" option is off, or
    -- this is the bank/guild-bank path that doesn't call OpenAllBags), open
    -- the bag ourselves and claim it.
    if not frame or not frame:IsShown() then
        BagFrame:Show()
        bagsAutoOpened = true
    end
end

local function SmartAutoClose()
    if bagsAutoOpened and Database:GetSetting("autoCloseBags") then
        BagFrame:Hide()  -- OnHide hook clears bagsAutoOpened
    end
    -- Defer the inInteraction clear by one frame so the gate in CloseAllBags /
    -- CloseBag / CloseBackpack stays effective for ALL of Blizzard's interaction
    -- handlers in the current event dispatch, regardless of whether they run
    -- before or after this handler. The order between Blizzard's MerchantFrame
    -- (and MailFrame, etc.) OnEvent and our addon's eventFrame OnEvent is not
    -- guaranteed. Without this defer, when our handler wins the race,
    -- Blizzard's subsequent CloseAllBags (called from *_OnHide) would see
    -- inInteraction=false and forcibly hide the bags — breaking the
    -- "user-opened bags stay open" and "autoCloseBags=off" guarantees.
    C_Timer.After(0, function() inInteraction = false end)
end

-- Public hooks so GuildBankFrame (and any other future external interaction
-- module) can route through the same smart-open/close logic.
function BagFrame:OnAutoInteractionOpen()  SmartAutoOpen()  end
function BagFrame:OnAutoInteractionClose() SmartAutoClose() end

local function OnInteractionOpen()
    SmartAutoOpen()
    -- Keep bags at base level so the interaction frame stays on top (whether
    -- the addon or the user opened the bags).
    C_Timer.After(0, function()
        if frame and frame:IsShown() then
            frame:SetFrameLevel(Constants.FRAME_LEVELS.BASE)
            Theme:SyncBlizzardBgLevel(frame)
            if frame.container then
                frame.container:SetFrameLevel(Constants.FRAME_LEVELS.BASE + Constants.FRAME_LEVELS.CONTAINER)
                ItemButton:SyncFrameLevels(frame.container)
            end
        end
    end)
    -- Deferred refresh to unstack grouped items — interaction frame needs a frame to be fully shown
    -- so IsInteractionWindowOpen() can detect it
    C_Timer.After(0.05, function()
        if frame and frame:IsShown() then
            BagFrame:Refresh()
        end
    end)
end

local function OnInteractionClose()
    SmartAutoClose()
    -- Deferred refresh to re-enable grouping after interaction window fully closes
    C_Timer.After(0.05, function()
        if frame and frame:IsShown() then
            BagFrame:Refresh()
        end
    end)
end

local function OnBankOpen()
    SmartAutoOpen()
    -- Keep bags at base level and raise the bank frame above them (whether the
    -- addon or the user opened the bags).
    C_Timer.After(0, function()
        if frame and frame:IsShown() then
            frame:SetFrameLevel(Constants.FRAME_LEVELS.BASE)
            Theme:SyncBlizzardBgLevel(frame)
            if frame.container then
                frame.container:SetFrameLevel(Constants.FRAME_LEVELS.BASE + Constants.FRAME_LEVELS.CONTAINER)
                ItemButton:SyncFrameLevels(frame.container)
            end
        end
        local BankFrameModule = ns:GetModule("BankFrame")
        if BankFrameModule then
            local bankFrame = BankFrameModule:GetFrame()
            if bankFrame then
                bankFrame:SetFrameLevel(Constants.FRAME_LEVELS.RAISED)
                Theme:SyncBlizzardBgLevel(bankFrame)
                if bankFrame.container then
                    bankFrame.container:SetFrameLevel(Constants.FRAME_LEVELS.RAISED + Constants.FRAME_LEVELS.CONTAINER)
                    ItemButton:SyncFrameLevels(bankFrame.container)
                end
            end
        end
    end)
end

local function OnBankClose()
    SmartAutoClose()
end

Events:Register("TRADE_SHOW", OnInteractionOpen, "AutoOpenBags_Trade")
Events:Register("TRADE_CLOSED", OnInteractionClose, "AutoCloseBags_Trade")
Events:Register("MAIL_SHOW", OnInteractionOpen, "AutoOpenBags_Mail")
Events:Register("MAIL_CLOSED", OnInteractionClose, "AutoCloseBags_Mail")
Events:Register("MERCHANT_SHOW", OnInteractionOpen, "AutoOpenBags_Vendor")
Events:Register("MERCHANT_CLOSED", OnInteractionClose, "AutoCloseBags_Vendor")
Events:Register("AUCTION_HOUSE_SHOW", OnInteractionOpen, "AutoOpenBags_AH")
Events:Register("AUCTION_HOUSE_CLOSED", OnInteractionClose, "AutoCloseBags_AH")
-- Socketing UI — load-on-demand, so hook via SOCKET_INFO_UPDATE event
local socketFrameHooked = false
Events:Register("SOCKET_INFO_UPDATE", function()
    OnInteractionOpen()
    -- Hook OnHide for close detection (only once, after frame is created)
    if not socketFrameHooked and ItemSocketingFrame then
        socketFrameHooked = true
        ItemSocketingFrame:HookScript("OnHide", function()
            OnInteractionClose()
        end)
    end
end, "AutoOpenBags_Socket")
Events:Register("BANKFRAME_OPENED", OnBankOpen, "AutoOpenBags_Bank")
Events:Register("BANKFRAME_CLOSED", OnBankClose, "AutoCloseBags_Bank")

-- Bank window (our own bank frame showing affects grouping)
-- Small delay on open to ensure BankFrame is fully shown before checking
Events:Register("BANKFRAME_OPENED", function()
    C_Timer.After(0.05, function()
        RefreshForInteractionWindow()
        if frame then SearchBar:UpdateTransferState(frame) end
    end)
end, BagFrame)
Events:Register("BANKFRAME_CLOSED", function()
    RefreshForInteractionWindow()
    if frame then SearchBar:UpdateTransferState(frame) end
end, BagFrame)

Events:OnPlayerLogin(function()
    isInitialized = true
    ns:Print(string.format(L["ADDON_LOADED"], ns.version))

    -- Pre-create the bag frame and pre-warm item button pool
    -- This must happen before combat to avoid taint issues when opening bags during combat
    -- (ContainerFrameItemButtonTemplate is a secure template that cannot be created during combat)
    if not frame then
        frame = CreateBagFrame()
        RestoreFramePosition()
    end
    ItemButton:PreWarm(frame.container, 200)

    -- After login settles, grow the button pool in the background to cover a large
    -- bank's All-Tabs view (bags ~190 + bank ~550). Secure-frame creation is the bulk
    -- of the first big open's freeze; doing it across idle frames here makes the first
    -- bank open cheap. Aborts itself if a frame opens first; pauses during combat.
    C_Timer.After(3, function()
        if frame then ItemButton:BackgroundGrowPool(frame.container, 750) end
    end)

    -- Override default bag functions to use GudaBags
    ToggleBackpack = function()
        BagFrame:Toggle()
    end

    ToggleBag = function(bagID)
        BagFrame:Toggle()
    end

    -- OpenAllBags / OpenBag / OpenBackpack:
    --   Pass through to GudaBags so macros calling these still work, but gate
    --   by autoOpenBags so Blizzard's MailFrame/MerchantFrame internal calls
    --   respect the user's auto-open setting.
    --
    --   If the bags are already shown, return early WITHOUT calling Show. This
    --   is critical: Blizzard's MailFrame calls OpenAllBags on every
    --   MAIL_INBOX_UPDATE (and similar refresh events) during a mail session,
    --   so this override fires repeatedly. Calling frame:Show() on an
    --   already-shown frame can trigger a spurious OnHide → OnShow cycle on
    --   Classic Anniversary, which our OnHide hook interprets as the user
    --   closing bags — clearing bagsAutoOpened and breaking the smart-close
    --   path at MAIL_CLOSED. The guard makes repeat calls a true no-op.
    --
    --   First-call semantics: if wasShown == false, this is the one true
    --   addon-driven open for this interaction. Mark bagsAutoOpened = true so
    --   SmartAutoClose knows to close them when the interaction ends.
    local function DoBlizzardOpen()
        if not Database:GetSetting("autoOpenBags") then return end
        if frame and frame:IsShown() then return end
        BagFrame:Show()
        bagsAutoOpened = true
    end
    OpenAllBags  = DoBlizzardOpen
    OpenBag      = function(bagID) DoBlizzardOpen() end
    OpenBackpack = DoBlizzardOpen

    -- CloseAllBags / CloseBag / CloseBackpack:
    --   Short-circuit while inInteraction is true. Blizzard's stock interaction
    --   handlers (MailFrame_OnEvent etc.) call CloseAllBags BEFORE our own
    --   handler runs in the same event dispatch — letting it through would
    --   close bags before SmartAutoClose can apply the "did the addon open
    --   them?" check. Macros calling these outside an interaction still close
    --   the bags normally.
    local function DoBlizzardClose()
        if inInteraction then
            -- Inside an active interaction (mail/vendor/AH/etc.). Blizzard's stock
            -- *_OnHide handler is calling CloseAllBags as part of its close path.
            -- Treat this as the canonical interaction-close signal and apply our
            -- smart close, then let MAIL_CLOSED / MERCHANT_CLOSED / etc. fire
            -- afterwards (where SmartAutoClose is idempotent — bagsAutoOpened will
            -- already be false from this call's Hide → OnHide hook).
            --
            -- Why we can't just rely on the event: in Classic Anniversary,
            -- MAIL_CLOSED is not dispatched to addon event frames (or fires too
            -- late), so the only reliable close signal for mail is Blizzard's
            -- CloseAllBags call here.
            SmartAutoClose()
            return
        end
        BagFrame:Hide()
    end
    CloseAllBags  = DoBlizzardClose
    CloseBag      = function(bagID) DoBlizzardClose() end
    CloseBackpack = DoBlizzardClose

    ToggleAllBags = function()
        BagFrame:Toggle()
    end
end, BagFrame)
