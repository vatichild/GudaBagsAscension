local addonName, ns = ...

local Select = {}
ns:RegisterModule("Controls.Select", Select)

local Database = ns:GetModule("Database")
local Events = ns:GetModule("Events")

local DEFAULT_HEIGHT = 26

function Select:Create(parent, config)
    -- config = { key, label, options = {{value, label}, ...}, tooltip, width }
    local container = CreateFrame("Frame", nil, parent)
    container:SetHeight(DEFAULT_HEIGHT)

    -- Label on the left, right-aligned to center
    local label = container:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("LEFT", container, "LEFT", 0, 0)
    label:SetPoint("RIGHT", container, "CENTER", -60, 0)
    label:SetJustifyH("RIGHT")
    label:SetText(config.label)

    -- Build entries and values arrays
    local entries = {}
    local values = {}
    for _, opt in ipairs(config.options) do
        table.insert(entries, opt.label)
        table.insert(values, opt.value)
    end

    local currentValue = Database:GetSetting(config.key)

    -- Try to use WowStyle1DropdownTemplate if available
    local dropdown
    local useModernDropdown = DoesTemplateExist and DoesTemplateExist("WowStyle1DropdownTemplate")

    if useModernDropdown then
        dropdown = CreateFrame("DropdownButton", nil, container, "WowStyle1DropdownTemplate")
        dropdown:SetPoint("LEFT", container, "CENTER", -50, 0)
        dropdown:SetPoint("RIGHT", container, "RIGHT", -10, 0)

        -- Build menu entries for MenuUtil
        local menuEntries = {}
        for i = 1, #entries do
            table.insert(menuEntries, {entries[i], values[i]})
        end

        -- Use MenuUtil.CreateRadioMenu for radio-style selection
        MenuUtil.CreateRadioMenu(dropdown, function(value)
            return Database:GetSetting(config.key) == value
        end, function(value)
            Database:SetSetting(config.key, value)
            Events:Fire("SETTING_CHANGED", config.key, value)
        end, unpack(menuEntries))

        -- Public API for modern dropdown
        container.GetValue = function()
            return Database:GetSetting(config.key)
        end
        container.SetValue = function(self, v)
            dropdown:GenerateMenu()
        end
        container.Refresh = function(self)
            dropdown:GenerateMenu()
        end
    else
        -- Custom themed dropdown.
        --
        -- We deliberately do NOT use UIDropDownMenuTemplate here. On a 3.3.5a
        -- client its chrome renders wrong -- the Left/Middle/Right textures draw
        -- at full height as smeared bands and the arrow button detaches far to
        -- the right -- and none of that is fixable from the outside, because the
        -- geometry lives in the template's own XML. Its heavy grey/gold styling
        -- also clashes with the dark Guda theme regardless.
        --
        -- This is the same construction UI\CharacterDropdown.lua already uses
        -- successfully on this client: a backdrop button plus a row list.
        local SPAN_LEFT, SPAN_RIGHT = 50, 55
        local ROW_HEIGHT = 18

        dropdown = CreateFrame("Button", nil, container, "BackdropTemplate")
        dropdown:SetPoint("LEFT", container, "CENTER", -SPAN_LEFT, 0)
        dropdown:SetPoint("RIGHT", container, "RIGHT", -SPAN_RIGHT, 0)
        dropdown:SetHeight(20)
        dropdown:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        dropdown:SetBackdropColor(0.15, 0.15, 0.15, 1)
        dropdown:SetBackdropBorderColor(0.35, 0.35, 0.35, 1)

        local ddText = dropdown:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        ddText:SetPoint("LEFT", dropdown, "LEFT", 6, 0)
        ddText:SetPoint("RIGHT", dropdown, "RIGHT", -18, 0)
        ddText:SetJustifyH("LEFT")

        local arrow = dropdown:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        arrow:SetPoint("RIGHT", dropdown, "RIGHT", -6, 0)
        arrow:SetText("v")
        arrow:SetTextColor(0.7, 0.7, 0.7)

        dropdown:SetScript("OnEnter", function(self)
            self:SetBackdropBorderColor(0.9, 0.75, 0.3, 1)
        end)
        dropdown:SetScript("OnLeave", function(self)
            self:SetBackdropBorderColor(0.35, 0.35, 0.35, 1)
        end)

        -- The open list. Parented to UIParent so it is never clipped by the
        -- settings scroll area, and kept above it.
        local list = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        list:SetFrameStrata("FULLSCREEN_DIALOG")
        list:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        list:SetBackdropColor(0.10, 0.10, 0.10, 0.98)
        list:SetBackdropBorderColor(0.35, 0.35, 0.35, 1)
        list:Hide()
        dropdown.list = list

        local rows = {}

        local function SetDisplay(value)
            for _, opt in ipairs(config.options) do
                if opt.value == value then ddText:SetText(opt.label) return end
            end
            ddText:SetText(tostring(value or ""))
        end

        local function BuildRows()
            local current = Database:GetSetting(config.key)
            for i, opt in ipairs(config.options) do
                local row = rows[i]
                if not row then
                    row = CreateFrame("Button", nil, list)
                    row:SetHeight(ROW_HEIGHT)
                    row:SetPoint("LEFT", list, "LEFT", 1, 0)
                    row:SetPoint("RIGHT", list, "RIGHT", -1, 0)
                    local hl = row:CreateTexture(nil, "HIGHLIGHT")
                    hl:SetAllPoints()
                    hl:SetTexture("Interface\\Buttons\\WHITE8x8")
                    hl:SetVertexColor(1, 1, 1, 0.12)
                    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                    row.text:SetPoint("LEFT", row, "LEFT", 6, 0)
                    row.text:SetJustifyH("LEFT")
                    rows[i] = row
                end
                row:SetPoint("TOP", list, "TOP", 0, -((i - 1) * ROW_HEIGHT) - 1)
                row.text:SetText(opt.label)
                if opt.value == current then
                    row.text:SetTextColor(1, 0.82, 0)
                else
                    row.text:SetTextColor(0.9, 0.9, 0.9)
                end
                row:SetScript("OnClick", function()
                    Database:SetSetting(config.key, opt.value)
                    Events:Fire("SETTING_CHANGED", config.key, opt.value)
                    SetDisplay(opt.value)
                    list:Hide()
                end)
                row:Show()
            end
            for i = #config.options + 1, #rows do rows[i]:Hide() end
        end

        dropdown:SetScript("OnClick", function(self)
            if list:IsShown() then list:Hide() return end
            BuildRows()
            list:ClearAllPoints()
            list:SetPoint("TOPLEFT", self, "BOTTOMLEFT", 0, -2)
            list:SetWidth(self:GetWidth())
            list:SetHeight(#config.options * ROW_HEIGHT + 2)
            list:Show()
        end)

        -- Close when clicking elsewhere. GLOBAL_MOUSE_DOWN is Legion+, so fall
        -- back to hiding whenever the settings popup or this control goes away.
        list:SetScript("OnShow", function(self)
            pcall(self.RegisterEvent, self, "GLOBAL_MOUSE_DOWN")
        end)
        list:SetScript("OnHide", function(self)
            pcall(self.UnregisterEvent, self, "GLOBAL_MOUSE_DOWN")
        end)
        list:SetScript("OnEvent", function(self)
            if not self:IsMouseOver() and not dropdown:IsMouseOver() then self:Hide() end
        end)
        container:SetScript("OnHide", function() list:Hide() end)

        SetDisplay(currentValue)

        -- Public API for the themed dropdown
        container.GetValue = function()
            return Database:GetSetting(config.key)
        end
        container.SetValue = function(self, v)
            SetDisplay(v)
        end
        container.Refresh = function(self)
            SetDisplay(Database:GetSetting(config.key))
        end
        container.CloseDropdown = function()
            list:Hide()
        end
        container.GetSettingKey = function()
            return config.key
        end

        return container
    end

    -- Modern (Dragonflight+) path returns here; the themed path above has
    -- already returned with its own API attached.
    container.GetSettingKey = function()
        return config.key
    end
    container.CloseDropdown = function()
        if CloseDropDownMenus then CloseDropDownMenus() end
    end

    return container
end

-- Global function to close any open dropdown
function Select:CloseAll()
    if CloseDropDownMenus then CloseDropDownMenus() end
end

return Select
