-------------------------------------------------------------------------------
-- Utils.lua – Lightweight debug / utility helpers
-- Loaded FIRST – has zero dependencies on any other addon file.
--
-- Provides:
--   PST.Debug(...)          – conditional print gated on PST.debugEnabled
--   PST.DebugWarn(...)      – same but prefixed with WARNING
--   PST.GetCharKey()        – "Name-Realm" for the current character
--   PST.GetPlayerClassToken() – English class token
--   PST.ClassColorWrap(text, classToken) – color-code text with class color
-------------------------------------------------------------------------------

---@class PST
local _, PST_NS = ...

-- Expose the namespace globally for debugging  (/run ProfessionSpecTracker.debugEnabled = true).
ProfessionSpecTracker = PST_NS

local PST = PST_NS

-------------------------------------------------------------------------------
-- Debug toggle.  Players can flip this via  /pst debug
-------------------------------------------------------------------------------
PST.debugEnabled = false

--- Print a debug message to the default chat frame.
--- Only prints when PST.debugEnabled is true.
---@param ... any  Values to print (concatenated with spaces)
function PST.Debug(...)
    if not PST.debugEnabled then return end
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring(select(i, ...))
    end
    print("|cff33ccff[PST Debug]|r " .. table.concat(parts, " "))
end

--- Print a warning-level debug message.
---@param ... any
function PST.DebugWarn(...)
    if not PST.debugEnabled then return end
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring(select(i, ...))
    end
    print("|cffff9900[PST Warn]|r " .. table.concat(parts, " "))
end

-------------------------------------------------------------------------------
-- Character identity
-------------------------------------------------------------------------------

--- Build the "Name-Realm" key for the currently logged-in character.
--- Caches the result after first successful call.
---@return string  e.g. "Thrall-Stormrage"
function PST.GetCharKey()
    if PST._charKey then return PST._charKey end
    local name = UnitName("player")
    local realm = GetNormalizedRealmName() -- no spaces, e.g. "Stormrage"
    if name and realm and realm ~= "" then
        PST._charKey = name .. "-" .. realm
        return PST._charKey
    end
    -- Fallback: realm not yet available (very early in login).
    -- Return a temporary value but do NOT cache it.
    return (name or "Unknown") .. "-" .. (realm or "???")
end

--- Return the English class token (e.g. "WARRIOR", "MAGE") for the player.
---@return string
function PST.GetPlayerClassToken()
    local _, classToken = UnitClass("player")
    return classToken or "UNKNOWN"
end

-------------------------------------------------------------------------------
-- Color helpers
-------------------------------------------------------------------------------

--- Wrap text in the RAID_CLASS_COLORS hex color for the given class token.
--- Falls back to white if the class token is unknown.
---@param text string     The text to colorize
---@param classToken string  English class token, e.g. "MAGE"
---@return string  Color-coded text string
function PST.ClassColorWrap(text, classToken)
    local colorInfo = RAID_CLASS_COLORS[classToken]
    if colorInfo then
        return colorInfo:WrapTextInColorCode(text)
    end
    -- Unknown class – just return white
    return "|cffffffff" .. text .. "|r"
end
