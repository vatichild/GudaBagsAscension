local addonName, ns = ...

local CategoryManager = {}
ns:RegisterModule("CategoryManager", CategoryManager)

local Constants = ns.Constants
local DefaultCategories = ns.DefaultCategories

-- Performance: Cache sorted categories by priority
local cachedCategoriesByPriority = nil
local cachedCategoryVersion = 0  -- Incremented when categories change

-- Performance: Cache category results per item key
-- Key: itemKey (link:quality:bound) -> categoryId
local categoryResultCache = {}
local categoryResultCacheVersion = 0  -- Matches cachedCategoryVersion when valid

-------------------------------------------------
-- Rule Evaluation (delegates to RuleEngine)
-------------------------------------------------

function CategoryManager:EvaluateRule(rule, itemData, bagID, slotID, isOtherChar)
    local RuleEngine = ns:GetModule("RuleEngine")
    if not RuleEngine then
        return false
    end

    local context = RuleEngine:BuildContext(bagID, slotID, isOtherChar)
    return RuleEngine:Evaluate(rule, itemData, context)
end

function CategoryManager:EvaluateCategoryRules(categoryDef, itemData, bagID, slotID, isOtherChar)
    if not categoryDef.enabled then
        return false
    end

    local rules = categoryDef.rules or {}

    if #rules == 0 then
        return categoryDef.isFallback == true
    end

    local RuleEngine = ns:GetModule("RuleEngine")
    if not RuleEngine then
        return false
    end

    local context = RuleEngine:BuildContext(bagID, slotID, isOtherChar)
    local matchMode = categoryDef.matchMode or "any"

    return RuleEngine:EvaluateAll(rules, itemData, context, matchMode)
end

-------------------------------------------------
-- Category Management
-------------------------------------------------

-- Migration map for old category IDs to new IDs
local CATEGORY_MIGRATION = {
    ["Hearthstone"] = "Home",
    ["Quest Items"] = "Quest",
    ["TradeGoods"] = "Trade Goods",
    ["SoulShard"] = "Soul Bag",
    ["Projectile"] = "Class Items",
    ["Key"] = "Keyring",
    ["Weapons"] = "Weapon",
    ["Consumables"] = "Consumable",
    ["Reagents"] = "Reagent",
    ["Recipes"] = "Recipe",
    ["Containers"] = "Container",
    ["Quivers"] = "Quiver",
    ["Keys"] = "Keyring",
    ["Gems"] = nil, -- Remove Gems category
    ["Ammunition"] = "Class Items",
}

