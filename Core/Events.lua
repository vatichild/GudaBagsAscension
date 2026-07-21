local addonName, ns = ...

local Events = {}
ns:RegisterModule("Events", Events)

local callbacks = {}
local eventFrame = CreateFrame("Frame")

local function OnEvent(self, event, ...)
    if not callbacks[event] then return end
    for owner, callback in pairs(callbacks[event]) do
        local success, err = pcall(callback, event, ...)
        if not success then
            -- Also record it: chat scrolls away, the saved variable does not.
            if ns.ErrorSink then ns.ErrorSink:Capture(err, "event:" .. tostring(event)) end
            ns:Print("Error in", event, "handler:", err)
        end
    end
end

eventFrame:SetScript("OnEvent", OnEvent)

-- Custom events (not WoW events) don't need frame registration
local customEvents = {
    SETTING_CHANGED = true,
    BAGS_UPDATED = true,
    CATEGORIES_UPDATED = true,
    PROFILE_LOADED = true,
}

-- Events this client does not know about. RegisterEvent RAISES on an unknown
-- event name, and the addon registers plenty that postdate 3.3.5a
-- (BANK_TABS_CHANGED, AUCTION_HOUSE_*, PLAYER_INTERACTION_MANAGER_FRAME_SHOW,
-- ACCOUNT_MONEY, ...). One unknown name would otherwise take down whichever
-- module happened to register it. Record them for the port instead.
Events.unsupported = {}

function Events:Register(event, callback, owner)
    if not callbacks[event] then
        callbacks[event] = {}
        -- Only register with frame for WoW system events
        if not customEvents[event] then
            local ok = pcall(eventFrame.RegisterEvent, eventFrame, event)
            if not ok then
                -- Registration failed: the event simply never fires here. Keep
                -- the callback table so Unregister stays symmetrical.
                Events.unsupported[event] = true
                if ns.ErrorSink then
                    ns.ErrorSink:Capture("unsupported event: " .. tostring(event), "Events:Register")
                end
            end
        end
    end
    callbacks[event][owner] = callback
end

function Events:Unregister(event, owner)
    if not callbacks[event] then return end
    callbacks[event][owner] = nil

    local hasCallbacks = false
    for _ in pairs(callbacks[event]) do
        hasCallbacks = true
        break
    end

    if not hasCallbacks then
        callbacks[event] = nil
        -- Only unregister for WoW system events, and never for one that failed
        -- to register in the first place (UnregisterEvent raises on those too).
        if not customEvents[event] and not Events.unsupported[event] then
            pcall(eventFrame.UnregisterEvent, eventFrame, event)
        end
    end
end

function Events:UnregisterAll(owner)
    for event in pairs(callbacks) do
        self:Unregister(event, owner)
    end
end

function Events:OnBagUpdate(callback, owner)
    self:Register("BAG_UPDATE", callback, owner)
end

function Events:OnBankOpened(callback, owner)
    self:Register("BANKFRAME_OPENED", callback, owner)
end

function Events:OnBankClosed(callback, owner)
    self:Register("BANKFRAME_CLOSED", callback, owner)
end

function Events:OnPlayerLogin(callback, owner)
    self:Register("PLAYER_LOGIN", callback, owner)
end

function Events:OnPlayerMoney(callback, owner)
    self:Register("PLAYER_MONEY", callback, owner)
end

function Events:OnAddonLoaded(callback, owner)
    self:Register("ADDON_LOADED", function(event, loadedAddon)
        if loadedAddon == addonName then
            callback(event, loadedAddon)
        end
    end, owner)
end

function Events:Fire(event, ...)
    if not callbacks[event] then return end
    for owner, callback in pairs(callbacks[event]) do
        local success, err = pcall(callback, event, ...)
        if not success then
            -- Also record it: chat scrolls away, the saved variable does not.
            if ns.ErrorSink then ns.ErrorSink:Capture(err, "event:" .. tostring(event)) end
            ns:Print("Error in", event, "handler:", err)
        end
    end
end
