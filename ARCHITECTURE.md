# ProfessionSpecTracker – Architecture Guide

> **Purpose of this document:** Give an AI coding assistant (or a new contributor) enough context to understand, modify, and debug the addon without reading every line of source.

---

## 1. What the Addon Does

ProfessionSpecTracker (PST) is a World of Warcraft (Retail, Interface 120001+) addon that:

1. **Scans** the logged-in character's profession specialization trees (e.g. Blacksmithing → Armorsmithing) and records how many points are invested in each node.
2. **Stores** that data per-character in `SavedVariables` across all alts on the account.
3. **Enhances tooltips** in the profession specialization UI – when hovering a spec node or tab, the addon appends lines showing which other characters have invested points there, and how many.
4. **Syncs** data across WoW accounts via invisible addon messages (guild broadcast or targeted whisper).

---

## 2. File Layout & Load Order

Defined in `ProfessionSpecTracker.toc`:

| Order | File           | Role |
|-------|----------------|------|
| 1     | `Utils.lua`    | Zero-dependency helpers: debug printing, `GetCharKey()`, class-color wrapping. |
| 2     | `Core.lua`     | Addon namespace, constants, hidden event frame, event dispatcher, `/pst` slash commands. |
| 3     | `Data.lua`     | SavedVariables schema, DB initialization, migrations, nodeIndex maintenance, CRUD for character data. |
| 4     | `Config.lua`   | Settings panel (Interface → Addons), guild sync toggle, chat output toggle, Direct Sync character management, stored-character list UI. |
| 5     | `Scanner.lua`  | Reads Blizzard APIs to scan the current character's spec trees and calls `Data.SaveNodeData()`. |
| 6     | `Comm.lua`     | Cross-account synchronization protocol (HELLO/PUSH/CHUNK) over GUILD or WHISPER channels. |
| 7     | `Tooltip.lua`  | Hooks `EventRegistry` callbacks to append alt data into profession spec tooltips. |

Every file shares the addon namespace via `local _, PST = ...`. Sub-modules attach themselves to `PST` (e.g. `PST.Scanner`, `PST.Comm`, `PST.Data`, `PST.Config`, `PST.Tooltip`).

---

## 3. SavedVariables Schema

Stored in `ProfessionSpecTrackerDB` (a single global table). Current schema version: **3**.

```
ProfessionSpecTrackerDB
├── version        (number)  Schema version
├── characters     (table)   Keyed by "Name-Realm"
│   └── <charKey>
│       ├── class           (string)  "WARRIOR", "MAGE", etc.
│       ├── lastScan        (number)  time() of last successful scan
│       ├── syncedFrom      (string|nil)  "guild" if synced from another account; nil if locally scanned
│       └── professions     (table)   Keyed by skillLineID (number)
│           └── <skillLineID>
│               ├── professionName       (string)  Expansion-prefixed, e.g. "Midnight Blacksmithing"
│               ├── parentProfessionName (string)  Base name, e.g. "Blacksmithing"
│               └── tabs                 (table)   Keyed by treeID (number)
│                   └── <treeID>
│                       ├── tabName      (string)
│                       ├── rootNodeID   (number)
│                       └── nodes        (table)   Keyed by nodeID (number)
│                           └── <nodeID>
│                               ├── rank     (number)  Display rank (points invested)
│                               └── maxRank  (number)  Max display rank
├── nodeIndex      (table)   Reverse index: nodeID → { charKey → { rank, maxRank, class } }
└── config         (table)   User settings
    ├── guildSync          (boolean, default false)
    ├── chatOutput         (boolean, default true)
    └── directSyncTargets  (table)  Set of "Name-Realm" → true
```

### nodeIndex

A **derived** acceleration structure. Enables O(1) tooltip lookups by `nodeID` without iterating all characters. Rebuilt from `characters` during DB migration (`Data.RebuildNodeIndex`). Maintained incrementally during scans (`Data.SaveNodeData`) and syncs (`DeserializeAndMerge`).

