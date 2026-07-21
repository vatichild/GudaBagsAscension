local addonName, ns = ...

local CategoryEditor = {}
ns:RegisterModule("CategoryEditor", CategoryEditor)

local Constants = ns.Constants
local Events = ns:GetModule("Events")
local Theme = ns:GetModule("Theme")

local frame
local currentCategoryId
local currentRules = {}

-- Unique names for OptionsSliderTemplate instances; see CreateRuleValueControl.
local editorSliderCounter = 0
local currentMatchMode = "any"
local currentGroup = ""
local currentMark = nil
local ruleRows = {}
local isCreatingNew = false

-- Available mark icons for category items
local MARK_ICONS = {
    "Interface\\AddOns\\GudaBags\\Assets\\equipment.tga",
    "Interface\\AddOns\\GudaBags\\Assets\\plus.tga",
    "Interface\\AddOns\\GudaBags\\Assets\\guild.tga",
    "Interface\\AddOns\\GudaBags\\Assets\\combat.tga",
    "Interface\\AddOns\\GudaBags\\Assets\\cog.tga",
}

local EDITOR_WIDTH = Constants.CATEGORY_UI.EDITOR_WIDTH
local EDITOR_HEIGHT = Constants.CATEGORY_UI.EDITOR_HEIGHT
local PADDING = Constants.CATEGORY_UI.EDITOR_PADDING
local ROW_HEIGHT = Constants.CATEGORY_UI.RULE_ROW_HEIGHT

local RULE_TYPES

-------------------------------------------------
-- UI Helpers
-------------------------------------------------

local genericDropdownCounter = 0

local function CreateDropdown(parent, width, items, onSelect)
    -- MUST be named: pre-Cata UIDropDownMenu_SetWidth/_SetText resolve their
    -- child widgets through getglobal(frame:GetName() .. "Middle"/"Text"), so an
    -- anonymous dropdown makes them concatenate nil and throw.
    genericDropdownCounter = genericDropdownCounter + 1
    local dropdown = CreateFrame("Frame", "GudaBagsCategoryDropdown" .. genericDropdownCounter,
                                 parent, "UIDropDownMenuTemplate")
    dropdown:SetPoint("LEFT", parent, "LEFT", 0, 0)
    UIDropDownMenu_SetWidth(dropdown, width - 30)

    local currentValue = nil
    local currentLabel = ""

    UIDropDownMenu_Initialize(dropdown, function(self, level)
        for _, item in ipairs(items) do
            local info = UIDropDownMenu_CreateInfo()
            if type(item) == "table" then
                info.text = item.label
                info.value = item.value
            else
                info.text = item
                info.value = item
            end
            info.func = function(self)
                currentValue = self.value
                currentLabel = self:GetText()
                UIDropDownMenu_SetText(dropdown, currentLabel)
                if onSelect then
                    onSelect(currentValue)
                end
            end
            info.checked = (info.value == currentValue)
            UIDropDownMenu_AddButton(info, level)
        end
    end)

    dropdown.GetValue = function() return currentValue end
    dropdown.SetValue = function(self, val, label)
        currentValue = val
        if val == nil then
            currentLabel = "---"
        else
            currentLabel = label or tostring(val)
        end
        UIDropDownMenu_SetText(dropdown, currentLabel)
    end

    return dropdown
end

local function CreateSmallButton(parent, text, width, onClick)
    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetSize(width, 22)
    btn:SetText(text)
    btn:SetScript("OnClick", onClick)
    return btn
end

-------------------------------------------------
-- Item Drop Slot (for itemID rule)
-------------------------------------------------

