local addonName, ns = ...

local CategoryHeaderPool = {}
ns:RegisterModule("CategoryHeaderPool", CategoryHeaderPool)

local Font = ns:GetModule("Font")
local LayoutEngine = nil  -- Lazy loaded to avoid circular dependency

-------------------------------------------------
-- Category Header Pool
-- Object pool for category headers used in category view
-------------------------------------------------

local headerPool = {}
local activeHeadersByOwner = {}  -- { [owner] = { header1, header2, ... } }

-- Get LayoutEngine lazily to avoid initialization order issues
local function GetLayoutEngine()
    if not LayoutEngine then
        LayoutEngine = ns:GetModule("BagFrame.LayoutEngine")
    end
    return LayoutEngine
end

-- Acquire a category header from the pool
function CategoryHeaderPool:Acquire(parent)
    local header = table.remove(headerPool)
    if not header then
        header = CreateFrame("Frame", nil, parent)

        local layoutEngine = GetLayoutEngine()
        if layoutEngine then
            header:SetHeight(layoutEngine:GetCategoryHeaderHeight())
        else
            header:SetHeight(18)  -- Fallback height
        end

        header.icon = header:CreateTexture(nil, "ARTWORK")
        header.icon:SetSize(16, 16)
        header.icon:SetPoint("LEFT", header, "LEFT", 0, 0)
        header.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        header.text = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        Font:Override(header.text)
        header.text:SetPoint("LEFT", header.icon, "RIGHT", 4, 0)
        header.text:SetTextColor(1, 0.82, 0)

        header.line = header:CreateTexture(nil, "ARTWORK")
        header.line:SetHeight(1)
        header.line:SetPoint("LEFT", header.text, "RIGHT", 6, 0)
        header.line:SetPoint("RIGHT", header, "RIGHT", 0, 0)
        header.line:SetTexture("Interface\\Buttons\\WHITE8x8")
        header.line:SetVertexColor(0.3, 0.3, 0.3, 0.8)
    end

    header:SetParent(parent)
    header:Show()
    header.owner = parent  -- Track owner for selective release

    -- Store by owner
    if not activeHeadersByOwner[parent] then
        activeHeadersByOwner[parent] = {}
    end
    table.insert(activeHeadersByOwner[parent], header)

    return header
end

-- Helper function to release a single header (internal use)
local function ReleaseHeader(header)
    header:Hide()
    header:ClearAllPoints()

    -- Clear any stored data
    header.categoryId = nil
    header.fullName = nil
    header.isShortened = nil

    -- Clear scripts to prevent memory leaks
    header:SetScript("OnEnter", nil)
    header:SetScript("OnLeave", nil)
    header:SetScript("OnMouseDown", nil)

    table.insert(headerPool, header)
end

-- Release a single category header back to the pool
function CategoryHeaderPool:Release(header)
    local owner = header.owner

    -- Remove from owner's active headers
    if owner and activeHeadersByOwner[owner] then
        for i, h in ipairs(activeHeadersByOwner[owner]) do
            if h == header then
                table.remove(activeHeadersByOwner[owner], i)
                break
            end
        end
    end

    header.owner = nil
    ReleaseHeader(header)
end

-- Release all active headers back to the pool
-- If owner is specified, only release headers belonging to that owner
-- If owner is nil, release ALL headers (backwards compatibility)
function CategoryHeaderPool:ReleaseAll(owner)
    if owner then
        -- Release only headers for specific owner
        local headers = activeHeadersByOwner[owner]
        if headers then
            for _, header in ipairs(headers) do
                header.owner = nil
                ReleaseHeader(header)
            end
            activeHeadersByOwner[owner] = nil
        end
    else
        -- Release all headers from all owners
        for ownerFrame, headers in pairs(activeHeadersByOwner) do
            for _, header in ipairs(headers) do
                header.owner = nil
                ReleaseHeader(header)
            end
        end
        wipe(activeHeadersByOwner)
    end
end

-- Get count of active headers (optionally for a specific owner)
function CategoryHeaderPool:GetActiveCount(owner)
    if owner then
        local headers = activeHeadersByOwner[owner]
        return headers and #headers or 0
    end
    -- Count all active headers across all owners
    local count = 0
    for _, headers in pairs(activeHeadersByOwner) do
        count = count + #headers
    end
    return count
end

-- Get count of pooled (inactive) headers
function CategoryHeaderPool:GetPooledCount()
    return #headerPool
end

-- Get all active headers (for iteration, optionally for a specific owner)
function CategoryHeaderPool:GetActiveHeaders(owner)
    if owner then
        return activeHeadersByOwner[owner] or {}
    end
    -- Return all active headers across all owners (for backwards compatibility)
    local allHeaders = {}
    for _, headers in pairs(activeHeadersByOwner) do
        for _, header in ipairs(headers) do
            table.insert(allHeaders, header)
        end
    end
    return allHeaders
end