function CategoryManager:MigrateCategories(categories)
    local defaults = DefaultCategories:GetDefaults()
    local migrated = false

    -- Migrate definitions
    for oldId, newId in pairs(CATEGORY_MIGRATION) do
        if categories.definitions[oldId] then
            if newId and not categories.definitions[newId] then
                categories.definitions[newId] = categories.definitions[oldId]
                categories.definitions[newId].name = defaults.definitions[newId] and defaults.definitions[newId].name or newId
            end
            categories.definitions[oldId] = nil
            migrated = true
        end
    end

    -- Add missing built-in categories
    for id, def in pairs(defaults.definitions) do
        if not categories.definitions[id] then
            categories.definitions[id] = def
            migrated = true
        end
    end

    -- Migrate category names to match defaults
    local NAME_MIGRATIONS = {
        ["BoE"] = "BoE",  -- was "Bind on Equip"
    }
    for id, newName in pairs(NAME_MIGRATIONS) do
        local cat = categories.definitions[id]
        if cat and cat.isBuiltIn and cat.name ~= newName then
            cat.name = newName
            migrated = true
        end
    end

    -- Update Home category with hearthstone rules if missing, remove hideControls
    local homeCat = categories.definitions["Home"]
    if homeCat and homeCat.isBuiltIn then
        local hasRules = homeCat.rules and #homeCat.rules > 0
        if not hasRules then
            homeCat.rules = {{ type = "itemID", value = {6948, 260221} }}
            homeCat.matchMode = "any"
            homeCat.priority = 100
            migrated = true
        end
        if homeCat.hideControls then
            homeCat.hideControls = nil
            migrated = true
        end
    end

    -- Update Recent category: remove hideControls and convert old boolean rule to duration
    local recentCat = categories.definitions["Recent"]
    if recentCat and recentCat.isBuiltIn then
        -- Remove hideControls so Recent can be edited
        if recentCat.hideControls then
            recentCat.hideControls = nil
            migrated = true
        end
        -- Convert old rule format { type = "isRecent", value = true } to new format with duration
        if recentCat.rules and #recentCat.rules > 0 then
            for _, rule in ipairs(recentCat.rules) do
                if rule.type == "isRecent" and rule.value == true then
                    -- Get current duration from settings, fallback to 5 minutes
                    local Database = ns:GetModule("Database")
                    local duration = Database and Database:GetSetting("recentDuration") or 5
                    rule.value = duration
                    migrated = true
                end
            end
        end
    end

    -- Ungrouped built-in categories (always at top, no group)
    local ungroupedCategories = {
        "Recent", "Food", "Drink", "Consumable"
    }
    for _, catId in ipairs(ungroupedCategories) do
        local cat = categories.definitions[catId]
        if cat and cat.isBuiltIn and (cat.group == nil or cat.group == "Main" or cat.group == "Recent" or cat.group == "Consumables") then
            cat.group = ""
            migrated = true
        end
    end

    -- Add Main group to built-in categories (nil = never had a group, "" = intentionally ungrouped)
    local mainGroupCategories = {
        "Warbound", "BoE", "Weapon", "Armor",
        "Trade Goods", "Reagent", "Recipe", "Quiver", "Container",
        "Soul Bag", "Miscellaneous", "Quest", "Junk"
    }
    for _, catId in ipairs(mainGroupCategories) do
        local cat = categories.definitions[catId]
        if cat and cat.isBuiltIn and cat.group == nil then
            cat.group = "Main"
            migrated = true
        end
    end

    -- Add Other group to remaining built-in categories
    local otherGroupCategories = {
        "Home", "Tools"
    }
    for _, catId in ipairs(otherGroupCategories) do
        local cat = categories.definitions[catId]
        if cat and cat.isBuiltIn and cat.group == nil then
            cat.group = "Other"
            migrated = true
        end
    end

    -- Add Class group to class-specific categories (only if no group or old "Character" group)
    local classGroupCategories = {
        "Class Items", "Keyring"
    }
    for _, catId in ipairs(classGroupCategories) do
        local cat = categories.definitions[catId]
        if cat and cat.isBuiltIn then
            -- Only migrate from nil or old "Character" group name, not from "" (intentionally ungrouped)
            if cat.group == nil or cat.group == "Character" then
                cat.group = "Class"
                migrated = true
            end
        end
    end

    -- Migrate custom categories with old priority (50) to new default (95)
    for catId, cat in pairs(categories.definitions) do
        if not cat.isBuiltIn and cat.priority == 50 then
            cat.priority = 95
            migrated = true
        end
    end

    -- Add default group to custom categories without a group (nil only, not "" which is intentional)
    for catId, cat in pairs(categories.definitions) do
        if not cat.isBuiltIn and cat.group == nil then
            cat.group = "Main"
            migrated = true
        end
    end

    -- Rebuild order with new IDs
    if migrated then
        local newOrder = {}
        local seen = {}

        -- First add categories from defaults order that exist
        for _, id in ipairs(defaults.order) do
            if categories.definitions[id] and not seen[id] then
                table.insert(newOrder, id)
                seen[id] = true
            end
        end

        -- Then add any remaining custom categories
        for _, id in ipairs(categories.order or {}) do
            local actualId = CATEGORY_MIGRATION[id] or id
            if categories.definitions[actualId] and not seen[actualId] then
                table.insert(newOrder, actualId)
                seen[actualId] = true
            end
        end

        categories.order = newOrder
    end

    return migrated
end

function CategoryManager:GetCategories()
    local Database = ns:GetModule("Database")
    local categories = Database:GetCategories()

    if not categories then
        categories = DefaultCategories:GetDefaults()
        Database:SetCategories(categories)
    else
        -- Check if migration is needed
        if self:MigrateCategories(categories) then
            Database:SetCategories(categories)
        end
    end

    return categories
end

function CategoryManager:GetCategory(categoryId)
    local categories = self:GetCategories()
    return categories.definitions[categoryId]
end

function CategoryManager:GetCategoryOrder()
    local categories = self:GetCategories()
    return categories.order or {}
end

function CategoryManager:GetCategoriesByPriority()
    -- Return cached result if valid
    if cachedCategoriesByPriority then
        return cachedCategoriesByPriority
    end

    local categories = self:GetCategories()
    local sorted = {}

    for id, def in pairs(categories.definitions) do
        if def.enabled then
            table.insert(sorted, { id = id, def = def })
        end
    end

    table.sort(sorted, function(a, b)
        return (a.def.priority or 0) > (b.def.priority or 0)
    end)

    -- Cache the result
    cachedCategoriesByPriority = sorted
    return sorted
