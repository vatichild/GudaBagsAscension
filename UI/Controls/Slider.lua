local addonName, ns = ...

local Slider = {}
ns:RegisterModule("Controls.Slider", Slider)

local Database = ns:GetModule("Database")
local Events = ns:GetModule("Events")

local DEFAULT_HEIGHT = 26

-- Unique names for OptionsSliderTemplate instances; see the fallback branch in
-- Create() for why these sliders cannot be anonymous.
local sliderCounter = 0

function Slider:Create(parent, config)
    -- config = { key, label, min, max, step, format, width }
    local container = CreateFrame("Frame", nil, parent)
    container:SetHeight(DEFAULT_HEIGHT)

    -- Label on the left, right-aligned to center
    local label = container:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("LEFT", container, "LEFT", 0, 0)
    label:SetPoint("RIGHT", container, "CENTER", -60, 0)
    label:SetJustifyH("RIGHT")
    label:SetText(config.label)

    local function FormatValue(value)
        if config.format then
            if config.format == "%" then
                return value .. "%"
            elseif config.format == "px" then
                return value .. "px"
            elseif type(config.format) == "function" then
                return config.format(value)
            end
        end
        return tostring(value)
    end

    local currentValue = Database:GetSetting(config.key) or config.min

    -- Try to use MinimalSliderWithSteppersTemplate if available
    local slider
    local useModernSlider = DoesTemplateExist and DoesTemplateExist("MinimalSliderWithSteppersTemplate")

    if useModernSlider then
        slider = CreateFrame("Slider", nil, container, "MinimalSliderWithSteppersTemplate")
        slider:SetPoint("LEFT", container, "CENTER", -50, 0)
        slider:SetPoint("RIGHT", container, "RIGHT", -50, 0)
        slider:SetHeight(20)

        -- Initialize the modern slider
        local steps = config.max - config.min
        slider:Init(currentValue, config.min, config.max, steps, {
            [MinimalSliderWithSteppersMixin.Label.Right] = CreateMinimalSliderFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(value)
                return WHITE_FONT_COLOR:WrapTextInColorCode(FormatValue(value))
            end)
        })

        -- Debounce timer for expensive updates
        local debounceTimer = nil
        local DEBOUNCE_DELAY = 0.1

        slider:RegisterCallback("OnValueChanged", function(_, value)
            Database:SetSetting(config.key, value)  -- Save immediately for visual feedback

            if debounceTimer then
                debounceTimer:Cancel()
            end
            debounceTimer = C_Timer.NewTimer(DEBOUNCE_DELAY, function()
                Events:Fire("SETTING_CHANGED", config.key, value)
                debounceTimer = nil
            end)
        end)

        -- Public API for modern slider
        container.GetValue = function() return slider.Slider:GetValue() end
        container.SetValue = function(self, v)
            slider:SetValue(v)
        end
        container.Refresh = function(self)
            local v = Database:GetSetting(config.key) or config.min
            slider:SetValue(v)
        end
    else
        -- Fallback to OptionsSliderTemplate.
        -- The frame needs a NAME: pre-Cata this template exposes its label font
        -- strings only as $parent-named globals, not as .Text/.Low/.High members,
        -- so an anonymous slider leaves all three nil.
        sliderCounter = sliderCounter + 1
        local sliderName = "GudaBagsSettingsSlider" .. sliderCounter
        slider = CreateFrame("Slider", sliderName, container, "OptionsSliderTemplate")
        slider:SetPoint("LEFT", container, "CENTER", -50, 0)
        slider:SetPoint("RIGHT", container, "RIGHT", -55, 0)
        slider:SetMinMaxValues(config.min, config.max)
        slider:SetValueStep(config.step)
        -- SetObeyStepOnDrag is Cataclysm 4.0. Guarded at the call site rather
        -- than relying on a metatable polyfill: pre-Cata sliders already snap to
        -- SetValueStep while dragging, so skipping it changes nothing.
        if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end

        -- Alias whichever access path this client provides.
        slider.Text = slider.Text or _G[sliderName .. "Text"]
        slider.Low  = slider.Low  or _G[sliderName .. "Low"]
        slider.High = slider.High or _G[sliderName .. "High"]

        -- Hide template's text elements
        if slider.Text then slider.Text:SetText("") end
        if slider.Low then slider.Low:SetText("") end
        if slider.High then slider.High:SetText("") end

        slider:SetValue(currentValue)

        -- Value display on the right
        local valueText = container:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        valueText:SetPoint("LEFT", slider, "RIGHT", 5, 0)
        valueText:SetWidth(40)
        valueText:SetJustifyH("LEFT")
        valueText:SetText(FormatValue(currentValue))

        -- Debounce timer for expensive updates
        local debounceTimer = nil
        local DEBOUNCE_DELAY = 0.1

        slider:SetScript("OnValueChanged", function(self, value)
            value = math.floor(value / config.step + 0.5) * config.step
            valueText:SetText(FormatValue(value))
            Database:SetSetting(config.key, value)

            if debounceTimer then
                debounceTimer:Cancel()
            end
            debounceTimer = C_Timer.NewTimer(DEBOUNCE_DELAY, function()
                Events:Fire("SETTING_CHANGED", config.key, value)
                debounceTimer = nil
            end)
        end)

        -- Public API for classic slider
        container.GetValue = function() return slider:GetValue() end
        container.SetValue = function(self, v)
            slider:SetValue(v)
            valueText:SetText(FormatValue(v))
        end
        container.Refresh = function(self)
            local v = Database:GetSetting(config.key) or config.min
            slider:SetValue(v)
            valueText:SetText(FormatValue(v))
        end
    end

    container.GetSettingKey = function() return config.key end

    -- Mouse wheel support
    container:EnableMouseWheel(true)
    container:SetScript("OnMouseWheel", function(self, delta)
        local current = container.GetValue()
        local newValue = current + (delta * config.step)
        newValue = math.max(config.min, math.min(config.max, newValue))
        container:SetValue(newValue)
        Database:SetSetting(config.key, newValue)
        Events:Fire("SETTING_CHANGED", config.key, newValue)
    end)

    return container
end

return Slider
