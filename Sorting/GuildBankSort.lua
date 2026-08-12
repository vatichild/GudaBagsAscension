local addonName, ns = ...

-- Sorting for guild-bank-backed containers (Ascension's Personal Bank).
-- =====================================================================
-- Sorting\SortEngine.lua cannot do this job: it moves items with the CONTAINER
-- API (PickupContainerItem, bagID + slot), while these slots live in the guild
-- bank and are addressed as tab + slot through PickupGuildBankItem. Worse, a
-- guild tabIndex collides with real bag IDs 1-4 and bank bag IDs 5-11
-- (docs\ASCENSION-API.md section 4), so feeding them to the bag sorter would
-- address the wrong container. Hence a separate, deliberately small mover --
-- SortEngine is not touched (RULES rule 4).
--
-- Restricted to the Personal Bank on purpose. In a real guild bank every move is
-- a withdraw + deposit against a per-rank allowance, so sorting one could burn a
-- member's remaining withdrawals or stall halfway on a tab they may only view.
--
-- Order only: slots are rearranged, partial stacks are never merged. Merging
-- means dropping a stack onto a partial one, which leaves the remainder on the
-- cursor and needs a put-back step -- a failure mode that can strand the cursor
-- mid-sort, so it is left out until it is worth the risk.
--
-- Shape: scan once -> plan entirely offline -> execute event-driven, which is the
-- same snapshot/compute/execute split SortEngine uses. See
-- docs\PERSONAL_BANK_SORT_PLAN.md for the debugging record behind each guard.

local Constants = ns.Constants
if not Constants or not Constants.FEATURES or not Constants.FEATURES.GUILD_BANK then
    return
end

local GuildBankSort = {}
ns:RegisterModule("GuildBankSort", GuildBankSort)

local Database = ns:GetModule("Database")
local Events = ns:GetModule("Events")

local GuildBankScanner = nil

-- How long to wait for GUILDBANK_ITEM_LOCK_CHANGED before assuming the server is
-- not going to tell us and checking the slot anyway. The event is the normal
-- path; this only exists so a dropped event cannot wedge a sort forever.
local MOVE_TIMEOUT = 0.5
-- How many MOVE_TIMEOUT ticks a single move may spend unconfirmed before it is
-- treated as failed. Covers a slow server response without wedging the sort.
local MOVE_ATTEMPTS = 4

-- When to re-check the destination after a drop, in seconds.
--
-- The lock event is NOT a landing signal: a successful 25-move sort logged 50 lock
-- events -- two per move -- and not one of them found the destination updated yet.
-- Confirmation only ever came from the timer, so at a flat 0.5s every move cost
-- 0.5s and the sort took 13.5s. Front-loaded instead, so a move that lands quickly
-- is confirmed quickly, with the same ~2s total budget for a slow one.
local MOVE_CHECKS = { 0.1, 0.15, 0.25, 0.5, 0.5, 0.5 }
-- Which check asks the server for the tab again; see the note at that call site.
-- Not the first: at 0.1s nothing has landed yet on any move, so requerying there
-- would fire on every single one.
local MOVE_REQUERY_AT = 3

-- Redraw the grid at most this often while a sort runs. The scanner's per-move
-- rescan is suppressed during a sort (SetSortInProgress) because it would run a
-- full query + scan + refresh per move; this is the middle ground -- the tab is
-- rescanned at most four times a second so items visibly move, and Finish still
-- does exactly one authoritative refresh at the end.
local REDRAW_INTERVAL = 0.25
-- Whole-sort ceiling. 98 slots at worst-case ~0.5s each is well inside this;
-- anything slower means something is wrong and the sort should give up.
local SORT_TIMEOUT = 60
-- A failed verification replans from what the tab actually looks like now instead
-- of abandoning it half sorted. Once: a second failure means the disagreement is
-- not transient, and continuing would move items against a layout we no longer
-- understand.
local MAX_REPLANS = 1

local state = nil       -- nil when idle; table while a sort runs
local stepping = false  -- true only inside StepMove; see Advance()

-------------------------------------------------
-- Tracing
-------------------------------------------------

--- Every line a sort produces, kept for disk as well as chat.
---
--- ns:Debug alone was not enough to debug this feature: it reaches only the chat
--- frame, only while /guda debug is on, and the client does not reliably let chat
--- be copied out. So the same lines are captured here and published to
--- GudaBags_Diag when the sort ends, where a /reload writes them to
--- SavedVariables and they can be read off disk.
local sortLog = {}
local SORT_LOG_MAX = 300   -- a 98-slot sort logs far less; this is a runaway guard

local function trace(...)
    ns:Debug(...)
    if #sortLog < SORT_LOG_MAX then
        sortLog[#sortLog + 1] = string.join(" ", tostringall(...))
    end
end

function GuildBankSort:GetLog()
    return sortLog
end

-------------------------------------------------
-- Ordering
-------------------------------------------------
-- Mirrors the bag sorter's ordering so a sorted Personal Bank reads the same way
-- as sorted bags, and follows the same `sortPriority` setting. The few lines are
-- duplicated from SortEngine's comparator rather than shared, because that file
-- is off limits and its comparator works on its own snapshot entries with
-- pre-inverted keys -- there is nothing here to reuse without touching it.

-- Read once per plan, not once per comparison: a 98 slot tab runs the comparator
-- ~4700 times, and Database:GetSetting inside it made that 4700 setting lookups
-- (RULES rule 2). SortEngine hoists the same value the same way.
local currentSortPriority = "default"

local function CompareItems(a, b)
    -- Empty slots always sort last so items pack toward slot 1.
    if not a.itemID then return false end
    if not b.itemID then return true end

    if currentSortPriority == "ilvl" then
        if a.itemLevel ~= b.itemLevel then return a.itemLevel > b.itemLevel end
        if a.quality ~= b.quality then return a.quality > b.quality end
        if a.classID ~= b.classID then return a.classID < b.classID end
        if a.subClassID ~= b.subClassID then return a.subClassID < b.subClassID end
    elseif currentSortPriority == "quality" then
        if a.quality ~= b.quality then return a.quality > b.quality end
        if a.itemLevel ~= b.itemLevel then return a.itemLevel > b.itemLevel end
        if a.classID ~= b.classID then return a.classID < b.classID end
        if a.subClassID ~= b.subClassID then return a.subClassID < b.subClassID end
    else
        -- "default" and "type": class first, exactly like the bag sorter's
        -- default branch (which is already class-first, so both land here).
        if a.classID ~= b.classID then return a.classID < b.classID end
        if a.subClassID ~= b.subClassID then return a.subClassID < b.subClassID end
        if a.quality ~= b.quality then return a.quality > b.quality end
        if a.itemLevel ~= b.itemLevel then return a.itemLevel > b.itemLevel end
    end

    if a.name ~= b.name then return a.name < b.name end
    if a.itemID ~= b.itemID then return a.itemID < b.itemID end
    return a.count > b.count
end

-------------------------------------------------
-- Tab resolution
-------------------------------------------------

--- Which tab to sort.
---
--- Derived rather than asserted. The Personal Bank is presented as a single tab
--- and the addon pins the selection to 1 in several places -- but this client
--- reports THREE tabs for it (Data\GuildBankScanner.lua GetScanTabs), and a
--- "Personal Bank Tab Voucher" item exists, so "1" is a fact about today's
--- layout, not about the API. Reading the current tab is what keeps the plan and
--- the PickupGuildBankItem calls addressing the same container. Bagnon does the
--- same (components\sortBtn.lua) and refuses to sort when it is 0.
local function ResolveTab()
    local tab = GetCurrentGuildBankTab and GetCurrentGuildBankTab()
    if type(tab) ~= "number" or tab < 1 then
        tab = GuildBankScanner and GuildBankScanner:GetSelectedTab()
    end
    if type(tab) ~= "number" or tab < 1 then return nil end
    return tab
end

-------------------------------------------------
-- Planning (offline -- no API calls)
-------------------------------------------------

--- Snapshot of one tab, built from the scanner's cache. Callers rescan first, so
--- the cache is the fresh single source of truth rather than a second, parallel
--- live-read path.
---
--- Note tabData.slots is SPARSE -- keyed by slot index, empty slots absent -- so
--- it must be indexed, never walked with ipairs or measured with #.
local function BuildSnapshot(tabIndex)
    local tabData = GuildBankScanner and GuildBankScanner:GetCachedTab(tabIndex)
    if not tabData then return nil end

    local numSlots = tabData.numSlots or GuildBankScanner:GetSlotsPerTab()
    local items = {}
    for slot = 1, numSlots do
        local d = tabData.slots and tabData.slots[slot]
        items[#items + 1] = {
            slot = slot,
            itemID = d and d.itemID or nil,
            name = d and d.name or "",
            quality = d and d.quality or 0,
            itemLevel = d and d.itemLevel or 0,
            classID = d and d.classID or 15,
            subClassID = d and (d.subClassID or d.subclassID) or 0,
            count = d and d.count or 0,
            locked = d and d.locked or false,
        }
    end
    return items
end

--- Plan the moves. **Every move targets an EMPTY slot.**
---
--- The Personal Bank will not exchange two occupied slots: dropping an item onto
--- an occupied one is refused with the red "Can't stack items" error, by hand as
--- well as from here. That rules out a swap-based selection sort -- which is what
--- Bagnon does and what this used to do -- because every single one of its moves
--- targets an occupied slot. It is also why Bagnon's guild sort is not a working
--- reference for this bank.
---
--- So: rank the items, then repeatedly move any item whose target slot happens to
--- be empty. When none qualifies, the remaining misplaced items block each other
--- in a cycle -- break it by parking one in a spare slot outside the packed
--- region, which frees the slot the next item was waiting for. Costs one extra
--- move per cycle and never needs an exchange.
---
--- Terminates: a placed item is never moved again (only entries whose slot differs
--- from their rank are considered), and a park always unblocks at least one item
--- on the following pass.
local function PlanMoves(items)
    currentSortPriority = Database:GetSetting("sortPriority") or "default"

    local numSlots = #items

    -- Occupied entries in the order they should end up, so an entry's rank IS its
    -- target slot: rank 1 goes to slot 1, and items pack toward the front.
    local order = {}
    local occupant = {}   -- slot -> entry; the model of the tab, mutated as we plan
    for i = 1, numSlots do
        local entry = items[i]
        if entry.itemID then
            order[#order + 1] = entry
            occupant[entry.slot] = entry
        end
    end
    table.sort(order, CompareItems)

    local moves = {}
    local function record(entry, to)
        moves[#moves + 1] = {
            srcSlot = entry.slot,
            dstSlot = to,
            itemID = entry.itemID,
            count = entry.count,
        }
        occupant[entry.slot] = nil
        occupant[to] = entry
        entry.slot = to
    end

    -- Hard stop. The loop is proven to terminate above; this only keeps a future
    -- edit from hanging the client instead of failing.
    local guard = numSlots * 4

    while guard > 0 do
        guard = guard - 1

        local progressed = false
        for rank = 1, #order do
            local entry = order[rank]
            if entry.slot ~= rank and occupant[rank] == nil then
                record(entry, rank)
                progressed = true
            end
        end
        if progressed then
            -- keep placing; only fall through to cycle-breaking when stuck
        else
            local stuck = nil
            for rank = 1, #order do
                if order[rank].slot ~= rank then stuck = order[rank]; break end
            end
            if not stuck then break end   -- everything is where it belongs

            -- Park outside the packed region (slot > #order) so the parking spot
            -- can never be somebody's target and create a new cycle.
            local spare = nil
            for slot = numSlots, #order + 1, -1 do
                if occupant[slot] == nil then spare = slot; break end
            end
            if not spare then
                trace("GuildBankSort: no free slot to break a cycle, stopping with",
                    #moves, "moves")
                break
            end
            record(stuck, spare)
        end
    end

    return moves
end

-------------------------------------------------
-- Execution (event-driven)
-------------------------------------------------

local StepMove   -- forward declaration; assigned below

local function LinkItemID(link)
    return link and tonumber(link:match("item:(%d+)")) or nil
end

--- Does the cursor hold anything?
---
--- MEASURED ON THIS CLIENT: `CursorHasItem()` returns **false** for a guild-bank
--- item even while the item is visibly on the cursor -- confirmed by watching a
--- bag sit on the cursor for two seconds while the log insisted it was empty.
--- `GetCursorInfo()` reports the same cursor correctly as `"item"`. Its second
--- return is nil for these (no itemID), so the type is all we get -- and all we
--- need. `CursorHasItem` is kept only as a fallback for ordinary item cursors.
local function CursorLoaded()
    local cursorType = GetCursorInfo and GetCursorInfo()
    if cursorType then return true end
    return CursorHasItem() and true or false
end

--- What a slot holds right now, straight from the client.
local function LiveSlot(tab, slot)
    local _, count, locked = GetGuildBankItemInfo(tab, slot)
    return LinkItemID(GetGuildBankItemLink(tab, slot)), count or 1, locked and true or false
end

local function CancelTimers()
    if state and state.timer then
        state.timer:Cancel()
        state.timer = nil
    end
end

--- Single exit point. Always clears the cursor and does exactly one refresh, so
--- an abort can never leave a half-carried item or a stale grid.
local function Finish(reason)
    if not state then return end
    CancelTimers()
    local moved = state.completed
    local total = state.planned
    local lockEvents = state.lockEvents
    local elapsed = GetTime() - state.startedAt
    state = nil

    if ClearCursor then ClearCursor() end

    if GuildBankScanner and GuildBankScanner.SetSortInProgress then
        GuildBankScanner:SetSortInProgress(false)
    end

    -- The lock-event count is the measurement docs\PERSONAL_BANK_SORT_PLAN.md
    -- section 3.1 asks for: zero events alongside a failed verification means the
    -- server never told us the swap landed, and the driver -- not the plan -- is
    -- what needs changing.
    trace("GuildBankSort finished:", reason, "moved", moved, "of", total,
        "in", string.format("%.1fs", elapsed), "|", lockEvents, "lock events")

    -- One query + scan + refresh for the whole sort, instead of the per-move
    -- rescan the lock event would otherwise have triggered.
    if GuildBankScanner and GuildBankScanner:IsGuildBankOpen() then
        GuildBankScanner:ScanAllTabs()
    end
    if ns.OnGuildBankUpdated then
        ns.OnGuildBankUpdated()
    end

    local GuildBankHeader = ns:GetModule("GuildBankFrame.GuildBankHeader")
    if GuildBankHeader and GuildBankHeader.SetSortEnabled then
        GuildBankHeader:SetSortEnabled(true)
    end
end

--- Has the move we issued landed yet?
---
--- Item AND count, never item alone. A tab full of trade goods holds several
--- stacks of the same itemID, so an itemID-only test would read true for a stack
--- that merely happens to match. Every destination is empty before its move (see
--- PlanMoves), so item+count appearing there can only be ours.
local function MoveLanded(move)
    local itemID, count = LiveSlot(state.tab, move.dstSlot)
    return itemID == move.itemID and count == move.count
end

--- Show the tab catching up, without paying for a rescan per move.
local function Redraw()
    if not state then return end
    local now = GetTime()
    if now - (state.lastRedraw or 0) < REDRAW_INTERVAL then return end
    state.lastRedraw = now

    if GuildBankScanner and GuildBankScanner:IsGuildBankOpen() then
        GuildBankScanner:ScanTab(state.tab)
    end
    if ns.OnGuildBankUpdated then
        ns.OnGuildBankUpdated()
    end
end

--- Advance past a completed move.
local function Advance()
    CancelTimers()
    state.completed = state.completed + 1
    state.index = state.index + 1
    Redraw()

    -- Off the event dispatch, deliberately. StepMove issues PickupGuildBankItem,
    -- which itself changes lock state; called inline from the lock handler it can
    -- re-enter this path before the second pickup has been issued, leaving an
    -- orphaned timer and a pickup onto a loaded cursor. C_Timer.After(0) lands it
    -- on the next frame -- which is where Bagnon's driver runs it too. Not a
    -- ticker: exactly one deferred call per completed move (RULES rule 2).
    local mine = state
    C_Timer.After(0, function()
        if state == mine then StepMove() end
    end)
end

--- Rebuild the plan from what the tab looks like now. Returns "continue" when
--- there is more to do, "sorted" when nothing is left, nil when we are out of
--- retries or the data is unusable.
local function Replan()
    if state.replans >= MAX_REPLANS then return nil end
    state.replans = state.replans + 1

    if GuildBankScanner and GuildBankScanner:IsGuildBankOpen() then
        GuildBankScanner:ScanTab(state.tab)
    end
    local items = BuildSnapshot(state.tab)
    if not items then return nil end

    local moves = PlanMoves(items)
    if #moves == 0 then return "sorted" end

    state.moves = moves
    state.index = 1
    state.planned = state.planned + #moves
    return "continue"
end

local OnMoveTimeout   -- forward declaration; assigned below

--- Second half of a swap: click the destination, once the pickup has taken.
---
--- MEASURED ON THIS CLIENT, in two rounds:
---
--- 1. `PickupGuildBankItem` does not load the cursor in the frame it is called.
---    The first captured sort logged 4 lock events -- the call was working -- while
---    a same-frame CursorHasItem() read false, so the sort declared "pickup failed"
---    on move 1 and never issued a swap.
--- 2. Deferring did not help either: the second sort waited the full ladder
---    (4 x 0.5s) and CursorHasItem() stayed false for 2 whole seconds -- **while the
---    item was visibly sitting on the cursor**. So on this client
---    `CursorHasItem()` simply does not report a guild-bank item at all.
---
--- 3. `GetCursorInfo()` reports the very same cursor as `"item"`, immediately.
---    That is the signal the sort runs on -- see CursorLoaded().
---
--- Which also dissolves the Bagnon counter-example: what was verified working in
--- this bank is Bagnon's drag-and-drop, not its sort button, whose
--- `if CursorHasItem() == false then return end` would stall for the same reason.
---
--- Note the source slot is NOT a usable signal either: on 3.3.5a nothing is sent
--- to the server until the destination is clicked, so `GetGuildBankItemLink(src)`
--- legitimately still reports the item during a pickup. Verification of the drop
--- stays what section 2.1 concluded -- read the destination slot, never the cursor.
local function DoDrop()
    if not state then return end
    local move = state.moves[state.index]
    if not move or not move.pickedUp or move.issued then return end

    -- One line per move recording what each signal actually said, so the next
    -- surprise is one log read rather than another session.
    if not move.probed then
        move.probed = true
        local cursorType, cursorItemID = GetCursorInfo and GetCursorInfo()
        trace("GuildBankSort: after pickup src", move.srcSlot,
            "| cursorHasItem", tostring(CursorHasItem() and true or false),
            "| cursorInfo", tostring(cursorType), tostring(cursorItemID),
            "| srcNowHolds", tostring(LiveSlot(state.tab, move.srcSlot)),
            "expected", tostring(move.itemID))
    end

    if not CursorLoaded() then
        return   -- pickup has not taken yet; the ladder retries
    end

    local _, cursorItemID = GetCursorInfo and GetCursorInfo()

    -- If the client does tell us what it handed over and it is not what the plan
    -- picked up, dropping it would misplace a real item. Only trusted when the
    -- second return is actually an itemID -- it is undocumented for guild-bank
    -- cursors here, and a non-numeric value must not abort a healthy sort.
    if type(cursorItemID) == "number" and move.itemID and cursorItemID ~= move.itemID then
        trace("GuildBankSort: cursor holds", tostring(cursorItemID),
            "but move", state.index, "expected", tostring(move.itemID))
        if ClearCursor then ClearCursor() end
        Finish("cursor holds the wrong item")
        return
    end

    if state.timer then
        state.timer:Cancel()
        state.timer = nil
    end

    -- Marked issued BEFORE the call, not after. PickupGuildBankItem dispatches
    -- GUILDBANK_ITEM_LOCK_CHANGED synchronously, which re-enters this function
    -- through OnMoveEvent -- and with the flag set afterwards the re-entry still
    -- saw `issued == false`, found the cursor unchanged in the same frame, and
    -- dropped again. It recursed until the log filled: 300 identical
    -- "move 1 dropped 26 -> 1" lines, alternately picking the item back up and
    -- putting it down, which is where the "Can't stack items" errors came from.
    move.issued = true
    move.waits = 0   -- the landing budget is separate from the pickup budget

    PickupGuildBankItem(state.tab, move.dstSlot)
    trace("GuildBankSort: move", state.index, "dropped", move.srcSlot, "->", move.dstSlot,
        "id", tostring(move.itemID), "x", tostring(move.count))

    -- The move is in flight. The lock event will fire but will not confirm it (see
    -- MOVE_CHECKS), so these timed re-checks are what actually land the move, and
    -- the end of the ladder is the only thing allowed to declare it failed.
    state.timer = C_Timer.NewTimer(MOVE_CHECKS[1], OnMoveTimeout)
end

--- Re-entrancy guard, the same shape as StepMove's. The flag ordering inside
--- DoDrop is what actually prevents the recursion; this makes it structural so a
--- future edit cannot reintroduce it by moving one line.
local dropping = false

local function CheckCursorAndDrop()
    if dropping then return end
    dropping = true
    DoDrop()
    dropping = false
end

--- Called for every GUILDBANK_ITEM_LOCK_CHANGED while sorting.
---
--- One swap produces at least TWO of these -- the pickup locks the source slot,
--- the drop locks the destination -- and the first arrives before the item has
--- landed. So a mismatch here means "not yet", never "failed": we simply keep
--- waiting and let the timer below make the final call. Treating the first event
--- as a verdict would abort every single move.
local function OnMoveEvent()
    -- Ignored while StepMove is mid-swap: the pickup has not been issued yet, so
    -- nothing this handler could conclude would be true. The deferred check picks
    -- the move up a frame later.
    if not state or stepping then return end
    local move = state.moves[state.index]
    if not move then
        Finish("done")
        return
    end

    -- The pickup's own lock event is the earliest signal that the cursor may now
    -- be loaded, so this is the fast path for the second half of the swap.
    if move.pickedUp and not move.issued then
        CheckCursorAndDrop()
        return
    end

    if move.issued and MoveLanded(move) then
        Advance()
    end
end

--- The timer's verdict: by now the server has had MOVE_TIMEOUT to apply the swap,
--- so a slot that still doesn't hold the expected item means the move failed (or
--- something else moved items underneath us) and continuing would issue further
--- moves against a layout we no longer know.
OnMoveTimeout = function()
    if not state then return end
    state.timer = nil

    if GetTime() - state.startedAt > SORT_TIMEOUT then
        Finish("sort timeout")
        return
    end

    local move = state.moves[state.index]
    if not move then
        Finish("done")
        return
    end

    -- Picked up, but the cursor had not loaded yet when we last looked. This is
    -- the normal case on this client for at least one tick -- see
    -- CheckCursorAndDrop -- so keep trying before calling it a failure.
    if move.pickedUp and not move.issued then
        CheckCursorAndDrop()
        if move.issued then return end

        move.waits = (move.waits or 0) + 1
        if move.waits < MOVE_ATTEMPTS then
            trace("GuildBankSort: move", state.index, "cursor still empty, wait", move.waits)
            state.timer = C_Timer.NewTimer(MOVE_TIMEOUT, OnMoveTimeout)
            return
        end
        trace("GuildBankSort: move", state.index, "src", move.srcSlot,
            "pickup produced no cursor item after", move.waits, "waits")
        Finish("pickup failed")
        return
    end

    -- Never even attempted -- StepMove found the cursor loaded or a slot locked
    -- and backed off before issuing anything.
    if not move.pickedUp then
        move.waits = (move.waits or 0) + 1
        if move.waits < MOVE_ATTEMPTS then
            StepMove()
        else
            Finish("cursor never cleared")
        end
        return
    end

    if MoveLanded(move) then
        Advance()
        return
    end

    -- Not landed yet. One check is not proof of failure -- the move can still be
    -- in flight. Walk the MOVE_CHECKS ladder before giving up, so a slow server
    -- costs time rather than a broken sort.
    move.waits = (move.waits or 0) + 1
    local nextCheck = MOVE_CHECKS[move.waits + 1]
    if nextCheck then
        -- Ask the server for the tab again once the move is properly late. Both
        -- scanner handlers stop querying while a sort runs, so if the client only
        -- refreshes tab contents on request, GetGuildBankItemLink would report the
        -- pre-move link forever and every move would "fail".
        if move.waits == MOVE_REQUERY_AT and GuildBankScanner and GuildBankScanner.RequeryTab then
            trace("GuildBankSort: move", state.index, "still not landed, requerying tab")
            GuildBankScanner:RequeryTab(state.tab)
        end
        state.timer = C_Timer.NewTimer(nextCheck, OnMoveTimeout)
        return
    end

    trace("GuildBankSort: move", state.index, "src", move.srcSlot, "dst", move.dstSlot,
        "expected", tostring(move.itemID), "x", tostring(move.count),
        "got", tostring(GetGuildBankItemLink(state.tab, move.dstSlot)),
        "cursor", CursorLoaded() and "held" or "empty")

    local outcome = Replan()
    if outcome == "continue" then
        trace("GuildBankSort: replanned", #state.moves, "moves after a failed verification")
        StepMove()
        return
    elseif outcome == "sorted" then
        Finish("done after replan")
        return
    end

    Finish("verification failed")
end

--- Issue the next swap. Returns without advancing when it has to wait; the lock
--- event (or the timeout) calls back into OnMoveEvent / OnMoveTimeout.
local function DoStep()
    if not state then return end

    if GetTime() - state.startedAt > SORT_TIMEOUT then
        Finish("sort timeout")
        return
    end
    if InCombatLockdown() then
        Finish("combat")
        return
    end
    if not (GuildBankScanner and GuildBankScanner:IsGuildBankOpen()) then
        Finish("bank closed")
        return
    end

    local move = state.moves[state.index]
    if not move then
        Finish("done")
        return
    end

    -- Never pick up onto a loaded cursor: PickupGuildBankItem would DEPOSIT what
    -- we are carrying into the source slot. A cursor here means the previous swap
    -- is still in flight, so wait rather than force it. CursorLoaded, not
    -- CursorHasItem -- the latter does not see guild-bank cursors at all.
    if CursorLoaded() then
        state.timer = C_Timer.NewTimer(MOVE_TIMEOUT, OnMoveTimeout)
        return
    end

    -- Lock state read live, not from the plan. The cached flag is whatever the
    -- last scan saw, which is both stale enough to miss a slot that is locked now
    -- and sticky enough to block a slot that was unlocked long ago.
    local _, _, srcLocked = LiveSlot(state.tab, move.srcSlot)
    local _, _, dstLocked = LiveSlot(state.tab, move.dstSlot)
    if srcLocked or dstLocked then
        state.timer = C_Timer.NewTimer(MOVE_TIMEOUT, OnMoveTimeout)
        return
    end

    -- Two calls per swap, and then hands off the cursor entirely:
    --   1. pick up the source     -> cursor holds A, source empties
    --   2. click the destination  -> the server swaps A with whatever is there
    --
    -- Deliberately NOT a third call back at the source. The move is
    -- server-authoritative: the cursor does not reliably clear in the same frame
    -- as step 2, so a same-frame CursorHasItem() check reads "still holding" for
    -- a swap that is merely in flight, and clicking the source again puts the
    -- item straight back -- undoing the move it just made. Bagnon's guild bank
    -- sorter (components\sortBtn.lua, DoGuildBankMoves) issues these same two
    -- calls and then verifies by reading the destination link rather than the
    -- cursor, which is what the event and timer below do.
    -- Flag before the call, for the same reason the drop does -- see
    -- CheckCursorAndDrop. `stepping` already covers this path, but relying on two
    -- guards where one ordering would do is how the drop loop happened.
    move.pickedUp = true
    move.waits = 0
    PickupGuildBankItem(state.tab, move.srcSlot)

    -- NO same-frame CursorHasItem() check here. It reads false on this client even
    -- for a pickup that is working, and asserting on it aborted every sort on its
    -- first move. CheckCursorAndDrop owns the second half of the swap and runs
    -- when the cursor is actually loaded: next frame first, then the lock event,
    -- then the timer ladder.
    state.timer = C_Timer.NewTimer(MOVE_TIMEOUT, OnMoveTimeout)
    C_Timer.After(0, CheckCursorAndDrop)
end

StepMove = function()
    if stepping then return end
    stepping = true
    DoStep()
    stepping = false
end

--- Called by the scanner's GUILDBANK_ITEM_LOCK_CHANGED handler while a sort runs.
function GuildBankSort:OnLockChanged()
    if state then state.lockEvents = state.lockEvents + 1 end
    OnMoveEvent()
end

function GuildBankSort:IsSorting()
    return state ~= nil
end

-------------------------------------------------
-- Public entry points
-------------------------------------------------

--- Plan only -- moves nothing, changes nothing. Exists for /guda diag gbsort, so
--- "the sort does nothing" can be told apart from "the plan is empty" without
--- touching a single item.
function GuildBankSort:DryRun(tabIndex)
    if not GuildBankScanner then
        GuildBankScanner = ns:GetModule("GuildBankScanner")
    end
    if not GuildBankScanner then return nil end

    local tab = tabIndex or ResolveTab()
    if not tab then return nil end

    local items = BuildSnapshot(tab)
    if not items then return nil end
    return PlanMoves(items), tab
end

--- Sort the Personal Bank's tab. Returns false (and says why in the trace) when
--- the preconditions aren't met, so the caller can leave the button enabled.
function GuildBankSort:SortPersonalBank()
    -- Point the saved variable at this run's log before anything can bail, so even
    -- a refused sort leaves its reason on disk after a /reload. trace() appends to
    -- the same table for the whole run, so there is no publish step to forget and
    -- no way to lose the tail of a sort that never reached Finish.
    sortLog = {}
    GudaBags_Diag = sortLog
    trace("=== personal bank sort === build", tostring(ns.version))

    if not GuildBankScanner then
        GuildBankScanner = ns:GetModule("GuildBankScanner")
    end
    if not GuildBankScanner then
        trace("GuildBankSort: GuildBankScanner module missing")
        return false
    end

    if state then
        trace("GuildBankSort: already running")
        return false
    end
    if InCombatLockdown() then
        trace("GuildBankSort: blocked in combat")
        return false
    end
    if not GuildBankScanner:IsGuildBankOpen() then
        trace("GuildBankSort: bank is not open")
        return false
    end
    -- Personal Bank only; see the note at the top of this file.
    if GuildBankScanner:GetSessionKind() ~= "personal" then
        trace("GuildBankSort: not a personal bank session")
        return false
    end
    if CursorLoaded() then
        trace("GuildBankSort: cursor is not empty")
        return false
    end

    local tab = ResolveTab()
    if not tab then
        trace("GuildBankSort: no current tab")
        return false
    end

    -- Plan against what the tab holds NOW. The cache is refreshed on a debounce
    -- and can be several seconds behind a manual drag, and every move.itemID in a
    -- plan built from stale data addresses the wrong slot. One 98-slot pass on an
    -- explicit click, the same single-scan-then-compute-offline shape SortEngine
    -- uses.
    GuildBankScanner:ScanTab(tab)

    local items = BuildSnapshot(tab)
    if not items then
        trace("GuildBankSort: no cached data for tab", tab)
        return false
    end

    local moves = PlanMoves(items)
    if #moves == 0 then
        trace("GuildBankSort: already sorted")
        return false
    end

    -- Cleared here rather than only where they are set: if a move ever errors
    -- mid-step the flags would otherwise stay set and silently refuse every later
    -- sort for the rest of the session.
    stepping = false
    dropping = false

    state = {
        tab = tab,
        moves = moves,
        index = 1,
        completed = 0,
        planned = #moves,
        replans = 0,
        lockEvents = 0,
        lastRedraw = 0,
        startedAt = GetTime(),
        timer = nil,
    }

    if GuildBankScanner.SetSortInProgress then
        GuildBankScanner:SetSortInProgress(true)
    end

    local GuildBankHeader = ns:GetModule("GuildBankFrame.GuildBankHeader")
    if GuildBankHeader and GuildBankHeader.SetSortEnabled then
        GuildBankHeader:SetSortEnabled(false)
    end

    trace("GuildBankSort: starting", #moves, "moves on tab", tab)
    StepMove()
    return true
end

-- Combat can start mid-sort (a stray add while standing at the bank). Item moves
-- are not protected calls, but finishing a multi-second sequence during combat is
-- not something to do quietly -- stop and leave the bank in a consistent state.
Events:Register("PLAYER_REGEN_DISABLED", function()
    if state then Finish("combat started") end
end, GuildBankSort)

return GuildBankSort
