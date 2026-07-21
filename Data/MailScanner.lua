local addonName, ns = ...

local MailScanner = {}
ns:RegisterModule("MailScanner", MailScanner)

local Database = ns:GetModule("Database")
local Events = ns:GetModule("Events")

-- State
local isMailboxOpen = false
local cachedMail = {}
local saveTimer = nil
local scanTimer = nil
local SAVE_DELAY = 1.0
local SCAN_DELAY = 0.5
local RESCAN_DEBOUNCE = 0.3
local PREDICTED_MAIL_EXPIRY_DAYS = 30

-- AH purchase tracking state
local pendingAHPurchase = nil  -- Retail: stores item info between hook and event

-------------------------------------------------
-- Public State
-------------------------------------------------

function MailScanner:IsMailboxOpen()
    return isMailboxOpen
end

function MailScanner:GetCachedMail()
    return cachedMail
end

-------------------------------------------------
-- Scanning
-------------------------------------------------

function MailScanner:ScanMailbox()
    if not isMailboxOpen then
        ns:Debug("MailScanner: Mailbox not open, returning cached")
        return cachedMail
    end

    local numItems = GetInboxNumItems()
    ns:Debug("MailScanner: Scanning", numItems, "mails")

    local rows = {}

    for mailIndex = 1, numItems do
        local _, _, sender, subject, money, CODAmount, daysLeft, numAttachments, wasRead, _, _, _, isGM = GetInboxHeaderInfo(mailIndex)

        if not sender then sender = UNKNOWN or "Unknown" end
        if not subject then subject = "" end

        local hasAttachments = numAttachments and numAttachments > 0

        if hasAttachments then
            for attachIndex = 1, numAttachments do
                local name, itemID, texture, count, quality, canUse = GetInboxItem(mailIndex, attachIndex)
                local link = GetInboxItemLink(mailIndex, attachIndex)

                if itemID then
                    local itemType, itemSubType, _, equipSlot
                    if link then
                        _, _, _, _, _, itemType, itemSubType, _, equipSlot = GetItemInfo(link)
                    end

                    table.insert(rows, {
                        mailIndex = mailIndex,
                        attachmentIndex = attachIndex,
                        sender = sender,
                        subject = subject,
                        money = money or 0,
                        CODAmount = CODAmount or 0,
                        daysLeft = daysLeft or 0,
                        wasRead = wasRead,
                        hasItem = true,
                        itemID = itemID,
                        link = link,
                        name = name or "",
                        texture = texture,
                        count = count or 1,
                        quality = quality or 0,
                        itemType = itemType,
                        itemSubType = itemSubType,
                        equipSlot = equipSlot,
                    })
                end
            end
        end

        -- Money-only or no-attachment mails get one row
        if not hasAttachments then
            table.insert(rows, {
                mailIndex = mailIndex,
                attachmentIndex = 0,
                sender = sender,
                subject = subject,
                money = money or 0,
                CODAmount = CODAmount or 0,
                daysLeft = daysLeft or 0,
                wasRead = wasRead,
                hasItem = false,
            })
        end
    end

    cachedMail = rows
    ns:Debug("MailScanner: Scanned", #rows, "rows from", numItems, "mails")

    return rows
end

-------------------------------------------------
-- Database Persistence
-------------------------------------------------

function MailScanner:SaveToDatabase()
    Database:SaveMailbox(cachedMail)
    ns:Debug("MailScanner: Saved", #cachedMail, "rows to database")
end

function MailScanner:LoadFromDatabase(fullName)
    local mailData = Database:GetMailbox(fullName)
    if mailData and #mailData > 0 then
        cachedMail = mailData
        ns:Debug("MailScanner: Loaded", #cachedMail, "rows from database for", fullName or "current")
    else
        cachedMail = {}
        ns:Debug("MailScanner: No mail data found for", fullName or "current")
    end
end

-------------------------------------------------
-- Deferred Save
-------------------------------------------------

local function ScheduleDeferredSave()
    if saveTimer then
        saveTimer:Cancel()
    end
    saveTimer = C_Timer.NewTimer(SAVE_DELAY, function()
        MailScanner:SaveToDatabase()
        saveTimer = nil
        ns:Debug("MailScanner: Deferred save complete")
    end)
end

-------------------------------------------------
-- Debounced Rescan
-------------------------------------------------

local function ScheduleRescan()
    if scanTimer then
        scanTimer:Cancel()
    end
    scanTimer = C_Timer.NewTimer(RESCAN_DEBOUNCE, function()
        scanTimer = nil
        if not isMailboxOpen then return end
        MailScanner:ScanMailbox()
        ScheduleDeferredSave()

        if ns.OnMailUpdated then
            ns.OnMailUpdated()
        end
    end)
end

-------------------------------------------------
-- Predicted Mail (AH purchases)
-------------------------------------------------

local function AddPredictedMail(itemID, count, sender)
    local name, link, quality, _, _, itemType, itemSubType, _, equipSlot, texture = GetItemInfo(itemID)

    local row = {
        mailIndex = -1,  -- Negative index = predicted
        attachmentIndex = 1,
        sender = sender or AUCTION_HOUSE or "Auction House",
        subject = name or ("Item " .. itemID),
        money = 0,
        CODAmount = 0,
        daysLeft = PREDICTED_MAIL_EXPIRY_DAYS,
        wasRead = false,
        hasItem = true,
        itemID = itemID,
        link = link,
        name = name or "",
        texture = texture,
        count = count or 1,
        quality = quality or 0,
        itemType = itemType,
        itemSubType = itemSubType,
        equipSlot = equipSlot,
        predicted = true,
    }

    table.insert(cachedMail, 1, row)
    ns:Debug("MailScanner: Added predicted mail for", name or itemID, "x" .. (count or 1))
    ScheduleDeferredSave()

    if ns.OnMailUpdated then
        ns.OnMailUpdated()
    end
end

-------------------------------------------------
-- AH Purchase Hooks
-------------------------------------------------

local function InitializeAHHooks()
    -- C_AuctionHouse is available on Retail and MoP Classic
    if C_AuctionHouse and C_AuctionHouse.PlaceBid then
        -- Single item purchase
        hooksecurefunc(C_AuctionHouse, "PlaceBid", function(auctionID, bidAmount)
            -- Store pending purchase info
            local info = C_AuctionHouse.GetAuctionInfoByID(auctionID)
            if info and info.buyoutAmount and bidAmount >= info.buyoutAmount then
                pendingAHPurchase = {
                    itemID = info.itemKey and info.itemKey.itemID,
                    count = info.quantity or 1,
                }
                ns:Debug("MailScanner: AH PlaceBid (buyout) for", pendingAHPurchase.itemID)
            end
        end)

        -- Commodity purchase
        if C_AuctionHouse.ConfirmCommoditiesPurchase then
            hooksecurefunc(C_AuctionHouse, "ConfirmCommoditiesPurchase", function(itemID, quantity)
                pendingAHPurchase = {
                    itemID = itemID,
                    count = quantity or 1,
                }
                ns:Debug("MailScanner: AH ConfirmCommoditiesPurchase for", itemID, "x" .. (quantity or 1))
            end)
        end
    elseif PlaceAuctionBid then
        -- Classic Era / TBC: legacy PlaceAuctionBid hook
        -- Defer predicted mail until we confirm no error from the server
        local pendingClassicPurchase = nil
        local pendingTimer = nil

        hooksecurefunc("PlaceAuctionBid", function(listType, index, bid)
            local info = {GetAuctionItemInfo(listType, index)}
            local name = info[1]
            local texture = info[2]
            local count = info[3]
            local quality = info[4]
            local buyoutPrice = info[10]
            local itemID = info[17]
            -- Only track buyouts (bid == buyout price)
            if buyoutPrice and buyoutPrice > 0 and bid >= buyoutPrice and itemID then
                local link = GetAuctionItemLink(listType, index)
                pendingClassicPurchase = {
                    mailIndex = -1,
                    attachmentIndex = 1,
                    sender = AUCTION_HOUSE or "Auction House",
                    subject = name or ("Item " .. itemID),
                    money = 0,
                    CODAmount = 0,
                    daysLeft = PREDICTED_MAIL_EXPIRY_DAYS,
                    wasRead = false,
                    hasItem = true,
                    itemID = itemID,
                    link = link,
                    name = name or "",
                    texture = texture,
                    count = count or 1,
                    quality = quality or 0,
                    predicted = true,
                }
                -- Wait a short time for potential error; if none arrives, commit the predicted mail
                if pendingTimer then pendingTimer:Cancel() end
                pendingTimer = C_Timer.NewTimer(1.0, function()
                    if pendingClassicPurchase then
                        table.insert(cachedMail, 1, pendingClassicPurchase)
                        ns:Debug("MailScanner: Classic AH buyout for", pendingClassicPurchase.name or pendingClassicPurchase.itemID, "x" .. (pendingClassicPurchase.count or 1))
                        pendingClassicPurchase = nil
                        ScheduleDeferredSave()
                        if ns.OnMailUpdated then
                            ns.OnMailUpdated()
                        end
                    end
                end)
            end
        end)

        -- Cancel pending predicted mail if auction error occurs
        local auctionErrorFrame = CreateFrame("Frame")
        auctionErrorFrame:RegisterEvent("UI_ERROR_MESSAGE")
        auctionErrorFrame:SetScript("OnEvent", function(_, _, errorType, message)
            if pendingClassicPurchase and message and (
                message == ERR_AUCTION_DATABASE_ERROR
                or message == ERR_ITEM_NOT_FOUND
                or message == ERR_AUCTION_HIGHER_BID
                or message == ERR_NOT_ENOUGH_MONEY
                or string.find(message, "Internal Auction Error")
            ) then
                ns:Debug("MailScanner: Classic AH purchase failed:", message)
                pendingClassicPurchase = nil
                if pendingTimer then
                    pendingTimer:Cancel()
                    pendingTimer = nil
                end
            end
        end)
    end
end

-------------------------------------------------
-- SendMail Hook (track mail to alts)
-------------------------------------------------

local function InitializeSendMailHook()
    if not SendMail then return end

    hooksecurefunc("SendMail", function(recipient, subject, body)
        if not recipient or recipient == "" then return end

        -- Normalize recipient: add realm if not present
        local realm = GetRealmName()
        local recipientFullName = recipient
        if not recipient:find("-") then
            recipientFullName = recipient .. "-" .. realm
        end

        -- Check if recipient is a known alt
        local charData = GudaBags_DB and GudaBags_DB.characters and GudaBags_DB.characters[recipientFullName]
        if not charData then return end

        -- Don't track mail to self
        local playerName = UnitName("player")
        if recipient == playerName or recipientFullName == (playerName .. "-" .. realm) then return end

        ns:Debug("MailScanner: SendMail to known alt", recipientFullName)

        local senderName = playerName
        local rows = {}

        -- Scan send mail attachments (slots 1-ATTACHMENTS_MAX_SEND)
        local maxSlots = ATTACHMENTS_MAX_SEND or 12
        for i = 1, maxSlots do
            local name, itemID, texture, count, quality = GetSendMailItem(i)
            if itemID then
                local link = GetSendMailItemLink(i)
                table.insert(rows, {
                    mailIndex = -1,
                    attachmentIndex = i,
                    sender = senderName,
                    subject = subject or "",
                    money = 0,
                    CODAmount = GetSendMailCOD() or 0,
                    daysLeft = PREDICTED_MAIL_EXPIRY_DAYS,
                    wasRead = false,
                    hasItem = true,
                    itemID = itemID,
                    link = link,
                    name = name or "",
                    texture = texture,
                    count = count or 1,
                    quality = quality or 0,
                    predicted = true,
                })
            end
        end

        -- Check if sending money
        local money = GetSendMailMoney() or 0
        if #rows == 0 and money > 0 then
            table.insert(rows, {
                mailIndex = -1,
                attachmentIndex = 0,
                sender = senderName,
                subject = subject or "",
                money = money,
                CODAmount = 0,
                daysLeft = PREDICTED_MAIL_EXPIRY_DAYS,
                wasRead = false,
                hasItem = false,
                predicted = true,
            })
        elseif #rows > 0 then
            -- Attach money to the first row
            rows[1].money = money
        end

        if #rows == 0 then return end

        -- Add predicted rows to recipient's mailbox data
        local recipientMailbox = Database:GetMailbox(recipientFullName)
        -- Copy to avoid modifying the original reference if empty
        local updatedMailbox = {}
        for _, existingRow in ipairs(recipientMailbox) do
            table.insert(updatedMailbox, existingRow)
        end
        -- Insert new rows at the beginning
        for i = #rows, 1, -1 do
            table.insert(updatedMailbox, 1, rows[i])
        end

        -- Save directly to recipient's character data
        if GudaBags_DB.characters[recipientFullName] then
            GudaBags_DB.characters[recipientFullName].mailbox = updatedMailbox
            ns:Debug("MailScanner: Added", #rows, "predicted mail rows to", recipientFullName)
        end
    end)
end

-------------------------------------------------
-- Hooks
-------------------------------------------------

local function InitializeHooks()
    -- TakeInboxItem: player took an attachment
    if TakeInboxItem then
        hooksecurefunc("TakeInboxItem", function(mailIndex, attachIndex)
            ns:Debug("MailScanner: TakeInboxItem hook", mailIndex, attachIndex)
            ScheduleRescan()
        end)
    end

    -- TakeInboxMoney: player took money from mail
    if TakeInboxMoney then
        hooksecurefunc("TakeInboxMoney", function(mailIndex)
            ns:Debug("MailScanner: TakeInboxMoney hook", mailIndex)
            ScheduleRescan()
        end)
    end

    -- AutoLootMailItem: auto-loot attachment
    if AutoLootMailItem then
        hooksecurefunc("AutoLootMailItem", function(mailIndex)
            ns:Debug("MailScanner: AutoLootMailItem hook", mailIndex)
            ScheduleRescan()
        end)
    end

    -- DeleteInboxItem: player deleted a mail
    if DeleteInboxItem then
        hooksecurefunc("DeleteInboxItem", function(mailIndex)
            ns:Debug("MailScanner: DeleteInboxItem hook", mailIndex)
            ScheduleRescan()
        end)
    end
end

-------------------------------------------------
-- Event Handlers
-------------------------------------------------

Events:Register("MAIL_SHOW", function()
    ns:Debug("MailScanner: MAIL_SHOW")
    isMailboxOpen = true

    -- Delay initial scan to wait for server data
    if scanTimer then
        scanTimer:Cancel()
    end
    scanTimer = C_Timer.NewTimer(SCAN_DELAY, function()
        scanTimer = nil
        if not isMailboxOpen then return end
        MailScanner:ScanMailbox()
        MailScanner:SaveToDatabase()

        if ns.OnMailUpdated then
            ns.OnMailUpdated()
        end
    end)
end, MailScanner)

Events:Register("MAIL_CLOSED", function()
    ns:Debug("MailScanner: MAIL_CLOSED")
    -- Final save before closing
    if isMailboxOpen then
        MailScanner:ScanMailbox()
        MailScanner:SaveToDatabase()
    end
    isMailboxOpen = false

    if scanTimer then
        scanTimer:Cancel()
        scanTimer = nil
    end
end, MailScanner)

Events:Register("MAIL_INBOX_UPDATE", function()
    if not isMailboxOpen then return end
    ns:Debug("MailScanner: MAIL_INBOX_UPDATE")
    ScheduleRescan()
end, MailScanner)

-- Modern AH purchase confirmation events (Retail + MoP Classic)
if C_AuctionHouse then
    Events:Register("AUCTION_HOUSE_PURCHASE_COMPLETED", function()
        if pendingAHPurchase and pendingAHPurchase.itemID then
            AddPredictedMail(pendingAHPurchase.itemID, pendingAHPurchase.count)
            pendingAHPurchase = nil
        end
    end, MailScanner)

    Events:Register("COMMODITY_PURCHASE_SUCCEEDED", function()
        if pendingAHPurchase and pendingAHPurchase.itemID then
            AddPredictedMail(pendingAHPurchase.itemID, pendingAHPurchase.count)
            pendingAHPurchase = nil
        end
    end, MailScanner)
end

-------------------------------------------------
-- Initialization
-------------------------------------------------

local hooksInitialized = false

Events:OnPlayerLogin(function()
    if not hooksInitialized then
        hooksInitialized = true
        InitializeHooks()
        InitializeAHHooks()
        InitializeSendMailHook()
    end

    -- Load cached mail from database
    MailScanner:LoadFromDatabase()
end, MailScanner)