### syncedFrom

Marks characters whose data came from another account via sync. Key invariant: **the logged-in character always has `syncedFrom = nil`** (enforced in `Data.GetCharData()`). Characters with `syncedFrom` set are **never pushed** during sync, preventing A→B→A data loops.

---

## 4. Scanning Pipeline

Triggered by: `PLAYER_LOGIN` (delayed 3s), `TRADE_SKILL_SHOW`, `TRADE_SKILL_DATA_SOURCE_CHANGED`, `SKILL_LINE_SPECS_RANKS_CHANGED`, `TRAIT_CONFIG_UPDATED`, `TRAIT_NODE_CHANGED`.

```
Scanner.TryScanAll(reason)
  │
  ├── Throttle check (2s minimum between scans)
  ├── C_TradeSkillUI.GetAllProfessionTradeSkillLines() → all skillLineIDs
  │     ⚠ WARNING: Returns stale IDs for dropped professions!
  │
  ├── GetProfessions() + GetProfessionInfo() → build set of CURRENT profession names
  ├── Filter skillLineIDs to only those matching current professions
  │
  ├── For each valid skillLineID → ScanProfession(skillLineID):
  │     ├── C_ProfSpecs.SkillLineHasSpecialization()
  │     ├── C_ProfSpecs.GetConfigIDForSkillLine() → configID
  │     ├── C_ProfSpecs.GetSpecTabIDsForSkillLine() → tab treeIDs
  │     └── For each tab:
  │           ├── C_ProfSpecs.GetTabInfo() → tabName, rootNodeID
  │           ├── WalkTree(rootNodeID) → all nodeIDs (recursive via GetChildrenForPath)
  │           └── For each node:
  │                 ├── C_Traits.GetNodeInfo() → currentRank, maxRanks
  │                 ├── GetDisplayRanks() → subtract unlock entry (mirrors Blizzard's ProfessionsSpecPathMixin:GetRanks())
  │                 └── Data.SaveNodeData(...)
  │
  ├── Remove stale profession entries (dropped professions) from character data + nodeIndex
  ├── Data.MarkScanComplete()
  └── Comm.OnScanComplete() → triggers sync broadcast
```

### Display Rank Calculation

Blizzard's spec nodes have an "unlock entry" (first tier) that costs 0-1 point. The **display** rank subtracts this, so a node shows "0/30" not "1/31". `GetDisplayRanks()` replicates `ProfessionsSpecPathMixin:GetRanks()` from Blizzard source.

---

## 5. Sync Protocol

Two independent mechanisms:

### 5a. Guild Sync (opt-in, default OFF)

Broadcasts to all guild members running PST. Toggle: `config.guildSync`.

### 5b. Direct Sync (always active when targets exist)

Whispers HELLO to specific characters listed in `config.directSyncTargets`. Works cross-account. **One-sided**: only one side needs to list the other.

### Message Types

