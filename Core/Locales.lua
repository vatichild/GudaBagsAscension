local addonName, ns = ...

-------------------------------------------------
-- Initialize Localization System
-------------------------------------------------

-- Store reference to all locales for language switching
local AllLocales = ns.Locales

-- Start with English as the base (fallback for missing translations)
ns.L = {}
for key, value in pairs(AllLocales.enUS) do
    ns.L[key] = value
end

-- Track current locale (will be updated in ADDON_LOADED)
local currentLocale = GetLocale()

-- Apply locale overlay
local function ApplyLocaleOverlay(localeCode)
    if AllLocales[localeCode] then
        for key, translation in pairs(AllLocales[localeCode]) do
            if translation and translation ~= "" then
                ns.L[key] = translation
            end
        end
        return true
    end
    return false
end

-- Export keybinding strings to global namespace
local function UpdateBindingStrings()
    for key, translation in pairs(ns.L) do
        if key:match("^BINDING_") then
            local bindingKey = key:gsub("^BINDING_", "")
            _G["BINDING_HEADER_GUDABAGS"] = ns.L["BINDING_HEADER"]
            if bindingKey ~= "HEADER" then
                _G["BINDING_NAME_GUDABAGS_" .. bindingKey] = translation
            end
        end
    end
end

-- Apply client locale immediately (for non-English clients)
if currentLocale ~= "enUS" then
    ApplyLocaleOverlay(currentLocale)
end
UpdateBindingStrings()

-------------------------------------------------
-- Deferred Initialization (after SavedVariables load)
-------------------------------------------------

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("ADDON_LOADED")
initFrame:SetScript("OnEvent", function(self, event, loadedAddon)
    if loadedAddon ~= addonName then return end
    self:UnregisterEvent("ADDON_LOADED")

    -- Check for test locale override
    if GudaBags_DB and GudaBags_DB.settings and GudaBags_DB.settings.testLocale then
        local testLocale = GudaBags_DB.settings.testLocale
        if AllLocales[testLocale] then
            currentLocale = testLocale
            -- Re-apply: first reset to English, then apply test locale
            for key, value in pairs(AllLocales.enUS) do
                ns.L[key] = value
            end
            ApplyLocaleOverlay(testLocale)
            UpdateBindingStrings()
        end
    end
end)

-------------------------------------------------
-- Language Switching (for testing)
-------------------------------------------------

-- Get list of available locales
function ns:GetAvailableLocales()
    local locales = {}
    for code, _ in pairs(AllLocales) do
        table.insert(locales, code)
    end
    table.sort(locales)
    return locales
end

-- Get current locale code
function ns:GetCurrentLocale()
    return currentLocale
end

-- Switch to a different locale (for testing)
function ns:SetLocale(localeCode)
    -- Handle "reset" to clear test locale
    if localeCode == "reset" or localeCode == "auto" then
        if GudaBags_DB and GudaBags_DB.settings then
            GudaBags_DB.settings.testLocale = nil
        end
        ns:Print("Locale reset to game default (" .. GetLocale() .. "). Type /reload to apply.")
        return true
    end

    if not AllLocales[localeCode] then
        ns:Print("Unknown locale: " .. localeCode)
        ns:Print("Available: " .. table.concat(ns:GetAvailableLocales(), ", "))
        ns:Print("Use '/guda locale reset' to restore game default")
        return false
    end

    -- Save to DB so it persists across reload
    if not GudaBags_DB then GudaBags_DB = {} end
    if not GudaBags_DB.settings then GudaBags_DB.settings = {} end
    GudaBags_DB.settings.testLocale = localeCode

    ns:Print("Locale set to: " .. localeCode)
    ns:Print("Type /reload to apply.")

    return true
end

-- Keep Locales reference (don't nil it) for language switching
ns.Locales = nil  -- Clear the ns reference but AllLocales is kept locally
