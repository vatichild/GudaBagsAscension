local addonName, ns = ...

local Characters = {}
ns:RegisterModule("Header.Characters", Characters)

local Database = ns:GetModule("Database")
local Font = ns:GetModule("Font")

local frame = nil
local onCharacterSelected = nil

local DROPDOWN_WIDTH = 140
local ROW_HEIGHT = 20
local PADDING = 8
local MAX_VISIBLE_ROWS = 10

local function CreateDropdownFrame()
    local f = CreateFrame("Frame", "GudaBagsCharacterDropdown", UIParent, "BackdropTemplate")
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

    -- Close when clicking outside
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

    -- Scroll frame for character list.
    -- NAMED deliberately: pre-Cata the scroll bar exists only as the global
    -- $parentScrollBar, and the lookup below concatenates GetName().
    local scrollFrame = CreateFrame("ScrollFrame", "GudaBagsHeaderCharactersScroll", f,
                                    "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", PADDING, -PADDING)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PADDING - 20, PADDING)
    f.scrollFrame = scrollFrame

    -- Hide scroll bar when not needed
    local scrollBar = scrollFrame.ScrollBar or _G[scrollFrame:GetName() and (scrollFrame:GetName() .. "ScrollBar")]
    if scrollBar then
        scrollBar:SetAlpha(0.7)
    end

    -- Content frame inside scroll
    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(DROPDOWN_WIDTH - PADDING * 2 - 20, 100)
    scrollFrame:SetScrollChild(content)
    f.content = content

    f.rows = {}

    return f
end

local function CreateRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(DROPDOWN_WIDTH - PADDING * 2 - 20, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -((index - 1) * ROW_HEIGHT))

    -- Highlight on hover
    local highlight = row:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetTexture("Interface\\Buttons\\WHITE8x8")
    highlight:SetVertexColor(1, 1, 1, 0.1)

    -- Character name (left)
    local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    Font:Override(nameText)
    nameText:SetPoint("LEFT", row, "LEFT", 4, 0)
    nameText:SetJustifyH("LEFT")
    row.nameText = nameText

    -- Level text (small, after name)
    local levelText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    Font:Override(levelText)
    levelText:SetPoint("LEFT", nameText, "RIGHT", 2, 0)
    levelText:SetTextColor(0.6, 0.6, 0.6)
    row.levelText = levelText

    return row
end

local function PopulateDropdown()
    if not frame then return end

    local characters = Database:GetVisibleCharacters(false, true) -- Same realm only, excludes hidden chars
    local currentFullName = Database:GetPlayerFullName()
    local BagFrame = ns:GetModule("BagFrame")
    local viewingCharacter = BagFrame:GetViewingCharacter()

    -- Calculate content height
    local rowCount = #characters + 1 -- +1 for "Current Character" option
    local contentHeight = rowCount * ROW_HEIGHT
    local visibleHeight = math.min(rowCount, MAX_VISIBLE_ROWS) * ROW_HEIGHT

    -- Show/hide scroll bar based on row count
    local needsScrollBar = rowCount > MAX_VISIBLE_ROWS
    local scrollBar = frame.scrollFrame.ScrollBar or _G[frame.scrollFrame:GetName() and (frame.scrollFrame:GetName() .. "ScrollBar")]
    local scrollBarWidth = needsScrollBar and 20 or 0

    if scrollBar then
        if needsScrollBar then
            scrollBar:Show()
        else
            scrollBar:Hide()
        end
    end

    -- Adjust scroll frame and row width based on scroll bar visibility
    frame.scrollFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PADDING - scrollBarWidth, PADDING)
    local rowWidth = DROPDOWN_WIDTH - PADDING * 2 - scrollBarWidth

    frame.content:SetHeight(contentHeight)
    frame.content:SetWidth(rowWidth)
    frame:SetHeight(visibleHeight + PADDING * 2)

    -- Create rows if needed
    while #frame.rows < rowCount do
        local row = CreateRow(frame.content, #frame.rows + 1)
        table.insert(frame.rows, row)
    end

    -- Update row widths and hide extra rows
    for i, row in ipairs(frame.rows) do
        if i <= rowCount then
            row:SetWidth(rowWidth)
        else
            row:Hide()
        end
    end

    local rowIndex = 1

    -- "Current Character" option (always first)
    local currentRow = frame.rows[rowIndex]
    currentRow:SetPoint("TOPLEFT", frame.content, "TOPLEFT", 0, -((rowIndex - 1) * ROW_HEIGHT))

    if viewingCharacter then
        currentRow.nameText:SetText("|cff00ff00< Back to Current|r")
        currentRow.levelText:SetText("")
    else
        currentRow.nameText:SetText("|cffffffff(Current Character)|r")
        currentRow.levelText:SetText("")
    end

    currentRow:SetScript("OnClick", function()
        frame:Hide()
        if onCharacterSelected then
            onCharacterSelected(nil) -- nil = current character
        end
    end)
    currentRow:Show()
    rowIndex = rowIndex + 1

    -- Character list
    for _, char in ipairs(characters) do
        local row = frame.rows[rowIndex]
        row:SetPoint("TOPLEFT", frame.content, "TOPLEFT", 0, -((rowIndex - 1) * ROW_HEIGHT))

        -- Class color
        local classColor = RAID_CLASS_COLORS[char.class]
        local r, g, b = 0.7, 0.7, 0.7
        if classColor then
            r, g, b = classColor.r, classColor.g, classColor.b
        end

        -- Highlight current view
        local isViewing = viewingCharacter == char.fullName
        local isCurrent = char.fullName == currentFullName

        local namePrefix = ""
        if isViewing then
            namePrefix = "|cff00ff00> |r"
        elseif isCurrent then
            namePrefix = ""
        end

        row.nameText:SetText(namePrefix .. char.name)
        row.nameText:SetTextColor(r, g, b)

        -- Level
        row.levelText:SetText("(" .. char.level .. ")")

        row:SetScript("OnClick", function()
            frame:Hide()
            if onCharacterSelected then
                if isCurrent then
                    onCharacterSelected(nil)
                else
                    onCharacterSelected(char.fullName, char)
                end
            end
        end)

        row:Show()
        rowIndex = rowIndex + 1
    end
end

function Characters:Show(anchor)
    if not frame then
        frame = CreateDropdownFrame()
    end

    PopulateDropdown()

    -- Position relative to anchor
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)

    frame:Show()
end

function Characters:Hide()
    if frame then
        frame:Hide()
    end
end

function Characters:Toggle(anchor)
    if frame and frame:IsShown() then
        self:Hide()
    else
        self:Show(anchor)
    end
end

function Characters:SetCallback(callback)
    onCharacterSelected = callback
end

function Characters:IsShown()
    return frame and frame:IsShown()
end
