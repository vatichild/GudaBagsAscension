local addonName, ns = ...

local Footer = {}
ns:RegisterModule("Footer", Footer)

local Constants = ns.Constants

local Database = ns:GetModule("Database")

local frame = nil
local backButton = nil
local onBackCallback = nil

-- Footer components (loaded after registration)
local BagSlots = nil
local Keyring = nil
local SoulBag = nil
local QuiverBag = nil
local Money = nil
local Currency = nil

local function LoadComponents()
    BagSlots = ns:GetModule("Footer.BagSlots")
    Keyring = ns:GetModule("Footer.Keyring")
    SoulBag = ns:GetModule("Footer.SoulBag")
    QuiverBag = ns:GetModule("Footer.QuiverBag")
    Money = ns:GetModule("Footer.Money")
    Currency = ns:GetModule("Footer.Currency")
end

function Footer:Init(parent)
    LoadComponents()

    -- Clean up any ghost hearthstone frames from previous versions
    local ghostWrapper = _G["GudaBagsHearthstoneWrapper"]
    if ghostWrapper then
        ghostWrapper:Hide()
        ghostWrapper:EnableMouse(false)
        ghostWrapper:SetAlpha(0)
        ghostWrapper:SetSize(1, 1)
        ghostWrapper:ClearAllPoints()
        ghostWrapper:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", -1000, -1000)
        ghostWrapper:UnregisterAllEvents()
    end
    local ghostButton = _G["GudaBagsHearthstoneButton"]
    if ghostButton then
        ghostButton:Hide()
        ghostButton:EnableMouse(false)
        ghostButton:SetAlpha(0)
        ghostButton:SetSize(1, 1)
        ghostButton:ClearAllPoints()
        ghostButton:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", -1000, -1000)
        ghostButton:UnregisterAllEvents()
        if ghostButton.SetAttribute then
            ghostButton:SetAttribute("type", nil)
            ghostButton:SetAttribute("item", nil)
        end
    end

    frame = CreateFrame("Frame", "GudaBagsFooter", parent)
    frame:SetHeight(Constants.FRAME.FOOTER_HEIGHT)
    frame:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", Constants.FRAME.PADDING, Constants.FRAME.PADDING - 5)
    frame:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -Constants.FRAME.PADDING, Constants.FRAME.PADDING - 5)
    frame:EnableMouse(true)  -- Capture stray clicks to prevent click-through

    -- Initialize components
    frame.bagSlotsFrame = BagSlots:Init(frame)

    -- Initialize soul bag toggle (Warlock only - returns nil for other classes)
    frame.soulBagButton = SoulBag:Init(frame)
    local soulBagButton = SoulBag:GetButton()

    -- Initialize quiver/ammo bag toggle (Hunter Classic/TBC only - returns nil otherwise)
    frame.quiverBagButton = QuiverBag:Init(frame)
    local quiverBagButton = QuiverBag:GetButton()

    -- Initialize keyring (TBC only - returns nil for other expansions)
    frame.keyringButton = Keyring:Init(frame)
    local keyringButton = Keyring:GetButton()

    -- Slot counter after keyring, soul bag, quiver bag, or bag slots (with tooltip frame for hover)
    local slotInfoFrame = CreateFrame("Button", nil, frame)
    slotInfoFrame:EnableMouse(true)
    -- Anchor to rightmost special button available - NO GAP to prevent click-through
    if keyringButton then
        slotInfoFrame:SetPoint("LEFT", keyringButton, "RIGHT", 0, 0)
    elseif quiverBagButton then
        slotInfoFrame:SetPoint("LEFT", quiverBagButton, "RIGHT", 0, 0)
    elseif soulBagButton then
        slotInfoFrame:SetPoint("LEFT", soulBagButton, "RIGHT", 0, 0)
    else
        slotInfoFrame:SetPoint("LEFT", BagSlots:GetAnchor(), "RIGHT", 0, 0)
    end
    slotInfoFrame:SetSize(78, 20)  -- Includes 8px padding on left
    -- Capture clicks to prevent propagation
    slotInfoFrame:SetScript("OnClick", function() end)

    local slotInfo = slotInfoFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    slotInfo:SetPoint("LEFT", slotInfoFrame, "LEFT", 8, 0)  -- 8px visual padding from keyring
    slotInfo:SetTextColor(0.8, 0.8, 0.8)
    slotInfo:SetShadowOffset(1, -1)
    slotInfo:SetShadowColor(0, 0, 0, 1)
    frame.slotInfo = slotInfo
    frame.slotInfoFrame = slotInfoFrame

    -- Store special bags data for tooltip
    frame.specialBagsData = nil

    -- Tooltip on hover
    slotInfoFrame:SetScript("OnEnter", function(self)
        if frame.specialBagsData and next(frame.specialBagsData) then
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine("Bag Slots", 1, 1, 1)
            GameTooltip:AddLine(" ")

            -- Show regular bags info
            if frame.regularTotal then
                local regularUsed = frame.regularTotal - (frame.regularFree or 0)
                GameTooltip:AddDoubleLine("Regular Bags:", string.format("%d/%d", regularUsed, frame.regularTotal), 1, 1, 1, 0.8, 0.8, 0.8)
            end

            -- Show special bags
            for bagType, data in pairs(frame.specialBagsData) do
                local used = data.total - data.free
                GameTooltip:AddDoubleLine(bagType .. ":", string.format("%d/%d", used, data.total), 1, 0.82, 0, 0.8, 0.8, 0.8)
            end

            GameTooltip:Show()
        end
    end)
    slotInfoFrame:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    frame.moneyFrame = Money:Init(frame)

    frame.currencyFrame = Currency:Init(frame)
    if frame.currencyFrame then
        frame.currencyFrame:SetPoint("RIGHT", frame.moneyFrame, "LEFT", -8, 0)
    end

    -- Create back button (hidden by default, shown when viewing cached)
    backButton = CreateFrame("Button", "GudaBagsBackButton", frame)
    backButton:SetSize(60, 18)
    backButton:SetPoint("LEFT", frame, "LEFT", 0, 0)

    local backText = backButton:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    backText:SetPoint("LEFT", backButton, "LEFT", 0, 0)
    backText:SetText("<< Back")
    backText:SetTextColor(0.6, 0.8, 1)
    backButton.text = backText

    backButton:SetScript("OnEnter", function(self)
        self.text:SetTextColor(1, 1, 1)
    end)
    backButton:SetScript("OnLeave", function(self)
        self.text:SetTextColor(0.6, 0.8, 1)
    end)
    backButton:SetScript("OnClick", function()
        if onBackCallback then
            onBackCallback()
        end
    end)
    backButton:Hide()

    return frame
