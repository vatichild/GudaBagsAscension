-- GudaBags Expansion Detection
-- Detects WoW version and provides expansion-specific feature flags

local addonName, ns = ...

local Expansion = {}
ns:RegisterModule("Expansion", Expansion)

-- WoW Project ID constants (from Blizzard API)
-- WOW_PROJECT_MAINLINE = 1                  (Retail, Interface 110005+)
-- WOW_PROJECT_CLASSIC = 2                   (Classic Era, Interface 11508)
-- WOW_PROJECT_BURNING_CRUSADE_CLASSIC = 5   (TBC Anniversary, Interface 20506)
-- WOW_PROJECT_MISTS_CLASSIC = 19            (MoP Classic, Interface 50504)

-- Primary detection via WOW_PROJECT_ID
-- NOTE: On WotLK 3.3.5a clients (e.g. Ascension) WOW_PROJECT_ID is nil, so every
-- comparison below is false and detection falls through to the interface-version block.
Expansion.IsRetail = WOW_PROJECT_ID == (WOW_PROJECT_MAINLINE or 1)
Expansion.IsClassicEra = WOW_PROJECT_ID == (WOW_PROJECT_CLASSIC or 2)
Expansion.IsTBC = WOW_PROJECT_ID == (WOW_PROJECT_BURNING_CRUSADE_CLASSIC or 5)
Expansion.IsMoP = WOW_PROJECT_ID == (WOW_PROJECT_MISTS_CLASSIC or 19)
Expansion.IsWrath = false  -- no WOW_PROJECT id exists for WotLK; set via interface below

-- Get interface version for fallback detection.
-- 3.3.5a's GetBuildInfo returns only 3 values (version, build, date) -- the TOC
-- version was added in Cataclysm. Derive it from the "3.3.5" version string so
-- every comparison below stays a number-vs-number test.
local buildVersion, _, _, interfaceVersion = GetBuildInfo()
if type(interfaceVersion) ~= "number" then
    local major, minor, patch = tostring(buildVersion or ""):match("^(%d+)%.(%d+)%.(%d+)")
    if major then
        interfaceVersion = tonumber(major) * 10000 + tonumber(minor) * 100 + tonumber(patch)
    else
        interfaceVersion = 30300  -- assume WotLK 3.3.5a
    end
end
Expansion.InterfaceVersion = interfaceVersion

-- Fallback detection via interface version if project ID detection failed
if not Expansion.IsRetail and not Expansion.IsClassicEra and not Expansion.IsTBC and not Expansion.IsMoP then
    Expansion.IsRetail = interfaceVersion >= 110000
    Expansion.IsClassicEra = interfaceVersion >= 11500 and interfaceVersion < 20000
    Expansion.IsTBC = interfaceVersion >= 20500 and interfaceVersion < 30000
    Expansion.IsWrath = interfaceVersion >= 30000 and interfaceVersion < 40000  -- WotLK 3.3.5a
    Expansion.IsMoP = interfaceVersion >= 50500 and interfaceVersion < 60000
end

-- Wrath 3.3.5a shares Classic's bag layout (bags 0-4, bank -1/5-11, keyring -2).
-- It has a keyring, quivers/ammo and a guild bank, but NONE of the modern systems
-- (reagent bank, warband bank, C_CurrencyInfo, native C_Container.SortBags).
Expansion.Features = {
    -- Classic Era / TBC / Wrath features
    HasKeyring = Expansion.IsClassicEra or Expansion.IsTBC or Expansion.IsWrath,
    HasQuiverBags = Expansion.IsClassicEra or Expansion.IsTBC or Expansion.IsWrath,
    HasAmmoBags = Expansion.IsClassicEra or Expansion.IsTBC or Expansion.IsWrath,

    -- MoP-specific features
    HasGemBags = Expansion.IsMoP,
    HasInscriptionBags = Expansion.IsMoP,

    -- Retail-specific features (all absent on Wrath)
    HasNativeBagSort = Expansion.IsRetail,  -- C_Container.SortBags() available
    HasReagentBank = Expansion.IsRetail,
    HasWarbandBank = Expansion.IsRetail,
    HasCurrency = Expansion.IsRetail or Expansion.IsMoP,
}

-- Convenience exports to namespace root
ns.IsRetail = Expansion.IsRetail
ns.IsClassicEra = Expansion.IsClassicEra
ns.IsTBC = Expansion.IsTBC
ns.IsWrath = Expansion.IsWrath
ns.IsMoP = Expansion.IsMoP
ns.ExpansionFeatures = Expansion.Features

