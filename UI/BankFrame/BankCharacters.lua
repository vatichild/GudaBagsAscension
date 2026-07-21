local addonName, ns = ...

local BankCharacters = {}
ns:RegisterModule("BankFrame.BankCharacters", BankCharacters)

local CharacterDropdown = ns:GetModule("CharacterDropdown")

local Database = ns:GetModule("Database")

local function HasBankData(fullName)
    local bank = Database:GetNormalizedBank(fullName)
    if not bank then return false end

    for bagID, bagData in pairs(bank) do
        if bagData.slots then
            for slot, _ in pairs(bagData.slots) do
                return true
            end
        end
    end

    return false
end

local dropdown = CharacterDropdown:Create({
    frameName = "GudaBagsBankCharacterDropdown",
    hasDataFunc = HasBankData,
    getViewingCharacter = function()
        local BankFrame = ns:GetModule("BankFrame")
        return BankFrame:GetViewingCharacter()
    end,
})

function BankCharacters:Show(anchor)
    dropdown:Show(anchor)
end

function BankCharacters:Hide()
    dropdown:Hide()
end

function BankCharacters:Toggle(anchor)
    dropdown:Toggle(anchor)
end

function BankCharacters:SetCallback(callback)
    dropdown:SetCallback(callback)
end

function BankCharacters:IsShown()
    return dropdown:IsShown()
end
