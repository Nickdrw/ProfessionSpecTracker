-------------------------------------------------------------------------------
-- Data.lua – SavedVariables management, schema migration, index maintenance
--
-- Schema (ProfessionSpecTrackerDB):
--
--   version    (number)   Current schema version (PST.DB_VERSION)
--
--   characters (table)    Keyed by "Name-Realm"
--     .<charKey>
--       .class           (string)  English class token, e.g. "WARRIOR"
--       .lastScan        (number)  time() of last successful scan
--       .professions     (table)   Keyed by skillLineID (number)
--         .<skillLineID>
--           .professionName       (string)  Localized profession name
--           .parentProfessionName (string)  Localized base profession name
--           .tabs                 (table)   Keyed by treeID (number)
--             .<treeID>
--               .tabName      (string)   Localized tab name
--               .rootNodeID   (number)   Root node of this spec tab
--               .nodes        (table)    Keyed by nodeID (number)
--                 .<nodeID>
--                   .rank     (number)   Current invested ranks (display rank)
--                   .maxRank  (number)   Maximum possible ranks
--
--   nodeIndex  (table)    Reverse index for fast tooltip lookup
--     .<nodeID>           (table) Keyed by "Name-Realm"
--       .<charKey>
--         .rank           (number)
--         .maxRank        (number)
--         .class          (string)
--
--   config     (table)    User settings (see Config.lua)
--
-- Design rationale:
--   • The `characters` table stores the canonical data per character.
--   • The `nodeIndex` table is a derived acceleration structure rebuilt from
--     `characters` when needed.  It enables O(1) lookup by nodeID in the
--     tooltip hook path, avoiding iteration over all characters.
--   • Safe schema upgrades: the version field allows future migrations.
--
-- Depends on: Utils.lua, Core.lua (PST namespace, PST.DB_VERSION)
-------------------------------------------------------------------------------

local _, PST = ...

PST.Data = PST.Data or {}
local Data = PST.Data

-------------------------------------------------------------------------------
-- Default (empty) database template
-------------------------------------------------------------------------------
local DB_DEFAULTS = {
    version    = 0,       -- will be set to PST.DB_VERSION after init
    characters = {},
    nodeIndex  = {},
}

-------------------------------------------------------------------------------
-- Init – called from Core.lua on ADDON_LOADED
--   Creates or migrates ProfessionSpecTrackerDB.
--
-- Migration from old addon name:
--   If ProfessionAccountSkillsDB exists as a global (e.g. both addons were
--   briefly installed), we adopt the old data and clear the old global.
--   In the common case (user renamed the folder), the old saved variables
--   file is not loaded by WoW.  Users must rename the file in WTF/ manually.
--   See migration notes in the addon documentation.
-------------------------------------------------------------------------------
function Data.Init()
    -- Migration from old addon name: if both globals exist, adopt old data
    if type(ProfessionAccountSkillsDB) == "table" and type(ProfessionSpecTrackerDB) ~= "table" then
        ProfessionSpecTrackerDB = ProfessionAccountSkillsDB
        ProfessionAccountSkillsDB = nil
        PST.Debug("Data.Init: Migrated from ProfessionAccountSkillsDB")
    end

    if type(ProfessionSpecTrackerDB) ~= "table" then
        ProfessionSpecTrackerDB = {}
    end

    local db = ProfessionSpecTrackerDB

    -- Ensure top-level keys exist
    for key, default in pairs(DB_DEFAULTS) do
        if db[key] == nil then
            db[key] = default
        end
    end

    -- Schema migration
    Data.Migrate(db)

    -- Store shortcut on namespace for convenience
    PST.db = db

    PST.Debug("Data.Init complete – version:", db.version,
              "characters:", Data.CountCharacters())
end

-------------------------------------------------------------------------------
-- Migrate – handle version upgrades
--   Version 3: rebrand from ProfessionAccountSkills to ProfessionSpecTracker.
--   Rebuilds nodeIndex to ensure consistency.
-------------------------------------------------------------------------------
function Data.Migrate(db)
    if (db.version or 0) < PST.DB_VERSION then
        -- Rebuild the nodeIndex from character data in case it's stale
        Data.RebuildNodeIndex(db)
        db.version = PST.DB_VERSION
        PST.Debug("Migrated DB to version", PST.DB_VERSION)
    end
