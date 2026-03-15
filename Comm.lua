-------------------------------------------------------------------------------
-- Comm.lua – Cross-account synchronization
--
-- Two independent sync mechanisms:
--
--   1. GUILD SYNC (toggle in settings)
--      Broadcasts HELLO to the entire guild.  Any guild member running
--      this addon will respond with newer data.
--
--   2. DIRECT SYNC (always active when targets are configured)
--      Whispers HELLO directly to each direct sync character on login
--      and after each scan.  Independent of the guild sync toggle.
--
-- Protocol overview:
--
--   1. HELLO  (H|charKey1:ts1,charKey2:ts2,...)
--      Broadcast on login and after each scan.  Lists every character the
--      sender knows about together with their lastScan timestamp.
--
--   2. PUSH   (P|charKey~class~lastScan~nodeID:rank:maxRank,...~profData)
--      Sent in response to a HELLO when the sender has newer data for
--      characters the other side is missing or has stale.
--
--   3. CHUNK  (C|msgID|totalChunks|chunkIdx|innerPayload)
--      Wrapper for messages that exceed the 255-byte per-message limit.
--      The inner payload is reassembled on the receiving end and then
--      processed as a regular HELLO or PUSH message.
--
-- Flow:
--   A logs in → broadcasts HELLO after scan.
--   B (other account, same guild) receives HELLO → compares timestamps →
--     pushes characters A is missing → echoes its own HELLO (throttled).
--   A receives B's HELLO → pushes characters B is missing.
--   A receives B's PUSH messages → merges into local DB + nodeIndex.
--   Done – both sides are in sync.
--
-- Throttling:
--   • BroadcastHello is limited to once per SYNC_COOLDOWN (30 s) to
--     prevent infinite HELLO ping-pong.
--   • Pushes are staggered (0.2 s between characters) to avoid flooding.
--   • Chunk sends are staggered (0.15 s between chunks).
--
-- Depends on: Utils.lua, Core.lua, Data.lua
-------------------------------------------------------------------------------

local _, PST = ...

PST.Comm = PST.Comm or {}
local Comm = PST.Comm

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------
local PREFIX              = "PST"        -- addon message prefix (max 16 chars)
local CHANNEL             = "GUILD"      -- distribution channel
local CHUNK_SIZE          = 240          -- max bytes of payload per message
local SYNC_COOLDOWN       = 30           -- seconds between HELLO broadcasts
local REASSEMBLY_TIMEOUT  = 30           -- seconds before we discard partial chunks
local PUSH_STAGGER        = 0.2          -- seconds between pushing each character

-- Message type tags (single character to save bytes)
local T_HELLO = "H"
local T_PUSH  = "P"
local T_CHUNK = "C"

-------------------------------------------------------------------------------
-- Module state
-------------------------------------------------------------------------------
local prefixRegistered    = false
local lastBroadcastTime   = 0            -- GetTime() of last HELLO send
local reassemblyBuffers   = {}           -- [senderKey] = { total, received, timer }
local msgCounter          = 0            -- monotonic counter for chunk msgIDs
local recentHelloEchoes   = {}           -- [sender] = GetTime() – anti-ping-pong

-- Merge feedback batching
local mergedEntries = {}          -- collected during the batch window
local mergeTimer    = nil