end

-- Invalidate priority cache (called when categories change)
function CategoryManager:InvalidatePriorityCache()
    cachedCategoriesByPriority = nil
    cachedCategoryVersion = cachedCategoryVersion + 1
end

-- Generate cache key for item categorization
-- Uses itemLink + quality + bound status (same as GetItemKey in BagFrame)
local function GetItemCacheKey(itemData)
    if not itemData then return nil end
    local link = itemData.link or ""
    local quality = itemData.quality or 0
    local isBound = itemData.isBound and "1" or "0"
    return link .. ":" .. quality .. ":" .. isBound
end

function CategoryManager:CategorizeItem(itemData, bagID, slotID, isOtherChar)
    -- Check item overrides first (for manually assigned items)
    if itemData and itemData.itemID then
        local categories = self:GetCategories()
        if categories.itemOverrides and categories.itemOverrides[itemData.itemID] then
            local overrideCategory = categories.itemOverrides[itemData.itemID]
            -- Verify the category still exists and is enabled
            local catDef = categories.definitions[overrideCategory]
            if catDef and catDef.enabled then
                return overrideCategory
            end
        end
    end

    -- Equipment set categories (higher priority than rule-based matching)
    if itemData and itemData.itemID then
        local Database = ns:GetModule("Database")
        if Database and Database:GetSetting("showEquipSetCategories") then
            local EquipmentSets = ns:GetModule("EquipmentSets")
            if EquipmentSets and EquipmentSets:IsInSet(itemData.itemID) then
                local setNames = EquipmentSets:GetSetNames(itemData.itemID)
                if setNames and #setNames > 0 then
                    table.sort(setNames)
                    local catId = "EquipSet:" .. setNames[1]
                    local catDef = self:GetCategory(catId)
                    if catDef and catDef.enabled then
                        return catId
                    end
                end
            end
        end
    end

    -- Try to use cached result for this item
    local cacheKey = GetItemCacheKey(itemData)
    if cacheKey and categoryResultCacheVersion == cachedCategoryVersion then
        local cached = categoryResultCache[cacheKey]
        if cached then
            return cached
        end
    elseif categoryResultCacheVersion ~= cachedCategoryVersion then
        -- Categories changed, clear result cache
        categoryResultCache = {}
        categoryResultCacheVersion = cachedCategoryVersion
    end

    local sortedCats = self:GetCategoriesByPriority()

    for _, entry in ipairs(sortedCats) do
        if not entry.def.isFallback then
            if self:EvaluateCategoryRules(entry.def, itemData, bagID, slotID, isOtherChar) then
                -- Cache the result
                if cacheKey then
                    categoryResultCache[cacheKey] = entry.id
                end
                return entry.id
            end
        end
    end

    -- Cache fallback result
    if cacheKey then
        categoryResultCache[cacheKey] = "Miscellaneous"
    end
    return "Miscellaneous"
end

-- Clear the item category cache (called externally if needed)
function CategoryManager:ClearCategoryCache()
    categoryResultCache = {}
end

