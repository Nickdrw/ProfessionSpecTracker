-------------------------------------------------------------------------------
-- Config.lua – Settings panel (Interface → Addons → Profession Spec Tracker)
--
-- Provides:
--   • Guild Sync toggle (enable/disable automatic guild addon messaging)
--   • Chat Output toggle
--   • Direct Sync character management
--   • Stored character list with delete buttons
--
-- Uses the modern Settings API (10.0+):
--   • RegisterVerticalLayoutCategory for the guild sync checkbox
--   • RegisterCanvasLayoutSubcategory for custom panels
--
-- Depends on: Utils.lua, Core.lua, Data.lua
-------------------------------------------------------------------------------

local _, PST = ...

PST.Config = PST.Config or {}
local Config = PST.Config

-------------------------------------------------------------------------------
-- Config defaults (stored inside ProfessionSpecTrackerDB.config)
-------------------------------------------------------------------------------
local CONFIG_DEFAULTS = {
    guildSync   = false,  -- Whether to broadcast/receive guild addon messages
    chatOutput  = true,   -- Whether to print sync notifications in chat
}

-------------------------------------------------------------------------------
-- Direct Sync – stored as a set: { ["Name-Realm"] = true, ... }
-- Characters listed here receive targeted whisper sync on login and after
-- each scan.  This is independent of guild sync and is the primary mechanism
-- for cross-account synchronization.
-------------------------------------------------------------------------------

--- Get the direct sync character list (always returns a table, never nil).
---@return table<string, boolean>
function Config.GetDirectSyncList()
    local db = PST.db
    if db and db.config and db.config.directSyncTargets then
        return db.config.directSyncTargets
    end
    return {}
end
Config.GetWhitelist = Config.GetDirectSyncList  -- backward compat alias

--- Check if a character name is a direct sync target.
--- Returns false if the list is empty or name is not listed.
---@param charName string  "Name-Realm" format
---@return boolean
function Config.IsDirectSyncTarget(charName)
    local db = PST.db
    if not db or not db.config or not db.config.directSyncTargets then
        return false
    end
    local list = db.config.directSyncTargets
    -- Try exact match first
    if list[charName] then return true end
    -- Try Ambiguate match (strip realm if same realm)
    local short = Ambiguate(charName, "none")
    for name in pairs(list) do
        if Ambiguate(name, "none") == short then return true end
    end
    return false
end
Config.IsOnWhitelist = Config.IsDirectSyncTarget  -- backward compat alias

--- Add a character to the direct sync list.
---@param charName string  "Name-Realm" format
function Config.AddDirectSyncTarget(charName)
    local db = PST.db
    if not db then return end
    if not db.config then db.config = {} end
    if not db.config.directSyncTargets then db.config.directSyncTargets = {} end
    db.config.directSyncTargets[charName] = true
    PST.Debug("Config: Added direct sync target:", charName)
end
Config.AddToWhitelist = Config.AddDirectSyncTarget  -- backward compat alias

--- Remove a character from the direct sync list.
---@param charName string
function Config.RemoveDirectSyncTarget(charName)
    local db = PST.db
    if not db or not db.config or not db.config.directSyncTargets then return end
    db.config.directSyncTargets[charName] = nil
    PST.Debug("Config: Removed direct sync target:", charName)
end
Config.RemoveFromWhitelist = Config.RemoveDirectSyncTarget  -- backward compat alias

-------------------------------------------------------------------------------
-- Accessors – safe to call even before DB is loaded
-------------------------------------------------------------------------------

--- Get a config value with fallback to default.
---@param key string
---@return any
function Config.Get(key)
    local db = PST.db
    if db and db.config and db.config[key] ~= nil then
        return db.config[key]
    end
    return CONFIG_DEFAULTS[key]
end

--- Set a config value.
---@param key string
---@param value any
function Config.Set(key, value)
    local db = PST.db
    if not db then return end
    if not db.config then db.config = {} end
    db.config[key] = value
end

-------------------------------------------------------------------------------
-- Ensure config table exists after Data.Init
-------------------------------------------------------------------------------
function Config.InitDefaults()
    local db = PST.db
    if not db then return end
    if not db.config then
        db.config = {}
    end
    -- Fill in any missing keys with defaults
    for k, v in pairs(CONFIG_DEFAULTS) do
        if db.config[k] == nil then
            db.config[k] = v
        end
    end
    -- Migrate old "syncWhitelist" key to "directSyncTargets"
    if db.config.syncWhitelist and not db.config.directSyncTargets then
        db.config.directSyncTargets = db.config.syncWhitelist
        db.config.syncWhitelist = nil
        PST.Debug("Config: Migrated syncWhitelist → directSyncTargets")
    elseif db.config.syncWhitelist then
        db.config.syncWhitelist = nil  -- clean up leftover
    end
    -- Ensure direct sync list exists
    if not db.config.directSyncTargets then
        db.config.directSyncTargets = {}
    end
