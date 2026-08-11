local addonName, ns = ...

local GuildBankHeader = {}
ns:RegisterModule("GuildBankFrame.GuildBankHeader", GuildBankHeader)

local Constants = ns.Constants
local L = ns.L
local Database = ns:GetModule("Database")
local Font = ns:GetModule("Font")
local HeaderButtonVisibility = ns:GetModule("HeaderButtonVisibility")
local IconButton = ns:GetModule("IconButton")
local ItemButton = ns:GetModule("ItemButton")
local SearchToggleButton = ns:GetModule("SearchToggleButton")
local Theme = ns:GetModule("Theme")

local CreateFrame = ns.CreateFrame or CreateFrame

local frame = nil
local onDragStop = nil

-- Matches UI\Header.lua's guard on the bag sort button.
local SORT_DEBOUNCE = 1.0
local lastSortTime = 0

local function CreateHeader(parent)
    local titleBar = CreateFrame("Frame", "GudaGuildBankHeader", parent, "BackdropTemplate")
    titleBar:SetHeight(Constants.FRAME.TITLE_HEIGHT)
    titleBar:SetPoint("TOPLEFT", parent, "TOPLEFT", 4, -4)
    titleBar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -4, -4)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")

    titleBar:SetScript("OnMouseDown", function(self, button)
        -- Raise parent frame above other frames when clicked
        parent:SetFrameLevel(Constants.FRAME_LEVELS.RAISED)
        Theme:SyncBlizzardBgLevel(parent)
        if parent.container then
            ItemButton:SyncFrameLevels(parent.container)
        end
        local BagFrameModule = ns:GetModule("BagFrame")
        if BagFrameModule and BagFrameModule:GetFrame() then
            local bagFrame = BagFrameModule:GetFrame()
            bagFrame:SetFrameLevel(Constants.FRAME_LEVELS.BASE)
            Theme:SyncBlizzardBgLevel(bagFrame)
            if bagFrame.container then
                bagFrame.container:SetFrameLevel(Constants.FRAME_LEVELS.BASE + Constants.FRAME_LEVELS.CONTAINER)
                ItemButton:SyncFrameLevels(bagFrame.container)
            end
        end
        local BankFrameModule = ns:GetModule("BankFrame")
        if BankFrameModule and BankFrameModule:GetFrame() then
            local bankFrame = BankFrameModule:GetFrame()
            bankFrame:SetFrameLevel(Constants.FRAME_LEVELS.BASE)
            Theme:SyncBlizzardBgLevel(bankFrame)
            if bankFrame.container then
                ItemButton:SyncFrameLevels(bankFrame.container)
            end
        end
    end)

    titleBar:SetScript("OnDragStart", function()
        if not Database:GetSetting("locked") then
            parent:StartMoving()
        end
    end)

    titleBar:SetScript("OnDragStop", function()
        parent:StopMovingOrSizing()
        if onDragStop then
            onDragStop()
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

    -- Guild name as title (will be updated when guild bank opens)
    local guildName = GetGuildInfo("player") or L["TITLE_GUILD_BANK"]
    local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    Font:Override(title)
    title:SetPoint("CENTER", titleBar, "CENTER", 0, 0)
    title:SetText(guildName .. (L["TITLE_GUILD_BANK"] or "'s Guild Bank"))
    title:SetTextColor(0, 0.8, 0.4)  -- Green-ish color for guild
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

    -- Sort button. Personal Bank only -- GuildBankFrame's chrome pass shows and
    -- hides it, so a real guild bank never gets one (each move there is a
    -- withdraw against a per-rank allowance; see Sorting\GuildBankSort.lua).
    if Constants.FEATURES.SORT then
        local sortButton = IconButton:Create(titleBar, "sort", {
            tooltip = L["TOOLTIP_SORT_PERSONAL_BANK"],
            onClick = function()
                if InCombatLockdown() then return end
                -- Same debounce as the bag header's sort button: a double click
                -- must not start a second pass over a layout that is moving.
                local now = GetTime()
                if now - lastSortTime < SORT_DEBOUNCE then return end
                lastSortTime = now

                local GuildBankSort = ns:GetModule("GuildBankSort")
                if GuildBankSort then
                    GuildBankSort:SortPersonalBank()
                else
                    -- Sorting\GuildBankSort.lua is a .toc addition: without a full
                    -- client restart the file never loads and the button is inert.
                    ns:Debug("Sort clicked but GuildBankSort module is not loaded")
                end
            end,
        })
        sortButton:SetPoint("RIGHT", lastRightButton, "LEFT", -4, 0)
        sortButton:Hide()   -- shown by ApplyBankModeChrome when personal
        titleBar.sortButton = sortButton
        lastRightButton = sortButton
    end

    -- Search toggle button (shown when "Always Show Search Bar" is off)
    local searchButton = SearchToggleButton:Create(titleBar, {
        targetModule = "GuildBankFrame",
        anchorButton = lastRightButton,
    })
    titleBar.searchButton = searchButton
    lastRightButton = searchButton

    return titleBar
end

function GuildBankHeader:Init(parent)
    frame = CreateHeader(parent)
    return frame
end

function GuildBankHeader:GetFrame()
    return frame
end

function GuildBankHeader:SetDragCallback(callback)
    onDragStop = callback
end

local lastAlpha = 1

function GuildBankHeader:SetBackdropAlpha(alpha)
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
        -- Raise header above blizzardBg's NineSlice on retail
        local parent = frame:GetParent()
        if parent.blizzardBg or parent.metalFrame then
            frame:SetFrameLevel(parent:GetFrameLevel() + Constants.FRAME_LEVELS.HEADER)
        end
    end
    local rightButtons = HeaderButtonVisibility:Filter({
        frame.settingsButton, frame.searchButton
    })

    Theme:ApplyHeaderButtons(
        frame,
        {},
        rightButtons,
        frame.closeButton
    )
end

-- Re-apply layout when any header button setting flips.
HeaderButtonVisibility:Watch(GuildBankHeader, function()
    if frame then GuildBankHeader:SetBackdropAlpha(lastAlpha) end
end)

function GuildBankHeader:SetGuildName(guildName)
    if not frame or not frame.title then return end

    if guildName then
        frame.title:SetText(guildName .. (L["TITLE_GUILD_BANK"] or "'s Guild Bank"))
    else
        frame.title:SetText(L["TITLE_GUILD_BANK"] or "Guild Bank")
    end
end

--- Show or hide the sort button. Called from GuildBankFrame's chrome pass, which
--- also runs when the bank kind resolves late -- so a session that starts out
--- looking like a guild bank picks the button up as soon as it is identified.
function GuildBankHeader:SetSortShown(shown)
    if not frame or not frame.sortButton then return end
    if shown then frame.sortButton:Show() else frame.sortButton:Hide() end
end

--- Greyed out while a sort runs, so a second click cannot start another pass.
function GuildBankHeader:SetSortEnabled(enabled)
    if not frame or not frame.sortButton then return end
    local Utils = ns:GetModule("Utils")
    if Utils then
        Utils:SetEnabled(frame.sortButton, enabled)
    end
    frame.sortButton:SetAlpha(enabled and 1 or 0.4)
end

--- Ascension's Personal Bank shares this window, so the title is what tells the
--- player which one they are looking at: character name in the addon's usual
--- gold, matching UI\Header.lua's "<name>'s Bags", instead of the guild green.
function GuildBankHeader:SetPersonalTitle()
    if not frame or not frame.title then return end
    local playerName = UnitName("player") or ""
    frame.title:SetText(playerName .. (L["TITLE_PERSONAL_BANK"] or "'s Personal Bank"))
    frame.title:SetTextColor(1, 0.82, 0)
end

function GuildBankHeader:UpdateTitle()
    local GuildBankFrame = ns:GetModule("GuildBankFrame")
    if GuildBankFrame and GuildBankFrame.IsPersonalMode and GuildBankFrame:IsPersonalMode() then
        self:SetPersonalTitle()
        return
    end

    -- Restore the guild colour: the same font string carries both titles.
    if frame and frame.title then
        frame.title:SetTextColor(0, 0.8, 0.4)
    end
    local guildName = GetGuildInfo("player")
    self:SetGuildName(guildName)
end
