local addonName, ns = ...

-- Shared title-bar controls for the Bag and Bank headers:
--   1. Layout cycle button — rotates the per-frame view setting through
--      Constants.VIEW_TYPES (single → category → split).
--   2. Recent toggle button — enables/disables the built-in Recent category;
--      visually desaturates when disabled.
--
-- Header.lua and BankHeader.lua use this module so the only difference between
-- their title bars is the per-frame view-setting key (bagViewType vs bankViewType).

local HeaderViewControls = {}
ns:RegisterModule("HeaderViewControls", HeaderViewControls)

local Constants = ns.Constants
local L = ns.L

local Database = ns:GetModule("Database")
local Events = ns:GetModule("Events")
local IconButton = ns:GetModule("IconButton")
local HeaderButtonVisibility = ns:GetModule("HeaderButtonVisibility")

local function nextViewType(current)
    local order = Constants.VIEW_TYPES
    for i, v in ipairs(order) do
        if v == current then return order[(i % #order) + 1] end
    end
    return order[1]
end

local function applyRecentVisualState(btn)
    if not btn then return end
    local CategoryManager = ns:GetModule("CategoryManager")
    if not CategoryManager then return end
    local def = CategoryManager:GetCategory("Recent")
    local enabled = def and def.enabled
    local tex = btn:GetNormalTexture()
    if tex then
        tex:SetDesaturated(not enabled)
        tex:SetAlpha(enabled and 1.0 or 0.5)
    end
end

--- Create the layout-cycle and Recent-toggle buttons and chain them to the
--- right of `opts.anchorButton`. Returns both buttons; caller is expected to
--- store them on the title bar and update its `lastRightButton` chain.
---
--- @param parent Frame Title bar to parent the buttons to.
--- @param opts table { viewSettingKey, ownerPrefix, anchorButton }
---     viewSettingKey: "bagViewType" or "bankViewType"
---     ownerPrefix:    string used as prefix for Events:Register owner keys
---     anchorButton:   the button to anchor the cycle button's right edge to
--- @return Button viewCycleButton
--- @return Button recentToggleButton
function HeaderViewControls:Attach(parent, opts)
    local viewKey = opts.viewSettingKey
    local ownerPrefix = opts.ownerPrefix
    local anchor = opts.anchorButton

    -- Layout cycle button. Theme:StyleButton resizes the button frame; the
    -- inner texture is re-anchored to a smaller centered region for visual
    -- balance against the other (heavier) header glyphs.
    local viewCycleButton = IconButton:Create(parent, "viewCycle", {
        tooltip = L["TOOLTIP_VIEW_CYCLE"],
        onClick = function()
            local current = Database:GetSetting(viewKey) or "single"
            local nextType = nextViewType(current)
            Database:SetSetting(viewKey, nextType)
            Events:Fire("SETTING_CHANGED", viewKey, nextType)
        end,
    })
    do
        local tex = viewCycleButton:GetNormalTexture()
        if tex then
            tex:ClearAllPoints()
            tex:SetPoint("CENTER")
            tex:SetSize(13, 13)
        end
    end
    viewCycleButton:SetPoint("RIGHT", anchor, "LEFT", -4, 0)
    HeaderButtonVisibility:SetKey(viewCycleButton, "showHeaderViewCycle")
    HeaderButtonVisibility:ApplyState(viewCycleButton)

    -- Recent toggle button.
    local recentToggleButton = IconButton:Create(parent, "recent", {
        tooltip = L["TOOLTIP_RECENT_TOGGLE"],
        onClick = function()
            local CategoryManager = ns:GetModule("CategoryManager")
            if CategoryManager then
                CategoryManager:ToggleCategory("Recent")
            end
        end,
    })
    recentToggleButton:SetPoint("RIGHT", viewCycleButton, "LEFT", -4, 0)
    HeaderButtonVisibility:SetKey(recentToggleButton, "showHeaderRecentToggle")
    HeaderButtonVisibility:ApplyState(recentToggleButton)
    applyRecentVisualState(recentToggleButton)

    Events:Register("CATEGORIES_UPDATED", function()
        applyRecentVisualState(recentToggleButton)
    end, ownerPrefix .. ".RecentToggle")

    return viewCycleButton, recentToggleButton
end

--- Re-apply visibility for both buttons during a header relayout. Force-hides
--- the Recent toggle when the active view isn't "category" — Recent is a
--- category, so the button is meaningless in single/split views.
function HeaderViewControls:ApplyVisibility(viewCycleButton, recentToggleButton, viewSettingKey)
    HeaderButtonVisibility:ApplyState(viewCycleButton)
    HeaderButtonVisibility:ApplyState(recentToggleButton)
    if recentToggleButton and (Database:GetSetting(viewSettingKey) or "single") ~= "category" then
        recentToggleButton:Hide()
    end
end

--- Register a SETTING_CHANGED listener that re-runs `relayoutCallback` when
--- the view-type setting flips. Used so the Recent button can re-show when
--- the user cycles back into category view.
function HeaderViewControls:WatchViewType(viewSettingKey, ownerPrefix, relayoutCallback)
    Events:Register("SETTING_CHANGED", function(event, key)
        if key == viewSettingKey then
            C_Timer.After(0, relayoutCallback)
        end
    end, ownerPrefix .. ".ViewTypeWatch")
end

return HeaderViewControls
