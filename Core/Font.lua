local addonName, ns = ...

-------------------------------------------------
-- Font
-- Central font family selection. Every font string in the addon routes
-- through here so a single setting ("fontFamily") drives the family used
-- everywhere, and changing it re-applies live without rebuilding frames.
-------------------------------------------------
local Font = {}
ns:RegisterModule("Font", Font)

local Database

-- Weak keys so discarded font strings can still be collected. Each entry
-- remembers the size/flags last applied so ReapplyAll can re-set the family
-- while preserving the per-string sizing.
local registry = setmetatable({}, { __mode = "k" })

-- Top-level frames whose region tree should be re-swept on a font change, so
-- text created lazily (purchase prompts, log entries, list rows, …) picks up
-- the selected family without each site needing an explicit Apply call.
local sweptFrames = setmetatable({}, { __mode = "k" })

-- Ultimate fallback only used before the Database/Constants are available
-- (effectively never for UI). STANDARD_TEXT_FONT is the client's locale font.
local DEFAULT_PATH = STANDARD_TEXT_FONT or "Fonts\\ARIALN.TTF"

-- Cached resolved font path. The path only changes when the "fontFamily"
-- setting changes, which routes through ReapplyAll (where the cache is
-- cleared). Memoizing it keeps the per-string Apply path free of a
-- Database:GetSetting lookup on every SetFont.
local cachedFontPath

-- Resolve the currently selected font path. Database:GetSetting already falls
-- back to Constants.DEFAULTS.fontFamily (locale-aware) when nothing is set.
function Font:GetFont()
    if cachedFontPath then return cachedFontPath end
    Database = Database or ns:GetModule("Database")
    cachedFontPath = (Database and Database:GetSetting("fontFamily")) or DEFAULT_PATH
    return cachedFontPath
end

-- Apply the selected font with an explicit size/flags. Use for numeric/text
-- sites that own a specific (often dynamic) size. When size is omitted the
-- string's current size/flags are kept.
function Font:Apply(fontString, size, flags)
    if not fontString or not fontString.SetFont then return end
    if not size then
        local _, curSize, curFlags = fontString:GetFont()
        size = curSize or 12
        flags = flags or curFlags
    end
    local path = self:GetFont()
    -- Reuse the registry entry (no per-call allocation) and skip SetFont when
    -- the string already has exactly this path/size/flags. The repeated full
    -- sweeps (UpdateFontSize on every appearance update, ReapplyAll, per-item
    -- re-application) thus become cheap comparisons instead of text reflows.
    -- Safe because only GudaBags sets these strings' fonts, so the stored
    -- entry faithfully reflects their current state.
    local entry = registry[fontString]
    if entry then
        if entry.path == path and entry.size == size and entry.flags == flags then
            return
        end
        entry.path, entry.size, entry.flags = path, size, flags
    else
        registry[fontString] = { path = path, size = size, flags = flags }
    end
    fontString:SetFont(path, size, flags)
end

-- Swap only the family on a string that already has its size/flags set
-- (e.g. created from a GameFont* template). Preserves Blizzard's sizing.
function Font:Override(fontString)
    if not fontString or not fontString.GetFont then return end
    local _, size, flags = fontString:GetFont()
    self:Apply(fontString, size, flags)
end

-- Recursively swap the family on every FontString in a frame's region tree,
-- preserving each string's own size/flags. EditBoxes are handled by the
-- explicit Apply/Override sites since they are not FontStrings.
function Font:ApplyToRegions(frame)
    if not frame then return end
    if frame.GetRegions then
        for _, region in ipairs({ frame:GetRegions() }) do
            if region.GetObjectType and region:GetObjectType() == "FontString" then
                self:Override(region)
            end
        end
    end
    if frame.GetChildren then
        for _, child in ipairs({ frame:GetChildren() }) do
            self:ApplyToRegions(child)
        end
    end
end

-- Register a top-level frame: sweep it now and re-sweep on every font change.
function Font:RegisterFrame(frame)
    if not frame then return end
    sweptFrames[frame] = true
    self:ApplyToRegions(frame)
end

-- Re-set the family on every registered string at its remembered size/flags,
-- then re-sweep registered frames to catch any text created since.
function Font:ReapplyAll()
    cachedFontPath = nil  -- force GetFont to re-resolve the newly selected family
    local path = self:GetFont()
    for fs, info in pairs(registry) do
        if fs.SetFont then
            info.path = path  -- keep the Apply no-op check coherent with the new family
            fs:SetFont(path, info.size, info.flags)
        end
    end
    for frame in pairs(sweptFrames) do
        self:ApplyToRegions(frame)
    end
end

-- NOTE: GudaBags deliberately does NOT restyle the shared GameTooltip. The font
-- below applies only to GudaBags' own frames (registered via RegisterFrame /
-- swept by ApplyToRegions). Item tooltips and unit (NPC/character) tooltips reuse
-- the shared GameTooltip, so touching its fonts here inevitably leaked the
-- selected font onto them; the Font setting must leave them on the game default.

local Events = ns:GetModule("Events")
if Events then
    Events:Register("SETTING_CHANGED", function(_, key)
        if key == "fontFamily" then
            Font:ReapplyAll()
        end
    end, Font)
end
