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

local frame = nil
local onDragStop = nil

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

function GuildBankHeader:UpdateTitle()
    local guildName = GetGuildInfo("player")
    self:SetGuildName(guildName)
end