-- Sync equipment set categories into saved category data
-- Adds new sets, removes stale ones. Preserves user edits (group, priority, order).
function CategoryManager:SyncEquipmentSetCategories()
    local Database = ns:GetModule("Database")
    if not Database then return end

    local categories = self:GetCategories()
    local EquipmentSets = ns:GetModule("EquipmentSets")
    local showSetting = Database:GetSetting("showEquipSetCategories")

    -- Collect active set names
    local activeSetIds = {}
    if showSetting and EquipmentSets then
        local names = EquipmentSets:GetAllSetNames()
        for _, name in ipairs(names) do
            activeSetIds["EquipSet:" .. name] = true
        end
    end

    local changed = false

    -- Remove equipment set categories that no longer exist or setting is off
    -- Preserve user-edited properties so they can be restored if the category is recreated
    categories.savedEquipSetProps = categories.savedEquipSetProps or {}
    local toRemove = {}
    for catId, def in pairs(categories.definitions) do
        if def.isEquipSet and not activeSetIds[catId] then
            table.insert(toRemove, catId)
        end
    end
    for _, catId in ipairs(toRemove) do
        local def = categories.definitions[catId]
        if def then
            categories.savedEquipSetProps[catId] = {
                categoryMark = def.categoryMark,
                group = def.group,
                enabled = def.enabled,
                priority = def.priority,
            }
        end
        categories.definitions[catId] = nil
        for i, id in ipairs(categories.order) do
            if id == catId then
                table.remove(categories.order, i)
                break
            end
        end
        changed = true
    end

    -- Add new equipment set categories
    for catId in pairs(activeSetIds) do
        if not categories.definitions[catId] then
            local setName = catId:sub(10)
            local saved = categories.savedEquipSetProps and categories.savedEquipSetProps[catId]
            local restoredEnabled = true
            if saved and saved.enabled ~= nil then
                restoredEnabled = saved.enabled
            end
            categories.definitions[catId] = {
                name = setName,
                icon = "Interface\\PaperDollInfoFrame\\PaperDollSidebarTabs",
                group = saved and saved.group or "Sets",
                enabled = restoredEnabled,
                isEquipSet = true,
                isBuiltIn = false,
                rules = {},
                matchMode = "any",
                priority = saved and saved.priority or 95,
                categoryMark = saved and saved.categoryMark or "Interface\\AddOns\\GudaBags\\Assets\\equipment.tga",
            }
            -- Clean up saved props after restoring
            if categories.savedEquipSetProps then
                categories.savedEquipSetProps[catId] = nil
            end
            -- Insert after Consumable category so Sets group appears before Main
            local insertIdx = #categories.order + 1
            for i, id in ipairs(categories.order) do
                if id == "Consumable" then
                    insertIdx = i + 1
                    break
                end
            end
            table.insert(categories.order, insertIdx, catId)
            changed = true
        end
    end

    if changed then
        Database:SetCategories(categories)
    end
end

function CategoryManager:UpdateCategory(categoryId, newDef)
    local categories = self:GetCategories()
    if categories.definitions[categoryId] then
        for k, v in pairs(newDef) do
            categories.definitions[categoryId][k] = v
        end
        self:SaveCategories(categories)
        return true
    end
    return false
end

function CategoryManager:ToggleCategory(categoryId)
    local categories = self:GetCategories()
    local def = categories.definitions[categoryId]
    if def then
        def.enabled = not def.enabled
        self:SaveCategories(categories)
        return def.enabled
    end
    return nil
end

function CategoryManager:MoveCategoryUp(categoryId)
    local categories = self:GetCategories()
    local order = categories.order
    local catDef = categories.definitions[categoryId]
    if not catDef then return false end

    local currentGroup = catDef.group or ""

    -- Find position and check if first in group
    local catIndex = nil
    local isFirstInGroup = true
    for i, id in ipairs(order) do
        if id == categoryId then
            catIndex = i
            break
        end
        local def = categories.definitions[id]
        if def and (def.group or "") == currentGroup then
            isFirstInGroup = false
        end
    end

    if not catIndex then return false end

    if not isFirstInGroup then
        -- Simple swap within group
        if catIndex > 1 then
            order[catIndex], order[catIndex-1] = order[catIndex-1], order[catIndex]
            self:SaveCategories(categories)
            return true
        end
    else
        -- First in group - move to previous group
        local prevGroup = self:GetPreviousGroup(currentGroup)
        if prevGroup then
            catDef.group = prevGroup
            -- Move to end of previous group
            table.remove(order, catIndex)
            local insertIdx = #order + 1
            for i = #order, 1, -1 do
                local def = categories.definitions[order[i]]
                if def and (def.group or "") == prevGroup then
                    insertIdx = i + 1
                    break
                end
            end
            table.insert(order, insertIdx, categoryId)
            self:SaveCategories(categories)
            return true
        end
    end
    return false
end

function CategoryManager:MoveCategoryDown(categoryId)
    local categories = self:GetCategories()
    local order = categories.order
    local catDef = categories.definitions[categoryId]
    if not catDef then return false end

    local currentGroup = catDef.group or ""

    -- Find position and check if last in group
    local catIndex = nil
    local isLastInGroup = true
    for i, id in ipairs(order) do
        if id == categoryId then
            catIndex = i
        elseif catIndex then
            local def = categories.definitions[id]
            if def and (def.group or "") == currentGroup then
                isLastInGroup = false
                break
            end
        end
    end

    if not catIndex then return false end

    if not isLastInGroup then
        -- Simple swap within group
        if catIndex < #order then
            order[catIndex], order[catIndex+1] = order[catIndex+1], order[catIndex]
            self:SaveCategories(categories)
            return true
        end
    else
        -- Last in group - move to next group
        local nextGroup = self:GetNextGroup(currentGroup)
        if nextGroup then
            catDef.group = nextGroup
            -- Move to beginning of next group
            table.remove(order, catIndex)
            local insertIdx = #order + 1
            for i, id in ipairs(order) do
                local def = categories.definitions[id]
                if def and (def.group or "") == nextGroup then
                    insertIdx = i
                    break
                end
            end
            table.insert(order, insertIdx, categoryId)
            self:SaveCategories(categories)
            return true
        end
    end
    return false
