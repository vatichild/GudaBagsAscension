local addonName, ns = ...

local ToggleButton = {}
ns:RegisterModule("Controls.ToggleButton", ToggleButton)

local Database = ns:GetModule("Database")
local Events = ns:GetModule("Events")

local DEFAULT_HEIGHT = 26

function ToggleButton:Create(parent, config)
    -- config = { key, label, options = {{value, label}, ...}, tooltip, width }
    local container = CreateFrame("Frame", nil, parent)
    container:SetHeight(DEFAULT_HEIGHT)
    if config.width then
        container:SetWidth(config.width)
    end

    local button = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    button:SetHeight(22)
    button:SetPoint("LEFT", container, "LEFT", 0, 0)
    button:SetPoint("RIGHT", container, "RIGHT", 0, 0)

    local currentValue = Database:GetSetting(config.key) or config.options[1].value

    local function UpdateButtonText()
        for _, opt in ipairs(config.options) do
            if opt.value == currentValue then
                button:SetText(config.label .. ": " .. opt.label)
                break
            end
        end
    end
    UpdateButtonText()

    button:SetScript("OnClick", function()
        local currentIndex = 1
        for i, opt in ipairs(config.options) do
            if opt.value == currentValue then
                currentIndex = i
                break
            end
        end
        currentIndex = currentIndex % #config.options + 1
        currentValue = config.options[currentIndex].value
        Database:SetSetting(config.key, currentValue)
        Events:Fire("SETTING_CHANGED", config.key, currentValue)
        UpdateButtonText()
    end)

    if config.tooltip then
        button:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(config.tooltip, 1, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    -- Public API
    container.GetValue = function() return currentValue end
    container.SetValue = function(self, v)
        currentValue = v
        UpdateButtonText()
    end
    container.GetSettingKey = function() return config.key end
    container.Refresh = function(self)
        currentValue = Database:GetSetting(config.key) or config.options[1].value
        UpdateButtonText()
    end

    return container
end

return ToggleButton
