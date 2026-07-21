local addonName, ns = ...

local HorizontalRow = {}
ns:RegisterModule("Layout.HorizontalRow", HorizontalRow)

local DEFAULT_SPACING = 4
local DEFAULT_HEIGHT = 22

function HorizontalRow:Create(parent, config)
    -- config = { spacing, height, columns }
    local container = CreateFrame("Frame", nil, parent)
    local children = {}
    local spacing = config and config.spacing or DEFAULT_SPACING
    local height = config and config.height or DEFAULT_HEIGHT
    local columns = config and config.columns or 2

    container:SetHeight(height)

    function container:AddChild(child)
        table.insert(children, child)
        child:SetParent(container)
        self:Layout()
        return child
    end

    function container:AddChildren(...)
        for i = 1, select("#", ...) do
            local child = select(i, ...)
            table.insert(children, child)
            child:SetParent(container)
        end
        self:Layout()
    end

    function container:Clear()
        for _, child in ipairs(children) do
            child:Hide()
            child:SetParent(nil)
        end
        children = {}
    end

    function container:Layout()
        local numChildren = #children
        if numChildren == 0 then return end

        -- Calculate width per child
        local totalSpacing = spacing * (columns - 1)
        local containerWidth = container:GetWidth()
        if containerWidth < 1 then containerWidth = 286 end -- fallback
        local childWidth = (containerWidth - totalSpacing) / columns

        for i, child in ipairs(children) do
            local col = (i - 1) % columns
            local xOffset = col * (childWidth + spacing)

            child:ClearAllPoints()
            child:SetPoint("TOPLEFT", container, "TOPLEFT", xOffset, 0)
            child:SetWidth(childWidth)
        end
    end

    function container:GetChildren()
        return children
    end

    function container:RefreshAll()
        for _, child in ipairs(children) do
            if child.Refresh then
                child:Refresh()
            end
        end
    end

    -- Re-layout when container size changes
    container:SetScript("OnSizeChanged", function()
        container:Layout()
    end)

    return container
end

return HorizontalRow
