local addonName, ns = ...

local ProfessionButton = ns:GetModule("Footer.ProfessionButton")

ProfessionButton:Create({
    spellID        = 13262,
    globalName     = "GudaBagsDisenchantButton",
    icon           = "Interface\\Icons\\Spell_Holy_RemoveCurse",
    tooltipKey     = "FOOTER_DISENCHANT",
    tooltipDescKey = "FOOTER_DISENCHANT_TOOLTIP",
    defaultName    = "Disenchant",
})
