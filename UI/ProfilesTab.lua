local addonName, ns = ...

local ProfilesTab = {}
ns:RegisterModule("ProfilesTab", ProfilesTab)

local Events = ns:GetModule("Events")
local Constants = ns.Constants
local L = ns.L

local profileListScrollChild
local profileRows = {}
local importExportBox
local pendingImportData = nil

-------------------------------------------------
-- Static Popup Dialogs
-------------------------------------------------

StaticPopupDialogs["GUDABAGS_PROFILE_OVERWRITE"] = {
    text = L["PROFILE_OVERWRITE_CONFIRM"],
    button1 = OKAY,
    button2 = CANCEL,
    OnAccept = function(self)
        local ProfileManager = ns:GetModule("ProfileManager")
        if self.data then
            if pendingImportData then
                ProfileManager:SaveImportedProfile(self.data, pendingImportData)
                pendingImportData = nil
            else
                ProfileManager:SaveProfile(self.data)
            end
            ProfilesTab:RefreshList()
            ns:Print(string.format(L["PROFILE_SAVED"], self.data))
        end
    end,
    OnCancel = function()
        pendingImportData = nil
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["GUDABAGS_PROFILE_LOAD"] = {
    text = L["PROFILE_LOAD_CONFIRM"],
    button1 = OKAY,
    button2 = CANCEL,
    OnAccept = function(self)
        local ProfileManager = ns:GetModule("ProfileManager")
        if self.data then
            ProfileManager:LoadProfile(self.data)
            ProfilesTab:RefreshList()
            ns:Print(string.format(L["PROFILE_LOADED_MSG"], self.data))
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["GUDABAGS_PROFILE_DELETE"] = {
    text = L["PROFILE_DELETE_CONFIRM"],
    button1 = OKAY,
    button2 = CANCEL,
    OnAccept = function(self)
        local ProfileManager = ns:GetModule("ProfileManager")
        if self.data then
            ProfileManager:DeleteProfile(self.data)
            ProfilesTab:RefreshList()
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["GUDABAGS_PROFILE_RESET_DEFAULTS"] = {
    text = L["PROFILE_RESET_CONFIRM"],
    button1 = OKAY,
    button2 = CANCEL,
    OnAccept = function()
        local ProfileManager = ns:GetModule("ProfileManager")
        ProfileManager:ResetToDefaults()
        ProfilesTab:RefreshList()
        ns:Print(L["PROFILE_RESET_MSG"])
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["GUDABAGS_PROFILE_IMPORT_NAME"] = {
    text = L["PROFILE_IMPORT_NAME_PROMPT"],
    button1 = OKAY,
    button2 = CANCEL,
    hasEditBox = true,
    OnShow = function(self)
        self.EditBox:SetText(L["PROFILE_IMPORTED_DEFAULT"])
        self.EditBox:HighlightText()
    end,
    OnAccept = function(self)
        local name = self.EditBox:GetText()
        if name and name ~= "" and self.data then
            local ProfileManager = ns:GetModule("ProfileManager")
            if ProfileManager:ProfileExists(name) then
                pendingImportData = self.data
                local dialog = StaticPopup_Show("GUDABAGS_PROFILE_OVERWRITE", name)
                if dialog then
                    dialog.data = name
                end
            else
                ProfileManager:SaveImportedProfile(name, self.data)
                ProfilesTab:RefreshList()
                ns:Print(string.format(L["PROFILE_IMPORTED"], name))
            end
        end
    end,
    EditBoxOnEnterPressed = function(self)
        local parent = self:GetParent()
        StaticPopupDialogs["GUDABAGS_PROFILE_IMPORT_NAME"].OnAccept(parent)
        parent:Hide()
    end,
    EditBoxOnEscapePressed = function(self)
        self:GetParent():Hide()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-------------------------------------------------
-- Auto-hide scrollbar when content fits
-------------------------------------------------

local function SetupScrollbarAutoHide(scrollFrame)
    local scrollBar = scrollFrame.ScrollBar or _G[scrollFrame:GetName() and (scrollFrame:GetName() .. "ScrollBar")]
    if not scrollBar then return end

    local scrollBarWidth = (scrollBar:GetWidth() or 14) + 4

    local function UpdateScrollbarVisibility()
        local child = scrollFrame:GetScrollChild()
        if not child then return end
        local childHeight = child:GetHeight()
        local frameHeight = scrollFrame:GetHeight()
        local frameWidth = scrollFrame:GetWidth()
        if childHeight > frameHeight + 1 then
            scrollBar:Show()
            child:SetWidth(frameWidth - scrollBarWidth)
        else
            scrollBar:Hide()
            scrollFrame:SetVerticalScroll(0)
            child:SetWidth(frameWidth)
        end
    end

    scrollFrame:HookScript("OnScrollRangeChanged", UpdateScrollbarVisibility)
    scrollFrame:HookScript("OnShow", UpdateScrollbarVisibility)
    C_Timer.After(0, UpdateScrollbarVisibility)
end

-------------------------------------------------
-- Profile Row
-------------------------------------------------

local function CreateSeparator(parent, label)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetHeight(20)
    local text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("LEFT", frame, "LEFT", 0, 0)
    text:SetJustifyH("LEFT")
    text:SetTextColor(0.9, 0.75, 0.3)
    text:SetText(label)
    local line = frame:CreateTexture(nil, "ARTWORK")
    line:SetHeight(1)
    line:SetPoint("LEFT", text, "RIGHT", 6, 0)
    line:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
    line:SetColorTexture(0.5, 0.5, 0.5, 0.5)
    frame.line = line
    return frame
end

local function ReleaseFrame(f)
    if not f then return end
    f:Hide()
    f:ClearAllPoints()
end

local function CreateProfileRow(parent, profileInfo, yOffset)
    local ROW_HEIGHT = 28

    local row = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    row:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
    row:SetBackdrop({
        bgFile = Constants.TEXTURES and Constants.TEXTURES.WHITE_8x8 or "Interface\\Buttons\\WHITE8x8",
    })
    row:SetBackdropColor(0.1, 0.1, 0.1, 0.4)

    -- Profile name
    local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameText:SetPoint("LEFT", row, "LEFT", 6, 0)
    nameText:SetWidth(150)
    nameText:SetJustifyH("LEFT")
    nameText:SetText(profileInfo.name)
    nameText:SetTextColor(1, 1, 1)

    -- Current profile indicator + expansion badge
    local ProfileManager = ns:GetModule("ProfileManager")
    local isActive = ProfileManager:GetActiveProfile() == profileInfo.name

    if isActive then
        nameText:SetTextColor(0.3, 1, 0.3)
        row:SetBackdropColor(0.1, 0.2, 0.1, 0.5)
    end

    local badgeAnchor = nameText
    if isActive then
        local activeText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        activeText:SetPoint("LEFT", nameText, "RIGHT", 4, 0)
        activeText:SetText("|cff00cc00" .. L["PROFILE_ACTIVE"] .. "|r")
        badgeAnchor = activeText
    end

    local expName = ProfileManager:GetExpansionName(profileInfo.expansionId)
    local badgeText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    badgeText:SetPoint("LEFT", badgeAnchor, "RIGHT", 4, 0)
    badgeText:SetText("|cff888888[" .. expName .. "]|r")

    -- Delete button
    local deleteBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    deleteBtn:SetSize(50, 20)
    deleteBtn:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    deleteBtn:SetText(L["PROFILE_DELETE"])
    deleteBtn:GetFontString():SetFont(GameFontNormalSmall:GetFont())
    deleteBtn:SetScript("OnClick", function()
        local dialog = StaticPopup_Show("GUDABAGS_PROFILE_DELETE", profileInfo.name)
        if dialog then
            dialog.data = profileInfo.name
        end
    end)

    -- Load button
    local loadBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    loadBtn:SetSize(50, 20)
    loadBtn:SetPoint("RIGHT", deleteBtn, "LEFT", -4, 0)
    loadBtn:SetText(L["PROFILE_LOAD"])
    loadBtn:GetFontString():SetFont(GameFontNormalSmall:GetFont())
    loadBtn:SetScript("OnClick", function()
        local dialog = StaticPopup_Show("GUDABAGS_PROFILE_LOAD", profileInfo.name)
        if dialog then
            dialog.data = profileInfo.name
        end
    end)

    -- Export button
    local exportBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    exportBtn:SetSize(50, 20)
    exportBtn:SetPoint("RIGHT", loadBtn, "LEFT", -4, 0)
    exportBtn:SetText(L["PROFILE_EXPORT"])
    exportBtn:GetFontString():SetFont(GameFontNormalSmall:GetFont())
    exportBtn:SetScript("OnClick", function()
        local encoded = ProfileManager:ExportProfile(profileInfo.name)
        if encoded and importExportBox then
            importExportBox:SetText(encoded)
            importExportBox:HighlightText()
            importExportBox:SetFocus()
        end
    end)

    row:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.15, 0.15, 0.2, 0.6)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(profileInfo.name)
        if profileInfo.updatedAt then
            GameTooltip:AddLine(L["PROFILE_UPDATED"] .. ": " .. date("%Y-%m-%d %H:%M", profileInfo.updatedAt), 0.7, 0.7, 0.7)
        end
        if profileInfo.addonVersion then
            GameTooltip:AddLine("v" .. profileInfo.addonVersion, 0.5, 0.5, 0.5)
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0.1, 0.1, 0.1, 0.4)
        GameTooltip:Hide()
    end)

    return row
end

-------------------------------------------------
-- Refresh Profile List
-------------------------------------------------

function ProfilesTab:RefreshList()
    if not profileListScrollChild then return end

    for _, row in ipairs(profileRows) do
        ReleaseFrame(row)
    end
    profileRows = {}

    local ProfileManager = ns:GetModule("ProfileManager")
    local profiles = ProfileManager:GetProfileList()

    local yOffset = 0
    local ROW_HEIGHT = 28
    local SPACING = 2

    if #profiles == 0 then
        local emptyText = profileListScrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        emptyText:SetPoint("TOP", profileListScrollChild, "TOP", 0, -20)
        emptyText:SetText(L["PROFILE_NONE"])
        emptyText:SetTextColor(0.5, 0.5, 0.5)
        -- Store as a "row" so it gets cleaned up
        local emptyFrame = CreateFrame("Frame", nil, profileListScrollChild)
        emptyFrame:SetHeight(40)
        emptyFrame:SetPoint("TOPLEFT", profileListScrollChild, "TOPLEFT", 0, 0)
        emptyFrame:SetPoint("RIGHT", profileListScrollChild, "RIGHT", 0, 0)
        emptyText:SetParent(emptyFrame)
        emptyText:SetPoint("CENTER", emptyFrame, "CENTER")
        table.insert(profileRows, emptyFrame)
        profileListScrollChild:SetHeight(40)
        return
    end

    for _, profileInfo in ipairs(profiles) do
        local row = CreateProfileRow(profileListScrollChild, profileInfo, yOffset)
        row:Show()
        table.insert(profileRows, row)
        yOffset = yOffset - ROW_HEIGHT - SPACING
    end

    profileListScrollChild:SetHeight(math.abs(yOffset) + 10)
end

-------------------------------------------------
-- Create Profiles Tab Content
-------------------------------------------------

function ProfilesTab:CreateContent(parent)
    local content = CreateFrame("Frame", nil, parent)

    -- Save section
    local saveLabel = CreateSeparator(content, L["PROFILE_SAVE_SECTION"])
    saveLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    saveLabel:SetPoint("RIGHT", content, "RIGHT", 0, 0)

    local nameBox = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
    nameBox:SetSize(180, 20)
    nameBox:SetPoint("TOPLEFT", saveLabel, "BOTTOMLEFT", 4, -4)
    nameBox:SetAutoFocus(false)
    nameBox:SetMaxLetters(50)
    nameBox:SetTextInsets(0, 14, 0, 0)

    -- Clear button
    local clearBtn = CreateFrame("Button", nil, nameBox)
    clearBtn:SetSize(10, 10)
    clearBtn:SetPoint("RIGHT", nameBox, "RIGHT", -4, 0)
    clearBtn:Hide()
    local clearTex = clearBtn:CreateTexture(nil, "ARTWORK")
    clearTex:SetAllPoints()
    clearTex:SetTexture("Interface\\AddOns\\GudaBags\\Assets\\close.tga")
    clearTex:SetVertexColor(0.4, 0.4, 0.4)
    clearBtn:SetScript("OnEnter", function() clearTex:SetVertexColor(0.7, 0.7, 0.7) end)
    clearBtn:SetScript("OnLeave", function() clearTex:SetVertexColor(0.4, 0.4, 0.4) end)
    clearBtn:SetScript("OnClick", function()
        nameBox:SetText("")
        nameBox:ClearFocus()
    end)

    -- Placeholder text
    local placeholder = nameBox:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    placeholder:SetPoint("LEFT", nameBox, "LEFT", 2, 0)
    placeholder:SetText(L["PROFILE_NAME_PLACEHOLDER"])
    placeholder:SetTextColor(0.5, 0.5, 0.5)
    nameBox:SetScript("OnTextChanged", function(self)
        local hasText = self:GetText() ~= ""
        placeholder:SetShown(not hasText)
        clearBtn:SetShown(hasText)
    end)
    nameBox:HookScript("OnEditFocusGained", function()
        placeholder:Hide()
    end)
    nameBox:HookScript("OnEditFocusLost", function(self)
        placeholder:SetShown(self:GetText() == "")
    end)

    local saveBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    saveBtn:SetSize(60, 22)
    saveBtn:SetPoint("LEFT", nameBox, "RIGHT", 8, 0)
    saveBtn:SetText(L["PROFILE_SAVE"])

    -- Reset to Defaults button (right-aligned, same line as input)
    local resetBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    resetBtn:SetSize(100, 22)
    resetBtn:SetPoint("RIGHT", content, "RIGHT", 0, 0)
    resetBtn:SetPoint("TOP", nameBox, "TOP", 0, 0)
    resetBtn:SetText(L["PROFILE_RESET_DEFAULTS"])
    resetBtn:GetFontString():SetFont(GameFontNormalSmall:GetFont())
    resetBtn:SetScript("OnClick", function()
        StaticPopup_Show("GUDABAGS_PROFILE_RESET_DEFAULTS")
    end)

    local function DoSave()
        local name = nameBox:GetText()
        if not name or name == "" then return end

        local ProfileManager = ns:GetModule("ProfileManager")
        if ProfileManager:ProfileExists(name) then
            pendingImportData = nil
            local dialog = StaticPopup_Show("GUDABAGS_PROFILE_OVERWRITE", name)
            if dialog then
                dialog.data = name
            end
        else
            ProfileManager:SaveProfile(name)
            self:RefreshList()
            nameBox:SetText("")
            ns:Print(string.format(L["PROFILE_SAVED"], name))
        end
    end

    saveBtn:SetScript("OnClick", DoSave)
    nameBox:SetScript("OnEnterPressed", function(self)
        DoSave()
        self:ClearFocus()
    end)
    nameBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    -- Profile list section
    local listLabel = CreateSeparator(content, L["PROFILE_LIST_SECTION"])
    listLabel:SetPoint("TOPLEFT", saveLabel, "BOTTOMLEFT", 0, -34)
    listLabel:SetPoint("RIGHT", content, "RIGHT", 0, 0)

    -- Import/Export section (footer, anchored to bottom)
    local ieLabel = CreateSeparator(content, L["PROFILE_IMPORT_EXPORT"])
    ieLabel:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 0, 118)
    ieLabel:SetPoint("RIGHT", content, "RIGHT", 0, 0)

    -- NAMED: SetupScrollbarAutoHide resolves the bar via $parentScrollBar, which
    -- silently does nothing for an anonymous frame on pre-Cata clients.
    local ieScroll = CreateFrame("ScrollFrame", "GudaBagsProfilesImportExportScroll", content,
                                 "UIPanelScrollFrameTemplate")
    ieScroll:SetPoint("TOPLEFT", ieLabel, "BOTTOMLEFT", 0, -4)
    ieScroll:SetPoint("RIGHT", content, "RIGHT", -14, 0)
    ieScroll:SetPoint("BOTTOM", content, "BOTTOM", 0, 0)

    -- Profile list section (fills space between save and import/export). NAMED:
    -- see the import/export scroll frame above.
    local scrollFrame = CreateFrame("ScrollFrame", "GudaBagsProfilesListScroll", content,
                                    "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", listLabel, "BOTTOMLEFT", 0, -3)
    scrollFrame:SetPoint("RIGHT", content, "RIGHT", -18, 0)
    scrollFrame:SetPoint("BOTTOM", ieLabel, "TOP", 0, 10)

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetWidth(1)
    scrollChild:SetHeight(1)
    scrollFrame:SetScrollChild(scrollChild)
    profileListScrollChild = scrollChild
    SetupScrollbarAutoHide(scrollFrame)

    local ieBg = CreateFrame("Frame", nil, ieScroll, "BackdropTemplate")
    ieBg:SetPoint("TOPLEFT", ieScroll, "TOPLEFT", -4, 4)
    ieBg:SetPoint("BOTTOMRIGHT", ieScroll, "BOTTOMRIGHT", 18, -4)
    ieBg:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    ieBg:SetBackdropColor(0, 0, 0, 0.5)
    ieBg:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
    ieBg:SetFrameLevel(ieScroll:GetFrameLevel() + 10)
    ieBg:EnableMouse(true)
    ieBg:SetScript("OnMouseDown", function()
        if importExportBox then
            importExportBox:SetFocus()
        end
    end)

    local ieBox = CreateFrame("EditBox", nil, ieScroll)
    ieBox:SetMultiLine(true)
    ieBox:SetAutoFocus(false)
    ieBox:SetMaxLetters(0)
    ieBox:SetFontObject(ChatFontNormal)
    ieBox:SetWidth(1)
    ieBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    ieScroll:SetScrollChild(ieBox)
    importExportBox = ieBox
    SetupScrollbarAutoHide(ieScroll)

    local importBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    importBtn:SetSize(60, 22)
    importBtn:SetPoint("RIGHT", content, "RIGHT", 0, 0)
    importBtn:SetPoint("TOP", ieLabel, "TOP", 0, 6)
    importBtn:SetText(L["PROFILE_IMPORT"])

    -- Clip separator line to end before import button
    ieLabel.line:SetPoint("RIGHT", importBtn, "LEFT", -6, 0)

    importBtn:SetScript("OnClick", function()
        local text = ieBox:GetText()
        if not text or text == "" then return end

        local ProfileManager = ns:GetModule("ProfileManager")
        local success, result = ProfileManager:ImportProfile(text)
        if success then
            local dialog = StaticPopup_Show("GUDABAGS_PROFILE_IMPORT_NAME")
            if dialog then
                dialog.data = result
            end
        else
            ns:Print("|cffff4444" .. result .. "|r")
        end
    end)

    -- Sync widths on show so profile list rows match textarea width
    content:SetScript("OnShow", function(self)
        local width = self:GetWidth()
        if width and width > 0 then
            scrollChild:SetWidth(width)
            ieBox:SetWidth(width - 14)  -- account for scrollbar space on textarea
        end
        ProfilesTab:RefreshList()
    end)

    -- Initial refresh
    C_Timer.After(0.1, function()
        self:RefreshList()
    end)

    return content
end
