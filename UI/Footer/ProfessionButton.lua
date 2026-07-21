local addonName, ns = ...

-- Shared factory for standalone profession-action footer buttons
-- (Disenchant, Pick Lock, Prospecting, etc).
--
-- FULLY DECOUPLED from Footer.lua and BagFrame.lua to avoid taint:
-- - Never calls, registers with, or hooks those modules
-- - Only read-only global lookups for GudaBagsBagFrame / GudaBagsFooter
-- - Buttons parented to UIParent, never to the bag frame
-- - Secure attrs set once at PLAYER_LOGIN, never touched again
-- - Throttled OnUpdate polls bag frame visibility at 10Hz
-- - Show/Hide deferred during combat via PLAYER_REGEN_ENABLED

local ProfessionButton = {}
ns:RegisterModule("Footer.ProfessionButton", ProfessionButton)

local Constants = ns.Constants
local L = ns.L

local Database  -- lazy-initialized on first OnUpdate

local POLL_INTERVAL = 0.1

-- Ordered list of created instances. Insertion order = TOC load order of
-- call sites = left-to-right visual chain order.
local registry = {}

local function BuildButton(instance)
    local cfg = instance.config
    local Theme = ns:GetModule("Theme")

    local button = CreateFrame("Button", cfg.globalName, UIParent, "SecureActionButtonTemplate,BackdropTemplate")
    button:SetSize(Constants.BAG_SLOT_SIZE, Constants.BAG_SLOT_SIZE)
    button:SetFrameStrata("DIALOG")
    button:SetFrameLevel(10)
    button:EnableMouse(true)
    button:RegisterForClicks("AnyDown")

    -- Secure attrs — set ONCE, never again
    button:SetAttribute("type", "macro")
    local spellName = C_Spell.GetSpellName(cfg.spellID)
    button:SetAttribute("macrotext", "/cast " .. (spellName or cfg.defaultName))

    button:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    local fbBg = Theme:GetValue("footerButtonBg")
    local fbBorder = Theme:GetValue("footerButtonBorder")
    button:SetBackdropColor(fbBg[1], fbBg[2], fbBg[3], fbBg[4])
    button:SetBackdropBorderColor(fbBorder[1], fbBorder[2], fbBorder[3], fbBorder[4])

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(Constants.BAG_SLOT_SIZE - 2, Constants.BAG_SLOT_SIZE - 2)
    icon:SetPoint("CENTER")
    icon:SetTexture(cfg.icon)
    button.icon = icon

    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    highlight:SetBlendMode("ADD")

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(L[cfg.tooltipKey] or cfg.defaultName)
        GameTooltip:AddLine(L[cfg.tooltipDescKey] or "", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)

    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    button:Hide()
    instance.button = button
end

-- Position using absolute coords relative to UIParent.
-- NEVER anchor to bag frame elements — that would propagate protected state.
local function PositionButton(instance)
    local button = instance.button
    if not button then return end

    local footer = _G["GudaBagsFooter"]
    if not footer or not footer.slotInfoFrame then return end

    local slotInfo = footer.slotInfo or footer.slotInfoFrame
    local baseRight = slotInfo:GetRight()
    local _, centerY = footer.slotInfoFrame:GetCenter()
    if not baseRight or not centerY then return end

    -- Walk strictly-earlier registry entries; rightmost shown button wins
    for i = 1, instance.registryIndex - 1 do
        local prev = registry[i]
        if prev.button and prev.button:IsShown() then
            local r = prev.button:GetRight()
            if r and r > baseRight then baseRight = r end
        end
    end

    local halfSize = Constants.BAG_SLOT_SIZE / 2
    button:ClearAllPoints()
    button:SetPoint("CENTER", UIParent, "BOTTOMLEFT", baseRight + halfSize + 4, centerY)
end

local function ShowButton(instance)
    if InCombatLockdown() then
        if not instance.isShown then instance.pendingVisible = true end
        return
    end
    PositionButton(instance)
    if not instance.isShown then
        instance.button:Show()
        instance.isShown = true
    end
    -- Restore alpha in case we dimmed it as a fallback during combat
    instance.button:SetAlpha(1)
end

local function HideButton(instance)
    if not instance.isShown then return end
    if InCombatLockdown() then
        instance.pendingVisible = false
        -- Hide() is blocked on secure buttons in combat. SetAlpha is allowed
        -- and makes the button invisible until FlushPending hides it properly
        -- after PLAYER_REGEN_ENABLED.
        instance.button:SetAlpha(0)
        return
    end
    instance.button:Hide()
    instance.isShown = false
end

local function OnUpdate(instance, dt)
    instance.elapsed = instance.elapsed + dt
    if instance.elapsed < POLL_INTERVAL then return end
    instance.elapsed = 0

    if not instance.button then return end

    Database = Database or ns:GetModule("Database")

    local bagFrame = _G["GudaBagsBagFrame"]
    local showFooter = Database and Database:GetSetting("showFooter")
    -- Hide while the bag frame is being dragged, the player is in combat, or
    -- the user has disabled "Show Footer" in settings. Drag: buttons are
    -- parented to UIParent and don't follow the drag, so they look detached
    -- until release. Combat: the buttons can't be used (out-of-combat spells)
    -- and Hide() is blocked anyway — so we dim them via SetAlpha(0) inside
    -- HideButton and properly Hide() once combat ends. The 10Hz poll itself debounces.
    if bagFrame and bagFrame:IsShown()
        and not bagFrame._isDragging
        and not InCombatLockdown()
        and showFooter then
        ShowButton(instance)
    else
        HideButton(instance)
    end
end

local function FlushPending(instance)
    if instance.pendingVisible == true then
        instance.pendingVisible = nil
        ShowButton(instance)
    elseif instance.pendingVisible == false then
        instance.pendingVisible = nil
        HideButton(instance)
    end
end

-- Called by Header.lua the instant the bag frame starts being dragged so the
-- satellite buttons disappear immediately instead of waiting up to POLL_INTERVAL
-- for the next OnUpdate tick.
function ProfessionButton:HideAllInstantly()
    for i = 1, #registry do
        HideButton(registry[i])
    end
end

-- Public API
-- config fields:
--   spellID         (number, required)
--   globalName      (string, required)  -- frame global name
--   icon            (string, required)  -- texture path
--   tooltipKey      (string, required)  -- L key for title
--   tooltipDescKey  (string, required)  -- L key for description line
--   defaultName     (string, required)  -- fallback for /cast if spell name unavailable
--   requiredClass   (string, optional)  -- "ROGUE" etc; early-out if player class mismatch
function ProfessionButton:Create(config)
    if config.requiredClass then
        local _, class = UnitClass("player")
        if class ~= config.requiredClass then return end
    end

    local instance = {
        config = config,
        button = nil,
        isShown = false,
        pendingVisible = nil,
        elapsed = 0,
        registryIndex = nil,
        eventFrame = CreateFrame("Frame"),
    }

    instance.eventFrame:RegisterEvent("PLAYER_LOGIN")
    instance.eventFrame:SetScript("OnEvent", function(self, event)
        if event == "PLAYER_LOGIN" then
            if not IsSpellKnown(config.spellID) then
                self:UnregisterAllEvents()
                return
            end

            BuildButton(instance)
            table.insert(registry, instance)
            instance.registryIndex = #registry

            self:SetScript("OnUpdate", function(_, dt) OnUpdate(instance, dt) end)
            self:RegisterEvent("PLAYER_REGEN_ENABLED")

        elseif event == "PLAYER_REGEN_ENABLED" then
            FlushPending(instance)
        end
    end)
end
