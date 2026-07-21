local addonName, ns = ...

local Header = {}
ns:RegisterModule("Header", Header)

local Constants = ns.Constants
local L = ns.L
local Database = ns:GetModule("Database")
local Font = ns:GetModule("Font")
local HeaderButtonVisibility = ns:GetModule("HeaderButtonVisibility")
local HeaderViewControls = ns:GetModule("HeaderViewControls")
local IconButton = ns:GetModule("IconButton")
local ItemButton = ns:GetModule("ItemButton")
local SearchToggleButton = ns:GetModule("SearchToggleButton")
local Theme = ns:GetModule("Theme")

local frame = nil
local onDragStop = nil
local viewingCharacterData = nil

local Characters = nil
local BankCharacters = nil

-- Debounce for sort/restack button
local lastSortTime = 0
local SORT_DEBOUNCE = 0.5  -- 500ms debounce

-------------------------------------------------
-- Drag proxy
--
-- Moving the real window means the client re-anchors its entire widget tree
-- every frame -- ~200 item buttons (Rule 3 PreWarm) plus each button's
-- textures. 3.3.5a does that badly enough to stutter the whole game.
--
-- So the real window never moves during a drag. It stays exactly where it is
-- at alpha 0 while a single empty outline frame follows the cursor, and on
-- release the window is repositioned once to wherever the outline ended up.
-- One frame moving instead of thousands of regions.
--
-- Alpha rather than Hide, deliberately:
--   * a hidden frame receives no mouse events, so OnDragStop -- which lives on
--     the (now hidden) title bar -- would never fire and the window would be
--     stranded invisible;
--   * hiding the container would be a protected action while its secure item
--     buttons are shown, so it would break during combat (Rule 3).
-- SetAlpha is neither.
-------------------------------------------------
local dragProxy = nil
local dragOwner = nil
local dragFaded = {}   -- frame -> alpha to restore. Reused, never reallocated.

local function IsDescendantOf(frame, ancestor)
    local p = frame
    while p do
        if p == ancestor then return true end
        p = p.GetParent and p:GetParent() or nil
    end
    return false
end

-- Frames that move with the window but are NOT its children, so SetAlpha on
-- the window does not reach them.
--
-- The bag frame's item buttons live in a top-level secureButtonContainer that
-- is only ANCHORED to the window (see BagFrame.lua -- it is kept off the
-- window's child tree so the window stays unprotected and can be shown in
-- combat). Fading only the window therefore left every item button on screen,
-- parked at the old position until release.
local function FadeForDrag(owner)
    dragFaded[owner] = owner:GetAlpha()
    owner:SetAlpha(0)

    local container = owner.container
    if container and container.SetAlpha and not IsDescendantOf(container, owner) then
        dragFaded[container] = container:GetAlpha()
        container:SetAlpha(0)
    end
end

local function UnfadeAfterDrag()
    for frame, alpha in pairs(dragFaded) do
        frame:SetAlpha(alpha or 1)
        dragFaded[frame] = nil
    end
end

local function GetDragProxy()
    if dragProxy then return dragProxy end

    local p = CreateFrame("Frame", "GudaBagsDragProxy", UIParent, "BackdropTemplate")
    p:SetMovable(true)
    p:SetClampedToScreen(true)
    p:EnableMouse(false)   -- must not swallow the mouse-up that ends the drag
    p:SetFrameStrata("TOOLTIP")
    p:Hide()

    p:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    p:SetBackdropColor(0, 0, 0, 0.25)
    p:SetBackdropBorderColor(1, 0.82, 0, 0.9)

    dragProxy = p
    return p
end

-- Put the window back where the outline ended up and make it visible again.
-- Safe to call when no drag is in progress.
local function EndProxyDrag()
    if not dragOwner then return end

    local owner = dragOwner
    dragOwner = nil

    if dragProxy then
        dragProxy:StopMovingOrSizing()
        local left, bottom = dragProxy:GetLeft(), dragProxy:GetBottom()
        if left and bottom then
            owner:ClearAllPoints()
            owner:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left, bottom)
        end
        dragProxy:Hide()
    end

    UnfadeAfterDrag()
