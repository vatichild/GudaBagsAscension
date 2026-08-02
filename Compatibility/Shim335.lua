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

-- Sound playback for the whole addon. Defined UP HERE, before any polyfill can
-- fail, because it is called from click handlers: if anything below aborts this
-- file part-way, a missing sound must not turn into "attempt to call method
-- 'PlaySound' (a nil value)" on every button press. ns.Sounds is filled in by
-- the SOUNDKIT section further down; until then every id is simply nil and this
-- is a no-op.
--
-- Never touches the global PlaySound: Blizzard code and other addons call that
-- too, and swallowing their errors is not ours to decide.
function ns:PlaySound(kit)
    if kit == nil then return end
    pcall(_G.PlaySound, kit)
end
ns.Sounds = {}

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
-- 0b. Probe container -- EVERY throwaway frame this file creates lives here
-------------------------------------------------------------------------
-- This shim answers "does the client have X?" by trying to create X. Those
-- probe frames are never meant to be seen, but two of them used to be parented
-- to UIParent and never hidden, because `pcall(_CreateFrame, ...)` was used
-- purely for its boolean and the frame it returned was dropped on the floor.
--
-- One of those was `CreateFrame("Button", nil, UIParent, "NineSlicePanelTemplate")`.
-- A NineSlice panel anchors to fill its parent, so on UIParent it became a
-- FULL-SCREEN frame -- and buttons are mouse-enabled by default. The result was
-- an invisible, screen-sized click sponge: no targeting, no camera, no action
-- bars, and no Lua error to explain any of it.
--
-- Parenting probes to a HIDDEN frame fixes the whole class: a child of a hidden
-- frame can never render or take input no matter what its template anchors to.
-- Hiding each probe individually is not enough, because the actual defect was
-- probes that were never captured in order to be hidden.
local PROBE_PARENT = _CreateFrame("Frame", "GudaBagsShimProbeContainer", UIParent)
PROBE_PARENT:SetWidth(1)
PROBE_PARENT:SetHeight(1)
PROBE_PARENT:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
PROBE_PARENT:EnableMouse(false)
PROBE_PARENT:Hide()

--- Create a throwaway probe frame: parked, hidden, mouse-disabled, and tagged so
--- diagnostics can attribute it to us. Returns nil if the type/template is
--- unsupported, which is exactly the capability answer callers want.
local function CreateProbe(frameType, template)
    local ok, frame = pcall(_CreateFrame, frameType, nil, PROBE_PARENT, template)
    if not ok or not frame then return nil end
    if frame.Hide then frame:Hide() end
    if frame.EnableMouse then frame:EnableMouse(false) end
    -- Without this the frame reports tagged=false in /gbdiag, identical to a
    -- foreign frame -- which cost several rounds of misattribution.
    frame._gbCreatedBy = "Shim335 probe (" .. tostring(template or frameType) .. ")"
    return frame
end

-------------------------------------------------------------------------
-- 1. C_Timer  (WoD 6.0) -- OnUpdate-driven scheduler
-------------------------------------------------------------------------
-- Filled member by member, NOT all-or-nothing. This used to skip the whole
-- block when C_Timer.After existed, which left NewTicker/NewTimer nil on any
-- client that backported only part of the namespace -- and Ascension's C_Timer
-- is exactly that kind of partial table. Anything calling the missing member
-- then died at the call site, far from here.
if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
    markNative("C_Timer")
