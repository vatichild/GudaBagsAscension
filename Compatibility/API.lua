-- GudaBags Compatibility API Layer
-- Provides API abstractions for cross-expansion compatibility

local addonName, ns = ...

local API = {}
ns:RegisterModule("Compatibility.API", API)

local Expansion = ns:GetModule("Expansion")

-------------------------------------------------
-- Container API Wrappers
-- Same API in both TBC and MoP, but wrapped for future-proofing
-------------------------------------------------

function API:GetContainerNumSlots(bagID)
    return C_Container.GetContainerNumSlots(bagID)
end

function API:GetContainerNumFreeSlots(bagID)
    return C_Container.GetContainerNumFreeSlots(bagID)
end

function API:GetContainerItemInfo(bagID, slot)
    return C_Container.GetContainerItemInfo(bagID, slot)
end

function API:GetContainerItemLink(bagID, slot)
    return C_Container.GetContainerItemLink(bagID, slot)
end

function API:PickupContainerItem(bagID, slot)
    return C_Container.PickupContainerItem(bagID, slot)
end

function API:SplitContainerItem(bagID, slot, amount)
    return C_Container.SplitContainerItem(bagID, slot, amount)
end

function API:UseContainerItem(bagID, slot)
    return C_Container.UseContainerItem(bagID, slot)
end

-------------------------------------------------
-- Keyring API (TBC only)
-------------------------------------------------

function API:HasKeyring()
    return Expansion.Features.HasKeyring
end

function API:GetKeyringSize()
    if not Expansion.Features.HasKeyring then
        return 0
    end
    -- Keyring is bag ID -2 in TBC
    return C_Container.GetContainerNumSlots(-2) or 0
end

-------------------------------------------------
-- Item Family/Bag Type API
-------------------------------------------------

function API:GetItemFamily(itemID)
    if not itemID then return 0 end
    return C_Item.GetItemFamily(itemID) or 0
end

-- Check if item can go in a specialized bag
function API:CanItemGoInBag(itemID, bagFamily)
    if bagFamily == 0 then return true end
    if not itemID then return false end

    local itemFamily = C_Item.GetItemFamily(itemID)
    if not itemFamily then return false end

    return bit.band(itemFamily, bagFamily) ~= 0
end

-------------------------------------------------
-- Expansion-specific bag family checks
-------------------------------------------------

-- Quiver bags (TBC only, family bit 1)
function API:IsQuiverBag(bagFamily)
    if not Expansion.Features.HasQuiverBags then return false end
    return bit.band(bagFamily or 0, 1) ~= 0
end

-- Ammo bags (TBC only, family bit 2)
function API:IsAmmoBag(bagFamily)
    if not Expansion.Features.HasAmmoBags then return false end
    return bit.band(bagFamily or 0, 2) ~= 0
end

-- Soul bags (both expansions, family bit 4)
function API:IsSoulBag(bagFamily)
    return bit.band(bagFamily or 0, 4) ~= 0
end

-- Gem bags (MoP+, family bit 512)
function API:IsGemBag(bagFamily)
    if not Expansion.Features.HasGemBags then return false end
    return bit.band(bagFamily or 0, 512) ~= 0
end

-- Inscription bags (MoP+, family bit 16)
function API:IsInscriptionBag(bagFamily)
    if not Expansion.Features.HasInscriptionBags then return false end
    return bit.band(bagFamily or 0, 16) ~= 0
end