end

local function BeginProxyDrag(owner)
    -- A previous drag that never got its mouse-up would otherwise leave the
    -- window stuck at alpha 0.
    EndProxyDrag()

    local left, bottom = owner:GetLeft(), owner:GetBottom()
    if not left or not bottom then return false end

    local p = GetDragProxy()
    p:SetSize(owner:GetWidth(), owner:GetHeight())
    p:ClearAllPoints()
    p:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left, bottom)
    p:Show()

    dragOwner = owner
    FadeForDrag(owner)

    p:StartMoving()
    return true
end

-- Exposed so a frame can bail out of a drag it is about to lose (e.g. hidden
-- by Escape mid-drag) without stranding itself invisible.
-- Only ends the drag if THIS frame owns it, so one window closing cannot
-- reposition another that is mid-drag.
local function CancelDragFor(owner)
    if dragOwner == owner then EndProxyDrag() end
end

function Header:CancelDrag()
    EndProxyDrag()
end

local function LoadComponents()
    Characters = ns:GetModule("Header.Characters")
    if Constants.FEATURES.BANK then
        BankCharacters = ns:GetModule("BankFrame.BankCharacters")
    end
end

local function CreateHeader(parent)
    local titleBar = CreateFrame("Frame", "GudaBagsHeader", parent, "BackdropTemplate")
    titleBar:SetHeight(Constants.FRAME.TITLE_HEIGHT)
    titleBar:SetPoint("TOPLEFT", parent, "TOPLEFT", 4, -4)
    titleBar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -4, -4)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")

    titleBar:SetScript("OnMouseDown", function(self, button)
        -- Raise parent frame above other bag/bank frames when clicked
        -- BUT keep secure container above the frame backdrop
        parent:SetFrameLevel(Constants.FRAME_LEVELS.RAISED)
        Theme:SyncBlizzardBgLevel(parent)
        if parent.container then
            parent.container:SetFrameLevel(Constants.FRAME_LEVELS.RAISED + Constants.FRAME_LEVELS.CONTAINER)
            ItemButton:SyncFrameLevels(parent.container)
        end

        local BankFrameModule = ns:GetModule("BankFrame")
        if BankFrameModule and BankFrameModule:GetFrame() and BankFrameModule:GetFrame() ~= parent then
            local bankFrame = BankFrameModule:GetFrame()
            bankFrame:SetFrameLevel(Constants.FRAME_LEVELS.BASE)
            Theme:SyncBlizzardBgLevel(bankFrame)
            if bankFrame.container then
                bankFrame.container:SetFrameLevel(Constants.FRAME_LEVELS.BASE + Constants.FRAME_LEVELS.CONTAINER)
                ItemButton:SyncFrameLevels(bankFrame.container)
            end
        end
        local BagFrameModule = ns:GetModule("BagFrame")
        if BagFrameModule and BagFrameModule:GetFrame() and BagFrameModule:GetFrame() ~= parent then
            local bagFrame = BagFrameModule:GetFrame()
            bagFrame:SetFrameLevel(Constants.FRAME_LEVELS.BASE)
            Theme:SyncBlizzardBgLevel(bagFrame)
            if bagFrame.container then
                bagFrame.container:SetFrameLevel(Constants.FRAME_LEVELS.BASE + Constants.FRAME_LEVELS.CONTAINER)
                ItemButton:SyncFrameLevels(bagFrame.container)
            end
        end
        local GuildBankFrameModule = ns:GetModule("GuildBankFrame")
        if GuildBankFrameModule and GuildBankFrameModule.GetFrame and GuildBankFrameModule:GetFrame() and GuildBankFrameModule:GetFrame() ~= parent then
            local guildFrame = GuildBankFrameModule:GetFrame()
            guildFrame:SetFrameLevel(Constants.FRAME_LEVELS.BASE)
            Theme:SyncBlizzardBgLevel(guildFrame)
            if guildFrame.container then
                guildFrame.container:SetFrameLevel(Constants.FRAME_LEVELS.BASE + Constants.FRAME_LEVELS.CONTAINER)
                ItemButton:SyncFrameLevels(guildFrame.container)
            end
        end
    end)

    titleBar:SetScript("OnDragStart", function()
        if not Database:GetSetting("locked") then
            -- Move an outline, not the window itself -- see the drag proxy note
            -- above. Falls back to the native path if the window has no
            -- resolved position yet (never anchored, so GetLeft is nil).
            if not BeginProxyDrag(parent) then
                parent:StartMoving()
            end
            -- Public flag observed by satellite buttons (Disenchant, Pick Lock,
            -- Prospecting) so they can hide during the drag. Frame:IsMoving()
            -- is not available on all Classic clients.
            parent._isDragging = true

            if parent == _G["GudaBagsBagFrame"] then
                local ProfessionButton = ns:GetModule("Footer.ProfessionButton")
                if ProfessionButton and ProfessionButton.HideAllInstantly then
                    ProfessionButton:HideAllInstantly()
                end
            end
        end
    end)

    titleBar:SetScript("OnDragStop", function()
        -- StopMovingOrSizing is harmless when the native path was not used.
        parent:StopMovingOrSizing()
        CancelDragFor(parent)
        parent._isDragging = nil
        if onDragStop then
            onDragStop()
        end
    end)

    -- Escape (UISpecialFrames), CloseAllWindows, or another addon can hide the
    -- window mid-drag. OnDragStop never fires in that case, which would strand
    -- it at alpha 0 -- invisible but still there. Restore it here instead.
    parent:HookScript("OnHide", function(self)
        CancelDragFor(self)
        self._isDragging = nil
    end)

    -- Ensure container stays above frame backdrop when mouse enters header
    titleBar:SetScript("OnEnter", function()
        if parent.container then
            parent.container:SetFrameLevel(parent:GetFrameLevel() + Constants.FRAME_LEVELS.CONTAINER)
        end
    end)

    local bgAlpha = Database:GetSetting("bgAlpha") / 100
    local headerBackdrop = Theme:GetValue("headerBackdrop")
    if headerBackdrop then
        titleBar:SetBackdrop(headerBackdrop)
        local headerBg = Theme:GetValue("headerBg")
        titleBar:SetBackdropColor(headerBg[1], headerBg[2], headerBg[3], bgAlpha)
    else
        titleBar:SetBackdrop(nil)
    end

    -- Left side icons (use feature flags to show/hide)
    local lastLeftButton = nil

    if Constants.FEATURES.CHARACTERS then
        local charactersButton = IconButton:Create(titleBar, "characters", {
            tooltip = L["TOOLTIP_CHARACTERS"],
            onClick = function(self)
                Characters:Toggle(self)
            end,
        })
        charactersButton:SetPoint("LEFT", titleBar, "LEFT", 6, 0)
        titleBar.charactersButton = charactersButton
        HeaderButtonVisibility:SetKey(charactersButton, "showHeaderCharacters")
        HeaderButtonVisibility:ApplyState(charactersButton)
        lastLeftButton = charactersButton
    end

    if Constants.FEATURES.BANK then
        local chestButton = IconButton:Create(titleBar, "chest", {
            tooltip = L["TOOLTIP_BANK"],
            onClick = function(self)
                -- Close guild bank if open
                local GuildBankFrameModule = ns:GetModule("GuildBankFrame")
                local wasGuildBankOpen = GuildBankFrameModule and GuildBankFrameModule:GetFrame() and GuildBankFrameModule:GetFrame():IsShown()
                if wasGuildBankOpen then
                    GuildBankFrameModule:Hide()
                end
                if wasGuildBankOpen then
                    C_Timer.After(0, function()
                        BankCharacters:Toggle(self)
                    end)
                else
                    BankCharacters:Toggle(self)
                end
            end,
        })
        if lastLeftButton then
            chestButton:SetPoint("LEFT", lastLeftButton, "RIGHT", 4, 0)
        else
            chestButton:SetPoint("LEFT", titleBar, "LEFT", 6, 0)
        end
        titleBar.chestButton = chestButton
        HeaderButtonVisibility:SetKey(chestButton, "showHeaderBank")
        HeaderButtonVisibility:ApplyState(chestButton)
        lastLeftButton = chestButton
    end

    if Constants.FEATURES.GUILD_BANK and IsInGuild() then
        local guildButton = IconButton:Create(titleBar, "guild", {
            tooltip = L["TOOLTIP_GUILD_BANK"],
            onClick = function()
                -- Close bank view if open
                local BankFrameModule = ns:GetModule("BankFrame")
                local wasBankOpen = BankFrameModule and BankFrameModule:GetFrame() and BankFrameModule:GetFrame():IsShown()
                if wasBankOpen then
                    BankFrameModule:Hide()
                end
                -- Close bank characters dropdown if open
                if BankCharacters then
                    BankCharacters:Hide()
                end
                local GuildBankFrameModule = ns:GetModule("GuildBankFrame")
                if GuildBankFrameModule then
                    if wasBankOpen then
                        -- Defer to next frame to avoid script timeout from pool churn
                        C_Timer.After(0, function()
                            GuildBankFrameModule:Toggle()
                        end)
                    else
                        GuildBankFrameModule:Toggle()
                    end
                end
            end,
        })
        if lastLeftButton then
            guildButton:SetPoint("LEFT", lastLeftButton, "RIGHT", 4, 0)
        else
            guildButton:SetPoint("LEFT", titleBar, "LEFT", 6, 0)
        end
        titleBar.guildButton = guildButton
        HeaderButtonVisibility:SetKey(guildButton, "showHeaderGuildBank")
        HeaderButtonVisibility:ApplyState(guildButton)
        lastLeftButton = guildButton
    end

    if Constants.FEATURES.MAIL then
        local envelopeButton = IconButton:Create(titleBar, "envelope", {
            tooltip = L["TOOLTIP_MAIL"],
            onClick = function()
                local MailFrameModule = ns:GetModule("MailFrame")
                if MailFrameModule then
                    MailFrameModule:Toggle()
                end
            end,
        })
        if lastLeftButton then
            envelopeButton:SetPoint("LEFT", lastLeftButton, "RIGHT", 4, 0)
        else
            envelopeButton:SetPoint("LEFT", titleBar, "LEFT", 6, 0)
        end
        titleBar.envelopeButton = envelopeButton
        HeaderButtonVisibility:SetKey(envelopeButton, "showHeaderMail")
        HeaderButtonVisibility:ApplyState(envelopeButton)
        lastLeftButton = envelopeButton
    end

    -- Center title with character name
    local playerName = UnitName("player")
    local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    Font:Override(title)
    title:SetPoint("CENTER", titleBar, "CENTER", 0, 0)
    title:SetText(playerName .. L["TITLE_BAGS"])
    title:SetTextColor(1, 0.82, 0)
    title:SetShadowOffset(1, -1)
    title:SetShadowColor(0, 0, 0, 1)
    titleBar.title = title

    -- Right side icons (created right-to-left for proper anchoring)
    local closeButton = IconButton:CreateCloseButton(titleBar, {
        onClick = function()
            parent:Hide()
        end,
        point = "RIGHT",
        offsetX = 0,
        offsetY = 0,
    })
    titleBar.closeButton = closeButton
    local lastRightButton = closeButton

    local settingsButton = IconButton:Create(titleBar, "settings", {
        tooltip = L["TOOLTIP_SETTINGS"],
        onClick = function()
            local SettingsPopup = ns:GetModule("SettingsPopup")
            SettingsPopup:Toggle()
        end,
    })
    settingsButton:SetPoint("RIGHT", lastRightButton, "LEFT", -4, 0)
    titleBar.settingsButton = settingsButton
    lastRightButton = settingsButton

    if Constants.FEATURES.SORT then
        local sortButton = IconButton:Create(titleBar, "sort", {
            onClick = function()
                if InCombatLockdown() then return end
                -- Debounce protection
                local now = GetTime()
                if now - lastSortTime < SORT_DEBOUNCE then
                    return
                end
                lastSortTime = now

                local BagFrameModule = ns:GetModule("BagFrame")
                local viewType = Database:GetSetting("bagViewType") or "single"

                if viewType == "category" then
                    BagFrameModule:RestackAndClean()
                else
                    BagFrameModule:SortBags()
                end
            end,
        })
        -- Dynamic tooltip based on view type
        sortButton:SetScript("OnEnter", function(self)
            local viewType = Database:GetSetting("bagViewType") or "single"
            local tooltip = viewType == "category" and L["TOOLTIP_RESTACK_CLEAN"] or L["TOOLTIP_SORT_BAGS"]
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:SetText(tooltip)
            GameTooltip:Show()
        end)
        sortButton:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
        sortButton:SetPoint("RIGHT", lastRightButton, "LEFT", -4, 0)
        titleBar.sortButton = sortButton
        HeaderButtonVisibility:SetKey(sortButton, "showHeaderSort")
        HeaderButtonVisibility:ApplyState(sortButton)
        lastRightButton = sortButton
    end

    local viewCycleButton, recentToggleButton = HeaderViewControls:Attach(titleBar, {
        viewSettingKey = "bagViewType",
        ownerPrefix    = "Header",
        anchorButton   = lastRightButton,
    })
    titleBar.viewCycleButton = viewCycleButton
    titleBar.recentToggleButton = recentToggleButton
    lastRightButton = recentToggleButton

    -- Search toggle button (shown when "Always Show Search Bar" is off)
    local searchButton = SearchToggleButton:Create(titleBar, {
        targetModule = "BagFrame",
        anchorButton = lastRightButton,
    })
    titleBar.searchButton = searchButton
    lastRightButton = searchButton

    return titleBar
