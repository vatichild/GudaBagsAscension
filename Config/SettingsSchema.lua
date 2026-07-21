local addonName, ns = ...

local SettingsSchema = {}
ns:RegisterModule("SettingsSchema", SettingsSchema)

-------------------------------------------------
-- General Tab Schema
-------------------------------------------------
function SettingsSchema.GetGeneral()
    local L = ns.L
    return {
        { type = "description", text = L["SETTINGS_GENERAL_DESCRIPTION"], height = 28 },
        { type = "separator", label = L["SETTINGS_SECTION_APPEARANCE"] },
        { type = "select", key = "theme", label = L["SETTINGS_THEME"], tooltip = L["SETTINGS_THEME_TIP"], options = (function()
            local opts = {
                { value = "guda", label = L["SETTINGS_THEME_GUDA"] },
            }
            -- The blizzard theme is built on ButtonFrameTemplate (Cataclysm 4.0)
            -- and its NineSlice/Bg children, none of which exist on 3.3.5a.
            if not ns.IsWrath then
                table.insert(opts, { value = "blizzard", label = L["SETTINGS_THEME_BLIZZARD"] })
            end
            -- Re-enabled on 3.3.5a after fixing the stale cached backdrop in
            -- Core\Theme.lua:EnsureIconBg that crashed the client when cycling
            -- themes. If the crash returns, drop it here again and re-add the
            -- "retail" coercion in Theme:Get.
            if not ns.IsRetail then
                table.insert(opts, { value = "retail", label = L["SETTINGS_THEME_RETAIL"] })
            end
            return opts
        end)()},
        { type = "select", key = "fontFamily", label = L["SETTINGS_FONT"], tooltip = L["SETTINGS_FONT_TIP"], options = {
            { value = "Fonts\\ARIALN.TTF",   label = "Arial Narrow" },
            { value = "Fonts\\FRIZQT__.TTF", label = "Friz Quadrata" },
            { value = "Fonts\\MORPHEUS.TTF", label = "Morpheus" },
            { value = "Fonts\\SKURRI.TTF",   label = "Skurri" },
            { value = "Fonts\\2002.TTF",     label = "2002" },
        }},
        { type = "slider", key = "bgAlpha", label = L["SETTINGS_BG_OPACITY"], min = 0, max = 100, step = 5, format = "%" },
        { type = "row", children = {
            { type = "checkbox", key = "retailEmptySlots", label = L["SETTINGS_RETAIL_EMPTY_SLOTS"], tooltip = L["SETTINGS_RETAIL_EMPTY_SLOTS_TIP"],
              hidden = function() return ns.IsRetail end },
            { type = "checkbox", key = "minimalEmptySlots", label = L["SETTINGS_MINIMAL_EMPTY_SLOTS"], tooltip = L["SETTINGS_MINIMAL_EMPTY_SLOTS_TIP"] },
        }},

        { type = "separator", label = L["SETTINGS_SECTION_OPTIONS"] },
        { type = "row", children = {
            { type = "checkbox", key = "locked", label = L["SETTINGS_LOCK_WINDOW"], tooltip = L["SETTINGS_LOCK_WINDOW_TIP"] },
            { type = "checkbox", key = "showBorders", label = L["SETTINGS_SHOW_BORDERS"], tooltip = L["SETTINGS_SHOW_BORDERS_TIP"] },
        }},

        { type = "row", children = {
            { type = "checkbox", key = "hoverBagline", label = L["SETTINGS_SHOW_ALL_BAGS"], tooltip = L["SETTINGS_SHOW_ALL_BAGS_TIP"] },
            { type = "checkbox", key = "showTooltipCounts", label = L["SETTINGS_INVENTORY_COUNTS"], tooltip = L["SETTINGS_INVENTORY_COUNTS_TIP"] },
        }},

        { type = "separator", label = L["SETTINGS_SECTION_SORT"] },
        { type = "row", children = {
            { type = "select", key = "sortPriority", label = L["SETTINGS_SORT_PRIORITY"], tooltip = L["SETTINGS_SORT_PRIORITY_TIP"], options = {
                { value = "default", label = L["SETTINGS_SORT_DEFAULT"] },
                { value = "ilvl", label = L["SETTINGS_SORT_ILVL"] },
                { value = "quality", label = L["SETTINGS_SORT_QUALITY"] },
            }},
            { type = "checkbox", key = "reverseStackSort", label = L["SETTINGS_REVERSE_STACK"], tooltip = L["SETTINGS_REVERSE_STACK_TIP"] },
        }},
        { type = "row", children = {
            { type = "checkbox", key = "gudaSort", label = L["SETTINGS_GUDA_SORT"], tooltip = L["SETTINGS_GUDA_SORT_TIP"],
              hidden = function() local Expansion = ns:GetModule("Expansion") return not (Expansion and Expansion.IsRetail) end },
        }},
        { type = "row", children = {
            { type = "checkbox", key = "sortRightToLeft", label = L["SETTINGS_SORT_RTL"], tooltip = L["SETTINGS_SORT_RTL_TIP"],
              hidden = function() local Expansion = ns:GetModule("Expansion")
                if not (Expansion and Expansion.IsRetail) then return false end
                return not ns:GetModule("Database"):GetSetting("gudaSort") end },
            { type = "checkbox", key = "smoothSort", label = L["SETTINGS_SMOOTH_SORT"], tooltip = L["SETTINGS_SMOOTH_SORT_TIP"],
              hidden = function() local Expansion = ns:GetModule("Expansion")
                if not (Expansion and Expansion.IsRetail) then return false end
                return not ns:GetModule("Database"):GetSetting("gudaSort") end },
        }},

        { type = "separator", label = L["SETTINGS_SECTION_AUTOMATION"] },
        { type = "row", children = {
            { type = "checkbox", key = "autoOpenBags", label = L["SETTINGS_AUTO_OPEN_BAGS"], tooltip = L["SETTINGS_AUTO_OPEN_BAGS_TIP"] },
            { type = "checkbox", key = "autoCloseBags", label = L["SETTINGS_AUTO_CLOSE_BAGS"], tooltip = L["SETTINGS_AUTO_CLOSE_BAGS_TIP"] },
        }},
        { type = "row", children = {
            { type = "checkbox", key = "autoVendorJunk", label = L["SETTINGS_AUTO_VENDOR_JUNK"], tooltip = L["SETTINGS_AUTO_VENDOR_JUNK_TIP"] },
            { type = "checkbox", key = "autoRepair", label = L["SETTINGS_AUTO_REPAIR"], tooltip = L["SETTINGS_AUTO_REPAIR_TIP"] },
        }},
    }
