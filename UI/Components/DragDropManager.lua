local addonName, ns = ...

local DragDropManager = {}
ns:RegisterModule("DragDropManager", DragDropManager)

local Constants = ns.Constants

-------------------------------------------------
-- State
-------------------------------------------------

local draggedItem = nil
local dropIndicator = nil
local dropZones = {}
local draggables = {}

-------------------------------------------------
-- Drop Indicator
-------------------------------------------------

function DragDropManager:CreateDropIndicator(parent)
    if dropIndicator then return dropIndicator end

    local indicator = CreateFrame("Frame", nil, parent)
    indicator:SetHeight(2)
    indicator:SetFrameLevel(100)

    local tex = indicator:CreateTexture(nil, "OVERLAY")
    tex:SetAllPoints()
    local c = Constants.CATEGORY_COLORS.DROP_INDICATOR
    tex:SetColorTexture(c[1], c[2], c[3], c[4])

    indicator:Hide()
    dropIndicator = indicator
    return indicator
end

function DragDropManager:ShowIndicator(anchorFrame, position)
    if not dropIndicator then return end

    dropIndicator:ClearAllPoints()

    if position == "top" then
        dropIndicator:SetPoint("TOPLEFT", anchorFrame, "TOPLEFT", 0, 1)
        dropIndicator:SetPoint("TOPRIGHT", anchorFrame, "TOPRIGHT", 0, 1)
    elseif position == "bottom" then
        dropIndicator:SetPoint("BOTTOMLEFT", anchorFrame, "BOTTOMLEFT", 0, -1)
        dropIndicator:SetPoint("BOTTOMRIGHT", anchorFrame, "BOTTOMRIGHT", 0, -1)
    elseif position == "center" then
        dropIndicator:SetPoint("LEFT", anchorFrame, "LEFT", 0, 0)
        dropIndicator:SetPoint("RIGHT", anchorFrame, "RIGHT", 0, 0)
    end

    dropIndicator:Show()
end

function DragDropManager:HideIndicator()
    if dropIndicator then
        dropIndicator:Hide()
    end
end

-------------------------------------------------
-- Drag State
-------------------------------------------------

function DragDropManager:StartDrag(item)
    draggedItem = item
end

function DragDropManager:StopDrag()
    draggedItem = nil
    self:HideIndicator()
end

function DragDropManager:GetDraggedItem()
    return draggedItem
end

function DragDropManager:IsDragging()
    return draggedItem ~= nil
end

-------------------------------------------------
-- Draggable Registration
-------------------------------------------------

function DragDropManager:RegisterDraggable(frame, config)
    config = config or {}

    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")

    frame.dragData = config.data or {}
    frame.dragType = config.type or "default"

    frame:SetScript("OnDragStart", function(self)
        DragDropManager:StartDrag({
            frame = self,
            type = self.dragType,
            data = self.dragData,
        })
        self:SetAlpha(0.5)

        if config.onDragStart then
            config.onDragStart(self)
        end
    end)

    frame:SetScript("OnDragStop", function(self)
        self:SetAlpha(1)

        -- Find drop target
        local dropTarget = nil
        for _, zone in ipairs(dropZones) do
            if zone.isActiveTarget then
                dropTarget = zone
                break
            end
        end

        if dropTarget and config.onDrop then
            config.onDrop(self, dropTarget.frame, dropTarget.data)
        end

        if config.onDragStop then
            config.onDragStop(self, dropTarget)
        end

        DragDropManager:StopDrag()

        -- Clear all drop zone states
        for _, zone in ipairs(dropZones) do
            zone.isActiveTarget = false
        end
    end)

    table.insert(draggables, {
        frame = frame,
        config = config,
    })

    return frame
end

-------------------------------------------------
-- Drop Zone Registration
-------------------------------------------------

function DragDropManager:RegisterDropZone(frame, config)
    config = config or {}

    frame:EnableMouse(true)

    local zone = {
        frame = frame,
        config = config,
        data = config.data or {},
        acceptTypes = config.acceptTypes or {"default"},
        isActiveTarget = false,
    }

    frame:SetScript("OnEnter", function(self)
        if not DragDropManager:IsDragging() then return end

        local dragged = DragDropManager:GetDraggedItem()
        if not dragged then return end

        -- Check if this zone accepts the dragged type
        local accepts = false
        for _, acceptType in ipairs(zone.acceptTypes) do
            if acceptType == dragged.type or acceptType == "*" then
                accepts = true
                break
            end
        end

        -- Custom accept check
        if config.canAccept and not config.canAccept(dragged, zone.data) then
            accepts = false
        end

        if accepts then
            zone.isActiveTarget = true

            -- Show indicator
            local indicatorPos = config.indicatorPosition or "top"
            DragDropManager:ShowIndicator(self, indicatorPos)

            -- Highlight
            if config.onHighlight then
                config.onHighlight(self, true)
            end
        end
    end)

    frame:SetScript("OnLeave", function(self)
        zone.isActiveTarget = false

        if config.onHighlight then
            config.onHighlight(self, false)
        end
    end)

    table.insert(dropZones, zone)

    return frame
end

-------------------------------------------------
-- Cleanup
-------------------------------------------------

function DragDropManager:UnregisterAll()
    draggables = {}
    dropZones = {}
end

function DragDropManager:UnregisterFrame(frame)
    for i = #draggables, 1, -1 do
        if draggables[i].frame == frame then
            table.remove(draggables, i)
        end
    end

    for i = #dropZones, 1, -1 do
        if dropZones[i].frame == frame then
            table.remove(dropZones, i)
        end
    end
end

-------------------------------------------------
-- Utility
-------------------------------------------------

function DragDropManager:SetDragCursor(enabled)
    -- CURSOR_MOVE is nil where the client has no such texture (3.3.5a). Setting
    -- an unloadable cursor makes the hardware cursor blink and rescale, so we
    -- leave it untouched there rather than showing a broken one.
    if not Constants.TEXTURES.CURSOR_MOVE then return end
    if enabled then
        SetCursor(Constants.TEXTURES.CURSOR_MOVE)
    else
        SetCursor(nil)
    end
end
