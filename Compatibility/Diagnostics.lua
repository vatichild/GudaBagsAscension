-- GudaBags Diagnostics (3.3.5a port aid)
-- =====================================================================
-- /guda diag  -- inspect what the settings popup ACTUALLY built.
--
-- "The frame is empty" has many possible causes: content never created, created
-- but zero-sized, created but hidden, or created off-screen. Guessing between
-- them from a screenshot wastes a client run each time, so measure instead.
-- Results go to chat AND to the GudaBags_Diag saved variable.
--
-- NO SlashCmdList KEY OF ITS OWN. This file used to own /gbdiag and /gbtrace.
-- 3.3.5a's ChatEdit_ParseText dispatches a slash command by walking
-- pairs(SlashCmdList) and reading _G["SLASH_"..key..i] until one matches, so
-- every key an addon owns is a chance for a MACRO's execution to read an
-- addon-tainted value before it reaches the command it was actually looking
-- for. When that command is a protected one (/cast, /castsequence) the client
-- blocks it and names us:
--   "An action was blocked because of taint from GudaBags - CastSpellByName()"
-- Both entry points now hang off ns and are reached through the single /guda
-- key in Core\SlashCommands.lua. See ns.Diagnostics below.
-- =====================================================================

local addonName, ns = ...

local Diagnostics = {}
ns.Diagnostics = Diagnostics

local CreateFrame = ns.CreateFrame or CreateFrame

local report = {}

-------------------------------------------------
-- Crash-surviving trace
-------------------------------------------------
-- SavedVariables are NOT flushed when the client crashes, so anything written
-- to GudaBags_Diag dies with it. The one channel that DOES survive is the crash
-- dump's own "Last FrameScript_Execute" field, which records the last string
-- the client executed as a script. Pushing a marker through RunScript therefore
-- leaves a breadcrumb readable in Errors\*.txt after the fact.
--
-- Enable with /guda trace on. Off by default -- it is a debugging aid, not
-- something to leave running.
local traceEnabled = false
local traceRing, traceIndex, TRACE_MAX = {}, 0, 60

function ns.Trace(fmt, ...)
    if not traceEnabled then return end
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then msg = tostring(fmt) end

    traceIndex = traceIndex + 1
    traceRing[(traceIndex - 1) % TRACE_MAX + 1] = msg

    -- Survives the crash: shows up as Last FrameScript_Execute in the dump.
    -- Comment-only body so it cannot have side effects.
    if RunScript then
        pcall(RunScript, "--[[GB:" .. msg:gsub("[%[%]]", "") .. "]]")
    end
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff888888[gb]|r " .. msg)
    end
end

--- /guda trace [on|off|dump]
function Diagnostics:Trace(arg)
    if arg == "off" then
        traceEnabled = false
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffGudaBags|r trace |cffff5555off|r.")
    elseif arg == "dump" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffGudaBags|r last " ..
            math.min(traceIndex, TRACE_MAX) .. " trace line(s):")
        for i = 1, math.min(traceIndex, TRACE_MAX) do
            local idx = (traceIndex - math.min(traceIndex, TRACE_MAX) + i - 1) % TRACE_MAX + 1
            if traceRing[idx] then
                DEFAULT_CHAT_FRAME:AddMessage("  " .. i .. ". " .. traceRing[idx])
            end
        end
    else
        traceEnabled = true
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff00ccffGudaBags|r trace |cff33ff33on|r. Markers also land in the crash dump " ..
            "as 'Last FrameScript_Execute'. |cffffff00/guda trace off|r to stop.")
    end
end

