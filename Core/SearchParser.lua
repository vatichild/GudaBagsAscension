local addonName, ns = ...

local SearchParser = {}
ns:RegisterModule("SearchParser", SearchParser)

-------------------------------------------------
-- Quality Aliases (name → quality number)
-------------------------------------------------
local QUALITY_ALIASES = {
    poor = 0, gray = 0, grey = 0, junk = 0, trash = 0,
    common = 1, white = 1,
    uncommon = 2, green = 2,
    rare = 3, blue = 3,
    epic = 4, purple = 4,
    legendary = 5, orange = 5,
    artifact = 6,
    heirloom = 7,
}

-------------------------------------------------
-- Equipment Slot Aliases (alias → INVTYPE constant)
-------------------------------------------------
local SLOT_ALIASES = {
    head = "INVTYPE_HEAD", helm = "INVTYPE_HEAD", helmet = "INVTYPE_HEAD",
    neck = "INVTYPE_NECK", necklace = "INVTYPE_NECK", amulet = "INVTYPE_NECK",
    shoulder = "INVTYPE_SHOULDER", shoulders = "INVTYPE_SHOULDER",
    chest = "INVTYPE_CHEST", robe = "INVTYPE_ROBE",
    waist = "INVTYPE_WAIST", belt = "INVTYPE_WAIST",
    legs = "INVTYPE_LEGS", pants = "INVTYPE_LEGS", leggings = "INVTYPE_LEGS",
    feet = "INVTYPE_FEET", boots = "INVTYPE_FEET",
    wrist = "INVTYPE_WRIST", bracers = "INVTYPE_WRIST", bracer = "INVTYPE_WRIST",
    hands = "INVTYPE_HAND", gloves = "INVTYPE_HAND", hand = "INVTYPE_HAND",
    finger = "INVTYPE_FINGER", ring = "INVTYPE_FINGER",
    trinket = "INVTYPE_TRINKET",
    cloak = "INVTYPE_CLOAK", back = "INVTYPE_CLOAK", cape = "INVTYPE_CLOAK",
    mainhand = "INVTYPE_WEAPONMAINHAND", ["main hand"] = "INVTYPE_WEAPONMAINHAND",
    offhand = "INVTYPE_WEAPONOFFHAND", ["off hand"] = "INVTYPE_WEAPONOFFHAND",
    holdable = "INVTYPE_HOLDABLE",
    shield = "INVTYPE_SHIELD",
    ranged = "INVTYPE_RANGED", gun = "INVTYPE_RANGEDRIGHT", bow = "INVTYPE_RANGED",
    wand = "INVTYPE_RANGEDRIGHT",
    tabard = "INVTYPE_TABARD",
    shirt = "INVTYPE_BODY",
    weapon = "INVTYPE_WEAPON", ["one-hand"] = "INVTYPE_WEAPON", onehand = "INVTYPE_WEAPON",
    ["two-hand"] = "INVTYPE_2HWEAPON", twohand = "INVTYPE_2HWEAPON",
}

-------------------------------------------------
-- Type Aliases (short → full item type)
-------------------------------------------------
local TYPE_ALIASES = {
    wpn = "Weapon", weapon = "Weapon", weapons = "Weapon",
    arm = "Armor", armor = "Armor", armour = "Armor",
    con = "Consumable", consumable = "Consumable", consumables = "Consumable",
    trd = "Trade Goods", trade = "Trade Goods", tradegood = "Trade Goods", tradegoods = "Trade Goods",
    qst = "Quest", quest = "Quest",
    recipe = "Recipe", recipes = "Recipe",
    container = "Container", bag = "Container", bags = "Container",
    misc = "Miscellaneous", miscellaneous = "Miscellaneous",
    reagent = "Reagent", reagents = "Reagent",
    gem = "Gem", gems = "Gem",
    glyph = "Glyph", glyphs = "Glyph",
    projectile = "Projectile",
    quiver = "Quiver",
}

-------------------------------------------------
-- Operator pattern: key<op>value
-- Supports: q:epic, q>=3, q>2, q<=4, q<5, q=3
-- Also: ilvl>200, lvl>60, t:weapon, st:leather, s:head, n:name
-------------------------------------------------

local strfind = string.find
local strlower = string.lower
local strsub = string.sub
local tonumber = tonumber

-- Parse a quality value (name or number) → quality integer or nil
local function ParseQuality(val)
    local num = tonumber(val)
    if num and num >= 0 and num <= 7 then
        return num
    end
    return QUALITY_ALIASES[strlower(val)]
end

