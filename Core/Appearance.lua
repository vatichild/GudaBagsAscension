local addonName, ns = ...

-- Transmogrification support.
--
-- The marker answers one question: "can I still collect this item's appearance?"
-- That is the actionable signal -- gear whose look you already own is not worth
-- holding on to, and "is transmoggable" alone would mark nearly every piece of
-- gear in the bag, which is no signal at all.
--
-- SOURCE OF TRUTH: the purple tooltip line Ascension adds to collectable gear
-- ("Hold CTRL + ALT and CLICK to collect this appearance, binding the item to
-- you"). Data\ItemScanner.lua matches it inside the single tooltip pass it
-- already runs per item and caches the result by item link, so this costs one
-- extra string find per tooltip line on a cache miss and nothing thereafter.
--
-- Why not the API: Ascension does expose an appearance layer in Extensions.dll --
--   C_Appearance           = { IsTransmogable, GetItemAppearanceID, ... }
--   C_AppearanceCollection = { IsAppearanceCollected, GetCollectedCount, ... }
-- but the signatures are unverified (see /gbprobe and docs\TM_INDICATOR_PLAN.md),
-- and IsTransmogable answers the less useful question. The tooltip is what the
-- player actually sees, so matching it can never disagree with the game.

local Appearance = {}
ns:RegisterModule("Appearance", Appearance)

local Events = ns:GetModule("Events")

-- NOTE: there is deliberately no CanCollect() accessor here. The flag is a plain
-- field on the scanned record (itemData.canCollectAppearance), and UI\ItemButton.lua
-- reads it directly the same way it reads isQuestItem / isOpenable / isUsable.
-- Routing it through this module would add a load-order dependency for no gain --
-- and did exactly that once, blanking every bag when the .toc had not been
-- re-read (adding a file to the .toc needs a client restart, not /reload).

--- Does this client expose Ascension's appearance API? Not used by the marker --
--- this is the gate for the API-driven work in docs\TM_INDICATOR_PLAN.md.
--- @return boolean
function Appearance:HasCollectionAPI()
    return type(_G.C_AppearanceCollection) == "table"
        and type(_G.C_AppearanceCollection.IsAppearanceCollected) == "function"
end

-- Collecting an appearance removes the tooltip line, but the scanned result is
-- cached by item link and would keep the dot on every other copy of that look
-- until something else invalidated it. Drop the tooltip cache and repaint.
--
-- A full Refresh rather than a targeted marker pass: the flag lives in the
-- scanned itemData, so the slots genuinely have to be re-scanned -- walking the
-- button pool would only re-read the same stale records. Collecting an
-- appearance is a rare, deliberate action, so the cost is irrelevant, and only
-- open frames repaint.
--
-- Core\Events.lua pcalls RegisterEvent and records names this client does not
-- know in Events.unsupported, so listing an event that never fires is harmless.
if Events then
    local function OnAppearanceChanged()
        local ItemScanner = ns:GetModule("ItemScanner")
        if ItemScanner then ItemScanner:ClearTooltipCache() end

        local BagFrame = ns:GetModule("BagFrame")
        if BagFrame and BagFrame:IsShown() then BagFrame:Refresh() end

        local BankFrame = ns:GetModule("BankFrame")
        if BankFrame and BankFrame:IsShown() then BankFrame:Refresh() end
    end

    for _, event in ipairs({
        "APPEARANCE_COLLECTED",
        "APPEARANCE_UNCOLLECTED",
        "COLLECT_ITEM_APPEARANCE_RESULT",
        "UNLOCKED_APPEARANCE_ITEM_USED",
    }) do
        Events:Register(event, OnAppearanceChanged, Appearance)
    end
end
