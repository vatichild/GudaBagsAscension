-- GudaBags Compatibility Features
-- Provides expansion-specific feature toggles and bag family information

local addonName, ns = ...

local Features = {}
ns:RegisterModule("Compatibility.Features", Features)

local Expansion = ns:GetModule("Expansion")

-------------------------------------------------
-- Bag Families
-- Returns supported bag families for the current expansion
-------------------------------------------------

function Features:GetSupportedBagFamilies()
    local families = {
        -- Common bag types (all Classic expansions)
        regular = true,
        soul = true,
        herb = true,
        enchant = true,
        engineering = true,
        mining = true,
        leatherworking = true,
    }

    -- TBC / Wrath bag types (quivers and ammo pouches exist until Cataclysm)
    if Expansion.IsTBC or Expansion.IsWrath then
        families.quiver = true
        families.ammo = true
    end

    -- MoP-specific bag types
    if Expansion.IsMoP then
        families.gem = true
        families.inscription = true
    end

    return families
end

-------------------------------------------------
-- Bag Family Bit Masks
-- Maps bag type names to their family bit values
-------------------------------------------------

function Features:GetBagFamilyBits()
    local bits = {
        -- Common (all Classic expansions)
        soul = 4,
        leatherworking = 8,
        herb = 32,
        enchant = 64,
        engineering = 128,
        mining = 1024,
    }

    -- TBC / Wrath
    if Expansion.IsTBC or Expansion.IsWrath then
        bits.quiver = 1
        bits.ammo = 2
    end

    -- MoP-specific
    if Expansion.IsMoP then
        bits.inscription = 16
        bits.gem = 512
    end

    return bits
end

-------------------------------------------------
-- Get bag type from family bitmask
-------------------------------------------------

function Features:GetBagTypeFromFamily(bagFamily)
    if bagFamily == 0 then return nil end

    -- TBC / Wrath bag types (check first as they're lower bits)
    if Expansion.IsTBC or Expansion.IsWrath then
        if bit.band(bagFamily, 1) ~= 0 then return "quiver" end
        if bit.band(bagFamily, 2) ~= 0 then return "ammo" end
    end

    -- Common bag types
    if bit.band(bagFamily, 4) ~= 0 then return "soul" end
    if bit.band(bagFamily, 8) ~= 0 then return "leatherworking" end
    if bit.band(bagFamily, 32) ~= 0 then return "herb" end
    if bit.band(bagFamily, 64) ~= 0 then return "enchant" end
    if bit.band(bagFamily, 128) ~= 0 then return "engineering" end
    if bit.band(bagFamily, 1024) ~= 0 then return "mining" end

    -- MoP-specific bag types
    if Expansion.IsMoP then
        if bit.band(bagFamily, 16) ~= 0 then return "inscription" end
        if bit.band(bagFamily, 512) ~= 0 then return "gem" end
    end

    return "specialized"
end

-------------------------------------------------
-- Feature Queries
-------------------------------------------------

function Features:HasKeyring()
    return Expansion.Features.HasKeyring
end

function Features:HasQuiverBags()
    return Expansion.Features.HasQuiverBags
end

function Features:HasAmmoBags()
    return Expansion.Features.HasAmmoBags
end

function Features:HasGemBags()
    return Expansion.Features.HasGemBags
end

function Features:HasInscriptionBags()
    return Expansion.Features.HasInscriptionBags
end

-------------------------------------------------
-- Category availability based on expansion
-------------------------------------------------

function Features:ShouldShowCategory(categoryId)
    -- TBC-only categories
    if categoryId == "Keyring" then
        return Expansion.IsTBC
    end

    if categoryId == "Quiver" then
        return Expansion.IsTBC
    end

    -- All other categories are available in both expansions
    return true
end

-------------------------------------------------
-- Get list of expansion-specific categories to disable
-------------------------------------------------

function Features:GetDisabledCategories()
    local disabled = {}

    if not Expansion.IsTBC then
        disabled["Keyring"] = true
        disabled["Quiver"] = true
    end

    return disabled
end
