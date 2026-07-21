local addonName, ns = ...

-- Public namespace for third-party addon integration.
-- The internal `ns` table stays private (per WoW addon convention); only the
-- documented functions on _G.GudaBags.API are stable across versions.
_G.GudaBags = _G.GudaBags or {}
_G.GudaBags.API = _G.GudaBags.API or {}

local itemButtonHooks = {}

-- GudaBags.API.OnItemButtonUpdate(callback)
--
-- Register a callback that fires after each real-item update on a GudaBags
-- item button. Signature: callback(button, bagID, slot)
--
-- Use this to decorate GudaBags' item buttons from another addon — e.g.,
--   GudaBags.API.OnItemButtonUpdate(function(button, bag, slot)
--       local item = Item:CreateFromBagAndSlot(bag, slot)
--       MyAddon:DecorateButton(button, item)
--   end)
--
-- Fires for bags, bank, and mail buttons (all share ItemButton:SetItem).
-- Does NOT fire for: pseudo-items (Empty / Soul / DropTarget), read-only or
-- cached-character views, or guild-bank items (synthetic bagID).
function _G.GudaBags.API.OnItemButtonUpdate(callback)
    if type(callback) ~= "function" then return end
    table.insert(itemButtonHooks, callback)
end

-- Internal: invoked from UI/ItemButton.lua SetItem. Not part of the public API.
-- pcall-wrapped so a buggy third-party callback can't break rendering.
function ns:FireItemButtonUpdate(button, bagID, slot)
    for i = 1, #itemButtonHooks do
        local ok, err = pcall(itemButtonHooks[i], button, bagID, slot)
        if not ok then
            ns:Print("GudaBags.API hook error:", err)
        end
    end
end