| Tag | Name  | Format | Description |
|-----|-------|--------|-------------|
| `H` | HELLO | `H\|charKey1:ts1,charKey2:ts2,...` | Character list with `lastScan` timestamps. Broadcast on login and after scans. |
| `P` | PUSH  | `P\|charKey~class~lastScan~nodeID:rank:maxRank,...~skillLineID/profName/parentName;...` | Full character data. Sent via WHISPER in response to HELLO when sender has newer data. |
| `C` | CHUNK | `C\|msgID\|totalChunks\|chunkIdx\|innerPayload` | Splits messages exceeding 240 bytes (WoW's addon message limit is 255). Reassembled on receive. |

### Sync Flow

```
A logs in
  → Scanner runs (3s delay)
  → Comm.OnScanComplete()
     ├── BroadcastHello() on GUILD (if guildSync enabled)
     └── WhisperSyncAll() to each direct sync target

B receives HELLO from A
  → HandleHello(): compares timestamps
     ├── Pushes characters B has newer data for → WHISPER PUSH to A
     └── Echoes HELLO back to A (throttled, anti-ping-pong)

A receives B's PUSH
  → DeserializeAndMerge(): updates characters + nodeIndex
  → Characters marked syncedFrom = "guild"

A receives B's echoed HELLO
  → HandleHello(): pushes characters A has newer data for → WHISPER PUSH to B
```

### Anti-Loop Protection

1. **`syncedFrom` filtering**: `HandleHello()` only pushes characters where `syncedFrom == nil` (locally scanned). Prevents A→B→A bounce.
2. **`syncedFrom` clearing**: `Data.GetCharData()` clears `syncedFrom` for the logged-in character, ensuring it's always treated as locally owned.
3. **HELLO echo throttle**: Each sender only gets one echo per `SYNC_COOLDOWN` (30s) window.
4. **Timestamp comparison**: Data is only pushed when the sender's `lastScan` is strictly newer.

### Message Acceptance Rules

In `Comm.OnAddonMessage()`, a message is accepted if ANY of these are true:
- Channel is `WHISPER` (always accept – enables one-sided direct sync)
- `guildSync` is enabled (accept all GUILD broadcasts)
- Sender is in `directSyncTargets`

---

## 6. Tooltip Enhancement

Uses `EventRegistry` callbacks (not `hooksecurefunc`) for reliability:

- **`ProfessionSpecs.SpecPathEntered`** → fired when hovering a spec node. Calls `Data.GetNodeAlts(nodeID)`.
- **`ProfessionSpecs.SpecTabEntered`** → fired when hovering a spec tab. Calls `Data.GetTabAlts(treeID)` which finds the root node and delegates to `GetNodeAlts`.

Alt data is split into "Account Characters" (locally scanned) and "Synced Characters" (from other accounts) with separate headers.

### Why EventRegistry over hooksecurefunc

`ProfessionsSpecPathMixin` is applied via `Mixin()` which copies function references at frame creation time. If hooks are applied after frames exist, those frames keep unhooked originals. `EventRegistry` callbacks fire from the original `OnEnter` regardless of timing.

---

## 7. Config / Settings Panel

Uses WoW 10.0+ Settings API:

- **Main category** (`RegisterVerticalLayoutCategory`): Guild Sync checkbox, Chat Output checkbox.
- **Subcategory "Stored Characters"** (`RegisterCanvasLayoutSubcategory`): Scrollable list of all stored characters with delete buttons.
- **Subcategory "Direct Sync"** (`RegisterCanvasLayoutSubcategory`): Add/remove direct sync targets, Export/Import character lists.

### DB Key Migration

Old key `syncWhitelist` is migrated to `directSyncTargets` in `Config.InitDefaults()`. Backward-compatible function aliases exist: `GetWhitelist`, `IsOnWhitelist`, `AddToWhitelist`, `RemoveFromWhitelist`.

---

## 8. Slash Commands

| Command | Action |
|---------|--------|
| `/pst` | Show help / version |
| `/pst debug` | Toggle debug logging |
| `/pst scan` | Force rescan of current professions |
| `/pst status` | Print stored character summary |
| `/pst sync` | Force guild broadcast + direct sync |
| `/pst config` | Open settings panel |
| `/pst directsync [list\|add\|remove\|clear]` | Manage direct sync targets |
| `/pst wipe` | Wipe all saved data |
| `/pst test` | Show nodeIndex diagnostic info |

Hidden alias: `/pst whitelist` → same as `/pst directsync` (backward compat).

---

## 9. Key Blizzard APIs Used

| API | Purpose | Gotchas |
|-----|---------|---------|
| `C_TradeSkillUI.GetAllProfessionTradeSkillLines()` | Get all known skill line IDs | **Returns stale IDs for dropped professions** – must cross-reference with `GetProfessions()` |
| `GetProfessions()` | Get indexes of current primary professions | Authoritative source for active professions |
| `GetProfessionInfo(index)` | Get profession name from index | |
| `C_TradeSkillUI.GetProfessionInfoBySkillLineID(id)` | Get profession name/parent from skill line | |
| `C_ProfSpecs.SkillLineHasSpecialization(id)` | Check if profession has spec tree | |
| `C_ProfSpecs.GetConfigIDForSkillLine(id)` | Get trait config ID | Returns 0 if not available |
| `C_ProfSpecs.GetSpecTabIDsForSkillLine(id)` | Get spec tab tree IDs | |
| `C_ProfSpecs.GetTabInfo(treeID)` | Tab name + root node ID | |
| `C_ProfSpecs.GetChildrenForPath(nodeID)` | Child nodes in tree | |
| `C_ProfSpecs.GetUnlockEntryForPath(nodeID)` | Unlock entry for display rank calc | |
| `C_Traits.GetNodeInfo(configID, nodeID)` | Current/max ranks for a node | |
| `C_Traits.GetEntryInfo(configID, entryID)` | Entry max ranks (for unlock subtraction) | |
| `C_ChatInfo.RegisterAddonMessagePrefix(prefix)` | Register "PST" for addon messaging | Must be called before messages can be received |
| `C_ChatInfo.SendAddonMessage(prefix, text, channel, target)` | Send addon message | 255 byte limit per message |
| `EventRegistry:RegisterCallback(event, callback, owner)` | Hook tooltip events | |

---

## 10. Common Pitfalls & Past Bugs

### Stale Professions (Dropped Profession Data)
`C_TradeSkillUI.GetAllProfessionTradeSkillLines()` returns skill line IDs for professions the character **previously had but dropped**. The scanner cross-references with `GetProfessions()` to filter these out and cleans up stale entries from storage.

### Sync Loop (A→B→A Bounce)
Without the `syncedFrom` guard, account A pushes a character to B, then B pushes it back to A (since B now has it). Fixed by only pushing locally-scanned characters (`syncedFrom == nil`).

### One-Sided Direct Sync
Originally both sides needed to list each other. Fixed by accepting all WHISPER-channel messages regardless of sender's presence in the direct sync list.

### Display Rank Off-By-One
Raw `currentRank` from `C_Traits.GetNodeInfo` includes the unlock entry cost. Must subtract via `GetDisplayRanks()` to match what Blizzard shows in the UI.

---

## 11. Module Dependency Graph

```
Utils.lua  (no dependencies)
    ↓
Core.lua   (depends on Utils)
    ↓
Data.lua   (depends on Utils, Core)
    ↓
Config.lua (depends on Utils, Core, Data)
    ↓
Scanner.lua (depends on Utils, Core, Data)
    ↓
Comm.lua   (depends on Utils, Core, Data, Config)
    ↓
Tooltip.lua (depends on Utils, Data)
```

All files share the `PST` namespace. Cross-module calls go through `PST.<Module>.<Function>()` (e.g. `PST.Comm.OnScanComplete()`, `PST.Config.GetDirectSyncList()`).

---

## 12. Editing Guidelines

- **Namespace**: All modules attach to `PST`. No global pollution except `ProfessionSpecTracker` (debug alias) and `ProfessionSpecTrackerDB` (SavedVariables).
- **Events**: Register via `PST.RegisterEvent(event, handler)`, not directly on frames.
- **Debug**: Use `PST.Debug(...)` and `PST.DebugWarn(...)`. Gated by `PST.debugEnabled` (toggle with `/pst debug`).
- **DB access**: Always go through `PST.db` (set after `Data.Init()`). Never write to `ProfessionSpecTrackerDB` directly except in `Data.Init()` and `Data.WipeAll()`.
- **Config access**: Use `PST.Config.Get(key)` / `PST.Config.Set(key, value)`. Defaults are in `CONFIG_DEFAULTS`.
- **Throttling**: Scans throttled to 2s, HELLO broadcasts to 30s. Respect these when adding new trigger paths.
- **pcall wrapping**: All Blizzard API calls in Scanner.lua are wrapped in `pcall()` for resilience against API changes or unavailable data.
