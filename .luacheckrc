-- .luacheckrc – LuaCheck configuration for ProfessionSpecTracker
-- WoW Retail addon (Lua 5.1 runtime)

std = "lua51"
max_line_length = false

-- These globals are provided by the WoW client environment
read_globals = {
    -- Addon / SavedVariables globals we write
    "ProfessionSpecTracker",
    "ProfessionSpecTrackerDB",
    "ProfessionAccountSkillsDB",       -- old addon name (migration)

    -- WoW standard globals
    "print",
    "date",
    "time",
    "wipe",
    "strsplit",
    "strtrim",
    "tostring",
    "tonumber",
    "type",
    "pairs",
    "ipairs",
    "select",
    "unpack",
    "math",
    "table",
    "string",

    -- WoW Frame / UI API
    "CreateFrame",
    "UIParent",
    "GameTooltip",
    "GameTooltip_AddBlankLineToTooltip",
    "GameTooltip_AddColoredLine",
    "StaticPopup_Show",
    "StaticPopupDialogs",
    "Settings",
    "EventRegistry",
    "Mixin",
    "NORMAL_FONT_COLOR",
    "RAID_CLASS_COLORS",
    "DELETE",
    "CANCEL",

    -- WoW unit / player API
    "UnitName",
    "UnitClass",
    "UnitFullName",
    "GetNormalizedRealmName",
    "GetProfessions",
    "GetProfessionInfo",
    "GetTime",
    "IsInGuild",
    "Ambiguate",
    "Professions",

    -- WoW C namespace APIs
    "C_AddOns",
    "C_ChatInfo",
    "C_ProfSpecs",
    "C_Timer",
    "C_Traits",
    "C_TradeSkillUI",

    -- Slash command globals
    "SlashCmdList",
    "SLASH_PST1",
    "SLASH_PST2",
}

-- Globals we both read and write
globals = {
    "ProfessionSpecTracker",
    "ProfessionSpecTrackerDB",
    "ProfessionAccountSkillsDB",
    "StaticPopupDialogs",
    "SlashCmdList",
    "SLASH_PST1",
    "SLASH_PST2",
}

-- Ignore unused self parameter (common in WoW event handlers)
self = false

-- Ignore unused loop variables (common: for _ in pairs())
unused_args = false

-- Per-file overrides
files["Utils.lua"] = {
    -- Utils.lua sets the ProfessionSpecTracker global alias
    globals = { "ProfessionSpecTracker" },
}

files["Data.lua"] = {
    -- Data.lua manages the raw ProfessionSpecTrackerDB global
    globals = { "ProfessionSpecTrackerDB", "ProfessionAccountSkillsDB" },
}

files["Config.lua"] = {
    globals = { "StaticPopupDialogs" },
}

files["Core.lua"] = {
    globals = { "SlashCmdList", "SLASH_PST1", "SLASH_PST2" },
}
