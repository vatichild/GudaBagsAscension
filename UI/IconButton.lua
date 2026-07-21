local addonName, ns = ...

local IconButton = {}
ns:RegisterModule("IconButton", IconButton)

-- Icon definitions with default sizes
local ICONS = {
    close = {
        texture = "Interface\\AddOns\\GudaBags\\Assets\\close.tga",
        size = 14,
    },
    settings = {
        texture = "Interface\\AddOns\\GudaBags\\Assets\\cog.tga",
        size = 16,
    },
    search = {
        texture = "Interface\\AddOns\\GudaBags\\Assets\\search.tga",
        size = 16,
    },
    sort = {
        texture = "Interface\\AddOns\\GudaBags\\Assets\\sort.tga",
        size = 16,
    },
    bank = {
        -- There has never been a bank.tga/png on disk; chest is the bank icon.
        texture = "Interface\\AddOns\\GudaBags\\Assets\\chest.tga",
        size = 16,
    },
    characters = {
        texture = "Interface\\AddOns\\GudaBags\\Assets\\characters.tga",
        size = 16,
    },
    chest = {
        texture = "Interface\\AddOns\\GudaBags\\Assets\\chest.tga",
        size = 16,
    },
    guild = {
        texture = "Interface\\AddOns\\GudaBags\\Assets\\guild.tga",
        size = 16,
    },
    envelope = {
        texture = "Interface\\AddOns\\GudaBags\\Assets\\envelope.tga",
        size = 16,
    },
    viewCycle = {
        texture = "Interface\\AddOns\\GudaBags\\Assets\\categories.tga",
        size = 16,
    },
    recent = {
        texture = "Interface\\AddOns\\GudaBags\\Assets\\fav.tga",
        size = 16,
    },
}

local DEFAULT_HIGHLIGHT = "Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight"

---Create a reusable icon button
---@param parent Frame The parent frame
---@param iconType string Icon type from ICONS table or custom texture path
---@param options table|nil Optional settings: size, tooltip, onClick, anchor
---@return Button
function IconButton:Create(parent, iconType, options)
    options = options or {}

    local iconDef = ICONS[iconType]
    local texture = iconDef and iconDef.texture or iconType
    local size = options.size or (iconDef and iconDef.size) or 16

    local button = CreateFrame("Button", nil, parent)
    button:SetSize(size, size)

    -- Set textures
    button:SetNormalTexture(texture)
    button:SetHighlightTexture(options.highlight or DEFAULT_HIGHLIGHT, "ADD")

    -- Optional pushed texture (slightly darker)
    if options.pushedTexture then
        button:SetPushedTexture(options.pushedTexture)
    end

    -- Click handler
    if options.onClick then
        button:SetScript("OnClick", options.onClick)
    end

    -- Tooltip
    if options.tooltip then
        button:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, options.tooltipAnchor or "ANCHOR_BOTTOM")
            GameTooltip:SetText(options.tooltip)
            GameTooltip:Show()
        end)
        button:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
    end

    -- Store icon type for later reference
    button.iconType = iconType

    return button
end

---Update button icon
---@param button Button The button to update
---@param iconType string New icon type or texture path
function IconButton:SetIcon(button, iconType)
    local iconDef = ICONS[iconType]
    local texture = iconDef and iconDef.texture or iconType
    button:SetNormalTexture(texture)
    button.iconType = iconType
end

---Update button size
---@param button Button The button to update
---@param size number New size in pixels
function IconButton:SetSize(button, size)
    button:SetSize(size, size)
end

---Register a custom icon type
---@param name string Icon name
---@param texture string Texture path
---@param defaultSize number|nil Default size (defaults to 16)
function IconButton:RegisterIcon(name, texture, defaultSize)
    ICONS[name] = {
        texture = texture,
        size = defaultSize or 16,
    }
end

---Get icon definition
---@param iconType string Icon type name
---@return table|nil
function IconButton:GetIconDef(iconType)
    return ICONS[iconType]
end

---Create a standard Blizzard red close button
---@param parent Frame The parent frame
---@param options table|nil Optional settings: size, onClick, point, offsetX, offsetY
---@return Button
function IconButton:CreateCloseButton(parent, options)
    options = options or {}
    local size = options.size or 22

    local button = CreateFrame("Button", nil, parent, "UIPanelCloseButton")
    button:SetSize(size, size)

    if options.point then
        button:SetPoint(options.point, parent, options.point, options.offsetX or 0, options.offsetY or 0)
    else
        button:SetPoint("TOPRIGHT", parent, "TOPRIGHT", options.offsetX or 0, options.offsetY or 0)
    end

    if options.onClick then
        button:SetScript("OnClick", options.onClick)
    end

    return button
end
