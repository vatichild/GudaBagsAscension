-- GudaBags Error Sink (3.3.5a port aid)
-- =====================================================================
-- The 3.3.5a client writes no Lua error log, and Core\Events.lua wraps every
-- event handler in pcall -- so failures vanish into chat and are gone after a
-- relog. This module captures them to a saved variable instead, deduped by
-- message, so a port iteration is "run the client once, then read the file".
--
-- Loads early (see .toc) so it catches errors from every later file.
--
-- SAFETY: an error raised from an OnUpdate handler fires ~60x/second. Anything
-- expensive here (debugstack, chat output, table churn) then freezes the client
-- outright -- which is exactly what an earlier version of this file did. Every
-- guard below exists to make a per-frame error storm cheap and self-limiting.
--
-- OPT-IN, OFF BY DEFAULT (GudaBags_ErrorSink.enabled -- own saved variable, not
-- a Database setting, so this file stays self-contained). seterrorhandler()
-- makes GudaBags the owner of the GLOBAL error handler: every Lua error anywhere
-- in the client, other addons' included, then runs our code inside whatever
-- execution raised it and taints the rest of that execution. That is how a bag
-- addon ends up named in
--   "An action was blocked because of taint from GudaBags - CastSpellByName()"
-- for a /castsequence macro it never touched. Worth it while hunting a bug,
-- not worth it every session.
--
-- What "off" still catches: Capture() is called DIRECTLY by Core\Events.lua
-- (every pcall'd event handler) and by the C_Timer shim, so GudaBags' own
-- failures are still logged with the sink off. What is lost is the rest of the
-- client -- other addons and FrameXML -- which is exactly the part that was
-- making us the taint owner for errors that were never ours.
--
-- Known gap of the deferred install: SavedVariables are restored AFTER an
-- addon's files execute (see `entries` below), so the flag cannot be read until
-- ADDON_LOADED -- by which point GudaBags' own files have already run. Errors
-- raised during file load are therefore no longer captured even when enabled.
-- They still print to chat through whatever handler is installed.
-- =====================================================================

local addonName, ns = ...

-- `entries` -- NOT the saved variable -- is the source of truth.
--
-- SavedVariables are restored AFTER an addon's Lua files execute, so assigning
-- GudaBags_Errors at file scope is pointless: the client overwrites it with last
-- session's table moments later. (That is why an earlier version kept reporting
-- stale errors from a previous run as if they were current.) Collect into a local
-- table and publish it at ADDON_LOADED, once the restore has already happened.
local entries = {}

local CreateFrame = ns.CreateFrame or CreateFrame

local MAX_ENTRIES   = 60      -- distinct messages retained
local MAX_MSG_LEN   = 800
local MAX_EVENTS    = 2000    -- hard stop: after this the sink disables itself
local MAX_FORWARDS  = 10      -- per distinct message, before we stop re-printing

local ErrorSink = {}
ns.ErrorSink = ErrorSink

local seen = {}     -- msg -> entry
local count = 0     -- distinct messages
local events = 0    -- total errors observed
local disabled = false

--- Record one error. Cheap for repeats: a table lookup and an increment.
--- @param msg string   the error message
--- @param source string where it came from (errorhandler / event:NAME)
--- @param stack string  optional; only ever captured once per distinct message
function ErrorSink:Capture(msg, source, stack)
    if disabled then return end

    msg = tostring(msg or "?")
    if #msg > MAX_MSG_LEN then msg = msg:sub(1, MAX_MSG_LEN) .. "..." end

    -- Dedup FIRST. Repeats must stay O(1) with no allocation.
    local entry = seen[msg]
    if entry then
        entry.count = entry.count + 1
        return
    end

    if count >= MAX_ENTRIES then return end

    entry = {
        msg = msg,
        source = source or "unknown",
        stack = stack,
        count = 1,
        first = _G.date and _G.date("%Y-%m-%d %H:%M:%S") or nil,
        version = ns.version,
    }
    seen[msg] = entry
    count = count + 1
    entries[count] = entry
end

-- Publish this session's table over whatever the client restored. Same table
-- reference from here on, so later captures land straight in the saved variable.
--
-- This is also the earliest point at which GudaBags_ErrorSink.enabled is
-- readable, so it is where the global error handler gets installed (or not).
do
    local loader = CreateFrame("Frame")
    loader:RegisterEvent("ADDON_LOADED")
    loader:SetScript("OnEvent", function(self, _, loaded)
        if loaded == addonName then
            GudaBags_Errors = entries
            if type(GudaBags_ErrorSink) ~= "table" then GudaBags_ErrorSink = {} end
            if GudaBags_ErrorSink.enabled then ErrorSink:Install() end
            self:UnregisterEvent("ADDON_LOADED")
        end
    end)
end