end

-------------------------------------------------------------------------------
-- Character list UI helpers
-------------------------------------------------------------------------------

-- Height of each character row in the scrollable list
local ROW_HEIGHT = 28

-------------------------------------------------------------------------------
-- Reusable StaticPopupDialog for character deletion.
-- Uses a single stable name to avoid leaking dialog entries.
-------------------------------------------------------------------------------
StaticPopupDialogs["PST_DELETE_CHARACTER"] = {
    text = "Delete stored data for\n|cffffffff%s|r?",
    button1 = DELETE or "Delete",
    button2 = CANCEL or "Cancel",
    OnAccept = function(self, data)
        if data and data.charKey and PST.Data.DeleteCharacter(data.charKey) then
            PST.Debug("Config: Deleted", data.charKey)
            if Config.RefreshCharacterList then
                Config.RefreshCharacterList()
            end
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

--- Create a single row for a character in the list.
---@param parent Frame  The scroll child frame
---@param index number  Row index (1-based)
---@param charInfo table  { charKey, class, lastScan, profNames, synced }
---@param onDelete function(charKey)  Delete callback
---@return Frame  The row frame
local function CreateCharRow(parent, index, charInfo, onDelete)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -((index - 1) * ROW_HEIGHT))
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -((index - 1) * ROW_HEIGHT))

    -- Alternating background for readability
    if index % 2 == 0 then
        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(1, 1, 1, 0.03)
    end

    -- Delete button (red X)
    local delBtn = CreateFrame("Button", nil, row)
    delBtn:SetSize(20, 20)
    delBtn:SetPoint("LEFT", row, "LEFT", 4, 0)
    delBtn:SetNormalFontObject("GameFontNormalSmall")

    -- Red cross text
    local delText = delBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    delText:SetPoint("CENTER")
    delText:SetText("|cffff3333X|r")
    delBtn:SetFontString(delText)

    -- Highlight on hover
    delBtn:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight")

    delBtn:SetScript("OnClick", function()
        -- Use the stable reusable dialog with data parameter
        local dialog = StaticPopup_Show("PST_DELETE_CHARACTER",
            charInfo.charKey)
        if dialog then
            dialog.data = { charKey = charInfo.charKey }
        end
    end)

    delBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Delete " .. charInfo.charKey)
        GameTooltip:Show()
    end)
    delBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- Character name (class-colored)
    local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameText:SetPoint("LEFT", delBtn, "RIGHT", 6, 0)
    nameText:SetWidth(180)
    nameText:SetJustifyH("LEFT")
    nameText:SetText(PST.ClassColorWrap(charInfo.charKey, charInfo.class))

    -- Professions
    local profText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    profText:SetPoint("LEFT", nameText, "RIGHT", 8, 0)
    profText:SetWidth(260)
    profText:SetJustifyH("LEFT")
    local profStr = #charInfo.profNames > 0
        and table.concat(charInfo.profNames, ", ")
        or "|cffa0a0a0none|r"
    profText:SetText(profStr)

    -- Last scan / synced tag
    local metaText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    metaText:SetPoint("LEFT", profText, "RIGHT", 8, 0)
    metaText:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    metaText:SetJustifyH("RIGHT")
    local scanStr = charInfo.lastScan > 0
        and date("%m/%d %H:%M", charInfo.lastScan)
        or "never"
    if charInfo.synced then
        scanStr = scanStr .. " |cffa0a0a0(synced)|r"
    end
    metaText:SetText(scanStr)

    return row
end

-------------------------------------------------------------------------------
-- The character list panel (canvas layout subcategory)
-------------------------------------------------------------------------------
local charScrollChild = nil    -- scroll child containing character rows
local charRows = {}            -- current row frames

-------------------------------------------------------------------------------
-- The direct sync panel (canvas layout subcategory)
-------------------------------------------------------------------------------
local directSyncScrollChild = nil
local directSyncRows = {}

