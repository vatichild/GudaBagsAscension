local addonName, ns = ...

local TabPanel = {}
ns:RegisterModule("TabPanel", TabPanel)

-- Global counter for unique tab names
local tabCounter = 0

-- Retail tab texture
local TAB_TEXTURE = "Interface\\AddOns\\GudaBags\\Assets\\Themes\\retail\\uiframetabs"

local TAB_COORDS = {
    -- Normal (inactive) pieces
    left       = {0.015625, 0.5625, 0.816406, 0.957031},
    right      = {0.015625, 0.59375, 0.667969, 0.808594},
    middle     = {0, 0.015625, 0.175781, 0.316406},
    -- Selected (active) pieces
    leftSel    = {0.015625, 0.5625, 0.496094, 0.660156},
    rightSel   = {0.015625, 0.59375, 0.324219, 0.488281},
    middleSel  = {0, 0.015625, 0.00390625, 0.167969},
}

local function CreateRetailTab(container, tabInfo, index, prevTab, selectFn)
    local tab = CreateFrame("Button", nil, container)
    tab:SetSize(70, 32)

    -- Normal state textures
    local left = tab:CreateTexture(nil, "BACKGROUND")
    left:SetTexture(TAB_TEXTURE)
    left:SetSize(35, 36)
    left:SetPoint("TOPLEFT", tab, "TOPLEFT", -3, 0)
    left:SetTexCoord(unpack(TAB_COORDS.left))
    tab.Left = left

    local right = tab:CreateTexture(nil, "BACKGROUND")
    right:SetTexture(TAB_TEXTURE)
    right:SetSize(37, 36)
    right:SetPoint("TOPRIGHT", tab, "TOPRIGHT", 7, 0)
    right:SetTexCoord(unpack(TAB_COORDS.right))
    tab.Right = right

    local middle = tab:CreateTexture(nil, "BACKGROUND")
    middle:SetTexture(TAB_TEXTURE)
    middle:SetSize(1, 36)
    middle:SetPoint("TOPLEFT", left, "TOPRIGHT", 0, 0)
    middle:SetPoint("TOPRIGHT", right, "TOPLEFT", 0, 0)
    middle:SetTexCoord(unpack(TAB_COORDS.middle))
    tab.Middle = middle

    -- Selected state textures
    local leftSel = tab:CreateTexture(nil, "BACKGROUND")
    leftSel:SetTexture(TAB_TEXTURE)
    leftSel:SetSize(35, 45)
    leftSel:SetPoint("TOPLEFT", tab, "TOPLEFT", -1, 0)
    leftSel:SetTexCoord(unpack(TAB_COORDS.leftSel))
    leftSel:Hide()
    tab.LeftSel = leftSel

    local rightSel = tab:CreateTexture(nil, "BACKGROUND")
    rightSel:SetTexture(TAB_TEXTURE)
    rightSel:SetSize(37, 45)
    rightSel:SetPoint("TOPRIGHT", tab, "TOPRIGHT", 8, 0)
    rightSel:SetTexCoord(unpack(TAB_COORDS.rightSel))
    rightSel:Hide()
    tab.RightSel = rightSel

    local middleSel = tab:CreateTexture(nil, "BACKGROUND")
    middleSel:SetTexture(TAB_TEXTURE)
    middleSel:SetSize(1, 45)
    middleSel:SetPoint("TOPLEFT", leftSel, "TOPRIGHT", 0, 0)
    middleSel:SetPoint("TOPRIGHT", rightSel, "TOPLEFT", 0, 0)
    middleSel:SetTexCoord(unpack(TAB_COORDS.middleSel))
    middleSel:Hide()
    tab.MiddleSel = middleSel

    -- Highlight textures
    local hlLeft = tab:CreateTexture(nil, "HIGHLIGHT")
    hlLeft:SetTexture(TAB_TEXTURE)
    hlLeft:SetSize(35, 36)
    hlLeft:SetPoint("TOPLEFT", tab, "TOPLEFT", -3, 0)
    hlLeft:SetTexCoord(unpack(TAB_COORDS.left))
    hlLeft:SetBlendMode("ADD")
    hlLeft:SetAlpha(0.4)
    tab.HlLeft = hlLeft

    local hlRight = tab:CreateTexture(nil, "HIGHLIGHT")
    hlRight:SetTexture(TAB_TEXTURE)
    hlRight:SetSize(37, 36)
    hlRight:SetPoint("TOPRIGHT", tab, "TOPRIGHT", 7, 0)
    hlRight:SetTexCoord(unpack(TAB_COORDS.right))
    hlRight:SetBlendMode("ADD")
    hlRight:SetAlpha(0.4)
    tab.HlRight = hlRight

    local hlMiddle = tab:CreateTexture(nil, "HIGHLIGHT")
    hlMiddle:SetTexture(TAB_TEXTURE)
    hlMiddle:SetSize(1, 36)
    hlMiddle:SetPoint("TOPLEFT", hlLeft, "TOPRIGHT", 0, 0)
    hlMiddle:SetPoint("TOPRIGHT", hlRight, "TOPLEFT", 0, 0)
    hlMiddle:SetTexCoord(unpack(TAB_COORDS.middle))
    hlMiddle:SetBlendMode("ADD")
    hlMiddle:SetAlpha(0.4)
    tab.HlMiddle = hlMiddle

    -- Label
    local label = tab:CreateFontString(nil, "BORDER", "GameFontNormalSmall")
    label:SetPoint("CENTER", tab, "CENTER", 0, 2)
    label:SetText(tabInfo.label)
    tab.Text = label

    -- Auto-size based on text
    local textWidth = label:GetStringWidth()
    tab:SetSize(textWidth + 36, 32)

    -- Tint all tab textures
    function tab:SetTint(r, g, b)
        left:SetVertexColor(r, g, b)
        right:SetVertexColor(r, g, b)
        middle:SetVertexColor(r, g, b)
        leftSel:SetVertexColor(r, g, b)
        rightSel:SetVertexColor(r, g, b)
        middleSel:SetVertexColor(r, g, b)
        hlLeft:SetVertexColor(r, g, b)
        hlRight:SetVertexColor(r, g, b)
        hlMiddle:SetVertexColor(r, g, b)
    end

    -- State function
    function tab:SetSelected(selected)
        if selected then
            left:Hide(); right:Hide(); middle:Hide()
            leftSel:Show(); rightSel:Show(); middleSel:Show()
            hlLeft:SetHeight(45); hlRight:SetHeight(45); hlMiddle:SetHeight(45)
            label:SetTextColor(1, 1, 1)
        else
            left:Show(); right:Show(); middle:Show()
            leftSel:Hide(); rightSel:Hide(); middleSel:Hide()
            hlLeft:SetHeight(36); hlRight:SetHeight(36); hlMiddle:SetHeight(36)
            label:SetTextColor(1, 0.82, 0)
        end
    end

    -- Position: bottom-anchored
    if not prevTab then
        tab:SetPoint("BOTTOMLEFT", container:GetParent(), "BOTTOMLEFT", 8, -30)
    else
        tab:SetPoint("BOTTOMLEFT", prevTab, "BOTTOMRIGHT", 1, 0)
    end

    tab:SetScript("OnClick", function()
        PlaySound(SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB or 841)
        selectFn(tabInfo.id)
    end)

    if tabInfo.tooltip then
        tab:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(tabInfo.tooltip)
            GameTooltip:Show()
        end)
        tab:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
    end

    tab:SetSelected(false)
    return tab
