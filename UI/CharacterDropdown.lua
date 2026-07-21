local addonName, ns = ...

local CharacterDropdown = {}
ns:RegisterModule("CharacterDropdown", CharacterDropdown)

local L = ns.L

local Database = ns:GetModule("Database")
local Font = ns:GetModule("Font")

local DROPDOWN_WIDTH = 160
local ROW_HEIGHT = 20
local PADDING = 8
local MAX_VISIBLE_ROWS = 10

local function CreateDropdownFrame(frameName)
    local f = CreateFrame("Frame", frameName, UIParent, "BackdropTemplate")
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

    -- NAMED deliberately: pre-Cata UIPanelScrollFrameTemplate exposes its scroll
    -- bar only as the global $parentScrollBar, never as a .ScrollBar member, and
    -- the lookup below concatenates GetName() -- which is nil for an anonymous
    -- frame, turning a missing scroll bar into a hard error.
    local scrollFrame = CreateFrame("ScrollFrame", "GudaBagsCharacterDropdownScroll", f,
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

    return f
end

local function CreateRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(DROPDOWN_WIDTH - PADDING * 2 - 20, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -((index - 1) * ROW_HEIGHT))

    local highlight = row:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetTexture("Interface\\Buttons\\WHITE8x8")
    highlight:SetVertexColor(1, 1, 1, 0.1)

    local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    Font:Override(nameText)
    nameText:SetPoint("LEFT", row, "LEFT", 4, 0)
    nameText:SetJustifyH("LEFT")
    row.nameText = nameText

    local statusText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    Font:Override(statusText)
    statusText:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    statusText:SetJustifyH("RIGHT")
    row.statusText = statusText

    return row
end

local function PopulateDropdown(dropdown)
    local frame = dropdown.frame
    if not frame then return end

    local characters = Database:GetVisibleCharacters(false, true)
    local currentFullName = Database:GetPlayerFullName()
    local viewingCharacter = dropdown.getViewingCharacter and dropdown.getViewingCharacter() or nil

    local rowCount = #characters + 1

    local contentHeight = rowCount * ROW_HEIGHT
    local visibleHeight = math.min(rowCount, MAX_VISIBLE_ROWS) * ROW_HEIGHT

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

    frame.scrollFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PADDING - scrollBarWidth, PADDING)
    local rowWidth = DROPDOWN_WIDTH - PADDING * 2 - scrollBarWidth

    frame.content:SetHeight(contentHeight)
    frame.content:SetWidth(rowWidth)
    frame:SetHeight(visibleHeight + PADDING * 2)

    while #frame.rows < rowCount do
        local row = CreateRow(frame.content, #frame.rows + 1)
        table.insert(frame.rows, row)
    end

    for i, row in ipairs(frame.rows) do
        if i <= rowCount then
            row:SetWidth(rowWidth)
        else
            row:Hide()
        end
    end

    local rowIndex = 1

    -- Current character / Back row
    local currentRow = frame.rows[rowIndex]
    currentRow:SetPoint("TOPLEFT", frame.content, "TOPLEFT", 0, -((rowIndex - 1) * ROW_HEIGHT))

    if viewingCharacter then
        currentRow.nameText:SetText("|cff00ff00" .. L["BACK_TO_CURRENT"] .. "|r")
        currentRow.statusText:SetText("")
    else
        currentRow.nameText:SetText("|cffffffff" .. L["CURRENT_CHARACTER"] .. "|r")
        currentRow.statusText:SetText("")
    end

    currentRow:SetScript("OnClick", function()
        frame:Hide()
        if dropdown.onCharacterSelected then
            dropdown.onCharacterSelected(nil)
        end
    end)
    currentRow:Show()
    rowIndex = rowIndex + 1

    for _, char in ipairs(characters) do
        local row = frame.rows[rowIndex]
        row:SetPoint("TOPLEFT", frame.content, "TOPLEFT", 0, -((rowIndex - 1) * ROW_HEIGHT))

        local classColor = RAID_CLASS_COLORS[char.class]
        local r, g, b = 0.7, 0.7, 0.7
        if classColor then
            r, g, b = classColor.r, classColor.g, classColor.b
        end

        local isViewing = viewingCharacter == char.fullName
        local isCurrent = char.fullName == currentFullName

        local namePrefix = ""
        if isViewing then
            namePrefix = "|cff00ff00> |r"
        end

        row.nameText:SetText(namePrefix .. char.name)
        row.nameText:SetTextColor(r, g, b)

        local hasData = dropdown.hasDataFunc(char.fullName)
        if hasData then
            row.statusText:SetText("|cff666666(" .. char.level .. ")|r")
        else
            row.statusText:SetText("|cff994444" .. L["NO_DATA"] .. "|r")
        end

        row:SetScript("OnClick", function()
            frame:Hide()
            if dropdown.onCharacterSelected then
                if isCurrent then
                    dropdown.onCharacterSelected(nil)
                else
                    dropdown.onCharacterSelected(char.fullName, char)
                end
            end
        end)

        row:Show()
        rowIndex = rowIndex + 1
    end
end

-------------------------------------------------
-- Public API
-------------------------------------------------

-- Create a new character dropdown instance
-- config.frameName: unique global frame name
-- config.hasDataFunc: function(fullName) -> bool, checks if character has data
-- config.getViewingCharacter: function() -> fullName or nil
function CharacterDropdown:Create(config)
    local dropdown = {
        frame = nil,
        frameName = config.frameName,
        hasDataFunc = config.hasDataFunc,
        getViewingCharacter = config.getViewingCharacter,
        onCharacterSelected = nil,
    }

    function dropdown:Show(anchor)
        if not self.frame then
            self.frame = CreateDropdownFrame(self.frameName)
        end
        PopulateDropdown(self)
        self.frame:ClearAllPoints()
        self.frame:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
        self.frame:Show()
    end

    function dropdown:Hide()
        if self.frame then
            self.frame:Hide()
        end
    end

    function dropdown:Toggle(anchor)
        if self.frame and self.frame:IsShown() then
            self:Hide()
        else
            self:Show(anchor)
        end
    end

    function dropdown:SetCallback(callback)
        self.onCharacterSelected = callback
    end

    function dropdown:IsShown()
        return self.frame and self.frame:IsShown()
    end

    return dropdown
end