end

function Header:Init(parent)
    LoadComponents()
    frame = CreateHeader(parent)
    return frame
end

function Header:GetFrame()
    return frame
end

function Header:GetHeight()
    if frame then
        return frame:GetHeight()
    end
    return Constants.FRAME.TITLE_HEIGHT
end

function Header:SetDragCallback(callback)
    onDragStop = callback
end

local lastAlpha = 1

function Header:SetBackdropAlpha(alpha)
    if not frame then return end
    lastAlpha = alpha
    local headerBackdrop = Theme:GetValue("headerBackdrop")
    if headerBackdrop then
        frame:SetBackdrop(headerBackdrop)
        local headerBg = Theme:GetValue("headerBg")
        frame:SetBackdropColor(headerBg[1], headerBg[2], headerBg[3], alpha)
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", frame:GetParent(), "TOPLEFT", 4, -4)
        frame:SetPoint("TOPRIGHT", frame:GetParent(), "TOPRIGHT", -4, -4)
        if frame.closeButton then frame.closeButton:SetSize(22, 22) end
    else
        frame:SetBackdrop(nil)
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", frame:GetParent(), "TOPLEFT", 0, 1)
        frame:SetPoint("TOPRIGHT", frame:GetParent(), "TOPRIGHT", 4, 0)
        local closeSize = ns.IsRetail and 22 or 32
        if frame.closeButton then frame.closeButton:SetSize(closeSize, closeSize) end
        -- Raise header above blizzardBg's NineSlice or metalFrame overlay
        local parent = frame:GetParent()
        if parent.blizzardBg or parent.metalFrame then
            frame:SetFrameLevel(parent:GetFrameLevel() + Constants.FRAME_LEVELS.HEADER)
        end
    end
    -- Sync any tagged button's Show state to its settings, then filter out
    -- hidden ones before handing to Theme so anchors chain without gaps.
    -- In compact mode the nav buttons are managed by SetNarrowMode (hidden to
    -- make room for the hamburger) — skip them here so we don't accidentally
    -- un-hide them and overlap the hamburger.
    if not frame.isCompactMode then
        HeaderButtonVisibility:ApplyState(frame.charactersButton)
        HeaderButtonVisibility:ApplyState(frame.chestButton)
        HeaderButtonVisibility:ApplyState(frame.guildButton)
        HeaderButtonVisibility:ApplyState(frame.envelopeButton)
    end
    HeaderButtonVisibility:ApplyState(frame.sortButton)
    HeaderViewControls:ApplyVisibility(frame.viewCycleButton, frame.recentToggleButton, "bagViewType")
    -- searchButton manages its own Show/Hide via SearchToggleButton's listener

    local leftButtons = HeaderButtonVisibility:Filter({
        frame.charactersButton, frame.chestButton, frame.guildButton, frame.envelopeButton
    })
    local rightButtons = HeaderButtonVisibility:Filter({
        frame.settingsButton, frame.sortButton, frame.viewCycleButton, frame.recentToggleButton, frame.searchButton
    })

    Theme:ApplyHeaderButtons(
        frame,
        leftButtons,
        rightButtons,
        frame.closeButton
    )