end

-------------------------------------------------------------------------------
-- GetCharData – return (or create) the entry for a character.
---@param charKey string|nil   defaults to PST.GetCharKey()
---@return table  Character data subtable
-------------------------------------------------------------------------------
function Data.GetCharData(charKey)
    charKey = charKey or PST.GetCharKey()
    local db = PST.db
    if not db then return {} end

    if not db.characters[charKey] then
        db.characters[charKey] = {
            class       = PST.GetPlayerClassToken(),
            lastScan    = 0,
            professions = {},
        }
    end

    -- Always keep the class token fresh (in case of race/class change).
    -- Also clear syncedFrom: if we are the logged-in character, this is
    -- locally owned data, not synced data (prevents the sync-loop where
    -- our own character comes back tagged as "synced").
    if charKey == PST.GetCharKey() then
        db.characters[charKey].class = PST.GetPlayerClassToken()
        db.characters[charKey].syncedFrom = nil
    end

    return db.characters[charKey]
end

-------------------------------------------------------------------------------
-- SaveNodeData – store a single node's rank data for the current character.
--
-- Also updates the nodeIndex for O(1) tooltip lookups.
--
---@param skillLineID number   Expansion skill line ID for the profession
---@param professionName string  Localized name, e.g. "Midnight Blacksmithing"
---@param parentProfessionName string|nil  Base name, e.g. "Blacksmithing"
---@param treeID number        Spec tab tree ID
---@param tabName string       Localized tab name, e.g. "Armorsmithing"
---@param rootNodeID number    Root node of this tab tree
---@param nodeID number        The specific trait node
---@param rank number          Display rank (after subtracting unlock entry)
---@param maxRank number       Max display rank
---@param isLearned boolean|nil  true if the node is unlocked
-------------------------------------------------------------------------------
function Data.SaveNodeData(skillLineID, professionName, parentProfessionName,
                           treeID, tabName, rootNodeID, nodeID, rank, maxRank,
                           isLearned)
    local charKey  = PST.GetCharKey()
    local charData = Data.GetCharData(charKey)
    local db       = PST.db

    -- Ensure profession table
    if not charData.professions[skillLineID] then
        charData.professions[skillLineID] = {
            professionName       = professionName,
            parentProfessionName = parentProfessionName,
            tabs = {},
        }
    end
    local prof = charData.professions[skillLineID]
    prof.professionName       = professionName       -- refresh
    prof.parentProfessionName = parentProfessionName  -- refresh

    -- Ensure tab table
    if not prof.tabs[treeID] then
        prof.tabs[treeID] = {
            tabName    = tabName,
            rootNodeID = rootNodeID,
            nodes      = {},
        }
    end
    local tab = prof.tabs[treeID]
    tab.tabName    = tabName    -- refresh
    tab.rootNodeID = rootNodeID -- refresh

    -- Store or update node data
    tab.nodes[nodeID] = {
        rank    = rank,
        maxRank = maxRank,
    }

    -- Update reverse nodeIndex
    if not db.nodeIndex[nodeID] then
        db.nodeIndex[nodeID] = {}
    end

    if isLearned or rank > 0 then
        db.nodeIndex[nodeID][charKey] = {
            rank    = rank,
            maxRank = maxRank,
            class   = charData.class,
        }
    else
        -- Not learned, not invested → remove from index to keep it lean
        db.nodeIndex[nodeID][charKey] = nil
    end
end

-------------------------------------------------------------------------------
-- MarkScanComplete – stamp lastScan for the current character
-------------------------------------------------------------------------------
function Data.MarkScanComplete()
    local charData = Data.GetCharData()
    charData.lastScan = time()
end

