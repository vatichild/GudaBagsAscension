local addonName, ns = ...

local SearchBarToggle = {}
ns:RegisterModule("SearchBarToggle", SearchBarToggle)

local Database = ns:GetModule("Database")

-- Applies transient-search-bar toggle state and methods to a frame module.
--
-- After Apply(FrameModule, opts), the module gains:
--   FrameModule:IsSearchBarVisible() -> boolean (effective visibility)
--   FrameModule:ToggleSearchBar()    -> flips transient state, refreshes, focuses input
--   FrameModule:ResetSearchToggle()  -> sets state back to false (call from Hide())
--
-- opts = {
--   getFrame = function() return frame end,   -- returns the module's root frame
--   onChanged = function(isOpen) ... end,     -- called after toggle, before focus
-- }
function SearchBarToggle:Apply(frameModule, opts)
    frameModule._searchBarOpen = false

    function frameModule:IsSearchBarVisible()
        return Database:GetSetting("showSearchBar") or self._searchBarOpen
    end

    function frameModule:ToggleSearchBar()
        local frame = opts.getFrame and opts.getFrame()
        if not frame or not frame:IsShown() then return end
        -- Always-on mode: the header icon is hidden anyway; treat as no-op.
        if Database:GetSetting("showSearchBar") then return end

        self._searchBarOpen = not self._searchBarOpen

        if opts.onChanged then
            opts.onChanged(self._searchBarOpen)
        end

        if self._searchBarOpen then
            local SearchBar = ns:GetModule("SearchBar")
            local instance = SearchBar and SearchBar:GetInstance(frame)
            if instance and instance.searchBox then
                instance.searchBox:SetFocus()
            end
        end
    end

    function frameModule:ResetSearchToggle()
        self._searchBarOpen = false
    end
end
