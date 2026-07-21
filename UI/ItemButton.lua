local addonName, ns = ...

local ItemButton = {}
ns:RegisterModule("ItemButton", ItemButton)

local Constants = ns.Constants
local Database = ns:GetModule("Database")
local Font = ns:GetModule("Font")
local Tooltip = ns:GetModule("Tooltip")
local Utils = ns:GetModule("Utils")

-- Which frame type CreateFrame accepts for our item buttons. The dedicated
-- "ItemButton" type only exists from Dragonflight (10.0); everywhere else the
-- template is a plain Button. Resolved once by asking the client directly --
-- see CreateItemButton, where getting this wrong crashes ~200x during PreWarm.
local ITEM_BUTTON_FRAME_TYPE = "Button"
do
    local probeName = "GudaBagsItemButtonTypeProbe"
    if pcall(CreateFrame, "ItemButton", probeName, UIParent) then
        ITEM_BUTTON_FRAME_TYPE = "ItemButton"
        local probe = _G[probeName]
        if probe then probe:Hide() end
    end
end

-------------------------------------------------
-- Upgrade arrow (Pawn / SimpleItemLevel compatibility)
-- Drawn on our own buttons using whichever advisor addon is present. Pawn
-- takes priority; SimpleItemLevel is the fallback. Pawn's verdict is cached,
-- budgeted, and invalidated by the Compatibility.Pawn module.
-------------------------------------------------

-- Pawn shows the green arrow on bags by reusing Blizzard's built-in bag
-- UpgradeIcon ("bags-greenarrow" atlas) -- so we use that to match Pawn. On
-- clients without that atlas, fall back to Pawn's own arrow texture.
local PAWN_ARROW_ATLAS = (C_Texture and C_Texture.GetAtlasInfo
    and C_Texture.GetAtlasInfo("bags-greenarrow")) and "bags-greenarrow" or nil
local PAWN_ARROW_TEXTURE = "Interface\\AddOns\\Pawn\\Textures\\UpgradeArrow"

local PawnCompat  -- resolved lazily to avoid load-order coupling

-- Which addon says this item is an upgrade? Returns "pawn", "sil", or nil.
-- Pawn takes priority. classID 2 = Weapon, 4 = Armor (itemType is localized).
local function GetUpgradeArrowSource(itemData, isReadOnly)
    if ns.suspectDisabled and ns.suspectDisabled.upgrade then return nil end
    if isReadOnly or not itemData or not itemData.link then return nil end
    if not (itemData.classID == 2 or itemData.classID == 4) then return nil end

    PawnCompat = PawnCompat or ns:GetModule("Compatibility.Pawn")
    if PawnCompat and PawnCompat:IsAvailable() then
        -- nil ("not sure yet") is handled inside the module, which refreshes
        -- the arrows once it resolves -- so treat anything but true as no arrow.
        return PawnCompat:GetUpgradeStatus(itemData.link) == true and "pawn" or nil
    end

    local sil = _G.SimpleItemLevel
    if sil and sil.API and sil.API.ItemIsUpgrade then
        return sil.API.ItemIsUpgrade(itemData.link) == true and "sil" or nil
    end
    return nil
end

-- Apply or clear the upgrade arrow on a button based on its current item.
-- Reads button.itemData / button.isReadOnly (both set in SetItem), so it can
-- also be called standalone by RefreshUpgradeArrows.
local function ApplyUpgradeArrow(button)
    if not button.upgradeArrow then return end
    local source = GetUpgradeArrowSource(button.itemData, button.isReadOnly)
    if source == "pawn" then
        if PAWN_ARROW_ATLAS then
            button.upgradeArrow:SetAtlas(PAWN_ARROW_ATLAS)
        else
            button.upgradeArrow:SetTexture(PAWN_ARROW_TEXTURE)
        end
        button.upgradeArrow:Show()
    elseif source == "sil" then
        button.upgradeArrow:SetAtlas("poi-door-arrow-up")
        button.upgradeArrow:Show()
    else
        button.upgradeArrow:Hide()
    end
end

-- No-op: UIErrorsFrame hooking was removed to prevent taint propagation
-- that would break Blizzard's secure unit frame code (maxHealth comparisons, etc.)
local function SuppressItemErrors()
end

-- Check if an item is protected from selling/deleting (user-locked or in equipment set)
local function IsItemProtected(itemID)
    if not itemID then return false end
    if Database:IsItemLocked(itemID) then return true end
    if Database:GetSetting("autoLockSetItems") then
        local EquipSets = ns:GetModule("EquipmentSets")
        if EquipSets and EquipSets:IsInSet(itemID)
           and not Database:IsSetProtectionException(itemID) then
            return true
        end
    end
    return false
end

-- Protect locked items from disenchant/milling/prospecting without tainting secure click chain
-- Uses overlay frames on protected buttons that eat clicks while spell targeting is active
local spellTargetingActive = false
local spellOverlayButtons = {}

local function CreateSpellOverlay(button)
    if button.spellOverlay then return button.spellOverlay end
    local overlay = CreateFrame("Button", nil, button)
    overlay:SetAllPoints()
    overlay:SetFrameLevel(button:GetFrameLevel() + 21)
    overlay:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    overlay:SetScript("OnClick", function(self)
        local parent = self:GetParent()
        if parent.itemData and parent.itemData.itemID then
            local L = ns.L
            ns:Print(string.format(L["ITEM_LOCKED_CANNOT_DISENCHANT"], parent.itemData.link or parent.itemData.name or ""))
        end
    end)
    overlay:SetScript("OnEnter", function(self)
        local parent = self:GetParent()
        if parent:GetScript("OnEnter") then parent:GetScript("OnEnter")(parent) end
    end)
    overlay:SetScript("OnLeave", function(self)
        local parent = self:GetParent()
        if parent:GetScript("OnLeave") then parent:GetScript("OnLeave")(parent) end
    end)
    overlay:Hide()
    button.spellOverlay = overlay
    return overlay
end

local function UpdateSpellOverlay(button)
    if spellTargetingActive and button.itemData and button.itemData.itemID and IsItemProtected(button.itemData.itemID) then
        local overlay = CreateSpellOverlay(button)
        overlay:SetFrameLevel(button:GetFrameLevel() + 21)
        overlay:Show()
        spellOverlayButtons[button] = true
    else
        if button.spellOverlay then
            button.spellOverlay:Hide()
        end
        spellOverlayButtons[button] = nil
    end
end

do
    local spellGuardFrame = CreateFrame("Frame")
    spellGuardFrame:Hide()
    spellGuardFrame:SetScript("OnUpdate", function(self)
        if not SpellIsTargeting() then
            -- Spell targeting ended, hide all overlays
            spellTargetingActive = false
            for button in pairs(spellOverlayButtons) do
                if button.spellOverlay then button.spellOverlay:Hide() end
            end
            wipe(spellOverlayButtons)
            self:Hide()
            return
        end
    end)

    local spellEventFrame = CreateFrame("Frame")
    spellEventFrame:RegisterEvent("CURRENT_SPELL_CAST_CHANGED")
    spellEventFrame:SetScript("OnEvent", function()
        if SpellIsTargeting() then
            spellTargetingActive = true
            -- Show overlays on all protected buttons
            local BagFrame = ns:GetModule("BagFrame")
            if BagFrame and BagFrame.RefreshLockIcons then BagFrame:RefreshLockIcons() end
            local BankFrame = ns:GetModule("BankFrame")
            if BankFrame and BankFrame.RefreshLockIcons then BankFrame:RefreshLockIcons() end
            spellGuardFrame:Show()
        end
    end)
end

-- Protect locked items from being sold at merchant
-- Uses overlay frames on protected buttons that intercept right-clicks while merchant is open
local merchantProtectionActive = false
local merchantOverlayButtons = {}

local function CreateMerchantOverlay(button)
    if button.merchantOverlay then return button.merchantOverlay end
    local overlay = CreateFrame("Button", nil, button)
    overlay:SetAllPoints()
    overlay:SetFrameLevel(button:GetFrameLevel() + 20)
    overlay:RegisterForClicks("RightButtonUp")
    overlay:SetScript("OnClick", function(self)
        local parent = self:GetParent()
        if parent.itemData and parent.itemData.itemID then
            local L = ns.L
            ns:Print(string.format(L["ITEM_LOCKED_CANNOT_SELL"], parent.itemData.link or parent.itemData.name or ""))
        end
    end)
    -- Forward non-right-click mouse events (tooltip, drag, etc.)
    overlay:SetScript("OnEnter", function(self)
        local parent = self:GetParent()
        if parent:GetScript("OnEnter") then parent:GetScript("OnEnter")(parent) end
    end)
    overlay:SetScript("OnLeave", function(self)
        local parent = self:GetParent()
        if parent:GetScript("OnLeave") then parent:GetScript("OnLeave")(parent) end
    end)
    overlay:Hide()
    button.merchantOverlay = overlay
    return overlay
end

local function UpdateMerchantOverlay(button)
    if merchantProtectionActive and button.itemData and button.itemData.itemID and IsItemProtected(button.itemData.itemID) then
        local overlay = CreateMerchantOverlay(button)
        overlay:SetFrameLevel(button:GetFrameLevel() + 20)
        overlay:Show()
        merchantOverlayButtons[button] = true
    else
        if button.merchantOverlay then
            button.merchantOverlay:Hide()
        end
        merchantOverlayButtons[button] = nil
    end
end

do
    local merchantFrame = CreateFrame("Frame")
    merchantFrame:RegisterEvent("MERCHANT_SHOW")
    merchantFrame:RegisterEvent("MERCHANT_CLOSED")
    merchantFrame:SetScript("OnEvent", function(self, event)
        merchantProtectionActive = (event == "MERCHANT_SHOW")
        if not merchantProtectionActive then
            -- Hide all overlays
            for button in pairs(merchantOverlayButtons) do
                if button.merchantOverlay then button.merchantOverlay:Hide() end
            end
            wipe(merchantOverlayButtons)
        end
        -- Overlays will be shown/hidden via UpdateUserLockIcon or next button update
        -- Force refresh lock icons on all visible buttons
        local BagFrame = ns:GetModule("BagFrame")
        if BagFrame and BagFrame.RefreshLockIcons then BagFrame:RefreshLockIcons() end
        local BankFrame = ns:GetModule("BankFrame")
        if BankFrame and BankFrame.RefreshLockIcons then BankFrame:RefreshLockIcons() end
    end)
end

-- Hook delete confirmation popups to prevent deleting protected items
local function HookDeletePopup(dialogName)
    if not StaticPopupDialogs or not StaticPopupDialogs[dialogName] then return end
    local originalOnShow = StaticPopupDialogs[dialogName].OnShow
    StaticPopupDialogs[dialogName].OnShow = function(self, ...)
        local cursorType, itemID = GetCursorInfo()
        if cursorType == "item" and itemID and IsItemProtected(itemID) then
            local L = ns.L
            ns:Print(string.format(L["ITEM_LOCKED_CANNOT_DELETE"], select(2, GetItemInfo(itemID)) or ""))
            ClearCursor()
            self:Hide()
            return
        end
        if originalOnShow then
            return originalOnShow(self, ...)
        end
    end
end
HookDeletePopup("DELETE_ITEM")
HookDeletePopup("DELETE_GOOD_ITEM")

-- Retail slot textures used when retailEmptySlots setting is enabled
local RETAIL_SLOT_TEXTURES = {
    background = "Interface\\AddOns\\GudaBags\\Assets\\Themes\\retail\\HDActionBarBtn",
    border = "Interface\\AddOns\\GudaBags\\Assets\\Themes\\retail\\btn_border",
    highlight = "Interface\\AddOns\\GudaBags\\Assets\\Themes\\retail\\btn_highlight_strong",
}

-- Resolve effective slot textures: on Retail WoW use theme directly,
-- on Classic expansions the retailEmptySlots setting controls it
local function GetEffectiveSlotTextures()
    if ns.IsRetail then
        local Theme = ns:GetModule("Theme")
        return Theme:Get().slotTextures
    end
    return Database:GetSetting("retailEmptySlots") and RETAIL_SLOT_TEXTURES or nil
end

-- Apply retail/default slot textures to a single button
local function ApplyThemeToButton(button, slotTex)
    local minimalMode = Database:GetSetting("minimalEmptySlots")

    if minimalMode then
        -- Minimal mode: thin border outline, no slot icon
        button.slotBackground:Hide()
        if button.retailSlotBg then button.retailSlotBg:Hide() end
        if button.minimalSlot then button.minimalSlot:Show() end
        button.highlight:Show()
        if button.retailHighlight then button.retailHighlight:Hide() end
    elseif slotTex then
        -- Retail-style slot textures
        button.slotBackground:Hide()
        if button.minimalSlot then button.minimalSlot:Hide() end
        button.retailSlotBg:SetTexture(slotTex.background)
        button.retailSlotBg:Show()
        button.highlight:Hide()
        button.retailHighlight:SetTexture(slotTex.highlight)
        button.retailHighlight:Show()
    else
        -- Default classic slot icon
        button.slotBackground:Show()
        if button.retailSlotBg then button.retailSlotBg:Hide() end
        if button.minimalSlot then button.minimalSlot:Hide() end
        button.highlight:Show()
        if button.retailHighlight then button.retailHighlight:Hide() end
    end
end

-- Scale slot background extension based on icon size (default 37px → 9px extension)
local function UpdateSlotBackgroundSize(button, size)
    local slotExtend = math.max(1, math.floor(size * 9 / 37))
    button.slotBackground:ClearAllPoints()
    button.slotBackground:SetPoint("TOPLEFT", button, "TOPLEFT", -slotExtend, slotExtend)
    button.slotBackground:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", slotExtend, -slotExtend)
end

-- Phase 1: Use Blizzard's optimized CreateObjectPool API
local buttonPool = nil  -- Lazy initialized
local buttonIndex = 0