end

-- Re-apply header layout when any header button setting flips.
HeaderButtonVisibility:Watch(Header, function()
    if frame then Header:SetBackdropAlpha(lastAlpha) end
end)

-- Recent toggle is gated by bagViewType too — re-lay out when the view cycles.
HeaderViewControls:WatchViewType("bagViewType", "Header", function()
    if frame then Header:SetBackdropAlpha(lastAlpha) end
end)

function Header:SetViewingCharacter(fullName, charData)
    viewingCharacterData = charData
    if not frame or not frame.title then return end

    if charData then
        -- Viewing another character
        local classColor = RAID_CLASS_COLORS[charData.class]
        local r, g, b = 0.7, 0.7, 0.7
        if classColor then
            r, g, b = classColor.r, classColor.g, classColor.b
        end
        frame.title:SetText(charData.name .. L["TITLE_BAGS"])
        frame.title:SetTextColor(r, g, b)
    else
        -- Back to current character
        local playerName = UnitName("player")
        frame.title:SetText(playerName .. L["TITLE_BAGS"])
        frame.title:SetTextColor(1, 0.82, 0)
    end
end

function Header:GetCharactersButton()
    if frame then
        return frame.charactersButton
    end
    return nil
end

function Header:IsViewingOther()
    return viewingCharacterData ~= nil