-- Messages that must NEVER be rate-limited away.
--
-- Taint and blocked-action errors are the ones you are most likely to be
-- actively hunting, and they repeat -- a tainted execution path usually fires
-- again every time the UI it poisoned runs. Suppressing them after
-- MAX_FORWARDS hid exactly the diagnostic that mattered.
local ALWAYS_FORWARD = {
    "tainted the call",
    "ADDON_ACTION_BLOCKED",
    "ADDON_ACTION_FORBIDDEN",
    "blocked from an action",
}

local function isAlwaysForwarded(msg)
    for i = 1, #ALWAYS_FORWARD do
        if msg:find(ALWAYS_FORWARD[i], 1, true) then return true end
    end
    return false
end

--- True while this message still deserves to reach the normal error display.
local function shouldForward(msg)
    if isAlwaysForwarded(msg) then return true end
    local entry = seen[msg]
    return (not entry) or entry.count <= MAX_FORWARDS
end

-- Chain onto whatever handler is already installed (BugSack, Blizzard's, ...)
-- so we observe errors without swallowing them outright.
--
-- Called from ADDON_LOADED only when the user has opted in, so `previous` is
-- read at INSTALL time rather than at file scope -- by then every other addon
-- has had its chance to install one, and we chain onto the real current handler
-- instead of onto whoever happened to be there when the shim loaded.
local installed = false
function ErrorSink:Install()
    if installed or not seterrorhandler then return end
    installed = true

    local previous = geterrorhandler and geterrorhandler() or nil
    seterrorhandler(function(msg)
        if disabled then
            if previous then return previous(msg) end
            return
        end

        events = events + 1
        if events > MAX_EVENTS then
            -- An unfixable error storm. Stop doing any work at all rather
            -- than dragging the client down with us.
            disabled = true
            if DEFAULT_CHAT_FRAME then
                DEFAULT_CHAT_FRAME:AddMessage(
                    "|cffff5555GudaBags error sink disabled|r after " ..
                    MAX_EVENTS .. " errors. Run |cffffff00/guda errors|r to see them.")
            end
            return
        end

        local text = tostring(msg or "?")
        if #text > MAX_MSG_LEN then text = text:sub(1, MAX_MSG_LEN) .. "..." end

        -- debugstack is expensive: only walk the stack for a message we
        -- have never seen. Repeats skip it entirely.
        --
        -- Skipped for taint/blocked messages too: the client raises those
        -- with no usable Lua stack (the recorded ERROR_HANDLER_DATABASE
        -- entry has an empty `stack` field), so walking it costs time inside
        -- a handler that now runs for every error in the client and returns
        -- nothing worth reading.
        local stack
        if not seen[text] and debugstack and not isAlwaysForwarded(text) then
            stack = debugstack(2, 12, 12)
        end

        local forward = shouldForward(text)
        pcall(ErrorSink.Capture, ErrorSink, msg, "errorhandler", stack)

        -- Suppress runaway re-printing; the saved variable still counts them.
        if previous and forward then return previous(msg) end
    end)

    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff00ccffGudaBags|r error sink |cff33ff33installed|r " ..
            "(|cffffff00/guda errors off|r to stop owning the global error handler).")
    end
end

--- /guda errors [on|off|clear]
--- No SlashCmdList key of its own -- see the header of Compatibility\Diagnostics.lua
--- for why every key we drop is one less way for a macro to be blocked in our name.
function ErrorSink:Dump(arg)
    if arg == "on" or arg == "off" then
        local on = (arg == "on")
        if type(GudaBags_ErrorSink) ~= "table" then GudaBags_ErrorSink = {} end
        GudaBags_ErrorSink.enabled = on
        if on and not installed then
            -- Install now so this session is already covered; the saved flag
            -- keeps it on across reloads.
            self:Install()
        elseif not on and installed then
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cff00ccffGudaBags|r error sink |cffff5555off|r after |cffffff00/reload|r " ..
                "(the handler cannot be uninstalled mid-session).")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffGudaBags|r error sink " ..
                (on and "|cff33ff33on|r" or "|cffff5555off|r") .. ".")
        end
        return
    end
    if arg == "clear" then
        -- Wipe in place: GudaBags_Errors and `entries` must stay the same table.
        for i = #entries, 1, -1 do entries[i] = nil end
        seen, count, events, disabled = {}, 0, 0, false
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffGudaBags|r error log cleared.")
        return
    end
    if count == 0 then
        if not installed then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffGudaBags|r error sink is |cffff5555off|r " ..
                "-- nothing is being captured. |cffffff00/guda errors on|r then |cffffff00/reload|r.")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffGudaBags|r no errors captured. |cff33ff33Clean.|r")
        end
        return
    end
    DEFAULT_CHAT_FRAME:AddMessage(("|cff00ccffGudaBags|r %d distinct error(s), %d total%s:")
        :format(count, events, disabled and " |cffff5555(sink disabled)|r" or ""))
    for i = 1, count do
        local e = entries[i]
        DEFAULT_CHAT_FRAME:AddMessage(("|cffff5555%d.|r [x%d] %s"):format(i, e.count, e.msg))
    end
end
