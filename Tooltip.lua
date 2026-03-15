-------------------------------------------------------------------------------
-- Tooltip.lua – Inject alt-character specialization data into tooltips
--
-- Hook strategy (verified against Blizzard source on Gethe/wow-ui-source):
--
-- We use EventRegistry callbacks that Blizzard fires AFTER tooltip:Show()
-- in each OnEnter method:
--
--   "ProfessionSpecs.SpecPathEntered"   (nodeID, frameName)
--     Fired at the end of ProfessionsSpecPathMixin:OnEnter().
--     ProfessionsSpecPathMixin is defined in
--     Blizzard_ProfessionsSpecializationsTemplates.lua (part of the
--     Blizzard_Professions demand-loaded addon).
--     The tooltip (GameTooltip) is already built and shown before this
--     event fires, so we append our alt lines and call Show() to resize.
--
--   "ProfessionSpecs.SpecTabEntered"    (treeID)
--     Fired at the end of ProfessionSpecTabMixin:OnEnter().
--     Same pattern: tooltip already shown, we append and resize.
--
-- Why EventRegistry instead of hooksecurefunc on the mixin table:
--   ProfessionsSpecPathMixin is applied via Mixin(frame, mixin) during
--   frame creation from a pool.  Mixin() copies function references at
--   creation time.  If our hooksecurefunc wraps the mixin AFTER frames
--   were already created, those existing frames keep the original OnEnter
--   (race condition with demand-loading + C_Timer.After).
--   EventRegistry is fired by the original OnEnter regardless of when we
--   registered, so it is 100% reliable with no timing dependencies.
--
-- Line formatting:
--    Blank line separator
--    Header: "Account Characters:" in gold (NORMAL_FONT_COLOR)
--    Per alt:  "CharName-Realm (25)"
--              Name-Realm part is colored by RAID_CLASS_COLORS
--              " (25)" is white
--
-- Depends on: Utils.lua, Data.lua
-------------------------------------------------------------------------------

local _, PST = ...

PST.Tooltip = PST.Tooltip or {}
local Tooltip = PST.Tooltip

-------------------------------------------------------------------------------
-- AppendAltLines – given a sorted list of alt data, append formatted lines
--   to the provided tooltip.
--
---@param tooltip GameTooltip   The tooltip frame to modify
---@param alts table[]          Result of Data.GetNodeAlts()
---@param headerLabel string    Text for the header line
-------------------------------------------------------------------------------
local function AppendAltLines(tooltip, alts, headerLabel)
    if not alts or #alts == 0 then
        return
    end

    -- Blank line separator from Blizzard's existing content
    GameTooltip_AddBlankLineToTooltip(tooltip)

    -- Header in gold color (matches Blizzard's NORMAL_FONT_COLOR style)
    GameTooltip_AddColoredLine(tooltip, headerLabel, NORMAL_FONT_COLOR)

    -- One line per alt, sorted by rank descending (already sorted by Data)
    for _, altInfo in ipairs(alts) do
        -- Color the Name-Realm with class color
        local coloredName = PST.ClassColorWrap(altInfo.charKey, altInfo.class)
        -- Points text: show "learned" for rank 0, number for rank > 0
        local pointsText
        if altInfo.rank == 0 then
            pointsText = "|cff888888 (learned)|r"
        else
            pointsText = "|cffffffff (" .. altInfo.rank .. ")|r"
        end

        -- Use a single AddLine with inline color codes for the full string.
        -- This avoids issues with AddDoubleLine and inline color codes.
        tooltip:AddLine(coloredName .. pointsText)
    end

    -- Resize the tooltip to accommodate new lines
    tooltip:Show()
end

-------------------------------------------------------------------------------
-- Helper: split alt list into account-local vs synced, then append both.
-------------------------------------------------------------------------------
local function AppendSplitAltLines(tooltip, alts)
    if not alts or #alts == 0 then return end

    local accountAlts, syncedAlts = {}, {}
    for _, alt in ipairs(alts) do
        if alt.synced then
            syncedAlts[#syncedAlts + 1] = alt
        else
            accountAlts[#accountAlts + 1] = alt
        end
    end
    if #accountAlts > 0 then
        AppendAltLines(tooltip, accountAlts, "Account Characters:")
    end
    if #syncedAlts > 0 then
        AppendAltLines(tooltip, syncedAlts, "Synced Characters:")
    end
end

-------------------------------------------------------------------------------
-- EventRegistry Callbacks
--
-- EventRegistry is a global CallbackRegistry (always available in modern WoW).
-- SetUndefinedEventsAllowed(true) is set on it by Blizzard, so we can
-- register for any event string without pre-declaring it.
--
-- The callbacks will sit idle until Blizzard_Professions loads and fires them.
-------------------------------------------------------------------------------

--- Callback for specialization path node hover.
--- Fires after ProfessionsSpecPathMixin:OnEnter() calls tooltip:Show().
---@param owner table       Our Tooltip table (callback owner)
---@param nodeID number     The profession specialization node being hovered
---@param frameName string  The frame name of the hovered path button
local function OnSpecPathEntered(owner, nodeID, frameName)
    -- Guard: database must be initialized and nodeID must be valid
    if not PST.db or not nodeID or nodeID == 0 then return end

    local alts = PST.Data.GetNodeAlts(nodeID)

    PST.Debug("SpecPathEntered – nodeID:", nodeID, "alts:", #alts)

    AppendSplitAltLines(GameTooltip, alts)
end

--- Callback for specialization tab button hover.
--- Fires after ProfessionSpecTabMixin:OnEnter() calls GameTooltip:Show().
--- For tabs, we look up the root node of the tab's tree to find which
--- characters have invested any points in that specialization.
---@param owner table   Our Tooltip table (callback owner)
---@param treeID number The trait tree ID for the hovered tab
local function OnSpecTabEntered(owner, treeID)
    -- Guard: database must be initialized and treeID must be valid
    if not PST.db or not treeID then return end

    local alts = PST.Data.GetTabAlts(treeID)

    PST.Debug("SpecTabEntered – treeID:", treeID, "alts:", alts and #alts or 0)

    AppendSplitAltLines(GameTooltip, alts)
end

-------------------------------------------------------------------------------
-- Registration
--
-- We register at file load time.  EventRegistry is always available.
-- The callbacks only fire when Blizzard_Professions code triggers them
-- (i.e. when the player hovers spec nodes in the opened profession UI).
-------------------------------------------------------------------------------
if EventRegistry and EventRegistry.RegisterCallback then
    EventRegistry:RegisterCallback(
        "ProfessionSpecs.SpecPathEntered",
        OnSpecPathEntered,
        Tooltip  -- owner: passed as first arg to callback
    )
    EventRegistry:RegisterCallback(
        "ProfessionSpecs.SpecTabEntered",
        OnSpecTabEntered,
        Tooltip  -- owner: passed as first arg to callback
    )
    PST.Debug("Tooltip: EventRegistry callbacks registered for SpecPath and SpecTab events")
else
    -- Should never happen in modern WoW (10.x+), but be defensive.
    PST.DebugWarn("Tooltip: EventRegistry not available – tooltip enhancement disabled")
end