local function ReportMerges()
    local count = #mergedEntries
    if count > 0 and PST.Config.Get("chatOutput") then
        local parts = {}
        for _, entry in ipairs(mergedEntries) do
            parts[#parts + 1] = entry
        end
        print("|cff33ccff[PST]|r Synced " .. count .. " character(s): " .. table.concat(parts, ", "))
    end
    mergedEntries = {}
    mergeTimer = nil
end

--- Build a display string for a just-merged character.
local function BuildMergeLabel(charKey)
    local db = PST.db
    local charData = db and db.characters and db.characters[charKey]
    if not charData then return charKey end

    local seen = {}
    local names = {}
    for _, prof in pairs(charData.professions or {}) do
        local displayName = PST.Data.GetDisplayProfessionName(prof)
        if not seen[displayName] then
            seen[displayName] = true
            names[#names + 1] = displayName
        end
    end
    table.sort(names)

    if #names > 0 then
        return charKey .. " (" .. table.concat(names, ", ") .. ")"
    end
    return charKey
end

---@param charKey string  "Name-Realm" of the character just merged
local function NotifyMerge(charKey)
    mergedEntries[#mergedEntries + 1] = BuildMergeLabel(charKey)
    if mergeTimer then
        mergeTimer:Cancel()
    end
    -- Wait a few seconds for additional merges before printing summary
    mergeTimer = C_Timer.NewTimer(3, ReportMerges)
end

-------------------------------------------------------------------------------
-- Init – register the addon message prefix.
-- MUST be called before any addon message with prefix "PST" can be received.
-- WoW silently drops messages for unregistered prefixes.
-------------------------------------------------------------------------------
function Comm.Init()
    if prefixRegistered then return end
    local ok = C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    if not ok then
        -- Might already be registered (returns false), which is fine.
        PST.Debug("Comm: RegisterAddonMessagePrefix returned false (may already be registered)")
    end
    prefixRegistered = true
    PST.Debug("Comm: Prefix registered")
end

-- Register prefix IMMEDIATELY at file load time.
-- This is critical: WoW won't deliver CHAT_MSG_ADDON for unregistered prefixes.
Comm.Init()

-------------------------------------------------------------------------------
-- Self-detection: ignore our own guild messages (WoW echoes them back).
-- Use Ambiguate to normalize sender names across same/cross realm.
-------------------------------------------------------------------------------
local function IsSelf(sender)
    if not sender then return true end
    -- Ambiguate strips the realm suffix when it matches the player's realm
    local normalizedSender = Ambiguate(sender, "none")
    local myName = UnitName("player")
    if normalizedSender == myName then return true end
    -- Also compare full Name-Realm in case Ambiguate behaves unexpectedly
    local myFullName = PST.GetCharKey()
    if sender == myFullName then return true end
    return false
end

-------------------------------------------------------------------------------
-- Serialization helpers
-------------------------------------------------------------------------------

--- Build HELLO payload: "charKey1:ts1,charKey2:ts2,..."
local function BuildHelloPayload()
    local db = PST.db
    if not db or not db.characters then return nil end

    local parts = {}
    for charKey, charData in pairs(db.characters) do
        parts[#parts + 1] = charKey .. ":" .. (charData.lastScan or 0)
    end
    if #parts == 0 then return nil end
    return table.concat(parts, ",")
end

--- Parse HELLO payload → { [charKey] = lastScan (number) }
local function ParseHelloPayload(payload)
    local result = {}
    for entry in payload:gmatch("[^,]+") do
        local charKey, ts = entry:match("^(.+):(%d+)$")
        if charKey and ts then
            result[charKey] = tonumber(ts)
        end
    end
    return result
end

--- Serialize one character's invested-node data for transmission.
--- Format: "charKey~class~lastScan~nodeID:rank:maxRank,...~skillLineID/profName/parentName;..."
--- Uses ~ as field separator (printable, safe for WoW addon messages).
---@param charKey string
---@return string|nil
local function SerializeCharData(charKey)
    local db = PST.db
    if not db or not db.characters or not db.characters[charKey] then return nil end

    local charData = db.characters[charKey]
    local nodeParts = {}

    -- Collect from nodeIndex (includes learned rank-0 nodes)
    if db.nodeIndex then
        for nodeID, charEntries in pairs(db.nodeIndex) do
            local entry = charEntries[charKey]
            if entry then
                nodeParts[#nodeParts + 1] = nodeID .. ":" .. (entry.rank or 0)
                                            .. ":" .. (entry.maxRank or 0)
            end
        end
    end

    -- Build profession summary (5th field)
    -- Format per entry: skillLineID/professionName/parentProfessionName
    -- Entries separated by ";"
    local profParts = {}
    for skillLineID, prof in pairs(charData.professions or {}) do
        local pName  = (prof.professionName or "?"):gsub("[~/;]", "")
        local ppName = (prof.parentProfessionName or pName):gsub("[~/;]", "")
        profParts[#profParts + 1] = skillLineID .. "/" .. pName .. "/" .. ppName
    end

    return charKey  .. "~" .. (charData.class or "UNKNOWN")
                    .. "~" .. (charData.lastScan or 0)
                    .. "~" .. table.concat(nodeParts, ",")
                    .. "~" .. table.concat(profParts, ";")
end

--- Deserialize pushed character data and merge into local DB + nodeIndex.
--- Supports both old (4-field) and new (5-field) format.
--- Returns true if new data was actually merged.
---@param payload string
---@return boolean merged
local function DeserializeAndMerge(payload)
    -- Split on ~ (tilde) – we expect 4 or 5 fields
    local fields = {}
    for field in (payload .. "~"):gmatch("([^~]*)~") do
        fields[#fields + 1] = field
    end

    local charKey = fields[1]
    local class   = fields[2]
    local tsStr   = fields[3]
    local nodeStr = fields[4] or ""
    local profStr = fields[5]          -- may be nil (old protocol)

    if not charKey or not class or not tsStr then
        PST.DebugWarn("Comm: Failed to parse pushed data, payload start:", payload:sub(1, 60))
        return false
    end

    local lastScan = tonumber(tsStr) or 0
    local db = PST.db
    if not db then return false end

    -- Skip if local data is already same age or newer
    if db.characters[charKey] and (db.characters[charKey].lastScan or 0) >= lastScan then
        PST.Debug("Comm: Skip merge for", charKey, "– local data same/newer")
        return false
    end

    -- Create or update the character entry.
    if not db.characters[charKey] then
        db.characters[charKey] = {
            class       = class,
            lastScan    = lastScan,
            professions = {},
            syncedFrom  = "guild",
        }
    else
        db.characters[charKey].class      = class
        db.characters[charKey].lastScan   = lastScan
        db.characters[charKey].syncedFrom = "guild"
    end

    -- Parse profession summary (5th field) if present.
    -- Replace the professions table entirely so stale entries from previous
    -- syncs are removed (e.g. character dropped a profession since last push).
    if profStr and profStr ~= "" then
        db.characters[charKey].professions = {}
        local profs = db.characters[charKey].professions
        for entry in profStr:gmatch("[^;]+") do
            local sidStr, pName, ppName = entry:match("^(%d+)/([^/]*)/([^/]*)$")
            if sidStr then
                local sid = tonumber(sidStr)
                if sid then
                    if not profs[sid] then
                        profs[sid] = { tabs = {} }
                    end
                    profs[sid].professionName       = (pName ~= "") and pName or nil
                    profs[sid].parentProfessionName  = (ppName ~= "") and ppName or nil
                end
            end
        end
    end

    -- Merge node data into the reverse nodeIndex (used by tooltip)
    if nodeStr and nodeStr ~= "" then
        for entry in nodeStr:gmatch("[^,]+") do
            local nid, r, mr = entry:match("^(%d+):(%d+):(%d+)$")
            if nid then
                local nodeID  = tonumber(nid)
                local rank    = tonumber(r)
                local maxRank = tonumber(mr)

                if rank then
                    if not db.nodeIndex[nodeID] then
                        db.nodeIndex[nodeID] = {}
                    end
                    db.nodeIndex[nodeID][charKey] = {
                        rank    = rank,
                        maxRank = maxRank,
                        class   = class,
                    }
                end
            end
        end
    end

    PST.Debug("Comm: Merged remote data for", charKey,
              "scanned at", date("%Y-%m-%d %H:%M", lastScan))
    NotifyMerge(charKey)
    return true
end

-------------------------------------------------------------------------------
-- Low-level sending
-------------------------------------------------------------------------------

--- Low-level send: broadcast on GUILD channel.
local function SendRaw(text)
    PST.Debug("Comm: SendRaw len=", #text, "preview:", text:sub(1, 40):gsub("|", "||"))
    local ok = C_ChatInfo.SendAddonMessage(PREFIX, text, CHANNEL)
    if not ok then
        PST.DebugWarn("Comm: SendAddonMessage FAILED! len=", #text)
    else
        PST.Debug("Comm: SendAddonMessage OK")
    end
    return ok
end

--- Low-level send: WHISPER to a specific character.
---@param text string   The full raw message to send
---@param target string The recipient character "Name-Realm"
local function SendWhisper(text, target)
    PST.Debug("Comm: SendWhisper to", target, "len=", #text, "preview:", text:sub(1, 40):gsub("|", "||"))
    local ok = C_ChatInfo.SendAddonMessage(PREFIX, text, "WHISPER", target)
    if not ok then
        PST.DebugWarn("Comm: SendAddonMessage WHISPER FAILED! target:", target, "len=", #text)
    else
        PST.Debug("Comm: SendAddonMessage WHISPER OK")
    end
    return ok
end

--- Send a typed message, automatically chunking if it exceeds CHUNK_SIZE.
--- If target is provided, sends via WHISPER; otherwise broadcasts on GUILD.
---@param msgType string        T_HELLO or T_PUSH
---@param payload string
---@param target  string|nil    Whisper target ("Name-Realm"), nil = GUILD
local function SendMessage(msgType, payload, target)
    local full = msgType .. "|" .. payload
    local sendFn = target and function(t) return SendWhisper(t, target) end or SendRaw

    if #full <= CHUNK_SIZE then
        -- Fits in one message – send directly
        sendFn(full)
        return
    end

    -- Need to chunk.  Reserve ~20 bytes for the chunk header.
    local dataSize = CHUNK_SIZE - 20
    msgCounter = msgCounter + 1
    local msgID = tostring(msgCounter)

    local chunks = {}
    for i = 1, #full, dataSize do
        chunks[#chunks + 1] = full:sub(i, i + dataSize - 1)
    end

    for i, chunk in ipairs(chunks) do
        -- Stagger sends to respect chat throttle
        local chunkIdx = i
        local totalChunks = #chunks
        C_Timer.After((i - 1) * 0.15, function()
            local raw = T_CHUNK .. "|" .. msgID .. "|" .. totalChunks
                        .. "|" .. chunkIdx .. "|" .. chunk
            PST.Debug("Comm: Sending chunk", chunkIdx, "/", totalChunks, "len=", #raw)
            sendFn(raw)
        end)
    end

    PST.Debug("Comm: Queued chunked message, type:", msgType,
              "totalLen:", #full, "chunks:", #chunks)
end

-------------------------------------------------------------------------------
-- Chunk reassembly
-------------------------------------------------------------------------------

local function CleanupReassembly(key)
    if reassemblyBuffers[key] then
        if reassemblyBuffers[key].timer then
            reassemblyBuffers[key].timer:Cancel()
        end
        reassemblyBuffers[key] = nil
    end
end

--- Handle a fully-reassembled (or single-part) message.
---@param text string    The complete message (type|payload)
---@param sender string  The character who sent it ("Name-Realm")
local function HandleCompleteMessage(text, sender)
    local msgType = text:sub(1, 1)
    local payload = text:match("^[^|]+|(.+)$")
    if not msgType or not payload then
        PST.DebugWarn("Comm: HandleCompleteMessage – failed to parse, text:", text:sub(1, 40))
        return
    end

    PST.Debug("Comm: HandleCompleteMessage type:", msgType, "payloadLen:", #payload)

    if msgType == T_HELLO then
        Comm.HandleHello(payload, sender)
    elseif msgType == T_PUSH then
        local ok = DeserializeAndMerge(payload)
        PST.Debug("Comm: PUSH merge result:", ok and "merged" or "skipped")
    else
        PST.DebugWarn("Comm: Unknown message type:", msgType)
    end
end

--- Process one chunk; reassemble if all chunks for a msgID have arrived.
local function HandleChunk(sender, msgID, totalStr, idxStr, chunkData)
    local total = tonumber(totalStr) or 1
    local idx   = tonumber(idxStr) or 1
    local key   = sender .. "|" .. msgID

    if not reassemblyBuffers[key] then
        reassemblyBuffers[key] = {
            total    = total,
            received = {},
            timer    = C_Timer.NewTimer(REASSEMBLY_TIMEOUT, function()
                PST.DebugWarn("Comm: Chunk reassembly timeout:", key)
                CleanupReassembly(key)
            end),
        }
    end

    reassemblyBuffers[key].received[idx] = chunkData

    -- Check if all chunks have arrived
    for i = 1, total do
        if not reassemblyBuffers[key].received[i] then
            return -- still waiting
        end
    end

    -- All chunks received → reassemble and process
    local full = table.concat(reassemblyBuffers[key].received)
    CleanupReassembly(key)
    HandleCompleteMessage(full, sender)
end

-------------------------------------------------------------------------------
-- HELLO broadcast
-------------------------------------------------------------------------------

--- Broadcast our character list + timestamps to the guild.
--- Throttled to once per SYNC_COOLDOWN seconds.
---@param force boolean|nil  If true, ignore cooldown (for /pst sync)
function Comm.BroadcastHello(force)
    if not IsInGuild() then
        PST.Debug("Comm: BroadcastHello skipped – not in guild")
        return
    end
    if not PST.db then
        PST.Debug("Comm: BroadcastHello skipped – no DB")
        return
    end
    if not PST.Config.Get("guildSync") then
        PST.Debug("Comm: BroadcastHello skipped – guild sync disabled")
        return
    end

    local now = GetTime()
    if not force and (now - lastBroadcastTime) < SYNC_COOLDOWN then
        PST.Debug("Comm: HELLO throttled")
        return
    end
    lastBroadcastTime = now

    local payload = BuildHelloPayload()
    if not payload then
        PST.Debug("Comm: BroadcastHello skipped – no character data")
        return
    end

    Comm.Init()  -- ensure prefix is registered (should already be)
    SendMessage(T_HELLO, payload)
    PST.Debug("Comm: Broadcast HELLO (", #payload, "bytes)")
end

-------------------------------------------------------------------------------
-- HELLO handler – compare timestamps, push newer data
-------------------------------------------------------------------------------

--- Handle incoming HELLO: compare timestamps and push newer data.
--- PUSH responses are sent via WHISPER directly to the requester.
---@param payload string  The HELLO payload (charKey:ts,...)
---@param sender  string  The character who sent the HELLO ("Name-Realm")
function Comm.HandleHello(payload, sender)
    local theirChars = ParseHelloPayload(payload)
    local db = PST.db
    if not db or not db.characters then return end

    local pushCount = 0
    for charKey, charData in pairs(db.characters) do
        -- Only push characters we scanned locally (syncedFrom == nil).
        -- Synced characters should only be pushed by the account that
        -- originally scanned them, preventing data from bouncing back
        -- to the originator in a loop (A → B → A).
        if not charData.syncedFrom then
            local ourTS   = charData.lastScan or 0
            local theirTS = theirChars[charKey] or 0

            if ourTS > theirTS then
                pushCount = pushCount + 1
                -- Stagger pushes to avoid flooding
                local delay = pushCount * PUSH_STAGGER + math.random() * 0.3
                local ck = charKey       -- capture for closure
                local replyTo = sender   -- capture for closure
                C_Timer.After(delay, function()
                    local serialized = SerializeCharData(ck)
                    if serialized then
                        PST.Debug("Comm: Pushing data for", ck, "via WHISPER to", replyTo, "serializedLen:", #serialized)
                        SendMessage(T_PUSH, serialized, replyTo)  -- WHISPER back
                        PST.Debug("Comm: Pushed data for", ck)
                    else
                        PST.DebugWarn("Comm: SerializeCharData returned nil for", ck)
                    end
                end)
            end
        end -- locally scanned only
    end

    -- Echo our own HELLO back to the sender via WHISPER so they can push
    -- any data we're missing.
    -- Anti-ping-pong: only echo once per sender per SYNC_COOLDOWN window.
    local now = GetTime()
    if not recentHelloEchoes[sender] or (now - recentHelloEchoes[sender]) > SYNC_COOLDOWN then
        recentHelloEchoes[sender] = now
        C_Timer.After(1 + math.random(), function()
            local echoPayload = BuildHelloPayload()
            if echoPayload then
                Comm.Init()
                PST.Debug("Comm: Echoing HELLO back to", sender, "via WHISPER")
                SendMessage(T_HELLO, echoPayload, sender)
            end
        end)
    else
        PST.Debug("Comm: Skipping HELLO echo to", sender, "– already echoed recently")
    end

    PST.Debug("Comm: Received HELLO from", sender, "pushing", pushCount, "character(s) via WHISPER")
end

-------------------------------------------------------------------------------
-- CHAT_MSG_ADDON handler – entry point for all received addon messages
-------------------------------------------------------------------------------

--- Event handler registered via PST.RegisterEvent.
---@param self table   Event frame
---@param event string "CHAT_MSG_ADDON"
---@param prefix string
---@param text string
---@param channel string
---@param sender string
function Comm.OnAddonMessage(self, event, prefix, text, channel, sender, ...)
    -- Log ALL PST-prefix addon messages for diagnostics
    if prefix == PREFIX then
        PST.Debug("Comm: CHAT_MSG_ADDON from", sender, "ch:", channel,
                  "type:", text:sub(1, 1), "len:", #text)
    end

    if prefix ~= PREFIX then return end
    if IsSelf(sender) then
        PST.Debug("Comm: Ignoring own message from", sender)
        return
    end

    -- Determine if we should process this message.
    -- Three acceptance paths:
    --   1. WHISPER channel → always accept.  A whisper is a deliberate,
    --      targeted sync request; the sender explicitly chose to contact us.
    --      This allows one-sided direct sync: if A adds B, A will whisper B,
    --      and B will respond without needing A on its own list.
    --   2. Guild sync enabled → accept GUILD broadcasts from any member.
    --   3. Sender is on our direct sync list → accept regardless of channel.
    local accept = false
    if channel == "WHISPER" then
        accept = true  -- direct whisper → always process
    end
    if PST.Config.Get("guildSync") then
        accept = true  -- guild sync enabled → accept from any guild member
    end
    if PST.Config.IsDirectSyncTarget(sender) then
        accept = true  -- sender is a direct sync target → always accept
    end
    if not accept then
        PST.Debug("Comm: Ignoring message from", sender,
                  "– guild sync off and sender not in direct sync list")
        return
    end

    local firstChar = text:sub(1, 1)

    if firstChar == T_CHUNK then
        -- Chunked message – extract header and hand off to reassembly
        local msgID, total, idx, chunk = text:match("^C|([^|]+)|([^|]+)|([^|]+)|(.+)$")
        if msgID then
            PST.Debug("Comm: Chunk received", idx, "/", total, "msgID:", msgID, "from", sender)
            HandleChunk(sender, msgID, total, idx, chunk)
        else
            PST.DebugWarn("Comm: Failed to parse chunk header")
        end
    else
        -- Non-chunked message – process directly
        PST.Debug("Comm: Processing non-chunked message type:", firstChar)
        HandleCompleteMessage(text, sender)
    end
end

-------------------------------------------------------------------------------
-- Direct sync – whisper HELLO to each configured direct sync character
-------------------------------------------------------------------------------
local lastWhisperSyncTime = 0

--- Send HELLO directly to every direct sync character via WHISPER.
--- Staggered to avoid throttle.  Independent of guild sync toggle.
---@param force boolean|nil  If true, ignore cooldown
function Comm.WhisperSyncAll(force)
    local list = PST.Config.GetDirectSyncList()
    local count = 0
    for _ in pairs(list) do count = count + 1 end
    if count == 0 then return end

    local now = GetTime()
    if not force and (now - lastWhisperSyncTime) < SYNC_COOLDOWN then
        PST.Debug("Comm: WhisperSyncAll throttled")
        return
    end
    lastWhisperSyncTime = now

    local payload = BuildHelloPayload()
    if not payload then
        PST.Debug("Comm: WhisperSyncAll skipped – no character data")
        return
    end

    Comm.Init()
    local delay = 0
    for charName in pairs(list) do
        delay = delay + 0.5
        local target = charName  -- capture
        C_Timer.After(delay, function()
            PST.Debug("Comm: Whisper HELLO to direct sync target", target)
            SendMessage(T_HELLO, payload, target)
        end)
    end
    PST.Debug("Comm: Queued whisper sync to", count, "direct sync character(s)")
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

--- Manual sync trigger (from /pst sync).
function Comm.TriggerSync()
    Comm.Init()
    local payload = BuildHelloPayload()
    if not payload then
        print("|cff33ccff[PST]|r No character data to sync. Open a profession with specializations and /pst scan first.")
        return
    end

    local did = false
    -- Guild sync path
    if PST.Config.Get("guildSync") and IsInGuild() then
        Comm.BroadcastHello(true)
        print("|cff33ccff[PST]|r Guild sync broadcast sent (" .. #payload .. " bytes).")
        did = true
    end

    -- Direct sync path
    local list = PST.Config.GetDirectSyncList()
    local dsCount = 0
    for _ in pairs(list) do dsCount = dsCount + 1 end
    if dsCount > 0 then
        Comm.WhisperSyncAll(true)
        print("|cff33ccff[PST]|r Direct sync sent to " .. dsCount .. " character(s).")
        did = true
    end

    if not did then
        print("|cff33ccff[PST]|r Nothing to do. Guild sync is off and no direct sync characters configured. Use /pst config.")
    end
end

--- Called after a successful scan to share updated data.
function Comm.OnScanComplete()
    -- Small delay so DB writes settle
    C_Timer.After(1, function()
        -- Guild sync path
        if IsInGuild() and PST.Config.Get("guildSync") then
            Comm.BroadcastHello()
        end
        -- Direct sync path (independent)
        Comm.WhisperSyncAll()
    end)
end

-------------------------------------------------------------------------------
-- Event registration
--
-- CHAT_MSG_ADDON fires for every addon message on every channel.
-- We filter by PREFIX inside the handler.
-------------------------------------------------------------------------------
PST.RegisterEvent("CHAT_MSG_ADDON", Comm.OnAddonMessage)

-- Auto-sync on login: broadcast HELLO after the initial scan completes.
-- Prefix is already registered at file load time (see Comm.Init() call above).
PST.RegisterEvent("PLAYER_LOGIN", function()
    -- After the initial scan (3 s Core.lua delay + scan time), broadcast
    C_Timer.After(10, function()
        -- Guild sync
        if IsInGuild() and PST.Config.Get("guildSync") then
            Comm.BroadcastHello()
        end
        -- Direct sync (independent)
        Comm.WhisperSyncAll()
    end)
end)
