local addonName, ns = ...

local ProfessionButton = ns:GetModule("Footer.ProfessionButton")

ProfessionButton:Create({
    spellID        = 1804,
    globalName     = "GudaBagsLockpickButton",
    icon           = "Interface\\Icons\\INV_Misc_Key_03",
    tooltipKey     = "FOOTER_PICKLOCK",
    tooltipDescKey = "FOOTER_PICKLOCK_TOOLTIP",
    defaultName    = "Pick Lock",
    requiredClass  = "ROGUE",
})