end

-------------------------------------------------
-- Layout Tab Schema
-------------------------------------------------
function SettingsSchema.GetLayout()
    local L = ns.L
    local viewOptions = {}
    for _, v in ipairs(ns.Constants.VIEW_TYPES) do
        viewOptions[#viewOptions + 1] = { value = v, label = L["SETTINGS_VIEW_" .. v:upper()] }
    end
    return {
        { type = "separator", label = L["SETTINGS_SECTION_VIEW"] },
        { type = "select", key = "bagViewType", label = L["SETTINGS_BAG_VIEW"], tooltip = L["SETTINGS_BAG_VIEW_TIP"], options = viewOptions },
        { type = "select", key = "bankViewType", label = L["SETTINGS_BANK_VIEW"], tooltip = L["SETTINGS_BANK_VIEW_TIP"], options = viewOptions },

        { type = "separator", label = L["SETTINGS_SECTION_SPLIT"],
          hidden = function() local Database = ns:GetModule("Database")
            return Database:GetSetting("bagViewType") ~= "split" and Database:GetSetting("bankViewType") ~= "split" end },
        { type = "slider", key = "splitBagColumns", label = L["SETTINGS_SPLIT_BAG_COLUMNS"], min = 1, max = 3, step = 1,
          hidden = function() local Database = ns:GetModule("Database") return Database:GetSetting("bagViewType") ~= "split" end },
        { type = "slider", key = "splitBankColumns", label = L["SETTINGS_SPLIT_BANK_COLUMNS"], min = 1, max = 4, step = 1,
          hidden = function() local Database = ns:GetModule("Database") return Database:GetSetting("bankViewType") ~= "split" end },
        { type = "row", hidden = function() local Database = ns:GetModule("Database")
            return Database:GetSetting("bagViewType") ~= "split" and Database:GetSetting("bankViewType") ~= "split" end,
          children = {
            { type = "checkbox", key = "splitFullWidthBackpack", label = L["SETTINGS_SPLIT_FULL_WIDTH_BACKPACK"], tooltip = L["SETTINGS_SPLIT_FULL_WIDTH_BACKPACK_TIP"] },
            { type = "checkbox", key = "splitFullWidthReagent", label = L["SETTINGS_SPLIT_FULL_WIDTH_REAGENT"], tooltip = L["SETTINGS_SPLIT_FULL_WIDTH_REAGENT_TIP"],
              hidden = function() local Expansion = ns:GetModule("Expansion") return not (Expansion and Expansion.IsRetail) end },
            { type = "checkbox", key = "splitFullWidthKeyring", label = L["SETTINGS_SPLIT_FULL_WIDTH_KEYRING"], tooltip = L["SETTINGS_SPLIT_FULL_WIDTH_KEYRING_TIP"],
              hidden = function() local Expansion = ns:GetModule("Expansion") return Expansion and Expansion.IsRetail end },
        }},

        { type = "separator", label = L["SETTINGS_SECTION_COLUMNS"] },
        { type = "slider", key = "bagColumns", label = L["SETTINGS_BAG_COLUMNS"], min = 5, max = 22, step = 1 },
        { type = "slider", key = "bankColumns", label = L["SETTINGS_BANK_COLUMNS"], min = 5, max = 36, step = 1 },
        { type = "slider", key = "guildBankColumns", label = L["SETTINGS_GUILD_BANK_COLUMNS"], min = 10, max = 36, step = 1 },

        { type = "separator", label = L["SETTINGS_SECTION_CATEGORY"],
          hidden = function() local Database = ns:GetModule("Database")
            return Database:GetSetting("bagViewType") ~= "category" and Database:GetSetting("bankViewType") ~= "category" end },
        { type = "row", hidden = function() local Database = ns:GetModule("Database")
            return Database:GetSetting("bagViewType") ~= "category" and Database:GetSetting("bankViewType") ~= "category" end,
          children = {
            { type = "checkbox", key = "showCategoryCount", label = L["SETTINGS_SHOW_CAT_COUNT"], tooltip = L["SETTINGS_SHOW_CAT_COUNT_TIP"] },
            { type = "checkbox", key = "showEquipSetCategories", label = L["SETTINGS_EQUIP_SET_CATEGORIES"], tooltip = L["SETTINGS_EQUIP_SET_CATEGORIES_TIP"] },
        }},
        { type = "row", hidden = function() local Database = ns:GetModule("Database")
            return Database:GetSetting("bagViewType") ~= "category" and Database:GetSetting("bankViewType") ~= "category" end,
          children = {
            { type = "checkbox", key = "groupIdenticalItems", label = L["SETTINGS_GROUP_IDENTICAL"], tooltip = L["SETTINGS_GROUP_IDENTICAL_TIP"] },
        }},
    }
end

-------------------------------------------------
-- Features Tab Schema
-------------------------------------------------
function SettingsSchema.GetFeatures()
    local L = ns.L
    return {
        { type = "separator", label = L["SETTINGS_SECTION_HEADER_BUTTONS"] },
        { type = "row", children = {
            { type = "checkbox", key = "showHeaderCharacters", label = L["SETTINGS_SHOW_HEADER_CHARACTERS"], tooltip = L["SETTINGS_SHOW_HEADER_CHARACTERS_TIP"] },
            { type = "checkbox", key = "showHeaderBank", label = L["SETTINGS_SHOW_HEADER_BANK"], tooltip = L["SETTINGS_SHOW_HEADER_BANK_TIP"] },
        }},
        { type = "row", children = {
            { type = "checkbox", key = "showHeaderGuildBank", label = L["SETTINGS_SHOW_HEADER_GUILD_BANK"], tooltip = L["SETTINGS_SHOW_HEADER_GUILD_BANK_TIP"],
              hidden = function() return not (ns.Constants.FEATURES and ns.Constants.FEATURES.GUILD_BANK) end },
            { type = "checkbox", key = "showHeaderMail", label = L["SETTINGS_SHOW_HEADER_MAIL"], tooltip = L["SETTINGS_SHOW_HEADER_MAIL_TIP"] },
        }},
        { type = "row", children = {
            { type = "checkbox", key = "showHeaderSort", label = L["SETTINGS_SHOW_HEADER_SORT"], tooltip = L["SETTINGS_SHOW_HEADER_SORT_TIP"] },
            { type = "checkbox", key = "showHeaderSearch", label = L["SETTINGS_SHOW_HEADER_SEARCH"], tooltip = L["SETTINGS_SHOW_HEADER_SEARCH_TIP"] },
        }},
        { type = "row", children = {
            { type = "checkbox", key = "showHeaderViewCycle", label = L["SETTINGS_SHOW_HEADER_VIEW_CYCLE"], tooltip = L["SETTINGS_SHOW_HEADER_VIEW_CYCLE_TIP"] },
            { type = "checkbox", key = "showHeaderRecentToggle", label = L["SETTINGS_SHOW_HEADER_RECENT_TOGGLE"], tooltip = L["SETTINGS_SHOW_HEADER_RECENT_TOGGLE_TIP"] },
        }},

        { type = "separator", label = L["SETTINGS_SECTION_VISIBILITY"] },
        { type = "row", children = {
            { type = "checkbox", key = "showSearchBar", label = L["SETTINGS_SHOW_SEARCH"], tooltip = L["SETTINGS_SHOW_SEARCH_TIP"] },
            { type = "checkbox", key = "showFilterChips", label = L["SETTINGS_SHOW_FILTER_CHIPS"], tooltip = L["SETTINGS_SHOW_FILTER_CHIPS_TIP"] },
        }},
        { type = "row", children = {
            { type = "checkbox", key = "showFooter", label = L["SETTINGS_SHOW_FOOTER"], tooltip = L["SETTINGS_SHOW_FOOTER_TIP"] },
            { type = "checkbox", key = "showDragFlyout", label = L["SETTINGS_SHOW_DRAG_FLYOUT"], tooltip = L["SETTINGS_SHOW_DRAG_FLYOUT_TIP"] },
        }},
    }
end

-------------------------------------------------
-- Icons Tab Schema
-------------------------------------------------
function SettingsSchema.GetIcons()
    local L = ns.L
    return {
        { type = "separator", label = L["SETTINGS_SECTION_ICON"] },
        { type = "slider", key = "iconSize", label = L["SETTINGS_ICON_SIZE"], min = 22, max = 64, step = 1, format = "px" },
        { type = "slider", key = "iconFontSize", label = L["SETTINGS_ICON_FONT_SIZE"], min = 8, max = 20, step = 1, format = "px" },
        { type = "slider", key = "iconSpacing", label = L["SETTINGS_ICON_SPACING"], min = 0, max = 20, step = 1, format = "px" },

        { type = "separator", label = L["SETTINGS_SECTION_ICON_OPTIONS"] },
        { type = "row", children = {
            { type = "checkbox", key = "equipmentBorders", label = L["SETTINGS_QUALITY_BORDERS"], tooltip = L["SETTINGS_QUALITY_BORDERS_TIP"] },
            { type = "checkbox", key = "otherBorders", label = L["SETTINGS_OTHER_BORDERS"], tooltip = L["SETTINGS_OTHER_BORDERS_TIP"] },
        }},

        -- Row 2
        { type = "row", children = {
            { type = "checkbox", key = "markUnusableItems", label = L["SETTINGS_MARK_UNUSABLE"], tooltip = L["SETTINGS_MARK_UNUSABLE_TIP"] },
            { type = "checkbox", key = "grayoutJunk", label = L["SETTINGS_GRAYOUT_JUNK"], tooltip = L["SETTINGS_GRAYOUT_JUNK_TIP"] },
        }},

        -- Row 3 - Junk and equipment set options
        { type = "row", children = {
            { type = "checkbox", key = "whiteItemsJunk", label = L["SETTINGS_WHITE_JUNK"], tooltip = L["SETTINGS_WHITE_JUNK_TIP"] },
            { type = "checkbox", key = "showItemLevel", label = L["SETTINGS_SHOW_ITEM_LEVEL"], tooltip = L["SETTINGS_SHOW_ITEM_LEVEL_TIP"] },
        }},

        -- Row 4 - Equipment sets
        { type = "row", children = {
            { type = "checkbox", key = "markEquipmentSets", label = L["SETTINGS_MARK_EQUIP_SETS"], tooltip = L["SETTINGS_MARK_EQUIP_SETS_TIP"] },
            { type = "checkbox", key = "autoLockSetItems", label = L["SETTINGS_AUTO_LOCK_SET_ITEMS"], tooltip = L["SETTINGS_AUTO_LOCK_SET_ITEMS_TIP"] },
        }},

        -- Row 5 - Charges and BoE label
        { type = "row", children = {
            { type = "checkbox", key = "showCharges",  label = L["SETTINGS_SHOW_CHARGES"],   tooltip = L["SETTINGS_SHOW_CHARGES_TIP"] },
            { type = "checkbox", key = "showBoeLabel", label = L["SETTINGS_SHOW_BOE_LABEL"], tooltip = L["SETTINGS_SHOW_BOE_LABEL_TIP"] },
        }},
    }
end

-------------------------------------------------
-- Bar Tab Schema
-------------------------------------------------
function SettingsSchema.GetBar()
    local L = ns.L
    return {
        { type = "separator", label = L["SETTINGS_SECTION_QUEST_BAR"] },
        { type = "slider", key = "questBarSize", label = L["SETTINGS_QUEST_BAR_SIZE"], min = 22, max = 64, step = 1, format = "px" },
        { type = "slider", key = "questBarColumns", label = L["SETTINGS_QUEST_BAR_COLS"], min = 1, max = 5, step = 1 },
        { type = "slider", key = "questBarSpacing", label = L["SETTINGS_QUEST_BAR_SPACING"], min = 0, max = 12, step = 1, format = "px" },
        { type = "row", children = {
            { type = "checkbox", key = "showQuestBar", label = L["SETTINGS_SHOW_QUEST_BAR"], tooltip = L["SETTINGS_SHOW_QUEST_BAR_TIP"] },
            { type = "checkbox", key = "hideQuestBarInBGs", label = L["SETTINGS_HIDE_QUEST_BAR_BG"], tooltip = L["SETTINGS_HIDE_QUEST_BAR_BG_TIP"] },
        }},

        { type = "separator", label = L["SETTINGS_SECTION_TRACKED"] },
        { type = "slider", key = "trackedBarSize", label = L["SETTINGS_TRACKED_BAR_SIZE"], min = 22, max = 64, step = 1, format = "px" },
        { type = "slider", key = "trackedBarColumns", label = L["SETTINGS_TRACKED_BAR_COLS"], min = 2, max = 12, step = 1 },
        { type = "slider", key = "trackedBarSpacing", label = L["SETTINGS_TRACKED_BAR_SPACING"], min = 0, max = 12, step = 1, format = "px" },
    }
end

-- Backwards compatibility - these will be called as functions now
SettingsSchema.GENERAL = nil
SettingsSchema.LAYOUT = nil
SettingsSchema.ICONS = nil

return SettingsSchema