-- Parse operator+value from ">=3", ">rare", "=epic", ":4", "<3", "<=2"
local function ParseComparison(rest)
    -- rest is everything after the operator key, e.g. ":epic", ">=3", ">200"
    local op, val

    if strsub(rest, 1, 2) == ">=" then
        op, val = ">=", strsub(rest, 3)
    elseif strsub(rest, 1, 2) == "<=" then
        op, val = "<=", strsub(rest, 3)
    elseif strsub(rest, 1, 1) == ">" then
        op, val = ">", strsub(rest, 2)
    elseif strsub(rest, 1, 1) == "<" then
        op, val = "<", strsub(rest, 2)
    elseif strsub(rest, 1, 1) == "=" then
        op, val = "=", strsub(rest, 2)
    elseif strsub(rest, 1, 1) == ":" then
        op, val = "=", strsub(rest, 2)
    else
        return nil, nil
    end

    return op, val
end

-- Compare two numbers with an operator string
local function CompareNum(actual, op, target)
    if not actual or not target then return false end
    if op == "=" then return actual == target end
    if op == ">=" then return actual >= target end
    if op == ">" then return actual > target end
    if op == "<=" then return actual <= target end
    if op == "<" then return actual < target end
    return false
end

-------------------------------------------------
-- ParseSearchInput(text) → parsed result table
-------------------------------------------------
function SearchParser:ParseSearchInput(text)
    if not text or text == "" then
        return nil
    end

    local result = {
        textSearch = nil,     -- remaining plain text for substring matching
        operators = {},       -- array of {type, op, value} parsed operators
        keywords = {},        -- array of keyword strings (boe, quest, new, usable, junk)
    }

    local textParts = {}

    -- Tokenize: split by spaces, process each token
    for token in text:gmatch("%S+") do
        local tokenLower = strlower(token)
        local handled = false

        -- Check standalone keywords first
        if tokenLower == "boe" or tokenLower == "bop" or tokenLower == "quest"
            or tokenLower == "new" or tokenLower == "usable" or tokenLower == "junk"
            or tokenLower == "openable" or tokenLower == "learnable" then
            table.insert(result.keywords, tokenLower)
            handled = true
        end

        if not handled then
            -- Try to parse as operator: key<comparison>value
            -- Patterns: q:epic, q>=3, ilvl>200, t:weapon, st:leather, s:head, n:text
            local key, rest

            -- Match key + rest (key is letters, rest starts with :, =, >, <)
            local s, e, k, r = strfind(token, "^(%a+)([><=:].+)$")
            if s then
                key = strlower(k)
                rest = r
            end

            if key then
                local op, val = ParseComparison(rest)
                if op and val and val ~= "" then
                    local valLower = strlower(val)

                    if key == "q" or key == "quality" then
                        local qVal = ParseQuality(val)
                        if qVal then
                            table.insert(result.operators, {type = "quality", op = op, value = qVal})
                            handled = true
                        end
                    elseif key == "t" or key == "type" then
                        local resolved = TYPE_ALIASES[valLower] or val
                        table.insert(result.operators, {type = "itemType", op = "=", value = resolved})
                        handled = true
                    elseif key == "st" or key == "subtype" then
                        table.insert(result.operators, {type = "itemSubType", op = "=", value = valLower})
                        handled = true
                    elseif key == "ilvl" or key == "itemlevel" then
                        local num = tonumber(val)
                        if num then
                            table.insert(result.operators, {type = "itemLevel", op = op, value = num})
                            handled = true
                        end
                    elseif key == "lvl" or key == "level" or key == "reqlvl" then
                        local num = tonumber(val)
                        if num then
                            table.insert(result.operators, {type = "itemMinLevel", op = op, value = num})
                            handled = true
                        end
                    elseif key == "s" or key == "slot" then
                        local resolved = SLOT_ALIASES[valLower]
                        if resolved then
                            table.insert(result.operators, {type = "equipSlot", op = "=", value = resolved})
                            handled = true
                        end
                    elseif key == "n" or key == "name" then
                        table.insert(result.operators, {type = "name", op = "=", value = valLower})
                        handled = true
                    end
                end
            end
        end

        if not handled then
            table.insert(textParts, token)
        end
    end

    -- Join remaining parts as plain text search
    if #textParts > 0 then
        result.textSearch = strlower(table.concat(textParts, " "))
    end

    -- Return nil if nothing was parsed
    if not result.textSearch and #result.operators == 0 and #result.keywords == 0 then
        return nil
    end

    return result
end