end

function TabPanel:Create(parent, config)
    -- config = { tabs = {{id, label}, ...}, tabHeight, topMargin, padding, onSelect }
    local container = CreateFrame("Frame", nil, parent)
    local tabs = {}
    local tabButtons = {}      -- standard (top) tab buttons
    local retailButtons = {}   -- retail (bottom) tab buttons
    local tabContents = {}
    local activeTab = nil
    local currentTheme = nil   -- "retail" or nil

    local topMargin = config.topMargin or 0
    local padding = config.padding or 12

    container.Tabs = tabButtons

    -- Content area (tabs are at bottom, so full top space)
    local contentArea = CreateFrame("Frame", nil, container)
    contentArea:SetPoint("TOPLEFT", container, "TOPLEFT", padding, -topMargin - 10)
    contentArea:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -padding, padding)

    local function SelectTab(tabId)
        activeTab = tabId

        -- Find tab index
        local tabIndex = 1
        for i, tabInfo in ipairs(config.tabs) do
            if tabInfo.id == tabId then
                tabIndex = i
                break
            end
        end

        if currentTheme == "blizzard" then
            -- Update standard tab visuals using PanelTemplates
            PanelTemplates_SetTab(container, tabIndex)
        else
            -- Update retail/guda custom tab visuals
            for i, btn in ipairs(retailButtons) do
                btn:SetSelected(i == tabIndex)
            end
        end

        -- Show/hide content
        for id, content in pairs(tabContents) do
            if id == tabId then
                content:Show()
            else
                content:Hide()
            end
        end

        if config.onSelect then
            config.onSelect(tabId)
        end
    end

    local function CreateTabButton(tabInfo, index)
        tabCounter = tabCounter + 1
        local tabName = "GudaBagsSettingsTab" .. tabCounter

        -- Bottom-oriented tab: rounded borders go down
        -- Retail uses "PanelTabButtonTemplate" (SharedXML)
        -- Classic/TBC/MoP/Anniversary use "CharacterFrameTabButtonTemplate" (FrameXML)
        local tabTemplate = ns.IsRetail and "PanelTabButtonTemplate" or "CharacterFrameTabButtonTemplate"
        local tab = CreateFrame("Button", tabName, container, tabTemplate)

        -- Position tabs at the bottom
        if index == 1 then
            tab:SetPoint("BOTTOMLEFT", container:GetParent(), "BOTTOMLEFT", 8, -30)
        else
            tab:SetPoint("BOTTOMLEFT", tabButtons[index - 1], "BOTTOMRIGHT", -16, 0)
        end

        tab:SetText(tabInfo.label)
        tab:SetID(index)

        tab:SetScript("OnShow", function(self)
            PanelTemplates_TabResize(self, 10, nil, 10)
            PanelTemplates_DeselectTab(self)
        end)

        tab:SetScript("OnClick", function()
            SelectTab(tabInfo.id)
        end)

        if tabInfo.tooltip then
            tab:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
                GameTooltip:SetText(tabInfo.tooltip)
                GameTooltip:Show()
            end)
            tab:SetScript("OnLeave", function()
                GameTooltip:Hide()
            end)
        end

        return tab
    end

    -- Create standard tab buttons
    for i, tabInfo in ipairs(config.tabs) do
        local tab = CreateTabButton(tabInfo, i)
        tabButtons[i] = tab
        tabs[tabInfo.id] = tab
    end

    -- Set up PanelTemplates
    PanelTemplates_SetNumTabs(container, #config.tabs)

    -- Lazily create retail tabs
    local function EnsureRetailTabs()
        if #retailButtons > 0 then return end
        local prev = nil
        for i, tabInfo in ipairs(config.tabs) do
            local btn = CreateRetailTab(container, tabInfo, i, prev, SelectTab)
            retailButtons[i] = btn
            btn:Hide()
            prev = btn
        end
    end

    -- Public API
    container.SelectTab = SelectTab
    container.GetActiveTab = function() return activeTab end
    container.GetContentArea = function() return contentArea end

    container.SetContent = function(self, tabId, content)
        content:SetParent(contentArea)
        content:SetAllPoints(contentArea)
        content:Hide()
        tabContents[tabId] = content
    end

    container.GetContent = function(self, tabId)
        return tabContents[tabId]
    end

    container.RefreshAll = function(self)
        for _, content in pairs(tabContents) do
            if content.RefreshAll then
                content:RefreshAll()
            end
        end
    end

    container.ApplyTheme = function(self, theme)
        -- theme: "retail", "guda", or "blizzard"
        currentTheme = theme
        EnsureRetailTabs()

        if theme == "blizzard" then
            -- Blizzard: use standard Blizzard template tabs
            for _, btn in ipairs(retailButtons) do btn:Hide() end
            for _, btn in ipairs(tabButtons) do btn:Show() end
        else
            -- Retail & Guda: use custom tabs with tinting
            for _, btn in ipairs(tabButtons) do btn:Hide() end
            for _, btn in ipairs(retailButtons) do
                if theme == "guda" then
                    btn:SetTint(0.45, 0.45, 0.45)
                else
                    btn:SetTint(1, 1, 1)
                end
                btn:Show()
            end
        end

        -- Re-select active tab to update visuals
        if activeTab then
            SelectTab(activeTab)
        end
    end

    -- Select first tab by default
    if config.tabs[1] then
        SelectTab(config.tabs[1].id)
    end

    return container
end

return TabPanel