end

-- Helper to get ordered list of groups
function CategoryManager:GetGroupOrder()
    local categories = self:GetCategories()
    local groupOrder = {}
    local seen = {}

    for _, catId in ipairs(categories.order) do
        local def = categories.definitions[catId]
        if def then
            local group = def.group or ""
            if group ~= "" and not seen[group] then
                table.insert(groupOrder, group)
                seen[group] = true
            end
        end
    end

    return groupOrder
end

-- Get previous group in order
function CategoryManager:GetPreviousGroup(currentGroup)
    local groupOrder = self:GetGroupOrder()
    for i, group in ipairs(groupOrder) do
        if group == currentGroup and i > 1 then
            return groupOrder[i - 1]
        end
    end
    return nil
end

-- Get next group in order
function CategoryManager:GetNextGroup(currentGroup)
    local groupOrder = self:GetGroupOrder()
    for i, group in ipairs(groupOrder) do
        if group == currentGroup and i < #groupOrder then
            return groupOrder[i + 1]
        end
    end
    return nil
end

-- Check if category can move up
function CategoryManager:CanMoveUp(categoryId)
    local categories = self:GetCategories()
    local catDef = categories.definitions[categoryId]
    if not catDef then return false end

    local currentGroup = catDef.group or ""

    -- Check if first in group
    local isFirstInGroup = true
    for _, id in ipairs(categories.order) do
        if id == categoryId then
            break
        end
        local def = categories.definitions[id]
        if def and (def.group or "") == currentGroup then
            isFirstInGroup = false
        end
    end

    if not isFirstInGroup then
        return true -- Can move within group
    end

    -- First in group - check if there's a previous group
    return self:GetPreviousGroup(currentGroup) ~= nil
end

-- Check if category can move down
function CategoryManager:CanMoveDown(categoryId)
    local categories = self:GetCategories()
    local catDef = categories.definitions[categoryId]
    if not catDef then return false end

    local currentGroup = catDef.group or ""

    -- Check if last in group
    local catIndex = nil
    local isLastInGroup = true
    for i, id in ipairs(categories.order) do
        if id == categoryId then
            catIndex = i
        elseif catIndex then
            local def = categories.definitions[id]
            if def and (def.group or "") == currentGroup then
                isLastInGroup = false
                break
            end
        end
    end

    if not isLastInGroup then
        return true -- Can move within group
    end

    -- Last in group - check if there's a next group
    return self:GetNextGroup(currentGroup) ~= nil
end

function CategoryManager:AddCategory(name, icon, group)
    local categories = self:GetCategories()
    local targetGroup = group or "Main"

    local id = "Custom_" .. time() .. "_" .. math.random(1000, 9999)

    categories.definitions[id] = {
        name = name or "New Category",
        icon = icon or "Interface\\AddOns\\GudaBags\\Assets\\bags.tga",
        rules = {},
        matchMode = "any",
        priority = 95,
        enabled = true,
        isBuiltIn = false,
        group = targetGroup,
    }

    -- Find the last category in the target group to insert after it
    local insertIndex = nil
    for i, catId in ipairs(categories.order) do
        local catDef = categories.definitions[catId]
        if catDef and catDef.group == targetGroup then
            insertIndex = i + 1
        end
    end

    if insertIndex then
        table.insert(categories.order, insertIndex, id)
    else
        -- No categories in this group yet, add at end
        table.insert(categories.order, id)
    end

    self:SaveCategories(categories)
    return id
end

function CategoryManager:DeleteCategory(categoryId)
    local categories = self:GetCategories()
    local def = categories.definitions[categoryId]

    if not def then return false end
    if def.isBuiltIn then return false end

    categories.definitions[categoryId] = nil

    for i, id in ipairs(categories.order) do
        if id == categoryId then
            table.remove(categories.order, i)
            break
        end
    end

    self:SaveCategories(categories)
    return true
end