local function CreateItemDropSlot(parent, onItemDropped)
    local slot = CreateFrame("Button", nil, parent, "BackdropTemplate")
    slot:SetSize(32, 32)
    slot:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    slot:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
    slot:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

    local icon = slot:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 2, -2)
    icon:SetPoint("BOTTOMRIGHT", -2, 2)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    slot.icon = icon

    local hint = slot:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("CENTER")
    hint:SetText("?")
    hint:SetTextColor(0.5, 0.5, 0.5)
    slot.hint = hint

    slot:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    slot:RegisterForDrag("LeftButton")

    slot:SetScript("OnReceiveDrag", function(self)
        local infoType, itemID, itemLink = GetCursorInfo()
        if infoType == "item" and itemID then
            ClearCursor()
            local name, _, _, _, _, _, _, _, _, texture = GetItemInfo(itemLink or itemID)
            if texture then
                icon:SetTexture(texture)
                icon:Show()
                hint:Hide()
            end
            if onItemDropped then
                onItemDropped(itemID, name)
            end
        end
    end)

    slot:SetScript("OnClick", function(self, button)
        if button == "LeftButton" then
            local infoType, itemID, itemLink = GetCursorInfo()
            if infoType == "item" and itemID then
                ClearCursor()
                local name, _, _, _, _, _, _, _, _, texture = GetItemInfo(itemLink or itemID)
                if texture then
                    icon:SetTexture(texture)
                    icon:Show()
                    hint:Hide()
                end
                if onItemDropped then
                    onItemDropped(itemID, name)
                end
            end
        elseif button == "RightButton" then
            icon:SetTexture(nil)
            icon:Hide()
            hint:Show()
            if onItemDropped then
                onItemDropped(nil, nil)
            end
        end
    end)

    slot:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(ns.L["ITEM_ID_SLOT"], 1, 0.82, 0)
        GameTooltip:AddLine(ns.L["ITEM_ID_SLOT_TIP"], 1, 1, 1, true)
        GameTooltip:AddLine(ns.L["RIGHT_CLICK_CLEAR"], 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)

    slot:SetScript("OnLeave", function() GameTooltip:Hide() end)

    slot.SetItem = function(self, itemID)
        if itemID then
            local name, _, _, _, _, _, _, _, _, texture = GetItemInfo(itemID)
            if texture then
                icon:SetTexture(texture)
                icon:Show()
                hint:Hide()
            end
        else
            icon:SetTexture(nil)
            icon:Hide()
            hint:Show()
        end
    end

    slot.Clear = function(self)
        icon:SetTexture(nil)
        icon:Hide()
        hint:Show()
    end

    return slot
end

-------------------------------------------------
-- Rule Row
-------------------------------------------------

-- Counter for unique dropdown names
local dropdownCounter = 0

local function CreateRuleTypeDropdown(parent, index, onSelect)
    dropdownCounter = dropdownCounter + 1
    local dropdownName = "GudaBagsRuleTypeDropdown" .. dropdownCounter

    local dropdown = CreateFrame("Frame", dropdownName, parent, "UIDropDownMenuTemplate")
    UIDropDownMenu_SetWidth(dropdown, 100)

    local currentTypeId = nil

    UIDropDownMenu_Initialize(dropdown, function(self, level)
        for _, rt in ipairs(RULE_TYPES) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = rt.label
            info.value = rt.id
            info.func = function(self)
                currentTypeId = self.value
                UIDropDownMenu_SetText(dropdown, rt.shortLabel or rt.label)
                if onSelect then
                    onSelect(self.value)
                end
            end
            info.checked = (rt.id == currentTypeId)
            if rt.tooltip then
                info.tooltipTitle = rt.label
                info.tooltipText = rt.tooltip
                info.tooltipOnButton = true
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)

    dropdown.GetValue = function() return currentTypeId end
    dropdown.SetValue = function(self, typeId)
        currentTypeId = typeId
        -- Find the label for this type
        for _, rt in ipairs(RULE_TYPES) do
            if rt.id == typeId then
                UIDropDownMenu_SetText(dropdown, rt.shortLabel or rt.label)
                break
            end
        end
    end

    return dropdown
end

local function CreateRuleRow(parent, index)
    local row = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    row:SetHeight(ROW_HEIGHT)
    row:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
    })
    row:SetBackdropColor(0.15, 0.15, 0.15, 0.5)

    -- Delete button
    local deleteBtn = CreateFrame("Button", nil, row)
    deleteBtn:SetSize(16, 16)
    deleteBtn:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    deleteBtn:SetNormalTexture("Interface\\Buttons\\UI-StopButton")
    deleteBtn:SetHighlightTexture("Interface\\Buttons\\UI-StopButton")
    deleteBtn:GetHighlightTexture():SetVertexColor(1, 0.3, 0.3)
    deleteBtn:SetScript("OnClick", function()
        CategoryEditor:RemoveRule(index)
    end)
    deleteBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(ns.L["DELETE_RULE"])
        GameTooltip:Show()
    end)
    deleteBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.deleteBtn = deleteBtn

    -- Rule type dropdown (standard Blizzard dropdown)
    local typeDropdown = CreateRuleTypeDropdown(row, index, function(typeId)
        currentRules[index].type = typeId
        currentRules[index].value = nil
        CategoryEditor:RefreshRules()
    end)
    typeDropdown:SetPoint("LEFT", row, "LEFT", -12, 0)
    row.typeDropdown = typeDropdown

    -- Required-rule checkbox (between type dropdown and value control)
    local requiredCheckbox = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    requiredCheckbox:SetSize(18, 18)
    requiredCheckbox:SetPoint("LEFT", typeDropdown, "RIGHT", -10, 0)
    requiredCheckbox:SetScript("OnClick", function(self)
        if currentMatchMode == "all" then
            -- No-op in "all" mode; keep visual state synced to stored value
            self:SetChecked(currentRules[index] and currentRules[index].required == true)
            return
        end
        if currentRules[index] then
            if self:GetChecked() then
                currentRules[index].required = true
            else
                currentRules[index].required = nil
            end
        end
    end)
    requiredCheckbox:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(ns.L["RULE_REQUIRED"], 1, 0.82, 0)
        GameTooltip:AddLine(ns.L["RULE_REQUIRED_TIP"], 1, 1, 1, true)
        GameTooltip:Show()
    end)
    requiredCheckbox:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.requiredCheckbox = requiredCheckbox

    -- Value container (positioned after required-checkbox)
    local valueContainer = CreateFrame("Frame", nil, row)
    valueContainer:SetPoint("LEFT", requiredCheckbox, "RIGHT", 2, 0)
    valueContainer:SetPoint("RIGHT", deleteBtn, "LEFT", -8, 0)
    valueContainer:SetHeight(ROW_HEIGHT)
    row.valueContainer = valueContainer

    row.index = index
    row.ruleType = nil
    row.ruleValue = nil
    row.valueControl = nil

    return row
