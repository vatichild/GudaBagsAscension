local addonName, ns = ...

-- Lightweight, debug-gated performance profiler.
--
-- Everything here is a no-op unless ns.profileMode is true, so it adds zero
-- cost in normal play. Enable with `/guda profile`, exercise the addon (open
-- bags/bank, sort, etc.), then `/guda profiledump` to print a summary.
--
-- It also hosts the live A/B "suspect" toggles (ns.suspectDisabled) so the user
-- can disable one subsystem at a time (`/guda toggle tooltipscan`) and re-measure
-- to attribute cost. See the call sites that check ns.suspectDisabled[...].

ns.profileMode = false

-- Runtime A/B switches. When a key is true, that subsystem is skipped at its
-- call site. These are debug-only switches, NOT user settings.
ns.suspectDisabled = ns.suspectDisabled or {}

-- High-resolution clock (seconds, fractional). Same source used by Pawn compat.
local GetTime = GetTimePreciseSec

-- label -> { count, total (ms), max (ms) }
local stats = {}
-- label -> start time (for Start/Stop pairs)
local starts = {}

local function getStat(label)
    local s = stats[label]
    if not s then
        s = { count = 0, total = 0, max = 0 }
        stats[label] = s
    end
    return s
end

-- Begin timing a named phase. Pair with ns:ProfileStop(label).
-- Calling Start/Stop repeatedly with the same label accumulates (count sums,
-- total sums, max tracks the worst single occurrence) — ideal for per-item work.
function ns:ProfileStart(label)
    if not self.profileMode then return end
    starts[label] = GetTime()
end

function ns:ProfileStop(label)
    if not self.profileMode then return end
    local st = starts[label]
    if not st then return end
    starts[label] = nil
    local ms = (GetTime() - st) * 1000
    local s = getStat(label)
    s.count = s.count + 1
    s.total = s.total + ms
    if ms > s.max then s.max = ms end
end

-- Add an externally measured duration (ms) to a label's running totals.
function ns:ProfileAdd(label, ms, count)
    if not self.profileMode then return end
    local s = getStat(label)
    s.count = s.count + (count or 1)
    s.total = s.total + ms
    if ms > s.max then s.max = ms end
end

-- Bump a plain counter (cache hit/miss, event count, ...). No timing.
function ns:ProfileBump(label, n)
    if not self.profileMode then return end
    local s = getStat(label)
    s.count = s.count + (n or 1)
end

function ns:ProfileReset()
    stats = {}
    starts = {}
end

-- Print a compact summary table sorted by total time descending.
function ns:ProfileDump()
    local rows = {}
    for label, s in pairs(stats) do
        rows[#rows + 1] = { label = label, s = s }
    end
    if #rows == 0 then
        self:Print("Profiler: no samples. Enable with /guda profile, then use the bags.")
        return
    end
    table.sort(rows, function(a, b) return a.s.total > b.s.total end)

    self:Print("=== GudaBags Profiler ===")
    self:Print(string.format("%-28s %6s %9s %8s %8s", "label", "count", "total ms", "avg ms", "max ms"))
    for _, row in ipairs(rows) do
        local s = row.s
        local avg = s.count > 0 and (s.total / s.count) or 0
        self:Print(string.format("%-28s %6d %9.2f %8.3f %8.3f",
            row.label, s.count, s.total, avg, s.max))
    end
end
