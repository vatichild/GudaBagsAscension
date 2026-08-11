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
-- Whole-sort ceiling. 98 slots at worst-case ~0.5s each is well inside this;
-- anything slower means something is wrong and the sort should give up.
local SORT_TIMEOUT = 60

local state = nil   -- nil when idle; table while a sort runs

-------------------------------------------------
-- Ordering
-------------------------------------------------
-- Mirrors the bag sorter's ordering so a sorted Personal Bank reads the same way
-- as sorted bags, and follows the same `sortPriority` setting. The few lines are
-- duplicated from SortEngine's comparator rather than shared, because that file
-- is off limits and its comparator works on its own snapshot entries with
-- pre-inverted keys -- there is nothing here to reuse without touching it.
local function CompareItems(a, b)
    -- Empty slots always sort last so items pack toward slot 1.
    if not a.itemID then return false end
    if not b.itemID then return true end

    local priority = Database:GetSetting("sortPriority") or "default"

    if priority == "ilvl" then
        if a.itemLevel ~= b.itemLevel then return a.itemLevel > b.itemLevel end
        if a.quality ~= b.quality then return a.quality > b.quality end
        if a.classID ~= b.classID then return a.classID < b.classID end
        if a.subClassID ~= b.subClassID then return a.subClassID < b.subClassID end
    elseif priority == "quality" then
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
-- Planning (offline -- no API calls)
-------------------------------------------------

--- Snapshot of one tab, built from the scanner's cache. That cache already holds
--- classID/subClassID/quality/itemLevel/name/count for every slot, so planning
--- needs no GetItemInfo round trips.
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

--- Selection sort that records swaps instead of performing them, so the whole
--- plan exists before a single item moves. Same shape as the reference
--- implementation in Bagnon's sortBtn.lua.
local function PlanMoves(items)
    local moves = {}
    for i = 1, #items do
        local lowest = i
        for j = i + 1, #items do
            if CompareItems(items[j], items[lowest]) then
                lowest = j
            end
        end
        if lowest ~= i then
            -- Record the physical slots BEFORE swapping the entries around.
            moves[#moves + 1] = {
                srcSlot = items[lowest].slot,
                dstSlot = items[i].slot,
                itemID = items[lowest].itemID,
            }
            items[i], items[lowest] = items[lowest], items[i]
            items[i].slot, items[lowest].slot = items[lowest].slot, items[i].slot
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
    local total = #state.moves
    state = nil

    if ClearCursor then ClearCursor() end

    if GuildBankScanner and GuildBankScanner.SetSortInProgress then
        GuildBankScanner:SetSortInProgress(false)
    end

    ns:Debug("GuildBankSort finished:", reason, "moved", moved, "of", total)

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
local function MoveLanded(move)
    return LinkItemID(GetGuildBankItemLink(state.tab, move.dstSlot)) == move.itemID
end

--- Advance past a completed move.
local function Advance()
    CancelTimers()
    state.completed = state.completed + 1
    state.index = state.index + 1
    StepMove()
end

--- Called for every GUILDBANK_ITEM_LOCK_CHANGED while sorting.
---
--- One swap produces at least TWO of these -- the pickup locks the source slot,
--- the drop locks the destination -- and the first arrives before the item has
--- landed. So a mismatch here means "not yet", never "failed": we simply keep
--- waiting and let the timer below make the final call. Treating the first event
--- as a verdict would abort every single move.
local function OnMoveEvent()
    if not state then return end
    local move = state.moves[state.index]
    if not move then
        Finish("done")
        return
    end
    if MoveLanded(move) then
        Advance()
    end
end

