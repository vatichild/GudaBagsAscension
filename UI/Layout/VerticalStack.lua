local addonName, ns = ...

local VerticalStack = {}
ns:RegisterModule("Layout.VerticalStack", VerticalStack)

local DEFAULT_SPACING = 8

function VerticalStack:Create(parent, config)
    -- config = { spacing, padding }
    local container = CreateFrame("Frame", nil, parent)
    local children = {}
    local spacing = config and config.spacing or DEFAULT_SPACING
    local padding = config and config.padding or 0

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
        local yOffset = -padding
        for _, child in ipairs(children) do
            child:ClearAllPoints()
            child:SetPoint("TOPLEFT", container, "TOPLEFT", padding, yOffset)
            child:SetPoint("TOPRIGHT", container, "TOPRIGHT", -padding, yOffset)
            yOffset = yOffset - child:GetHeight() - spacing
        end
        -- Set container height based on content
        local totalHeight = math.abs(yOffset) - spacing + padding
        if totalHeight < 1 then totalHeight = 1 end
        container:SetHeight(totalHeight)
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

    return container
end

return VerticalStack
