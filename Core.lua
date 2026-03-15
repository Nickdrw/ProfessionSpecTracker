-------------------------------------------------------------------------------
-- Core.lua – Addon initialization, event dispatch, slash commands
--
-- Responsibilities:
--   • Create the hidden event frame
--   • Dispatch ADDON_LOADED  → Data.Init()
--   • Dispatch PLAYER_LOGIN  → Scanner.TryScanAll()
--   • Dispatch profession-related events → Scanner
--   • Register /pst slash command
--
-- Depends on: Utils.lua (PST namespace)
-------------------------------------------------------------------------------

local ADDON_NAME, PST = ...

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------
PST.ADDON_NAME      = ADDON_NAME
PST.DB_VERSION      = 3          -- Bump when SavedVariables schema changes
PST.SCAN_THROTTLE   = 2.0        -- Min seconds between full scans

-------------------------------------------------------------------------------
-- Event frame – a hidden frame that receives WoW events
-------------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
PST.eventFrame = eventFrame

-- Table of event → handler mappings, populated below and by other modules.
-- Each entry is a list of callbacks: { function(self, event, ...) }
PST._eventHandlers = PST._eventHandlers or {}

--- Register a handler for a WoW event.  Multiple handlers per event are fine.
---@param event string  Event name, e.g. "PLAYER_LOGIN"
---@param handler function(self, event, ...)
function PST.RegisterEvent(event, handler)
    if not PST._eventHandlers[event] then
        PST._eventHandlers[event] = {}
        eventFrame:RegisterEvent(event)
    end
    table.insert(PST._eventHandlers[event], handler)
end

--- Unregister a specific handler for an event.
---@param event string
---@param handler function
function PST.UnregisterEvent(event, handler)
    local handlers = PST._eventHandlers[event]
    if not handlers then return end
    for i = #handlers, 1, -1 do
        if handlers[i] == handler then
            table.remove(handlers, i)
        end
    end
    if #handlers == 0 then
        PST._eventHandlers[event] = nil
        eventFrame:UnregisterEvent(event)
    end
end

-- Central dispatcher
eventFrame:SetScript("OnEvent", function(self, event, ...)
    local handlers = PST._eventHandlers[event]
    if handlers then
        for _, handler in ipairs(handlers) do
            handler(self, event, ...)
        end
    end
end)

-------------------------------------------------------------------------------
-- ADDON_LOADED – Initialize saved variables and modules
-------------------------------------------------------------------------------
local function OnAddonLoaded(self, event, addonName)
    if addonName ~= ADDON_NAME then return end

    -- Initialize the database (Data.lua)
    if PST.Data and PST.Data.Init then
        PST.Data.Init()
    end

    -- Initialize config defaults (Config.lua)
    if PST.Config and PST.Config.InitDefaults then
        PST.Config.InitDefaults()
    end

    -- Build the Settings panel (requires DB to be ready)
    if PST.Config and PST.Config.SetupPanel then
        PST.Config.SetupPanel()
    end

    PST.Debug("ADDON_LOADED – database initialized")

    -- Remove only THIS handler.  Other modules (e.g. Tooltip.lua) may also
    -- listen for ADDON_LOADED to detect Blizzard_Professions loading.
    PST.UnregisterEvent("ADDON_LOADED", OnAddonLoaded)
end
PST.RegisterEvent("ADDON_LOADED", OnAddonLoaded)

-------------------------------------------------------------------------------
-- PLAYER_LOGIN – Kick off initial scan attempt
-------------------------------------------------------------------------------
PST.RegisterEvent("PLAYER_LOGIN", function(self, event)
    -- Cache player info now that it's reliably available
    PST._charKey = nil  -- force re-cache
    PST.GetCharKey()

    -- Print a one-time startup message so the user knows the addon loaded.
    local version = C_AddOns and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")
                    or "?"
    print("|cff33ccff[Profession Spec Tracker]|r v" .. version .. " loaded – " .. PST._charKey)
    PST.Debug("PLAYER_LOGIN – char key:", PST._charKey)

    -- Attempt a scan.  It may partially fail if profession data isn't loaded
    -- yet, but the trade-skill events will fill in the gaps later.
    if PST.Scanner and PST.Scanner.TryScanAll then
        -- Delay slightly so other addons and Blizzard frames finish loading
        C_Timer.After(3, function()
            PST.Scanner.TryScanAll("PLAYER_LOGIN delayed")
        end)
    end
end)