--- The timer's verdict: by now the server has had MOVE_TIMEOUT to apply the swap,
--- so a slot that still doesn't hold the expected item means the move failed (or
--- something else moved items underneath us) and continuing would issue further
--- moves against a layout we no longer know.
local function OnMoveTimeout()
    if not state then return end
    state.timer = nil
    local move = state.moves[state.index]
    if not move then
        Finish("done")
        return
    end
    if MoveLanded(move) then
        Advance()
        return
    end

    -- Not landed yet. One timeout is not proof of failure -- a swap can still be
    -- in flight, and the reference implementation simply keeps re-checking until
    -- the destination link matches. Wait a bounded number of ticks before giving
    -- up, so a slow server costs time rather than a broken sort.
    move.waits = (move.waits or 0) + 1
    if move.waits < MOVE_ATTEMPTS then
        ns:Debug("GuildBankSort: move", state.index, "not landed yet, wait", move.waits)
        state.timer = C_Timer.NewTimer(MOVE_TIMEOUT, OnMoveTimeout)
        return
    end

    ns:Debug("GuildBankSort: move", state.index, "src", move.srcSlot, "dst", move.dstSlot,
        "expected", tostring(move.itemID),
        "got", tostring(GetGuildBankItemLink(state.tab, move.dstSlot)),
        "cursor", CursorHasItem() and "held" or "empty")
    Finish("verification failed")
end

--- Issue the next swap. Returns without advancing when it has to wait; the lock
--- event (or the timeout) calls back into VerifyAndAdvance.
StepMove = function()
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
    PickupGuildBankItem(state.tab, move.srcSlot)
    if not CursorHasItem() then
        -- Slot was locked, empty, or the server refused the pickup.
        Finish("pickup failed")
        return
    end

    PickupGuildBankItem(state.tab, move.dstSlot)

    -- The swap is in flight. GUILDBANK_ITEM_LOCK_CHANGED normally settles it
    -- within a frame or two; this timer both backstops a dropped event and is
    -- the only thing allowed to declare a move failed.
    state.timer = C_Timer.NewTimer(MOVE_TIMEOUT, OnMoveTimeout)
end

--- Called by the scanner's GUILDBANK_ITEM_LOCK_CHANGED handler while a sort runs.
function GuildBankSort:OnLockChanged()
    OnMoveEvent()
end

function GuildBankSort:IsSorting()
    return state ~= nil
end

-------------------------------------------------
-- Public entry point
-------------------------------------------------

--- Sort the Personal Bank's tab. Returns false (and says why in debug) when the
--- preconditions aren't met, so the caller can leave the button enabled.
function GuildBankSort:SortPersonalBank()
    if not GuildBankScanner then
        GuildBankScanner = ns:GetModule("GuildBankScanner")
    end
    if not GuildBankScanner then return false end

    if state then
        ns:Debug("GuildBankSort: already running")
        return false
    end
    if InCombatLockdown() then
        ns:Debug("GuildBankSort: blocked in combat")
        return false
    end
    if not GuildBankScanner:IsGuildBankOpen() then
        ns:Debug("GuildBankSort: bank is not open")
        return false
    end
    -- Personal Bank only; see the note at the top of this file.
    if GuildBankScanner:GetSessionKind() ~= "personal" then
        ns:Debug("GuildBankSort: not a personal bank session")
        return false
    end
    if CursorHasItem() then
        ns:Debug("GuildBankSort: cursor is not empty")
        return false
    end

    -- The Personal Bank is presented as tab 1 only (UI\GuildBankFrame.lua pins
    -- the selection), so that is the tab this sorts.
    local tab = 1
    local items = BuildSnapshot(tab)
    if not items then
        ns:Debug("GuildBankSort: no cached data for tab", tab)
        return false
    end

    -- A locked slot means something is already in flight; planning around it
    -- would produce moves against a layout that is about to change.
    for _, item in ipairs(items) do
        if item.locked then
            ns:Debug("GuildBankSort: slot", item.slot, "is locked")
            return false
        end
    end

    local moves = PlanMoves(items)
    if #moves == 0 then
        ns:Debug("GuildBankSort: already sorted")
        return false
    end

    state = {
        tab = tab,
        moves = moves,
        index = 1,
        completed = 0,
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

    ns:Debug("GuildBankSort: starting", #moves, "moves on tab", tab)
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