end

function Header:SetCharacterCallback(callback)
    if Characters then
        Characters:SetCallback(callback)
    end
end

function Header:SetBankCharacterCallback(callback)
    if BankCharacters then
        BankCharacters:SetCallback(callback)
    end
end

function Header:SetNarrowMode(isCompact)
    local titleBar = self:GetFrame()
    if not titleBar then return end
    titleBar.isCompactMode = isCompact

    -- Collect nav buttons (Characters, Bank, Guild Bank, Mail)
    local navButtons = {}
    if titleBar.charactersButton then table.insert(navButtons, titleBar.charactersButton) end
    if titleBar.chestButton then table.insert(navButtons, titleBar.chestButton) end
    if titleBar.guildButton then table.insert(navButtons, titleBar.guildButton) end
    if titleBar.envelopeButton then table.insert(navButtons, titleBar.envelopeButton) end

    if isCompact then
        -- Smaller title font
        if titleBar.title then
            local _, _, flags = titleBar.title:GetFont()
            Font:Apply(titleBar.title, 10, flags)
        end

        -- Hide individual nav buttons
        for _, btn in ipairs(navButtons) do
            btn:Hide()
        end

        -- Create hamburger menu button (once) — uses Assets/more.tga
        if not titleBar.menuButton then
            local menuBtn = CreateFrame("Button", nil, titleBar)
            menuBtn:SetSize(16, 16)

            -- Theme-aware background chip (matches the other header icons).
            -- Always created; shown/hidden below based on current theme.
            local themeBg = CreateFrame("Frame", nil, menuBtn, "BackdropTemplate")
            themeBg:SetSize(21, 17)
            themeBg:SetPoint("CENTER")
            themeBg:SetFrameLevel(menuBtn:GetFrameLevel())
            themeBg:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8x8",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                edgeSize = 8,
                insets = { left = 2, right = 2, top = 2, bottom = 2 },
            })
            themeBg:SetBackdropColor(0.15, 0.12, 0.10, 0.6)
            themeBg:SetBackdropBorderColor(0.45, 0.40, 0.35, 1)
            themeBg:Hide()
            menuBtn.themeBg = themeBg

            local menuIcon = menuBtn:CreateTexture(nil, "ARTWORK")
            menuIcon:SetPoint("CENTER")
            menuIcon:SetSize(14, 14)
            menuIcon:SetTexture("Interface\\AddOns\\GudaBags\\Assets\\more.tga")
            menuIcon:SetVertexColor(0.7, 0.7, 0.7)
            menuBtn.icon = menuIcon

            menuBtn:SetScript("OnEnter", function(self)
                self.icon:SetVertexColor(1, 1, 1)
                GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
                GameTooltip:SetText("Navigation")
                GameTooltip:Show()
            end)
            menuBtn:SetScript("OnLeave", function(self)
                self.icon:SetVertexColor(0.7, 0.7, 0.7)
                GameTooltip:Hide()
            end)
            menuBtn:SetScript("OnClick", function(self)
                Header:ShowNavMenu(self)
            end)

            titleBar.menuButton = menuBtn
        end

        -- Match theme-aware chip + offset used by other header icons.
        local useBlizzardMenu = Theme:GetValue("useBlizzardFrame")
        local useMetalMenu = Theme:GetValue("useMetalFrame")
        if titleBar.menuButton.themeBg then
            if useBlizzardMenu or useMetalMenu then
                titleBar.menuButton.themeBg:Show()
            else
                titleBar.menuButton.themeBg:Hide()
            end
        end
        titleBar.menuButton:ClearAllPoints()
        local menuOffset = (useBlizzardMenu or useMetalMenu) and 13 or 4
        titleBar.menuButton:SetPoint("LEFT", titleBar, "LEFT", menuOffset, 0)
        titleBar.menuButton:Show()

        -- Title next to menu button
        if titleBar.title then
            titleBar.title:ClearAllPoints()
            titleBar.title:SetPoint("LEFT", titleBar.menuButton, "RIGHT", 4, 0)
        end
    else
        -- Restore title font
        if titleBar.title then
            local _, _, flags = titleBar.title:GetFont()
            Font:Apply(titleBar.title, 12, flags)
        end

        -- Hide menu button
        if titleBar.menuButton then
            titleBar.menuButton:Hide()
        end

        -- Sync each nav button's Show state to its setting, then chain only
        -- the visible ones. Spacing matches Theme:ApplyHeaderButtons so
        -- Blizzard/Metal themes keep their 10px gap / 13px left offset.
        for _, btn in ipairs(navButtons) do
            HeaderButtonVisibility:ApplyState(btn)
        end
        local useBlizzard = Theme:GetValue("useBlizzardFrame")
        local useMetal = Theme:GetValue("useMetalFrame")
        local gap = (useBlizzard or useMetal) and 10 or 4
        local firstLeftOffset = (useBlizzard or useMetal) and 13 or 4
        local lastBtn = nil
        for _, btn in ipairs(HeaderButtonVisibility:Filter(navButtons)) do
            btn:ClearAllPoints()
            if lastBtn then
                btn:SetPoint("LEFT", lastBtn, "RIGHT", gap, 0)
            else
                btn:SetPoint("LEFT", titleBar, "LEFT", firstLeftOffset, 0)
            end
            lastBtn = btn
        end

        -- Restore title to center
        if titleBar.title then
            titleBar.title:ClearAllPoints()
            titleBar.title:SetPoint("CENTER", titleBar, "CENTER", 0, 0)
        end
    end
