local addonName, ns = ...

local DefaultCategories = {}
ns.DefaultCategories = DefaultCategories

-- Get Expansion module for conditional category definitions
local Expansion = ns:GetModule("Expansion")

-- Rule Types:
-- itemType: Match GetItemInfo itemType (Armor, Weapon, Consumable, Trade Goods, etc.)
-- itemSubtype: Match GetItemInfo itemSubType
-- namePattern: Lua pattern match on item name
-- quality: Exact quality match (0=Poor, 1=Common, 2=Uncommon, 3=Rare, 4=Epic, 5=Legendary)
-- qualityMin: Minimum quality (item.quality >= value)
-- isBoE: Bind on Equip detection (requires tooltip scan)
-- isQuestItem: Quest item flag from ItemScanner
-- isJunk: Gray quality or white equippable without special properties
-- isProfessionTool: Profession tools (fishing pole, mining pick, skinning knife)
-- texturePattern: Match icon texture path
-- itemID: Specific item ID (number) or array of IDs ({123, 456})
-- isSoulShard: Soul shard detection
-- isProjectile: Arrows and bullets
-- restoreTag: Consumable type from tooltip (eat/drink/restore)

-- Rule types are returned as a function to get localized labels
function DefaultCategories:GetRuleTypes()
    local L = ns.L
    return {
        { id = "itemType", label = L["RULE_ITEM_TYPE"], valueType = "dropdown", options = {
            "Armor", "Weapon", "Consumable", "Trade Goods", "Container", "Projectile",
            "Quiver", "Recipe", "Reagent", "Gem", "Key", "Quest", "Miscellaneous"
        }},
        { id = "itemID", label = L["RULE_ITEM_ID"], shortLabel = L["RULE_ITEM_ID_SHORT"], valueType = "itemID" },
        { id = "itemSubtype", label = L["RULE_ITEM_SUBTYPE"], valueType = "text" },
        { id = "namePattern", label = L["RULE_NAME_CONTAINS"], valueType = "text" },
        { id = "tooltipPattern", label = L["RULE_TOOLTIP_CONTAINS"], valueType = "text", tooltip = L["RULE_TOOLTIP_CONTAINS_TIP"] },
        { id = "quality", label = L["RULE_QUALITY_EXACT"], valueType = "dropdown", options = {
            {value = 0, label = L["QUALITY_POOR"]},
            {value = 1, label = L["QUALITY_COMMON"]},
            {value = 2, label = L["QUALITY_UNCOMMON"]},
            {value = 3, label = L["QUALITY_RARE"]},
            {value = 4, label = L["QUALITY_EPIC"]},
            {value = 5, label = L["QUALITY_LEGENDARY"]},
        }},
        { id = "qualityMin", label = L["RULE_QUALITY_MIN"], valueType = "dropdown", options = {
            {value = 0, label = L["QUALITY_POOR_PLUS"]},
            {value = 1, label = L["QUALITY_COMMON_PLUS"]},
            {value = 2, label = L["QUALITY_UNCOMMON_PLUS"]},
            {value = 3, label = L["QUALITY_RARE_PLUS"]},
            {value = 4, label = L["QUALITY_EPIC_PLUS"]},
            {value = 5, label = L["QUALITY_LEGENDARY_ONLY"]},
        }},
        { id = "isBoE", label = L["RULE_BOE"], valueType = "boolean" },
        { id = "isWarbound", label = L["RULE_WARBOUND"], valueType = "boolean" },
        { id = "isQuestItem", label = L["RULE_QUEST_ITEM"], valueType = "boolean" },
        { id = "isJunk", label = L["RULE_JUNK_ITEM"], valueType = "boolean" },
        { id = "isProfessionTool", label = L["RULE_PROFESSION_TOOL"], valueType = "boolean" },
        { id = "isSoulShard", label = L["RULE_SOUL_SHARD"], valueType = "boolean" },
        { id = "isProjectile", label = L["RULE_PROJECTILE"], valueType = "boolean" },
        { id = "isReagent", label = L["RULE_REAGENT"], valueType = "boolean", tooltip = L["RULE_REAGENT_TIP"] },
        { id = "restoreTag", label = L["RULE_CONSUMABLE_TYPE"], valueType = "dropdown", options = {
            {value = "eat", label = L["CONSUMABLE_FOOD"]},
            {value = "drink", label = L["CONSUMABLE_DRINK"]},
            {value = "restore", label = L["CONSUMABLE_RESTORE"]},
        }},
        { id = "texturePattern", label = L["RULE_ICON_PATTERN"], valueType = "text" },
        { id = "isRecent", label = L["RULE_RECENT_ITEMS"], valueType = "slider", min = 1, max = 60, step = 1, format = "min" },
    }
