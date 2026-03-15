-------------------------------------------------------------------------------
-- Scanner.lua – Profession specialization tree scanner
--
-- Reads the current character's profession specialization data from the
-- Blizzard API and stores it via Data.SaveNodeData().
--
-- Scanning flow:
--   1. C_TradeSkillUI.GetAllProfessionTradeSkillLines() → all skill line IDs
--   2. For each skill line with specializations:
--      a. C_ProfSpecs.GetConfigIDForSkillLine() → configID (need != 0)
--      b. C_ProfSpecs.GetSpecTabIDsForSkillLine() → tab treeIDs
--      c. For each tab:
--         - C_ProfSpecs.GetTabInfo() → tabName, rootNodeID
--         - Walk the tree: rootNodeID + C_ProfSpecs.GetChildrenForPath()
--         - For each node: C_Traits.GetNodeInfo() → currentRank, maxRanks
--         - Compute display rank: subtract unlock entry ranks (first tier)
--           following the same logic as ProfessionsSpecPathMixin:GetRanks()
--           (verified against Blizzard_ProfessionsSpecializationsTemplates.lua)
--         - Data.SaveNodeData(...)
--   3. Data.MarkScanComplete()
--
-- Throttling:
--   TryScanAll() is gated by PST.SCAN_THROTTLE (2 seconds default).
--   Rapid event bursts (e.g. multiple TRAIT_NODE_CHANGED) are collapsed.
--
-- Depends on: Utils.lua, Core.lua, Data.lua
-------------------------------------------------------------------------------

local _, PST = ...

PST.Scanner = PST.Scanner or {}
local Scanner = PST.Scanner

--- Timestamp of the last completed (or attempted) scan.
Scanner._lastScanTime = 0

--- Flag: true while a scan is actively running (prevents re-entrancy).
Scanner._scanning = false

-------------------------------------------------------------------------------
-- GetDisplayRanks – replicate Blizzard's ProfessionsSpecPathMixin:GetRanks()
--
-- The first entry of each path node is the "unlock" entry, which costs 0 or 1
-- point.  Blizzard subtracts this from the displayed rank/maxRank so that
-- the tooltip reads "0/30" instead of "1/31".
--
-- Reference: ProfessionsSpecPathMixin:GetRanks() in
-- Blizzard_ProfessionsSpecializationsTemplates.lua (Gethe/wow-ui-source)
--
---@param configID number       Trait config ID
---@param nodeID number         Trait node ID
---@param nodeInfo table        Result of C_Traits.GetNodeInfo()
---@return number rank          Display rank (points invested, excluding unlock)
---@return number maxRank       Display max rank (excluding unlock)
---@return boolean isLearned    true if the node is unlocked (purchased)
-------------------------------------------------------------------------------
local function GetDisplayRanks(configID, nodeID, nodeInfo)
    -- Safely get the unlock entry for this path
    local ok, unlockEntryID = pcall(C_ProfSpecs.GetUnlockEntryForPath, nodeID)
    if not ok or not unlockEntryID or unlockEntryID == 0 then
        -- No unlock entry – raw ranks are display ranks
        return nodeInfo.currentRank, nodeInfo.maxRanks, nodeInfo.currentRank > 0
    end

    -- How many points does the unlock entry itself consume?
    local entryOk, entryInfo = pcall(C_Traits.GetEntryInfo, configID, unlockEntryID)
    local numUnlockPoints = 0
    if entryOk and entryInfo and entryInfo.maxRanks then
        numUnlockPoints = entryInfo.maxRanks
    end

    -- currentRank > 0 means at least the unlock is purchased (= learned)
    local isLearned = nodeInfo.currentRank > 0

    -- Subtract unlock tier from both current and max
    local currentRank = nodeInfo.currentRank
    if currentRank > 0 then
        currentRank = currentRank - numUnlockPoints
    end
    local maxRank = nodeInfo.maxRanks - numUnlockPoints

    return currentRank, maxRank, isLearned