-- Full reset function for pool (called on Release)
local function ResetButton(pool, button)
    -- Remove from Masque before reset
    local MasqueModule = ns:GetModule("Masque")
    local masqueActive = MasqueModule and MasqueModule:IsActive()
    if masqueActive then MasqueModule:RemoveButton(button) end

    button._pooledActive = false  -- O(1) active flag (see ItemButton:Release)
    button:SetShown(false)  -- Use SetShown to avoid taint during combat
    button.wrapper:SetShown(false)
    button.wrapper:ClearAllPoints()
    button.itemData = nil
    button.owner = nil
    button.isEmptySlotButton = nil
    button.isDropTargetButton = nil
    button._masqueApplied = nil
    button.categoryId = nil
    button.iconSize = nil
    button.layoutX = nil
    button.layoutY = nil
    button.layoutIndex = nil
    button.containerFrame = nil

    -- Hide Blizzard template's built-in textures
    if button.IconBorder then button.IconBorder:Hide() end
    if button.IconOverlay then button.IconOverlay:Hide() end
    if button.NewItemTexture then button.NewItemTexture:Hide() end
    if button.BattlepayItemTexture then button.BattlepayItemTexture:Hide() end
    -- Don't hide NormalTexture when Masque is active — Masque manages it
    if not masqueActive then
        local normalTex = button:GetNormalTexture()
        if normalTex then normalTex:Hide() end
    end

    -- Clear visual state to prevent texture bleeding
    SetItemButtonTexture(button, nil)
    SetItemButtonCount(button, 0)
    SetItemButtonDesaturated(button, false)
    if button.border then button.border:Hide() end
    if button.innerShadow then
        for _, tex in pairs(button.innerShadow) do tex:Hide() end
    end
    if button.lockOverlay then button.lockOverlay:Hide() end
    if button.unusableOverlay then button.unusableOverlay:Hide() end
    if button.junkOverlay then button.junkOverlay:Hide() end
    if button.junkIcon then button.junkIcon:Hide() end
    if button.trackedIcon then button.trackedIcon:Hide() end
    if button.trackedIconShadow then button.trackedIconShadow:Hide() end
    if button.equipSetIcon then button.equipSetIcon:Hide() end
    if button.equipSetIconShadow then button.equipSetIconShadow:Hide() end
    if button.itemLevelText then button.itemLevelText:Hide() end
    if button.chargesText then button.chargesText:Hide() end
    if button.boeText then button.boeText:Hide() end
    if button.upgradeArrow then button.upgradeArrow:Hide() end
    if button.questIcon then button.questIcon:Hide() end
    if button.questStarterIcon then button.questStarterIcon:Hide() end
    if button.craftingQualityIcon then button.craftingQualityIcon:Hide() end
    if button.pinIcon then button.pinIcon:Hide() end
    if button.pinIconShadow then button.pinIconShadow:Hide() end
    if button.searchGlow then button.searchGlow:Hide() end
    if button.dropTargetGlow then
        button.dropTargetGlow.animGroup:Stop()
        button.dropTargetGlow:Hide()
    end
    if button.minimalSlot then button.minimalSlot:Hide() end
    if button.cooldown then CooldownFrame_Set(button.cooldown, 0, 0, false) end
end

local function ApplyFontSize(button, fontSize)
    fontSize = fontSize or Database:GetSetting("iconFontSize")
    if button.Count then
        Font:Apply(button.Count, fontSize, "OUTLINE")
        button.Count:ClearAllPoints()
        button.Count:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, 1)
        button.Count:SetJustifyH("RIGHT")
    end
    if button.itemLevelText then
        Font:Apply(button.itemLevelText, fontSize, "OUTLINE")
    end
    if button.chargesText then
        Font:Apply(button.chargesText, fontSize, "OUTLINE")
    end
end

local function IsTool(itemName)
    if not itemName then return false end
    local nameLower = string.lower(itemName)

    if string.find(nameLower, "mining pick") then return true end
    if string.find(nameLower, "fishing pole") then return true end
    if string.find(nameLower, "fishing rod") then return true end
    if string.find(nameLower, "skinning knife") then return true end
    if string.find(nameLower, "blacksmith hammer") then return true end
    if string.find(nameLower, "jumper cables") then return true end
    if string.find(nameLower, "gnomish") then return true end
    if string.find(nameLower, "goblin") then return true end
    if string.find(nameLower, "arclight spanner") then return true end
    if string.find(nameLower, "gyromatic") then return true end

    return false
end

