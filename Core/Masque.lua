local addonName, ns = ...

local MasqueModule = {}
ns:RegisterModule("Masque", MasqueModule)

local Masque = LibStub and LibStub("Masque", true)
local Groups = {}

function MasqueModule:IsActive()
    return Masque ~= nil
end

local function GetOrCreateGroup(groupKey)
    if not Masque then return nil end
    if not Groups[groupKey] then
        Groups[groupKey] = Masque:Group("GudaBags", groupKey)
    end
    return Groups[groupKey]
end

function MasqueModule:AddButton(button, groupName, buttonData)
    if not Masque then return end
    local group = GetOrCreateGroup(groupName or "Bags")
    if not group then return end

    local data = buttonData or {
        Icon = button.icon or button.Icon,
        Cooldown = button.cooldown,
        Count = button.Count,
        Pushed = button.GetPushedTexture and button:GetPushedTexture() or nil,
        Normal = button.GetNormalTexture and button:GetNormalTexture() or false,
        Highlight = button.highlight,
    }

    group:AddButton(button, data)
    button._masqueGroup = groupName
end

function MasqueModule:RemoveButton(button)
    if not Masque then return end
    local groupName = button._masqueGroup
    if groupName and Groups[groupName] then
        Groups[groupName]:RemoveButton(button)
    end
    button._masqueGroup = nil
end
