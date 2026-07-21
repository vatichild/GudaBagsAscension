-- GudaBags Diagnostics (3.3.5a port aid)
-- =====================================================================
-- /gbdiag  -- inspect what the settings popup ACTUALLY built.
--
-- "The frame is empty" has many possible causes: content never created, created
-- but zero-sized, created but hidden, or created off-screen. Guessing between
-- them from a screenshot wastes a client run each time, so measure instead.
-- Results go to chat AND to the GudaBags_Diag saved variable.
-- =====================================================================

local addonName, ns = ...

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
-- Enable with /gbtrace on. Off by default -- it is a debugging aid, not
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

SLASH_GUDABAGSTRACE1 = "/gbtrace"
SlashCmdList["GUDABAGSTRACE"] = function(arg)
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
            "as 'Last FrameScript_Execute'. |cffffff00/gbtrace off|r to stop.")
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

local function DumpSettings()
    report = {}
    local SettingsPopup = ns:GetModule("SettingsPopup")
    if not SettingsPopup then line("SettingsPopup module NOT REGISTERED"); return end

    -- Force the frame to exist.
    local ok, err = pcall(function() SettingsPopup:Show() end)
    if not ok then
        line("SettingsPopup:Show() ERRORED -> %s", tostring(err))
        -- Keep going: a partially built frame is still worth measuring.
    else
        line("SettingsPopup:Show() ok")
    end

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

local function RunDiagnostics(quiet)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffGudaBags diagnostics|r")
    pcall(DumpSchema)
    pcall(DumpSettings)

    -- DumpSettings has to Show() the popup to measure it. Put it back.
    if quiet then
        local SettingsPopup = ns:GetModule("SettingsPopup")
        if SettingsPopup and SettingsPopup.Hide then pcall(SettingsPopup.Hide, SettingsPopup) end
    end

    GudaBags_Diag = report
    DEFAULT_CHAT_FRAME:AddMessage(
        "|cff00ccff[diag]|r saved to GudaBags_Diag -- log out or /reload to write it to disk")
end

SLASH_GUDABAGSDIAG1 = "/gbdiag"
SlashCmdList["GUDABAGSDIAG"] = function() RunDiagnostics(false) end

-- Run once automatically shortly after login. Typing a slash command requires a
-- working keyboard, and keybindings are one of the things this port has been
-- breaking -- so the diagnostic must not depend on them. SavedVariables are
-- flushed on logout, so a plain "log in, play briefly, log out" produces a full
-- report with no input required.
do
    local auto = CreateFrame("Frame")
    auto:RegisterEvent("PLAYER_LOGIN")
    auto:SetScript("OnEvent", function(self)
        self:UnregisterEvent("PLAYER_LOGIN")
        -- Delay so every module has finished its own PLAYER_LOGIN work first.
        if C_Timer and C_Timer.After then
            C_Timer.After(5, function() pcall(RunDiagnostics, true) end)
        else
            pcall(RunDiagnostics, true)
        end
    end)
end