end

-------------------------------------------------------------------------------
-- WalkTree – recursively iterate a spec tree starting from rootNodeID.
--   Collects all { nodeID } via C_ProfSpecs.GetChildrenForPath().
--   Includes rootNodeID itself.
--
---@param rootNodeID number
---@return number[]  Flat list of all node IDs in the tree
-------------------------------------------------------------------------------
local function WalkTree(rootNodeID)
    local allNodes = {}
    local visited  = {}

    local function recurse(nodeID)
        if visited[nodeID] then return end
        visited[nodeID] = true
        allNodes[#allNodes + 1] = nodeID

        local ok, children = pcall(C_ProfSpecs.GetChildrenForPath, nodeID)
        if ok and children then
            for _, childID in ipairs(children) do
                recurse(childID)
            end
        end
    end

    recurse(rootNodeID)
    return allNodes
end

-------------------------------------------------------------------------------
-- ScanProfession – scan one profession's full specialization tree.
--
---@param skillLineID number  Expansion-specific skill line ID
---@return boolean success    true if any data was stored
-------------------------------------------------------------------------------
local function ScanProfession(skillLineID)
    -- Check if this skill line has specializations at all.
    local ok, hasSpecResult = pcall(C_ProfSpecs.SkillLineHasSpecialization, skillLineID)
    if not ok then
        PST.Debug("  SkillLineHasSpecialization error for", skillLineID, ":", tostring(hasSpecResult))
        return false
    end
    if not hasSpecResult then
        PST.Debug("  SkillLine", skillLineID, "has no specialization")
        return false
    end

    -- Get the trait config ID for this profession
    local cfgOk, configID = pcall(C_ProfSpecs.GetConfigIDForSkillLine, skillLineID)
    if not cfgOk or not configID or configID == 0 then
        PST.Debug("  No valid configID for skillLine", skillLineID)
        return false
    end

    -- Get profession name via C_TradeSkillUI
    local professionName = "Unknown"
    local parentProfessionName = nil
    local infoOk, profInfo = pcall(C_TradeSkillUI.GetProfessionInfoBySkillLineID, skillLineID)
    if infoOk and profInfo then
        professionName = profInfo.professionName or profInfo.parentProfessionName or "Unknown"
        parentProfessionName = profInfo.parentProfessionName
    end

    -- Get all specialization tab tree IDs
    local tabsOk, tabTreeIDs = pcall(C_ProfSpecs.GetSpecTabIDsForSkillLine, skillLineID)
    if not tabsOk or not tabTreeIDs or #tabTreeIDs == 0 then
        PST.Debug("  No spec tabs for skillLine", skillLineID)
        return false
    end

    PST.Debug("  Scanning profession:", professionName,
              "parent:", parentProfessionName or "nil",
              "skillLine:", skillLineID,
              "configID:", configID, "tabs:", #tabTreeIDs)

    local anyStored = false

    for _, treeID in ipairs(tabTreeIDs) do
        -- Get tab info (name, rootNodeID)
        local tabOk, tabInfo = pcall(C_ProfSpecs.GetTabInfo, treeID)
        if tabOk and tabInfo and tabInfo.rootNodeID then
            local tabName    = tabInfo.name or "?"
            local rootNodeID = tabInfo.rootNodeID

            PST.Debug("    Tab:", tabName, "treeID:", treeID, "root:", rootNodeID)

            -- Walk the entire node tree
            local allNodeIDs = WalkTree(rootNodeID)
            PST.Debug("      Nodes found:", #allNodeIDs)

            for _, nodeID in ipairs(allNodeIDs) do
                -- Get node info from the trait system
                local nodeOk, nodeInfo = pcall(C_Traits.GetNodeInfo, configID, nodeID)
                if nodeOk and nodeInfo and nodeInfo.ID and nodeInfo.ID ~= 0 then
                    local rank, maxRank, isLearned = GetDisplayRanks(configID, nodeID, nodeInfo)

                    PST.Data.SaveNodeData(
                        skillLineID, professionName, parentProfessionName,
                        treeID, tabName, rootNodeID,
                        nodeID, rank, maxRank, isLearned
                    )
                    anyStored = true
                else
                    PST.Debug("      NodeInfo unavailable for nodeID:", nodeID)
                end
            end
        else
            PST.Debug("    TabInfo unavailable for treeID:", treeID)
        end
    end

    return anyStored
end

-------------------------------------------------------------------------------
-- TryScanAll – Attempt to scan all known professions.
--   Subject to throttle.  Called from events and manual /pst scan.
--
---@param reason string|nil  Debug label for why the scan is happening
-------------------------------------------------------------------------------
function Scanner.TryScanAll(reason)
    -- Guard: don't re-enter
    if Scanner._scanning then
        PST.Debug("Scan skipped – already scanning")
        return
    end

    -- Guard: throttle
    local now = GetTime()
    if (now - Scanner._lastScanTime) < PST.SCAN_THROTTLE then
        PST.Debug("Scan throttled – too soon (" .. (reason or "?") .. ")")
        return
    end

    -- Guard: DB must be initialized
    if not PST.db then
        PST.Debug("Scan skipped – DB not initialized")
        return
    end

    Scanner._scanning     = true
    Scanner._lastScanTime = now
    PST.Debug("=== TryScanAll start (" .. (reason or "?") .. ") ===")

    -- Get all profession skill line IDs the character knows.
    -- This returns expansion-specific (child) skill line IDs where
    -- specializations live.
    -- WARNING: this API also returns skill lines for professions the
    -- character dropped in the past.  We must cross-reference with
    -- GetProfessions() to determine which professions are *current*.
    local ok, skillLineIDs = pcall(C_TradeSkillUI.GetAllProfessionTradeSkillLines)
    if not ok or not skillLineIDs then
        PST.DebugWarn("GetAllProfessionTradeSkillLines failed")
        Scanner._scanning = false
        return
    end

    -- Build a set of currently-active profession names from
    -- GetProfessions(), which is the authoritative source.
    -- This lets us discard stale skill lines for dropped professions.
    local currentProfNames = {}
    local prof1, prof2 = GetProfessions()
    for _, profIdx in pairs({prof1, prof2}) do
        if profIdx then
            local name = GetProfessionInfo(profIdx)
            if name then
                currentProfNames[name] = true
                PST.Debug("  Current profession:", name)
            end
        end
    end

    -- Filter skill lines: only keep those whose parent profession
    -- matches one of the character's current professions.
    local filteredIDs = {}
    for _, skillLineID in ipairs(skillLineIDs) do
        local infoOk, profInfo = pcall(C_TradeSkillUI.GetProfessionInfoBySkillLineID, skillLineID)
        if infoOk and profInfo then
            local parentName = profInfo.parentProfessionName or profInfo.professionName
            if parentName and currentProfNames[parentName] then
                filteredIDs[#filteredIDs + 1] = skillLineID
            else
                PST.Debug("  Skipping stale skill line", skillLineID,
                          "(", parentName or "?", ") – profession no longer active")
            end
        else
            -- Can't determine parent – include it so ScanProfession can
            -- decide via its own guards (SkillLineHasSpecialization, etc.)
            filteredIDs[#filteredIDs + 1] = skillLineID
        end
    end
    skillLineIDs = filteredIDs

    PST.Debug("Found", #skillLineIDs, "active skill line IDs")

    local anySuccess = false
    for _, skillLineID in ipairs(skillLineIDs) do
        local success = ScanProfession(skillLineID)
        if success then
            anySuccess = true
        end
    end

    if anySuccess then
        -- Clean up stale profession entries that no longer belong to this
        -- character (e.g. the player dropped a profession and learned a new
        -- one).  The filtered skillLineIDs set only contains currently-active
        -- professions, so anything else in storage is stale.
        local knownSkillLines = {}
        for _, sid in ipairs(skillLineIDs) do
            knownSkillLines[sid] = true
        end

        local charKey  = PST.GetCharKey()
        local charData = PST.Data.GetCharData(charKey)
        for skillLineID, prof in pairs(charData.professions) do
            if not knownSkillLines[skillLineID] then
                -- Remove stale node entries from nodeIndex first
                if prof.tabs then
                    for _, tab in pairs(prof.tabs) do
                        if tab.nodes then
                            for nodeID in pairs(tab.nodes) do
                                if PST.db.nodeIndex[nodeID] then
                                    PST.db.nodeIndex[nodeID][charKey] = nil
                                end
                            end
                        end
                    end
                end
                charData.professions[skillLineID] = nil
                PST.Debug("Removed stale profession entry:", skillLineID)
            end
        end

        PST.Data.MarkScanComplete()
        PST.Debug("=== TryScanAll complete – data saved ===")

        -- Notify the Comm module so updated data gets shared
        if PST.Comm and PST.Comm.OnScanComplete then
            PST.Comm.OnScanComplete()
        end
    else
        PST.Debug("=== TryScanAll complete – no data stored ===")
    end

    Scanner._scanning = false
end

-------------------------------------------------------------------------------
-- OnEvent – Called by core event dispatcher for profession-related events.
--
-- Different events trigger different scan strategies:
--   TRADE_SKILL_SHOW              → full scan (new profession window opened)
--   TRADE_SKILL_DATA_SOURCE_CHANGED → full scan (data now available)
--   SKILL_LINE_SPECS_RANKS_CHANGED  → full scan (points were spent)
--   TRAIT_CONFIG_UPDATED          → full scan (config committed)
--   TRAIT_NODE_CHANGED            → targeted update if possible, else full
--
---@param event string
---@param ... any  Event payload
-------------------------------------------------------------------------------
function Scanner.OnEvent(event, ...)
    if event == "TRADE_SKILL_SHOW" then
        -- The profession window just opened.  Scan after a brief delay
        -- to let the data finish loading.
        C_Timer.After(0.5, function()
            Scanner.TryScanAll("TRADE_SKILL_SHOW")
        end)

    elseif event == "TRADE_SKILL_DATA_SOURCE_CHANGED" then
        -- Data source has changed (could be loading another character's
        -- public profession, or own profession data becoming available).
        -- Only scan if we are in local (own) crafting mode.
        C_Timer.After(0.5, function()
            if Professions and Professions.InLocalCraftingMode
               and Professions.InLocalCraftingMode() then
                Scanner.TryScanAll("TRADE_SKILL_DATA_SOURCE_CHANGED")
            end
        end)

    elseif event == "SKILL_LINE_SPECS_RANKS_CHANGED" then
        -- Specialization ranks changed – rescan.
        C_Timer.After(0.3, function()
            Scanner.TryScanAll("SKILL_LINE_SPECS_RANKS_CHANGED")
        end)

    elseif event == "TRAIT_CONFIG_UPDATED" then
        -- A trait config was committed (points finalized).
        local configID = ...
        C_Timer.After(0.3, function()
            Scanner.TryScanAll("TRAIT_CONFIG_UPDATED:" .. tostring(configID))
        end)

    elseif event == "TRAIT_NODE_CHANGED" then
        -- A specific node changed.  Could be a staged change (not yet
        -- committed) or a committed change.  We rescan fully as the
        -- overhead is minimal and guarantees correctness.
        -- Use a slightly longer debounce since this event can fire many
        -- times in sequence (one per node in a batch commit).
        if Scanner._nodeChangedTimer then
            Scanner._nodeChangedTimer:Cancel()
        end
        Scanner._nodeChangedTimer = C_Timer.NewTimer(1.0, function()
            Scanner._nodeChangedTimer = nil
            Scanner.TryScanAll("TRAIT_NODE_CHANGED (debounced)")
        end)
    end
end
