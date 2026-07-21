local addonName, ns = ...

-- Declarative per-button visibility gating for frame headers.
--
-- Each hideable button is tagged at creation time with the settings key that
-- controls it (via SetKey). Filter() returns a new array containing only the
-- visible buttons, skipping nils and buttons whose setting is off. Watch()
-- registers a SETTING_CHANGED listener so each header re-applies layout when
-- any of its buttons' settings flip.
--
-- A single source of truth: no condition lists are duplicated between the
-- header's initial layout, theme re-apply, narrow-mode, and live settings.

local HeaderButtonVisibility = {}
ns:RegisterModule("HeaderButtonVisibility", HeaderButtonVisibility)

local Database = ns:GetModule("Database")
local Events = ns:GetModule("Events")

-- Private attribute name used to tag buttons. Avoids clashing with any
-- Blizzard or Masque field.
local KEY_ATTR = "_gbVisibilityKey"

-- Tag a button with the settings key that controls its visibility.
-- Pass nil to untag (button becomes always-visible).
function HeaderButtonVisibility:SetKey(button, settingKey)
    if not button then return end
    button[KEY_ATTR] = settingKey
end

-- Returns true if the button's controlling setting is enabled.
-- Ignores external Show/Hide state — used when the caller needs to know the
-- user's *intent* even if the button happens to be hidden for another reason
-- (e.g. narrow-mode hid nav buttons to make room for a hamburger menu; the
-- menu entries should still respect the user's visibility choice).
function HeaderButtonVisibility:IsSettingEnabled(button)
    if not button then return false end
    local key = button[KEY_ATTR]
    if not key then return true end
    return Database:GetSetting(key) ~= false
end

-- Returns true if the button should participate in layout right now.
-- Accounts for both (1) any external Show/Hide (e.g. SearchToggleButton's own
-- listener) and (2) the tagged setting for tagged buttons.
function HeaderButtonVisibility:IsVisible(button)
    if not button then return false end
    if button.IsShown and not button:IsShown() then
        return false
    end
    return self:IsSettingEnabled(button)
end

-- Build a new array containing only the visible entries of `list`.
-- Skips nils automatically. Preserves original order.
function HeaderButtonVisibility:Filter(list)
    local out = {}
    if not list then return out end
    for _, btn in ipairs(list) do
        if btn and self:IsVisible(btn) then
            out[#out + 1] = btn
        end
    end
    return out
end

-- Apply Show/Hide to a button based on its controlling setting. Uses
-- IsSettingEnabled (not IsVisible) so a currently-hidden button can be
-- revealed when the user flips its setting back on.
function HeaderButtonVisibility:ApplyState(button)
    if not button then return end
    if self:IsSettingEnabled(button) then
        button:Show()
    else
        button:Hide()
    end
end

-- Register `callback` to fire whenever any button-visibility setting changes.
-- Reacts to `showHeader*` keys AND `showSearchBar` (since the latter affects
-- the search button's effective visibility). The callback is deferred by one
-- frame so other SETTING_CHANGED listeners (notably SearchToggleButton's own
-- Show/Hide handler) complete first — avoids stale IsShown reads during
-- filter.
function HeaderButtonVisibility:Watch(owner, callback)
    Events:Register("SETTING_CHANGED", function(event, key)
        if type(key) ~= "string" then return end
        if key:sub(1, 10) == "showHeader" or key == "showSearchBar" then
            C_Timer.After(0, callback)
        end
    end, owner)
end