function CategoryManager:ResetToDefaults()
    local Database = ns:GetModule("Database")
    local categories = DefaultCategories:GetDefaults()
    Database:SetCategories(categories)

    -- Reset merged groups to default (empty = no groups merged)
    Database:SetSetting("mergedGroups", {})

    -- Re-sync equipment set categories so they aren't lost on reset
    self:SyncEquipmentSetCategories()

    -- Invalidate caches when categories reset
    self:InvalidatePriorityCache()

    local Events = ns:GetModule("Events")
    if Events then
        Events:Fire("CATEGORIES_UPDATED")
        Events:Fire("SETTING_CHANGED", "mergedGroups", {})
    end

    return categories
end

function CategoryManager:SaveCategories(categories)
    local Database = ns:GetModule("Database")
    Database:SetCategories(categories)

    -- Invalidate caches when categories change
    self:InvalidatePriorityCache()

    local Events = ns:GetModule("Events")
    if Events then
        Events:Fire("CATEGORIES_UPDATED")
    end
end

function CategoryManager:GetRuleTypes()
    return DefaultCategories:GetRuleTypes()
end

-------------------------------------------------
-- Item-to-Category Assignment
-------------------------------------------------

-- Assign a specific item to a category using item overrides (not category rules)
-- This avoids issues with matchMode="all" breaking other items in the category
function CategoryManager:AssignItemToCategory(itemID, categoryId)
    if not itemID or not categoryId then return false end

    local categories = self:GetCategories()
    local targetCategory = categories.definitions[categoryId]

    if not targetCategory then
        return false
    end

    -- Use itemOverrides map instead of adding rules to categories
    -- This is checked first in CategorizeItem and doesn't interfere with category rules
    categories.itemOverrides = categories.itemOverrides or {}
    categories.itemOverrides[itemID] = categoryId

    -- Remove from Recent when manually assigned to a category
    local RecentItems = ns:GetModule("RecentItems")
    if RecentItems then
        RecentItems:RemoveRecent(itemID)
    end

    self:SaveCategories(categories)
    return true
end

-- Remove an item-specific assignment from a category
function CategoryManager:RemoveItemFromCategory(itemID, categoryId)
    if not itemID then return false end

    local categories = self:GetCategories()
    local removed = false

    -- Remove from itemOverrides
    if categories.itemOverrides and categories.itemOverrides[itemID] then
        if not categoryId or categories.itemOverrides[itemID] == categoryId then
            categories.itemOverrides[itemID] = nil
            removed = true
        end
    end

    -- Also check legacy itemID rules in category definitions
    if categoryId then
        -- Remove from specific category
        local category = categories.definitions[categoryId]
        if category and category.rules then
            for i = #category.rules, 1, -1 do
                local rule = category.rules[i]
                if rule.type == "itemID" and rule.value == itemID then
                    table.remove(category.rules, i)
                    removed = true
                end
            end
        end
    else
        -- Remove from all categories
        for id, def in pairs(categories.definitions) do
            if def.rules then
                for i = #def.rules, 1, -1 do
                    local rule = def.rules[i]
                    if rule.type == "itemID" and rule.value == itemID then
                        table.remove(def.rules, i)
                        removed = true
                    end
                end
            end
        end
    end

    if removed then
        self:SaveCategories(categories)
        return true
    end

    return false
end

-------------------------------------------------
-- Category Display Helpers
-------------------------------------------------

function CategoryManager:GetEnabledCategories()
    local categories = self:GetCategories()
    local enabled = {}

    for _, id in ipairs(categories.order) do
        local def = categories.definitions[id]
        if def and def.enabled and not def.hideControls then
            table.insert(enabled, {
                id = id,
                name = def.name,
                icon = def.icon,
                priority = def.priority,
            })
        end
    end

    return enabled
end

function CategoryManager:CategorizeItems(items, isOtherChar)
    local categorized = {}
    local categories = self:GetCategories()

    for _, id in ipairs(categories.order) do
        local def = categories.definitions[id]
        if def and def.enabled then
            categorized[id] = {}
        end
    end

    for _, item in ipairs(items) do
        local categoryId = self:CategorizeItem(item.itemData, item.bagID, item.slotID, isOtherChar)
        if categorized[categoryId] then
            table.insert(categorized[categoryId], item)
        else
            if categorized["Miscellaneous"] then
                table.insert(categorized["Miscellaneous"], item)
            end
        end
    end

    return categorized
end

do
    local Events = ns:GetModule("Events")
    if Events then
        Events:Register("PROFILE_LOADED", function()
            CategoryManager:InvalidatePriorityCache()
        end, CategoryManager)
    end
end