end

-- Locale keys for built-in category names
local CATEGORY_LOCALE_KEYS = {
    ["Home"] = "CAT_HOME",
    ["Recent"] = "CAT_RECENT",
    ["BoE"] = "CAT_BOE",
    ["Warbound"] = "CAT_WARBOUND",
    ["Weapon"] = "CAT_WEAPON",
    ["Armor"] = "CAT_ARMOR",
    ["Consumable"] = "CAT_CONSUMABLE",
    ["Food"] = "CAT_FOOD",
    ["Drink"] = "CAT_DRINK",
    ["Trade Goods"] = "CAT_TRADE_GOODS",
    ["Reagent"] = "CAT_REAGENT",
    ["Recipe"] = "CAT_RECIPE",
    ["Quiver"] = "CAT_QUIVER",
    ["Quiver Bag"] = "CAT_QUIVER_BAG",
    ["Container"] = "CAT_CONTAINER",
    ["Soul Bag"] = "CAT_SOUL_BAG",
    ["Tools"] = "CAT_TOOLS",
    ["Miscellaneous"] = "CAT_MISCELLANEOUS",
    ["Quest"] = "CAT_QUEST",
    ["Junk"] = "CAT_JUNK",
    ["Class Items"] = "CAT_CLASS_ITEMS",
    ["Keyring"] = "CAT_KEYRING",
    ["Empty"] = "CAT_EMPTY",
    ["Soul"] = "CAT_SOUL",
}

-- Locale keys for group names
local GROUP_LOCALE_KEYS = {
    ["Main"] = "GROUP_MAIN",
    ["Sets"] = "GROUP_SETS",
    ["Other"] = "GROUP_OTHER",
    ["Class"] = "GROUP_CLASS",
}

-- Get localized category name
function DefaultCategories:GetLocalizedName(categoryId, fallbackName)
    local localeKey = CATEGORY_LOCALE_KEYS[categoryId]
    if localeKey and ns.L[localeKey] then
        return ns.L[localeKey]
    end
    return fallbackName or categoryId
end

-- Get localized group name
function DefaultCategories:GetLocalizedGroupName(groupId)
    local localeKey = GROUP_LOCALE_KEYS[groupId]
    if localeKey and ns.L[localeKey] then
        return ns.L[localeKey]
    end
    return groupId
end

-- Get English group ID from localized name
function DefaultCategories:GetGroupIdFromLocalized(localizedName)
    for groupId, localeKey in pairs(GROUP_LOCALE_KEYS) do
        if ns.L[localeKey] == localizedName or groupId == localizedName then
            return groupId
        end
    end
    return localizedName -- Return as-is if not a known group
end

-- Get all localized group names
function DefaultCategories:GetLocalizedGroupNames()
    return {
        { id = "Sets", name = self:GetLocalizedGroupName("Sets") },
        { id = "Main", name = self:GetLocalizedGroupName("Main") },
        { id = "Other", name = self:GetLocalizedGroupName("Other") },
        { id = "Class", name = self:GetLocalizedGroupName("Class") },
    }
end