local function line(fmt, ...)
    local msg = select("#", ...) > 0 and fmt:format(...) or fmt
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[diag]|r " .. msg)
    report[#report + 1] = msg
end

--- Frame geometry in one string. nil-safe: a missing frame is itself a finding.
local function describeFrame(label, f)
    if not f then return label .. " = nil" end
    local ok, w, h = pcall(function() return f:GetWidth(), f:GetHeight() end)
    if not ok then return label .. " = <error reading size>" end
    local shown = f.IsShown and f:IsShown() and "shown" or "HIDDEN"
    local numPoints = f.GetNumPoints and f:GetNumPoints() or -1
    local kids = 0
    if f.GetChildren then
        local children = { f:GetChildren() }
        kids = #children
    end
    local regions = 0
    if f.GetRegions then
        local r = { f:GetRegions() }
        regions = #r
    end
    return ("%s: %.0fx%.0f %s points=%d children=%d regions=%d")
        :format(label, w or 0, h or 0, shown, numPoints, kids, regions)
end

-- NOTE: does NOT reset `report`. Only the slash-command entry points clear it.
-- This used to start with `report = {}`, which silently erased everything the
-- earlier passes had collected -- the build stamp, the mouse-blocker scan and
-- the children dump all vanished, and the saved output always began at
-- "SettingsPopup:Show()". That looked exactly like stale output from an old
-- build and cost several pointless reload cycles to chase.
local function DumpSettings()
    local SettingsPopup = ns:GetModule("SettingsPopup")
    if not SettingsPopup then line("SettingsPopup module NOT REGISTERED"); return end

    -- Force the frame to exist so it can be measured, but REMEMBER whether it
    -- was open and put it back afterwards. Leaving it shown makes a large,
    -- effectively invisible, mouse-enabled frame sit over the middle of the
    -- screen and swallow every click in the game.
    local wasShown = SettingsPopup.IsShown and SettingsPopup:IsShown() or false
    local ok, err = pcall(function() SettingsPopup:Show() end)
    if not ok then
        line("SettingsPopup:Show() ERRORED -> %s", tostring(err))
        -- Keep going: a partially built frame is still worth measuring.
    else
        line("SettingsPopup:Show() ok (wasShown=%s)", tostring(wasShown))
    end
    report._restorePopup = not wasShown

    local f = _G.GudaBagsSettingsPopup
    line(describeFrame("popup", f))
    if not f then return end

    line("popup.SetTitle = %s | CloseButton = %s | Inset = %s",
        type(f.SetTitle), tostring(f.CloseButton ~= nil), tostring(f.Inset ~= nil))

    -- The TabPanel container is the popup's only real child; find it and its
    -- contentArea, then measure each tab's content stack.
    local TabPanel = ns:GetModule("TabPanel")
    line("TabPanel module = %s", tostring(TabPanel ~= nil))

    local children = { f:GetChildren() }
    line("popup direct children = %d", #children)
    for i, child in ipairs(children) do
        if i > 6 then line("  ... (%d more)", #children - 6) break end
        line("  " .. describeFrame("child" .. i, child))
        -- A TabPanel container exposes GetContent/GetContentArea.
        if child.GetContentArea then
            line("    " .. describeFrame("contentArea", child:GetContentArea()))
            for _, tabId in ipairs({ "general", "layout", "icons", "bar",
                                     "features", "profiles", "categories", "guide" }) do
                local content = child.GetContent and child:GetContent(tabId)
                if content then
                    local kids = { content:GetChildren() }
                    line("    tab %-11s %s childControls=%d",
                        tabId, describeFrame("", content):gsub("^: ", ""), #kids)
                else
                    line("    tab %-11s CONTENT MISSING", tabId)
                end
            end
        end
    end
end

--- Verify the schema itself produces entries -- an empty schema and a failed
--- build look identical on screen.
local function DumpSchema()
    local SettingsSchema = ns:GetModule("SettingsSchema")
    if not SettingsSchema then line("SettingsSchema module NOT REGISTERED"); return end
    for _, name in ipairs({ "GetGeneral", "GetLayout", "GetIcons", "GetBar", "GetFeatures" }) do
        local fn = SettingsSchema[name]
        if type(fn) ~= "function" then
            line("schema %s = %s", name, type(fn))
        else
            local ok, res = pcall(fn)
            if not ok then
                line("schema %s ERRORED -> %s", name, tostring(res))
            elseif type(res) ~= "table" then
                line("schema %s returned %s", name, type(res))
            else
                local visible = 0
                for _, item in ipairs(res) do
                    local hidden = item.hidden
                    if type(hidden) == "function" then
                        local okh, h = pcall(hidden)
                        hidden = okh and h or false
                    end
                    if not hidden then visible = visible + 1 end
                end
                line("schema %-11s items=%d visible=%d", name, #res, visible)
            end
        end
    end
end

--- Full ordered dump of UIParent's children. Children are roughly in creation
--- order, so seeing every index at once -- rather than a window around one hit --
--- is what actually pins an anonymous frame to the addon that made it.
--- `tagged` is whether Shim335's CreateFrame wrapper saw it created, which
--- distinguishes "GudaBags made this" from "it existed before we loaded".
-- Forward declaration: RunDiagnostics below calls DumpMouseBlockers, which is
-- defined further down. Without this the name would resolve to a nil global at
-- call time and the pcall would swallow it silently -- the scan would simply
-- never run, with nothing to indicate why.
local DumpMouseBlockers, WatchBlockers, DumpWatchResults

local function DumpChildren()
    local kids = { UIParent:GetChildren() }
    local screenArea = UIParent:GetWidth() * UIParent:GetHeight()
    line("UIParent has %d children", #kids)
    for i, c in ipairs(kids) do
        local nm = c.GetName and c:GetName()
        local w = c.GetWidth and c:GetWidth() or 0
        local h = c.GetHeight and c:GetHeight() or 0
        -- Only the interesting ones: anything unnamed, or anything large.
        if not nm or (w * h) >= screenArea * 0.10 then
            line("[%d] %s type=%s %.0fx%.0f shown=%s mouse=%s tagged=%s",
                i, nm or "<unnamed>",
                tostring(c.GetObjectType and c:GetObjectType()),
                w, h,
                tostring(c.IsShown and c:IsShown()),
                tostring(c.IsMouseEnabled and c:IsMouseEnabled()),
                tostring(c._gbCreatedBy ~= nil))
        end
    end
end

--- Probe Ascension's custom GetContainerItemGUID.
---
--- docs/ASCENSION-API.md section 4 lists this in Extensions.dll but flags it as
--- unverified at runtime. Per-item locking is only viable if the GUID (a) exists,
--- (b) is non-nil for a real item, and (c) survives the item moving to another
--- slot -- otherwise it is just a dressed-up slot key and buys nothing over the
--- current itemID scope.
---
--- Usage: /guda diag guid, then SWAP two different items between two occupied slots,
--- then /guda diag guid again. A swap is decisive in both directions -- if the guids
--- stay put it is slot-derived, if they follow their items it is a real identity.
--- Moving into an empty slot can only ever prove PASS, never FAIL, because the
--- vacated slot drops out of the scan entirely.
---
--- The snapshot is keyed by SLOT, not by guid. That matters: a slot-derived guid
--- never appears to move -- every guid stays put at its own slot while the items
--- underneath it shuffle -- which is indistinguishable from "the user moved
--- nothing" if you only diff guid -> slot. Keying by slot and tracking the itemID
--- alongside gives the discriminator: a slot whose ITEM changed while its GUID did
--- not is proof the guid is addressing the slot, not the item.
local guidSnapshot = nil   -- [bag*1000+slot] = { guid=, itemID= } from the previous run

local function DumpItemGUIDs()
    line("---- item GUID probe ----")

    local fn = _G.GetContainerItemGUID
    line("GetContainerItemGUID type: %s", type(fn))
    if type(fn) ~= "function" then
        line("VERDICT: ABSENT -- per-instance locking is not possible on this client")
        guidSnapshot = nil
        return
    end

    local Constants = ns.Constants
    local bagMin = Constants and Constants.PLAYER_BAG_MIN or 0
    local bagMax = Constants and Constants.PLAYER_BAG_MAX or 4

    local bySlot, byGuid = {}, {}
    local scanned, withGuid, dupes, shown = 0, 0, 0, 0

    for bag = bagMin, bagMax do
        local numSlots = C_Container.GetContainerNumSlots(bag) or 0
        for slot = 1, numSlots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info then
                scanned = scanned + 1
                local ok, guid = pcall(fn, bag, slot)
                if not ok then guid = nil end
                if shown < 10 then
                    shown = shown + 1
                    line("  %d:%d itemID=%s guid=%s (%s)",
                        bag, slot, tostring(info.itemID), tostring(guid), type(guid))
                end
                bySlot[bag * 1000 + slot] = { guid = guid, itemID = info.itemID, bag = bag, slot = slot }
                if guid ~= nil then
                    withGuid = withGuid + 1
                    if byGuid[guid] then
                        dupes = dupes + 1
                        if dupes <= 3 then
                            line("  DUPLICATE guid %s at %d:%d and %d:%d",
                                tostring(guid), byGuid[guid].bag, byGuid[guid].slot, bag, slot)
                        end
                    else
                        byGuid[guid] = { bag = bag, slot = slot, itemID = info.itemID }
                    end
                end
            end
        end
    end

    line("occupied slots: %d, with a non-nil guid: %d, duplicate guids: %d", scanned, withGuid, dupes)

    if withGuid == 0 then
        line("VERDICT: NIL -- the function exists but returns nothing. Per-instance locking not viable.")
        guidSnapshot = nil
        return
    end
    if dupes > 0 then
        line("VERDICT: NOT UNIQUE -- two stacks share a guid. Per-instance locking not viable.")
        guidSnapshot = bySlot
        return
    end

    if not guidSnapshot then
        line("Baseline captured (%d slots). Now SWAP two different items between two", scanned)
        line("occupied slots (drag A onto B), then run /guda diag guid again.")
        line("A swap is decisive both ways; moving into an EMPTY slot can only prove PASS.")
        guidSnapshot = bySlot
        return
    end

    -- Second run. Two independent signals, both keyed off the item actually moving.
    local itemChangedSlots = 0   -- slots whose occupant changed between runs
    local slotDerived      = 0   -- ...and whose guid did NOT change  -> guid addresses the slot
    local guidChangedToo   = 0   -- ...and whose guid DID change      -> consistent with item identity
    local followedItem     = 0   -- a guid now at a different slot, still on the same itemID -> proof

    for key, was in pairs(guidSnapshot) do
        local now = bySlot[key]
        local nowItem = now and now.itemID or nil
        if nowItem ~= was.itemID then
            itemChangedSlots = itemChangedSlots + 1
            local nowGuid = now and now.guid or nil
            if now and nowGuid == was.guid then
                slotDerived = slotDerived + 1
                if slotDerived <= 5 then
                    line("  SLOT-DERIVED: %d:%d itemID %s -> %s but guid stayed %s",
                        was.bag, was.slot, tostring(was.itemID), tostring(nowItem), tostring(was.guid))
                end
            else
                guidChangedToo = guidChangedToo + 1
            end
        end
    end

    -- Did any baseline guid turn up at a new slot still carrying the same item?
    for key, was in pairs(guidSnapshot) do
        if was.guid ~= nil then
            local now = byGuid[was.guid]
            if now and (now.bag ~= was.bag or now.slot ~= was.slot) and now.itemID == was.itemID then
                followedItem = followedItem + 1
                if followedItem <= 5 then
                    line("  FOLLOWED ITEM: guid %s  %d:%d -> %d:%d (itemID %s)",
                        tostring(was.guid), was.bag, was.slot, now.bag, now.slot, tostring(now.itemID))
                end
            end
        end
    end

    line("slots whose item changed: %d (guid unchanged: %d, guid changed: %d); guids that followed an item: %d",
        itemChangedSlots, slotDerived, guidChangedToo, followedItem)

    if itemChangedSlots == 0 and followedItem == 0 then
        line("VERDICT: NO CHANGE DETECTED -- nothing moved between the two runs.")
        line("Swap two different items between two occupied slots, then run /guda diag guid again.")
    elseif slotDerived > 0 then
        line("VERDICT: FAIL -- a slot kept its guid while its item changed.")
        line("The guid addresses the SLOT, not the item. Per-instance locking not viable.")
    elseif followedItem > 0 then
        line("VERDICT: PASS -- a guid followed its item to a new slot.")
        line("Per-instance locking is viable.")
    else
        line("VERDICT: INCONCLUSIVE -- items changed slots but no guid followed one.")
        line("Guids look regenerated on move, which is as unusable as slot-derived.")
    end

    guidSnapshot = bySlot
end

local currencyTokenHooked = false

-- Describe one pcall'd return tuple: arity first, then each value's type and
-- value. Arity is the finding -- a custom core routinely appends returns, and a
-- name list read out of a doc file cannot tell you where the tuple really ends.
local function describeCall(label, fn, ...)
    if type(fn) ~= "function" then
        line("  %s: %s (not callable)", label, type(fn))
        return
    end
    -- Read the tuple through a vararg callee rather than packing into a table:
    -- a trailing nil is a real return here, and `#t` would silently drop it.
    local function report_(ok, ...)
        if not ok then
            line("  %s: RAISED -- %s", label, tostring((...)))
            return
        end
        local n = select("#", ...)
        if n == 0 then
            line("  %s: returned nothing", label)
            return
        end
        local parts = {}
        for i = 1, n do
            local v = select(i, ...)
            parts[#parts + 1] = ("[%d]%s=%s"):format(i, type(v), tostring(v))
        end
        line("  %s: arity=%d %s", label, n, table.concat(parts, " "))
    end
    report_(pcall(fn, ...))
end

-- Taint-surface probe.
--
-- Answers one question: what does GudaBags still OWN that Blizzard's code also
-- reads? Anything we own is a place where secure execution enters addon Lua and
-- picks up our taint -- which is what produced
-- "AddOn 'GudaBags' tainted the call of the secure function 'IsResponseSeen()'"
-- when opening the GM ticket UI.
--
-- Tier 1 entries below MUST all report `native`. The bag globals are Tier 3:
-- they report `GudaBags` by design, because replacing them is how the addon
-- takes over the bags at all.
local function DumpTaintSurface()
    line("---- taint surface ----")

    -- Functions we know are ours, by identity -- no debug library needed and no
    -- guessing. Anything matching one of these is a global we still own.
    local OURS = {}
    local function markOurs(fn, label)
        if type(fn) == "function" then OURS[fn] = label end
    end
    markOurs(ns.CreateFrame, "ns.CreateFrame")
    markOurs(ns.DropDownSetWidth, "ns.DropDownSetWidth")
    markOurs(ns.DropDownSetText, "ns.DropDownSetText")
    markOurs(ns.GuardBackdrop, "ns.GuardBackdrop")

    -- Fallback for functions we did not pre-register (the bag globals, the error
    -- handler): the source chunk name, when the client exposes a debug library.
    local function ownerOf(fn)
        if fn == nil then return "nil" end
        if type(fn) ~= "function" then return type(fn) end
        if OURS[fn] then return "|cffff5555GudaBags|r (" .. OURS[fn] .. ")" end
        if type(debug) == "table" and type(debug.getinfo) == "function" then
            local ok, info = pcall(debug.getinfo, fn, "S")
            local src = ok and info and info.source and tostring(info.source) or nil
            if src then
                if src:find("GudaBags", 1, true) then
                    return "|cffff5555GudaBags|r " .. (src:match("([^\\/]+)$") or src)
                end
                return "native (" .. src .. ")"
            end
        end
        return "function (source unknown)"
    end

    local function reportGlobal(name)
        local secure, owner = "?", nil
        if issecurevariable then
            local ok, s, o = pcall(issecurevariable, name)
            if ok then secure, owner = tostring(s), o end
        end
        line("  %-36s %s  issecure=%s%s", name, ownerOf(_G[name]),
            secure, owner and (" taintedBy=" .. tostring(owner)) or "")
    end

    line("Tier 1 -- these must all read native:")
    for _, n in ipairs({
        "CreateFrame",
        "UIDropDownMenu_SetWidth", "UIDropDownMenu_SetText",
        "ButtonFrameTemplate_HidePortrait", "ButtonFrameTemplate_HideButtonBar",
        "securecallfunction",
    }) do reportGlobal(n) end

    line("Tier 3 -- expected to read GudaBags (this is how the addon works):")
    for _, n in ipairs({
        "ToggleBackpack", "ToggleBag", "ToggleAllBags",
        "OpenAllBags", "OpenBag", "OpenBackpack",
        "CloseAllBags", "CloseBag", "CloseBackpack",
    }) do reportGlobal(n) end

    -- Shared widget metatables. A wrapper here reaches every widget in the
    -- client, Blizzard's included -- the broadest taint surface there is after
    -- CreateFrame itself.
    line("shared widget metatables:")
    local probeParent = _G.GudaBagsShimProbeContainer or UIParent
    local WIDGETS = { "Frame", "Button", "CheckButton", "Slider", "EditBox", "StatusBar", "ScrollFrame" }
    -- Every method the shim has ever put on a shared metatable. All of these
    -- must read native or be absent; a GudaBags owner on any of them means
    -- Blizzard's own widgets run our Lua and inherit our taint.
    local METHODS = { "SetBackdropColor", "SetBackdropBorderColor", "GetChecked",
                      "SetGradient", "SetObeyStepOnDrag", "SetEnabled",
                      "SetDrawEdge", "SetHideCountdownNumbers", "SetDrawSwipe",
                      "SetSize", "SetShown" }
    for _, wtype in ipairs(WIDGETS) do
        local ok, obj = pcall(CreateFrame, wtype, nil, probeParent)
        if ok and obj then
            local mt = getmetatable(obj)
            local index = mt and type(mt.__index) == "table" and mt.__index or nil
            if index then
                for _, m in ipairs(METHODS) do
                    if index[m] ~= nil then
                        line("  %s.%s: %s", wtype, m, ownerOf(index[m]))
                    end
                end
            else
                line("  %s: no writable __index table", wtype)
            end
            obj:Hide()
        end
    end

    -- Blizzard-owned tables we must only ever read.
    line("Blizzard tables:")
    if issecurevariable and type(RAID_CLASS_COLORS) == "table" then
        local ok, secure, owner = pcall(issecurevariable, RAID_CLASS_COLORS, "WARRIOR")
        line("  RAID_CLASS_COLORS.WARRIOR issecure=%s%s",
            ok and tostring(secure) or "?", owner and (" taintedBy=" .. tostring(owner)) or "")
    end
    for _, n in ipairs({ "WHITE_FONT_COLOR", "NORMAL_FONT_COLOR", "GRAY_FONT_COLOR" }) do
        local t = _G[n]
        line("  %-20s %s WrapTextInColorCode=%s", n, type(t),
            type(t) == "table" and type(t.WrapTextInColorCode) or "n/a")
    end

    -- Slash surface. Every key we own in SlashCmdList is one more chance for a
    -- MACRO to pick up our taint: 3.3.5a's ChatEdit_ParseText dispatches by
    -- walking pairs(SlashCmdList) and reading _G["SLASH_"..key..i], so a key
    -- visited before CASTSEQUENCE taints that execution and the following
    -- CastSpellByName is blocked in our name. Target: exactly one -- GUDABAGS.
    line("slash surface (want exactly 1 GudaBags key):")
    local ours = 0
    if type(SlashCmdList) == "table" then
        for key, fn in pairs(SlashCmdList) do
            -- Key prefix, not just ownerOf: this client may ship no debug
            -- library, and without debug.getinfo ownerOf cannot name the source
            -- of a plain closure -- which would report zero of our own keys.
            local owner = ownerOf(fn)
            if key:upper():find("GUDABAGS", 1, true) or owner:find("GudaBags", 1, true) then
                ours = ours + 1
                local secure = "?"
                if issecurevariable then
                    local ok, s = pcall(issecurevariable, SlashCmdList, key)
                    if ok then secure = tostring(s) end
                end
                local aliases, i = {}, 1
                while _G["SLASH_" .. key .. i] do
                    aliases[i] = _G["SLASH_" .. key .. i]
                    i = i + 1
                end
                line("  SlashCmdList.%-16s %s  issecure=%s  aliases=%s",
                    key, owner, secure, table.concat(aliases, " "))
            end
        end
    end
    line("  total GudaBags keys: %d%s", ours,
        ours > 1 and " |cffff5555(each one is a macro-taint chance)|r" or "")

    line("error handler: %s", ownerOf(geterrorhandler and geterrorhandler() or nil))
    line("(the error sink is OPT-IN: off by default, /guda errors on + /reload to")
    line(" install it. Owning the global handler means every error in the client,")
    line(" including other addons', runs our code and taints that execution.)")
end

-- Currency API probe.
--
-- The whole 3.3.5a currency port is written against the client's own shipped
-- APIDocumentation addon -- a DOC FILE, not the binary. docs\ASCENSION-API.md
-- spells out why that is not enough on its own: a markNative check answers "does
-- this exist", not "does this work", and the first attempt at the SOUNDKIT bug
-- failed precisely because a 3.3.5a signature was assumed instead of read.
--
-- So this prints the real arity and the real value types, not the documented
-- names. Run it, /reload, and read GudaBags_Diag out of SavedVariables.
local function DumpCurrencyAPI()
    line("---- currency API probe ----")

    local names = {
        "GetCurrencyListSize", "GetCurrencyListInfo", "GetCurrencyListLink",
        "GetBackpackCurrencyInfo", "SetCurrencyBackpack", "SetCurrencyUnused",
        "ExpandCurrencyList", "SetCurrencyShow", "GetCurrencyInfo",
        "GetHonorCurrency", "GetMaxArenaCurrency", "GetNumWatchedTokens",
    }
    line("globals:")
    for _, n in ipairs(names) do
        line("  %s: %s", n, type(_G[n]))
    end

    line("MAX_WATCHED_TOKENS: %s (%s)",
        tostring(_G.MAX_WATCHED_TOKENS), type(_G.MAX_WATCHED_TOKENS))

    local ciCount = -1
    if type(C_CurrencyInfo) == "table" then
        ciCount = 0
        for _ in pairs(C_CurrencyInfo) do ciCount = ciCount + 1 end
    end
    line("C_CurrencyInfo members: %d (0 means the Shim335 NoopTable guard still holds)", ciCount)

    -- The currency list. Arity of GetCurrencyListInfo is the headline finding.
    local size = 0
    if type(GetCurrencyListSize) == "function" then
        local ok, n = pcall(GetCurrencyListSize)
        size = (ok and n) or 0
    end
    line("GetCurrencyListSize() = %d", size)

    local firstItemID
    for i = 1, math.min(size, 25) do
        describeCall(("GetCurrencyListInfo(%d)"):format(i), _G.GetCurrencyListInfo, i)
        if not firstItemID and type(GetCurrencyListInfo) == "function" then
            local ok, _, isHeader = pcall(GetCurrencyListInfo, i)
            if ok and not isHeader then
                local ok2, r = pcall(function() return select(9, GetCurrencyListInfo(i)) end)
                if ok2 and type(r) == "number" and r > 0 then firstItemID = r end
            end
        end
        if type(GetCurrencyListLink) == "function" then
            describeCall(("GetCurrencyListLink(%d)"):format(i), _G.GetCurrencyListLink, i)
        end
    end
    if size > 25 then line("  (list truncated at 25 of %d rows)", size) end

    -- Does an out-of-range backpack index return nil, or raise? That decides
    -- whether Currency:Update can loop past the watched count or must clamp.
    local probeMax = (type(_G.MAX_WATCHED_TOKENS) == "number" and _G.MAX_WATCHED_TOKENS + 2) or 5
    line("backpack (tracked) currencies, probing 1..%d:", probeMax)
    for i = 1, probeMax do
        describeCall(("GetBackpackCurrencyInfo(%d)"):format(i), _G.GetBackpackCurrencyInfo, i)
    end

    describeCall("GetHonorCurrency()", _G.GetHonorCurrency)
    describeCall("GetMaxArenaCurrency()", _G.GetMaxArenaCurrency)

    -- Ascension's own namespace. Unverified; a possible enhancement, never a
    -- dependency -- the stock list API above is the documented path.
    if type(C_Token) == "table" then
        local members = {}
        for k, v in pairs(C_Token) do members[#members + 1] = ("%s(%s)"):format(k, type(v)) end
        table.sort(members)
        line("C_Token members: %s", table.concat(members, " "))
        describeCall("C_Token.GetTokenTypes()", C_Token.GetTokenTypes)
        if firstItemID then
            describeCall(("C_Token.GetTokenInfo(%d)"):format(firstItemID), C_Token.GetTokenInfo, firstItemID)
            describeCall(("C_Token.GetTokenAmount(%d)"):format(firstItemID), C_Token.GetTokenAmount, firstItemID)
        end
    else
        line("C_Token: %s", type(C_Token))
    end

    -- Proves the SetHyperlink tooltip route: WotLK currencies are real items.
    if firstItemID then
        local nm, lnk = GetItemInfo(firstItemID)
        line("GetItemInfo(%d) -> name=%s link=%s", firstItemID, tostring(nm), tostring(lnk))
    else
        line("no non-header row with an itemID found -- SetHyperlink route unproven")
    end

    line("GameTooltip.SetCurrencyToken: %s", type(GameTooltip.SetCurrencyToken))
    line("GameTooltip.SetCurrencyByID: %s", type(GameTooltip.SetCurrencyByID))

    -- Settles the one thing a static dump cannot: whether SetCurrencyToken's
    -- argument indexes the FULL currency list or only the watched subset. The
    -- Tooltip.lua hook is keyed off that answer.
    if not currencyTokenHooked and type(GameTooltip.SetCurrencyToken) == "function" then
        currencyTokenHooked = true
        hooksecurefunc(GameTooltip, "SetCurrencyToken", function(_, index)
            local ok, nm = pcall(GetCurrencyListInfo, index)
            line("SetCurrencyToken(%s) -> GetCurrencyListInfo name=%s",
                tostring(index), ok and tostring(nm) or "<error>")
            GudaBags_Diag = report
        end)
        line("hooked SetCurrencyToken -- now hover a row in the Currency tab, then /reload")
    end
end

--- Dump every active item button's cached identity against the live slot.
---
--- The failure this exists to catch: a button whose cached bagID/slot points at a
--- slot that now holds a different item. Marker code resolves lock state from
--- those coordinates, so a stale button adopts the current occupant's lock and the
--- icon lights up on the wrong item. Category view can leave buttons stale
--- (grouped and orphaned buttons are not re-pointed on every refresh).
---
--- Run it with bags open, ideally right after locking something that made a wrong
--- icon appear. STALE lines are the smoking gun; ORPHAN counts buttons whose slot
--- no longer exists at all.
-- The transmog dot is driven by a server-sent tooltip line that exists in no
-- binary and no GlobalString, matched on BOTH its wording and its purple colour
-- (Data\ItemScanner.lua). That makes a wrong colour threshold a silent failure:
-- no error, just no dots. This prints the raw text and RGB of every tooltip line
-- on your gear so the threshold can be checked against what the client actually
-- sends, instead of guessed at.
local function DumpTransmogLines()
    line("---- transmog tooltip lines ----")

    local threshold = ns.Constants.COLOR_THRESHOLDS.PURPLE
    line("PURPLE threshold: r>%.2f  g<%.2f  b>%.2f  (and r>g and b>g)",
        threshold.min_r, threshold.max_g, threshold.min_b)
    line("required words: click + collect + appearance (all must be present)")
    line("A purple line that FAILS the words is the already-collected status line.")

    local ItemScanner = ns:GetModule("ItemScanner")
    local tip = ItemScanner and ItemScanner.GetScanningTooltip and ItemScanner:GetScanningTooltip()
    if not tip then
        line("ItemScanner scanning tooltip unavailable")
        return
    end

    local scanned, hits = 0, 0
    for bag = 0, 4 do
        local slots = C_Container.GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local link = C_Container.GetContainerItemLink(bag, slot)
            local equipSlot = link and select(9, GetItemInfo(link)) or nil
            if equipSlot and equipSlot ~= "" and equipSlot ~= "INVTYPE_BAG" then
                scanned = scanned + 1
                tip:SetOwner(WorldFrame, "ANCHOR_NONE")
                tip:ClearLines()
                tip:SetBagItem(bag, slot)

                local shown = false
                for i = 1, (tip:NumLines() or 0) do
                    local fs = _G["GudaBagsScanningTooltipTextLeft" .. i]
                    if fs and fs:IsShown() and fs:GetText() then
                        local text = fs:GetText()
                        local r, g, b = fs:GetTextColor()
                        local lower = text:lower()
                        -- Only the candidate lines: printing every line of every
                        -- item would bury the answer in hundreds of rows.
                        if lower:find("collect", 1, true) or lower:find("appearance", 1, true) then
                            if not shown then
                                line("  [%d:%d] %s", bag, slot, link)
                                shown = true
                            end
                            hits = hits + 1
                            -- Report the two verdicts SEPARATELY. A line that is
                            -- purple but fails the words is the already-collected
                            -- status line (expected: no dot). One that passes the
                            -- words but not the colour means the threshold is off.
                            local purple = r > threshold.min_r and g < threshold.max_g
                                and b > threshold.min_b and r > g and b > g
                            local words = lower:find("click", 1, true)
                                and lower:find("collect", 1, true)
                                and lower:find("appearance", 1, true)
                            line("     line %d  r=%.3f g=%.3f b=%.3f  purple=%s words=%s -> dot=%s",
                                i, r, g, b, tostring(purple), tostring(words and true or false),
                                tostring((purple and words) and true or false))
                            line("        %q", text)
                        end
                    end
                end
            end
        end
    end

    line("scanned %d equippable item(s), %d candidate line(s)", scanned, hits)
    if scanned > 0 and hits == 0 then
        line("No candidate lines at all -- this gear has no collectable appearance,")
        line("or the wording changed (ItemScanner matches 'collect' AND 'appearance').")
    end
end

-- Replay the last restack: what was attempted, what the client reported back,
-- and which slots were still locked when it handed control to the UI.
--
-- The restack mutates bags asynchronously and its failures are silent -- the
-- server simply never answers -- so by the time a slot shows up grey every piece
-- of evidence is gone unless it was recorded as it happened.
local function DumpRestackLog()
    line("---- last restack ----")

    local SortEngine = ns:GetModule("SortEngine")
    if not SortEngine or not SortEngine.GetRestackLog then
        line("SortEngine has no restack log (old build?)")
        return
    end

    local log, count = SortEngine:GetRestackLog()
    if not count or count == 0 then
        line("no restack recorded yet -- run Restack and Clean, then this command")
        return
    end

    for i = 1, count do
        line("%s", tostring(log[i]))
    end

    -- Live state now, which is the part the log itself cannot know: a slot listed
    -- as locked at FINISH but unlocked here recovered on its own; one still
    -- locked here is the stuck item, and only a relog clears it.
    line("---- locked slots right now ----")
    local stuck = 0
    for _, bagID in ipairs(ns.Constants.BAG_IDS) do
        for slot = 1, (C_Container.GetContainerNumSlots(bagID) or 0) do
            local info = C_Container.GetContainerItemInfo(bagID, slot)
            if info and info.isLocked then
                stuck = stuck + 1
                line("  %d:%d LOCKED item=%s %s", bagID, slot,
                    tostring(info.itemID), tostring(info.hyperlink))
            end
        end
    end
    if stuck == 0 then
        line("  none -- bags are clean")
    else
        line("  %d slot(s) still locked. /reload will NOT clear these;", stuck)
        line("  log out to character select and back in.")
    end
end

local function DumpMarkerState()
    line("---- item button marker state ----")

    local ItemButton = ns:GetModule("ItemButton")
    if not ItemButton or not ItemButton.GetActiveButtons then
        line("ItemButton module unavailable")
        return
    end

    local total, stale, orphan, lockShown, strokeShown, shownPairs = 0, 0, 0, 0, 0, 0

    for button in ItemButton:GetActiveButtons() do
        local d = button.itemData
        if d and d.itemID then
            total = total + 1
            local liveID = nil
            if not d.isGuildBank and d.bagID and d.slot then
                local info = C_Container.GetContainerItemInfo(d.bagID, d.slot)
                liveID = info and info.itemID or nil
            end

            local lockOn   = button.userLockIcon and button.userLockIcon:IsShown() or false
            local strokeOn = button.userLockIconStroke and button.userLockIconStroke:IsShown() or false
            if lockOn then lockShown = lockShown + 1 end
            if strokeOn then strokeShown = strokeShown + 1 end
            if lockOn and strokeOn then shownPairs = shownPairs + 1 end

            if liveID == nil then
                orphan = orphan + 1
                if orphan <= 8 then
                    line("  ORPHAN %s:%s shows itemID=%s but slot is EMPTY (lock=%s stroke=%s)",
                        tostring(d.bagID), tostring(d.slot), tostring(d.itemID),
                        tostring(lockOn), tostring(strokeOn))
                end
            elseif liveID ~= d.itemID then
                stale = stale + 1
                if stale <= 8 then
                    line("  STALE %s:%s shows itemID=%s but slot holds %s (lock=%s stroke=%s)",
                        tostring(d.bagID), tostring(d.slot), tostring(d.itemID),
                        tostring(liveID), tostring(lockOn), tostring(strokeOn))
                end
            end
        end
    end

    line("active item buttons: %d, stale: %d, orphaned: %d", total, stale, orphan)
    line("lock icon shown: %d, stroke shown: %d, both shown: %d", lockShown, strokeShown, shownPairs)
    if lockShown ~= strokeShown then
        line("MISMATCH: icon and outline show counts differ -- one is shown without the other.")
    end
    if stale > 0 or orphan > 0 then
        line("VERDICT: stale buttons present. A lock resolved from their coordinates")
        line("lands on the wrong item. This is the wrong-icon cause.")
    else
        line("VERDICT: every active button matches its slot. Wrong icons are NOT")
        line("caused by stale coordinates -- look at draw order or texture state.")
    end
end

-- Bump on every change to this file. Editing a Lua file does not affect the
-- running session, so a /guda diag issued before the next /reload silently reports
-- from the OLD code -- which has already cost a round trip. Stamping the build
-- into the report makes stale output obvious at a glance instead of something to
-- reconstruct from file timestamps.
local DIAG_BUILD = "2026-08-01-c (marker state dump: /guda diag markers)"

local function RunDiagnostics()
    report = {}   -- the ONE place a full run clears accumulated output
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffGudaBags diagnostics|r")
    line("diag build: %s", DIAG_BUILD)

    -- ORDER MATTERS. The mouse/children scans must run BEFORE DumpSettings,
    -- because DumpSettings has to Show() the settings popup -- a large
    -- mouse-enabled frame that would then appear in its own scan results.
    -- A diagnostic that contaminates its own measurement is worse than none.
    pcall(DumpMouseBlockers)
    pcall(DumpChildren)
    -- Report anything caught since the last run, then (re)arm the hooks.
    pcall(DumpWatchResults)
    pcall(WatchBlockers)

    pcall(DumpSchema)
    pcall(DumpSettings)

    -- ALWAYS restore: DumpSettings had to Show() the popup to measure it, and a
    -- popup left open blocks mouse input across the middle of the screen.
    if report._restorePopup then
        local SettingsPopup = ns:GetModule("SettingsPopup")
        if SettingsPopup and SettingsPopup.Hide then pcall(SettingsPopup.Hide, SettingsPopup) end
    end
    report._restorePopup = nil

    GudaBags_Diag = report
    DEFAULT_CHAT_FRAME:AddMessage(
        "|cff00ccff[diag]|r saved to GudaBags_Diag -- log out or /reload to write it to disk")
end

--- Find frames that could be swallowing mouse input.
--- A shown, mouse-enabled frame covering a large part of the screen blocks
--- targeting, the camera and the action bars, and produces NO error while doing
--- it -- so it is invisible to every other diagnostic here.
-- Frames we have already hooked, so repeat /guda diag runs do not stack hooks.
local watched = {}

--- Hook Show() on large, mouse-enabled, non-GudaBags frames so we learn WHO
--- shows them. The blocker appears only while the bag frame is open, so the
--- interesting event is the Show, not the creation -- and the creator tag is no
--- help because the frame predates us.
---
--- hooksecurefunc on a frame method fires after the real call, capturing the
--- stack of whatever asked for it.
function WatchBlockers()
    local screenArea = UIParent:GetWidth() * UIParent:GetHeight()
    local hooked = 0
    for i, c in ipairs({ UIParent:GetChildren() }) do
        local nm = c.GetName and c:GetName()
        local w = c.GetWidth and c:GetWidth() or 0
        local h = c.GetHeight and c:GetHeight() or 0
        local isOurs = nm and nm:match("^Guda")
        if not isOurs and not watched[c] and w * h >= screenArea * 0.10
           and c.IsMouseEnabled and c:IsMouseEnabled() and c.Show then
            watched[c] = true
            hooked = hooked + 1
            local label = nm or ("UIParent.child" .. i)
            hooksecurefunc(c, "Show", function(self)
                if not self._gbShownBy and debugstack then
                    self._gbShownBy = debugstack(2, 4, 0)
                    self._gbShownLabel = label
                end
            end)
        end
    end
    line("watching %d frame(s) for Show(). Open your bags, then run /guda diag again.", hooked)
end

--- Report any watched frame that has since been shown, with the capturing stack.
function DumpWatchResults()
    local any = false
    for frame in pairs(watched) do
        if frame._gbShownBy then
            any = true
            line("SHOWN: %s -- shown by:", tostring(frame._gbShownLabel))
            for l in tostring(frame._gbShownBy):gmatch("[^\r\n]+") do
                local t = l:match("^%s*(.-)%s*$")
                if t ~= "" then line("   %s", t) end
            end
        end
    end
    if not any then line("no watched frame has been Show()n yet") end
end

-- Assigns to the local forward-declared above -- do NOT add `local` here.
function DumpMouseBlockers()
    local sw, sh = UIParent:GetWidth(), UIParent:GetHeight()
    if not sw or sw == 0 then line("UIParent has no size"); return end
    local screenArea = sw * sh

    local found = 0
    local function inspect(frame, label)
        if not frame or frame == UIParent then return end
        if not frame.IsShown or not frame:IsShown() then return end
        if not frame.IsMouseEnabled or not frame:IsMouseEnabled() then return end
        local w = frame.GetWidth and frame:GetWidth() or 0
        local h = frame.GetHeight and frame:GetHeight() or 0
        if not w or not h or w * h < screenArea * 0.10 then return end
        found = found + 1

        -- A frame the user can SEE is not a bug: a visible window is supposed to
        -- take clicks over itself. The dangerous case is shown-but-invisible, so
        -- report enough to tell them apart. IsVisible() accounts for the whole
        -- parent chain; effective alpha catches a frame faded to nothing.
        local nm = frame.GetName and frame:GetName()
        local visible = frame.IsVisible and frame:IsVisible()
        local effAlpha = frame.GetEffectiveAlpha and frame:GetEffectiveAlpha() or
                         (frame.GetAlpha and frame:GetAlpha()) or -1
        local verdict
        if not visible or effAlpha < 0.05 then
            verdict = "INVISIBLE -> almost certainly the culprit"
        elseif nm and nm:match("^Guda") then
            verdict = "visible GudaBags window -- expected while it is open"
        else
            verdict = "visible -- expected if you can see it"
        end

        line("BLOCKER %s %.0fx%.0f strata=%s level=%s alpha=%.2f effAlpha=%.2f type=%s [%s]",
            label, w, h,
            tostring(frame.GetFrameStrata and frame:GetFrameStrata()),
            tostring(frame.GetFrameLevel and frame:GetFrameLevel()),
            frame.GetAlpha and frame:GetAlpha() or -1,
            effAlpha,
            tostring(frame.GetObjectType and frame:GetObjectType()),
            verdict)

        -- Identifying detail for UNNAMED frames, which is the hard case: a
        -- texture path or a parent name usually names the owner outright.
        local parent = frame.GetParent and frame:GetParent()
        line("   parent=%s scripts:OnClick=%s OnMouseDown=%s",
            (parent and parent.GetName and parent:GetName()) or "<unnamed/UIParent>",
            tostring(frame.GetScript and frame:GetScript("OnClick") ~= nil),
            tostring(frame.GetScript and frame:GetScript("OnMouseDown") ~= nil))
        if frame.GetRegions then
            local regions = { frame:GetRegions() }
            for i = 1, math.min(#regions, 3) do
                local r = regions[i]
                if r and r.GetTexture then
                    line("   region%d texture=%s", i, tostring(r:GetTexture()))
                end
            end
        end
        -- The decisive identifier: the stack captured at CreateFrame time by the
        -- wrapper in Shim335.lua. Names the exact file and line that made it,
        -- which is the only reliable way to attribute an anonymous frame.
        if frame._gbCreatedBy then
            for stackLine in tostring(frame._gbCreatedBy):gmatch("[^\r\n]+") do
                local trimmed = stackLine:match("^%s*(.-)%s*$")
                if trimmed ~= "" then line("   created by: %s", trimmed) end
            end
        else
            line("   created by: <unknown -- created before the shim, or not via CreateFrame>")
        end

        -- `nm` is already resolved above for the verdict; reuse it.
        if nm and nm:match("^Guda") then
            line("   -> this is a GudaBags frame")
        end
    end

    -- Named frames we know about, plus a sweep of UIParent's direct children.
    for _, name in ipairs({ "GudaBagsSearchOverlay", "GudaBagsSettingsPopup",
                            "GudaBagsCategoryEditor", "GudaBagsGoldDropdown",
                            "GudaBagFrame", "GudaBankFrame", "GudaGuildBankFrame",
                            "GudaMailFrame" }) do
        inspect(_G[name], name)
    end
    local kids = { UIParent:GetChildren() }
    for i, child in ipairs(kids) do
        inspect(child, (child.GetName and child:GetName()) or ("UIParent.child" .. i))
    end

    if found == 0 then
        line("no large shown mouse-enabled frames -- mouse is not blocked by a frame")
    end

    -- Neighbours of any unnamed hit. UIParent's children are roughly in creation
    -- order, so the NAMED frames either side usually identify the owning addon
    -- even when the frame itself is anonymous.
    for i, child in ipairs(kids) do
        if child and child.GetName and not child:GetName()
           and child.IsMouseEnabled and child:IsMouseEnabled()
           and child.IsShown and child:IsShown() then
            local w = child.GetWidth and child:GetWidth() or 0
            local h = child.GetHeight and child:GetHeight() or 0
            if w * h >= screenArea * 0.10 then
                line("neighbours of unnamed blocker at index %d:", i)
                for j = math.max(1, i - 3), math.min(#kids, i + 3) do
                    local n = kids[j]
                    line("   [%d] %s (%s)", j,
                        (n and n.GetName and n:GetName()) or "<unnamed>",
                        (n and n.GetObjectType and n:GetObjectType()) or "?")
                end
            end
        end
    end
end

--- Disable mouse input on every large frame that is NOT a visible GudaBags
--- window, and report what changed.
---
--- This is a TEST, not a fix. If the mouse works afterwards, the blocking
--- hypothesis is confirmed and we know the culprit is in that list. Nothing is
--- hidden and nothing is destroyed -- EnableMouse(false) leaves the frame
--- rendering exactly as before -- and a /reload restores everything, because the
--- owning addon sets its own mouse state on creation.
local function UnblockMouse()
    local sw, sh = UIParent:GetWidth(), UIParent:GetHeight()
    if not sw or sw == 0 then line("UIParent has no size"); return end
    local screenArea = sw * sh
    local changed = 0

    local kids = { UIParent:GetChildren() }
    for i, frame in ipairs(kids) do
        if frame ~= UIParent and frame.IsShown and frame:IsShown()
           and frame.IsMouseEnabled and frame:IsMouseEnabled() then
            local w = frame.GetWidth and frame:GetWidth() or 0
            local h = frame.GetHeight and frame:GetHeight() or 0
            local nm = frame.GetName and frame:GetName()
            -- Never touch our own windows: they are supposed to take clicks.
            local isOurs = nm and nm:match("^Guda")
            if w and h and w * h >= screenArea * 0.10 and not isOurs then
                frame:EnableMouse(false)
                changed = changed + 1
                line("mouse DISABLED on %s (%.0fx%.0f)",
                     nm or ("UIParent.child" .. i), w, h)
            end
        end
    end

    if changed == 0 then
        line("nothing to disable -- no large non-GudaBags frame is taking mouse input")
    else
        line("disabled %d frame(s). Try clicking/targeting/camera NOW.", changed)
        line("If the mouse works, that list contains the culprit. /reload restores it.")
    end
end

-- The shim's own report. It no longer announces itself at login (a count only
-- the porter cares about), so this is where you read it.
local function DumpShimReport()
    local db = GudaBagsShim_DB
    if type(db) ~= "table" then line("GudaBagsShim_DB missing -- shim did not finish"); return end

    local function dumpBucket(label, t, withReason)
        if type(t) ~= "table" then return end
        local keys = {}
        for k in pairs(t) do keys[#keys + 1] = k end
        if #keys == 0 then return end
        table.sort(keys)
        line("%s (%d):", label, #keys)
        for _, k in ipairs(keys) do
            local why = withReason and type(t[k]) == "string" and t[k] or nil
            line("  %s%s", k, why and ("  -- " .. why) or "")
        end
    end

    line("---- shim report ----")
    if type(db.build) == "table" then
        line("client %s build %s (%s), toc %s", tostring(db.build.version),
            tostring(db.build.build), tostring(db.build.date), tostring(db.build.tocversion))
    end
    line("recorded %s", tostring(db.time))
    dumpBucket("native", db.native)
    dumpBucket("polyfilled", db.polyfilled)
    -- The important one: absent ON PURPOSE, nearly always because writing it
    -- would put us on a shared metatable and leak taint into Blizzard's code.
    dumpBucket("by design (not polyfilled)", db.byDesign, true)
    dumpBucket("MISSING (needed, not found)", db.missingGlobals)
    if type(db.notes) == "table" and #db.notes > 0 then
        line("notes (%d):", #db.notes)
        for i = 1, #db.notes do line("  %s", tostring(db.notes[i])) end
    end
end

-------------------------------------------------
-- Bank vs Guild Bank watcher  (/guda diag bank)
-------------------------------------------------
-- GudaBags shows the same UI for both banks on this client, which means the
-- guild-bank open path is not being reached. Which of the three possible causes
-- it is -- the event never fires, Blizzard_GuildBankUI never loads so the frame
-- hook is dead, or the guild banker fires BANKFRAME_OPENED and the personal path
-- wins -- is not answerable from source, so measure it at the banker instead.
--
-- Its own frame, not Core\Events.lua: registering each name here with a pcall
-- reports what THIS client accepts per event, rather than inheriting the Events
-- module's fallback/unsupported handling. Logging only -- nothing here changes
-- how either bank opens.

local BANK_WATCH_EVENTS = {
    -- personal bank (Interface\AddOns\APIDocumentation\...\BankDocumentation.lua)
    "BANKFRAME_OPENED",
    "BANKFRAME_CLOSED",
    "PLAYERBANKSLOTS_CHANGED",
    "PLAYERBANKBAGSLOTS_CHANGED",
    -- guild bank (...\GuildBankDocumentation.lua)
    "GUILDBANKFRAME_OPENED",
    "GUILDBANKFRAME_CLOSED",
    "GUILDBANKBAGSLOTS_CHANGED",
    "GUILDBANK_UPDATE_TABS",
    "GUILDBANK_UPDATE_MONEY",
    "GUILDBANK_ITEM_LOCK_CHANGED",
    "GUILDBANKLOG_UPDATE",
    "GUILDBANK_TEXT_CHANGED",
    -- the guild bank UI is load-on-demand, so its load is itself a signal
    "ADDON_LOADED",
    -- Ascension's Personal Bank is reached by USING an item (110000), which
    -- summons the "Personal Belongings" object (46). Nothing in Extensions.dll
    -- mentions a personal bank, so it is the guild bank system reused
    -- server-side -- meaning the guild events below fire for BOTH banks and the
    -- only client-visible difference is what preceded the open, plus the tab
    -- identity the server sends. This is the "what preceded it" half.
    "UNIT_SPELLCAST_SUCCEEDED",
    -- retail-only; registering it here proves whether this client knows the name
    "PLAYER_INTERACTION_MANAGER_FRAME_SHOW",
}

-- Events that arrive in bursts while a bank is open. Logged, but they must not
-- drown the open/close lines, so they only log while a session is open.
local BANK_WATCH_NOISY = {
    PLAYERBANKSLOTS_CHANGED = true,
    PLAYERBANKBAGSLOTS_CHANGED = true,
    GUILDBANKBAGSLOTS_CHANGED = true,
    GUILDBANK_ITEM_LOCK_CHANGED = true,
    GUILDBANK_UPDATE_MONEY = true,
    GUILDBANK_TEXT_CHANGED = true,
    GUILDBANKLOG_UPDATE = true,
}

local bankWatchFrame = nil
local bankWatchStart = 0
local bankWatchSessionOpen = false
local bankWatchHookedGuildFrame = false

--- Call `fn` and stringify its first return; a missing/erroring API becomes
--- "n/a" rather than aborting the handler mid-snapshot.
local function safeCall(fn, ...)
    if type(fn) ~= "function" then return "n/a" end
    local ok, v = pcall(fn, ...)
    if not ok then return "err" end
    if v == nil then return "nil" end
    return tostring(v)
end

local function frameState(name)
    local f = _G[name]
    if not f then return name .. "=absent" end
    local shown = (f.IsShown and f:IsShown()) and "shown" or "hidden"
    return name .. "=" .. shown
end

--- One line of everything that could tell the two banks apart. GetNumGuildBankTabs
--- > 0 next to the event name is the actual discriminator; the rest is here so a
--- surprising answer can be explained without a second trip to the banker.
local function bankWatchState()
    return table.concat({
        "target=" .. safeCall(UnitName, "target"),
        "guid=" .. safeCall(UnitGUID, "target"),
        "guildTabs=" .. safeCall(GetNumGuildBankTabs),
        "curTab=" .. safeCall(GetCurrentGuildBankTab),
        "guildMoney=" .. safeCall(GetGuildBankMoney),
        "bankSlots=" .. safeCall(GetNumBankSlots),
        "inGuild=" .. safeCall(IsInGuild),
        frameState("BankFrame"),
        frameState("GuildBankFrame"),
        "gbUILoaded=" .. safeCall(IsAddOnLoaded, "Blizzard_GuildBankUI"),
    }, " | ")
end

local function bankWatchLog(fmt, ...)
    line("|cffffff00[bankwatch +%.2fs]|r " .. fmt, GetTime() - bankWatchStart, ...)
    -- Written on every line, not just at stop: the answer must survive a
    -- disconnect at the banker as well as a clean /reload.
    GudaBags_Diag = report
end

-- Last thing the player cast, kept so an open can be attributed to what caused
-- it. Using the Personal Bank item is a cast; walking up to a guild banker is
-- not, so "a cast landed 2s ago" is the behavioural discriminator if the tab
-- identity below turns out to be identical for both banks.
local bankWatchLastCast, bankWatchLastCastAt = nil, 0

--- Who the server thinks this guild-bank session belongs to. Tab NAMES are the
--- most promising discriminator: the Personal Bank is the guild bank system
--- reused, so the packets are the same, but the tabs it sends are the server's
--- own. Printed on open AND again on GUILDBANK_UPDATE_TABS, because tab info
--- arrives asynchronously and is usually still empty at the moment of the open.
local function DumpGuildBankIdentity(why)
    -- Same predicate the addon itself uses, so the log can never disagree with
    -- the "Personal Bank Opened" line -- and so a wrong verdict is visible here
    -- next to the raw fields it was derived from.
    local GuildBankScanner = ns:GetModule("GuildBankScanner")
    local verdict = (GuildBankScanner and GuildBankScanner.GetBankKind)
        and safeCall(GuildBankScanner.GetBankKind, GuildBankScanner) or "n/a"
    bankWatchLog("  identity (%s): verdict=%s", why, verdict)
    bankWatchLog("    guild=%s | numTabs=%s | money=%s | withdrawLimit=%s | canWithdrawMoney=%s",
        safeCall(GetGuildInfo, "player"),
        safeCall(GetNumGuildBankTabs),
        safeCall(GetGuildBankMoney),
        safeCall(GetGuildBankWithdrawLimit),
        safeCall(CanWithdrawGuildBankMoney))

    local numTabs = tonumber(safeCall(GetNumGuildBankTabs)) or 0
    if numTabs == 0 then
        bankWatchLog("    (no tabs reported yet)")
        return
    end
    for i = 1, numTabs do
        local ok, name, icon, isViewable, canDeposit, numWithdrawals = pcall(GetGuildBankTabInfo, i)
        if ok then
            bankWatchLog("    tab %d: name=%s | icon=%s | viewable=%s | deposit=%s | withdrawals=%s | text=%s",
                i, tostring(name), tostring(icon), tostring(isViewable),
                tostring(canDeposit), tostring(numWithdrawals),
                safeCall(GetGuildBankText, i))
        else
            bankWatchLog("    tab %d: GetGuildBankTabInfo errored", i)
        end
    end
end

-- Log-only hook on Blizzard's guild bank frame. HookScript, never SetScript:
-- Data\GuildBankScanner.lua:539 hooks the same frame for real behaviour and must
-- not be displaced.
-- HookScript is additive and cannot be undone, so both callbacks check the
-- enabled flag themselves: once the watcher is stopped they must go quiet
-- instead of printing for the rest of the session.
local BankWatchEnabled   -- forward declaration; defined with the toggle below

local function BankWatchHookGuildFrame()
    if bankWatchHookedGuildFrame then return end
    local f = _G.GuildBankFrame
    if not f or not f.HookScript then return end
    bankWatchHookedGuildFrame = true
    f:HookScript("OnShow", function()
        if not BankWatchEnabled() then return end
        bankWatchSessionOpen = true
        bankWatchLog(">>> GUILD-BANK-TYPE FRAME SHOWN (Blizzard GuildBankFrame OnShow)")
        bankWatchLog("    %s", bankWatchState())
        DumpGuildBankIdentity("frame OnShow")
    end)
    f:HookScript("OnHide", function()
        if not BankWatchEnabled() then return end
        bankWatchLog("<<< guild bank frame hidden")
    end)
    bankWatchLog("hooked Blizzard GuildBankFrame OnShow/OnHide")
end

--- How long ago the player last cast something, as a string. "never" when the
--- watcher has not seen a cast this session.
local function lastCastAgo()
    if not bankWatchLastCast then return "never" end
    return ("%s (%.1fs ago)"):format(bankWatchLastCast, GetTime() - bankWatchLastCastAt)
end

local function BankWatchOnEvent(_, event, arg1, arg2)
    if event == "ADDON_LOADED" then
        if arg1 ~= "Blizzard_GuildBankUI" then return end
        bankWatchLog("ADDON_LOADED: Blizzard_GuildBankUI (guild bank UI is load-on-demand)")
        BankWatchHookGuildFrame()
        return
    end

    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        -- Recorded silently -- every cast in combat would otherwise bury the
        -- bank lines. Reported as part of the open snapshot instead.
        if arg1 == "player" and arg2 then
            bankWatchLastCast, bankWatchLastCastAt = tostring(arg2), GetTime()
        end
        return
    end

    if event == "BANKFRAME_OPENED" then
        bankWatchSessionOpen = true
        bankWatchLog(">>> BANKER BANK OPENED (BANKFRAME_OPENED) -- the normal banker")
    elseif event == "GUILDBANKFRAME_OPENED" then
        bankWatchSessionOpen = true
        -- Both the real guild bank and Ascension's Personal Bank land here.
        bankWatchLog(">>> GUILD-BANK-TYPE OPENED (GUILDBANKFRAME_OPENED) -- guild bank OR Personal Bank")
        bankWatchLog("    lastCast=%s", lastCastAgo())
    elseif event == "BANKFRAME_CLOSED" or event == "GUILDBANKFRAME_CLOSED" then
        bankWatchLog("<<< %s", event)
        bankWatchSessionOpen = false
    elseif event == "GUILDBANK_UPDATE_TABS" then
        bankWatchLog("%s", event)
        DumpGuildBankIdentity("GUILDBANK_UPDATE_TABS")
        return
    elseif BANK_WATCH_NOISY[event] then
        if not bankWatchSessionOpen then return end
        bankWatchLog("%s", event)
        return   -- burst event: name only, no snapshot
    else
        bankWatchLog("%s", event)
    end

    bankWatchLog("    %s", bankWatchState())

    if event == "GUILDBANKFRAME_OPENED" then
        DumpGuildBankIdentity("at open")
        -- Tab names usually arrive after the open, so take a second look once
        -- the server has answered; that late pass is the one likely to carry
        -- the name that separates the two banks.
        if C_Timer and C_Timer.After then
            C_Timer.After(1.5, function()
                if BankWatchEnabled() then DumpGuildBankIdentity("1.5s after open") end
            end)
        end
    end
end

--- `quiet` is the login re-arm: the full registration report belongs to the run
--- where you switched the watcher on, not to every subsequent login. Re-arming
--- silently would be worse though -- a watcher you forgot about is exactly what
--- makes its output look like the addon spamming you -- so it still says one line.
local function StartBankWatch(quiet)
    if not bankWatchFrame then
        bankWatchFrame = CreateFrame("Frame")
        bankWatchFrame:SetScript("OnEvent", BankWatchOnEvent)
    end
    bankWatchStart = GetTime()
    bankWatchSessionOpen = false

    if quiet then
        for _, event in ipairs(BANK_WATCH_EVENTS) do
            pcall(bankWatchFrame.RegisterEvent, bankWatchFrame, event)
        end
        if IsAddOnLoaded and IsAddOnLoaded("Blizzard_GuildBankUI") then
            BankWatchHookGuildFrame()
        end
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff00ccff[diag]|r bank watch is still ARMED from an earlier session -- /guda diag bank to stop it")
        return
    end

    line("---- bank watch ARMED ----")
    local ok, rejected = {}, {}
    for _, event in ipairs(BANK_WATCH_EVENTS) do
        -- RegisterEvent RAISES on a name this client does not know, so each one
        -- is guarded and the failure recorded: a rejected name is itself an answer.
        if pcall(bankWatchFrame.RegisterEvent, bankWatchFrame, event) then
            ok[#ok + 1] = event
        else
            rejected[#rejected + 1] = event
        end
    end
    line("registered (%d): %s", #ok, table.concat(ok, ", "))
    if #rejected > 0 then
        line("REJECTED by this client (%d): %s", #rejected, table.concat(rejected, ", "))
    else
        line("REJECTED by this client: none")
    end

    -- Nothing else prints this, and "the addon already knows this event does not
    -- exist" is exactly the kind of finding we are here for.
    local Events = ns:GetModule("Events")
    if Events and type(Events.unsupported) == "table" then
        local names = {}
        for name in pairs(Events.unsupported) do names[#names + 1] = name end
        table.sort(names)
        line("Events.unsupported (%d): %s", #names,
            #names > 0 and table.concat(names, ", ") or "none")
    end

    if IsAddOnLoaded and IsAddOnLoaded("Blizzard_GuildBankUI") then
        BankWatchHookGuildFrame()
    else
        line("Blizzard_GuildBankUI not loaded yet -- will hook its frame when it loads")
    end

    line("Now open a normal banker, close it, then open a guild banker.")
    line("Run /guda diag bank again to stop, then /reload to write GudaBags_Diag.")
end

local function StopBankWatch()
    if bankWatchFrame then
        pcall(bankWatchFrame.UnregisterAllEvents, bankWatchFrame)
    end
    -- The OnShow/OnHide hooks cannot be removed (HookScript is additive), so they
    -- stay for the session; they early-out below via the enabled flag.
    line("---- bank watch STOPPED ---- /reload to write GudaBags_Diag to disk")
end

--- Enabled state lives in the account DB so it survives /reload: the watcher is
--- armed once and left running while walking between the two bankers.
--- Assigns the forward-declared local above -- do NOT add `local` here.
function BankWatchEnabled()
    return type(GudaBags_DB) == "table" and GudaBags_DB.diagBankWatch == true
end

local function ToggleBankWatch()
    if type(GudaBags_DB) ~= "table" then
        line("GudaBags_DB not initialised yet -- try again after login completes")
        return
    end
    if BankWatchEnabled() then
        GudaBags_DB.diagBankWatch = nil
        StopBankWatch()
    else
        GudaBags_DB.diagBankWatch = true
        StartBankWatch()
    end
end

-- Re-arm after a /reload if it was left on.
function Diagnostics:RestoreBankWatch()
    if BankWatchEnabled() then
        report = {}
        StartBankWatch(true)   -- quiet: one reminder line, not the full report
    end
end

--- Why the Personal Bank sort does or does not do anything -- in one read-only
--- pass, saved to disk.
---
--- docs\PERSONAL_BANK_SORT_PLAN.md section 3 lists a bail reason per failure, but
--- those only reach chat, only while /guda debug is on, and only if someone is
--- watching -- which is why the failure went unmeasured for three sessions. This
--- lands the same facts in GudaBags_Diag, where they survive a /reload and can be
--- read off disk.
---
--- Moves nothing and changes nothing: the plan comes from GuildBankSort:DryRun.
--- The point of the cached-vs-live pair is the comparison -- a divergence means
--- the sorter was planning against stale data, and identical-but-unchanged after
--- a move means the client never refreshed the tab.
local function DumpGuildBankSort()
    local GuildBankSort = ns:GetModule("GuildBankSort")
    local GuildBankScanner = ns:GetModule("GuildBankScanner")
    local GuildBankFrame = ns:GetModule("GuildBankFrame")

    line("=== guild bank sort ===")
    line("build: %s", tostring(ns.version))

    -- 1. Wiring. Sorting\GuildBankSort.lua is a .toc addition, and a .toc addition
    -- does not load on /reload -- so "module absent" here means restart the
    -- client, not fix the code.
    local FEATURES = (ns.Constants and ns.Constants.FEATURES) or {}
    line("modules: GuildBankSort=%s | GuildBankScanner=%s | GuildBankFrame=%s",
        tostring(GuildBankSort ~= nil), tostring(GuildBankScanner ~= nil),
        tostring(GuildBankFrame ~= nil))
    line("features: GUILD_BANK=%s | SORT=%s",
        tostring(FEATURES.GUILD_BANK), tostring(FEATURES.SORT))

    if not GuildBankScanner then
        line("GuildBankScanner missing -- nothing further can be read")
        return
    end

    -- 2. Session. The sort refuses anything that is not a resolved personal
    -- session, and addresses one tab -- so both have to be visible here.
    local personalMode = (GuildBankFrame and GuildBankFrame.IsPersonalMode)
        and safeCall(GuildBankFrame.IsPersonalMode, GuildBankFrame) or "n/a"
    line("session: open=%s | kind=%s | personalMode=%s | sorting=%s",
        safeCall(GuildBankScanner.IsGuildBankOpen, GuildBankScanner),
        safeCall(GuildBankScanner.GetSessionKind, GuildBankScanner),
        personalMode,
        (GuildBankSort and GuildBankSort.IsSorting)
            and safeCall(GuildBankSort.IsSorting, GuildBankSort) or "n/a")
    line("tabs: numTabs=%s | currentTab=%s | selectedTab=%s | slotsPerTab=%s",
        safeCall(GetNumGuildBankTabs),
        safeCall(GetCurrentGuildBankTab),
        safeCall(GuildBankScanner.GetSelectedTab, GuildBankScanner),
        safeCall(GuildBankScanner.GetSlotsPerTab, GuildBankScanner))

    local numTabs = tonumber(safeCall(GetNumGuildBankTabs)) or 0
    for i = 1, numTabs do
        local ok, name, icon, isViewable, canDeposit, numWithdrawals, remaining =
            pcall(GetGuildBankTabInfo, i)
        if ok then
            line("  tab %d: name=%s | icon=%s | viewable=%s | deposit=%s | withdrawals=%s/%s",
                i, tostring(name), tostring(icon), tostring(isViewable),
                tostring(canDeposit), tostring(remaining), tostring(numWithdrawals))
        else
            line("  tab %d: GetGuildBankTabInfo errored", i)
        end
    end

    -- The tab the sorter would actually address, resolved the same way it does.
    local tab = tonumber(safeCall(GetCurrentGuildBankTab)) or 0
    if tab < 1 then tab = tonumber(safeCall(GuildBankScanner.GetSelectedTab, GuildBankScanner)) or 0 end
    if tab < 1 then
        line("no usable tab index -- the sort would bail with 'no current tab'")
        return
    end
    line("sorting would target tab %d", tab)

    local slotsPerTab = tonumber(safeCall(GuildBankScanner.GetSlotsPerTab, GuildBankScanner)) or 98

    -- 3. Cached tab. Note slots is SPARSE -- keyed by slot index, empties absent.
    local okCached, tabData = pcall(GuildBankScanner.GetCachedTab, GuildBankScanner, tab)
    if not okCached then tabData = nil end
    if not tabData then
        line("cached tab %d: ABSENT -- the sort would bail with 'no cached data'", tab)
    else
        local occupied, shown = 0, 0
        for slot = 1, (tabData.numSlots or slotsPerTab) do
            local d = tabData.slots and tabData.slots[slot]
            if d then
                occupied = occupied + 1
                if shown < 10 then
                    shown = shown + 1
                    line("  cached %3d: id=%s x%s q=%s class=%s/%s ilvl=%s locked=%s %s",
                        slot, tostring(d.itemID), tostring(d.count), tostring(d.quality),
                        tostring(d.classID), tostring(d.subclassID),
                        tostring(d.itemLevel), tostring(d.locked), tostring(d.name))
                end
            end
        end
        line("cached tab %d: numSlots=%s freeSlots=%s occupied=%d",
            tab, tostring(tabData.numSlots), tostring(tabData.freeSlots), occupied)
    end

    -- 4. Live tab, read straight from the client with the same two calls the
    -- sorter verifies moves with.
    local liveOccupied, liveShown = 0, 0
    for slot = 1, slotsPerTab do
        local okInfo, texture, count, locked = pcall(GetGuildBankItemInfo, tab, slot)
        local okLink, link = pcall(GetGuildBankItemLink, tab, slot)
        if okInfo and texture then
            liveOccupied = liveOccupied + 1
            if liveShown < 10 then
                liveShown = liveShown + 1
                local itemID = okLink and link and tostring(link):match("item:(%d+)") or "nil"
                line("  live   %3d: id=%s x%s locked=%s link=%s",
                    slot, itemID, tostring(count), tostring(locked),
                    okLink and tostring(link) or "err")
            end
        end
    end
    line("live tab %d: occupied=%d of %d", tab, liveOccupied, slotsPerTab)

    -- 5. The plan itself. Zero moves against a non-empty tab is the 'already
    -- sorted' bail, and says the comparator -- not the mover -- is the problem.
    if not (GuildBankSort and GuildBankSort.DryRun) then
        line("GuildBankSort:DryRun unavailable -- cannot plan (old build loaded?)")
        return
    end
    local Database = ns:GetModule("Database")
    line("sortPriority=%s", Database and safeCall(Database.GetSetting, Database, "sortPriority") or "n/a")

    local function reportPlan(label)
        local ok, moves = pcall(GuildBankSort.DryRun, GuildBankSort, tab)
        if not ok then
            line("%s plan: errored: %s", label, tostring(moves))
            return
        end
        if not moves then
            line("%s plan: nothing -- no snapshot for tab %d", label, tab)
            return
        end
        line("%s plan: %d moves", label, #moves)
        for i = 1, math.min(10, #moves) do
            local m = moves[i]
            line("  move %2d: slot %d -> %d (id=%s x%s)",
                i, m.srcSlot, m.dstSlot, tostring(m.itemID), tostring(m.count))
        end
    end

    -- DryRun plans from the scanner's cache, so this first pass is what a sort
    -- would have produced from stale data.
    reportPlan("cached")

    -- Then the plan the sort actually builds, which rescans first. The only side
    -- effect of this whole dump: it refreshes the scanner cache, exactly as any
    -- bank event does. If the two plans differ, staleness was the problem.
    if GuildBankScanner.ScanTab and GuildBankScanner:IsGuildBankOpen() then
        pcall(GuildBankScanner.ScanTab, GuildBankScanner, tab)
        reportPlan("rescanned")
    end

    -- 6. The last sort's own trace. A sort points GudaBags_Diag at its log, so
    -- running this probe afterwards would otherwise throw that log away -- fold it
    -- in instead, and the two can be read together.
    local log = GuildBankSort.GetLog and GuildBankSort:GetLog()
    if log and #log > 0 then
        line("--- last sort trace (%d lines) ---", #log)
        for i = 1, #log do line("  %s", tostring(log[i])) end
    else
        line("--- no sort has run this session ---")
    end
end

--- /guda diag [shim|mouse|children|restack|mog|markers|guid|taint|currency|bank|gbsort|unblock]
function Diagnostics:Dispatch(arg)
    if arg == "gbsort" then
        report = {}
        pcall(DumpGuildBankSort)
        GudaBags_Diag = report
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff00ccff[diag]|r saved to GudaBags_Diag -- /reload to write it to disk")
        return
    end
    if arg == "bank" then
        if not BankWatchEnabled() then report = {} end   -- keep prior lines when stopping
        pcall(ToggleBankWatch)
        GudaBags_Diag = report
        return
    end
    if arg == "shim" then
        report = {}
        pcall(DumpShimReport)
        GudaBags_Diag = report
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff00ccff[diag]|r saved to GudaBags_Diag -- /reload to write it to disk")
        return
    elseif arg == "mouse" then
        report = {}
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffGudaBags|r scanning for mouse blockers...")
        pcall(DumpMouseBlockers)
        GudaBags_Diag = report
        return
    elseif arg == "children" then
        report = {}
        pcall(DumpChildren)
        GudaBags_Diag = report
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[diag]|r saved to GudaBags_Diag -- /reload to write it")
        return
    elseif arg == "restack" then
        report = {}
        pcall(DumpRestackLog)
        GudaBags_Diag = report
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff00ccff[diag]|r saved to GudaBags_Diag -- /reload to write it to disk")
        return
    elseif arg == "mog" then
        report = {}
        pcall(DumpTransmogLines)
        GudaBags_Diag = report
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff00ccff[diag]|r saved to GudaBags_Diag -- /reload to write it to disk")
        return
    elseif arg == "markers" then
        report = {}
        pcall(DumpMarkerState)
        GudaBags_Diag = report
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff00ccff[diag]|r saved to GudaBags_Diag -- /reload to write it to disk")
        return
    elseif arg == "guid" then
        -- Reset only on the baseline run. The baseline and the after-move run are
        -- one investigation and only the last GudaBags_Diag written reaches disk,
        -- so the second run must append to keep both halves readable in the file.
        if not guidSnapshot then report = {} end
        pcall(DumpItemGUIDs)
        GudaBags_Diag = report
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff00ccff[diag]|r saved to GudaBags_Diag -- /reload to write it to disk")
        return
    elseif arg == "taint" then
        report = {}
        pcall(DumpTaintSurface)
        GudaBags_Diag = report
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff00ccff[diag]|r saved to GudaBags_Diag -- /reload to write it to disk")
        return
    elseif arg == "currency" then
        report = {}
        pcall(DumpCurrencyAPI)
        GudaBags_Diag = report
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff00ccff[diag]|r saved to GudaBags_Diag -- /reload to write it to disk")
        return
    elseif arg == "unblock" then
        report = {}
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffGudaBags|r disabling mouse on large non-GudaBags frames...")
        pcall(UnblockMouse)
        GudaBags_Diag = report
        return
    end
    RunDiagnostics()
end

-- NO AUTO-RUN. This deliberately does not fire on login any more.
--
-- It used to, so that a report could be produced without needing the keyboard.
-- But DumpSettings has to Show() the settings popup in order to measure it, and
-- that popup is a 620x560 mouse-enabled frame in the centre of the screen. Force
-- opening it on every login meant the game could be left unclickable -- no
-- targeting, no camera, no action bars -- for reasons that produced no error and
-- looked nothing like a settings window, because the popup draws its background
-- from the theme rather than from the frame itself.
--
-- A diagnostic must never change the state it is measuring. Run it explicitly.
--
-- The one exception below is not that: re-arming the bank watcher only registers
-- events and prints, it shows no frame and touches no UI state. It exists so the
-- watcher can be switched on once and survive the /reload between visiting the
-- two bankers, which is the whole point of persisting its flag.
do
    local Events = ns:GetModule("Events")
    if Events then
        Events:Register("PLAYER_LOGIN", function()
            if Diagnostics.RestoreBankWatch then
                pcall(Diagnostics.RestoreBankWatch, Diagnostics)
            end
        end, Diagnostics)
    end
end