-------------------------------------------------
-- MatchOperator(operator, itemData) → boolean
-------------------------------------------------
function SearchParser:MatchOperator(operator, itemData)
    if not itemData then return false end

    local t = operator.type

    if t == "quality" then
        return CompareNum(itemData.quality or 0, operator.op, operator.value)

    elseif t == "itemType" then
        if not itemData.itemType then return false end
        return strlower(itemData.itemType) == strlower(operator.value)

    elseif t == "itemSubType" then
        if not itemData.itemSubType then return false end
        return strfind(strlower(itemData.itemSubType), operator.value, 1, true) ~= nil

    elseif t == "itemLevel" then
        return CompareNum(itemData.itemLevel or 0, operator.op, operator.value)

    elseif t == "itemMinLevel" then
        return CompareNum(itemData.itemMinLevel or 0, operator.op, operator.value)

    elseif t == "equipSlot" then
        if not itemData.equipSlot or itemData.equipSlot == "" then return false end
        -- Handle multiple possible slot types (e.g. INVTYPE_WEAPON matches INVTYPE_WEAPON, INVTYPE_WEAPONMAINHAND, etc.)
        return itemData.equipSlot == operator.value

    elseif t == "name" then
        if not itemData.name then return false end
        return strfind(strlower(itemData.name), operator.value, 1, true) ~= nil
    end

    return false
end

-------------------------------------------------
-- MatchKeyword(keyword, itemData, context) → boolean
-- context: { tooltipScanner, recentItems }
-------------------------------------------------
function SearchParser:MatchKeyword(keyword, itemData, context)
    if not itemData then return false end

    if keyword == "boe" then
        -- Need tooltip scanner and bag/slot info
        if context and context.tooltipScanner and itemData.bagID and itemData.slot then
            return context.tooltipScanner:IsBindOnEquip(itemData.bagID, itemData.slot, itemData)
        end
        return false

    elseif keyword == "bop" then
        -- Soulbound items: already bound, so NOT BoE and has equip slot or is bound
        if itemData.quality and itemData.quality >= 2 then
            if context and context.tooltipScanner and itemData.bagID and itemData.slot then
                return not context.tooltipScanner:IsBindOnEquip(itemData.bagID, itemData.slot, itemData)
                    and (itemData.equipSlot and itemData.equipSlot ~= "")
            end
        end
        return false

    elseif keyword == "quest" then
        return itemData.isQuestItem == true
            or (itemData.itemType and strlower(itemData.itemType) == "quest")

    elseif keyword == "new" then
        if context and context.recentItems and itemData.itemID then
            return context.recentItems:IsRecent(itemData.itemID)
        end
        return false

    elseif keyword == "usable" then
        return itemData.isUsable == true

    elseif keyword == "junk" then
        return (itemData.quality or 0) == 0

    elseif keyword == "openable" then
        -- Loot containers (chest/cache/box/lockbox) flagged at scan time via the
        -- ITEM_OPENABLE tooltip line. Excludes equippable bags.
        return itemData.isOpenable == true

    elseif keyword == "learnable" then
        -- Recipe item class (recipes/patterns/plans/formulae/schematics/manuals).
        -- Uses classID (locale-independent) rather than the localized itemType string.
        return itemData.classID == 9
    end

    return false
end

-------------------------------------------------
-- MatchesTextSearch(itemData, textSearch) → boolean
-- Plain substring match against name/type/subtype
-------------------------------------------------
function SearchParser:MatchesTextSearch(itemData, textSearch)
    if not textSearch or textSearch == "" then return true end
    if not itemData then return false end

    if itemData.name and strfind(strlower(itemData.name), textSearch, 1, true) then
        return true
    end
    if itemData.itemType and strfind(strlower(itemData.itemType), textSearch, 1, true) then
        return true
    end
    if itemData.itemSubType and strfind(strlower(itemData.itemSubType), textSearch, 1, true) then
        return true
    end

    return false
end

-------------------------------------------------
-- MatchesParsed(parsed, itemData, context) → boolean
-- Check all operators + keywords + text against one item
-------------------------------------------------
function SearchParser:MatchesParsed(parsed, itemData, context)
    if not parsed then return true end
    if not itemData then return false end

    -- All operators must match (AND)
    for _, op in ipairs(parsed.operators) do
        if not self:MatchOperator(op, itemData) then
            return false
        end
    end

    -- All keywords must match (AND)
    for _, kw in ipairs(parsed.keywords) do
        if not self:MatchKeyword(kw, itemData, context) then
            return false
        end
    end

    -- Text search must match
    if not self:MatchesTextSearch(itemData, parsed.textSearch) then
        return false
    end

    return true
end
