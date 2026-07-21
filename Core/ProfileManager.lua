local addonName, ns = ...

local ProfileManager = {}
ns:RegisterModule("ProfileManager", ProfileManager)

local Events = ns:GetModule("Events")
local Constants = ns.Constants

-- Profile schema version
local PROFILE_VERSION = 1

-- Export format prefix
local EXPORT_PREFIX = "!GudaBags:1:"

-- Settings keys excluded from profiles (frame positions are screen-specific)
local EXCLUDED_SETTINGS = {
    framePoint = true,
    frameRelativePoint = true,
    frameX = true,
    frameY = true,
    bankFramePoint = true,
    bankFrameRelativePoint = true,
    bankFrameX = true,
    bankFrameY = true,
    guildBankFramePoint = true,
    guildBankFrameRelativePoint = true,
    guildBankFrameX = true,
    guildBankFrameY = true,
}

-------------------------------------------------
-- Deep Copy
-------------------------------------------------

local function DeepCopy(orig)
    if type(orig) ~= "table" then
        return orig
    end
    local copy = {}
    for k, v in pairs(orig) do
        copy[DeepCopy(k)] = DeepCopy(v)
    end
    return copy
end

-------------------------------------------------
-- Base64 Encode/Decode
-------------------------------------------------

local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function Base64Encode(data)
    local result = {}
    local len = #data
    local i = 1
    while i <= len do
        local a = string.byte(data, i)
        local b = i + 1 <= len and string.byte(data, i + 1) or 0
        local c = i + 2 <= len and string.byte(data, i + 2) or 0

        local n = a * 65536 + b * 256 + c

        table.insert(result, string.sub(b64chars, math.floor(n / 262144) + 1, math.floor(n / 262144) + 1))
        table.insert(result, string.sub(b64chars, math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1))

        if i + 1 <= len then
            table.insert(result, string.sub(b64chars, math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1))
        else
            table.insert(result, "=")
        end

        if i + 2 <= len then
            table.insert(result, string.sub(b64chars, n % 64 + 1, n % 64 + 1))
        else
            table.insert(result, "=")
        end

        i = i + 3
    end
    return table.concat(result)
end

local b64lookup = {}
for i = 1, 64 do
    b64lookup[string.byte(b64chars, i)] = i - 1
end

local function Base64Decode(data)
    local result = {}
    local len = #data
    local i = 1
    while i <= len do
        local a = b64lookup[string.byte(data, i)] or 0
        local b = b64lookup[string.byte(data, i + 1)] or 0
        local c = b64lookup[string.byte(data, i + 2)] or 0
        local d = b64lookup[string.byte(data, i + 3)] or 0

        local n = a * 262144 + b * 4096 + c * 64 + d

        table.insert(result, string.char(math.floor(n / 65536) % 256))
        if string.sub(data, i + 2, i + 2) ~= "=" then
            table.insert(result, string.char(math.floor(n / 256) % 256))
        end
        if string.sub(data, i + 3, i + 3) ~= "=" then
            table.insert(result, string.char(n % 256))
        end

        i = i + 4
    end
    return table.concat(result)
end

-------------------------------------------------
-- Table Serializer
-------------------------------------------------