-------------------------------------------------------------------------------
-- Profession-related events → forwarded to the Scanner module
--
-- TRADE_SKILL_SHOW                   fires when the player opens a profession
-- TRADE_SKILL_DATA_SOURCE_CHANGED    fires when profession data finishes loading
-- SKILL_LINE_SPECS_RANKS_CHANGED     fires when specialization points change
-- TRAIT_CONFIG_UPDATED               fires when a trait config is committed
-- TRAIT_NODE_CHANGED                 fires when a specific node changes ranks
-------------------------------------------------------------------------------
local professionEvents = {
    "TRADE_SKILL_SHOW",
    "TRADE_SKILL_DATA_SOURCE_CHANGED",
    "SKILL_LINE_SPECS_RANKS_CHANGED",
    "TRAIT_CONFIG_UPDATED",
    "TRAIT_NODE_CHANGED",
}

for _, evt in ipairs(professionEvents) do
    PST.RegisterEvent(evt, function(self, event, ...)
        PST.Debug("Event:", event, ...)
        if PST.Scanner and PST.Scanner.OnEvent then
            PST.Scanner.OnEvent(event, ...)
        end
    end)
end

-------------------------------------------------------------------------------
-- Slash command: /pst
--   /pst              – print status
--   /pst debug        – toggle debug logging
--   /pst scan         – force a rescan
--   /pst wipe         – wipe ALL saved data (after confirmation)
--   /pst status       – show stored character summary
-------------------------------------------------------------------------------
SLASH_PST1 = "/pst"
SLASH_PST2 = "/profspectracker"