end

-- Sync every rule row's required-checkbox to current state and matchMode
local function UpdateRequiredCheckboxes()
    local disabled = currentMatchMode == "all"
    for i, row in ipairs(ruleRows) do
        if row.requiredCheckbox then
            local rule = currentRules[i]
            row.requiredCheckbox:SetChecked(rule and rule.required == true)
            if disabled then
                row.requiredCheckbox:Disable()
                row.requiredCheckbox:SetAlpha(0.35)
            else
                row.requiredCheckbox:Enable()
                row.requiredCheckbox:SetAlpha(1)
            end
        end
    end
end

local function UpdateRuleRowValue(row, ruleType, ruleValue)
    row.ruleType = ruleType
    row.ruleValue = ruleValue

    -- Find rule type info
    local ruleInfo
    for _, rt in ipairs(RULE_TYPES) do
        if rt.id == ruleType then
            ruleInfo = rt
            break
        end
    end

    -- Update dropdown selection
    if row.typeDropdown then
        row.typeDropdown:SetValue(ruleType)
    end

    if not ruleInfo then
        return
    end

    -- Clear existing value control
    if row.valueControl then
        row.valueControl:Hide()
        row.valueControl:SetParent(nil)
    end

    local vc = row.valueContainer

    if ruleInfo.valueType == "boolean" then
        local cb = CreateFrame("CheckButton", nil, vc, "UICheckButtonTemplate")
        cb:SetPoint("LEFT", vc, "LEFT", 0, 0)
        cb:SetSize(24, 24)
        cb:SetChecked(ruleValue == true)
        cb:SetScript("OnClick", function(self)
            currentRules[row.index].value = self:GetChecked()
        end)
        if ruleInfo.tooltip then
            cb:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(ruleInfo.label, 1, 0.82, 0)
                GameTooltip:AddLine(ruleInfo.tooltip, 1, 1, 1, true)
                GameTooltip:Show()
            end)
            cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
        row.valueControl = cb

    elseif ruleInfo.valueType == "dropdown" then
        local items = ruleInfo.options
        local dropdown = CreateDropdown(vc, 140, items, function(val)
            currentRules[row.index].value = val
        end)
        dropdown:SetPoint("LEFT", vc, "LEFT", -16, 0)

        -- Find the label for the current value
        local label = nil
        if ruleValue ~= nil then
            for _, opt in ipairs(items) do
                if type(opt) == "table" and opt.value == ruleValue then
                    label = opt.label
                    break
                elseif opt == ruleValue then
                    label = ruleValue
                    break
                end
            end
        end
        dropdown:SetValue(ruleValue, label)
        row.valueControl = dropdown

    elseif ruleInfo.valueType == "text" then
        local editBox = CreateFrame("EditBox", nil, vc, "InputBoxTemplate")
        editBox:SetSize(140, 20)
        editBox:SetPoint("LEFT", vc, "LEFT", 6, 0)
        editBox:SetAutoFocus(false)
        editBox:SetText(ruleValue or "")
        editBox:SetScript("OnTextChanged", function(self)
            currentRules[row.index].value = self:GetText()
        end)
        editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        editBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
        row.valueControl = editBox

    elseif ruleInfo.valueType == "itemID" then
        local container = CreateFrame("Frame", nil, vc)
        container:SetAllPoints()

        local editBox = CreateFrame("EditBox", nil, container, "InputBoxTemplate")
        editBox:SetSize(80, 20)
        editBox:SetPoint("LEFT", container, "LEFT", 6, 0)
        editBox:SetAutoFocus(false)
        editBox:SetNumeric(true)
        if type(ruleValue) == "number" then
            editBox:SetText(tostring(ruleValue))
        elseif type(ruleValue) == "table" and #ruleValue > 0 then
            editBox:SetText(tostring(ruleValue[1]))
        else
            editBox:SetText("")
        end
        local slot
        editBox:SetScript("OnTextChanged", function(self)
            local num = tonumber(self:GetText())
            if num then
                currentRules[row.index].value = num
                if slot then slot:SetItem(num) end
            end
        end)
        editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        editBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

        slot = CreateItemDropSlot(container, function(itemID, itemName)
            if itemID then
                editBox:SetText(tostring(itemID))
                currentRules[row.index].value = itemID
            else
                editBox:SetText("")
                currentRules[row.index].value = nil
            end
        end)
        slot:SetPoint("LEFT", editBox, "RIGHT", 8, 0)

        -- Add hint text
        local hint = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hint:SetPoint("LEFT", slot, "RIGHT", 6, 0)
        hint:SetText(ns.L["DROP_ITEM"])
        hint:SetTextColor(0.5, 0.5, 0.5)

        if type(ruleValue) == "number" then
            slot:SetItem(ruleValue)
        end

        row.valueControl = container

    elseif ruleInfo.valueType == "slider" then
        local container = CreateFrame("Frame", nil, vc)
        container:SetAllPoints()

        local minVal = ruleInfo.min or 1
        local maxVal = ruleInfo.max or 100
        local step = ruleInfo.step or 1
        local format = ruleInfo.format or ""

        -- Current value display
        local valueText = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        valueText:SetPoint("LEFT", container, "LEFT", 6, 0)
        valueText:SetWidth(50)
        valueText:SetJustifyH("LEFT")

        local function UpdateValueText(val)
            if format == "min" then
                valueText:SetText(tostring(val) .. " min")
            elseif format == "%" then
                valueText:SetText(tostring(val) .. "%")
            elseif format == "px" then
                valueText:SetText(tostring(val) .. "px")
            else
                valueText:SetText(tostring(val))
            end
        end

        -- Slider. Needs a NAME: pre-Cata OptionsSliderTemplate exposes its label
        -- font strings only as $parent-named globals, never as .Text/.Low/.High.
        editorSliderCounter = editorSliderCounter + 1
        local sliderName = "GudaBagsCategoryRuleSlider" .. editorSliderCounter
        local slider = CreateFrame("Slider", sliderName, container, "OptionsSliderTemplate")
        slider:SetPoint("LEFT", valueText, "RIGHT", 8, 0)
        slider:SetWidth(100)
        slider:SetHeight(17)
        slider:SetMinMaxValues(minVal, maxVal)
        slider:SetValueStep(step)
        -- Cataclysm 4.0; guarded at the call site (see UI\Controls\Slider.lua).
        if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end

        -- Add slider track background (may not be visible by default in Classic)
        local bg = slider:CreateTexture(nil, "BACKGROUND")
        bg:SetPoint("TOPLEFT", slider, "TOPLEFT", 0, -5)
        bg:SetPoint("BOTTOMRIGHT", slider, "BOTTOMRIGHT", 0, 5)
        bg:SetColorTexture(0.3, 0.3, 0.3, 0.8)

        -- Add track line
        local track = slider:CreateTexture(nil, "ARTWORK")
        track:SetHeight(2)
        track:SetPoint("LEFT", slider, "LEFT", 5, 0)
        track:SetPoint("RIGHT", slider, "RIGHT", -5, 0)
        track:SetColorTexture(0.5, 0.5, 0.5, 1)

        -- Hide default slider text (alias whichever access path this client has)
        slider.Text = slider.Text or _G[sliderName .. "Text"]
        slider.Low  = slider.Low  or _G[sliderName .. "Low"]
        slider.High = slider.High or _G[sliderName .. "High"]
        if slider.Low then slider.Low:SetText("") end
        if slider.High then slider.High:SetText("") end
        if slider.Text then slider.Text:SetText("") end

        local currentVal = ruleValue or minVal
        slider:SetValue(currentVal)
        UpdateValueText(currentVal)

        slider:SetScript("OnValueChanged", function(self, val)
            val = math.floor(val / step + 0.5) * step  -- Round to step
            currentRules[row.index].value = val
            UpdateValueText(val)
        end)

        row.valueControl = container
    end