-------------------------------------------------------------------------------
-- GetNodeAlts – return a sorted list of other characters' data for a nodeID.
--
-- Returns a table of { charKey, rank, maxRank, class } entries sorted by
-- rank descending.  The current character is excluded.
--
---@param nodeID number
---@return table[]  Array of { charKey=string, rank=number, maxRank=number, class=string }
-------------------------------------------------------------------------------
function Data.GetNodeAlts(nodeID)
    local db = PST.db
    if not db or not db.nodeIndex[nodeID] then
        return {}
    end

    local currentChar = PST.GetCharKey()
    local results = {}

    for charKey, info in pairs(db.nodeIndex[nodeID]) do
        if charKey ~= currentChar then
            local synced = false
            if db.characters and db.characters[charKey] and db.characters[charKey].syncedFrom then
                synced = true
            end
            results[#results + 1] = {
                charKey = charKey,
                rank    = info.rank,
                maxRank = info.maxRank,
                class   = info.class,
                synced  = synced,
            }
        end
    end

    -- Sort by rank descending, then by name ascending for ties
    table.sort(results, function(a, b)
        if a.rank ~= b.rank then
            return a.rank > b.rank
        end
        return a.charKey < b.charKey
    end)

    return results
end

-------------------------------------------------------------------------------
-- GetTabAlts – return other characters' invested points for a given treeID.
-- This is used when hovering a spec tab rather than an individual node.
-- We find the rootNodeID for that tree and look up the nodeIndex.
--
---@param treeID number  The spec tab tree ID
---@return table[]  Same format as GetNodeAlts
-------------------------------------------------------------------------------
function Data.GetTabAlts(treeID)
    local db = PST.db
    if not db then return {} end

    -- Find the rootNodeID for this tree by scanning character data
    local rootNodeID = nil
    for _, charData in pairs(db.characters) do
        if charData.professions then
            for _, prof in pairs(charData.professions) do
                if prof.tabs and prof.tabs[treeID] then
                    rootNodeID = prof.tabs[treeID].rootNodeID
                    break
                end
            end
        end
        if rootNodeID then break end
    end

    if not rootNodeID then return {} end
    return Data.GetNodeAlts(rootNodeID)
end

-------------------------------------------------------------------------------
-- RebuildNodeIndex – regenerate the entire nodeIndex from character data.
--   Used on migration or after a /pst wipe.
-------------------------------------------------------------------------------
function Data.RebuildNodeIndex(db)
    db = db or PST.db
    if not db then return end

    db.nodeIndex = {}
    for charKey, charData in pairs(db.characters or {}) do
        local classToken = charData.class or "UNKNOWN"
        for _, prof in pairs(charData.professions or {}) do
            for _, tab in pairs(prof.tabs or {}) do
                for nodeID, nodeData in pairs(tab.nodes or {}) do
                    if not db.nodeIndex[nodeID] then
                        db.nodeIndex[nodeID] = {}
                    end
                    db.nodeIndex[nodeID][charKey] = {
                        rank    = nodeData.rank or 0,
                        maxRank = nodeData.maxRank or 0,
                        class   = classToken,
                    }
                end
            end
        end
    end
    PST.Debug("RebuildNodeIndex complete")
end

-------------------------------------------------------------------------------
-- DeleteCharacter – remove a single character from DB and nodeIndex.
---@param charKey string  "Name-Realm"
---@return boolean  true if the character existed and was deleted
-------------------------------------------------------------------------------
function Data.DeleteCharacter(charKey)
    local db = PST.db
    if not db or not db.characters or not db.characters[charKey] then
        return false
    end

    -- Remove from characters table
    db.characters[charKey] = nil

    -- Remove from nodeIndex
    if db.nodeIndex then
        for nodeID, chars in pairs(db.nodeIndex) do
            chars[charKey] = nil
        end
    end

    PST.Debug("Deleted character:", charKey)
    return true
end

-------------------------------------------------------------------------------
-- Known base profession names.  Used to extract the canonical name from
-- expansion-prefixed variants ("Khaz Algar Herbalism" → "Herbalism",
-- "Midnight Tailoring" → "Tailoring") when parentProfessionName is missing.
-------------------------------------------------------------------------------
local BASE_PROFESSIONS = {
    ["Alchemy"]        = true,
    ["Blacksmithing"]  = true,
    ["Enchanting"]     = true,
    ["Engineering"]    = true,
    ["Herbalism"]      = true,
    ["Inscription"]    = true,
    ["Jewelcrafting"]  = true,
    ["Leatherworking"] = true,
    ["Mining"]         = true,
    ["Skinning"]       = true,
    ["Tailoring"]      = true,
    ["Cooking"]        = true,
    ["Fishing"]        = true,
}