end

function Footer:Show()
    if not frame then return end
    frame:Show()

    -- Hide back button (only for cached views)
    if backButton then
        backButton:Hide()
    end

    -- Reset viewing character to current character
    BagSlots:SetViewingCharacter(nil)

    -- Show bag slots and get anchor
    BagSlots:Show()
    local bagAnchor = BagSlots:GetAnchor()
    local lastAnchor = bagAnchor

    -- Position soul bag relative to bag slots (Warlock only, single view only)
    local soulBagButton = SoulBag:GetButton()
    if soulBagButton then
        local viewType = Database:GetSetting("bagViewType") or "single"
        if viewType == "single" then
            SoulBag:SetAnchor(lastAnchor)
            SoulBag:Show()
            lastAnchor = soulBagButton
        else
            SoulBag:Hide()
        end
    end

    -- Position quiver/ammo bag relative to bag slots (Hunter Classic/TBC only)
    local quiverBagButton = QuiverBag:GetButton()
    if quiverBagButton then
        local viewType = Database:GetSetting("bagViewType") or "single"
        if viewType == "single" then
            QuiverBag:SetAnchor(lastAnchor)
            QuiverBag:Show()
            lastAnchor = quiverBagButton
        else
            QuiverBag:Hide()
        end
    end

    -- Position keyring relative to soul/quiver bag or bag slots (TBC only)
    local keyringButton = Keyring:GetButton()
    if keyringButton then
        Keyring:SetAnchor(lastAnchor)
        Keyring:Show()
        lastAnchor = keyringButton
    end

    -- Position slot counter where hearthstone used to be
    if frame.slotInfoFrame then
        frame.slotInfoFrame:ClearAllPoints()
        frame.slotInfoFrame:SetPoint("LEFT", lastAnchor, "RIGHT", 0, 0)
    end

    -- Show money and currency
    Money:Show()
    Currency:Show()

    self:Update()
end

function Footer:Hide()
    if not frame then return end
    frame:Hide()

    BagSlots:Hide()
    if Keyring:GetButton() then
        Keyring:Hide()
    end
    if SoulBag:GetButton() then
        SoulBag:Hide()
    end
    if QuiverBag:GetButton() then
        QuiverBag:Hide()
    end
    Money:Hide()
    Currency:Hide()
    if backButton then
        backButton:Hide()
    end
end