end

-------------------------------------------------
-- Theme Support
-------------------------------------------------

local function ApplyEditorTheme()
    if not frame then return end
    Theme:ApplyPopupTheme(frame)
end

-------------------------------------------------
-- Main Frame (Modern Blizzard UI)
-------------------------------------------------

local function CreateEditorFrame()
    -- Use ButtonFrameTemplate for standard Blizzard look (same as SettingsPopup)
    local f = CreateFrame("Frame", "GudaBagsCategoryEditor", UIParent, "ButtonFrameTemplate")
    f:SetSize(EDITOR_WIDTH, EDITOR_HEIGHT)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetFrameLevel(250)
    f:EnableMouse(true)

    -- Hide portrait and button bar for clean look
    ButtonFrameTemplate_HidePortrait(f)
    ButtonFrameTemplate_HideButtonBar(f)
    if f.Inset then
        f.Inset:Hide()
    end

    -- Set title (will be updated when opening)
    if f.SetTitle then f:SetTitle(ns.L["EDIT_CATEGORY"]) end

    -- Make draggable via title bar
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self)
        self:StartMoving()
        self:SetUserPlaced(false)
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        self:SetUserPlaced(false)
    end)

    -- Content area starts below title
    local contentTop = -30
    local yOffset = contentTop

    -- Category Name
    local nameLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameLabel:SetPoint("TOPLEFT", f, "TOPLEFT", PADDING, yOffset)
    nameLabel:SetText(ns.L["CATEGORY_NAME"])
    nameLabel:SetTextColor(0.8, 0.8, 0.8)

    -- Built-in indicator (after label)
    local builtInText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    builtInText:SetPoint("LEFT", nameLabel, "RIGHT", 4, 0)
    builtInText:SetText(ns.L["BUILTIN"])
    builtInText:SetTextColor(0.5, 0.5, 0.5)
    f.builtInText = builtInText

    local nameBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    nameBox:SetSize(180, 20)
    nameBox:SetPoint("TOPLEFT", nameLabel, "BOTTOMLEFT", 4, -4)
    nameBox:SetAutoFocus(false)
    nameBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    nameBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    f.nameBox = nameBox

    -- Group field
    local groupLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    groupLabel:SetPoint("TOPLEFT", f, "TOPLEFT", PADDING + 220, yOffset)
    groupLabel:SetText(ns.L["GROUP_OPTIONAL"])
    groupLabel:SetTextColor(0.8, 0.8, 0.8)

    local groupBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    groupBox:SetSize(150, 20)
    groupBox:SetPoint("TOPLEFT", groupLabel, "BOTTOMLEFT", 4, -4)
    groupBox:SetAutoFocus(false)
    groupBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    groupBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    groupBox:SetScript("OnTextChanged", function(self)
        currentGroup = self:GetText()
    end)
    f.groupBox = groupBox

    yOffset = yOffset - 50

    -- Mark icon selector
    local markLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    markLabel:SetPoint("TOPLEFT", f, "TOPLEFT", PADDING, yOffset)
    markLabel:SetText(ns.L["CATEGORY_MARK"] or "Mark")
    markLabel:SetTextColor(0.8, 0.8, 0.8)
    f.markLabel = markLabel

    local markButtons = {}
    local MARK_BTN_SIZE = 22
    local MARK_BTN_SPACING = 6

    -- "None" button (clears mark)
    local noneBtn = CreateFrame("Button", nil, f, "BackdropTemplate")
    noneBtn:SetSize(MARK_BTN_SIZE, MARK_BTN_SIZE)
    noneBtn:SetPoint("TOPLEFT", markLabel, "BOTTOMLEFT", 0, -4)
    noneBtn:SetBackdrop({ bgFile = Constants.TEXTURES.WHITE_8x8, edgeFile = Constants.TEXTURES.WHITE_8x8, edgeSize = 1 })
    noneBtn:SetBackdropColor(0.15, 0.15, 0.15, 0.8)
    noneBtn:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    local noneX = noneBtn:CreateTexture(nil, "ARTWORK")
    noneX:SetSize(12, 12)
    noneX:SetPoint("CENTER")
    noneX:SetTexture("Interface\\Buttons\\UI-StopButton")
    noneX:SetVertexColor(0.6, 0.6, 0.6)
    noneBtn.markPath = nil
    noneBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(ns.L["CATEGORY_NO_MARK"] or "No mark")
        GameTooltip:Show()
    end)
    noneBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    noneBtn:SetScript("OnClick", function()
        currentMark = nil
        for _, btn in ipairs(markButtons) do
            btn:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
        end
        noneBtn:SetBackdropBorderColor(1, 0.82, 0, 1)
    end)
    table.insert(markButtons, noneBtn)

    -- Icon buttons
    for i, iconPath in ipairs(MARK_ICONS) do
        local btn = CreateFrame("Button", nil, f, "BackdropTemplate")
        btn:SetSize(MARK_BTN_SIZE, MARK_BTN_SIZE)
        btn:SetPoint("LEFT", markButtons[i], "RIGHT", MARK_BTN_SPACING, 0)
        btn:SetBackdrop({ bgFile = Constants.TEXTURES.WHITE_8x8, edgeFile = Constants.TEXTURES.WHITE_8x8, edgeSize = 1 })
        btn:SetBackdropColor(0.15, 0.15, 0.15, 0.8)
        btn:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
        local tex = btn:CreateTexture(nil, "ARTWORK")
        tex:SetSize(16, 16)
        tex:SetPoint("CENTER")
        tex:SetTexture(iconPath)
        btn.markPath = iconPath
        btn:SetScript("OnClick", function()
            currentMark = iconPath
            for _, b in ipairs(markButtons) do
                b:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
            end
            btn:SetBackdropBorderColor(1, 0.82, 0, 1)
        end)
        table.insert(markButtons, btn)
    end
    f.markButtons = markButtons

    yOffset = yOffset - 40

    -- Equipment set description (shown only for equipment set categories)
    local equipSetDesc = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    equipSetDesc:SetPoint("TOPLEFT", f, "TOPLEFT", PADDING, yOffset)
    equipSetDesc:SetPoint("RIGHT", f, "RIGHT", -PADDING, 0)
    equipSetDesc:SetJustifyH("LEFT")
    equipSetDesc:SetText(ns.L["EQUIP_SET_DESC"] or "")
    equipSetDesc:SetTextColor(1, 1, 1)
    equipSetDesc:SetWordWrap(true)
    equipSetDesc:SetSpacing(4)
    equipSetDesc:Hide()
    f.equipSetDesc = equipSetDesc

    -- Match Mode
    local matchLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    matchLabel:SetPoint("TOPLEFT", f, "TOPLEFT", PADDING, yOffset)
    matchLabel:SetText(ns.L["MATCH_MODE"])
    matchLabel:SetTextColor(0.8, 0.8, 0.8)
    f.matchLabel = matchLabel

    local matchAnyBtn = CreateFrame("CheckButton", nil, f, "UIRadioButtonTemplate")
    matchAnyBtn:SetPoint("TOPLEFT", matchLabel, "BOTTOMLEFT", 0, -4)
    matchAnyBtn:SetSize(20, 20)
    local matchAnyLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    matchAnyLabel:SetPoint("LEFT", matchAnyBtn, "RIGHT", 2, 0)
    matchAnyLabel:SetText(ns.L["MATCH_ANY"])
    matchAnyLabel:SetTextColor(1, 1, 1)
    f.matchAnyBtn = matchAnyBtn
    f.matchAnyLabel = matchAnyLabel

    local matchAllBtn = CreateFrame("CheckButton", nil, f, "UIRadioButtonTemplate")
    matchAllBtn:SetPoint("LEFT", matchAnyLabel, "RIGHT", 20, 0)
    matchAllBtn:SetSize(20, 20)
    local matchAllLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    matchAllLabel:SetPoint("LEFT", matchAllBtn, "RIGHT", 2, 0)
    matchAllLabel:SetText(ns.L["MATCH_ALL"])
    matchAllLabel:SetTextColor(1, 1, 1)
    f.matchAllBtn = matchAllBtn
    f.matchAllLabel = matchAllLabel

    matchAnyBtn:SetScript("OnClick", function()
        matchAnyBtn:SetChecked(true)
        matchAllBtn:SetChecked(false)
        currentMatchMode = "any"
        UpdateRequiredCheckboxes()
    end)

    matchAllBtn:SetScript("OnClick", function()
        matchAnyBtn:SetChecked(false)
        matchAllBtn:SetChecked(true)
        currentMatchMode = "all"
        UpdateRequiredCheckboxes()
    end)

    yOffset = yOffset - 50

    -- Rules header
    local rulesHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rulesHeader:SetPoint("TOPLEFT", f, "TOPLEFT", PADDING, yOffset)
    rulesHeader:SetText(ns.L["RULES"])
    rulesHeader:SetTextColor(0.8, 0.8, 0.8)
    f.rulesHeader = rulesHeader

    -- Add Rule button (wider for some locales)
    local locale = GetLocale()
    local addRuleBtnWidth = (locale == "ruRU" or locale == "frFR" or locale == "deDE" or locale == "itIT") and 130 or 80
    local addRuleBtn = CreateSmallButton(f, ns.L["ADD_RULE"], addRuleBtnWidth, function()
        CategoryEditor:AddRule()
    end)
    addRuleBtn:SetPoint("LEFT", rulesHeader, "RIGHT", 20, 0)
    f.addRuleBtn = addRuleBtn

    yOffset = yOffset - 20

    -- Rules scroll frame. NAMED: pre-Cata the scroll bar is only reachable as the
    -- global $parentScrollBar, so an anonymous frame has no way to find it.
    local scrollFrame = CreateFrame("ScrollFrame", "GudaBagsCategoryEditorRulesScroll", f,
                                    "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", PADDING, yOffset)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PADDING - 24, 60)

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(EDITOR_WIDTH - PADDING * 2 - 24, 1)
    scrollFrame:SetScrollChild(scrollChild)
    f.scrollChild = scrollChild
    f.scrollFrame = scrollFrame

    -- Bottom buttons
    local saveBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    saveBtn:SetSize(100, 26)
    saveBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PADDING - 110, PADDING + 8)
    saveBtn:SetText(ns.L["SAVE"])
    saveBtn:SetScript("OnClick", function()
        CategoryEditor:Save()
    end)

    local cancelBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    cancelBtn:SetSize(100, 26)
    cancelBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PADDING, PADDING + 8)
    cancelBtn:SetText(ns.L["CANCEL"])
    cancelBtn:SetScript("OnClick", function()
        f:Hide()
    end)

    -- Listen for theme changes
    Events:Register("SETTING_CHANGED", function(event, key)
        if key == "theme" then
            ApplyEditorTheme()
        end
    end, f)

    Events:Register("PROFILE_LOADED", function()
        ApplyEditorTheme()
    end, f)

    f:Hide()
    return f
