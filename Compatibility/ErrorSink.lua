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
do
    local loader = CreateFrame("Frame")
    loader:RegisterEvent("ADDON_LOADED")
    loader:SetScript("OnEvent", function(self, _, loaded)
        if loaded == addonName then
            GudaBags_Errors = entries
            self:UnregisterEvent("ADDON_LOADED")
        end
    end)
end

--- True while this message still deserves to reach the normal error display.
local function shouldForward(msg)
    local entry = seen[msg]
    return (not entry) or entry.count <= MAX_FORWARDS
end

-- Chain onto whatever handler is already installed (BugSack, Blizzard's, ...)
-- so we observe errors without swallowing them outright.
do
    local previous = geterrorhandler and geterrorhandler() or nil
    if seterrorhandler then
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
                        MAX_EVENTS .. " errors. Run |cffffff00/gberrors|r to see them.")
                end
                return
            end

            local text = tostring(msg or "?")
            if #text > MAX_MSG_LEN then text = text:sub(1, MAX_MSG_LEN) .. "..." end

            -- debugstack is expensive: only walk the stack for a message we
            -- have never seen. Repeats skip it entirely.
            local stack
            if not seen[text] and debugstack then
                stack = debugstack(2, 12, 12)
            end

            local forward = shouldForward(text)
            pcall(ErrorSink.Capture, ErrorSink, msg, "errorhandler", stack)

            -- Suppress runaway re-printing; the saved variable still counts them.
            if previous and forward then return previous(msg) end
        end)
    end
end

SLASH_GUDABAGSERRORS1 = "/gberrors"
SlashCmdList["GUDABAGSERRORS"] = function(arg)
    if arg == "clear" then
        -- Wipe in place: GudaBags_Errors and `entries` must stay the same table.
        for i = #entries, 1, -1 do entries[i] = nil end
        seen, count, events, disabled = {}, 0, 0, false
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffGudaBags|r error log cleared.")
        return
    end
    if count == 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffGudaBags|r no errors captured. |cff33ff33Clean.|r")
        return
    end
    DEFAULT_CHAT_FRAME:AddMessage(("|cff00ccffGudaBags|r %d distinct error(s), %d total%s:")
        :format(count, events, disabled and " |cffff5555(sink disabled)|r" or ""))
    for i = 1, count do
        local e = entries[i]
        DEFAULT_CHAT_FRAME:AddMessage(("|cffff5555%d.|r [x%d] %s"):format(i, e.count, e.msg))
    end
end