end

-- Navigation dropdown menu for compact mode
local navMenu = nil

function Header:ShowNavMenu(anchor)
    if not navMenu then
        navMenu = CreateFrame("Frame", "GudaBagsNavMenu", UIParent, "BackdropTemplate")
        navMenu:SetFrameStrata("TOOLTIP")
        navMenu:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 10,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        navMenu:SetBackdropColor(0.1, 0.1, 0.1, 0.95)
        navMenu:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.9)
        navMenu:EnableMouse(true)
        navMenu:Hide()
    end

    if navMenu:IsShown() then
        navMenu:Hide()
        return
    end

    -- Build menu items from nav buttons
    local titleBar = self:GetFrame()
    if not titleBar then return end

    local L = ns.L
    local menuItems = {}
    -- Only include nav entries whose button is currently visible (expansion
    -- feature flag + user visibility setting).
    if Constants.FEATURES.CHARACTERS and HeaderButtonVisibility:IsSettingEnabled(titleBar.charactersButton) then
        table.insert(menuItems, { label = L["TOOLTIP_CHARACTERS"] or "Characters", onClick = function()
            if titleBar.charactersButton then
                titleBar.charactersButton:Click()
            end
        end})
    end
    if Constants.FEATURES.BANK and HeaderButtonVisibility:IsSettingEnabled(titleBar.chestButton) then
        table.insert(menuItems, { label = L["TOOLTIP_BANK"] or "Bank", onClick = function()
            if titleBar.chestButton then
                titleBar.chestButton:Click()
            end
        end})
    end
    if Constants.FEATURES.GUILD_BANK and IsInGuild() and HeaderButtonVisibility:IsSettingEnabled(titleBar.guildButton) then
        table.insert(menuItems, { label = L["TOOLTIP_GUILD_BANK"] or "Guild Bank", onClick = function()
            if titleBar.guildButton then
                titleBar.guildButton:Click()
            end
        end})
    end
    if Constants.FEATURES.MAIL and HeaderButtonVisibility:IsSettingEnabled(titleBar.envelopeButton) then
        table.insert(menuItems, { label = L["TOOLTIP_MAIL"] or "Mail", onClick = function()
            if titleBar.envelopeButton then
                titleBar.envelopeButton:Click()
            end
        end})
    end

    -- Clear old items
    if navMenu.items then
        for _, item in ipairs(navMenu.items) do item:Hide() end
    end
    navMenu.items = navMenu.items or {}

    local yOffset = -4
    local maxWidth = 0
    for i, def in ipairs(menuItems) do
        local item = navMenu.items[i]
        if not item then
            item = CreateFrame("Button", nil, navMenu)
            item:SetHeight(18)
            local label = item:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            label:SetPoint("LEFT", 6, 0)
            item.label = label
            local bg = item:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetTexture("Interface\\Buttons\\WHITE8x8")
            bg:SetVertexColor(0, 0, 0, 0)
            item.bg = bg
            item:SetScript("OnEnter", function(self)
                self.bg:SetVertexColor(0.25, 0.25, 0.25, 0.8)
            end)
            item:SetScript("OnLeave", function(self)
                self.bg:SetVertexColor(0, 0, 0, 0)
            end)
            navMenu.items[i] = item
        end

        item.label:SetText(def.label)
        item.label:SetTextColor(1, 0.82, 0)
        item:SetScript("OnClick", function()
            navMenu:Hide()
            def.onClick()
        end)
        item:SetPoint("TOPLEFT", navMenu, "TOPLEFT", 4, yOffset)
        item:SetPoint("TOPRIGHT", navMenu, "TOPRIGHT", -4, yOffset)
        local w = item.label:GetStringWidth() + 16
        if w > maxWidth then maxWidth = w end
        yOffset = yOffset - 18
        item:Show()
    end

    navMenu:SetSize(math.max(maxWidth, 100), -yOffset + 4)
    navMenu:ClearAllPoints()
    navMenu:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
    navMenu:Show()

    navMenu:SetScript("OnUpdate", function(self)
        if not MouseIsOver(self) and not MouseIsOver(anchor) then
            if IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton") then
                self:Hide()
            end
        end
    end)
end