end

-------------------------------------------------
-- Public API
-------------------------------------------------

function CategoryEditor:Open(categoryId)
    -- Always refresh RULE_TYPES to ensure we have the latest
    local CategoryManager = ns:GetModule("CategoryManager")
    if CategoryManager then
        RULE_TYPES = CategoryManager:GetRuleTypes()
    end

    if not RULE_TYPES or #RULE_TYPES == 0 then
        ns:Print(ns.L["ERROR_RULE_TYPES"])
        return
    end

    if not frame then
        frame = CreateEditorFrame()
    end

    isCreatingNew = false
    currentCategoryId = categoryId
    local CategoryManager = ns:GetModule("CategoryManager")
    local categoryDef = CategoryManager:GetCategory(categoryId)

    if not categoryDef then
        ns:Print(string.format(ns.L["CATEGORY_NOT_FOUND"], categoryId))
        return
    end

    -- Copy rules
    currentRules = {}
    if categoryDef.rules then
        for i, rule in ipairs(categoryDef.rules) do
            currentRules[i] = { type = rule.type, value = rule.value, required = rule.required and true or nil }
        end
    end

    currentMatchMode = categoryDef.matchMode or "any"
    currentGroup = categoryDef.group or ""
    currentMark = categoryDef.categoryMark or nil

    -- Update mark icon selection
    if frame.markButtons then
        for _, btn in ipairs(frame.markButtons) do
            if btn.markPath == currentMark then
                btn:SetBackdropBorderColor(1, 0.82, 0, 1)
            else
                btn:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
            end
        end
    end

    -- Update UI (use localized name for built-in categories)
    local displayName = categoryDef.isBuiltIn
        and ns.DefaultCategories:GetLocalizedName(categoryId, categoryDef.name)
        or (categoryDef.name or categoryId)
    if frame.SetTitle then frame:SetTitle(string.format(ns.L["EDIT_CATEGORY_NAME"], displayName)) end
    frame.nameBox:SetText(displayName)
    if frame.nameBox.SetEnabled then frame.nameBox:SetEnabled(not categoryDef.isBuiltIn) end
    -- Display localized group name
    local localizedGroup = ns.DefaultCategories:GetLocalizedGroupName(currentGroup)
    frame.groupBox:SetText(localizedGroup)

    if categoryDef.isBuiltIn then
        frame.builtInText:Show()
        frame.nameBox:SetTextColor(0.5, 0.5, 0.5)
    else
        frame.builtInText:Hide()
        frame.nameBox:SetTextColor(1, 1, 1)
    end

    if currentMatchMode == "all" then
        frame.matchAllBtn:SetChecked(true)
        frame.matchAnyBtn:SetChecked(false)
    else
        frame.matchAnyBtn:SetChecked(true)
        frame.matchAllBtn:SetChecked(false)
    end

    -- Equipment set categories: hide rules section, disable name, show mark + description
    if categoryDef.isEquipSet then
        if frame.nameBox.SetEnabled then frame.nameBox:SetEnabled(false) end
        frame.nameBox:SetTextColor(0.5, 0.5, 0.5)
        frame.markLabel:Show()
        for _, btn in ipairs(frame.markButtons) do btn:Show() end
        frame.equipSetDesc:Show()
        frame.matchLabel:Hide()
        frame.matchAnyBtn:Hide()
        frame.matchAnyLabel:Hide()
        frame.matchAllBtn:Hide()
        frame.matchAllLabel:Hide()
        frame.rulesHeader:Hide()
        frame.addRuleBtn:Hide()
        frame.scrollFrame:Hide()
    else
        frame.markLabel:Show()
        for _, btn in ipairs(frame.markButtons) do btn:Show() end
        frame.equipSetDesc:Hide()
        frame.matchLabel:Show()
        frame.matchAnyBtn:Show()
        frame.matchAnyLabel:Show()
        frame.matchAllBtn:Show()
        frame.matchAllLabel:Show()
        frame.rulesHeader:Show()
        frame.addRuleBtn:Show()
        frame.scrollFrame:Show()
    end

    self:RefreshRules()
    ApplyEditorTheme()
    frame:Show()