end
do
    C_Timer = C_Timer or {}
    local timers = {}
    local driver = _CreateFrame("Frame")
    -- Parked until something is actually scheduled, and re-parked when the
    -- queue drains, so a client with a fully native C_Timer pays nothing and
    -- an idle queue does not tick (Rule 2).
    driver:Hide()
    driver:SetScript("OnUpdate", function(self)
        if #timers == 0 then self:Hide() return end
        local now = GetTime()
        for i = #timers, 1, -1 do
            local t = timers[i]
            if t.cancelled then
                table.remove(timers, i)
            elseif now >= t.at then
                local ok, err = pcall(t.func, t)
                if not ok then
                    -- This used to go ONLY into report.notes, which is not
                    -- readable until the saved variable is written at logout.
                    -- A timer callback failing 10x a second was therefore
                    -- completely silent in game, and callbacks that set up
                    -- state before failing left that state stranded. Route it
                    -- to ErrorSink (deduped and rate-capped there) so /gberrors
                    -- sees it; keep the note for failures raised before
                    -- ErrorSink has loaded.
                    if ns and ns.ErrorSink then
                        ns.ErrorSink:Capture(err, "C_Timer callback")
                    else
                        report.notes[#report.notes + 1] = "timer error: " .. tostring(err)
                    end
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
    local function schedule(t) timers[#timers + 1] = t; driver:Show(); return t end
    local function makeCancelable(t)
        t.Cancel = function(self) self.cancelled = true end
        t.IsCancelled = function(self) return self.cancelled == true end
        return t
    end
    -- Record each member we actually had to supply, so the report distinguishes
    -- "C_Timer is native" from "C_Timer exists but was missing NewTicker".
    local function fillTimer(key, fn)
        if type(C_Timer[key]) ~= "function" then
            markPolyfilled("C_Timer." .. key)
        end
        fill(C_Timer, key, fn)
    end

    fillTimer("After", function(seconds, func)
        schedule({ at = GetTime() + (seconds or 0), func = func })
    end)
    fillTimer("NewTimer", function(seconds, func)
        return makeCancelable(schedule({ at = GetTime() + (seconds or 0), func = func }))
    end)
    fillTimer("NewTicker", function(seconds, func, iterations)
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
    -- Was: pcall(_CreateFrame, "Frame", nil, UIParent, "ButtonFrameTemplate"),
    -- which leaked a shown ~338x424 panel onto UIParent on every login.
    local hasButtonFrameTemplate = CreateProbe("Frame", "ButtonFrameTemplate") ~= nil

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

        -- The title gets its OWN child frame instead of living on the popup.
        --
        -- Core\Theme.lua's retail theme adds a metal frame (EnsureMetalFrame) as a
        -- child at the SAME frame level as the popup, and its top bar is an OVERLAY
        -- texture. Regions of same-level frames sort by draw layer, so an ARTWORK
        -- FontString on the popup itself always loses to that band -- the settings
        -- and category-editor titles were drawn behind the retail title bar.
        -- A child frame can be raised above the metal; Core\Theme.lua's
        -- ApplyPopupTheme does that (the popup's own level is only set after
        -- construction, so the level cannot be fixed here).
        --
        -- EnableMouse(false): the settings popup puts an invisible drag region over
        -- the same 24px band (UI\SettingsPopup.lua), which must keep its clicks.
        local titleHost = _CreateFrame("Frame", nil, frame)
        titleHost:EnableMouse(false)
        titleHost:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
        titleHost:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
        titleHost:SetHeight(30)
        frame.TitleHost = titleHost

        local title = titleHost:CreateFontString(name and (name .. "TitleText") or nil,
                                                 "OVERLAY", "GameFontNormal")
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
        -- The substitute has no portrait and no button bar, so hiding them is a
        -- no-op. Methods, not globals -- see the note where the old global
        -- overrides used to live.
        function frame:HidePortrait() end
        function frame:HideButtonBar() end

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
        -- THE BUG THAT BROKE THE MOUSE. This used to be
        --     pcall(_CreateFrame, "Button", nil, UIParent, name)
        -- using only the boolean and discarding the frame. For
        -- NineSlicePanelTemplate -- which this client HAS -- that produced a
        -- Button anchored to fill UIParent, mouse-enabled by default, shown
        -- forever: an invisible full-screen click sponge with no error to trace.
        local function templateExists(name)
            return CreateProbe("Button", name) ~= nil
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

    -- NOTE: this is deliberately NOT assigned to the global `CreateFrame`.
    --
    -- It used to be, and that made GudaBags the owner of every frame creation in
    -- the client -- Blizzard's FrameXML, Ascension's own Lua UI, every other
    -- addon. Secure code that calls an addon-owned global has its execution
    -- tainted for the rest of its scope, and the next protected call in that
    -- scope is blocked and blamed on us. That is what produced
    -- "AddOn 'GudaBags' tainted the call of the secure function 'IsResponseSeen()'"
    -- when opening the GM ticket UI (IsResponseSeen is Ascension's own protected
    -- C_GMTicket function; its caller creates frames).
    --
    -- Nothing here was ever needed by a non-GudaBags caller: this client is
    -- 3.3.5a, so no Blizzard code passes BackdropTemplate or any other post-4.0
    -- template name. Every file in the addon takes it as a file-local instead:
    --     local CreateFrame = ns.CreateFrame or CreateFrame
    ns.CreateFrame = function(frameType, name, parent, template, id)
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

        -- Every frame the addon owns gets the backdrop crash guard stamped on it
        -- (see section 11d). Blizzard's frames must not, which is exactly why
        -- the guard cannot live on the shared widget metatables any more.
        if frame and ns.GuardBackdrop then ns.GuardBackdrop(frame) end

        -- Record WHERE a top-level frame came from.
        --
        -- A shown, mouse-enabled frame parented directly to UIParent can swallow
        -- every click in the game while producing no error, no log line and no
        -- visible artifact. If it is also unnamed there is nothing to grep for,
        -- which has cost several debugging rounds. Frames parented to UIParent
        -- are rare, so capturing one stack line each is cheap, and it turns
        -- "some anonymous Button" into a file and line number.
        if parent == UIParent and frame and debugstack then
            local ok, stack = pcall(debugstack, 2, 2, 0)
            if ok then frame._gbCreatedBy = stack end
        end

        return frame
    end

    if not hasButtonFrameTemplate then markPolyfilled("ButtonFrameTemplate") end

    -- Chrome helpers.
    --
    -- These used to be assigned to the FrameXML GLOBALS
    -- ButtonFrameTemplate_HidePortrait / _HideButtonBar, unconditionally, so
    -- every Blizzard caller of them ran GudaBags Lua and picked up our taint.
    -- The reason they existed is real but narrow: we always substitute
    -- ButtonFrameTemplate, so OUR frames lack the portrait/button-bar children
    -- the stock helpers dereference and the stock version would nil-error.
    --
    -- That is a property of our substitute frames, so it belongs on the
    -- substitute frames. buildButtonFrameSubstitute installs them as methods
    -- (see :HidePortrait / :HideButtonBar there) and the addon's six call sites
    -- call the method. Blizzard's globals are left alone.

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
-- securecallfunction is deliberately NOT defined here.
--
-- The shim used to publish `function securecallfunction(func, ...) return func(...) end`
-- -- a security-named global that provides no security whatsoever. Nothing in
-- GudaBags calls it (grep: zero sites), so it bought nothing, and leaving a
-- fake behind for some other addon to find is worse than leaving it missing.
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
--
-- ColorMixin is defined UNCONDITIONALLY, and that is the whole point.
--
-- It used to live inside the "CreateColor is missing" branch below. This client
-- HAS CreateColor but NOT ColorMixin, so that branch was skipped, ColorMixin
-- stayed nil, and the RAID_CLASS_COLORS loop right after called Mixin(color, nil).
-- Ascension's Mixin asserts on a nil mixin, and the assert killed the main chunk
-- of this file: every polyfill past that point (11c widget methods, 11d SOUNDKIT
-- and friends, the sort no-ops, and the diagnostic report itself) silently never
-- ran. Two "existence" checks, CreateColor and ColorMixin, were treated as one.
--
-- The methods live in a file-local table we own outright, and the global is only
-- set when the client has none -- writing into a table this addon did not create
-- is exactly the trap that cost a day on SOUNDKIT.
local ColorMethods = {}
function ColorMethods:GetRGB()  return self.r, self.g, self.b end
function ColorMethods:GetRGBA() return self.r, self.g, self.b, self.a end
function ColorMethods:SetRGBA(r, g, b, a) self.r, self.g, self.b, self.a = r, g, b, a end
function ColorMethods:SetRGB(r, g, b) self:SetRGBA(r, g, b, 1) end
function ColorMethods:IsEqualTo(o) return o and self.r == o.r and self.g == o.g
                                        and self.b == o.b and self.a == o.a end
function ColorMethods:GenerateHexColor()
    return ("ff%02x%02x%02x"):format(
        math.floor((self.r or 0) * 255 + 0.5),
        math.floor((self.g or 0) * 255 + 0.5),
        math.floor((self.b or 0) * 255 + 0.5))
end
function ColorMethods:WrapTextInColorCode(text)
    return "|c" .. self:GenerateHexColor() .. tostring(text) .. "|r"
end

if type(ColorMixin) == "table" then
    markNative("ColorMixin")
else
    markPolyfilled("ColorMixin")
    ColorMixin = ColorMethods
end

-- Mix ColorMethods (never the global, which may be the client's own and may be
-- missing the methods we rely on) into a plain colour table. Nil-safe: a colour
-- table that never gains WrapTextInColorCode is a cosmetic loss, not a reason to
-- abort the file.
local function MixinColorMethods(t)
    if type(t) ~= "table" then return end
    if type(Mixin) == "function" then
        pcall(Mixin, t, ColorMethods)
    else
        for name, fn in pairs(ColorMethods) do
            if t[name] == nil then t[name] = fn end
        end
    end
end

if type(CreateColor) == "function" then markNative("CreateColor") else
    markPolyfilled("CreateColor")
    function CreateColor(r, g, b, a)
        local c = {}
        MixinColorMethods(c)
        c:SetRGBA(r, g, b, a == nil and 1 or a)
        return c
    end
end

-- Blizzard's global colour objects are Legion-era. UI\Footer\Money.lua calls
-- RAID_CLASS_COLORS[class]:WrapTextInColorCode(), but on WotLK those entries are
-- plain {r,g,b,colorStr} tables with no methods.
--
-- This used to mix the methods straight INTO Blizzard's tables. Writing into a
-- table this addon did not create is the trap that cost a day on SOUNDKIT, and
-- here it is worse than cosmetic: an addon-authored field on a Blizzard global
-- makes that global tainted for every Blizzard reader of it.
--
-- So we never touch them. ns.ClassColor / ns.FontColor return addon-owned
-- clones, built once on first use and cached. Blizzard's globals stay read-only
-- to us. Call sites: ns.ClassColor(classToken), ns.FontColor("NORMAL"), ...
do
    local FONT_COLOR_FALLBACK = {
        WHITE     = { 1, 1, 1 },
        NORMAL    = { 1, 0.82, 0 },
        HIGHLIGHT = { 1, 1, 1 },
        GRAY      = { 0.5, 0.5, 0.5 },
        RED       = { 1, 0.125, 0.125 },
        GREEN     = { 0.125, 1, 0.125 },
    }

    -- Copy the plain data out of a Blizzard colour table into one of ours.
    local function cloneColor(src, r, g, b, a)
        local c = {}
        MixinColorMethods(c)
        if type(src) == "table" then
            c:SetRGBA(src.r or r or 1, src.g or g or 1, src.b or b or 1,
                      src.a == nil and (a == nil and 1 or a) or src.a)
            c.colorStr = src.colorStr
        else
            c:SetRGBA(r or 1, g or 1, b or 1, a == nil and 1 or a)
        end
        return c
    end

    local classCache = {}
    function ns.ClassColor(classToken)
        if not classToken then return nil end
        local cached = classCache[classToken]
        if cached then return cached end
        local src = type(RAID_CLASS_COLORS) == "table" and RAID_CLASS_COLORS[classToken] or nil
        if not src then return nil end
        cached = cloneColor(src)
        classCache[classToken] = cached
        return cached
    end

    local fontCache = {}
    function ns.FontColor(key)
        local cached = fontCache[key]
        if cached then return cached end
        local rgb = FONT_COLOR_FALLBACK[key] or FONT_COLOR_FALLBACK.WHITE
        cached = cloneColor(_G[key .. "_FONT_COLOR"], rgb[1], rgb[2], rgb[3], 1)
        fontCache[key] = cached
        return cached
    end

    markPolyfilled("ns.ClassColor/ns.FontColor")
end

-------------------------------------------------------------------------
-- 11c. Widget-method polyfills
--      ~310 call sites across the UI use region methods added in 5.0-10.0.
--      Adding a MISSING method to a shared metatable is safe: a client that
--      never had the method has no code that calls it, so only we ever reach it.
--
--      WRAPPING an existing method is not, and nothing in this section does it
--      any more. A wrapper on a shared metatable runs GudaBags Lua for every
--      Blizzard widget in the client, which taints secure execution -- see
--      Core\Utils.lua for GetChecked/SetGradient and section 11c-bis for the
--      backdrop crash guard, both of which moved out of here for that reason.
-------------------------------------------------------------------------
-- Wrapped in pcall: this section reaches into widget metatables, and a failure
-- here must not abort the rest of the shim (which would leave the addon running
-- against a half-installed compatibility layer -- far worse than missing one
-- polyfill). Any failure is recorded for the diagnostic report.
local widgetPolyfillOK, widgetPolyfillErr = pcall(function()
    local WHITE = "Interface\\Buttons\\WHITE8x8"

    -- Every widget class has its own metatable; grab each from a throwaway object.
    -- All of these are parked under PROBE_PARENT (hidden), never UIParent.
    local probeFrame = CreateProbe("Frame")
    local metas = {}
    local function addMeta(key, obj)
        if not obj then return end
        local mt = getmetatable(obj)
        if mt and type(mt.__index) == "table" then metas[key] = mt.__index end
    end
    -- Each creation is individually guarded: an unsupported widget type on this
    -- client should cost us that one metatable, not the whole section.
    addMeta("Texture",     probeFrame:CreateTexture())
    addMeta("FontString",  probeFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal"))
    addMeta("Frame",       probeFrame)
    addMeta("Button",      CreateProbe("Button"))
    addMeta("Cooldown",    CreateProbe("Cooldown"))
    -- CheckButton / Slider / ScrollFrame / EditBox / StatusBar used to be probed
    -- here too, purely so the SetBackdropColor crash guard could reach every
    -- metatable. That guard is per-instance now (section 11c-bis), so those five
    -- probe frames were five frames created at login for nothing.

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

    -- Animation:SetFromAlpha / SetToAlpha  (Cata 4.0)
    --
    -- WotLK has animations, but an Alpha animation is expressed as a single
    -- SetChange(delta) applied to the region's CURRENT alpha -- there is no
    -- absolute from/to. Remember whichever endpoint was set and convert as soon
    -- as both are known, so the retail two-call form keeps working.
    --
    -- The Alpha metatable is not reachable from a frame: it needs an actual
    -- animation, which needs an animation group. Guarded like every other probe
    -- here, since a client without animations must cost only this polyfill.
    do
        local okAnim, anim = pcall(function()
            return probeFrame:CreateAnimationGroup():CreateAnimation("Alpha")
        end)
        if okAnim and anim then
            local mt = getmetatable(anim)
            if mt and type(mt.__index) == "table" then
                metas.Alpha = mt.__index

                local function applyChange(self)
                    -- Only once both ends are known; a lone SetFromAlpha says
                    -- nothing about the delta.
                    if self.__gbFromAlpha and self.__gbToAlpha and self.SetChange then
                        self:SetChange(self.__gbToAlpha - self.__gbFromAlpha)
                    end
                end
                polyfillMethod({ "Alpha" }, "SetFromAlpha", function(self, v)
                    self.__gbFromAlpha = v
                    applyChange(self)
                end)
                polyfillMethod({ "Alpha" }, "SetToAlpha", function(self, v)
                    self.__gbToAlpha = v
                    applyChange(self)
                end)
            end
        end
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

    -- Texture:SetGradient and CheckButton:GetChecked are NOT patched here.
    --
    -- Both used to be wrapped over the native on the shared widget metatable,
    -- because in both cases WotLK HAS the method but with the wrong shape:
    --   SetGradient  -- pre-10.0 takes (orientation, r1,g1,b1, r2,g2,b2); the
    --                   addon calls the 10.0 form (orientation, color, color).
    --   GetChecked   -- pre-Legion returns 1/nil, not true/false, and nil
    --                   assigned into the settings table DELETES the key, so
    --                   unticking any checkbox appeared to do nothing.
    -- Both problems are real. But a wrapper on the shared metatable means every
    -- Blizzard widget in the client runs GudaBags Lua on those calls -- Blizzard
    -- reads :GetChecked() constantly -- and that leaks taint into secure code.
    --
    -- They are OUR call-shape problems, so they are fixed at OUR call sites:
    -- ns.Utils:GetChecked(button) and ns.Utils:SetGradient(texture, ...) in
    -- Core\Utils.lua. Blizzard's methods stay native.

    -- Texture:SetAtlas  (7.0) -- WotLK has no atlas system. Hide rather than
    -- leave a stale texture showing; callers only use it for decorative icons.
    polyfillMethod({ "Texture" }, "SetAtlas", function(self) self:SetTexture(nil) end)

    -- Slider:SetObeyStepOnDrag (Cataclysm 4.0). Pre-Cata sliders always snap to
    -- SetValueStep while dragging, so requesting that behaviour is a no-op here.
    --
    -- Reported only, never written. A no-op written into the shared Slider
    -- metatable put GudaBags on the call path of every Blizzard slider in the
    -- client -- for a method that does nothing. UI\Controls\Slider.lua and
    -- UI\CategoryEditor.lua nil-guard the call instead, which is correct on a
    -- client where the behaviour is already the default.
    do
        local slider = CreateProbe("Slider")
        local mt = getmetatable(slider)
        local index = mt and type(mt.__index) == "table" and mt.__index or nil
        if not index then
            -- Not every widget class exposes a writable __index TABLE. Record it
            -- rather than failing silently: call sites are guarded anyway, but a
            -- missing metatable invalidates every polyfill in this section.
            report.notes[#report.notes + 1] =
                "Slider metatable __index is " ..
                type(mt and mt.__index) .. " -- metatable polyfills unavailable"
        elseif type(index.SetObeyStepOnDrag) == "function" then
            markNative("widget:SetObeyStepOnDrag")
        else
            report.missingGlobals["widget:SetObeyStepOnDrag"] = true
        end
        slider:Hide()
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
-- 11c-bis. SetBackdropColor / SetBackdropBorderColor CRASH GUARD.
--
-- Pre-Legion these are raw C calls that dereference the frame's backdrop
-- struct with no null check. Calling either on a frame whose backdrop is unset
-- (never assigned, or cleared with SetBackdrop(nil)) writes through a null
-- pointer and takes the whole client down with
-- "ERROR #132 ACCESS_VIOLATION ... at 0x00000000". On retail the same call is a
-- harmless no-op, which is why the addon does it freely. Core\Theme.lua clears
-- the backdrop on a theme switch and other code then recolours the frame, so
-- this is reachable in normal use, and there are ~170 recolour call sites.
--
-- This used to wrap the method on every shared widget metatable. That fixed the
-- crash and created a worse problem: every Blizzard frame in the client then ran
-- GudaBags Lua on those calls, which taints secure execution.
--
-- So the guard is stamped PER INSTANCE, from ns.CreateFrame, on frames we own.
-- An instance field shadows the metatable method, so Blizzard's frames keep the
-- native and ours get the null check.
--
-- Allocation shape matters here (RULES.md Rule 2): ~750 item buttons are
-- pre-warmed, so this is two module-level closures plus one weak cache keyed by
-- metatable -- NOT a closure pair per frame.
-------------------------------------------------------------------------
do
    local nativesByIndex = setmetatable({}, { __mode = "k" })

    local function nativesFor(frame)
        local mt = getmetatable(frame)
        local index = mt and type(mt.__index) == "table" and mt.__index or nil
        if not index then return nil end
        local entry = nativesByIndex[index]
        if entry == nil then
            entry = {
                color  = index.SetBackdropColor,
                border = index.SetBackdropBorderColor,
            }
            nativesByIndex[index] = entry
        end
        return entry
    end

    local function guardedSetBackdropColor(self, ...)
        -- GetBackdrop() is nil when no backdrop is applied.
        if self.GetBackdrop and not self:GetBackdrop() then return end
        local n = nativesFor(self)
        if n and n.color then return n.color(self, ...) end
    end

    local function guardedSetBackdropBorderColor(self, ...)
        if self.GetBackdrop and not self:GetBackdrop() then return end
        local n = nativesFor(self)
        if n and n.border then return n.border(self, ...) end
    end

    -- Idempotent: safe to call again on a frame that already carries the guard.
    function ns.GuardBackdrop(frame)
        if not frame or frame.__gbBackdropGuarded then return end
        local n = nativesFor(frame)
        if not n or not (n.color or n.border) then return end
        frame.__gbBackdropGuarded = true
        if n.color  then frame.SetBackdropColor       = guardedSetBackdropColor end
        if n.border then frame.SetBackdropBorderColor = guardedSetBackdropBorderColor end
    end

    markPolyfilled("backdrop crash guard (per-instance)")
end

-------------------------------------------------------------------------
-- 11d. Remaining Legion+ globals with no WotLK equivalent
-------------------------------------------------------------------------

-- SOUNDKIT (7.0) -> ns.Sounds.
--
-- Resolved into a table of OUR OWN. Two earlier attempts wrote into the client's
-- SOUNDKIT with rawset instead, and both failed the same way: a client-provided
-- enum table can be read-only, the rawset throws, and the throw aborts the REST
-- OF THIS FILE. That is why ns:PlaySound ended up nil while the sound keys still
-- looked unfixed -- one silent error, two misleading symptoms. Never write to a
-- table this addon does not own.
--
-- Three clients to satisfy:
--  * Stock 3.3.5a: no SOUNDKIT at all, and PlaySound takes a NAME STRING.
--  * Ascension: ships a 771-entry SOUNDKIT with its own naming and NO IG_* keys,
--    so every retail name resolves to nil.
--  * Anything later that renames again: falls through to the 3.3.5a name, and
--    ns:PlaySound pcalls, so the worst case is a missing click noise.
--
-- Candidates are tried in order: retail name first (so a client that does ship
-- the retail key wins), then the names this client really has, verified against
-- the SOUNDKIT dump in the GudaBagsProbe saved variables.
local SOUND_CANDIDATES = {
    RESTACK     = { "IG_BACKPACK_OPEN",      "UI_BAGSORTING_01", "PUT_DOWN_BAG", "PICK_UP_BAG" },
    MENU_OPTION = { "IG_MAINMENU_OPTION",    "UIMAINMENUBUTTONA", "CHAT_SCROLL_BUTTON" },
    TAB         = { "IG_CHARACTER_INFO_TAB", "CHARACTER_SHEET_TAB", "UCHARACTERSHEETTAB" },
}

-- Last resort: stock 3.3.5a PlaySound name strings.
local SOUND_NAMES_335 = {
    RESTACK     = "igBackPackOpen",
    MENU_OPTION = "igMainMenuOption",
    TAB         = "igCharacterInfoTab",
}

do
    local kit = type(SOUNDKIT) == "table" and SOUNDKIT or nil
    if kit then markNative("SOUNDKIT") else markPolyfilled("SOUNDKIT") end

    for name, candidates in pairs(SOUND_CANDIDATES) do
        local resolved
        if kit then
            for _, key in ipairs(candidates) do
                -- pcall: reading a protected table can throw just like writing one.
                local ok, value = pcall(function() return kit[key] end)
                if ok and value ~= nil then
                    resolved = value
                    markNative("sound:" .. name .. " = SOUNDKIT." .. key)
                    break
                end
            end
        end
        if resolved == nil then
            resolved = SOUND_NAMES_335[name]
            markPolyfilled("sound:" .. name .. " = " .. tostring(resolved))
        end
        ns.Sounds[name] = resolved
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

            -- Published on ns, NOT assigned back over the FrameXML globals.
            --
            -- Overwriting the globals put GudaBags on the call path of every
            -- Blizzard dropdown in the client, for a problem that is purely
            -- ours: our 7 call sites use the modern order. The addon calls
            -- ns.DropDownSetWidth / ns.DropDownSetText instead.
            ns.DropDownSetWidth = function(frame, width, padding)
                if legacyOrder then return nativeSetWidth(width, frame, padding) end
                return nativeSetWidth(frame, width, padding)
            end

            ns.DropDownSetText = function(frame, text)
                if legacyOrder then return nativeSetText(text, frame) end
                return nativeSetText(frame, text)
            end

            report.notes[#report.notes + 1] =
                "UIDropDownMenu order: " .. (legacyOrder and "legacy (width,frame)" or "modern (frame,width)")
            markPolyfilled("ns.DropDownSetWidth/SetText")
        end
    end

    -- The probe can fail (no UIDropDownMenuTemplate, or the natives are absent).
    -- Call sites must still be callable, so fall back to the modern order --
    -- which is what this client reports anyway.
    if not ns.DropDownSetWidth then
        ns.DropDownSetWidth = function(frame, width, padding)
            if nativeSetWidth then return nativeSetWidth(frame, width, padding) end
        end
        ns.DropDownSetText = function(frame, text)
            if nativeSetText then return nativeSetText(frame, text) end
        end
        report.notes[#report.notes + 1] = "UIDropDownMenu order: probe failed, assuming modern"
    end
end

-- GetTimePreciseSec (Legion 7.0). Core\Profiler.lua aliases this at FILE SCOPE
-- (`local GetTime = GetTimePreciseSec`), so a nil here silently breaks every
-- profiling call. GetTime is lower resolution but has the same units/epoch.
if type(GetTimePreciseSec) ~= "function" then
    markPolyfilled("GetTimePreciseSec")
    GetTimePreciseSec = GetTime
end

-- MuteSoundFile / UnmuteSoundFile (Legion 7.x). No pre-Legion equivalent.
--
-- These are why sorting only ever moved ONE item. Sorting\SortEngine.lua mutes
-- pickup sounds after its first successful move:
--     if not soundsMuted then MutePickupSounds(); soundsMuted = true end
-- With MuteSoundFile nil that raised inside the sort coroutine, so the driver
-- aborted the pass and called FinishSort("Sort error: ...") -- and FinishSort
-- itself calls UnmutePickupSounds() at its line 1392, which raised AGAIN on
-- UnmuteSoundFile and killed FinishSort before its ns:Print(message) on 1396.
-- Hence one item moved, no error text in chat, and a half-reset sort state
-- (ClearCache and the ITEM_LOCK_CHANGED unregister were skipped too).
--
-- Muting is purely cosmetic -- it suppresses the item pickup sound during a
-- sort. No-ops restore the whole sort path; the only consequence on this client
-- is that sorting is audible.
if type(MuteSoundFile) ~= "function" then
    markPolyfilled("MuteSoundFile")
    function MuteSoundFile() end
end
if type(UnmuteSoundFile) ~= "function" then
    markPolyfilled("UnmuteSoundFile")
    function UnmuteSoundFile() end
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
