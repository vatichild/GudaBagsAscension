local addonName, ns = ...

local ProfessionButton = ns:GetModule("Footer.ProfessionButton")

ProfessionButton:Create({
    spellID        = 31252,
    globalName     = "GudaBagsProspectingButton",
    icon           = "Interface\\Icons\\INV_Misc_Gem_BloodGem_01",
    tooltipKey     = "FOOTER_PROSPECTING",
    tooltipDescKey = "FOOTER_PROSPECTING_TOOLTIP",
    defaultName    = "Prospecting",
})
