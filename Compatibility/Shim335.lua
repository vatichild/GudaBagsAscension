-- GudaBags 3.3.5a Compatibility Shim
-- =====================================================================
-- Loads FIRST (see .toc). Polyfills the modern WoW APIs GudaBags is built
-- on (namespaced C_* tables, CreateObjectPool, Mixin, C_Timer, ...) onto the
-- WotLK 3.3.5a global API so the rest of the addon runs unmodified.
--
-- Every polyfill is existence-checked: if the client already provides a
-- native implementation (e.g. an Ascension backport) that one is kept and we
-- record it. A diagnostic report of what was native / polyfilled / missing is
-- written to the GudaBagsShim_DB saved variable for post-run inspection.
-- =====================================================================

local addonName, ns = ...

GudaBagsShim_DB = GudaBagsShim_DB or {}
local report = { native = {}, polyfilled = {}, missingGlobals = {}, notes = {} }

local function markNative(name)      report.native[name] = true end
local function markPolyfilled(name)  report.polyfilled[name] = true end

-- Record whether a global the shim RELIES ON actually exists on this client.
local function requireGlobal(name)
    local exists = _G[name] ~= nil
    if not exists then report.missingGlobals[name] = true end
    return exists
end

local function ensureTable(name)
    if type(_G[name]) == "table" then markNative(name); return _G[name], false end
    _G[name] = {}
    markPolyfilled(name)
    return _G[name], true
end

-- Fill a method on a namespace table only if it is not already present.
local function fill(tbl, key, fn)
    if type(tbl[key]) ~= "function" then tbl[key] = fn end
end

-------------------------------------------------------------------------
-- 0. Capture originals we wrap
-------------------------------------------------------------------------
local _CreateFrame = CreateFrame
local GetTime = GetTime

-------------------------------------------------------------------------
-- 1. C_Timer  (WoD 6.0) -- OnUpdate-driven scheduler
-------------------------------------------------------------------------
if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
    markNative("C_Timer")