-- Category definitions matching original Guda addon
DefaultCategories.DEFINITIONS = {
    ["Home"] = {
        name = "Home",
        icon = "Interface\\Icons\\INV_Misc_Rune_01",
        rules = {
            { type = "itemID", value = {6948, 260221} },
        },
        matchMode = "any",
        priority = 100,
        enabled = true,
        isBuiltIn = true,
        group = "Other",
    },

    ["Recent"] = {
        name = "Recent",
        icon = "Interface\\Icons\\INV_Misc_PocketWatch_01",
        rules = {
            { type = "isRecent", value = 5 },  -- Duration in minutes
        },
        matchMode = "all",
        priority = 200,  -- Highest priority, shows first
        enabled = true,
        isBuiltIn = true,
        group = "",
    },

    ["BoE"] = {
        name = "BoE",
        icon = "Interface\\Icons\\INV_Misc_Orb_01",
        rules = {
            { type = "isBoE", value = true },
        },
        matchMode = "all",
        priority = 75,
        enabled = true,
        isBuiltIn = true,
        group = "Main",
    },

    ["Weapon"] = {
        name = "Weapon",
        icon = "Interface\\Icons\\INV_Sword_04",
        rules = {
            { type = "itemType", value = "Weapon" },
        },
        matchMode = "all",
        priority = 70,
        enabled = true,
        isBuiltIn = true,
        group = "Main",
    },

    ["Armor"] = {
        name = "Armor",
        icon = "Interface\\Icons\\INV_Chest_Chain",
        rules = {
            { type = "itemType", value = "Armor" },
        },
        matchMode = "all",
        priority = 70,
        enabled = true,
        isBuiltIn = true,
        group = "Main",
    },

    ["Warbound"] = {
        name = "Warbound",
        icon = "Interface\\Icons\\INV_Misc_Book_16",
        rules = {
            { type = "isWarbound", value = true },
        },
        matchMode = "all",
        priority = 76,
        enabled = true,
        isBuiltIn = true,
        group = "Main",
    },

    ["Consumable"] = {
        name = "Consumable",
        icon = "Interface\\Icons\\INV_Potion_54",
        rules = {
            { type = "itemType", value = "Consumable" },
        },
        matchMode = "all",
        priority = 50,
        enabled = true,
        isBuiltIn = true,
        group = "",
    },

    ["Food"] = {
        name = "Food",
        icon = "Interface\\Icons\\INV_Misc_Food_14",
        rules = {
            { type = "itemType", value = "Consumable" },
            { type = "restoreTag", value = "eat" },
        },
        matchMode = "all",
        priority = 55,
        enabled = true,
        isBuiltIn = true,
        group = "",
    },

    ["Drink"] = {
        name = "Drink",
        icon = "Interface\\Icons\\INV_Drink_07",
        rules = {
            { type = "itemType", value = "Consumable" },
            { type = "restoreTag", value = "drink" },
        },
        matchMode = "all",
        priority = 55,
        enabled = true,
        isBuiltIn = true,
        group = "",
    },

    ["Trade Goods"] = {
        name = "Trade Goods",
        icon = "Interface\\Icons\\INV_Misc_Bomb_08",
        rules = {
            { type = "itemType", value = "Trade Goods" },
        },
        matchMode = "all",
        priority = 40,
        enabled = true,
        isBuiltIn = true,
        group = "Main",
    },

    ["Reagent"] = {
        name = "Reagent",
        icon = "Interface\\Icons\\INV_Misc_Dust_02",
        rules = {
            { type = "isReagent", value = true },
        },
        matchMode = "all",
        priority = 42,  -- Higher than Trade Goods to catch crafting materials first
        enabled = true,
        isBuiltIn = true,
        group = "Main",
    },

    ["Recipe"] = {
        name = "Recipe",
        icon = "Interface\\Icons\\INV_Scroll_03",
        rules = {
            { type = "itemType", value = "Recipe" },
        },
        matchMode = "all",
        priority = 40,
        enabled = true,
        isBuiltIn = true,
        group = "Main",
    },

    ["Quiver Bag"] = {
        name = "Quiver Bag",
        icon = "Interface\\Icons\\INV_Misc_Quiver_03",
        rules = {
            { type = "itemType", value = "Quiver" },
        },
        matchMode = "all",
        priority = 40,
        enabled = true,
        isBuiltIn = true,
        group = "Main",
    },

    ["Container"] = {
        name = "Container",
        icon = "Interface\\Icons\\INV_Misc_Bag_07",
        rules = {
            { type = "itemType", value = "Container" },
        },
        matchMode = "all",
        priority = 40,
        enabled = true,
        isBuiltIn = true,
        group = "Main",
    },

    ["Soul Bag"] = {
        name = "Soul Bag",
        icon = "Interface\\Icons\\INV_Misc_Bag_EnchantedMageweave",
        rules = {
            { type = "itemSubtype", value = "Soul Bag" },
        },
        matchMode = "all",
        priority = 45,
        enabled = true,
        isBuiltIn = true,
        group = "Main",
    },

    ["Tools"] = {
        name = "Tools",
        icon = "Interface\\Icons\\INV_Pick_02",
        rules = {
            { type = "isProfessionTool", value = true },
            -- Tools the heuristic misses (e.g. Zapthrottle Mote Extractor).
            { type = "itemID", value = {23821} },
        },
        matchMode = "any",
        priority = 60,
        enabled = true,
        isBuiltIn = true,
        group = "Other",
    },

    ["Miscellaneous"] = {
        name = "Miscellaneous",
        icon = "Interface\\Icons\\INV_Misc_Rune_01",
        rules = {},
        matchMode = "any",
        priority = 0,
        enabled = true,
        isBuiltIn = true,
        isFallback = true,
        group = "Main",
    },

    ["Quest"] = {
        name = "Quest",
        icon = "Interface\\Icons\\INV_Misc_Book_08",
        rules = {
            { type = "isQuestItem", value = true },
        },
        matchMode = "all",
        priority = 80,
        enabled = true,
        isBuiltIn = true,
        group = "Main",
    },

    ["Junk"] = {
        name = "Junk",
        icon = "Interface\\Icons\\INV_Misc_Gear_06",
        rules = {
            { type = "isJunk", value = true },
        },
        matchMode = "any",
        priority = 85,
        enabled = true,
        isBuiltIn = true,
        group = "Main",
    },

    ["Class Items"] = {
        name = "Class Items",
        icon = "Interface\\Icons\\INV_Misc_Ammo_Arrow_01",
        rules = {
            { type = "itemType", value = "Projectile" },
            { type = "isSoulShard", value = true },
        },
        matchMode = "any",
        priority = 90,
        enabled = true,
        isBuiltIn = true,
        group = "Class",
    },

    ["Keyring"] = {
        name = "Keyring",
        icon = "Interface\\Icons\\INV_Misc_Key_04",
        rules = {
            { type = "itemType", value = "Key" },
        },
        matchMode = "all",
        priority = 40,
        enabled = true,
        isBuiltIn = true,
        group = "Class",
    },

    ["Empty"] = {
        name = "Empty",
        icon = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Bag",
        rules = {},
        matchMode = "any",
        priority = -10,  -- Lowest priority, appears last
        enabled = true,
        isBuiltIn = true,
        isEmptyCategory = true,  -- Special flag for empty slot handling
        group = "Other",
        hideControls = true,  -- Don't show in category editor
    },

    ["Soul"] = {
        name = "Soul",
        icon = "Interface\\Icons\\INV_Misc_Gem_Amethyst_02",
        rules = {},  -- No rules - this is a pseudo-category for empty soul bag slots only
        matchMode = "any",
        priority = -10,  -- Same as Empty - lowest priority, only for empty slot display
        enabled = true,
        isBuiltIn = true,
        isSoulCategory = true,  -- Special flag for soul bag empty slot handling
        group = "Other",
        hideControls = true,  -- Don't show in category editor
    },

    ["Quiver"] = {
        name = "Quiver",
        icon = "Interface\\AddOns\\GudaBags\\Assets\\quiver.tga",
        rules = {},  -- No rules - this is a pseudo-category for empty quiver/ammo bag slots only
        matchMode = "any",
        priority = -10,  -- Same as Empty - lowest priority, only for empty slot display
        enabled = true,
        isBuiltIn = true,
        isQuiverCategory = true,  -- Special flag for quiver/ammo bag empty slot handling
        group = "Other",
        hideControls = true,  -- Don't show in category editor
    },
}