SlashCmdList["PST"] = function(input)
    local cmd = (input or ""):lower():trim()

    if cmd == "debug" then
        PST.debugEnabled = not PST.debugEnabled
        print("|cff33ccff[PST]|r Debug mode:", PST.debugEnabled and "|cff00ff00ON|r" or "|cffff0000OFF|r")

    elseif cmd == "scan" then
        print("|cff33ccff[PST]|r Forcing a full scan...")
        if PST.Scanner and PST.Scanner.TryScanAll then
            PST.Scanner.TryScanAll("manual /pst scan")
        end

    elseif cmd == "wipe" then
        if PST.Data and PST.Data.WipeAll then
            PST.Data.WipeAll()
            print("|cff33ccff[PST]|r All saved data has been wiped.")
        end

    elseif cmd == "status" then
        if PST.Data and PST.Data.PrintStatus then
            PST.Data.PrintStatus()
        else
            print("|cff33ccff[PST]|r No data module loaded.")
        end

    elseif cmd == "test" then
        -- Diagnostic: dump nodeIndex summary so user can verify data exists
        if not PST.db or not PST.db.nodeIndex then
            print("|cff33ccff[PST]|r No node index data found. Open a profession with specializations first.")
        else
            local nodeCount = 0
            for _ in pairs(PST.db.nodeIndex) do
                nodeCount = nodeCount + 1
            end
            print("|cff33ccff[PST]|r Node index has", nodeCount, "unique nodes tracked.")
            -- Show first 3 nodes as sample
            local shown = 0
            for nodeID, chars in pairs(PST.db.nodeIndex) do
                if shown >= 3 then break end
                local charList = {}
                for charKey, info in pairs(chars) do
                    local name = PST.ClassColorWrap(charKey, info.class)
                    charList[#charList + 1] = name .. " (" .. info.rank .. ")"
                end
                print("  nodeID", nodeID, ":", table.concat(charList, ", "))
                shown = shown + 1
            end
            if nodeCount > 3 then
                print("  ... and", nodeCount - 3, "more nodes")
            end
        end

    elseif cmd == "sync" then
        if PST.Comm and PST.Comm.TriggerSync then
            PST.Comm.TriggerSync()
        else
            print("|cff33ccff[PST]|r Comm module not loaded.")
        end

    elseif cmd == "config" or cmd == "options" or cmd == "settings" then
        if PST.Config and PST.Config.OpenPanel then
            PST.Config.OpenPanel()
        else
            print("|cff33ccff[PST]|r Config module not loaded.")
        end

    elseif cmd:sub(1, 10) == "directsync" or cmd:sub(1, 9) == "whitelist" then
        -- "directsync" is the canonical command; "whitelist" kept as hidden alias
        local sub
        if cmd:sub(1, 10) == "directsync" then
            sub = cmd:sub(12):trim()
        else
            sub = cmd:sub(11):trim()
        end
        if not PST.Config then
            print("|cff33ccff[PST]|r Config module not loaded.")
        elseif sub == "" or sub == "list" then
            -- List current direct sync targets
            local list = PST.Config.GetDirectSyncList()
            local names = {}
            for name in pairs(list) do names[#names + 1] = name end
            table.sort(names)
            if #names == 0 then
                print("|cff33ccff[PST]|r Direct sync list is |cff00ff00empty|r — no targeted whisper sync active.")
            else
                print("|cff33ccff[PST]|r Direct sync targets (" .. #names .. "):")
                for _, name in ipairs(names) do
                    print("  |cffffffff" .. name .. "|r")
                end
            end
        elseif sub:sub(1, 4) == "add " then
            local name = sub:sub(5):trim()
            if name ~= "" then
                if not name:find("-") then
                    local _, realm = UnitFullName("player")
                    if realm and realm ~= "" then
                        name = name .. "-" .. realm
                    end
                end
                name = name:sub(1, 1):upper() .. name:sub(2)
                PST.Config.AddDirectSyncTarget(name)
                print("|cff33ccff[PST]|r Added |cffffffff" .. name .. "|r to direct sync list.")
            end
        elseif sub:sub(1, 7) == "remove " then
            local name = sub:sub(8):trim()
            if name ~= "" then
                PST.Config.RemoveDirectSyncTarget(name)
                print("|cff33ccff[PST]|r Removed |cffffffff" .. name .. "|r from direct sync list.")
            end
        elseif sub == "clear" then
            if PST.db and PST.db.config then
                PST.db.config.directSyncTargets = {}
                print("|cff33ccff[PST]|r Direct sync list cleared — no targeted whisper sync active.")
            end
        else
            print("|cff33ccff[PST]|r Direct Sync commands:")
            print("  |cffffff00/pst directsync|r         – Show current direct sync targets")
            print("  |cffffff00/pst directsync add Name-Realm|r   – Add a character")
            print("  |cffffff00/pst directsync remove Name-Realm|r – Remove a character")
            print("  |cffffff00/pst directsync clear|r    – Clear the direct sync list")
        end

    else
        local version = C_AddOns and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")
                        or "?"
        print("|cff33ccff[Profession Spec Tracker]|r v" .. version)
        print("  |cffffff00/pst debug|r   – Toggle debug logging")
        print("  |cffffff00/pst scan|r    – Force rescan of current professions")
        print("  |cffffff00/pst status|r  – Show stored character summary")
        print("  |cffffff00/pst sync|r    – Force sync with guild (cross-account)")
        print("  |cffffff00/pst config|r  – Open settings panel")
        print("  |cffffff00/pst directsync|r – Manage direct sync targets")
        print("  |cffffff00/pst wipe|r    – Wipe all saved data")
        print("  |cffffff00/pst test|r    – Show test tooltip info for debugging")
    end
end