local function SerializeValue(val, parts)
    local t = type(val)
    if t == "number" then
        table.insert(parts, "N")
        table.insert(parts, tostring(val))
        table.insert(parts, ";")
    elseif t == "string" then
        table.insert(parts, "S")
        table.insert(parts, tostring(#val))
        table.insert(parts, ":")
        table.insert(parts, val)
    elseif t == "boolean" then
        table.insert(parts, val and "T" or "F")
    elseif t == "table" then
        -- Count entries
        local count = 0
        for _ in pairs(val) do
            count = count + 1
        end
        table.insert(parts, "{")
        table.insert(parts, tostring(count))
        table.insert(parts, ";")
        for k, v in pairs(val) do
            SerializeValue(k, parts)
            SerializeValue(v, parts)
        end
        table.insert(parts, "}")
    elseif t == "nil" then
        table.insert(parts, "X")
    end
end

local function Serialize(tbl)
    local parts = {}
    SerializeValue(tbl, parts)
    return table.concat(parts)
end

local function DeserializeValue(data, pos)
    if pos > #data then
        return nil, pos
    end

    local tag = string.sub(data, pos, pos)
    pos = pos + 1

    if tag == "N" then
        local semi = string.find(data, ";", pos, true)
        if not semi then return nil, pos end
        local num = tonumber(string.sub(data, pos, semi - 1))
        return num, semi + 1
    elseif tag == "S" then
        local colon = string.find(data, ":", pos, true)
        if not colon then return nil, pos end
        local len = tonumber(string.sub(data, pos, colon - 1))
        if not len then return nil, pos end
        local str = string.sub(data, colon + 1, colon + len)
        return str, colon + len + 1
    elseif tag == "T" then
        return true, pos
    elseif tag == "F" then
        return false, pos
    elseif tag == "X" then
        return nil, pos
    elseif tag == "{" then
        local semi = string.find(data, ";", pos, true)
        if not semi then return nil, pos end
        local count = tonumber(string.sub(data, pos, semi - 1))
        if not count then return nil, pos end
        pos = semi + 1
        local tbl = {}
        for _ = 1, count do
            local key, val
            key, pos = DeserializeValue(data, pos)
            val, pos = DeserializeValue(data, pos)
            if key ~= nil then
                tbl[key] = val
            end
        end
        -- Consume closing brace
        if string.sub(data, pos, pos) == "}" then
            pos = pos + 1
        end
        return tbl, pos
    end

    return nil, pos
end

local function Deserialize(data)
    local val, _ = DeserializeValue(data, 1)
    return val
end

-------------------------------------------------
-- Profile Data Helpers
-------------------------------------------------

local function SnapshotSettings()
    if not GudaBags_CharDB or not GudaBags_CharDB.settings then
        return {}
    end
    local snapshot = {}
    for key, value in pairs(GudaBags_CharDB.settings) do
        if not EXCLUDED_SETTINGS[key] then
            snapshot[key] = DeepCopy(value)
        end
    end
    return snapshot
end

local function SnapshotCategories()
    if not GudaBags_CharDB or not GudaBags_CharDB.categories then
        return nil
    end
    local cats = GudaBags_CharDB.categories
    local snapshot = {
        definitions = DeepCopy(cats.definitions),
        order = DeepCopy(cats.order),
        itemOverrides = DeepCopy(cats.itemOverrides),
    }
    return snapshot
end

-------------------------------------------------
-- Expansion Name Table
-------------------------------------------------

local EXPANSION_NAMES = {
    [1] = "Retail",
    [2] = "Classic",
    [5] = "TBC",
    [19] = "MoP",
}

-------------------------------------------------
-- Public API
-------------------------------------------------

function ProfileManager:GetActiveProfile()
    if not GudaBags_CharDB then return nil end
    return GudaBags_CharDB.activeProfile
end

function ProfileManager:ClearActiveProfile()
    if GudaBags_CharDB then
        GudaBags_CharDB.activeProfile = nil
    end
end

function ProfileManager:SaveProfile(name)
    if not name or name == "" then return false end
    if not GudaBags_DB then return false end

    GudaBags_DB.profiles = GudaBags_DB.profiles or {}

    GudaBags_DB.profiles[name] = {
        version = PROFILE_VERSION,
        addonVersion = ns.version,
        expansionId = WOW_PROJECT_ID,
        settingsVersion = GudaBags_CharDB.settingsVersion or 0,
        createdAt = GudaBags_DB.profiles[name] and GudaBags_DB.profiles[name].createdAt or time(),
        updatedAt = time(),
        settings = SnapshotSettings(),
        categories = SnapshotCategories(),
    }

    return true
end

function ProfileManager:LoadProfile(name)
    if not name or not GudaBags_DB or not GudaBags_DB.profiles then return false end
    local profile = GudaBags_DB.profiles[name]
    if not profile then return false end

    local Database = ns:GetModule("Database")

    -- 1. Deep copy profile settings into CharDB (skip excluded keys)
    if profile.settings then
        for key, value in pairs(profile.settings) do
            if not EXCLUDED_SETTINGS[key] then
                GudaBags_CharDB.settings[key] = DeepCopy(value)
            end
        end
    end

    -- Remap theme for cross-expansion compatibility
    local theme = GudaBags_CharDB.settings.theme
    if ns.IsRetail and theme == "retail" then
        -- "Retail" theme is a Classic-only cosmetic; on actual Retail, "blizzard" is equivalent
        GudaBags_CharDB.settings.theme = "blizzard"
    elseif not ns.IsRetail and profile.expansionId == (WOW_PROJECT_MAINLINE or 1) and theme == "blizzard" then
        -- Importing from Retail where "blizzard" uses native metal frames; on Classic, "retail" is the equivalent look
        GudaBags_CharDB.settings.theme = "retail"
    end

    -- 2. Set settingsVersion and run migrations
    if profile.settingsVersion then
        GudaBags_CharDB.settingsVersion = profile.settingsVersion
    end
    -- Re-run DB initialization to apply migrations and fill missing defaults
    Database:Initialize()

    -- 3. Deep copy profile categories
    if profile.categories then
        GudaBags_CharDB.categories = DeepCopy(profile.categories)
    end

    -- 4. Run category migrations and invalidate caches
    local CategoryManager = ns:GetModule("CategoryManager")
    if CategoryManager then
        local categories = Database:GetCategories()
        if categories then
            CategoryManager:MigrateCategories(categories)
            Database:SetCategories(categories)
        end
        CategoryManager:InvalidatePriorityCache()
    end

    -- 5. Close bag/bank frames so they fully rebuild on next open
    self:CloseFrames()

    -- 6. Mark active profile and fire events for UI refresh
    GudaBags_CharDB.activeProfile = name
    self:FireProfileEvents()

    return true
end

function ProfileManager:DeleteProfile(name)
    if not name or not GudaBags_DB or not GudaBags_DB.profiles then return false end
    if not GudaBags_DB.profiles[name] then return false end
    GudaBags_DB.profiles[name] = nil
    return true
end

function ProfileManager:RenameProfile(oldName, newName)
    if not oldName or not newName or newName == "" then return false end
    if not GudaBags_DB or not GudaBags_DB.profiles then return false end
    if not GudaBags_DB.profiles[oldName] then return false end
    if GudaBags_DB.profiles[newName] then return false end

    GudaBags_DB.profiles[newName] = GudaBags_DB.profiles[oldName]
    GudaBags_DB.profiles[oldName] = nil
    return true
end

function ProfileManager:GetProfileList()
    if not GudaBags_DB or not GudaBags_DB.profiles then return {} end

    local list = {}
    for name, profile in pairs(GudaBags_DB.profiles) do
        table.insert(list, {
            name = name,
            expansionId = profile.expansionId,
            addonVersion = profile.addonVersion,
            createdAt = profile.createdAt,
            updatedAt = profile.updatedAt,
        })
    end

    local active = self:GetActiveProfile()
    table.sort(list, function(a, b)
        if a.name == active then return true end
        if b.name == active then return false end
        return (a.updatedAt or 0) > (b.updatedAt or 0)
    end)

    return list
end

function ProfileManager:ProfileExists(name)
    if not name or not GudaBags_DB or not GudaBags_DB.profiles then return false end
    return GudaBags_DB.profiles[name] ~= nil
end

-------------------------------------------------
-- Shared Helpers
-------------------------------------------------

function ProfileManager:CloseFrames()
    local BagFrame = ns:GetModule("BagFrame")
    if BagFrame and BagFrame.Hide then
        BagFrame:Hide()
    end
    local BankFrame = ns:GetModule("BankFrame")
    if BankFrame and BankFrame.Hide then
        BankFrame:Hide()
    end
end

function ProfileManager:FireProfileEvents()
    Events:Fire("PROFILE_LOADED")
    Events:Fire("CATEGORIES_UPDATED")
    Events:Fire("BAGS_UPDATED")
end

function ProfileManager:ResetToDefaults()
    -- Reset settings to defaults (preserve frame positions)
    if Constants.DEFAULTS then
        for key, default in pairs(Constants.DEFAULTS) do
            GudaBags_CharDB.settings[key] = default
        end
    end

    -- Reset categories
    local CategoryManager = ns:GetModule("CategoryManager")
    if CategoryManager then
        CategoryManager:ResetToDefaults()
    end

    self:ClearActiveProfile()
    self:CloseFrames()
    self:FireProfileEvents()
end

-------------------------------------------------
-- Export / Import
-------------------------------------------------

function ProfileManager:ExportProfile(name)
    if not name or not GudaBags_DB or not GudaBags_DB.profiles then return nil end
    local profile = GudaBags_DB.profiles[name]
    if not profile then return nil end

    local exportData = DeepCopy(profile)
    local serialized = Serialize(exportData)
    local encoded = Base64Encode(serialized)
    return EXPORT_PREFIX .. encoded
end

function ProfileManager:ImportProfile(encodedStr)
    if not encodedStr or encodedStr == "" then
        return false, ns.L["PROFILE_IMPORT_INVALID"]
    end

    -- Validate prefix
    if string.sub(encodedStr, 1, #EXPORT_PREFIX) ~= EXPORT_PREFIX then
        return false, ns.L["PROFILE_IMPORT_INVALID"]
    end

    local b64data = string.sub(encodedStr, #EXPORT_PREFIX + 1)
    if b64data == "" then
        return false, ns.L["PROFILE_IMPORT_INVALID"]
    end

    -- Decode
    local ok, decoded = pcall(Base64Decode, b64data)
    if not ok or not decoded or decoded == "" then
        return false, ns.L["PROFILE_IMPORT_DECODE_ERROR"]
    end

    -- Deserialize
    local ok2, profileData = pcall(Deserialize, decoded)
    if not ok2 or type(profileData) ~= "table" then
        return false, ns.L["PROFILE_IMPORT_DECODE_ERROR"]
    end

    -- Validate structure
    if not profileData.settings or type(profileData.settings) ~= "table" then
        return false, ns.L["PROFILE_IMPORT_INVALID"]
    end

    -- Fill missing settings from defaults
    if Constants.DEFAULTS then
        for key, default in pairs(Constants.DEFAULTS) do
            if profileData.settings[key] == nil and not EXCLUDED_SETTINGS[key] then
                profileData.settings[key] = DeepCopy(default)
            end
        end
    end

    return true, profileData
end

function ProfileManager:SaveImportedProfile(name, profileData)
    if not name or name == "" or not profileData then return false end
    if not GudaBags_DB then return false end

    GudaBags_DB.profiles = GudaBags_DB.profiles or {}

    GudaBags_DB.profiles[name] = {
        version = profileData.version or PROFILE_VERSION,
        addonVersion = profileData.addonVersion or ns.version,
        expansionId = profileData.expansionId,
        settingsVersion = profileData.settingsVersion or 0,
        createdAt = time(),
        updatedAt = time(),
        settings = DeepCopy(profileData.settings),
        categories = profileData.categories and DeepCopy(profileData.categories) or nil,
    }

    return true
end

-------------------------------------------------
-- Expansion Name Helper
-------------------------------------------------

function ProfileManager:GetExpansionName(expansionId)
    return EXPANSION_NAMES[expansionId] or ("ID:" .. tostring(expansionId or "?"))
end