-- Remove expansion-specific categories based on feature availability
if not Expansion.Features.HasKeyring then
    DefaultCategories.DEFINITIONS["Keyring"] = nil
end
if not Expansion.Features.HasQuiverBags then
    DefaultCategories.DEFINITIONS["Quiver Bag"] = nil
    DefaultCategories.DEFINITIONS["Quiver"] = nil
end
if not Expansion.IsRetail then
    DefaultCategories.DEFINITIONS["Warbound"] = nil
end

-- Class Items category only enabled by default for Hunters and Warlocks
-- Quiver category only enabled by default for Hunters
-- Soul Bag category only enabled by default for Warlocks
local _, playerClass = UnitClass("player")
if playerClass ~= "HUNTER" and playerClass ~= "WARLOCK" then
    DefaultCategories.DEFINITIONS["Class Items"].enabled = false
end
if playerClass ~= "HUNTER" then
    if DefaultCategories.DEFINITIONS["Quiver Bag"] then
        DefaultCategories.DEFINITIONS["Quiver Bag"].enabled = false
    end
    if DefaultCategories.DEFINITIONS["Quiver"] then
        DefaultCategories.DEFINITIONS["Quiver"].enabled = false
    end
end
if playerClass ~= "WARLOCK" then
    DefaultCategories.DEFINITIONS["Soul Bag"].enabled = false
