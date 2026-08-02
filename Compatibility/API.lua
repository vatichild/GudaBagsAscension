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

-------------------------------------------------
-- Currency API
--
-- Two shapes behind one set of wrappers (Expansion.CurrencyAPI says which):
--
--   "modern" -- C_CurrencyInfo.*, returns a table, identity is a currencyID,
--               currencies have |Hcurrency:ID|h links.
--   "wotlk"  -- bare globals, returns a value tuple, identity is an ITEM id.
--               3.3.5a has no currency link type and no GetCurrencyListLink, so
--               the id has to come out of the info tuple itself.
--
-- The scanner and the footer widget each used to carry their own binding and
-- their own normalizer, and both had the Wrath field order wrong in a different
-- way. One definition here, consumed by both.
-------------------------------------------------

local _GetListSize   = (C_CurrencyInfo and C_CurrencyInfo.GetCurrencyListSize) or GetCurrencyListSize
local _GetListInfo   = (C_CurrencyInfo and C_CurrencyInfo.GetCurrencyListInfo) or GetCurrencyListInfo
local _GetBackpack   = (C_CurrencyInfo and C_CurrencyInfo.GetBackpackCurrencyInfo) or GetBackpackCurrencyInfo
local _ExpandList    = (C_CurrencyInfo and C_CurrencyInfo.ExpandCurrencyList) or ExpandCurrencyList
local _GetListLink   = (C_CurrencyInfo and C_CurrencyInfo.GetCurrencyListLink) or GetCurrencyListLink

function API:HasCurrency()
    return Expansion.Features.HasCurrency == true
end

-- Honor and arena points ride the currency list as pseudo-rows: they have a
-- name and a count but no itemID. Key them off the negated extraCurrencyType so
-- they can be stored and looked up alongside real tokens without colliding.
function API:GetCurrencyKey(itemID, extraCurrencyType)
    if extraCurrencyType and extraCurrencyType ~= 0 then
        return -extraCurrencyType
    end
    if itemID and itemID ~= 0 then
        return itemID
    end
    return nil
end

function API:GetCurrencyListSize()
    if not _GetListSize then return 0 end
    return _GetListSize() or 0
end

-- Returns: name, isHeader, isExpanded, isWatched, quantity, extraCurrencyType, icon, itemID
function API:GetCurrencyListInfo(index)
    if not _GetListInfo then return nil end

    local result, a, b, c, d, e, f, g, h = _GetListInfo(index)

    if type(result) == "table" then
        -- Retail: one table, identity is currencyTypesID.
        if not result.name then return nil end
        return result.name, result.isHeader, result.isHeaderExpanded, result.isShowInBackpack,
            result.quantity, 0, result.iconFileID, result.currencyTypesID
    elseif result ~= nil then
        -- 3.3.5a / MoP:
        --   name, isHeader, isExpanded, isUnused, isWatched, count,
        --   extraCurrencyType, icon, itemID
        local isHeader, isExpanded, _isUnused, isWatched, count = a, b, c, d, e
        local extraCurrencyType, icon, itemID = f, g, h
        return result, isHeader, isExpanded, isWatched, count, extraCurrencyType or 0, icon, itemID
    end

    return nil
end

-- The backpack-tracked subset, in the order the client shows it.
-- Returns: name, quantity, extraCurrencyType, icon, itemID
function API:GetTrackedCurrency(index)
    if not _GetBackpack then return nil end

    local result, a, b, c, d = _GetBackpack(index)

    if type(result) == "table" then
        if not result.name then return nil end
        return result.name, result.quantity, 0, result.iconFileID, result.currencyTypesID
    elseif result ~= nil then
        -- 3.3.5a: name, count, extraCurrencyType, icon, itemID
        --
        -- The order matters and used to be wrong here: the old normalizer
        -- returned this tuple straight through into (name, quantity, icon,
        -- currencyID) bindings, which put the numeric extraCurrencyType in the
        -- icon slot and a texture path in the id slot.
        local count, extraCurrencyType, icon, itemID = a, b, c, d
        return result, count, extraCurrencyType or 0, icon, itemID
    end

    return nil
end

-- 3.3.5a types shouldExpand as a number, not a boolean.
function API:ExpandCurrencyList(index)
    if not _ExpandList then return end
    if Expansion.CurrencyAPI == "wotlk" then
        _ExpandList(index, 1)
    else
        _ExpandList(index, true)
    end
end

-- Retail only; nil on 3.3.5a, where no currency link type exists.
function API:GetCurrencyListLink(index)
    if not _GetListLink then return nil end
    return _GetListLink(index)
end