-------------------------------------------------------------------------------
-- GetDisplayProfessionName – return a clean display name for a profession.
-- Prefers parentProfessionName (e.g. "Blacksmithing") over the expansion-
-- prefixed professionName (e.g. "Midnight Blacksmithing").
---@param prof table  Profession data subtable
---@return string
-------------------------------------------------------------------------------
local function GetDisplayProfessionName(prof)
    if prof.parentProfessionName and prof.parentProfessionName ~= "" then
        return prof.parentProfessionName
    end
    -- Fallback: scan the profession name for a known base name suffix.
    -- Handles multi-word expansion prefixes ("Khaz Algar Herbalism").
    local name = prof.professionName or "?"
    for base in pairs(BASE_PROFESSIONS) do
        if name:find(base, 1, true) then     -- plain-text find (no patterns)
            return base
        end
    end
    -- Last resort: return the raw name (better than a bad strip)
    return name
end

-- Expose for Comm.lua merge labels
Data.GetDisplayProfessionName = GetDisplayProfessionName

-------------------------------------------------------------------------------
-- GetAllCharacters – return a sorted list of stored character info for the
--   settings panel.
---@return table[]  Array of { charKey, class, lastScan, profNames, synced }
-------------------------------------------------------------------------------
function Data.GetAllCharacters()
    local db = PST.db
    if not db or not db.characters then return {} end

    local results = {}
    for charKey, charData in pairs(db.characters) do
        local profNames = {}
        local seen = {}
        for skillLineID, prof in pairs(charData.professions or {}) do
            local displayName = GetDisplayProfessionName(prof)
            if not seen[displayName] then
                seen[displayName] = true
                profNames[#profNames + 1] = displayName
            end
        end
        table.sort(profNames)

        results[#results + 1] = {
            charKey   = charKey,
            class     = charData.class or "UNKNOWN",
            lastScan  = charData.lastScan or 0,
            profNames = profNames,
            synced    = charData.syncedFrom ~= nil,
        }
    end

    -- Sort by name
    table.sort(results, function(a, b) return a.charKey < b.charKey end)
    return results
end

-------------------------------------------------------------------------------
-- WipeAll – nuke all saved data.  Called via /pst wipe.
-------------------------------------------------------------------------------
function Data.WipeAll()
    ProfessionSpecTrackerDB = {
        version    = PST.DB_VERSION,
        characters = {},
        nodeIndex  = {},
    }
    PST.db = ProfessionSpecTrackerDB
    PST.Debug("All data wiped")
end

-------------------------------------------------------------------------------
-- PrintStatus – display a summary of stored character data.
-------------------------------------------------------------------------------
function Data.PrintStatus()
    local db = PST.db
    if not db then
        print("|cff33ccff[PST]|r No database loaded.")
        return
    end

    local count = Data.CountCharacters()
    print("|cff33ccff[PST]|r Database v" .. (db.version or "?") .. " – " .. count .. " character(s) stored:")

    for charKey, charData in pairs(db.characters or {}) do
        local profNames = {}
        for _, prof in pairs(charData.professions or {}) do
            profNames[#profNames + 1] = GetDisplayProfessionName(prof)
        end
        local profStr = (#profNames > 0) and table.concat(profNames, ", ") or "none"
        local classColored = PST.ClassColorWrap(charKey, charData.class or "UNKNOWN")
        local scanTime = charData.lastScan and date("%Y-%m-%d %H:%M", charData.lastScan) or "never"
        local syncTag = charData.syncedFrom and " |cffa0a0a0(synced)|r" or ""
        print("  " .. classColored .. "  –  " .. profStr .. "  (last scan: " .. scanTime .. ")" .. syncTag)
    end
end

-------------------------------------------------------------------------------
-- CountCharacters – utility for display
-------------------------------------------------------------------------------
function Data.CountCharacters()
    local n = 0
    if PST.db and PST.db.characters then
        for _ in pairs(PST.db.characters) do
            n = n + 1
        end
    end
    return n
end