end

function CategoryEditor:RefreshRules()
    local scrollChild = frame.scrollChild

    -- Clear existing rows
    for _, row in ipairs(ruleRows) do
        row:Hide()
        row:SetParent(nil)
    end
    ruleRows = {}

    local yOffset = 0
    for i, rule in ipairs(currentRules) do
        local row = CreateRuleRow(scrollChild, i)
        row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, yOffset)
        row:SetPoint("RIGHT", scrollChild, "RIGHT", 0, 0)

        UpdateRuleRowValue(row, rule.type, rule.value)
        row:Show()
        table.insert(ruleRows, row)

        yOffset = yOffset - ROW_HEIGHT - 4
    end

    scrollChild:SetHeight(math.abs(yOffset) + 10)

    -- Sync required-rule checkboxes to current state and matchMode
    UpdateRequiredCheckboxes()
end

function CategoryEditor:AddRule()
    table.insert(currentRules, { type = "itemType", value = "Consumable" })
    self:RefreshRules()
end

function CategoryEditor:RemoveRule(index)
    table.remove(currentRules, index)
    self:RefreshRules()
end

function CategoryEditor:Save()
    local CategoryManager = ns:GetModule("CategoryManager")
    local categoryName = frame.nameBox:GetText()

    if not categoryName or categoryName == "" then
        categoryName = "New Category"
    end

    local groupText = frame.groupBox:GetText()
    -- Convert localized group name back to English for storage
    -- Use "" for intentionally ungrouped (nil means "never had a group" for migration)
    local group = ""
    if groupText and groupText ~= "" then
        group = ns.DefaultCategories:GetGroupIdFromLocalized(groupText)
    end

    if isCreatingNew then
        -- Create new category
        local newId = CategoryManager:AddCategory(categoryName)
        local categoryDef = CategoryManager:GetCategory(newId)

        if categoryDef then
            categoryDef.group = group
            categoryDef.matchMode = currentMatchMode
            categoryDef.categoryMark = currentMark
            categoryDef.rules = {}
            for i, rule in ipairs(currentRules) do
                categoryDef.rules[i] = { type = rule.type, value = rule.value, required = rule.required and true or nil }
            end
            CategoryManager:UpdateCategory(newId, categoryDef)
        end

        frame:Hide()
        isCreatingNew = false
        ns:Print(string.format(ns.L["CATEGORY_CREATED"], categoryName))
    else
        -- Update existing category
        local categoryDef = CategoryManager:GetCategory(currentCategoryId)
        if not categoryDef then return end

        -- Update name if not built-in
        if not categoryDef.isBuiltIn then
            categoryDef.name = categoryName
        end

        categoryDef.group = group
        categoryDef.matchMode = currentMatchMode
        categoryDef.categoryMark = currentMark
        categoryDef.rules = {}
        for i, rule in ipairs(currentRules) do
            categoryDef.rules[i] = { type = rule.type, value = rule.value, required = rule.required and true or nil }
        end

        CategoryManager:UpdateCategory(currentCategoryId, categoryDef)

        frame:Hide()
        ns:Print(string.format(ns.L["CATEGORY_SAVED"], categoryDef.name))
    end
