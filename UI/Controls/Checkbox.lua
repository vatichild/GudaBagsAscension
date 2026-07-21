local addonName, ns = ...

local Checkbox = {}
ns:RegisterModule("Controls.Checkbox", Checkbox)

local Database = ns:GetModule("Database")
local Events = ns:GetModule("Events")

local DEFAULT_HEIGHT = 26

function Checkbox:Create(parent, config)
    -- config = { key, label, tooltip, width }
    local container = CreateFrame("Frame", nil, parent)
    container:SetHeight(DEFAULT_HEIGHT)

    -- Use modern SettingsCheckboxTemplate (check both capitalizations)
    local checkbox
    if DoesTemplateExist and DoesTemplateExist("SettingsCheckBoxTemplate") then
        checkbox = CreateFrame("CheckButton", nil, container, "SettingsCheckBoxTemplate")
    elseif DoesTemplateExist and DoesTemplateExist("SettingsCheckboxTemplate") then
        checkbox = CreateFrame("CheckButton", nil, container, "SettingsCheckboxTemplate")
    else
        -- Fallback for older versions
        checkbox = CreateFrame("CheckButton", nil, container, "InterfaceOptionsCheckButtonTemplate")
    end

    -- Position checkbox on the left
    checkbox:SetPoint("LEFT", container, "LEFT", 0, 0)

    -- Clear any existing text from template
    checkbox:SetText("")

    -- Create separate label to the right of checkbox
    local label = container:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("LEFT", checkbox, "RIGHT", 4, 0)
    label:SetText(config.label)

    local currentValue = Database:GetSetting(config.key)
    checkbox:SetChecked(currentValue)

    checkbox:SetScript("OnClick", function(self)
        -- Coerce to a real boolean: pre-Cata GetChecked returns 1 or NIL, and
        -- SetSetting assigns straight into the settings table -- so a nil would
        -- DELETE the key and silently revert the setting to its default.
        local checked = self:GetChecked() and true or false
        Database:SetSetting(config.key, checked)
        Events:Fire("SETTING_CHANGED", config.key, checked)
    end)

    -- Make the whole row clickable
    container:EnableMouse(true)
    container:SetScript("OnMouseUp", function()
        checkbox:Click()
    end)

    if config.tooltip then
        checkbox:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(config.tooltip, 1, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        checkbox:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    -- Public API
    container.GetValue = function() return checkbox:GetChecked() and true or false end
    container.SetValue = function(self, v) checkbox:SetChecked(v) end
    container.GetSettingKey = function() return config.key end
    container.Refresh = function(self)
        local v = Database:GetSetting(config.key)
        checkbox:SetChecked(v)
    end

    return container
end

return Checkbox