else
    C_Timer = C_Timer or {}
    markPolyfilled("C_Timer")
    local timers = {}
    local driver = _CreateFrame("Frame")
    driver:SetScript("OnUpdate", function()
        if #timers == 0 then return end
        local now = GetTime()
        for i = #timers, 1, -1 do
            local t = timers[i]
            if t.cancelled then
                table.remove(timers, i)
            elseif now >= t.at then
                local ok, err = pcall(t.func, t)
                if not ok then
                    report.notes[#report.notes + 1] = "timer error: " .. tostring(err)
                end
                if t.ticker and not t.cancelled then
                    t.at = now + t.interval
                    if t.left then
                        t.left = t.left - 1
                        if t.left <= 0 then table.remove(timers, i) end
                    end
                else
                    table.remove(timers, i)
                end
            end
        end
    end)
    local function schedule(t) timers[#timers + 1] = t; return t end
    local function makeCancelable(t)
        t.Cancel = function(self) self.cancelled = true end
        t.IsCancelled = function(self) return self.cancelled == true end
        return t
    end
    fill(C_Timer, "After", function(seconds, func)
        schedule({ at = GetTime() + (seconds or 0), func = func })
    end)
    fill(C_Timer, "NewTimer", function(seconds, func)
        return makeCancelable(schedule({ at = GetTime() + (seconds or 0), func = func }))
    end)
    fill(C_Timer, "NewTicker", function(seconds, func, iterations)
        return makeCancelable(schedule({
            at = GetTime() + (seconds or 0), func = func, ticker = true,
            interval = seconds or 0, left = iterations,
        }))
    end)
end

-------------------------------------------------------------------------
-- 2. Mixin helpers  (Legion 7.0)
-------------------------------------------------------------------------
if type(Mixin) == "function" then markNative("Mixin") else
    markPolyfilled("Mixin")
    function Mixin(object, ...)
        for i = 1, select("#", ...) do
            local mixin = select(i, ...)
            if mixin then for k, v in pairs(mixin) do object[k] = v end end
        end
        return object
    end
end
if type(CreateFromMixins) ~= "function" then
    function CreateFromMixins(...) return Mixin({}, ...) end
    markPolyfilled("CreateFromMixins")
end
if type(CreateAndInitFromMixin) ~= "function" then
    function CreateAndInitFromMixin(mixin, ...)
        local o = CreateFromMixins(mixin)
        if o.Init then o:Init(...) end
        return o
    end
    markPolyfilled("CreateAndInitFromMixin")
end

-------------------------------------------------------------------------
-- 3. Object / Frame pools  (Legion 7.0)
-------------------------------------------------------------------------
if type(CreateObjectPool) == "function" then markNative("CreateObjectPool") else
    markPolyfilled("CreateObjectPool")
    local PoolMixin = {}
    PoolMixin.__index = PoolMixin
    function PoolMixin:Acquire()
        local n = #self.inactiveObjects
        if n > 0 then
            local obj = self.inactiveObjects[n]
            self.inactiveObjects[n] = nil
            self.activeObjects[obj] = true
            self.numActiveObjects = self.numActiveObjects + 1
            return obj, false
        end
        local obj = self.creationFunc(self)
        if self.resetterFunc and not self.disallowResetIfNew then
            self.resetterFunc(self, obj)
        end
        self.activeObjects[obj] = true
        self.numActiveObjects = self.numActiveObjects + 1
        return obj, true
    end
    function PoolMixin:Release(obj)
        if self.activeObjects[obj] then
            self.activeObjects[obj] = nil
            self.numActiveObjects = self.numActiveObjects - 1
            if self.resetterFunc then self.resetterFunc(self, obj) end
            self.inactiveObjects[#self.inactiveObjects + 1] = obj
            return true
        end
        return false
    end
    function PoolMixin:ReleaseAll()
        for obj in pairs(self.activeObjects) do self:Release(obj) end
    end
    function PoolMixin:EnumerateActive() return pairs(self.activeObjects) end
    function PoolMixin:GetNextActive(current) return (next(self.activeObjects, current)) end
    function PoolMixin:IsActive(obj) return self.activeObjects[obj] == true end
    function PoolMixin:GetNumActive() return self.numActiveObjects end
    function PoolMixin:EnumerateInactive() return ipairs(self.inactiveObjects) end
    function PoolMixin:SetResetDisallowedIfNew(v) self.disallowResetIfNew = v end

    function CreateObjectPool(creationFunc, resetterFunc)
        local pool = setmetatable({}, PoolMixin)
        pool.creationFunc = creationFunc
        pool.resetterFunc = resetterFunc
        pool.activeObjects = {}
        pool.inactiveObjects = {}
        pool.numActiveObjects = 0
        return pool
    end

    -- Default frame-pool reset used by CreateFramePool
    function FramePool_HideAndClearAnchors(_, frame)
        frame:Hide()
        frame:ClearAllPoints()
    end
    if type(CreateFramePool) ~= "function" then
        function CreateFramePool(frameType, parent, template, resetterFunc, forbidden)
            local pool = CreateObjectPool(
                function() return _CreateFrame(frameType, nil, parent, template) end,
                resetterFunc or FramePool_HideAndClearAnchors)
            pool.parent = parent
            return pool
        end
    end
end

-------------------------------------------------------------------------
-- 4. CreateFrame -- strip templates that don't exist on 3.3.5a
--    * BackdropTemplate (9.0): WotLK frames have SetBackdrop natively.
--    * ButtonFrameTemplate (4.0): substituted with an equivalent-enough frame
--      built from 3.3.5a parts, so the popup UI code needs no changes.
-------------------------------------------------------------------------
do
    local usesBackdropTemplate = false
    local hasButtonFrameTemplate = pcall(_CreateFrame, "Frame", nil, UIParent, "ButtonFrameTemplate")

    -- Give a plain frame the handful of ButtonFrameTemplate members the addon
    -- actually touches: CloseButton, Inset, TitleText, Bg, TitleBg. Everything
    -- else is accessed nil-guarded (see Core\Theme.lua:ResetPopupChrome).
    local function buildButtonFrameSubstitute(frame, name)
        -- NO BACKDROP HERE, deliberately.
        --
        -- This used to apply a UI-DialogBox backdrop so the substitute looked
        -- like a panel. That put chrome on the FRAME ITSELF, and the theme
        -- system can only hide CHILD textures (Core\Theme.lua:ResetPopupChrome
        -- hides Bg/TitleBg/NineSlice), so nothing ever cleared it -- the
        -- settings and category-editor popups showed a stray Blizzard border
        -- under the Guda theme. It disappeared only after switching to the metal
        -- theme, because that path calls frame:SetBackdrop(nil), and never came
        -- back.
        --
        -- The theme always draws its own background (a _gudaBackdrop child, or
        -- the metal frame), so a bare frame is both correct and what the real
        -- template effectively provides once its chrome is hidden.

        local ok, close = pcall(_CreateFrame, "Button",
                                name and (name .. "CloseButton") or nil,
                                frame, "UIPanelCloseButton")
        if ok and close then
            close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -5, -5)
            frame.CloseButton = close
        end

        local title = frame:CreateFontString(name and (name .. "TitleText") or nil,
                                             "ARTWORK", "GameFontNormal")
        title:SetPoint("TOP", frame, "TOP", 0, -13)
        frame.TitleText = title

        local inset = _CreateFrame("Frame", name and (name .. "Inset") or nil, frame)
        inset:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -26)
        inset:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -6, 6)
        frame.Inset = inset

        -- ButtonFrameTemplate METHODS, not just children. UI\SettingsPopup.lua
        -- and UI\CategoryEditor.lua call frame:SetTitle(...), which is a mixin
        -- method on the real template (Cata+). Without it the popup errors
        -- part-way through construction and renders as a broken, empty window.
        function frame:SetTitle(text)
            if self.TitleText then self.TitleText:SetText(text) end
        end
        function frame:GetTitleText() return self.TitleText end
        function frame:SetPortraitToAsset() end
        function frame:SetPortraitToUnit() end

        return frame
    end

    -- Post-4.0 templates the addon inherits, mapped to a 3.3.5a stand-in.
    -- `false` means "drop it and create a bare frame".
    --
    -- IMPORTANT: every entry is dropped again below if the client actually HAS
    -- the template. Ascension backports more than stock 3.3.5a does (probe run
    -- confirmed ButtonFrameTemplate, NineSlicePanelTemplate and
    -- UIPanelDynamicResizeButtonTemplate all exist), and substituting a template
    -- that works only degrades the UI for no reason.
    local TEMPLATE_FALLBACKS = {
        BackdropTemplate                   = false,  -- SetBackdrop is native here
        ButtonFrameTemplate                = false,  -- rebuilt by the substitute below
        NineSlicePanelTemplate             = false,  -- decorative; callers nil-guard NineSliceUtil
        UIPanelDynamicResizeButtonTemplate = "UIPanelButtonTemplate",
        -- The War Within 11.0. UI\BankFrame.lua:451 inherits it alongside
        -- UIPanelButtonTemplate; an unknown name anywhere in the inherit list
        -- makes CreateFrame throw and breaks the bank purchase prompt.
        BankPanelPurchaseButtonScriptTemplate = false,
    }
    do
        local function templateExists(name)
            return (pcall(_CreateFrame, "Button", nil, UIParent, name))
        end
        -- Always substituted regardless of whether the client has them:
        --  * BackdropTemplate  -- WotLK frames have SetBackdrop natively.
        --  * ButtonFrameTemplate -- Ascension DOES ship one, but it is a
        --    Cata-era panel whose children (Bg, TitleBg, NineSlice, portrait,
        --    TopTileStreaks) are not the set Core\Theme.lua:ResetPopupChrome
        --    knows how to hide, so its chrome bleeds through the Guda theme as
        --    stray textures behind the settings and category-editor popups.
        --    Our own substitute is a plain backdrop frame with exactly the
        --    members the addon touches, so the popups theme predictably.
        local ALWAYS_SUBSTITUTE = { BackdropTemplate = true, ButtonFrameTemplate = true }
        for name in pairs(TEMPLATE_FALLBACKS) do
            if not ALWAYS_SUBSTITUTE[name] and templateExists(name) then
                TEMPLATE_FALLBACKS[name] = nil
                markNative("template:" .. name)
            else
                markPolyfilled("template:" .. name)
            end
        end
    end
    hasButtonFrameTemplate = TEMPLATE_FALLBACKS.ButtonFrameTemplate == nil

    -- Replace one template name inside a comma-separated inherit list.
    local function substituteTemplate(list, from, to)
        local pattern = from:gsub("%-", "%%-")
        if to then
            return (list:gsub(pattern, to))
        end
        return (list
            :gsub("%s*,%s*" .. pattern, "")
            :gsub(pattern .. "%s*,%s*", "")
            :gsub(pattern, ""))
    end

    CreateFrame = function(frameType, name, parent, template, id)
        local needsButtonFrame = false

        if type(template) == "string" then
            for modern, fallback in pairs(TEMPLATE_FALLBACKS) do
                if template:find(modern) then
                    if modern == "BackdropTemplate" then usesBackdropTemplate = true end
                    if modern == "ButtonFrameTemplate" then needsButtonFrame = true end
                    template = substituteTemplate(template, modern, fallback or nil)
                end
            end
            if template:match("^%s*$") then template = nil end
        end

        local frame = _CreateFrame(frameType, name, parent, template, id)
        if needsButtonFrame then
            buildButtonFrameSubstitute(frame, name)
        end
        return frame
    end

    if not hasButtonFrameTemplate then markPolyfilled("ButtonFrameTemplate") end

    -- Chrome helpers. Overridden UNCONDITIONALLY, not only when absent: since we
    -- always substitute ButtonFrameTemplate above, the frames handed to these
    -- helpers no longer have the portrait/button-bar children the real
    -- implementations dereference, and the stock version would nil-error.
    -- The substitute has no chrome to hide, so a no-op is the correct behaviour.
    function ButtonFrameTemplate_HidePortrait() end
    function ButtonFrameTemplate_HideButtonBar() end

    -- Note recorded lazily; flag captured for the report at PLAYER_LOGIN.
    report._backdropFlag = function() return usesBackdropTemplate end