end

-- Order matching original Guda addon
-- Built dynamically based on expansion
DefaultCategories.ORDER = {
    "Recent",
    "Food",
    "Drink",
    "Consumable",
    "BoE",
    "Weapon",
    "Armor",
    "Warbound",
    "Trade Goods",
    "Reagent",
    "Recipe",
}

-- Quiver Bag category for expansions that have it (catches actual quiver/ammo bag items)
if Expansion.Features.HasQuiverBags then
    table.insert(DefaultCategories.ORDER, "Quiver Bag")
end

-- Continue with common categories
local commonOrderContinued = {
    "Container",
    "Soul Bag",
    "Miscellaneous",
    "Quest",
    "Junk",
    "Home",
    "Tools",
    "Empty",
    "Soul",
    "Quiver",
    "Class Items",
}
for _, cat in ipairs(commonOrderContinued) do
    table.insert(DefaultCategories.ORDER, cat)
end

-- Keyring category for expansions that have it
if Expansion.Features.HasKeyring then
    table.insert(DefaultCategories.ORDER, "Keyring")
end

-- Deep copy utility
local function DeepCopy(orig)
    local copy
    if type(orig) == "table" then
        copy = {}
        for k, v in pairs(orig) do
            copy[k] = DeepCopy(v)
        end
    else
        copy = orig
    end
    return copy
end

-- Cached defaults (built once, deep copied on each call)
local cachedDefaults = nil

local function BuildDefaults(self)
    local definitions = {}
    for id, def in pairs(self.DEFINITIONS) do
        definitions[id] = {}
        for k, v in pairs(def) do
            if type(v) == "table" then
                definitions[id][k] = {}
                for i, rule in ipairs(v) do
                    definitions[id][k][i] = {}
                    for rk, rv in pairs(rule) do
                        definitions[id][k][i][rk] = rv
                    end
                end
            else
                definitions[id][k] = v
            end
        end
    end

    local order = {}
    for i, id in ipairs(self.ORDER) do
        order[i] = id
    end

    return {
        definitions = definitions,
        order = order,
    }
end

function DefaultCategories:GetDefaults()
    -- Build cache on first call
    if not cachedDefaults then
        cachedDefaults = BuildDefaults(self)
    end

    -- Return a deep copy of the cached defaults
    return DeepCopy(cachedDefaults)
end

function DefaultCategories:InvalidateCache()
    cachedDefaults = nil
end