function Footer:Update()
    if not frame then return end

    BagSlots:Update()
    Money:Update()
    Currency:Update()
    if Keyring:GetButton() then
        Keyring:UpdateState()
    end

    -- Update soul bag visibility based on view type
    local soulBagButton = SoulBag:GetButton()
    if soulBagButton then
        local viewType = Database:GetSetting("bagViewType") or "single"
        local bagAnchor = BagSlots:GetAnchor()
        local keyringButton = Keyring:GetButton()

        if viewType == "single" or viewType == "category" then
            -- Show soul bag and reposition chain
            SoulBag:SetAnchor(bagAnchor)
            SoulBag:Show()
            SoulBag:UpdateState()
            if keyringButton then
                Keyring:SetAnchor(soulBagButton)
                -- Position slot counter after keyring
                if frame.slotInfoFrame then
                    frame.slotInfoFrame:ClearAllPoints()
                    frame.slotInfoFrame:SetPoint("LEFT", keyringButton, "RIGHT", 0, 0)
                end
            else
                -- Position slot counter after soul bag
                if frame.slotInfoFrame then
                    frame.slotInfoFrame:ClearAllPoints()
                    frame.slotInfoFrame:SetPoint("LEFT", soulBagButton, "RIGHT", 0, 0)
                end
            end
        else
            -- Hide soul bag and reposition chain
            SoulBag:Hide()
            if keyringButton then
                Keyring:SetAnchor(bagAnchor)
                -- Position slot counter after keyring
                if frame.slotInfoFrame then
                    frame.slotInfoFrame:ClearAllPoints()
                    frame.slotInfoFrame:SetPoint("LEFT", keyringButton, "RIGHT", 0, 0)
                end
            else
                -- Position slot counter after bag slots
                if frame.slotInfoFrame then
                    frame.slotInfoFrame:ClearAllPoints()
                    frame.slotInfoFrame:SetPoint("LEFT", bagAnchor, "RIGHT", 0, 0)
                end
            end
        end
    end

    -- Update quiver/ammo bag visibility based on view type
    -- (Hunter and Warlock are mutually exclusive, so this block runs only for Hunters)
    local quiverBagButton = QuiverBag:GetButton()
    if quiverBagButton then
        local viewType = Database:GetSetting("bagViewType") or "single"
        local bagAnchor = BagSlots:GetAnchor()
        local keyringButton = Keyring:GetButton()

        if viewType == "single" or viewType == "category" then
            QuiverBag:SetAnchor(bagAnchor)
            QuiverBag:Show()
            QuiverBag:UpdateState()
            if keyringButton then
                Keyring:SetAnchor(quiverBagButton)
                if frame.slotInfoFrame then
                    frame.slotInfoFrame:ClearAllPoints()
                    frame.slotInfoFrame:SetPoint("LEFT", keyringButton, "RIGHT", 0, 0)
                end
            else
                if frame.slotInfoFrame then
                    frame.slotInfoFrame:ClearAllPoints()
                    frame.slotInfoFrame:SetPoint("LEFT", quiverBagButton, "RIGHT", 0, 0)
                end
            end
        else
            QuiverBag:Hide()
            if keyringButton then
                Keyring:SetAnchor(bagAnchor)
                if frame.slotInfoFrame then
                    frame.slotInfoFrame:ClearAllPoints()
                    frame.slotInfoFrame:SetPoint("LEFT", keyringButton, "RIGHT", 0, 0)
                end
            else
                if frame.slotInfoFrame then
                    frame.slotInfoFrame:ClearAllPoints()
                    frame.slotInfoFrame:SetPoint("LEFT", bagAnchor, "RIGHT", 0, 0)
                end
            end
        end
    end
end

function Footer:UpdateBagSlots()
    if BagSlots then
        BagSlots:Update()
    end
end

function Footer:UpdateMoney()
    if Money then
        Money:Update()
    end
end

function Footer:UpdateSlotInfo(used, total, regularTotal, regularFree, specialBags)
    if not frame or not frame.slotInfo then return end

    -- If detailed data provided, show only regular bags and store special for tooltip
    if regularTotal then
        local regularUsed = regularTotal - (regularFree or 0)
        frame.slotInfo:SetText(string.format("%d/%d", regularUsed, regularTotal))
        frame.regularTotal = regularTotal
        frame.regularFree = regularFree
        frame.specialBagsData = specialBags
    else
        -- Fallback to simple display
        frame.slotInfo:SetText(string.format("%d/%d", used, total))
        frame.regularTotal = total
        frame.regularFree = total - used
        frame.specialBagsData = nil
    end
end

function Footer:UpdateKeyringState()
    if Keyring then
        Keyring:UpdateState()
    end
end

function Footer:SetKeyringCallback(callback)
    if Keyring then
        Keyring:SetCallback(callback)
    end
end

function Footer:IsKeyringVisible()
    if Keyring then
        return Keyring:IsVisible()
    end
    return false
end

function Footer:SetSoulBagCallback(callback)
    if SoulBag then
        SoulBag:SetCallback(callback)
    end