end

-------------------------------------------------------------------------
-- 5. C_Container  (Dragonflight 10.0 namespacing of the global bag API)
-------------------------------------------------------------------------
if type(C_Container) == "table" and type(C_Container.GetContainerItemInfo) == "function" then
    markNative("C_Container")
else
    C_Container = C_Container or {}
    markPolyfilled("C_Container")
    requireGlobal("GetContainerItemInfo")
    requireGlobal("GetContainerNumSlots")
    requireGlobal("PickupContainerItem")

    fill(C_Container, "GetContainerNumSlots",     function(b) return GetContainerNumSlots(b) end)
    fill(C_Container, "GetContainerNumFreeSlots",  function(b) return GetContainerNumFreeSlots(b) end)
    fill(C_Container, "GetContainerItemLink",      function(b, s) return GetContainerItemLink(b, s) end)
    fill(C_Container, "PickupContainerItem",       function(b, s) return PickupContainerItem(b, s) end)
    fill(C_Container, "SplitContainerItem",        function(b, s, a) return SplitContainerItem(b, s, a) end)
    fill(C_Container, "UseContainerItem",          function(b, s, ...) return UseContainerItem(b, s, ...) end)
    fill(C_Container, "GetContainerItemCooldown",  function(b, s) return GetContainerItemCooldown(b, s) end)
    fill(C_Container, "ContainerIDToInventoryID",  function(b) return ContainerIDToInventoryID(b) end)
    fill(C_Container, "GetContainerItemID",        function(b, s)
        local link = GetContainerItemLink(b, s)
        return link and tonumber(link:match("item:(%d+)")) or nil
    end)

    -- Modern returns an info TABLE; WotLK returns positional values. Reshape.
    fill(C_Container, "GetContainerItemInfo", function(bag, slot)
        local texture, itemCount, locked, quality, readable, lootable, link,
              isFiltered, noValue, itemID = GetContainerItemInfo(bag, slot)
        if texture == nil and link == nil then return nil end  -- empty slot
        if itemID == nil and link then itemID = tonumber(link:match("item:(%d+)")) end
        return {
            iconFileID   = texture,
            stackCount   = itemCount,
            isLocked     = locked,
            quality      = quality,
            isReadable   = readable,
            hasLoot      = lootable,
            hyperlink    = link,
            isFiltered   = isFiltered or false,
            hasNoValue   = noValue or false,
            itemID       = itemID,
            isBound      = nil,
        }
    end)

    fill(C_Container, "GetContainerItemQuestInfo", function(bag, slot)
        local isQuestItem, questID, isActive = GetContainerItemQuestInfo(bag, slot)
        return { isQuestItem = isQuestItem, questId = questID, questID = questID, isActive = isActive }
    end)

    fill(C_Container, "GetContainerFreeSlots", function(bag)
        local free = {}
        for s = 1, (GetContainerNumSlots(bag) or 0) do
            if not GetContainerItemLink(bag, s) then free[#free + 1] = s end
        end
        return free
    end)
    -- NOTE: no C_Container.SortBags on WotLK; HasNativeBagSort is false so the
    -- addon uses its own SortEngine. Intentionally left unset.
end

-------------------------------------------------------------------------
-- 6. C_Item  (BfA 8.0)
-------------------------------------------------------------------------
-- enUS item class names -> modern numeric classID (Ascension locale is enUS).
local CLASS_NAME_TO_ID = {
    ["Consumable"] = 0, ["Container"] = 1, ["Weapon"] = 2, ["Gem"] = 3,
    ["Armor"] = 4, ["Reagent"] = 5, ["Projectile"] = 6, ["Trade Goods"] = 7,
    ["Recipe"] = 9, ["Quiver"] = 11, ["Quest"] = 12, ["Key"] = 13,
    ["Miscellaneous"] = 15, ["Glyph"] = 16,
}

-- enUS subclass names -> numeric subClassID, keyed by classID.
-- 3.3.5a's GetItemInfo stops at position 11 (sellPrice); classID/subClassID were
-- added in Legion. The scanners, category rules and sort keys all depend on them,
-- so they are reconstructed here from the localized type strings that ARE returned.
local SUBCLASS_NAME_TO_ID = {
    [0] = { ["Consumable"] = 0, ["Potion"] = 1, ["Elixir"] = 2, ["Flask"] = 3,
            ["Scroll"] = 4, ["Food & Drink"] = 5, ["Item Enhancement"] = 6,
            ["Bandage"] = 7, ["Other"] = 8 },
    [1] = { ["Bag"] = 0, ["Soul Bag"] = 1, ["Herb Bag"] = 2, ["Enchanting Bag"] = 3,
            ["Engineering Bag"] = 4, ["Gem Bag"] = 5, ["Mining Bag"] = 6,
            ["Leatherworking Bag"] = 7, ["Inscription Bag"] = 8 },
    [2] = { ["One-Handed Axes"] = 0, ["Two-Handed Axes"] = 1, ["Bows"] = 2,
            ["Guns"] = 3, ["One-Handed Maces"] = 4, ["Two-Handed Maces"] = 5,
            ["Polearms"] = 6, ["One-Handed Swords"] = 7, ["Two-Handed Swords"] = 8,
            ["Staves"] = 10, ["Fist Weapons"] = 13, ["Miscellaneous"] = 14,
            ["Daggers"] = 15, ["Thrown"] = 16, ["Crossbows"] = 18, ["Wands"] = 19,
            ["Fishing Poles"] = 20 },
    [3] = { ["Red"] = 0, ["Blue"] = 1, ["Yellow"] = 2, ["Purple"] = 3, ["Green"] = 4,
            ["Orange"] = 5, ["Meta"] = 6, ["Simple"] = 7, ["Prismatic"] = 8 },
    [4] = { ["Miscellaneous"] = 0, ["Cloth"] = 1, ["Leather"] = 2, ["Mail"] = 3,
            ["Plate"] = 4, ["Shields"] = 6, ["Librams"] = 7, ["Idols"] = 8,
            ["Totems"] = 9, ["Sigils"] = 10 },
    [5] = { ["Reagent"] = 0 },
    [6] = { ["Arrow"] = 2, ["Bullet"] = 3 },
    [7] = { ["Trade Goods"] = 0, ["Parts"] = 1, ["Explosives"] = 2, ["Devices"] = 3,
            ["Jewelcrafting"] = 4, ["Cloth"] = 5, ["Leather"] = 6,
            ["Metal & Stone"] = 7, ["Meat"] = 8, ["Herb"] = 9, ["Elemental"] = 10,
            ["Other"] = 11, ["Enchanting"] = 12, ["Materials"] = 13,
            ["Armor Enchantment"] = 14, ["Weapon Enchantment"] = 15 },
    [9] = { ["Book"] = 0, ["Leatherworking"] = 1, ["Tailoring"] = 2,
            ["Engineering"] = 3, ["Blacksmithing"] = 4, ["Cooking"] = 5,
            ["Alchemy"] = 6, ["First Aid"] = 7, ["Enchanting"] = 8, ["Fishing"] = 9,
            ["Jewelcrafting"] = 10, ["Inscription"] = 11 },
    [11] = { ["Quiver"] = 2, ["Ammo Pouch"] = 3 },
    [12] = { ["Quest"] = 0 },
    [13] = { ["Key"] = 0, ["Lockpick"] = 1 },
    [15] = { ["Junk"] = 0, ["Reagent"] = 1, ["Pet"] = 2, ["Holiday"] = 3,
             ["Other"] = 4, ["Mount"] = 5 },
}

-- Ascension exposes DBC-backed getters that return the real numeric ids. These
-- beat the name table above on every axis: locale independent, correct for
-- Ascension's custom items, and they work for items GetItemInfo hasn't cached.
-- Capability resolved ONCE here, not per item -- this runs in the sort engine's
-- hot path (see docs\RULES.md rule 2).
local nativeGetItemClassID    = type(GetItemClassID) == "function" and GetItemClassID or nil
local nativeGetItemSubClassID = type(GetItemSubClassID) == "function" and GetItemSubClassID or nil
if nativeGetItemClassID then markNative("GetItemClassID") end

--- Resolve numeric classID/subClassID for an item.
--- Prefers the client's own getters, falling back to mapping GetItemInfo's
--- localized type strings. Returns nil, nil when unknown so callers keep their
--- own defaults.
--- @param itemType string    GetItemInfo return 6 (item class name)
--- @param itemSubType string GetItemInfo return 7 (item subclass name)
--- @param itemID number|nil  itemID, when the caller has one (preferred path)
local function ResolveItemClassIDs(itemType, itemSubType, itemID)
    if nativeGetItemClassID and itemID then
        local classID = nativeGetItemClassID(itemID)
        if type(classID) == "number" then
            local subClassID
            if nativeGetItemSubClassID then
                local sub = nativeGetItemSubClassID(itemID)
                if type(sub) == "number" then subClassID = sub end
            end
            return classID, subClassID
        end
    end

    local classID = itemType and CLASS_NAME_TO_ID[itemType] or nil
    if classID == nil then return nil, nil end
    local subMap = SUBCLASS_NAME_TO_ID[classID]
    local subClassID = (subMap and itemSubType) and subMap[itemSubType] or nil
    return classID, subClassID
end

-- Exposed for the data layer; see Data\ItemScanner.lua and friends.
ns.Compat = ns.Compat or {}
ns.Compat.ResolveItemClassIDs = ResolveItemClassIDs
ns.Compat.CLASS_NAME_TO_ID = CLASS_NAME_TO_ID
ns.Compat.SUBCLASS_NAME_TO_ID = SUBCLASS_NAME_TO_ID
do
    local C = ensureTable("C_Item")
    requireGlobal("GetItemInfo")
    fill(C, "GetItemFamily",        function(item) return (GetItemFamily(item)) end)
    fill(C, "GetItemInfo",          function(item) return GetItemInfo(item) end)
    fill(C, "GetItemCount",         function(item, incBank, incUses) return GetItemCount(item, incBank, incUses) end)
    -- Real signature: itemID, itemType, itemSubType, itemEquipLoc, icon, classID, subClassID
    fill(C, "GetItemInfoInstant",   function(item)
        local name, link, quality, ilvl, req, class, subclass, maxStack, equipLoc, texture = GetItemInfo(item)
        local itemID
        if type(item) == "number" then itemID = item
        elseif type(item) == "string" then itemID = tonumber(item:match("item:(%d+)")) end
        -- Resolve BOTH ids: returning nil for subClassID (as this did before)
        -- silently disabled specialized-bag detection in BagClassifier.
        local classID, subClassID = ResolveItemClassIDs(class, subclass)
        return itemID, class, subclass, equipLoc, texture, classID, subClassID
    end)
    fill(C, "GetItemIconByID",      function(item)
        return (select(10, GetItemInfo(item))) or (GetItemIcon and GetItemIcon(item)) or nil
    end)
    fill(C, "IsItemDataCachedByID", function(item) return GetItemInfo(item) ~= nil end)
    fill(C, "RequestLoadItemDataByID", function(item) GetItemInfo(item) end)  -- WotLK caches on query
    fill(C, "GetItemQualityByID",   function(item) return (select(3, GetItemInfo(item))) end)
    fill(C, "GetItemNameByID",      function(item) return (GetItemInfo(item)) end)
end

-------------------------------------------------------------------------
-- 7. C_AddOns  (10.1)  -> WotLK globals
-------------------------------------------------------------------------
do
    local C = ensureTable("C_AddOns")
    fill(C, "GetAddOnMetadata", function(...) return GetAddOnMetadata(...) end)
    fill(C, "IsAddOnLoaded",    function(...) return IsAddOnLoaded(...) end)
    fill(C, "LoadAddOn",        function(...) return LoadAddOn(...) end)
    fill(C, "EnableAddOn",      function(...) return EnableAddOn(...) end)
    fill(C, "GetNumAddOns",     function(...) return GetNumAddOns(...) end)
    fill(C, "GetAddOnInfo",     function(...) return GetAddOnInfo(...) end)
end

-------------------------------------------------------------------------
-- 8. C_Spell (11.0), C_Texture / atlases (absent on WotLK)
-------------------------------------------------------------------------
do
    local C = ensureTable("C_Spell")
    fill(C, "GetSpellName", function(id) return (GetSpellInfo(id)) end)
    fill(C, "GetSpellInfo", function(id)
        local n, _, icon = GetSpellInfo(id)
        if not n then return nil end
        return { name = n, iconID = icon, spellID = id }
    end)
    fill(C, "GetSpellTexture", function(id) return (select(3, GetSpellInfo(id))) end)
end
do
    local C = ensureTable("C_Texture")
    fill(C, "GetAtlasInfo", function() return nil end)  -- no atlas system in WotLK
end
if type(CreateAtlasMarkup) ~= "function" then
    function CreateAtlasMarkup() return "" end
    markPolyfilled("CreateAtlasMarkup")
end
if type(GetAtlasInfo) ~= "function" then
    function GetAtlasInfo() return nil end
end

-------------------------------------------------------------------------
-- 9. C_EquipmentSet (8.0) -> WotLK equipment-manager globals (3.1.2+)
-------------------------------------------------------------------------
do
    local C = ensureTable("C_EquipmentSet")
    if type(GetNumEquipmentSets) == "function" then
        fill(C, "GetEquipmentSetIDs", function()
            local ids = {}
            for i = 1, (GetNumEquipmentSets() or 0) do ids[i] = i end
            return ids
        end)
        fill(C, "GetEquipmentSetInfo", function(id)
            local name, icon = GetEquipmentSetInfo(id)
            return name, icon, id
        end)
        fill(C, "GetItemIDs", function(id)
            local name = GetEquipmentSetInfo(id)
            if name and GetEquipmentSetItemIDs then return GetEquipmentSetItemIDs(name) end
            return {}
        end)
    else
        fill(C, "GetEquipmentSetIDs",  function() return {} end)
        fill(C, "GetEquipmentSetInfo", function() return nil end)
        fill(C, "GetItemIDs",          function() return {} end)
    end
end

-------------------------------------------------------------------------
-- 10. Feature-gated modern systems with no WotLK equivalent.
--     Stubbed as "no-op tables" so an accidental reference never nil-errors.
--     (These features are disabled via Expansion.Features on Wrath anyway.)
-------------------------------------------------------------------------
-- IMPORTANT: these are EMPTY tables, not __index-returns-a-function tables.
-- The addon feature-detects with `if C_Bank and C_Bank.FetchFoo then ... end`.
-- A metatable that manufactures a function for every key makes every one of
-- those ~45 guards pass, so the retail branch gets taken and silently returns
-- nil instead of falling through to the working WotLK path. An empty table
-- fails the guards correctly, which is the whole point of the guards.
local function NoopTable(name)
    if type(_G[name]) == "table" then markNative(name); return end
    _G[name] = {}
    markPolyfilled(name)
end
NoopTable("C_Bank")                      -- account/warband bank (11.0)
NoopTable("C_PlayerInteractionManager")  -- (9.0)
NoopTable("C_CurrencyInfo")              -- (8.0) currency feature off on Wrath
NoopTable("C_AuctionHouse")              -- (8.3) new AH

-------------------------------------------------------------------------
-- 11. Assorted global helpers
-------------------------------------------------------------------------
if type(securecallfunction) ~= "function" then
    function securecallfunction(func, ...) return func(...) end
end
if type(RunNextFrame) ~= "function" then
    function RunNextFrame(func) C_Timer.After(0, func) end
end
if type(CopyTable) ~= "function" then
    function CopyTable(src)
        local t = {}
        for k, v in pairs(src) do
            if type(v) == "table" then t[k] = CopyTable(v) else t[k] = v end
        end
        return t
    end
end
if type(Enum) ~= "table" then
    -- Safe stub: Enum.Anything.Whatever resolves to nil instead of erroring.
    Enum = setmetatable({}, { __index = function(t, k)
        local sub = setmetatable({}, { __index = function() return nil end })
        rawset(t, k, sub)
        return sub
    end })
    markPolyfilled("Enum")
end

-------------------------------------------------------------------------
-- 11b. ColorMixin / CreateColor  (Legion 7.0)
--      Needed before the SetGradient polyfill below, which consumes them.
-------------------------------------------------------------------------
if type(CreateColor) == "function" then markNative("CreateColor") else
    markPolyfilled("CreateColor")
    ColorMixin = ColorMixin or {}
    function ColorMixin:GetRGB()  return self.r, self.g, self.b end
    function ColorMixin:GetRGBA() return self.r, self.g, self.b, self.a end
    function ColorMixin:SetRGBA(r, g, b, a) self.r, self.g, self.b, self.a = r, g, b, a end
    function ColorMixin:SetRGB(r, g, b) self:SetRGBA(r, g, b, 1) end
    function ColorMixin:IsEqualTo(o) return o and self.r == o.r and self.g == o.g
                                            and self.b == o.b and self.a == o.a end
    function ColorMixin:GenerateHexColor()
        return ("ff%02x%02x%02x"):format(
            math.floor((self.r or 0) * 255 + 0.5),
            math.floor((self.g or 0) * 255 + 0.5),
            math.floor((self.b or 0) * 255 + 0.5))
    end
    function ColorMixin:WrapTextInColorCode(text)
        return "|c" .. self:GenerateHexColor() .. tostring(text) .. "|r"
    end
    function CreateColor(r, g, b, a)
        local c = Mixin({}, ColorMixin)
        c:SetRGBA(r, g, b, a == nil and 1 or a)
        return c
    end
end

-- Blizzard's global color objects are Legion-era. UI\Footer\Money.lua calls
-- RAID_CLASS_COLORS[class]:WrapTextInColorCode(), but on WotLK those entries are
-- plain {r,g,b,colorStr} tables with no methods -- so mix the behaviour in.
do
    if type(RAID_CLASS_COLORS) == "table" then
        for _, color in pairs(RAID_CLASS_COLORS) do
            if type(color) == "table" and type(color.WrapTextInColorCode) ~= "function" then
                Mixin(color, ColorMixin)
            end
        end
        markPolyfilled("RAID_CLASS_COLORS:ColorMixin")
    end
    for name, rgb in pairs({
        WHITE_FONT_COLOR     = { 1, 1, 1 },
        NORMAL_FONT_COLOR    = { 1, 0.82, 0 },
        HIGHLIGHT_FONT_COLOR = { 1, 1, 1 },
        GRAY_FONT_COLOR      = { 0.5, 0.5, 0.5 },
        RED_FONT_COLOR       = { 1, 0.125, 0.125 },
        GREEN_FONT_COLOR     = { 0.125, 1, 0.125 },
    }) do
        if type(_G[name]) ~= "table" then
            _G[name] = CreateColor(rgb[1], rgb[2], rgb[3], 1)
        elseif type(_G[name].WrapTextInColorCode) ~= "function" then
            Mixin(_G[name], ColorMixin)
        end
    end
end

-------------------------------------------------------------------------
-- 11c. Widget-method polyfills
--      ~310 call sites across the UI use region methods added in 5.0-10.0.
--      Patching the shared metatables once is far safer than editing every
--      site, and it is a no-op wherever Ascension already backported one.
-------------------------------------------------------------------------
-- Wrapped in pcall: this section reaches into widget metatables, and a failure
-- here must not abort the rest of the shim (which would leave the addon running
-- against a half-installed compatibility layer -- far worse than missing one
-- polyfill). Any failure is recorded for the diagnostic report.
local widgetPolyfillOK, widgetPolyfillErr = pcall(function()
    local WHITE = "Interface\\Buttons\\WHITE8x8"

    -- Every widget class has its own metatable; grab each from a throwaway object.
    local probeFrame = _CreateFrame("Frame", nil, UIParent)
    local metas = {}
    local function addMeta(key, obj)
        if not obj then return end
        local mt = getmetatable(obj)
        if mt and type(mt.__index) == "table" then metas[key] = mt.__index end
    end
    -- Each creation is individually guarded: an unsupported widget type on this
    -- client should cost us that one metatable, not the whole section.
    local function tryCreate(...)
        local ok, obj = pcall(_CreateFrame, ...)
        return ok and obj or nil
    end
    addMeta("Texture",     probeFrame:CreateTexture())
    addMeta("FontString",  probeFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal"))
    addMeta("Frame",       probeFrame)
    addMeta("Button",      tryCreate("Button", nil, UIParent))
    addMeta("Cooldown",    tryCreate("Cooldown", nil, UIParent))
    -- These carry their own metatables on some clients, and the addon applies
    -- backdrops to all of them -- the SetBackdropColor crash guard below has to
    -- reach every one.
    addMeta("CheckButton", tryCreate("CheckButton", nil, UIParent))
    addMeta("Slider",      tryCreate("Slider", nil, UIParent))
    addMeta("ScrollFrame", tryCreate("ScrollFrame", nil, UIParent))
    addMeta("EditBox",     tryCreate("EditBox", nil, UIParent))
    addMeta("StatusBar",   tryCreate("StatusBar", nil, UIParent))

    -- Apply `fn` as `name` on each listed metatable that lacks it.
    local function polyfillMethod(classes, name, fn)
        local applied, native = false, false
        for _, class in ipairs(classes) do
            local mt = metas[class]
            if mt then
                if type(rawget(mt, name)) == "function" or type(mt[name]) == "function" then
                    native = true
                else
                    mt[name] = fn
                    applied = true
                end
            end
        end
        if applied then markPolyfilled("widget:" .. name)
        elseif native then markNative("widget:" .. name) end
    end

    -- Region:SetSize / SetShown / SetEnabled  (Cata 4.0 / MoP 5.0)
    polyfillMethod({ "Frame", "Button", "Texture", "FontString", "Cooldown" }, "SetSize",
        function(self, w, h) self:SetWidth(w); self:SetHeight(h) end)
    polyfillMethod({ "Frame", "Button", "Texture", "FontString", "Cooldown" }, "SetShown",
        function(self, shown) if shown then self:Show() else self:Hide() end end)
    polyfillMethod({ "Frame", "Button" }, "SetEnabled",
        function(self, enabled)
            if enabled then if self.Enable then self:Enable() end
            else if self.Disable then self:Disable() end end
        end)

    -- Texture:SetColorTexture  (Legion 7.0) -- a solid fill on WotLK is a white
    -- 8x8 texture tinted with SetVertexColor.
    polyfillMethod({ "Texture" }, "SetColorTexture", function(self, r, g, b, a)
        self:SetTexture(WHITE)
        self:SetVertexColor(r or 1, g or 1, b or 1, a == nil and 1 or a)
    end)

    -- Texture:SetGradient -- must be WRAPPED, not conditionally added.
    -- WotLK already HAS SetGradient, but with the pre-10.0 signature
    -- (orientation, r1,g1,b1, r2,g2,b2) -- seven loose numbers, no alpha.
    -- The addon calls the 10.0 form (orientation, colorObj, colorObj), so a
    -- plain existence check would leave the native method in place and every
    -- call would fail. Detect by argument type and route accordingly.
    if metas.Texture then
        local nativeGradient = metas.Texture.SetGradient
        local nativeGradientAlpha = metas.Texture.SetGradientAlpha
        metas.Texture.SetGradient = function(self, orientation, a, b, ...)
            if type(a) == "table" then
                -- Modern form: two color objects.
                local c1, c2 = a, b
                if not (c1 and c2) then return end
                if nativeGradientAlpha then
                    return nativeGradientAlpha(self, orientation,
                        c1.r or 0, c1.g or 0, c1.b or 0, c1.a == nil and 1 or c1.a,
                        c2.r or 0, c2.g or 0, c2.b or 0, c2.a == nil and 1 or c2.a)
                elseif nativeGradient then
                    return nativeGradient(self, orientation,
                        c1.r or 0, c1.g or 0, c1.b or 0,
                        c2.r or 0, c2.g or 0, c2.b or 0)
                end
                -- No gradient support at all: approximate with the end stop.
                return self:SetVertexColor(c2.r or 0, c2.g or 0, c2.b or 0,
                                           c2.a == nil and 1 or c2.a)
            end
            -- Legacy numeric form: hand straight through.
            if nativeGradient then return nativeGradient(self, orientation, a, b, ...) end
        end
        markPolyfilled("widget:SetGradient")
    end

    -- Texture:SetAtlas  (7.0) -- WotLK has no atlas system. Hide rather than
    -- leave a stale texture showing; callers only use it for decorative icons.
    polyfillMethod({ "Texture" }, "SetAtlas", function(self) self:SetTexture(nil) end)

    -- CheckButton:GetChecked -- must be WRAPPED, not existence-checked.
    -- Pre-Legion it returns 1 or NIL; modern code expects true/false. That
    -- matters here because Database:SetSetting writes the value straight into
    -- the settings table, and assigning nil DELETES the key, so the setting
    -- silently falls back to its default. Net effect: unticking any checkbox in
    -- the options UI appeared to do nothing at all.
    do
        local checkButton = _CreateFrame("CheckButton", nil, UIParent)
        local mt = getmetatable(checkButton)
        local index = mt and type(mt.__index) == "table" and mt.__index or nil
        if index and type(index.GetChecked) == "function" then
            local nativeGetChecked = index.GetChecked
            index.GetChecked = function(self)
                local v = nativeGetChecked(self)
                return (v and v ~= 0) and true or false
            end
            markPolyfilled("widget:GetChecked")
        end
        checkButton:Hide()
    end

    -- Slider:SetObeyStepOnDrag (Cataclysm 4.0). Pre-Cata sliders always snap to
    -- SetValueStep while dragging, so requesting that behaviour is a no-op here.
    -- UI\Controls\Slider.lua calls it unconditionally, and a slider is the third
    -- control in the General settings tab -- so a nil here aborted the entire
    -- settings build and left the popup with tabs but no content.
    do
        local slider = _CreateFrame("Slider", nil, UIParent)
        local mt = getmetatable(slider)
        local index = mt and type(mt.__index) == "table" and mt.__index or nil
        if not index then
            -- Not every widget class exposes a writable __index TABLE. Record it
            -- rather than failing silently: call sites are guarded anyway, but a
            -- missing metatable invalidates every polyfill in this section.
            report.notes[#report.notes + 1] =
                "Slider metatable __index is " ..
                type(mt and mt.__index) .. " -- metatable polyfills unavailable"
        elseif type(index.SetObeyStepOnDrag) ~= "function" then
            index.SetObeyStepOnDrag = function() end
            -- Verify the write actually stuck; some clients protect these tables.
            if type(slider.SetObeyStepOnDrag) == "function" then
                markPolyfilled("widget:SetObeyStepOnDrag")
            else
                report.notes[#report.notes + 1] =
                    "metatable write REJECTED for SetObeyStepOnDrag"
            end
        else
            markNative("widget:SetObeyStepOnDrag")
        end
        slider:Hide()
    end

    -- Frame:SetBackdropColor / SetBackdropBorderColor -- CRASH GUARD.
    --
    -- Pre-Legion these are raw C calls that dereference the frame's backdrop
    -- struct with no null check. Calling either on a frame whose backdrop is
    -- unset (never assigned, or cleared with SetBackdrop(nil)) writes through a
    -- null pointer and takes the whole client down with
    -- "ERROR #132 ACCESS_VIOLATION ... at 0x00000000". On retail the same call
    -- is a harmless no-op, which is why the addon does it freely.
    --
    -- Switching themes does exactly this: Core\Theme.lua clears the backdrop
    -- when moving to the metal theme, and other code then recolours the frame.
    -- There are ~170 SetBackdropColor call sites across 27 files, so guarding
    -- each one is impractical and easy to regress -- guard the method instead.
    do
        -- Backdrop methods live on several widget metatables, and Button /
        -- CheckButton / Slider do not necessarily share Frame's. Wrap each
        -- distinct table once (dedup by identity in case they DO share).
        local wrapped = {}
        for _, mt in pairs(metas) do
            if not wrapped[mt] then
                wrapped[mt] = true
                for _, name in ipairs({ "SetBackdropColor", "SetBackdropBorderColor" }) do
                    local native = rawget(mt, name)
                    if type(native) == "function" then
                        mt[name] = function(self, ...)
                            -- GetBackdrop() is nil when no backdrop is applied.
                            if self.GetBackdrop and not self:GetBackdrop() then return end
                            return native(self, ...)
                        end
                        markPolyfilled("widget:" .. name .. " (crash guard)")
                    end
                end
            end
        end
    end

    -- Cooldown niceties added in MoP 5.0 -- purely visual, safe to ignore.
    polyfillMethod({ "Cooldown" }, "SetDrawEdge", function() end)
    polyfillMethod({ "Cooldown" }, "SetHideCountdownNumbers", function() end)
    polyfillMethod({ "Cooldown" }, "SetDrawSwipe", function() end)

    probeFrame:Hide()
end)
if not widgetPolyfillOK then
    report.notes[#report.notes + 1] = "widget polyfill failed: " .. tostring(widgetPolyfillErr)
end

-------------------------------------------------------------------------
-- 11d. Remaining Legion+ globals with no WotLK equivalent
-------------------------------------------------------------------------

-- SOUNDKIT (7.0). On WotLK PlaySound takes a NAME STRING, not a numeric kit id,
-- so map the ids the addon uses to their 3.3.5a names and keep PlaySound working
-- whichever form it is handed.
if type(SOUNDKIT) == "table" then markNative("SOUNDKIT") else
    markPolyfilled("SOUNDKIT")
    SOUNDKIT = setmetatable({
        IG_BACKPACK_OPEN        = "igBackPackOpen",
        IG_BACKPACK_CLOSE       = "igBackPackClose",
        IG_MAINMENU_OPTION      = "igMainMenuOption",
        IG_CHARACTER_INFO_TAB   = "igCharacterInfoTab",
        IG_MAINMENU_OPEN        = "igMainMenuOpen",
        IG_MAINMENU_CLOSE       = "igMainMenuClose",
        U_CHAT_SCROLL_BUTTON    = "UChatScrollButton",
    }, { __index = function() return "igMainMenuOption" end })

    local _PlaySound = PlaySound
    if type(_PlaySound) == "function" then
        PlaySound = function(sound, ...)
            -- Numeric kit ids don't exist here; swallow them rather than error.
            if type(sound) ~= "string" then return end
            return _PlaySound(sound, ...)
        end
    end
end

-- GameTooltip:SetItemByID (6.0). WotLK can express the same thing with
-- SetHyperlink. Two call sites (TrackedBar, QuestBar) call it unguarded.
do
    local tt = GameTooltip
    if tt and type(tt.SetItemByID) ~= "function" and type(tt.SetHyperlink) == "function" then
        local mt = getmetatable(tt)
        local target = (mt and type(mt.__index) == "table") and mt.__index or tt
        target.SetItemByID = function(self, itemID)
            if not itemID then return end
            local link = select(2, GetItemInfo(itemID)) or ("item:" .. tostring(itemID))
            return self:SetHyperlink(link)
        end
        markPolyfilled("GameTooltip:SetItemByID")
    end
end

-- GetItemInfoInstant (8.0) as a GLOBAL. The C_Item version is filled in above,
-- but Data\GuildBankScanner.lua calls the bare global.
if type(GetItemInfoInstant) ~= "function" then
    markPolyfilled("GetItemInfoInstant")
    function GetItemInfoInstant(item) return C_Item.GetItemInfoInstant(item) end
end

-- BreakUpLargeNumbers (MoP 5.0) -- thousands separators.
if type(BreakUpLargeNumbers) ~= "function" then
    markPolyfilled("BreakUpLargeNumbers")
    function BreakUpLargeNumbers(value)
        local n = tonumber(value)
        if not n then return tostring(value) end
        local int, frac = ("%.0f"):format(math.abs(n)), ""
        local out = int
        while true do
            local replaced
            out, replaced = out:gsub("^(%-?%d+)(%d%d%d)", "%1" .. (LARGE_NUMBER_SEPERATOR or ",") .. "%2")
            if replaced == 0 then break end
        end
        return (n < 0 and "-" or "") .. out .. frac
    end
end

-- UIDropDownMenu argument order flipped in Cataclysm 4.0:
--   pre-Cata : UIDropDownMenu_SetWidth(width, frame, padding)
--              UIDropDownMenu_SetText(text, frame)
--   Cata+    : UIDropDownMenu_SetWidth(frame, width, padding)
--              UIDropDownMenu_SetText(frame, text)
-- All 11 call sites in this addon use the modern order, so on a legacy client
-- the frame lands in the width/text slot and the function errors on `frame:GetName()`.
-- That killed Select:Create for the very first control in the General tab, which
-- aborted the whole settings-frame build: tabs present, content empty.
--
-- Rather than edit every call site, normalize here. Which order the client wants
-- is detected once, by calling the native function the legacy way and seeing if
-- it survives -- passing a number where a frame is expected always errors.
do
    local nativeSetWidth = UIDropDownMenu_SetWidth
    local nativeSetText  = UIDropDownMenu_SetText

    if type(nativeSetWidth) == "function" and type(nativeSetText) == "function" then
        local ok, probe = pcall(_CreateFrame, "Frame", "GudaBagsShimDropdownProbe",
                                UIParent, "UIDropDownMenuTemplate")
        if ok and probe then
            probe:Hide()
            -- Legacy order succeeds only on a legacy client.
            local legacyOrder = pcall(nativeSetWidth, 100, probe)

            -- Accept EITHER order from callers (frame is the table argument),
            -- then forward in whichever order this client actually implements.
            UIDropDownMenu_SetWidth = function(a, b, padding)
                local frame, width
                if type(a) == "table" then frame, width = a, b else width, frame = a, b end
                if legacyOrder then return nativeSetWidth(width, frame, padding) end
                return nativeSetWidth(frame, width, padding)
            end

            UIDropDownMenu_SetText = function(a, b)
                local frame, text
                if type(a) == "table" then frame, text = a, b else text, frame = a, b end
                if legacyOrder then return nativeSetText(text, frame) end
                return nativeSetText(frame, text)
            end

            report.notes[#report.notes + 1] =
                "UIDropDownMenu order: " .. (legacyOrder and "legacy (width,frame)" or "modern (frame,width)")
            markPolyfilled("UIDropDownMenu_SetWidth/SetText")
        end
    end
end

-- GetTimePreciseSec (Legion 7.0). Core\Profiler.lua aliases this at FILE SCOPE
-- (`local GetTime = GetTimePreciseSec`), so a nil here silently breaks every
-- profiling call. GetTime is lower resolution but has the same units/epoch.
if type(GetTimePreciseSec) ~= "function" then
    markPolyfilled("GetTimePreciseSec")
    GetTimePreciseSec = GetTime
end

-- GetMaxPlayerLevel (Cataclysm 4.0). WotLK exposes the cap as a global constant.
-- Ascension may raise or lower it, so read the constant rather than hardcoding 80.
if type(GetMaxPlayerLevel) ~= "function" then
    markPolyfilled("GetMaxPlayerLevel")
    function GetMaxPlayerLevel()
        return MAX_PLAYER_LEVEL
            or (MAX_PLAYER_LEVEL_TABLE and MAX_PLAYER_LEVEL_TABLE[#MAX_PLAYER_LEVEL_TABLE])
            or 80
    end
end

if type(tostringall) ~= "function" then
    markPolyfilled("tostringall")
    function tostringall(...)
        local n = select("#", ...)
        if n == 0 then return end
        local out = {}
        for i = 1, n do out[i] = tostring((select(i, ...))) end
        return unpack(out, 1, n)
    end
end

-------------------------------------------------------------------------
-- 12. Diagnostic report -> saved variable + one chat line
-------------------------------------------------------------------------
do
    local probe = _CreateFrame("Frame")
    probe:RegisterEvent("PLAYER_LOGIN")
    probe:SetScript("OnEvent", function()
        -- NOTE: the third return is the build DATE STRING, not Lua's date().
        -- Naming it `date` shadowed the global and made `date()` a string call,
        -- which aborted this handler before the report was ever saved.
        local ver, build, buildDate, toc = GetBuildInfo()
        report.build = { version = ver, build = build, date = buildDate, tocversion = toc }
        report.usedBackdropTemplate = report._backdropFlag and report._backdropFlag() or false
        report._backdropFlag = nil
        report.time = _G.date and _G.date("%Y-%m-%d %H:%M:%S") or "?"

        -- Count for a compact chat summary
        local nPoly, nNative, nMissing = 0, 0, 0
        for _ in pairs(report.polyfilled)     do nPoly = nPoly + 1 end
        for _ in pairs(report.native)         do nNative = nNative + 1 end
        for _ in pairs(report.missingGlobals) do nMissing = nMissing + 1 end

        GudaBagsShim_DB = report

        local msg = ("|cff00ccffGudaBags shim|r loaded: %d polyfilled, %d native"):format(nPoly, nNative)
        if nMissing > 0 then
            local names = {}
            for g in pairs(report.missingGlobals) do names[#names + 1] = g end
            msg = msg .. ("  |cffff5555%d MISSING globals: %s|r"):format(nMissing, table.concat(names, ", "))
        end
        DEFAULT_CHAT_FRAME:AddMessage(msg)
    end)
end