local function IsJunkItem(itemData)
    if not itemData then return false end

    -- Don't classify items with incomplete data as junk
    -- (GetItemInfo hasn't cached yet — name defaults to "")
    if not itemData.name or itemData.name == "" then return false end

    -- User-marked junk overrides quality and profession-tool protection.
    if itemData.itemID then
        local Database = ns:GetModule("Database")
        if Database and Database:IsItemMarkedJunk(itemData.itemID) then
            return true
        end
    end

    -- Profession tools are never junk
    if IsTool(itemData.name) then
        return false
    end

    -- Gray quality items are always junk (consistent with Category View isJunk rule)
    if itemData.quality == 0 then
        return true
    end

    -- White quality equipment (only if setting is enabled)
    if itemData.quality == 1 then
        local Database = ns:GetModule("Database")
        local whiteItemsJunk = Database and Database:GetSetting("whiteItemsJunk") or false

        if not whiteItemsJunk then
            return false  -- Setting is off, white items are never junk
        end

        local isEquipment = itemData.itemType == "Armor" or itemData.itemType == "Weapon"
        if isEquipment then
            -- Valuable slots (trinket, ring, neck, shirt, tabard) are never junk
            local equipSlot = itemData.equipSlot
            if equipSlot and Constants.VALUABLE_EQUIP_SLOTS[equipSlot] then
                return false
            end

            -- Check for special properties (unique, use, equip effects, green/yellow text)
            -- Use cached value from ItemScanner to avoid tooltip rescans
            if itemData.hasSpecialProperties then
                return false
            end
            return true
        end
    end

    return false
end

local function CreateButton(parent)
    -- Count newly-created secure buttons. A high count during a bank open means the
    -- pool was too small (PreWarm) and the freeze is secure-frame creation, not render.
    ns:ProfileBump("CreateButton.count")
    buttonIndex = buttonIndex + 1
    local name = "GudaBagsItemButton" .. buttonIndex

    -- Wrapper frame holds bag ID for the template's click handler
    local wrapper = CreateFrame("Frame", name .. "Wrapper", parent)
    wrapper:SetSize(37, 37)
    wrapper:EnableMouse(false)  -- Wrapper should not intercept mouse

    -- ContainerFrameItemButtonTemplate provides secure item click handling.
    -- NOTE: the "ItemButton" frame TYPE is Dragonflight 10.0 only; on 3.3.5a it
    -- is not a valid type and CreateFrame throws -- and this runs ~200x during
    -- PreWarm, so getting it wrong takes the whole UI down. Probe the client for
    -- the answer once rather than trusting expansion detection: a client that
    -- reports an unexpected WOW_PROJECT_ID must not resurrect the crash.
    local button = CreateFrame(ITEM_BUTTON_FRAME_TYPE, name, wrapper, "ContainerFrameItemButtonTemplate")
    button:SetSize(37, 37)
    button:SetAllPoints(wrapper)
    button.wrapper = wrapper
    button.currentSize = nil  -- Track current size to avoid redundant SetSize calls

    -- Pre-10.0 ItemButtonTemplate exposes its children only as $parent-named
    -- GLOBALS -- the button.icon / button.Count / button.NormalTexture members
    -- that modern code reads simply don't exist. Alias whichever are missing so
    -- every later access in this file works unchanged on both flavours.
    button.icon             = button.icon or button.Icon or _G[name .. "IconTexture"]
    button.Count            = button.Count or _G[name .. "Count"]
    button.NormalTexture    = button.NormalTexture or _G[name .. "NormalTexture"]
    button.IconQuestTexture = button.IconQuestTexture or _G[name .. "IconQuestTexture"]
    button.Cooldown         = button.Cooldown or _G[name .. "Cooldown"]
    button.Stock            = button.Stock or _G[name .. "Stock"]
    button.searchOverlay    = button.searchOverlay or _G[name .. "SearchOverlay"]

    -- Store reference to easily resize wrapper with button
    wrapper.button = button

    -- Initialize IDs to prevent errors from template handlers before SetItem is called
    wrapper:SetID(0)
    button:SetID(0)

    -- Disable mouse on all child frames from the template (retail has many overlays)
    -- This prevents them from intercepting mouse input meant for the button
    local function DisableChildMouse(frame)
        for _, child in pairs({frame:GetChildren()}) do
            if child.EnableMouse then
                child:EnableMouse(false)
            end
            if child.SetHitRectInsets then
                child:SetHitRectInsets(1000, 1000, 1000, 1000)
            end
            child:Hide()
            -- Recursively disable grandchildren
            if child.GetChildren then
                DisableChildMouse(child)
            end
        end
    end
    DisableChildMouse(button)

    -- Also check for and disable NineSlice (retail frame decoration)
    if button.NineSlice then
        button.NineSlice:Hide()
        if button.NineSlice.EnableMouse then button.NineSlice:EnableMouse(false) end
    end

    -- Disable button's built-in click handlers that might interfere
    -- We'll set up our own handlers
    button:EnableMouse(true)
    -- Only register for mouse up to prevent double-firing
    -- The template fires on both MouseDown and MouseUp with AnyDown, causing items to be used twice
    button:RegisterForClicks("AnyUp")
    -- Enable drag for all items including guild bank
    button:RegisterForDrag("LeftButton")

    -- Handle drag start for guild bank items (hook to preserve template behavior for regular items)
    button:HookScript("OnDragStart", function(self)
        if self.itemData and self.itemData.isGuildBank and not self.isReadOnly then
            local tabIndex = self.itemData.bagID
            local slotIndex = self.itemData.slot
            if self.itemData.itemID then  -- Only drag if there's an item
                PickupGuildBankItem(tabIndex, slotIndex)
            end
        end
    end)

    -- Hide template's built-in visual elements (we use our own)
    -- Always hide NormalTexture to prevent template's quest handlers from showing borders
    -- Hide template's NormalTexture — we use our own visuals
    local MasqueModule = ns:GetModule("Masque")
    local masqueActive = MasqueModule and MasqueModule:IsActive()
    local normalTex = button:GetNormalTexture()
    if normalTex then
        if masqueActive then
            -- Keep texture object alive for Masque but hide initially — Masque will manage it
            normalTex:Hide()
        else
            normalTex:SetTexture(nil)
            normalTex:Hide()
        end
    end

    -- Prevent template handlers (UpdateQuestItem etc.) from re-setting NormalTexture
    -- This stops quest indicator borders from appearing on all slots
    if masqueActive then
        button.SetNormalTexture = function() end
    end

    if button.IconBorder then button.IconBorder:Hide() end
    if button.IconOverlay then button.IconOverlay:Hide() end
    if button.NormalTexture then
        if not masqueActive then
            button.NormalTexture:SetTexture(nil)
        end
        button.NormalTexture:Hide()
    end
    if button.NewItemTexture then button.NewItemTexture:Hide() end
    if button.BattlepayItemTexture then button.BattlepayItemTexture:Hide() end

    -- Hide retail-specific template elements (Midnight/TWW)
    -- These overlays block mouse input - reparent them to remove completely
    local function DisableOverlay(overlay)
        if not overlay then return end
        overlay:Hide()
        overlay:SetAlpha(0)
        overlay:ClearAllPoints()
        -- Reparent to remove from button hierarchy entirely.
        -- Only frames may be orphaned: pre-Legion clients reject a nil parent
        -- for textures and font strings outright ("cannot set a 'nil' parent
        -- for fonts or textures"). Hiding + clearing points above is already
        -- enough to take those out of play.
        local objectType = overlay.GetObjectType and overlay:GetObjectType() or nil
        local isRegion = objectType == "Texture" or objectType == "FontString"
        if overlay.SetParent and not isRegion then
            overlay:SetParent(nil)
        end
        if overlay.EnableMouse then overlay:EnableMouse(false) end
        if overlay.SetHitRectInsets then overlay:SetHitRectInsets(1000, 1000, 1000, 1000) end
        if overlay.SetScript then
            overlay:SetScript("OnShow", function(self) self:Hide() end)
            overlay:SetScript("OnEnter", nil)
            overlay:SetScript("OnLeave", nil)
            overlay:SetScript("OnMouseDown", nil)
            overlay:SetScript("OnMouseUp", nil)
        end
    end

    DisableOverlay(button.ItemContextOverlay)
    DisableOverlay(button.SearchOverlay)
    DisableOverlay(button.ExtendedSlot)
    DisableOverlay(button.UpgradeIcon)
    DisableOverlay(button.ItemSlotBackground)
    DisableOverlay(button.JunkIcon)
    DisableOverlay(button.flash)
    DisableOverlay(button.NewItem)
    DisableOverlay(button.Cooldown)  -- Template's cooldown (we create our own)
    DisableOverlay(button.WidgetContainer)  -- Retail widget container
    DisableOverlay(button.LevelLinkLockIcon)
    DisableOverlay(button.BagIndicator)
    DisableOverlay(button.StackSplitFrame)

    -- Disable template's quest item texture (we use our own quest icons)
    -- The template's UpdateQuestItem() shows this with quest borders/bangs on quest items
    local questTex = button.IconQuestTexture or _G[name .. "IconQuestTexture"]
    DisableOverlay(questTex)

    -- No-op the template's quest update method to prevent it from managing quest visuals
    if button.UpdateQuestItem then
        button.UpdateQuestItem = function() end
    end

    -- Disable any mouse blocking on the icon texture layer
    if button.icon then button.icon:SetDrawLayer("ARTWORK", 0) end

    -- Ensure the button is the topmost interactive element
    button:SetFrameLevel(button:GetParent():GetFrameLevel() + Constants.FRAME_LEVELS.BUTTON)

    -- Sync child frame levels to match the (potentially new) button level
    local btnLvl = button:GetFrameLevel()
    if button.border then button.border:SetFrameLevel(btnLvl + Constants.FRAME_LEVELS.BORDER) end
    if button.cooldown then button.cooldown:SetFrameLevel(btnLvl + Constants.FRAME_LEVELS.COOLDOWN) end
    if button.questStarterIcon then button.questStarterIcon:SetFrameLevel(btnLvl + Constants.FRAME_LEVELS.QUEST_ICON) end
    if button.questIcon then button.questIcon:SetFrameLevel(btnLvl + Constants.FRAME_LEVELS.QUEST_ICON) end
    if button.userLockFrame then button.userLockFrame:SetFrameLevel(btnLvl + Constants.FRAME_LEVELS.BORDER + 2) end
    if button.craftingQualityFrame then button.craftingQualityFrame:SetFrameLevel(btnLvl + Constants.FRAME_LEVELS.BORDER + 1) end

    -- Reset hit rect to cover the full button (template might shrink it)
    button:SetHitRectInsets(0, 0, 0, 0)

    -- Ensure button receives all mouse events (check if methods exist)
    if button.SetMouseClickEnabled then button:SetMouseClickEnabled(true) end
    if button.SetMouseMotionEnabled then button:SetMouseMotionEnabled(true) end

    -- Hide global texture created by template XML
    local globalNormal = _G[name .. "NormalTexture"]
    if globalNormal then
        globalNormal:SetTexture(nil)
        globalNormal:Hide()
    end

    -- Custom slot background (extended to match item icon visual size)
    local slotBackground = button:CreateTexture(nil, "BACKGROUND", nil, -1)
    slotBackground:SetPoint("TOPLEFT", button, "TOPLEFT", -9, 9)
    slotBackground:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 9, -9)
    slotBackground:SetTexture("Interface\\Buttons\\UI-EmptySlot")
    button.slotBackground = slotBackground

    -- Retail theme slot background (hidden by default)
    local retailSlotBg = button:CreateTexture(nil, "BACKGROUND", nil, -1)
    retailSlotBg:SetPoint("TOPLEFT", button, "TOPLEFT", -2, 2)
    retailSlotBg:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 2, -2)
    retailSlotBg:Hide()
    button.retailSlotBg = retailSlotBg

    -- Minimal slot (slightly lighter than bag background — hidden by default)
    local minimalSlot = button:CreateTexture(nil, "BACKGROUND", nil, -1)
    minimalSlot:SetAllPoints(button)
    minimalSlot:SetTexture("Interface\\Buttons\\WHITE8x8")
    minimalSlot:SetVertexColor(0.05, 0.05, 0.05, 0.5)
    minimalSlot:Hide()
    button.minimalSlot = minimalSlot

    -- Item icon fills button completely to match empty slot size
    local icon = button.icon or button.Icon or _G[name .. "IconTexture"]
    if icon then
        icon:ClearAllPoints()
        icon:SetAllPoints(button)
        icon:SetTexCoord(0, 1, 0, 1)
    end

    -- Quality border (our custom one, not template's)
    local border = Utils:CreateItemBorder(button)
    button.border = border

    -- Inner shadow/glow for quality colors (inset effect)
    button.innerShadow = Utils:CreateInnerShadow(button, 4)

    -- Custom highlight
    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    highlight:SetBlendMode("ADD")
    button.highlight = highlight

    -- Retail theme highlight (hidden by default)
    local retailHighlight = button:CreateTexture(nil, "HIGHLIGHT")
    retailHighlight:SetPoint("TOPLEFT", button, "TOPLEFT", -4, 4)
    retailHighlight:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 4, -4)
    retailHighlight:SetBlendMode("ADD")
    retailHighlight:Hide()
    button.retailHighlight = retailHighlight

    -- Cooldown frame
    local cooldown = CreateFrame("Cooldown", name .. "Cooldown", button, "CooldownFrameTemplate")
    cooldown:SetAllPoints()
    cooldown:SetDrawEdge(false)
    cooldown:SetFrameLevel(button:GetFrameLevel() + Constants.FRAME_LEVELS.COOLDOWN)
    if cooldown.SetHideCountdownNumbers then
        cooldown:SetHideCountdownNumbers(false)
    end
    button.cooldown = cooldown

    -- Lock overlay for locked items
    local lockOverlay = button:CreateTexture(nil, "OVERLAY", nil, 1)
    lockOverlay:SetAllPoints()
    lockOverlay:SetTexture("Interface\\Buttons\\WHITE8x8")
    lockOverlay:SetVertexColor(0, 0, 0, 0.5)
    lockOverlay:Hide()
    button.lockOverlay = lockOverlay

    -- Unusable item overlay
    local unusableOverlay = button:CreateTexture(nil, "OVERLAY", nil, 2)
    unusableOverlay:SetAllPoints()
    unusableOverlay:SetTexture("Interface\\Buttons\\WHITE8x8")
    unusableOverlay:SetVertexColor(1, 0.1, 0.1, 0.4)
    unusableOverlay:Hide()
    button.unusableOverlay = unusableOverlay

    -- Junk item overlay (gray)
    local junkOverlay = button:CreateTexture(nil, "OVERLAY", nil, 2)
    junkOverlay:SetAllPoints()
    junkOverlay:SetTexture("Interface\\Buttons\\WHITE8x8")
    junkOverlay:SetVertexColor(0.3, 0.3, 0.3, 0.6)
    junkOverlay:Hide()
    button.junkOverlay = junkOverlay

    -- Junk coin icon
    local junkIcon = button:CreateTexture(nil, "OVERLAY", nil, 3)
    junkIcon:SetSize(12, 12)
    junkIcon:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
    junkIcon:SetTexture("Interface\\MoneyFrame\\UI-GoldIcon")
    junkIcon:Hide()
    button.junkIcon = junkIcon

    -- Crafting quality icon (top-left corner, Retail only).
    -- Wrapped in its own frame at frame-level BORDER+1 so the quality icon
    -- draws ABOVE the quality border (button.border is a frame at BORDER —
    -- a texture on the button itself would always be hidden behind it).
    local craftingQualityFrame = CreateFrame("Frame", nil, button)
    craftingQualityFrame:SetAllPoints(button)
    craftingQualityFrame:SetFrameLevel(button:GetFrameLevel() + Constants.FRAME_LEVELS.BORDER + 1)
    local craftingQualityIcon = craftingQualityFrame:CreateTexture(nil, "OVERLAY", nil, 3)
    craftingQualityIcon:SetSize(34, 34)
    craftingQualityIcon:SetPoint("TOPLEFT", button, "TOPLEFT", -5, 5)
    craftingQualityIcon:Hide()
    button.craftingQualityFrame = craftingQualityFrame
    button.craftingQualityIcon = craftingQualityIcon

    -- Tracked/favorite icon shadow (for darker stroke effect, drawn behind the icon)
    local trackedIconShadow = button:CreateTexture(nil, "OVERLAY", nil, 2)
    trackedIconShadow:SetSize(14, 14)
    trackedIconShadow:SetPoint("CENTER", button, "CENTER", 0, 0)
    trackedIconShadow:SetTexture("Interface\\AddOns\\GudaBags\\Assets\\fav.tga")
    trackedIconShadow:SetVertexColor(0, 0, 0, 1)
    trackedIconShadow:Hide()
    button.trackedIconShadow = trackedIconShadow

    -- Tracked/favorite icon (center of slot, freed from top-right so the
    -- item-level text can take that corner — leaves TOPLEFT free for SimpleItemLevel).
    local trackedIcon = button:CreateTexture(nil, "OVERLAY", nil, 3)
    trackedIcon:SetSize(12, 12)
    trackedIcon:SetPoint("CENTER", button, "CENTER", 0, 0)
    trackedIcon:SetTexture("Interface\\AddOns\\GudaBags\\Assets\\fav.tga")
    trackedIcon:Hide()
    button.trackedIcon = trackedIcon

    -- Upgrade arrow (top-left). Rendered by us using whichever advisor addon is
    -- present -- Pawn first, then SimpleItemLevel (see GetUpgradeArrowSource).
    -- The texture is swapped per source in SetItem (Pawn's green arrow vs the
    -- gold poi-door-arrow-up atlas); the atlas below is just the default.
    -- Anchored at TOPLEFT (freed by moving our iLvl to TOPRIGHT).
    -- Stays hidden when neither addon is installed (gate in SetItem).
    local upgradeArrow = button:CreateTexture(nil, "OVERLAY", nil, 4)
    upgradeArrow:SetSize(12, 12)
    upgradeArrow:SetPoint("TOPLEFT", button, "TOPLEFT", 2, -2)
    upgradeArrow:SetAtlas("poi-door-arrow-up")
    upgradeArrow:Hide()
    button.upgradeArrow = upgradeArrow

    -- Equipment set icon shadow (bottom-left corner)
    local equipSetIconShadow = button:CreateTexture(nil, "OVERLAY", nil, 2)
    equipSetIconShadow:SetSize(15, 15)
    equipSetIconShadow:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0)
    equipSetIconShadow:SetTexture("Interface\\AddOns\\GudaBags\\Assets\\equipment.tga")
    equipSetIconShadow:SetVertexColor(0, 0, 0, 1)
    equipSetIconShadow:Hide()
    button.equipSetIconShadow = equipSetIconShadow

    -- Equipment set icon (bottom-left corner)
    local equipSetIcon = button:CreateTexture(nil, "OVERLAY", nil, 3)
    equipSetIcon:SetSize(13, 13)
    equipSetIcon:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 1, 1)
    equipSetIcon:SetTexture("Interface\\AddOns\\GudaBags\\Assets\\equipment.tga")
    equipSetIcon:Hide()
    button.equipSetIcon = equipSetIcon

    -- Pin icon shadow (bottom-left corner, replaces category mark when pinned)
    local pinIconShadow = button:CreateTexture(nil, "OVERLAY", nil, 4)
    pinIconShadow:SetSize(15, 15)
    pinIconShadow:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0)
    pinIconShadow:SetTexture("Interface\\AddOns\\GudaBags\\Assets\\pin.tga")
    pinIconShadow:SetVertexColor(0, 0, 0, 1)
    pinIconShadow:Hide()
    button.pinIconShadow = pinIconShadow

    -- Pin icon (bottom-left corner, replaces category mark when pinned)
    local pinIcon = button:CreateTexture(nil, "OVERLAY", nil, 5)
    pinIcon:SetSize(13, 13)
    pinIcon:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 1, 1)
    pinIcon:SetTexture("Interface\\AddOns\\GudaBags\\Assets\\pin.tga")
    pinIcon:Hide()
    button.pinIcon = pinIcon

    -- User lock icon container (above quality border)
    local userLockFrame = CreateFrame("Frame", nil, button)
    userLockFrame:SetAllPoints(button)
    userLockFrame:SetFrameLevel(button:GetFrameLevel() + Constants.FRAME_LEVELS.BORDER + 2)

    -- User lock icon stroke (bottom-right corner, slightly larger black copy for outline)
    local userLockIconStroke = userLockFrame:CreateTexture(nil, "OVERLAY", nil, 6)
    userLockIconStroke:SetSize(11, 11)
    userLockIconStroke:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 5, -4)
    userLockIconStroke:SetTexture("Interface\\AddOns\\GudaBags\\Assets\\lock.tga")
    userLockIconStroke:SetVertexColor(0, 0, 0, 1)
    userLockIconStroke:Hide()
    button.userLockIconStroke = userLockIconStroke

    -- User lock icon (bottom-right corner)
    local userLockIcon = userLockFrame:CreateTexture(nil, "OVERLAY", nil, 7)
    userLockIcon:SetSize(9, 9)
    userLockIcon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 4, -3)
    userLockIcon:SetTexture("Interface\\AddOns\\GudaBags\\Assets\\lock.tga")
    userLockIcon:Hide()
    button.userLockIcon = userLockIcon
    button.userLockFrame = userLockFrame

    -- Item level text (top-right corner). Top-left is reserved for SimpleItemLevel
    -- when that addon is loaded (it places its iLvl there by default).
    local itemLevelText = button:CreateFontString(nil, "OVERLAY", nil)
    Font:Apply(itemLevelText, 12, "OUTLINE")
    itemLevelText:SetPoint("TOPRIGHT", button, "TOPRIGHT", -2, -2)
    itemLevelText:SetJustifyH("RIGHT")
    itemLevelText:Hide()
    button.itemLevelText = itemLevelText

    -- Charges text (bottom-right corner, e.g. "x5" for Wizard Oil)
    local chargesText = button:CreateFontString(nil, "OVERLAY", nil)
    Font:Apply(chargesText, 12, "OUTLINE")
    chargesText:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, 1)
    chargesText:SetJustifyH("RIGHT")
    chargesText:SetTextColor(1, 0.82, 0)
    chargesText:Hide()
    button.chargesText = chargesText

    -- BoE label (bottom-left corner, drawn above equipment-set and pin icons
    -- which sit on the same corner — sublayer 6 puts it above those
    -- sublayer 2-5 icons. OUTLINE keeps it readable when stacked on top of them.)
    -- Color is set per-item in SetItem() based on item quality.
    local boeText = button:CreateFontString(nil, "OVERLAY", nil, 6)
    Font:Apply(boeText, 10, "OUTLINE")
    boeText:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 1, 1)
    boeText:SetJustifyH("LEFT")
    boeText:SetText("BoE")
    boeText:Hide()
    button.boeText = boeText

    -- Quest starter icon (top left corner) - exclamation mark for quest starter items
    -- Use a frame container to ensure it draws above the border
    local questStarterFrame = CreateFrame("Frame", nil, button)
    questStarterFrame:SetFrameLevel(button:GetFrameLevel() + Constants.FRAME_LEVELS.QUEST_ICON)
    questStarterFrame:SetSize(14, 14)
    questStarterFrame:SetPoint("TOPLEFT", button, "TOPLEFT", -4, 2)
    local questStarterIcon = questStarterFrame:CreateTexture(nil, "OVERLAY")
    questStarterIcon:SetAllPoints()
    questStarterIcon:SetTexture("Interface\\GossipFrame\\AvailableQuestIcon")
    questStarterFrame:Hide()
    button.questStarterIcon = questStarterFrame

    -- Quest item icon (top left corner) - question mark for regular quest items
    -- Use a frame container to ensure it draws above the border
    local questIconFrame = CreateFrame("Frame", nil, button)
    questIconFrame:SetFrameLevel(button:GetFrameLevel() + Constants.FRAME_LEVELS.QUEST_ICON)
    questIconFrame:SetSize(14, 14)
    questIconFrame:SetPoint("TOPLEFT", button, "TOPLEFT", -4, 2)
    local questIcon = questIconFrame:CreateTexture(nil, "OVERLAY")
    questIcon:SetAllPoints()
    questIcon:SetTexture("Interface\\GossipFrame\\ActiveQuestIcon")
    questIconFrame:Hide()
    button.questIcon = questIconFrame

    -- Replace tooltip scripts (not hook, to prevent template's SetBagItem from running first)
    button:SetScript("OnEnter", function(self)
        -- Wrap in pcall to prevent errors from breaking interaction
        local success, err = pcall(function()
            -- Initialize shift state tracking for tooltip refresh
            self.lastShiftState = IsShiftKeyDown()

            -- A "live slot" is a real, currently-accessible container slot whose
            -- button IDs map to bagID/slot (set in SetItem), so Blizzard's secure
            -- handler resolves the correct item. Read-only/cached and guild-bank
            -- (IDs forced to 0) and keyring (bagID -2, hyperlink path) are NOT
            -- live slots — they need ShowForItem's SetHyperlink/SetItemByID.
            -- Bank slots are also excluded: Blizzard's ContainerFrameItemButton_OnEnter
            -- does not resolve the Classic main bank container (bagID -1), so it would
            -- leave the item body empty while our SetBagItem hook still adds the
            -- inventory counts — making blizzardPopulated wrongly true. Bank items are
            -- never shown at a merchant, so routing them through ShowForItem cannot
            -- reintroduce the sell-price money-frame taint the live-slot path guards.
            local liveSlot = self.itemData and self.itemData.bagID and self.itemData.slot
                and not self.isReadOnly
                and not self.itemData.isGuildBank
                and self.itemData.bagID ~= -2
                and not Tooltip:IsBankSlot(self.itemData.bagID)
                and not self.isEmptySlotButton and not self.isDropTargetButton
                and not self.itemData.isEmptySlots

            -- Call Blizzard's handler for sell cursor, inspect cursor, etc.
            -- Skip for pseudo-items (Empty/Soul/DropTarget) which don't have real bag slots
            local blizzardPopulated = false
            if self.itemData and self.itemData.bagID and not self.isEmptySlotButton and not self.isDropTargetButton and not self.itemData.isEmptySlots then
                -- ContainerFrameItemButton_OnEnter may not exist on retail
                if ContainerFrameItemButton_OnEnter then
                    ContainerFrameItemButton_OnEnter(self)
                    -- For live slots Blizzard's handler already populated GameTooltip
                    -- (item info + sell-price money frame). Re-driving it below with
                    -- our own SetBagItem stores the sell price a second time and
                    -- taints GameTooltip's money frame ("secret number value" in
                    -- MoneyFrame_Update). Our inventory counts come from the
                    -- hooksecurefunc on SetBagItem (UI/Tooltip.lua); the track hint
                    -- is appended below, so the tooltip stays complete.
                    if liveSlot then
                        blizzardPopulated = GameTooltip:IsOwned(self) and (GameTooltip:NumLines() or 0) > 0
                    end
                end
            end

            -- Show our custom tooltip (overrides Blizzard's if needed)
            -- Don't show tooltip for Empty/Soul pseudo-item buttons
            -- For drop-target buttons, show a hint tooltip
            if self.isDropTargetButton then
                local L = ns.L
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(L["DROP_HERE_TO_ASSIGN"], 1, 1, 1)
                GameTooltip:Show()
            elseif blizzardPopulated then
                -- Blizzard owns the tooltip; only append our GudaBags track hint.
                Tooltip:AddTrackHint(self)
                GameTooltip:Show()
            elseif not self.isEmptySlotButton and not (self.itemData and self.itemData.isEmptySlots) then
                Tooltip:ShowForItem(self)
            end


            -- Debug item info on hover
            if ns.debugItemMode and self.itemData and self.itemData.link then
                local d = self.itemData
                local catName = "?"
                if self.categoryId then
                    local CategoryManager = ns:GetModule("CategoryManager")
                    if CategoryManager then
                        local catDef = CategoryManager:GetCategory(self.categoryId)
                        catName = catDef and catDef.name or self.categoryId
                    end
                end
                ns:Print(format("|cff00ff00[DebugItem]|r %s | ID: %s | Bag: %s Slot: %s | Count: %s | Quality: %s | Category: %s | Type: %s - %s | Quest: %s | Duration: %s",
                    d.link or "?",
                    tostring(d.itemID or "?"),
                    tostring(d.bagID or "?"),
                    tostring(d.slot or "?"),
                    tostring(d.count or 1),
                    tostring(d.quality or "?"),
                    tostring(catName),
                    tostring(d.itemType or "?"),
                    tostring(d.itemSubType or "?"),
                    tostring(d.isQuestItem or false),
                    tostring(d.hasDuration or false)
                ))
            end

            -- Show drag-drop indicator if cursor has item and this is a category view item
            if self.categoryId and self.containerFrame then
                local cursorType = GetCursorInfo()
                if cursorType == "item" then
                    local CategoryDropIndicator = ns:GetModule("CategoryDropIndicator")
                    if CategoryDropIndicator then
                        CategoryDropIndicator:OnItemButtonEnter(self)
                    end
                end
            end
        end)
        if not success and ns.debugMode then
            ns:Print("OnEnter error: " .. tostring(err))
        end
    end)

    button:SetScript("OnLeave", function(self)
        -- Wrap in pcall to prevent errors
        local success, err = pcall(function()
            -- Clear shift state tracking
            self.lastShiftState = nil

            -- Call Blizzard's handler to clear cursor state (may not exist on retail)
            if ContainerFrameItemButton_OnLeave then
                ContainerFrameItemButton_OnLeave(self)
            end

            -- Hide our custom tooltip
            Tooltip:Hide()

            -- Hide drag-drop indicator
            local CategoryDropIndicator = ns:GetModule("CategoryDropIndicator")
            if CategoryDropIndicator then
                CategoryDropIndicator:OnItemButtonLeave()
            end
        end)
        if not success and ns.debugMode then
            ns:Print("OnLeave error: " .. tostring(err))
        end
    end)

    -- Update indicator position while hovering with dragged item
    -- Also refresh tooltip when shift key state changes (for price display)
    button:SetScript("OnUpdate", function(self)
        -- Track shift key state for tooltip refresh
        if self:IsMouseOver() then
            local shiftDown = IsShiftKeyDown()
            if self.lastShiftState ~= shiftDown then
                self.lastShiftState = shiftDown
                -- Refresh tooltip when shift state changes (for stack price vs single price).
                -- Replay OnEnter so the refresh uses the same path as the initial hover
                -- (Blizzard-driven for live slots) instead of a second insecure SetBagItem,
                -- which would re-taint GameTooltip's money frame. Skip with a held cursor
                -- (see the OnUpdate replay note below re: CursorUpdate desaturation).
                if self.itemData and not self.isEmptySlotButton and not self.isDropTargetButton
                    and not self.itemData.isEmptySlots and not GetCursorInfo() then
                    local onEnter = self:GetScript("OnEnter")
                    if onEnter then onEnter(self) end
                end
            end
        end

        -- Update drag-drop indicator position
        if self.categoryId and self.containerFrame and self:IsMouseOver() then
            local CategoryDropIndicator = ns:GetModule("CategoryDropIndicator")
            if CategoryDropIndicator and CategoryDropIndicator:IsShown() then
                CategoryDropIndicator:OnItemButtonUpdate(self)
            end
        end
    end)

    -- Disable template's tooltip update mechanism
    button.UpdateTooltip = nil

    -- Helper function to find current first empty slot for pseudo-items
    -- For Soul pseudo-items, find empty slot in soul bags
    -- For Empty pseudo-items, find empty slot in regular bags
    local function FindCurrentEmptySlot(btn)
        if not btn.isEmptySlotButton and not (btn.itemData and btn.itemData.isEmptySlots) then
            return nil, nil
        end

        -- Check if this is a Soul category pseudo-item
        local isSoulCategory = btn.categoryId == "Soul" or (btn.itemData and btn.itemData.isSoulSlots)
        -- Check if this is a Quiver category pseudo-item (Hunter equivalent of Soul)
        local isQuiverCategory = btn.categoryId == "Quiver" or (btn.itemData and btn.itemData.isQuiverSlots)

        -- Determine if this button belongs to the bank or player bags
        -- by checking the current bagID on the button
        local currentBagID = btn.itemData and btn.itemData.bagID or btn:GetParent():GetID()
        local Constants = ns.Constants
        local isBankSlot = currentBagID == Constants.BANK_MAIN_BAG
            or (currentBagID >= Constants.BANK_BAG_MIN and currentBagID <= Constants.BANK_BAG_MAX)

        -- Use BagClassifier for accurate bag type detection
        local BagClassifier = ns:GetModule("BagFrame.BagClassifier")

        -- Build list of bag IDs to search
        local bagIDsToSearch
        if isBankSlot then
            bagIDsToSearch = Constants.BANK_BAG_IDS
        else
            bagIDsToSearch = Constants.BAG_IDS
        end

        -- Scan appropriate bags to find first empty slot
        for _, bagID in ipairs(bagIDsToSearch) do
            local numSlots = C_Container.GetContainerNumSlots(bagID)
            if numSlots and numSlots > 0 then
                -- Check bag type using BagClassifier
                local bagType = BagClassifier and BagClassifier:GetBagType(bagID) or "regular"
                local isSoulBag = (bagType == "soul")
                local isQuiverBag = (bagType == "quiver" or bagType == "ammo")

                -- Match bag type to category
                local shouldSearchThisBag = false
                if isSoulCategory then
                    shouldSearchThisBag = isSoulBag
                elseif isQuiverCategory then
                    shouldSearchThisBag = isQuiverBag
                else
                    -- Empty category: regular bags only (backpack/main bank or regular bag type)
                    shouldSearchThisBag = (bagID == 0) or (bagID == Constants.BANK_MAIN_BAG) or (bagType == "regular")
                end

                if shouldSearchThisBag then
                    for slotID = 1, numSlots do
                        local itemInfo = C_Container.GetContainerItemInfo(bagID, slotID)
                        if not itemInfo then
                            -- Found empty slot
                            return bagID, slotID
                        end
                    end
                end
            end
        end

        return nil, nil
    end

    -- Update bagID/slotID for pseudo-item before click/drag
    local function UpdatePseudoItemSlot(btn)
        if not btn.isEmptySlotButton and not (btn.itemData and btn.itemData.isEmptySlots) then
            return false
        end

        local newBagID, newSlotID = FindCurrentEmptySlot(btn)
        if newBagID and newSlotID then
            btn.wrapper:SetID(newBagID)
            btn:SetID(newSlotID)
            if btn.itemData then
                btn.itemData.bagID = newBagID
                btn.itemData.slot = newSlotID
            end
            return true
        end

        return false  -- No empty slot found
    end

    -- Ctrl+Alt+Click to track/untrack items
    -- Also handle guild bank item clicks and read-only item linking
    button:HookScript("OnClick", function(self, mouseButton)
        -- Complete warband bank deposit (PreClick blocked the template)
        if self._warbandIntercept then
            local data = self._warbandIntercept
            self._warbandIntercept = nil
            -- Restore IDs for future clicks
            self.wrapper:SetID(data.bagID)
            self:SetID(data.slot)
            -- Deposit to warband bank
            C_Container.UseContainerItem(data.bagID, data.slot, nil, Enum.BankType.Account)
            return
        end

        -- Wrap in pcall to prevent errors from breaking item interaction
        local success, err = pcall(function()
            -- Handle shift-click to link items in chat for read-only items (cached/view mode)
            -- The template's handler doesn't work because we set IDs to 0 for read-only mode
            if mouseButton == "LeftButton" and IsShiftKeyDown() and self.isReadOnly then
                local link = self.itemData and (self.itemData.link or self.itemData.itemLink)
                if link then
                    HandleModifiedItemClick(link)
                end
                return
            end

            -- Track/untrack with Ctrl+Alt+Click
            if mouseButton == "LeftButton" and IsControlKeyDown() and IsAltKeyDown() then
                if self.itemData and self.itemData.itemID then
                    local TrackedBar = ns:GetModule("TrackedBar")
                    if TrackedBar then
                        TrackedBar:ToggleTrackItem(self.itemData.itemID)
                    end
                end
                return
            end

            -- Lock/unlock item with Ctrl+Right-Click
            if mouseButton == "RightButton" and IsControlKeyDown() and not IsAltKeyDown() and not self.isReadOnly then
                if self.itemData and self.itemData.itemID then
                    local Database = ns:GetModule("Database")
                    -- Equipment set items: toggle exception instead of manual lock
                    if Database:GetSetting("autoLockSetItems") then
                        local EquipSets = ns:GetModule("EquipmentSets")
                        if EquipSets and EquipSets:IsInSet(self.itemData.itemID) then
                            local isNowExcepted = Database:ToggleSetProtectionException(self.itemData.itemID)
                            local L = ns.L
                            local itemRef = self.itemData.link or self.itemData.name or ""
                            if isNowExcepted then
                                ns:Print(string.format(L["ITEM_SET_PROTECTION_REMOVED"], itemRef))
                            else
                                ns:Print(string.format(L["ITEM_SET_PROTECTION_RESTORED"], itemRef))
                            end
                            local BagFrame = ns:GetModule("BagFrame")
                            if BagFrame and BagFrame.RefreshLockIcons then
                                BagFrame:RefreshLockIcons()
                            end
                            local BankFrame = ns:GetModule("BankFrame")
                            if BankFrame and BankFrame.RefreshLockIcons then
                                BankFrame:RefreshLockIcons()
                            end
                            return
                        end
                    end
                    local isNowLocked = Database:ToggleItemLock(self.itemData.itemID)
                    local L = ns.L
                    if isNowLocked then
                        ns:Print(string.format(L["ITEM_LOCKED"], self.itemData.link or self.itemData.name or ""))
                    else
                        ns:Print(string.format(L["ITEM_UNLOCKED"], self.itemData.link or self.itemData.name or ""))
                    end
                    local BagFrame = ns:GetModule("BagFrame")
                    if BagFrame and BagFrame.RefreshLockIcons then
                        BagFrame:RefreshLockIcons()
                    end
                    local BankFrame = ns:GetModule("BankFrame")
                    if BankFrame and BankFrame.RefreshLockIcons then
                        BankFrame:RefreshLockIcons()
                    end
                end
                return
            end

            -- Pin/unpin slot with Alt+Right-Click (requires GudaBags sort on Retail)
            if mouseButton == "RightButton" and IsAltKeyDown() and not self.isReadOnly then
                if ns.IsRetail and not ns:GetModule("Database"):GetSetting("gudaSort") then
                    return
                end
                if self.itemData and self.itemData.bagID ~= nil and self.itemData.slot and not self.itemData.isGuildBank then
                    local Database = ns:GetModule("Database")
                    Database:TogglePinnedSlot(self.itemData.bagID, self.itemData.slot)
                    local BagFrame = ns:GetModule("BagFrame")
                    if BagFrame and BagFrame.RefreshPinIcons then
                        BagFrame:RefreshPinIcons()
                    end
                    local BankFrame = ns:GetModule("BankFrame")
                    if BankFrame and BankFrame.RefreshPinIcons then
                        BankFrame:RefreshPinIcons()
                    end
                end
                return
            end

            -- Handle guild bank items (not handled by ContainerFrameItemButtonTemplate)
            if self.itemData and self.itemData.isGuildBank and not self.isReadOnly then
                local tabIndex = self.itemData.bagID  -- bagID is actually tabIndex for guild bank
                local slotIndex = self.itemData.slot

                if mouseButton == "LeftButton" then
                    if IsShiftKeyDown() and self.itemData.count and self.itemData.count > 1 then
                        -- Split stack
                        OpenStackSplitFrame(self.itemData.count, self, "BOTTOMLEFT", "TOPLEFT")
                    else
                        -- Pick up / place item
                        PickupGuildBankItem(tabIndex, slotIndex)
                    end
                elseif mouseButton == "RightButton" then
                    -- Right-click to auto-move to bags (if at guild bank)
                    local GuildBankScanner = ns:GetModule("GuildBankScanner")
                    if GuildBankScanner and GuildBankScanner:IsGuildBankOpen() then
                        AutoStoreGuildBankItem(tabIndex, slotIndex)
                    end
                end
            end
        end)
        if not success and ns.debugMode then
            ns:Print("OnClick error: " .. tostring(err))
        end
    end)

    -- Handle stack split for guild bank items
    button.SplitStack = function(self, amount)
        if self.itemData and self.itemData.isGuildBank and not self.isReadOnly then
            local tabIndex = self.itemData.bagID
            local slotIndex = self.itemData.slot
            SplitGuildBankItem(tabIndex, slotIndex, amount)
        end
    end

    -- Helper function to find where the cursor item is coming from
    -- Returns "bag", "bank", or nil if unknown
    local function GetCursorItemSource()
        -- Check player bags (0 to NUM_BAG_SLOTS) for locked slot
        for bagID = 0, NUM_BAG_SLOTS do
            local numSlots = C_Container.GetContainerNumSlots(bagID)
            for slot = 1, numSlots do
                local itemInfo = C_Container.GetContainerItemInfo(bagID, slot)
                if itemInfo and itemInfo.isLocked then
                    return "bag"
                end
            end
        end

        -- Check bank slots for locked slot
        -- Build bank bag list based on game version
        local bankBags = {}

        -- On modern Retail (12.0+), use Character Bank Tabs
        if Constants.CHARACTER_BANK_TAB_IDS and #Constants.CHARACTER_BANK_TAB_IDS > 0 then
            for _, tabID in ipairs(Constants.CHARACTER_BANK_TAB_IDS) do
                table.insert(bankBags, tabID)
            end
        end

        -- Also check Warband/Account bank tabs
        if Constants.WARBAND_BANK_TAB_IDS and #Constants.WARBAND_BANK_TAB_IDS > 0 then
            for _, tabID in ipairs(Constants.WARBAND_BANK_TAB_IDS) do
                table.insert(bankBags, tabID)
            end
        end

        -- Use BANK_BAG_IDS as fallback (works for older Retail and Classic)
        if #bankBags == 0 and Constants.BANK_BAG_IDS and #Constants.BANK_BAG_IDS > 0 then
            for _, bagID in ipairs(Constants.BANK_BAG_IDS) do
                table.insert(bankBags, bagID)
            end
        end

        for _, bagID in ipairs(bankBags) do
            local numSlots = C_Container.GetContainerNumSlots(bagID)
            if numSlots and numSlots > 0 then
                for slot = 1, numSlots do
                    local itemInfo = C_Container.GetContainerItemInfo(bagID, slot)
                    if itemInfo and itemInfo.isLocked then
                        return "bank"
                    end
                end
            end
        end

        return nil
    end

    -- Helper function to check if swap should be BLOCKED
    -- Returns true to BLOCK swap (same container - no swapping within bag or within bank)
    -- Returns false to ALLOW swap (cross-container only - bag↔bank)
    local function ShouldBlockSwap(targetButton)
        -- Only block in category view with valid target
        if not targetButton.categoryId or not targetButton.itemData then
            return false
        end

        local cursorType, cursorItemID = GetCursorInfo()
        if cursorType ~= "item" or not cursorItemID then
            return false
        end

        -- Determine if this is a cross-container operation
        -- Cross-container swaps (bag↔bank) are ALLOWED
        -- Same-container swaps (bag→bag or bank→bank) are BLOCKED
        if targetButton.containerFrame then
            local containerName = targetButton.containerFrame:GetName()
            local cursorSource = GetCursorItemSource()

            if containerName == "GudaBankContainer" then
                -- Target is in bank
                if cursorSource == "bag" then
                    return false  -- Bag to Bank - ALLOW
                else
                    return true   -- Bank to Bank - BLOCK
                end
            end

            if containerName == "GudaBagsSecureContainer" then
                -- Target is in bag
                if cursorSource == "bank" then
                    return false  -- Bank to Bag - ALLOW
                else
                    return true   -- Bag to Bag - BLOCK
                end
            end
        end

        -- Same container operation - block the swap
        return true
    end

    -- Prevent swapping via click within the same container (bag or bank)
    -- Only allow cross-container swaps (bag↔bank)
    -- Also update pseudo-item slots to use current empty slot
    -- NOTE: On Retail, skip these operations to avoid tainting the secure click handler
    button:HookScript("PreClick", function(self, mouseButton)
        -- Suppress spurious "Item isn't ready yet" errors on retail
        SuppressItemErrors()

        -- Intercept right-click to deposit into warband bank instead of character bank
        -- The secure template calls UseContainerItem without bankType, defaulting to character bank
        if ns.IsRetail and mouseButton == "RightButton" and not IsModifiedClick() then
            local RetailBankScanner = ns:GetModule("RetailBankScanner")
            local BankFooter = ns:GetModule("BankFrame.BankFooter")
            if RetailBankScanner and RetailBankScanner:IsBankOpen()
               and BankFooter and BankFooter:GetCurrentBankType() == "warband"
               and self.itemData and self.itemData.itemID
               and not self.itemData.isGuildBank and not self.isReadOnly then
                -- Only intercept bag items (not bank items being withdrawn)
                local isBagItem = false
                for _, id in ipairs(Constants.BAG_IDS) do
                    if self.itemData.bagID == id then
                        isBagItem = true
                        break
                    end
                end
                if isBagItem then
                    self._warbandIntercept = { bagID = self.itemData.bagID, slot = self.itemData.slot }
                    -- SetID(0) blocks the secure template's default UseContainerItem
                    -- Wrapped in pcall to contain any taint propagation
                    pcall(function()
                        self.wrapper:SetID(0)
                        self:SetID(0)
                    end)
                end
            end
        end

        -- On Retail, don't do anything that could taint the secure click path
        -- Protection is handled via spell guard (OnUpdate) and merchant overlays
        if ns.IsRetail then return end

        -- For pseudo-item buttons, update to current empty slot BEFORE secure handler runs
        if self.isEmptySlotButton or (self.itemData and self.itemData.isEmptySlots) then
            local cursorType = GetCursorInfo()
            if cursorType == "item" then
                UpdatePseudoItemSlot(self)
            end
            return  -- Don't check same-category for pseudo-items
        end

        -- For drop-target buttons, assign item to category on click
        if self.isDropTargetButton and mouseButton == "LeftButton" then
            local infoType, itemID = GetCursorInfo()
            if infoType == "item" and itemID then
                ClearCursor()
                local CategoryManager = ns:GetModule("CategoryManager")
                if CategoryManager then
                    CategoryManager:AssignItemToCategory(itemID, self.categoryId)
                end
            end
            return
        end

        if mouseButton == "LeftButton" and ShouldBlockSwap(self) then
            ClearCursor()
        end
    end)

    -- Custom OnReceiveDrag to prevent swapping items within the same container
    -- Only allows cross-container swaps (bag↔bank)
    -- Also handles pseudo-item buttons to place items in current empty slot
    -- Also handles guild bank items
    local originalReceiveDrag = button:GetScript("OnReceiveDrag")
    button:SetScript("OnReceiveDrag", function(self)
        -- Handle guild bank items (works on both Classic and Retail)
        if self.itemData and self.itemData.isGuildBank and not self.isReadOnly then
            local cursorType = GetCursorInfo()
            if cursorType == "item" then
                local tabIndex = self.itemData.bagID
                local slotIndex = self.itemData.slot
                PickupGuildBankItem(tabIndex, slotIndex)
            end
            return
        end

        -- For pseudo-item buttons (Empty/Soul), find current empty slot
        if self.isEmptySlotButton or (self.itemData and self.itemData.isEmptySlots) then
            local cursorType = GetCursorInfo()
            if cursorType == "item" then
                local newBagID, newSlotID = FindCurrentEmptySlot(self)
                if newBagID and newSlotID then
                    -- Place item in the current first empty slot
                    C_Container.PickupContainerItem(newBagID, newSlotID)
                end
            end
            return
        end

        -- For drop-target buttons, assign item to category
        if self.isDropTargetButton then
            local infoType, itemID = GetCursorInfo()
            if infoType == "item" and itemID then
                ClearCursor()
                local CategoryManager = ns:GetModule("CategoryManager")
                if CategoryManager then
                    CategoryManager:AssignItemToCategory(itemID, self.categoryId)
                end
            end
            return
        end

        -- Block same-container swaps (only allow cross-container bag↔bank)
        -- This check applies to both Classic and Retail
        if ShouldBlockSwap(self) then
            ClearCursor()
            return
        end

        -- Allow cross-container swap (bag↔bank)
        -- Use itemData for bag/slot since GudaBags uses pooled buttons
        if self.itemData and self.itemData.bagID and self.itemData.slot then
            C_Container.PickupContainerItem(self.itemData.bagID, self.itemData.slot)
        elseif originalReceiveDrag then
            originalReceiveDrag(self)
        end
    end)

    return button
end

function ItemButton:Acquire(parent)
    -- Lazy initialize pool on first use
    if not buttonPool then
        buttonPool = CreateObjectPool(
            function() return CreateButton(parent) end,
            ResetButton
        )
    end

    local button = buttonPool:Acquire()
    button._pooledActive = true  -- O(1) active flag (see ItemButton:Release)
    button.wrapper:SetParent(parent)
    button.wrapper:SetShown(true)  -- Use SetShown to avoid taint during combat
    button:SetShown(true)
    button.owner = parent

    -- Note: Masque registration is deferred to SetItem/SetEmpty so it runs AFTER button sizing.
    -- Registering here (before sizing) causes Masque to override icon anchors at the wrong size.

    -- Apply retail slot textures immediately so first-open doesn't flash default
    ApplyThemeToButton(button, GetEffectiveSlotTextures())

    return button
end

function ItemButton:Release(button)
    if not buttonPool then return end

    -- Guard against double-release. This used to linearly scan EnumerateActive()
    -- on every call: O(active) per release, so releasing N buttons was O(N*active)
    -- — quadratic, and the pool is shared across bags/bank/guild bank/mail (can be
    -- ~600 active). An O(1) flag (set in Acquire, cleared in ResetButton) replaces it.
    if not button or not button._pooledActive then return end

    -- Keep button.currentSize intact: a pooled button reused at the same icon size
    -- can then skip the redundant SetSize/Masque re-register in EnsureButtonSize.
    -- (EnsureButtonSize still resizes correctly when the size actually differs.)

    -- Release to pool (ResetButton callback handles hide/clear/anchors)
    buttonPool:Release(button)
end

function ItemButton:ReleaseAll(owner)
    if not buttonPool then return end

    -- If owner specified, we need to iterate and release matching buttons
    if owner then
        -- Collect buttons to release (can't modify during iteration)
        local toRelease = {}
        for button in buttonPool:EnumerateActive() do
            if button.owner == owner then
                table.insert(toRelease, button)
            end
        end
        for _, button in ipairs(toRelease) do
            self:Release(button)
        end
    else
        -- Release all - pool's ReleaseAll handles cleanup via ResetButton callback
        -- Skip visual reset here - will be done in SetItem when button is reused
        buttonPool:ReleaseAll()
    end
end

-- Pre-create buttons so they're available during combat
-- ContainerFrameItemButtonTemplate is a secure template that cannot be created during combat
-- Call this on PLAYER_LOGIN before entering combat
function ItemButton:PreWarm(parent, count)
    count = count or 200  -- Default to 200 buttons (enough for all bag slots + buffer)

    -- Initialize pool if needed
    if not buttonPool then
        buttonPool = CreateObjectPool(
            function() return CreateButton(parent) end,
            ResetButton
        )
    end

    -- Create buttons by acquiring from pool
    for i = 1, count do
        local button = buttonPool:Acquire()
        button.wrapper:SetParent(parent)
    end

    -- Release all back to pool so they're available for use
    buttonPool:ReleaseAll()

end

-- Background pool growth: secure-frame creation is the bulk of the first big open
-- (e.g. a warband bank's All-Tabs view needs ~550 buttons but PreWarm only makes
-- ~200, so ~350 are created on the spot — a visible freeze). This grows the pool to
-- `target` in small batches across idle frames AFTER login, so by the time the bank
-- opens the buttons already exist. Out of combat only (secure frames can't be created
-- in combat); it pauses during combat and resumes after. Holds the batch acquired
-- until `target` is reached, then releases all back to the pool as free buttons.
local bgGrowTicker = nil
function ItemButton:BackgroundGrowPool(parent, target, perTick, interval)
    if bgGrowTicker then return end  -- already running / done
    if not buttonPool then
        buttonPool = CreateObjectPool(function() return CreateButton(parent) end, ResetButton)
    end
    target = target or 750
    perTick = perTick or 15
    local held = {}
    local function finish(ticker)
        for _, b in ipairs(held) do buttonPool:Release(b) end
        held = {}
        ticker:Cancel()
        bgGrowTicker = nil
    end
    bgGrowTicker = C_Timer.NewTicker(interval or 0.05, function(ticker)
        -- Don't create secure frames in combat; resume on the next tick after combat.
        if InCombatLockdown() then return end
        -- If a real consumer (bag/bank/guild bank) acquired buttons, it's already
        -- growing the pool itself — release our batch and stop so we don't compete.
        if buttonPool.GetNumActive and buttonPool:GetNumActive() > #held then
            finish(ticker)
            return
        end
        for _ = 1, perTick do
            if #held >= target then
                finish(ticker)
                return
            end
            local b = buttonPool:Acquire()  -- reuses free first, then creates new
            b.wrapper:SetParent(parent)
            b:SetShown(false)
            b.wrapper:SetShown(false)
            held[#held + 1] = b
        end
    end)
end

-- Check if a cooldown is just the GCD (matches global cooldown start/duration)
local function IsGlobalCooldown(start, duration)
    if not GetSpellCooldown then return false end
    local gcdStart, gcdDuration = GetSpellCooldown(61304)  -- Global Cooldown spell
    if not gcdStart or gcdStart == 0 then return false end
    return start == gcdStart and math.abs(duration - gcdDuration) < 0.01
end

-- Cached settings for batch updates (set by SetItemBatch or refreshed on demand)
local cachedSettings = nil
local cachedSettingsFrame = 0  -- Frame number when cached

local function GetCachedSettings()
    local currentFrame = GetTime()
    -- Cache settings for 0.1 second to avoid repeated lookups during batch updates
    if not cachedSettings or (currentFrame - cachedSettingsFrame) > 0.1 then
        cachedSettings = {
            iconSize = Database:GetSetting("iconSize"),
            bgAlpha = Database:GetSetting("bgAlpha") / 100,
            iconFontSize = Database:GetSetting("iconFontSize"),
            grayoutJunk = Database:GetSetting("grayoutJunk"),
            equipmentBorders = Database:GetSetting("equipmentBorders"),
            otherBorders = Database:GetSetting("otherBorders"),
            markUnusableItems = Database:GetSetting("markUnusableItems"),
            markEquipmentSets = Database:GetSetting("markEquipmentSets"),
            showItemLevel = Database:GetSetting("showItemLevel"),
            showCharges = Database:GetSetting("showCharges"),
            showBoeLabel = Database:GetSetting("showBoeLabel"),
        }
        cachedSettingsFrame = currentFrame
    end
    return cachedSettings
end

-- Invalidate cached settings (call when settings change)
function ItemButton:InvalidateSettingsCache()
    cachedSettings = nil
end

-- Drop target: create a pulsing green glow border lazily on first use
local function EnsureDropTargetGlow(button)
    if button.dropTargetGlow then return button.dropTargetGlow end

    -- Parent to wrapper so button:SetAlpha() doesn't dim the glow
    local glow = CreateFrame("Frame", nil, button.wrapper)
    glow:SetPoint("TOPLEFT", button, "TOPLEFT", -5, 5)
    glow:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 5, -5)
    glow:SetFrameLevel(button:GetFrameLevel() + Constants.FRAME_LEVELS.BORDER + 1)

    local border = CreateFrame("Frame", nil, glow, "BackdropTemplate")
    border:SetAllPoints(glow)
    border:SetBackdrop({
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    border:SetBackdropBorderColor(0.3, 0.9, 0.3, 0.8)

    local animGroup = glow:CreateAnimationGroup()
    local fadeOut = animGroup:CreateAnimation("Alpha")
    fadeOut:SetFromAlpha(1)
    fadeOut:SetToAlpha(0.2)
    fadeOut:SetDuration(0.6)
    fadeOut:SetOrder(1)
    fadeOut:SetSmoothing("IN_OUT")
    local fadeIn = animGroup:CreateAnimation("Alpha")
    fadeIn:SetFromAlpha(0.2)
    fadeIn:SetToAlpha(1)
    fadeIn:SetDuration(0.6)
    fadeIn:SetOrder(2)
    fadeIn:SetSmoothing("IN_OUT")
    animGroup:SetLooping("REPEAT")
    glow.animGroup = animGroup
    glow:Hide()
    button.dropTargetGlow = glow
    return glow
end

-- Register button with Masque after sizing is complete, then reapply icon anchoring
-- Masque overrides icon anchors as part of skinning, so we must re-anchor after registration
local function ApplyMasqueAfterSizing(button)
    if ns.suspectDisabled and ns.suspectDisabled.masque then return end
    if button._masqueApplied then return end
    local MasqueModule = ns:GetModule("Masque")
    if not MasqueModule or not MasqueModule:IsActive() or not button.owner then return end

    MasqueModule:AddButton(button, button.owner.masqueGroup or "Bags")
    button._masqueApplied = true

    -- Reapply icon anchoring after Masque (Masque may override SetAllPoints)
    local icon = button.icon or button.Icon
    if icon then
        icon:ClearAllPoints()
        icon:SetAllPoints(button)
    end
end

-- Resize a pool button. If Masque has already skinned it, unregister first so
-- ApplyMasqueAfterSizing's next AddButton re-skins at the new size. Mirrors
-- TrackedBar:UpdateSize — Masque caches region geometry at AddButton time
-- and Group:ReSkin does not refresh it.
local function EnsureButtonSize(button, size)
    if button.currentSize == size then return end

    if button._masqueApplied then
        local MasqueModule = ns:GetModule("Masque")
        if MasqueModule and MasqueModule:IsActive() then
            MasqueModule:RemoveButton(button)
        end
        button._masqueApplied = false
    end

    button:SetSize(size, size)
    if button.wrapper then
        button.wrapper:SetSize(size, size)
    end
    button.currentSize = size

    UpdateSlotBackgroundSize(button, size)
end

function ItemButton:SetItem(button, itemData, size, isReadOnly)
    ns:ProfileBump("SetItem.calls")
    -- Hide Blizzard template's built-in textures (they may re-show from events)
    if button.IconBorder then button.IconBorder:Hide() end
    if button.IconOverlay then button.IconOverlay:Hide() end
    if button.NewItemTexture then button.NewItemTexture:Hide() end
    if button.BattlepayItemTexture then button.BattlepayItemTexture:Hide() end
    local MasqueModule = ns:GetModule("Masque")
    local masqueActive = MasqueModule and MasqueModule:IsActive()
    -- Don't hide NormalTexture when Masque is active — Masque manages it
    if not masqueActive then
        local normalTex = button:GetNormalTexture()
        if normalTex then normalTex:Hide() end
    end

    -- Reset visual state from previous item (lazy cleanup)
    -- These elements might not be explicitly set below
    button:SetAlpha(1)
    -- Clear pseudo-slot flags: a recycled Empty/DropTarget pseudo button reused for
    -- a real item must not keep them (recycle skips ResetButton). The pseudo branches
    -- below re-set isEmptySlotButton when applicable.
    button.isEmptySlotButton = nil
    button.isDropTargetButton = nil
    if button.trackedIcon then button.trackedIcon:Hide() end
    if button.trackedIconShadow then button.trackedIconShadow:Hide() end
    if button.equipSetIcon then button.equipSetIcon:Hide() end
    if button.equipSetIconShadow then button.equipSetIconShadow:Hide() end
    if button.questIcon then button.questIcon:Hide() end
    if button.questStarterIcon then button.questStarterIcon:Hide() end
    if button.junkIcon then button.junkIcon:Hide() end
    if button.craftingQualityIcon then button.craftingQualityIcon:Hide() end
    if button.pinIcon then button.pinIcon:Hide() end
    if button.pinIconShadow then button.pinIconShadow:Hide() end

    button.itemData = itemData
    button.isReadOnly = isReadOnly or false

    local settings = GetCachedSettings()
    size = size or settings.iconSize

    ns:ProfileStart("setitem.masque")
    EnsureButtonSize(button, size)

    -- Register with Masque after sizing (deferred from Acquire to avoid icon anchor issues)
    ApplyMasqueAfterSizing(button)
    ns:ProfileStop("setitem.masque")

    button.slotBackground:SetVertexColor(0.5, 0.5, 0.5, settings.bgAlpha)

    ApplyFontSize(button, settings.iconFontSize)

    -- Special handling for "Empty" and "Soul" category pseudo-items
    if itemData and itemData.isEmptySlots then
        -- Display texture with count
        SetItemButtonTexture(button, itemData.texture or "Interface\\PaperDoll\\UI-PaperDoll-Slot-Bag")
        SetItemButtonCount(button, itemData.emptyCount or 0)

        -- Gray out both Empty and Soul pseudo-items for consistent appearance
        SetItemButtonDesaturated(button, true)

        -- Hide all overlays
        button.border:Hide()
        if button.innerShadow then
            for _, tex in pairs(button.innerShadow) do tex:Hide() end
        end
        button.unusableOverlay:Hide()
        button.junkOverlay:Hide()
        button.lockOverlay:Hide()
        if button.itemLevelText then button.itemLevelText:Hide() end
        if button.chargesText then button.chargesText:Hide() end
        if button.boeText then button.boeText:Hide() end
        if button.upgradeArrow then button.upgradeArrow:Hide() end
        if button.cooldown then CooldownFrame_Set(button.cooldown, 0, 0, false) end

        -- Mark this button as empty slot handler
        button.isEmptySlotButton = true

        -- Set real bagID/slot so template's click handler places items correctly
        -- itemData now contains real bagID/slot of first empty slot
        button.wrapper:SetID(itemData.bagID)
        button:SetID(itemData.slot)

        -- Refresh tooltip in place if user is hovering this pseudo-slot
        -- (e.g. another bag-update changed the empty count).
        -- Skip while an item is on the cursor (see note at the normal-item path).
        if GameTooltip:IsOwned(button) and not InCombatLockdown() and not GetCursorInfo() then
            local onEnter = button:GetScript("OnEnter")
            if onEnter then onEnter(button) end
        end

        return
    end

    -- Special handling for empty category drop-target pseudo-items
    if itemData and itemData.isDropTarget then
        SetItemButtonTexture(button, itemData.texture)
        SetItemButtonCount(button, 0)

        -- Slightly dimmed icon with green-tinted slot background
        button:SetAlpha(0.5)
        button.slotBackground:SetVertexColor(0.4, 0.8, 0.4, 0.7)
        SetItemButtonDesaturated(button, true)

        -- Hide all overlays
        button.border:Hide()
        if button.innerShadow then
            for _, tex in pairs(button.innerShadow) do tex:Hide() end
        end
        button.unusableOverlay:Hide()
        button.junkOverlay:Hide()
        button.lockOverlay:Hide()
        if button.itemLevelText then button.itemLevelText:Hide() end
        if button.chargesText then button.chargesText:Hide() end
        if button.boeText then button.boeText:Hide() end
        if button.upgradeArrow then button.upgradeArrow:Hide() end
        if button.cooldown then CooldownFrame_Set(button.cooldown, 0, 0, false) end

        -- Animated glow border
        local glow = EnsureDropTargetGlow(button)
        glow:Show()
        glow.animGroup:Play()

        button.isDropTargetButton = true
        button.wrapper:SetID(0)
        button:SetID(0)

        -- Refresh tooltip in place if user is hovering this drop-target slot.
        -- Skip while an item is on the cursor (see note at the normal-item path).
        if GameTooltip:IsOwned(button) and not InCombatLockdown() and not GetCursorInfo() then
            local onEnter = button:GetScript("OnEnter")
            if onEnter then onEnter(button) end
        end

        return
    end

    if itemData then
        -- Set IDs for ContainerFrameItemButtonTemplate's secure click handler
        -- Use invalid IDs for read-only mode or guild bank items to prevent template from
        -- interfering (guild bank items are handled by our own OnClick hook)
        if isReadOnly or itemData.isGuildBank then
            -- Set to 0 for read-only mode or guild bank items
            -- Guild bank items use their own click handler, not the template's
            button.wrapper:SetID(0)
            button:SetID(0)
        else
            button.wrapper:SetID(itemData.bagID)
            button:SetID(itemData.slot)
        end

        -- Use template's built-in functions for icon and count
        SetItemButtonTexture(button, itemData.texture)
        SetItemButtonCount(button, itemData.count)

        -- Keep template's visual elements hidden (we use our own)
        if button.IconBorder then button.IconBorder:Hide() end
        if button.IconOverlay then button.IconOverlay:Hide() end

        -- Apply gray overlay for junk items
        if settings.grayoutJunk and IsJunkItem(itemData) then
            button.junkOverlay:Show()
        else
            button.junkOverlay:Hide()
        end

        -- Determine quest indicator status (used for both border and quest icons below)
        local showQuestIndicator = not (itemData.quality == 0 and IsJunkItem(itemData)) and (itemData.isQuestItem or (itemData.hasDuration and itemData.itemID and GetItemSpell(itemData.itemID)))

        -- Quality border (quest items override with golden border)
        -- These are quality indicators that coexist with Masque's button chrome
        -- equipmentBorders = uncommon (green) and above for all item types
        -- otherBorders = white/common items only
        local showBorder = false
        if itemData.quality and itemData.quality >= 2 then
            showBorder = settings.equipmentBorders
        elseif itemData.quality and itemData.quality == 1 then
            showBorder = settings.otherBorders
        end

        -- Helper to show inner shadow with color. The 4 gradient textures only
        -- depend on the color, so cache the last-applied color on the button and skip
        -- the 4 SetGradient calls when it's unchanged AND the glow is still shown.
        -- The IsShown() check makes this robust against the other code paths that hide
        -- innerShadow directly (ResetButton/SetEmpty/pseudo) without touching them.
        local function ShowInnerShadow(color)
            if ns.suspectDisabled and ns.suspectDisabled.glow then
                if button.innerShadow then
                    for _, tex in pairs(button.innerShadow) do tex:Hide() end
                end
                return
            end
            if button.innerShadow then
                local r, g, b = color[1], color[2], color[3]
                if button._glowR == r and button._glowG == g and button._glowB == b
                    and button.innerShadow.top:IsShown() then
                    return  -- already showing this exact glow — nothing to rebuild
                end
                button._glowR, button._glowG, button._glowB = r, g, b
                button.innerShadow.top:SetGradient("VERTICAL", CreateColor(r, g, b, 0), CreateColor(r, g, b, 0.5))
                button.innerShadow.bottom:SetGradient("VERTICAL", CreateColor(r, g, b, 0.5), CreateColor(r, g, b, 0))
                button.innerShadow.left:SetGradient("HORIZONTAL", CreateColor(r, g, b, 0.5), CreateColor(r, g, b, 0))
                button.innerShadow.right:SetGradient("HORIZONTAL", CreateColor(r, g, b, 0), CreateColor(r, g, b, 0.5))
                for _, tex in pairs(button.innerShadow) do tex:Show() end
            end
        end
        local function HideInnerShadow()
            if button.innerShadow then
                for _, tex in pairs(button.innerShadow) do tex:Hide() end
            end
        end

        ns:ProfileStart("setitem.glow")
        if showQuestIndicator then
            local questColor = itemData.isQuestStarter and Constants.COLORS.QUEST_STARTER or Constants.COLORS.QUEST
            button.border:SetVertexColor(questColor[1], questColor[2], questColor[3], 1)
            button.border:Show()
            ShowInnerShadow(questColor)
        elseif showBorder and itemData.quality ~= nil then
            local color = Constants.QUALITY_COLORS[itemData.quality]
            if color then
                button.border:SetVertexColor(color[1], color[2], color[3], 1)
                button.border:Show()
                ShowInnerShadow(color)
            else
                button.border:Hide()
                HideInnerShadow()
            end
        else
            button.border:Hide()
            HideInnerShadow()
        end
        ns:ProfileStop("setitem.glow")

        -- The scanner snapshots `locked` at scan time, which during an equip-swap
        -- can capture the item while it is transiently locked. When the snapshot
        -- claims locked, verify against the live API for real container items so a
        -- stale lock doesn't leave the slot greyed. Guild-bank and cached/read-only
        -- views keep the snapshot value (the live container API doesn't apply).
        local isLocked = itemData.locked
        if isLocked and not isReadOnly and not itemData.isGuildBank
            and itemData.bagID and itemData.slot then
            local liveInfo = C_Container.GetContainerItemInfo(itemData.bagID, itemData.slot)
            if liveInfo then
                isLocked = liveInfo.isLocked or false
                -- Write back so the (shared) scanner snapshot stops reporting a
                -- stale lock and future refreshes skip this live re-check.
                itemData.locked = isLocked
            end
        end

        if isLocked then
            button.lockOverlay:Show()
            SetItemButtonDesaturated(button, true)
        else
            button.lockOverlay:Hide()
            SetItemButtonDesaturated(button, false)
        end

        -- Update cooldown (skip GCD to avoid spinning every item on wand/ability use)
        ns:ProfileStart("si.cooldown")
        local isOnCooldown = false
        if button.cooldown and not isReadOnly then
            local start, duration, enable = C_Container.GetContainerItemCooldown(itemData.bagID, itemData.slot)
            if start and duration and enable and enable > 0 and duration > 0 and not IsGlobalCooldown(start, duration) then
                CooldownFrame_Set(button.cooldown, start, duration, true)
                isOnCooldown = true
            else
                CooldownFrame_Set(button.cooldown, 0, 0, false)
            end
        elseif button.cooldown then
            CooldownFrame_Set(button.cooldown, 0, 0, false)
        end
        ns:ProfileStop("si.cooldown")

        if settings.markUnusableItems and itemData.isUsable == false and not isOnCooldown then
            button.unusableOverlay:Show()
        else
            button.unusableOverlay:Hide()
        end

        if button.junkIcon then
            if IsJunkItem(itemData) then
                button.junkIcon:Show()
            else
                button.junkIcon:Hide()
            end
        end

        -- Quest item icons (starter = exclamation, regular = question mark)
        if button.questStarterIcon then
            if itemData.isQuestStarter then
                button.questStarterIcon:Show()
            else
                button.questStarterIcon:Hide()
            end
        end
        if button.questIcon then
            if showQuestIndicator and not itemData.isQuestStarter then
                button.questIcon:Show()
            else
                button.questIcon:Hide()
            end
        end

        -- Crafting quality icon (Retail profession items).
        -- itemData.craftingQualityAtlas is the exact bag-overlay atlas extracted
        -- from the item link (see Data/ItemScanner.lua GetCraftingQualityAtlas) —
        -- this guarantees the icon matches the tooltip, including War Within's
        -- new "Professions-Icon-Quality-12-Tier{N}" family.
        if button.craftingQualityIcon then
            if itemData.craftingQualityAtlas then
                local cqSize = math.max(20, math.floor(size * 0.54))
                button.craftingQualityIcon:SetSize(cqSize, cqSize)
                button.craftingQualityIcon:SetAtlas(itemData.craftingQualityAtlas, false)
                button.craftingQualityIcon:Show()
            else
                button.craftingQualityIcon:Hide()
            end
        end

        -- Tracked item icon
        if button.trackedIcon then
            local TrackedBar = ns:GetModule("TrackedBar")
            if TrackedBar and TrackedBar:IsTracked(itemData.itemID) then
                button.trackedIcon:Show()
                if button.trackedIconShadow then
                    button.trackedIconShadow:Show()
                end
            else
                button.trackedIcon:Hide()
                if button.trackedIconShadow then
                    button.trackedIconShadow:Hide()
                end
            end
        end

        -- Category mark icon (equipment sets + any category with a mark)
        if button.equipSetIcon then
            local markIcon = nil

            -- Equipment set mark (higher priority)
            if settings.markEquipmentSets and itemData.itemID then
                local EquipSets = ns:GetModule("EquipmentSets")
                if EquipSets and EquipSets:IsInSet(itemData.itemID) then
                    markIcon = "Interface\\AddOns\\GudaBags\\Assets\\equipment.tga"
                    local Database = ns:GetModule("Database")
                    if Database and Database:GetSetting("showEquipSetCategories") then
                        local CategoryManager = ns:GetModule("CategoryManager")
                        if CategoryManager then
                            local setNames = EquipSets:GetSetNames(itemData.itemID)
                            if setNames and #setNames > 0 then
                                table.sort(setNames)
                                local catDef = CategoryManager:GetCategory("EquipSet:" .. setNames[1])
                                if catDef and catDef.categoryMark then
                                    markIcon = catDef.categoryMark
                                end
                            end
                        end
                    end
                end
            end

            -- General category mark (if no equipment set mark)
            if not markIcon and button.categoryId then
                local CategoryManager = ns:GetModule("CategoryManager")
                if CategoryManager then
                    local catDef = CategoryManager:GetCategory(button.categoryId)
                    if catDef and catDef.categoryMark then
                        markIcon = catDef.categoryMark
                    end
                end
            end

            if markIcon then
                button.equipSetIcon:SetTexture(markIcon)
                button.equipSetIcon:Show()
                if button.equipSetIconShadow then
                    button.equipSetIconShadow:SetTexture(markIcon)
                    button.equipSetIconShadow:Show()
                end
            else
                button.equipSetIcon:Hide()
                if button.equipSetIconShadow then button.equipSetIconShadow:Hide() end
            end
        end

        -- Item level display (Weapon classID=2, Armor classID=4).
        -- Text color matches the quality border so iLvl is visually grouped with
        -- the other quality indicators (border, BoE label) on the same icon.
        if button.itemLevelText then
            local isEquip = itemData.classID and (itemData.classID == 2 or itemData.classID == 4)
            if settings.showItemLevel and isEquip and itemData.itemLevel and itemData.itemLevel > 0 and (itemData.quality or 0) > 0 then
                button.itemLevelText:SetText(itemData.itemLevel)
                local c = Constants.QUALITY_COLORS[itemData.quality]
                if c then
                    button.itemLevelText:SetTextColor(c[1], c[2], c[3], 1)
                else
                    button.itemLevelText:SetTextColor(1, 1, 1, 1)
                end
                button.itemLevelText:Show()
            else
                button.itemLevelText:Hide()
            end
        end

        -- Charges display (Wizard Oil, Sharpening Stones, etc.)
        ns:ProfileStart("si.charges")
        if button.chargesText then
            local charges = nil
            if settings.showCharges and not isReadOnly then
                local TooltipScanner = ns:GetModule("TooltipScanner")
                if TooltipScanner then
                    charges = TooltipScanner:GetCharges(itemData.bagID, itemData.slot)
                end
            end
            if charges and charges > 0 then
                button.chargesText:SetText("x" .. charges)
                button.chargesText:Show()
            else
                button.chargesText:Hide()
            end
        end
        ns:ProfileStop("si.charges")

        -- BoE label (bottom-left corner). Only on unbound BoE weapons/armor;
        -- TooltipScanner:IsBindOnEquip excludes soulbound, BoP, and non-gear.
        -- The itemType pre-check skips the tooltip scan for the common case
        -- (consumables, reagents, etc.) so this stays cheap.
        ns:ProfileStart("si.boe")
        if button.boeText then
            local showBoe = settings.showBoeLabel
                and not isReadOnly
                and (itemData.itemType == "Weapon" or itemData.itemType == "Armor")
                and (itemData.quality or 0) > 0
                and itemData.bagID and itemData.slot
            if showBoe then
                local TooltipScanner = ns:GetModule("TooltipScanner")
                if TooltipScanner and TooltipScanner:IsBindOnEquip(itemData.bagID, itemData.slot, itemData) then
                    local c = Constants.QUALITY_COLORS[itemData.quality]
                    if c then
                        button.boeText:SetTextColor(c[1], c[2], c[3], 1)
                    else
                        button.boeText:SetTextColor(1, 1, 1, 1)
                    end
                    button.boeText:Show()
                else
                    button.boeText:Hide()
                end
            else
                button.boeText:Hide()
            end
        end
        ns:ProfileStop("si.boe")

        -- Upgrade arrow: Pawn (preferred) or SimpleItemLevel, when installed.
        -- Invisible without either addon. See ApplyUpgradeArrow above.
        ns:ProfileStart("si.upgrade")
        ApplyUpgradeArrow(button)
        ns:ProfileStop("si.upgrade")

        -- Pin icon (bottom-right corner)
        ItemButton:UpdatePinIcon(button)

        -- User lock icon (bottom-right corner)
        ItemButton:UpdateUserLockIcon(button)
    else
        button.wrapper:SetID(0)
        button:SetID(0)

        SetItemButtonTexture(button, nil)
        SetItemButtonCount(button, 0)
        if button.icon then button.icon:SetVertexColor(1, 1, 1, 1) end
        button.border:Hide()
        if button.innerShadow then
            for _, tex in pairs(button.innerShadow) do tex:Hide() end
        end
        button.lockOverlay:Hide()
        button.unusableOverlay:Hide()
        if button.junkOverlay then
            button.junkOverlay:Hide()
        end
        if button.junkIcon then
            button.junkIcon:Hide()
        end
        if button.questIcon then
            button.questIcon:Hide()
        end
        if button.questStarterIcon then
            button.questStarterIcon:Hide()
        end
        if button.trackedIcon then
            button.trackedIcon:Hide()
        end
        if button.trackedIconShadow then
            button.trackedIconShadow:Hide()
        end
        if button.equipSetIcon then
            button.equipSetIcon:Hide()
        end
        if button.equipSetIconShadow then
            button.equipSetIconShadow:Hide()
        end
        if button.itemLevelText then
            button.itemLevelText:Hide()
        end
        if button.chargesText then
            button.chargesText:Hide()
        end
        if button.boeText then
            button.boeText:Hide()
        end
        if button.upgradeArrow then
            button.upgradeArrow:Hide()
        end
        if button.userLockIcon then
            button.userLockIcon:Hide()
        end
        if button.userLockIconStroke then
            button.userLockIconStroke:Hide()
        end
        if button.cooldown then
            CooldownFrame_Set(button.cooldown, 0, 0, false)
        end
    end

    -- If the tooltip is currently hovering over this button, the user just saw
    -- the OLD item's tooltip. Re-run our OnEnter so they see the NEW item
    -- without having to move the mouse off and back on. (Blizzard's stock
    -- ContainerFrameItemButton_OnUpdate does this automatically, but our
    -- custom OnUpdate only listens for shift-key changes.) Combat-gated to
    -- match Blizzard's stock pattern.
    --
    -- Skip the replay while an item is on the cursor: our OnEnter calls
    -- Blizzard's ContainerFrameItemButton_OnEnter -> CursorUpdate, which
    -- desaturates a slot when the held cursor item can't drop there. During a
    -- right-click equip-swap WoW briefly parks the swapped item on the cursor
    -- (see UI/BagFrame.lua), so replaying OnEnter then would leave the slot
    -- greyed until the next mouse-over. Our custom OnUpdate never re-saturates
    -- it. Replaying only with an empty cursor is safe and still refreshes the
    -- tooltip.
    if GameTooltip:IsOwned(button) and not InCombatLockdown() and not GetCursorInfo() then
        local onEnter = button:GetScript("OnEnter")
        if onEnter then onEnter(button) end
    end

    -- Fire the public hook so third-party addons (e.g. SimpleItemLevel) can
    -- decorate this button. Only for real items in a real bag/slot — skip
    -- pseudo-items, cached/read-only views, and guild-bank synthetic IDs.
    if not isReadOnly
        and itemData and itemData.bagID and itemData.slot
        and not itemData.isGuildBank
        and not itemData.isEmptySlots
        and not itemData.isDropTarget then
        ns:FireItemButtonUpdate(button, itemData.bagID, itemData.slot)
    end
end

function ItemButton:UpdatePinIcon(button)
    if not button.pinIcon then return end
    -- Pin icons require GudaBags sort on Retail
    if ns.IsRetail and not ns:GetModule("Database"):GetSetting("gudaSort") then
        button.pinIcon:Hide()
        if button.pinIconShadow then button.pinIconShadow:Hide() end
        return
    end
    local itemData = button.itemData
    if itemData and itemData.bagID ~= nil and itemData.slot and not button.isReadOnly then
        local Database = ns:GetModule("Database")
        if Database:IsPinnedSlot(itemData.bagID, itemData.slot) then
            button.pinIcon:Show()
            if button.pinIconShadow then button.pinIconShadow:Show() end
            -- Hide category mark icon (pin takes priority in same corner)
            if button.equipSetIcon then button.equipSetIcon:Hide() end
            if button.equipSetIconShadow then button.equipSetIconShadow:Hide() end
            return
        end
    end
    button.pinIcon:Hide()
    if button.pinIconShadow then button.pinIconShadow:Hide() end
end

function ItemButton:UpdateUserLockIcon(button)
    if not button.userLockIcon then return end
    local itemData = button.itemData
    if itemData and itemData.itemID and not button.isReadOnly then
        local Database = ns:GetModule("Database")
        if Database:IsItemLocked(itemData.itemID) then
            button.userLockIcon:Show()
            if button.userLockIconStroke then button.userLockIconStroke:Show() end
            UpdateMerchantOverlay(button)
            UpdateSpellOverlay(button)
            return
        end
        if Database:GetSetting("autoLockSetItems") then
            local EquipSets = ns:GetModule("EquipmentSets")
            if EquipSets and EquipSets:IsInSet(itemData.itemID)
               and not Database:IsSetProtectionException(itemData.itemID) then
                button.userLockIcon:Show()
                if button.userLockIconStroke then button.userLockIconStroke:Show() end
                UpdateMerchantOverlay(button)
                UpdateSpellOverlay(button)
                return
            end
        end
    end
    button.userLockIcon:Hide()
    if button.userLockIconStroke then button.userLockIconStroke:Hide() end
    UpdateMerchantOverlay(button)
    UpdateSpellOverlay(button)
end

function ItemButton:SetEmpty(button, bagID, slot, size, isReadOnly, isGuildBank)
    ns:ProfileBump("SetEmpty.calls")
    -- Hide Blizzard template's built-in textures (they may re-show from events)
    if button.IconBorder then button.IconBorder:Hide() end
    if button.IconOverlay then button.IconOverlay:Hide() end
    if button.NewItemTexture then button.NewItemTexture:Hide() end
    if button.BattlepayItemTexture then button.BattlepayItemTexture:Hide() end
    -- Don't hide NormalTexture when Masque is active — Masque manages it
    -- Exception: always hide on minimal empty slots (no Masque chrome on empties)
    local MasqueModule = ns:GetModule("Masque")
    local masqueActive = MasqueModule and MasqueModule:IsActive()
    if not masqueActive or Database:GetSetting("minimalEmptySlots") then
        local normalTex = button:GetNormalTexture()
        if normalTex then normalTex:Hide() end
    end

    button.itemData = {bagID = bagID, slot = slot, isGuildBank = isGuildBank or false}
    button.isReadOnly = isReadOnly or false

    -- Set IDs for ContainerFrameItemButtonTemplate's secure click handler
    -- Use invalid IDs for read-only mode or guild bank items to prevent template from
    -- interfering (guild bank items are handled by our own OnClick hook)
    -- Skip during combat to avoid taint
    if not InCombatLockdown() then
        if isReadOnly or isGuildBank then
            -- Set to 0 for read-only mode or guild bank items
            button.wrapper:SetID(0)
            button:SetID(0)
        else
            button.wrapper:SetID(bagID)
            button:SetID(slot)
        end
    end

    local settings = GetCachedSettings()
    size = size or settings.iconSize

    EnsureButtonSize(button, size)

    -- Register with Masque after sizing (deferred from Acquire to avoid icon anchor issues)
    ApplyMasqueAfterSizing(button)

    button.slotBackground:SetVertexColor(0.5, 0.5, 0.5, settings.bgAlpha)

    SetItemButtonTexture(button, nil)
    SetItemButtonCount(button, 0)
    button.border:Hide()
    if button.innerShadow then
        for _, tex in pairs(button.innerShadow) do tex:Hide() end
    end
    button.lockOverlay:Hide()
    button.unusableOverlay:Hide()
    if button.junkOverlay then
        button.junkOverlay:Hide()
    end
    if button.junkIcon then
        button.junkIcon:Hide()
    end
    if button.questIcon then
        button.questIcon:Hide()
    end
    if button.questStarterIcon then
        button.questStarterIcon:Hide()
    end
    if button.trackedIcon then
        button.trackedIcon:Hide()
    end
    if button.trackedIconShadow then
        button.trackedIconShadow:Hide()
    end
    if button.equipSetIcon then
        button.equipSetIcon:Hide()
    end
    if button.equipSetIconShadow then
        button.equipSetIconShadow:Hide()
    end
    if button.craftingQualityIcon then
        button.craftingQualityIcon:Hide()
    end
    if button.itemLevelText then
        button.itemLevelText:Hide()
    end
    if button.chargesText then
        button.chargesText:Hide()
    end
    if button.boeText then
        button.boeText:Hide()
    end
    if button.upgradeArrow then
        button.upgradeArrow:Hide()
    end
    if button.userLockIcon then
        button.userLockIcon:Hide()
    end
    if button.userLockIconStroke then
        button.userLockIconStroke:Hide()
    end
    if button.cooldown then
        CooldownFrame_Set(button.cooldown, 0, 0, false)
    end

    -- Show pin icon for empty pinned slots
    ItemButton:UpdatePinIcon(button)
end

function ItemButton:UpdateSlotAlpha(alpha)
    if not buttonPool then return end
    for button in buttonPool:EnumerateActive() do
        if button.slotBackground then
            button.slotBackground:SetVertexColor(0.5, 0.5, 0.5, alpha)
        end
    end
end

function ItemButton:UpdateFontSize()
    if not buttonPool then return end
    for button in buttonPool:EnumerateActive() do
        ApplyFontSize(button)
    end
end

function ItemButton:ApplyThemeTextures()
    local slotTex = GetEffectiveSlotTextures()
    if not buttonPool then return end
    for button in buttonPool:EnumerateActive() do
        ApplyThemeToButton(button, slotTex)
    end
end

function ItemButton:GetActiveButtons()
    -- Return iterator for active buttons
    if not buttonPool then return function() end end
    return buttonPool:EnumerateActive()
end

function ItemButton:HighlightBagSlots(bagID, owner)
    if not buttonPool then return end
    local bgAlpha = Database:GetSetting("bgAlpha") / 100

    for button in buttonPool:EnumerateActive() do
        -- Only affect buttons belonging to the specified owner (if provided)
        if owner and button.owner ~= owner then
            -- Skip buttons from other frames
        elseif button.itemData and button.itemData.bagID == bagID then
            button:SetAlpha(1.0)
            if button.searchGlow then button.searchGlow:Hide() end
            SetItemButtonDesaturated(button, button.itemData.locked or false)
            if button.slotBackground then
                button.slotBackground:SetVertexColor(0.5, 0.5, 0.5, bgAlpha)
            end
        else
            button:SetAlpha(0.25)
            if button.searchGlow then button.searchGlow:Hide() end
            SetItemButtonDesaturated(button, true)
            if button.slotBackground then
                button.slotBackground:SetVertexColor(0.5, 0.5, 0.5, bgAlpha * 0.25)
            end
        end
    end
end

function ItemButton:ClearHighlightedSlots(parentFrame)
    if not buttonPool then return end
    local SearchBar = ns:GetModule("SearchBar")
    local hasSearch = (SearchBar and parentFrame) and SearchBar:HasActiveFilters(parentFrame) or false
    local bgAlpha = Database:GetSetting("bgAlpha") / 100

    for button in buttonPool:EnumerateActive() do
        if hasSearch then
            -- Respect search filter with spotlight effect
            local isMatch = button.itemData and SearchBar:ItemMatchesFilters(parentFrame, button.itemData)
            ItemButton:SetSearchState(button, isMatch)
            if button.slotBackground then
                button.slotBackground:SetVertexColor(0.5, 0.5, 0.5, isMatch and bgAlpha or bgAlpha * 0.4)
            end
        else
            ItemButton:ClearSearchState(button)
            if button.slotBackground then
                button.slotBackground:SetVertexColor(0.5, 0.5, 0.5, bgAlpha)
            end
        end
    end
end

-- Spotlight search: WeakAuras-style "shooting star" orbit.
-- Static sunny-gold border + N bright streaks racing around the perimeter,
-- each followed by a dimmer trailing echo for the "falling star" effect.
-- Pure Lua, no Blizzard overlay textures — portable across all expansions.
local STREAK_COUNT   = 4       -- bright streaks evenly spaced around the loop
local STREAK_PERIOD  = 3.2     -- seconds per full lap
local STREAK_SIZE    = 4       -- px (primary)
local TRAIL_PER_STREAK = 2     -- dim echoes behind each bright streak
local TRAIL_PHASE_STEP = 0.035 -- phase spacing between echoes
local ORBIT_INSET    = 7       -- px inset of orbit path from glow frame edge
                               --   (glow frame is +3 outside the button, so with
                               --   inset 7 the streaks ride ~4px inside the icon)
local ROUND_MASK     = "Interface\\CharacterFrame\\TempPortraitAlphaMask"

-- Advance streaks along the perimeter based on frame delta. Called from
-- each glow's OnUpdate handler while visible. Orbit path is inset from the
-- glow frame so the streaks ride inside the icon edge.
local function UpdateOrbitStreaks(glow, elapsed)
    glow.orbitPhase = ((glow.orbitPhase or 0) + elapsed / STREAK_PERIOD) % 1
    local fw, fh = glow:GetSize()
    local w, h = fw - 2 * ORBIT_INSET, fh - 2 * ORBIT_INSET
    if w <= 0 or h <= 0 then return end
    local perim = 2 * (w + h)
    local phase = glow.orbitPhase
    for _, streak in ipairs(glow.streaks) do
        local p = (phase + streak.phaseOffset) % 1
        local d = p * perim
        local x, y
        if d < w then
            x, y = d, 0
        elseif d < w + h then
            x, y = w, -(d - w)
        elseif d < 2 * w + h then
            x, y = w - (d - w - h), -h
        else
            x, y = 0, -(perim - d)
        end
        streak:SetPoint("CENTER", glow, "TOPLEFT", ORBIT_INSET + x, -ORBIT_INSET + y)
    end
end

local function EnsureSearchGlow(button)
    if button.searchGlow then return button.searchGlow end

    local glow = CreateFrame("Frame", nil, button, "BackdropTemplate")
    glow:SetPoint("TOPLEFT", button, "TOPLEFT", -3, 3)
    glow:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 3, -3)
    glow:SetFrameLevel(button:GetFrameLevel() + Constants.FRAME_LEVELS.BORDER + 1)

    -- Static sunny-gold border (matches image reference)
    glow:SetBackdrop({
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 10,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    glow:SetBackdropBorderColor(1.0, 0.85, 0.2, 0.95)

    -- Bright streaks + dimmer trailing echoes. Echoes are positioned behind
    -- each bright streak by multiples of TRAIL_PHASE_STEP (smaller phase =
    -- further back along the travel direction).
    glow.streaks = {}
    for i = 1, STREAK_COUNT do
        local basePhase = (i - 1) / STREAK_COUNT

        -- Primary bright streak (round via circular alpha mask)
        local primary = glow:CreateTexture(nil, "OVERLAY")
        primary:SetSize(STREAK_SIZE, STREAK_SIZE)
        primary:SetTexture("Interface\\Buttons\\WHITE8x8")
        if primary.SetMask then primary:SetMask(ROUND_MASK) end
        primary:SetVertexColor(1.0, 0.95, 0.45, 1.0)
        primary:SetBlendMode("ADD")
        primary:SetPoint("CENTER", glow, "TOPLEFT", 0, 0)
        primary.phaseOffset = basePhase
        glow.streaks[#glow.streaks + 1] = primary

        -- Trailing echoes (dimmer, smaller, also rounded)
        for t = 1, TRAIL_PER_STREAK do
            local trail = glow:CreateTexture(nil, "OVERLAY")
            local size = math.max(2, STREAK_SIZE - t)  -- 3, 2, 2...
            trail:SetSize(size, size)
            trail:SetTexture("Interface\\Buttons\\WHITE8x8")
            if trail.SetMask then trail:SetMask(ROUND_MASK) end
            trail:SetVertexColor(1.0, 0.85, 0.2, 1.0)
            trail:SetBlendMode("ADD")
            trail:SetAlpha(0.65 - t * 0.18)       -- 0.47, 0.29, 0.11
            trail:SetPoint("CENTER", glow, "TOPLEFT", 0, 0)
            trail.phaseOffset = (basePhase - t * TRAIL_PHASE_STEP) % 1
            glow.streaks[#glow.streaks + 1] = trail
        end
    end

    glow:SetScript("OnUpdate", UpdateOrbitStreaks)
    glow:SetScript("OnShow", function(self) self.orbitPhase = 0 end)
    glow:Hide()

    button.searchGlow = glow
    return glow
end

local function StartSearchGlow(button)
    local glow = button.searchGlow
    if glow then glow:Show() end
end

local function StopSearchGlow(button)
    local glow = button.searchGlow
    if glow then glow:Hide() end
end

-- Apply spotlight search visual state to a single button
function ItemButton:SetSearchState(button, isMatch)
    if isMatch then
        -- Matching item: full visibility + Blizzard proc glow (WA "Proc Glow" equiv.)
        button:SetAlpha(1)
        SetItemButtonDesaturated(button, button.itemData and button.itemData.locked or false)
        EnsureSearchGlow(button)
        StartSearchGlow(button)
    else
        -- Non-matching item: desaturated + dimmed
        button:SetAlpha(0.4)
        SetItemButtonDesaturated(button, true)
        if button.searchGlow then
            StopSearchGlow(button)
        end
    end
end

-- Clear spotlight search visual state from a single button
function ItemButton:ClearSearchState(button)
    button:SetAlpha(1)
    SetItemButtonDesaturated(button, button.itemData and button.itemData.locked or false)
    if button.searchGlow then
        StopSearchGlow(button)
    end
end

-- Reset all button alphas unconditionally (no search filter check)
-- If owner is specified, only reset buttons belonging to that owner
function ItemButton:ResetAllAlpha(owner)
    if not buttonPool then return end
    local bgAlpha = Database:GetSetting("bgAlpha") / 100

    for button in buttonPool:EnumerateActive() do
        -- Only affect buttons belonging to the specified owner (if provided)
        if not owner or button.owner == owner then
            ItemButton:ClearSearchState(button)
            if button.slotBackground then
                button.slotBackground:SetVertexColor(0.5, 0.5, 0.5, bgAlpha)
            end
        end
    end
end

--- Re-sync frame levels for all active buttons owned by the given container.
--- Call after changing a container's frame level (e.g. raise/lower on click).
function ItemButton:SyncFrameLevels(owner)
    if not buttonPool then return end
    local ownerLvl = owner and owner:GetFrameLevel() or 0
    for button in buttonPool:EnumerateActive() do
        if not owner or button.owner == owner then
            -- Update wrapper level first (wrapper is parented to owner container)
            if button.wrapper then
                button.wrapper:SetFrameLevel(ownerLvl + 1)
            end
            local btnLvl = ownerLvl + 1 + Constants.FRAME_LEVELS.BUTTON
            button:SetFrameLevel(btnLvl)
            if button.border then button.border:SetFrameLevel(btnLvl + Constants.FRAME_LEVELS.BORDER) end
            if button.cooldown then button.cooldown:SetFrameLevel(btnLvl + Constants.FRAME_LEVELS.COOLDOWN) end
            if button.questStarterIcon then button.questStarterIcon:SetFrameLevel(btnLvl + Constants.FRAME_LEVELS.QUEST_ICON) end
            if button.questIcon then button.questIcon:SetFrameLevel(btnLvl + Constants.FRAME_LEVELS.QUEST_ICON) end
            if button.userLockFrame then button.userLockFrame:SetFrameLevel(btnLvl + Constants.FRAME_LEVELS.BORDER + 2) end
            if button.craftingQualityFrame then button.craftingQualityFrame:SetFrameLevel(btnLvl + Constants.FRAME_LEVELS.BORDER + 1) end
        end
    end
end

-- Update lock state for a specific item (called on ITEM_LOCK_CHANGED)
function ItemButton:UpdateLockForItem(bagID, slotID)
    if not buttonPool then return end

    for button in buttonPool:EnumerateActive() do
        if button.itemData and button.itemData.bagID == bagID and button.itemData.slot == slotID then
            local itemInfo = C_Container.GetContainerItemInfo(bagID, slotID)
            local isLocked = itemInfo and itemInfo.isLocked or false

            -- Update cached state
            button.itemData.locked = isLocked

            -- Update visual state
            if isLocked then
                button.lockOverlay:Show()
                SetItemButtonDesaturated(button, true)
            else
                button.lockOverlay:Hide()
                SetItemButtonDesaturated(button, false)
            end

            -- Refresh user lock icon using live API data (itemData may be stale)
            if itemInfo and itemInfo.itemID and IsItemProtected(itemInfo.itemID) then
                if button.userLockIcon then button.userLockIcon:Show() end
                if button.userLockIconStroke then button.userLockIconStroke:Show() end
            else
                if button.userLockIcon then button.userLockIcon:Hide() end
                if button.userLockIconStroke then button.userLockIconStroke:Hide() end
            end
            return  -- Found the button, done
        end
    end
end

-- Re-evaluate just the upgrade arrow on every active button. Called by the
-- Pawn compat module when its data resolves or is invalidated (spec/scale/gear
-- change) -- far cheaper than a full bag refresh and avoids flicker.
function ItemButton:RefreshUpgradeArrows()
    if not buttonPool then return end
    for button in buttonPool:EnumerateActive() do
        if button.upgradeArrow and button.itemData then
            ApplyUpgradeArrow(button)
        end
    end
end

-- Update cooldowns on all active buttons when BAG_UPDATE_COOLDOWN fires
-- Without this, cooldowns (e.g. Hearthstone) only update during full bag refresh
local Events = ns:GetModule("Events")
if Events then
    Events:Register("BAG_UPDATE_COOLDOWN", function()
        if not buttonPool then return end
        for button in buttonPool:EnumerateActive() do
            if button.cooldown and button.itemData and button.itemData.bagID and button.itemData.slot
                and not button.isReadOnly and not button.isEmptySlotButton and not button.isDropTargetButton
                and not (button.itemData.isEmptySlots) then
                local start, duration, enable = C_Container.GetContainerItemCooldown(button.itemData.bagID, button.itemData.slot)
                if start and duration and enable and enable > 0 and duration > 0 and not IsGlobalCooldown(start, duration) then
                    CooldownFrame_Set(button.cooldown, start, duration, true)
                else
                    CooldownFrame_Set(button.cooldown, 0, 0, false)
                end
            end
        end
    end, ItemButton)
end

-- Invalidate settings cache when relevant settings change
if Events then
    Events:Register("SETTING_CHANGED", function(event, key, value)
        -- Invalidate cache for any setting that affects item buttons
        if key == "iconSize" or key == "bgAlpha" or key == "iconFontSize"
            or key == "grayoutJunk" or key == "equipmentBorders"
            or key == "otherBorders" or key == "markUnusableItems"
            or key == "markEquipmentSets"
            or key == "showItemLevel" or key == "showCharges"
            or key == "showBoeLabel" then
            ItemButton:InvalidateSettingsCache()
        end
    end, ItemButton)

    Events:Register("PROFILE_LOADED", function()
        cachedSettings = nil
    end, ItemButton)
end

-- Debug: Get pool statistics
function ItemButton:GetPoolStats()
    if not buttonPool then
        return { active = 0, inactive = 0 }
    end

    local active = buttonPool:GetNumActive() or 0
    local inactive = 0

    -- Count inactive objects if available
    if buttonPool.EnumerateInactive then
        for _ in buttonPool:EnumerateInactive() do
            inactive = inactive + 1
        end
    end

    return {
        active = active,
        inactive = inactive,
        total = active + inactive,
    }
end