end

function Footer:IsSoulBagVisible()
    if SoulBag then
        return SoulBag:IsVisible()
    end
    return true  -- Default to showing soul bags when module not available
end

function Footer:SetQuiverBagCallback(callback)
    if QuiverBag then
        QuiverBag:SetCallback(callback)
    end
end

function Footer:IsQuiverBagVisible()
    if QuiverBag then
        return QuiverBag:IsVisible()
    end
    return true  -- Default to showing quiver bags when module not available
end

function Footer:SetBagVisibilityCallback(callback)
    if BagSlots then
        BagSlots:SetVisibilityCallback(callback)
    end
end

function Footer:GetFrame()
    return frame
end

function Footer:GetHeight()
    if frame and frame.currentHeight then
        return frame.currentHeight
    end
    return Constants.FRAME.FOOTER_HEIGHT
end

function Footer:SetNarrowMode(isNarrow)
    if not frame then return end
    if frame.isNarrowMode == isNarrow then return end
    frame.isNarrowMode = isNarrow

    if isNarrow then
        -- 2-row layout: Bag slots on row 1, Money on row 2 left-aligned
        frame:SetHeight(40)
        frame.currentHeight = 40

        -- Bag slots on top row
        if frame.bagSlotsFrame then
            frame.bagSlotsFrame:ClearAllPoints()
            frame.bagSlotsFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -1)
        end

        -- Money on bottom row, left-aligned symmetric with bags
        if frame.moneyFrame then
            frame.moneyFrame:ClearAllPoints()
            frame.moneyFrame:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 1, 0)
        end
        Money:SetFontSize(12)
    else
        -- Single-row layout (default)
        frame:SetHeight(Constants.FRAME.FOOTER_HEIGHT)
        frame.currentHeight = Constants.FRAME.FOOTER_HEIGHT

        -- Money back to right
        if frame.moneyFrame then
            frame.moneyFrame:ClearAllPoints()
            frame.moneyFrame:SetPoint("RIGHT", frame, "RIGHT", 14, 0)
        end
        Money:SetFontSize(14)

        -- Bag slots back to left
        if frame.bagSlotsFrame then
            frame.bagSlotsFrame:ClearAllPoints()
            frame.bagSlotsFrame:SetPoint("LEFT", frame, "LEFT", 0, 0)
        end
    end
end

function Footer:UpdateTheme()
    if BagSlots then BagSlots:UpdateTheme() end
    if Keyring then Keyring:UpdateTheme() end
    if Currency then Currency:UpdateTheme() end
end

-- Show footer in cached mode (bag slots for highlighting, keyring toggle, cached money)
function Footer:ShowCached(characterFullName)
    if not frame then return end
    frame:Show()

    -- Hide back button
    if backButton then
        backButton:Hide()
    end

    -- Set viewing character for bag slot textures
    BagSlots:SetViewingCharacter(characterFullName)

    -- Show bag slots for hover highlighting
    BagSlots:Show()
    local bagAnchor = BagSlots:GetAnchor()
    local lastAnchor = bagAnchor

    -- Position and show soul bag toggle (Warlock only, single view only)
    local soulBagButton = SoulBag:GetButton()
    if soulBagButton then
        local viewType = Database:GetSetting("bagViewType") or "single"
        if viewType == "single" then
            SoulBag:SetAnchor(lastAnchor)
            SoulBag:Show()
            lastAnchor = soulBagButton
        else
            SoulBag:Hide()
        end
    end

    -- Position and show quiver bag toggle (Hunter Classic/TBC only, single view only)
    local quiverBagButton = QuiverBag:GetButton()
    if quiverBagButton then
        local viewType = Database:GetSetting("bagViewType") or "single"
        if viewType == "single" then
            QuiverBag:SetAnchor(lastAnchor)
            QuiverBag:Show()
            lastAnchor = quiverBagButton
        else
            QuiverBag:Hide()
        end
    end

    -- Position and show keyring for toggle functionality (TBC only)
    local keyringButton = Keyring:GetButton()
    if keyringButton then
        Keyring:SetAnchor(lastAnchor)
        Keyring:Show()
    end

    -- Hide currency (no data for cached characters)
    Currency:Hide()

    -- Show and update money for the cached character
    Money:Show()
    Money:UpdateCached(characterFullName)

    -- Update bag slots and keyring/soul/quiver bag state
    BagSlots:Update()
    if keyringButton then
        Keyring:UpdateState()
    end
    if soulBagButton then
        SoulBag:UpdateState()
    end
    if quiverBagButton then
        QuiverBag:UpdateState()
    end
end

function Footer:SetBackCallback(callback)
    onBackCallback = callback
end
