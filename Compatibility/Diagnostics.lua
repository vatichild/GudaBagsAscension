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

-- Bump on every change to this file. Editing a Lua file does not affect the
-- running session, so a /gbdiag issued before the next /reload silently reports
-- from the OLD code -- which has already cost a round trip. Stamping the build
-- into the report makes stale output obvious at a glance instead of something to
-- reconstruct from file timestamps.
local DIAG_BUILD = "2026-07-21-h (shim probes parked under hidden parent)"

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
-- Frames we have already hooked, so repeat /gbdiag runs do not stack hooks.
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
    line("watching %d frame(s) for Show(). Open your bags, then run /gbdiag again.", hooked)
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

SLASH_GUDABAGSDIAG1 = "/gbdiag"
SlashCmdList["GUDABAGSDIAG"] = function(arg)
    if arg == "mouse" then
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