--- Build or rebuild the direct sync list inside the scroll child.
function Config.RefreshDirectSyncList()
    if not directSyncScrollChild then return end

    -- Clear existing rows
    for _, row in ipairs(directSyncRows) do
        row:Hide()
        row:SetParent(nil)
    end
    wipe(directSyncRows)

    local list = Config.GetDirectSyncList()
    local names = {}
    for name in pairs(list) do
        names[#names + 1] = name
    end
    table.sort(names)

    if #names == 0 then
        local empty = CreateFrame("Frame", nil, directSyncScrollChild)
        empty:SetHeight(ROW_HEIGHT)
        empty:SetPoint("TOPLEFT", directSyncScrollChild, "TOPLEFT", 0, 0)
        empty:SetPoint("TOPRIGHT", directSyncScrollChild, "TOPRIGHT", 0, 0)

        local emptyText = empty:CreateFontString(nil, "OVERLAY", "GameFontDisable")
        emptyText:SetPoint("LEFT", 10, 0)
        emptyText:SetText("No direct sync characters configured. Add a character to enable cross-account sync.")

        directSyncRows[1] = empty
        directSyncScrollChild:SetHeight(ROW_HEIGHT)
        return
    end

    for i, name in ipairs(names) do
        local row = CreateFrame("Frame", nil, directSyncScrollChild)
        row:SetHeight(ROW_HEIGHT)
        row:SetPoint("TOPLEFT", directSyncScrollChild, "TOPLEFT", 0, -((i - 1) * ROW_HEIGHT))
        row:SetPoint("TOPRIGHT", directSyncScrollChild, "TOPRIGHT", 0, -((i - 1) * ROW_HEIGHT))

        -- Alternating background
        if i % 2 == 0 then
            local bg = row:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetColorTexture(1, 1, 1, 0.03)
        end

        -- Remove button
        local delBtn = CreateFrame("Button", nil, row)
        delBtn:SetSize(20, 20)
        delBtn:SetPoint("LEFT", row, "LEFT", 4, 0)

        local delText = delBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        delText:SetPoint("CENTER")
        delText:SetText("|cffff3333X|r")
        delBtn:SetFontString(delText)
        delBtn:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight")

        local nameCapture = name
        delBtn:SetScript("OnClick", function()
            Config.RemoveDirectSyncTarget(nameCapture)
            Config.RefreshDirectSyncList()
        end)
        delBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Remove " .. nameCapture .. " from direct sync")
            GameTooltip:Show()
        end)
        delBtn:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        -- Character name
        local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        nameText:SetPoint("LEFT", delBtn, "RIGHT", 6, 0)
        nameText:SetText(nameCapture)

        directSyncRows[i] = row
    end

    directSyncScrollChild:SetHeight(#names * ROW_HEIGHT)
end

-------------------------------------------------------------------------------
-- Create the direct sync canvas frame (called once during panel setup)
-------------------------------------------------------------------------------
local function CreateDirectSyncFrame()
    local frame = CreateFrame("Frame", "PST_DirectSyncPanel", UIParent)
    frame:SetSize(600, 400)
    frame:Hide()

    -- Header
    local header = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", 16, -16)
    header:SetText("Direct Sync Characters")

    local desc = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    desc:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    desc:SetWidth(560)
    desc:SetJustifyH("LEFT")
    desc:SetText("Sync profession data directly with specific characters via whisper. Useful for cross-account sync. Only one side needs to list the other. Characters listed here will receive a targeted sync request on login and after each scan.\nFormat: |cffffffffName-Realm|r (e.g. |cffffffffMyalt-Stormrage|r). Must be on the same or a connected realm.")

    -- Input box + Add button
    local inputBox = CreateFrame("EditBox", "PST_DirectSyncInput", frame, "InputBoxTemplate")
    inputBox:SetSize(280, 22)
    inputBox:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 6, -10)
    inputBox:SetAutoFocus(false)
    inputBox:SetMaxLetters(60)
    inputBox:SetFontObject("ChatFontNormal")

    local addBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    addBtn:SetSize(80, 24)
    addBtn:SetPoint("LEFT", inputBox, "RIGHT", 8, 0)
    addBtn:SetText("Add")

    local function AddCharFromInput()
        local text = inputBox:GetText():trim()
        if text == "" then return end
        -- Auto-append realm if not provided
        if not text:find("-") then
            local _, realm = UnitFullName("player")
            if realm and realm ~= "" then
                text = text .. "-" .. realm
            end
        end
        -- Capitalize first letter
        text = text:sub(1, 1):upper() .. text:sub(2)
        Config.AddDirectSyncTarget(text)
        inputBox:SetText("")
        Config.RefreshDirectSyncList()
    end

    addBtn:SetScript("OnClick", AddCharFromInput)
    inputBox:SetScript("OnEnterPressed", function()
        AddCharFromInput()
        inputBox:ClearFocus()
    end)
    inputBox:SetScript("OnEscapePressed", function()
        inputBox:ClearFocus()
    end)

    ---------------------------------------------------------------------------
    -- Export / Import buttons
    ---------------------------------------------------------------------------

    -- Export: copies all stored character keys (Name-Realm) to clipboard
    local exportBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    exportBtn:SetSize(100, 24)
    exportBtn:SetPoint("TOPLEFT", inputBox, "BOTTOMLEFT", -6, -8)
    exportBtn:SetText("Export Chars")

    exportBtn:SetScript("OnClick", function()
        local db = PST.db
        if not db or not db.characters then return end
        local keys = {}
        for charKey, charData in pairs(db.characters) do
            -- Only export local characters (not synced)
            if not charData.syncedFrom then
                keys[#keys + 1] = charKey
            end
        end
        table.sort(keys)
        if #keys == 0 then
            print("|cff33ccff[PST]|r No stored characters to export.")
            return
        end
        local text = table.concat(keys, "\n")
        -- Use a hidden editbox to put text on the clipboard
        local copyFrame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        copyFrame:SetFrameStrata("DIALOG")
        copyFrame:SetSize(420, 250)
        copyFrame:SetPoint("CENTER")
        copyFrame:SetBackdrop({
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile     = true, tileSize = 32, edgeSize = 32,
            insets   = { left = 8, right = 8, top = 8, bottom = 8 },
        })

        local title = copyFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOP", 0, -14)
        title:SetText("Copy this list (Ctrl+C)")

        local scrollBg = CreateFrame("ScrollFrame", nil, copyFrame, "UIPanelScrollFrameTemplate")
        scrollBg:SetPoint("TOPLEFT", 16, -36)
        scrollBg:SetPoint("BOTTOMRIGHT", -32, 40)

        local editBox = CreateFrame("EditBox", nil, scrollBg)
        editBox:SetMultiLine(true)
        editBox:SetAutoFocus(true)
        editBox:SetFontObject("ChatFontNormal")
        editBox:SetWidth(scrollBg:GetWidth() or 360)
        editBox:SetText(text)
        editBox:HighlightText()
        scrollBg:SetScrollChild(editBox)

        editBox:SetScript("OnEscapePressed", function()
            copyFrame:Hide()
        end)

        local closeBtn = CreateFrame("Button", nil, copyFrame, "UIPanelButtonTemplate")
        closeBtn:SetSize(80, 22)
        closeBtn:SetPoint("BOTTOM", 0, 12)
        closeBtn:SetText("Close")
        closeBtn:SetScript("OnClick", function()
            copyFrame:Hide()
        end)

        print("|cff33ccff[PST]|r Exported " .. #keys .. " character(s). Press Ctrl+C to copy.")
    end)
    exportBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Export all stored character names to clipboard")
        GameTooltip:Show()
    end)
    exportBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Import: paste a list of Name-Realm (one per line or comma-separated)
    local importBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    importBtn:SetSize(100, 24)
    importBtn:SetPoint("LEFT", exportBtn, "RIGHT", 8, 0)
    importBtn:SetText("Import List")

    importBtn:SetScript("OnClick", function()
        local importFrame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        importFrame:SetFrameStrata("DIALOG")
        importFrame:SetSize(420, 280)
        importFrame:SetPoint("CENTER")
        importFrame:SetBackdrop({
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile     = true, tileSize = 32, edgeSize = 32,
            insets   = { left = 8, right = 8, top = 8, bottom = 8 },
        })

        local title = importFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOP", 0, -14)
        title:SetText("Paste character list (one per line)")

        local scrollBg = CreateFrame("ScrollFrame", nil, importFrame, "UIPanelScrollFrameTemplate")
        scrollBg:SetPoint("TOPLEFT", 16, -36)
        scrollBg:SetPoint("BOTTOMRIGHT", -32, 50)

        local editBox = CreateFrame("EditBox", nil, scrollBg)
        editBox:SetMultiLine(true)
        editBox:SetAutoFocus(true)
        editBox:SetFontObject("ChatFontNormal")
        editBox:SetWidth(scrollBg:GetWidth() or 360)
        editBox:SetText("")
        scrollBg:SetScrollChild(editBox)

        editBox:SetScript("OnEscapePressed", function()
            importFrame:Hide()
        end)

        local doImportBtn = CreateFrame("Button", nil, importFrame, "UIPanelButtonTemplate")
        doImportBtn:SetSize(100, 22)
        doImportBtn:SetPoint("BOTTOMRIGHT", importFrame, "BOTTOM", -4, 14)
        doImportBtn:SetText("Import")

        local cancelBtn = CreateFrame("Button", nil, importFrame, "UIPanelButtonTemplate")
        cancelBtn:SetSize(80, 22)
        cancelBtn:SetPoint("BOTTOMLEFT", importFrame, "BOTTOM", 4, 14)
        cancelBtn:SetText("Cancel")
        cancelBtn:SetScript("OnClick", function()
            importFrame:Hide()
        end)

        doImportBtn:SetScript("OnClick", function()
            local raw = editBox:GetText() or ""
            local added, skipped = 0, 0
            -- Split on newlines, commas, or semicolons
            for entry in raw:gmatch("[^\n\r,;]+") do
                local name = entry:match("^%s*(.-)%s*$")  -- trim
                if name and name ~= "" then
                    -- Auto-append realm if not provided
                    if not name:find("-") then
                        local _, realm = UnitFullName("player")
                        if realm and realm ~= "" then
                            name = name .. "-" .. realm
                        end
                    end
                    -- Capitalize first letter
                    name = name:sub(1, 1):upper() .. name:sub(2)
                    -- Check for duplicates
                    if Config.IsDirectSyncTarget(name) then
                        skipped = skipped + 1
                    else
                        Config.AddDirectSyncTarget(name)
                        added = added + 1
                    end
                end
            end
            importFrame:Hide()
            Config.RefreshDirectSyncList()
            print("|cff33ccff[PST]|r Imported " .. added .. " character(s), " .. skipped .. " duplicate(s) skipped.")
            -- Trigger direct sync immediately so newly imported characters get contacted
            if added > 0 and PST.Comm and PST.Comm.WhisperSyncAll then
                C_Timer.After(0.5, function()
                    PST.Comm.WhisperSyncAll(true)
                end)
            end
        end)
    end)
    importBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Import a list of Name-Realm entries into the direct sync list")
        GameTooltip:Show()
    end)
    importBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Scroll frame for the list
    local scrollFrame = CreateFrame("ScrollFrame", "PST_DirectSyncScroll", frame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", exportBtn, "BOTTOMLEFT", 0, -10)
    scrollFrame:SetPoint("BOTTOMRIGHT", -30, 10)

    directSyncScrollChild = CreateFrame("Frame", "PST_DirectSyncScrollChild", scrollFrame)
    directSyncScrollChild:SetWidth(scrollFrame:GetWidth() or 540)
    directSyncScrollChild:SetHeight(1)
    scrollFrame:SetScrollChild(directSyncScrollChild)

    frame:SetScript("OnShow", function()
        directSyncScrollChild:SetWidth(scrollFrame:GetWidth())
        Config.RefreshDirectSyncList()
    end)

    return frame
end

--- Build or rebuild the character list inside the scroll child.
function Config.RefreshCharacterList()
    if not charScrollChild then return end

    -- Clear existing rows
    for _, row in ipairs(charRows) do
        row:Hide()
        row:SetParent(nil)
    end
    wipe(charRows)

    local characters = PST.Data.GetAllCharacters()

    if #characters == 0 then
        local empty = CreateFrame("Frame", nil, charScrollChild)
        empty:SetHeight(ROW_HEIGHT)
        empty:SetPoint("TOPLEFT", charScrollChild, "TOPLEFT", 0, 0)
        empty:SetPoint("TOPRIGHT", charScrollChild, "TOPRIGHT", 0, 0)

        local emptyText = empty:CreateFontString(nil, "OVERLAY", "GameFontDisable")
        emptyText:SetPoint("LEFT", 30, 0)
        emptyText:SetText("No characters stored yet. Open a profession panel to scan.")

        charRows[1] = empty
        charScrollChild:SetHeight(ROW_HEIGHT)
        return
    end

    for i, charInfo in ipairs(characters) do
        charRows[i] = CreateCharRow(charScrollChild, i, charInfo, function(charKey)
            PST.Data.DeleteCharacter(charKey)
            Config.RefreshCharacterList()
        end)
    end

    charScrollChild:SetHeight(#characters * ROW_HEIGHT)
end

-------------------------------------------------------------------------------
-- Create the character list canvas frame (called once during panel setup)
-------------------------------------------------------------------------------
local function CreateCharacterListFrame()
    local frame = CreateFrame("Frame", "PST_CharListPanel", UIParent)
    frame:SetSize(600, 400)
    frame:Hide()

    -- Header
    local header = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", 16, -16)
    header:SetText("Stored Characters")

    local desc = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    desc:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    desc:SetText("Characters whose profession specialization data is stored locally. Click |cffff3333X|r to remove.")

    -- Column headers
    local colY = -52
    local colName = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    colName:SetPoint("TOPLEFT", 30, colY)
    colName:SetText("|cffffcc00Character|r")

    local colProf = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    colProf:SetPoint("TOPLEFT", 220, colY)
    colProf:SetText("|cffffcc00Professions|r")

    local colScan = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    colScan:SetPoint("TOPRIGHT", -20, colY)
    colScan:SetText("|cffffcc00Last Scan|r")

    -- Scroll frame
    local scrollFrame = CreateFrame("ScrollFrame", "PST_CharListScroll", frame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 10, colY - 16)
    scrollFrame:SetPoint("BOTTOMRIGHT", -30, 10)

    charScrollChild = CreateFrame("Frame", "PST_CharListScrollChild", scrollFrame)
    charScrollChild:SetWidth(scrollFrame:GetWidth() or 540)
    charScrollChild:SetHeight(1) -- will be updated by RefreshCharacterList
    scrollFrame:SetScrollChild(charScrollChild)

    -- When the frame becomes visible, refresh the character list
    frame:SetScript("OnShow", function()
        -- Re-measure scroll child width to match scroll frame
        charScrollChild:SetWidth(scrollFrame:GetWidth())
        Config.RefreshCharacterList()
    end)

    return frame
end

-------------------------------------------------------------------------------
-- Build the Settings panel – called after DB is initialized
-------------------------------------------------------------------------------
function Config.SetupPanel()
    -- Main category with vertical layout (for checkboxes)
    local category = Settings.RegisterVerticalLayoutCategory("Profession Spec Tracker")

    -- Guild Sync checkbox
    do
        local variable = "PST_GuildSync"
        local name = "Enable Guild Sync"
        local tooltip = "Automatically share profession specialization data with guild members who also have this addon installed. Uses invisible addon messages — no visible chat output."
        local defaultValue = CONFIG_DEFAULTS.guildSync

        local setting = Settings.RegisterProxySetting(
            category,
            variable,
            type(defaultValue),     -- "boolean"
            name,
            defaultValue,
            function() return Config.Get("guildSync") end,
            function(value)
                Config.Set("guildSync", value)
                PST.Debug("Config: guildSync =", value)
            end
        )

        Settings.CreateCheckbox(category, setting, tooltip)
    end

    -- Chat Output checkbox
    do
        local variable = "PST_ChatOutput"
        local name = "Show Sync Notifications in Chat"
        local tooltip = "Print a message in chat whenever profession data is synced from another character."
        local defaultValue = CONFIG_DEFAULTS.chatOutput

        local setting = Settings.RegisterProxySetting(
            category,
            variable,
            type(defaultValue),
            name,
            defaultValue,
            function() return Config.Get("chatOutput") end,
            function(value)
                Config.Set("chatOutput", value)
                PST.Debug("Config: chatOutput =", value)
            end
        )

        Settings.CreateCheckbox(category, setting, tooltip)
    end

    -- Character Manager subcategory (canvas layout for the custom list)
    local charFrame = CreateCharacterListFrame()
    local subcategory = Settings.RegisterCanvasLayoutSubcategory(category, charFrame, "Stored Characters")
    subcategory.ID = "PST_StoredCharacters"

    -- Direct Sync subcategory (canvas layout for add/remove UI)
    local dsFrame = CreateDirectSyncFrame()
    local dsSubcategory = Settings.RegisterCanvasLayoutSubcategory(category, dsFrame, "Direct Sync")
    dsSubcategory.ID = "PST_DirectSync"

    -- Register with the Addon settings panel
    Settings.RegisterAddOnCategory(category)

    -- Store reference so /pst config can open it
    Config.category = category

    PST.Debug("Config: Settings panel registered")
end

-------------------------------------------------------------------------------
-- Open the settings panel (for /pst config)
-------------------------------------------------------------------------------
function Config.OpenPanel()
    if Config.category then
        Settings.OpenToCategory(Config.category:GetID())
    end
end
