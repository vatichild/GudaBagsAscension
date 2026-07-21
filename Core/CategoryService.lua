local addonName, ns = ...

local CategoryService = {}
ns:RegisterModule("CategoryService", CategoryService)

local Constants = ns.Constants
local CategoryManager = ns:GetModule("CategoryManager")
local Database = ns:GetModule("Database")
local Events = ns:GetModule("Events")

-------------------------------------------------
-- Category Access
-------------------------------------------------

function CategoryService:GetCategories()
    return CategoryManager:GetCategories()
end

function CategoryService:GetCategory(categoryId)
    return CategoryManager:GetCategory(categoryId)
end

function CategoryService:GetCategoryOrder()
    return CategoryManager:GetCategoryOrder()
end

-------------------------------------------------
-- Category Mutations
-------------------------------------------------

function CategoryService:CreateCategory(name, group)
    return CategoryManager:AddCategory(name, nil, group)
end

function CategoryService:UpdateCategory(categoryId, changes)
    return CategoryManager:UpdateCategory(categoryId, changes)
end

function CategoryService:DeleteCategory(categoryId)
    return CategoryManager:DeleteCategory(categoryId)
end

function CategoryService:ToggleCategory(categoryId)
    return CategoryManager:ToggleCategory(categoryId)
end

function CategoryService:ResetToDefaults()
    return CategoryManager:ResetToDefaults()
end

-------------------------------------------------
-- Category Ordering
-------------------------------------------------

function CategoryService:MoveCategory(categoryId, targetIndex, targetGroup)
    local categories = CategoryManager:GetCategories()
    local order = categories.order
    local def = categories.definitions[categoryId]

    if not def then return false end

    -- Update group if specified
    if targetGroup then
        def.group = targetGroup
    end

    -- Find and remove from current position
    local currentIdx = nil
    for i, id in ipairs(order) do
        if id == categoryId then
            currentIdx = i
            break
        end
    end

    if currentIdx then
        table.remove(order, currentIdx)

        -- Adjust target index if needed
        if targetIndex > currentIdx then
            targetIndex = targetIndex - 1
        end
    end

    -- Insert at new position
    if targetIndex then
        table.insert(order, targetIndex, categoryId)
    else
        table.insert(order, categoryId)
    end

    CategoryManager:SaveCategories(categories)
    return true
end

function CategoryService:MoveCategoryUp(categoryId)
    return CategoryManager:MoveCategoryUp(categoryId)
end

function CategoryService:MoveCategoryDown(categoryId)
    return CategoryManager:MoveCategoryDown(categoryId)
end

-------------------------------------------------
-- Group Operations
-------------------------------------------------

function CategoryService:GetGroups()
    local categories = self:GetCategories()
    local groups = {}
    local seen = {}

    for _, categoryId in ipairs(categories.order) do
        local def = categories.definitions[categoryId]
        if def and def.group and def.group ~= "" and not seen[def.group] then
            table.insert(groups, def.group)
            seen[def.group] = true
        end
    end

    return groups
end

function CategoryService:GetCategoriesByGroup()
    local categories = self:GetCategories()
    local grouped = {}
    local ungrouped = {}

    for _, categoryId in ipairs(categories.order) do
        local def = categories.definitions[categoryId]
        if def then
            local group = def.group
            if group and group ~= "" then
                grouped[group] = grouped[group] or {}
                table.insert(grouped[group], categoryId)
            else
                table.insert(ungrouped, categoryId)
            end
        end
    end

    return grouped, ungrouped
end

function CategoryService:SetCategoryGroup(categoryId, groupName)
    local categories = self:GetCategories()
    local def = categories.definitions[categoryId]

    if def then
        def.group = groupName or ""
        CategoryManager:SaveCategories(categories)
        return true
    end

    return false
end

-------------------------------------------------
-- Group Settings
-------------------------------------------------

function CategoryService:GetGroupSettings()
    return {
        mergedGroups = Database:GetSetting("mergedGroups") or {},
    }
end

function CategoryService:SetGroupMerged(groupName, merged)
    local current = Database:GetSetting("mergedGroups") or {}
    current[groupName] = merged
    Database:SetSetting("mergedGroups", current)

    if Events then
        Events:Fire("SETTING_CHANGED", "mergedGroups", current)
    end
end

function CategoryService:IsGroupMerged(groupName)
    local mergedGroups = Database:GetSetting("mergedGroups") or {}
    return mergedGroups[groupName] == true
end

function CategoryService:SetAllGroupsMerged(merged)
    local groups = self:GetGroups()
    for _, groupName in ipairs(groups) do
        self:SetGroupMerged(groupName, merged)
    end
end

-------------------------------------------------
-- Rule Types
-------------------------------------------------

function CategoryService:GetRuleTypes()
    return CategoryManager:GetRuleTypes()
end

-------------------------------------------------
-- Categorization
-------------------------------------------------

function CategoryService:CategorizeItem(itemData, bagID, slotID, isOtherChar)
    return CategoryManager:CategorizeItem(itemData, bagID, slotID, isOtherChar)
end

function CategoryService:GetCategoriesByPriority()
    return CategoryManager:GetCategoriesByPriority()
end
