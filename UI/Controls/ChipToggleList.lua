local addonName, ns = ...

local ChipToggleList = {}
ns:RegisterModule("Controls.ChipToggleList", ChipToggleList)

local CreateFrame = ns.CreateFrame or CreateFrame

-- Mirrors the search bar's own chip sizing so the picker reads as the same control
-- the user is about to see under the search box, not an abstract list of options.
local CHIP_SIZE = ns.Constants.FRAME.CHIP_SIZE
local CHIP_SPACING = ns.Constants.FRAME.CHIP_SPACING
local ROW_HEIGHT = 20
local ROW_SPACING = 2

local INACTIVE_BG = {0.15, 0.15, 0.15, 0.8}
local HIDDEN_ALPHA = 0.3

-- Positions the cells, skipping any whose owning addon or expansion doesn't provide
-- the chip. Re-run on Refresh rather than resolved once at build: availability can
-- change after login, and an unavailable chip is not always the last in its row, so
-- its slot has to close up rather than leave a hole.
local function LayoutCells(container, cells)
    local rowIndex, xOffset, lastGroup = 0, 0, nil

    for _, cell in ipairs(cells) do
        local available = not cell.availableFn or cell.availableFn() == true
        cell:SetShown(available)
        if available then
            -- A new row starts wherever the group changes, so a group with nothing
            -- available leaves no blank row behind.
            if lastGroup and cell.chipGroup ~= lastGroup then
                rowIndex = rowIndex + 1
                xOffset = 0
            end
            lastGroup = cell.chipGroup

            cell:ClearAllPoints()
            cell:SetPoint("TOPLEFT", container, "TOPLEFT", xOffset,
                -(rowIndex * (ROW_HEIGHT + ROW_SPACING)) - 3)
            xOffset = xOffset + cell:GetWidth() + CHIP_SPACING
        end
    end

    container:SetHeight((rowIndex + 1) * (ROW_HEIGHT + ROW_SPACING) + 4)
end

local function ApplyChipVisual(button, hidden)
    if hidden then
        button:SetAlpha(HIDDEN_ALPHA)
    else
        button:SetAlpha(1)
    end

    if button.dot then
        -- Quality entries are a colour swatch; the colour is the whole label.
        return
    end

    if hidden then
        button.label:SetTextColor(0.55, 0.55, 0.55)
        button.bg:SetVertexColor(INACTIVE_BG[1], INACTIVE_BG[2], INACTIVE_BG[3], INACTIVE_BG[4])
    else
        local c = button.chipColor
        button.label:SetTextColor(1, 1, 1)
        button.bg:SetVertexColor(c[1], c[2], c[3], c[4] or 0.9)
    end
end

-- One control for the whole session. CreateTabFromSchema's RefreshAll clears and
-- rebuilds the Features tab every time "Show Filter Chips" is toggled, and
-- VerticalStack:Clear only does Hide + SetParent(nil) -- rebuilding here would
-- re-CreateFrame ~20 buttons per toggle and orphan the previous set.
local singleton

function ChipToggleList:Create(parent, config)
    -- config = { label, tooltip }
    if singleton then
        singleton:SetParent(parent)
        singleton:Show()
        singleton:Refresh()
        return singleton
    end

    -- SearchBar is resolved lazily: Controls load before UI\SearchBar.lua, so a
    -- file-scope GetModule would be nil.
    local SearchBar = ns:GetModule("SearchBar")
    local Font = ns:GetModule("Font")

    local container = CreateFrame("Frame", nil, parent)
    local buttons = {}

    local catalogue = (SearchBar and SearchBar.GetChipCatalogue) and SearchBar:GetChipCatalogue() or {}

    -- The catalogue arrives grouped and in the order the strip lays the chips out, so
    -- LayoutCells can start a new row wherever the group changes. Reading it that way
    -- means this file never names a group, and cannot drift from SearchBar's own
    -- group constants.
    for _, entry in ipairs(catalogue) do
        local button = CreateFrame("Button", nil, container)
        button.settingKey = entry.settingKey
        button.chipColor = entry.color
        button.chipGroup = entry.group
        button.availableFn = entry.availableFn

        local bg = button:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture("Interface\\Buttons\\WHITE8x8")
        button.bg = bg

        if entry.swatch then
            -- Colour swatch, matching CreateQualityDot in UI\SearchBar.lua
            button:SetSize(CHIP_SIZE, CHIP_SIZE)
            bg:SetVertexColor(0, 0, 0, 0)
            local dot = button:CreateTexture(nil, "ARTWORK")
            dot:SetSize(CHIP_SIZE - 4, CHIP_SIZE - 4)
            dot:SetPoint("CENTER")
            dot:SetTexture("Interface\\Buttons\\WHITE8x8")
            dot:SetVertexColor(entry.color[1], entry.color[2], entry.color[3])
            button.dot = dot
        else
            local label = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            if Font then Font:Override(label) end
            label:SetPoint("CENTER", 0, 0)
            label:SetText(entry.label)
            button.label = label
            button:SetSize((label:GetStringWidth() or 20) + 10, CHIP_SIZE)
        end

        -- Every entry carries the full localized name; the strip's own labels may be
        -- abbreviated, so the tooltip is the only place some locales see the real word.
        local tooltipText = entry.tooltip or entry.label
        button:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(tooltipText, 1, 1, 1)
            GameTooltip:Show()
        end)
        button:SetScript("OnLeave", function() GameTooltip:Hide() end)

        button:SetScript("OnClick", function(self)
            if not SearchBar then return end
            local nowHidden = not SearchBar:IsChipHidden(self.settingKey)
            SearchBar:SetChipHidden(self.settingKey, nowHidden)
            ApplyChipVisual(self, nowHidden)
        end)

        ApplyChipVisual(button, SearchBar and SearchBar:IsChipHidden(entry.settingKey))
        buttons[#buttons + 1] = button
    end

    LayoutCells(container, buttons)

    if config and config.tooltip then
        container:EnableMouse(true)
        container:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(config.tooltip, 1, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        container:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    -- Public API (matches the other controls in UI\Controls\)
    container.Refresh = function()
        if not SearchBar then return end
        LayoutCells(container, buttons)
        for _, button in ipairs(buttons) do
            ApplyChipVisual(button, SearchBar:IsChipHidden(button.settingKey))
        end
    end

    singleton = container
    return container
end

return ChipToggleList
