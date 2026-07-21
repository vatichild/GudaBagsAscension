local addonName, ns = ...

local SearchToggleButton = {}
ns:RegisterModule("SearchToggleButton", SearchToggleButton)

local L = ns.L
local Database = ns:GetModule("Database")
local Events = ns:GetModule("Events")
local IconButton = ns:GetModule("IconButton")

-- Create a search-toggle IconButton on `parent`, anchored to the left of
-- `opts.anchorButton`. Clicking it calls `ns:GetModule(opts.targetModule):ToggleSearchBar()`.
-- Button visibility tracks the `showSearchBar` setting (hidden when always-on).
-- opts = {
--   targetModule = "BagFrame",   -- module that implements ToggleSearchBar
--   anchorButton = <Button>,      -- anchor for SetPoint("RIGHT", anchor, "LEFT", -4, 0)
--   tooltip      = string,        -- optional, defaults to L["TOOLTIP_TOGGLE_SEARCH"]
-- }
-- Button is visible only when:
--   - "Always Show Search Bar" (showSearchBar) is OFF (bar is on-demand), AND
--   - "Show Search Button" (showHeaderSearch) is ON.
local function ShouldShow()
    return not Database:GetSetting("showSearchBar")
        and Database:GetSetting("showHeaderSearch") ~= false
end

function SearchToggleButton:Create(parent, opts)
    local button = IconButton:Create(parent, "search", {
        tooltip = opts.tooltip or L["TOOLTIP_TOGGLE_SEARCH"],
        onClick = function()
            local mod = ns:GetModule(opts.targetModule)
            if mod and mod.ToggleSearchBar then
                mod:ToggleSearchBar()
            end
        end,
    })
    if opts.anchorButton then
        button:SetPoint("RIGHT", opts.anchorButton, "LEFT", -4, 0)
    end
    if not ShouldShow() then
        button:Hide()
    end

    -- Keep visibility in sync with either setting. Uses the button itself
    -- as the listener owner so each header gets its own callback.
    Events:Register("SETTING_CHANGED", function(event, key)
        if key == "showSearchBar" or key == "showHeaderSearch" then
            if ShouldShow() then
                button:Show()
            else
                button:Hide()
            end
        end
    end, button)

    return button
end
