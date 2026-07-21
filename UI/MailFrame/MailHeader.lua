local addonName, ns = ...

local MailHeader = {}
ns:RegisterModule("MailFrame.MailHeader", MailHeader)

local Constants = ns.Constants
local L = ns.L
local Database = ns:GetModule("Database")
local Font = ns:GetModule("Font")
local HeaderButtonVisibility = ns:GetModule("HeaderButtonVisibility")
local IconButton = ns:GetModule("IconButton")
local SearchToggleButton = ns:GetModule("SearchToggleButton")
local Theme = ns:GetModule("Theme")

local frame = nil
local onDragStop = nil
local viewingCharacterData = nil

local MailCharacters = nil

local function LoadComponents()
    MailCharacters = ns:GetModule("MailFrame.MailCharacters")
end

local function CreateHeader(parent)
    local titleBar = CreateFrame("Frame", "GudaMailHeader", parent, "BackdropTemplate")
    titleBar:SetHeight(Constants.FRAME.TITLE_HEIGHT)
    titleBar:SetPoint("TOPLEFT", parent, "TOPLEFT", 4, -4)
    titleBar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -4, -4)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")

    titleBar:SetScript("OnMouseDown", function(self, button)
        parent:SetFrameLevel(Constants.FRAME_LEVELS.RAISED)
        Theme:SyncBlizzardBgLevel(parent)

        -- Lower other frames
        local BagFrameModule = ns:GetModule("BagFrame")
        if BagFrameModule and BagFrameModule:GetFrame() then
            local bagFrame = BagFrameModule:GetFrame()
            bagFrame:SetFrameLevel(Constants.FRAME_LEVELS.BASE)
            Theme:SyncBlizzardBgLevel(bagFrame)
            if bagFrame.container then
                local ItemButton = ns:GetModule("ItemButton")
                bagFrame.container:SetFrameLevel(Constants.FRAME_LEVELS.BASE + Constants.FRAME_LEVELS.CONTAINER)
                ItemButton:SyncFrameLevels(bagFrame.container)
            end
        end
        local BankFrameModule = ns:GetModule("BankFrame")
        if BankFrameModule and BankFrameModule:GetFrame() then
            local bankFrame = BankFrameModule:GetFrame()
            bankFrame:SetFrameLevel(Constants.FRAME_LEVELS.BASE)
            Theme:SyncBlizzardBgLevel(bankFrame)
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

    -- Left side: Characters button
    local lastLeftButton = nil

    if Constants.FEATURES.CHARACTERS then
        local charactersButton = IconButton:Create(titleBar, "characters", {
            tooltip = L["TOOLTIP_CHARACTERS_MAIL"],
            onClick = function(self)
                if MailCharacters then
                    MailCharacters:Toggle(self)
                end
            end,
        })
        charactersButton:SetPoint("LEFT", titleBar, "LEFT", 6, 0)
        titleBar.charactersButton = charactersButton
        HeaderButtonVisibility:SetKey(charactersButton, "showHeaderCharacters")
        HeaderButtonVisibility:ApplyState(charactersButton)
        lastLeftButton = charactersButton
    end

    -- Center title
    local playerName = UnitName("player")
    local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    Font:Override(title)
    title:SetPoint("CENTER", titleBar, "CENTER", 0, 0)
    title:SetText(playerName .. L["TITLE_MAIL"])
    title:SetTextColor(1, 0.82, 0)
    title:SetShadowOffset(1, -1)
    title:SetShadowColor(0, 0, 0, 1)
    titleBar.title = title

    -- Right side: Close button
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

    -- Search toggle button (shown when "Always Show Search Bar" is off)
    local searchButton = SearchToggleButton:Create(titleBar, {
        targetModule = "MailFrame",
        anchorButton = lastRightButton,
    })
    titleBar.searchButton = searchButton
    lastRightButton = searchButton

    return titleBar
end

function MailHeader:Init(parent)
    LoadComponents()
    frame = CreateHeader(parent)
    return frame
end

function MailHeader:GetFrame()
    return frame
end

function MailHeader:SetDragCallback(callback)
    onDragStop = callback
end

local lastAlpha = 1

function MailHeader:SetBackdropAlpha(alpha)
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
        local parent = frame:GetParent()
        if parent.blizzardBg or parent.metalFrame then
            frame:SetFrameLevel(parent:GetFrameLevel() + Constants.FRAME_LEVELS.HEADER)
        end
    end
    HeaderButtonVisibility:ApplyState(frame.charactersButton)

    local leftButtons = HeaderButtonVisibility:Filter({ frame.charactersButton })
    local rightButtons = HeaderButtonVisibility:Filter({ frame.searchButton })

    Theme:ApplyHeaderButtons(
        frame,
        leftButtons,
        rightButtons,
        frame.closeButton
    )
end

-- Re-apply layout when any header button setting flips.
HeaderButtonVisibility:Watch(MailHeader, function()
    if frame then MailHeader:SetBackdropAlpha(lastAlpha) end
end)

function MailHeader:SetViewingCharacter(fullName, charData)
    viewingCharacterData = charData
    if not frame or not frame.title then return end

    if charData then
        local classColor = RAID_CLASS_COLORS[charData.class]
        local r, g, b = 0.7, 0.7, 0.7
        if classColor then
            r, g, b = classColor.r, classColor.g, classColor.b
        end
        frame.title:SetText(charData.name .. L["TITLE_MAIL"])
        frame.title:SetTextColor(r, g, b)
    else
        local playerName = UnitName("player")
        frame.title:SetText(playerName .. L["TITLE_MAIL"])
        frame.title:SetTextColor(1, 0.82, 0)
    end
end

function MailHeader:GetCharactersButton()
    if frame then
        return frame.charactersButton
    end
    return nil
end

function MailHeader:IsViewingOther()
    return viewingCharacterData ~= nil
end

function MailHeader:SetCharacterCallback(callback)
    if MailCharacters then
        MailCharacters:SetCallback(callback)
    end
end