end

function CategoryEditor:Hide()
    if frame then
        frame:Hide()
    end
end

function CategoryEditor:IsShown()
    return frame and frame:IsShown()
end

function CategoryEditor:CreateNew()
    -- Always refresh RULE_TYPES to ensure we have the latest
    local CategoryManager = ns:GetModule("CategoryManager")
    if CategoryManager then
        RULE_TYPES = CategoryManager:GetRuleTypes()
    end

    if not RULE_TYPES or #RULE_TYPES == 0 then
        ns:Print(ns.L["ERROR_RULE_TYPES"])
        return
    end

    if not frame then
        frame = CreateEditorFrame()
    end

    isCreatingNew = true
    currentCategoryId = nil
    currentRules = {}
    currentMatchMode = "any"
    currentGroup = ""
    currentMark = nil

    -- Update UI for new category
    if frame.SetTitle then frame:SetTitle(ns.L["CREATE_NEW_CATEGORY"]) end
    frame.nameBox:SetText("")
    if frame.nameBox.SetEnabled then frame.nameBox:SetEnabled(true) end
    frame.nameBox:SetTextColor(1, 1, 1)
    frame.groupBox:SetText("")
    frame.builtInText:Hide()

    -- Reset mark selection (select "none")
    if frame.markButtons then
        for _, btn in ipairs(frame.markButtons) do
            if btn.markPath == nil then
                btn:SetBackdropBorderColor(1, 0.82, 0, 1)
            else
                btn:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
            end
        end
    end

    -- Show all sections for new categories
    frame.markLabel:Show()
    for _, btn in ipairs(frame.markButtons) do btn:Show() end
    frame.equipSetDesc:Hide()
    frame.matchLabel:Show()
    frame.matchAnyBtn:Show()
    frame.matchAnyLabel:Show()
    frame.matchAllBtn:Show()
    frame.matchAllLabel:Show()
    frame.rulesHeader:Show()
    frame.addRuleBtn:Show()
    frame.scrollFrame:Show()

    frame.matchAnyBtn:SetChecked(true)
    frame.matchAllBtn:SetChecked(false)

    self:RefreshRules()
    ApplyEditorTheme()
    frame:Show()
end
