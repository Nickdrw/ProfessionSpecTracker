# Copilot Instructions – ProfessionSpecTracker

## Project Overview

This is a **World of Warcraft Retail addon** (Lua, Interface 120001+) that tracks profession specialization points across alts and syncs data between accounts. See `ARCHITECTURE.md` for full details.

## Language & Runtime

- **Lua 5.1** (WoW's embedded runtime). No LuaJIT, no Lua 5.2+ features.
- No `require`, no `module()`. Files are loaded sequentially per the `.toc` file.
- All files share a namespace via `local _, PST = ...` (the addon's private table).
- Global writes are restricted to `ProfessionSpecTracker` (debug alias) and `ProfessionSpecTrackerDB` (SavedVariables).

## Code Conventions

- Use `local` for all variables and functions unless they must be globally accessible.
- Sub-modules attach to the shared namespace: `PST.ModuleName = PST.ModuleName or {}`.
- Public functions: `PST.Module.FunctionName()`. Local helpers: `local function helperName()`.
- Use `PST.Debug(...)` and `PST.DebugWarn(...)` for debug output (gated by `PST.debugEnabled`).
- Wrap all Blizzard API calls in `pcall()` inside Scanner.lua for resilience.
- Event registration goes through `PST.RegisterEvent(event, handler)`, not direct frame methods.
- DB access always via `PST.db` (never raw `ProfessionSpecTrackerDB` except in `Data.Init`/`Data.WipeAll`).
- Config access via `PST.Config.Get(key)` / `PST.Config.Set(key, value)`.

## File Responsibilities

| File | Purpose |
|------|---------|
| `Utils.lua` | Zero-dependency helpers: debug print, `GetCharKey()`, class-color wrap |
| `Core.lua` | Event frame, event dispatcher, slash commands, constants |
| `Data.lua` | SavedVariables schema, migrations, nodeIndex, character CRUD |
| `Config.lua` | Settings panel (10.0+ Settings API), Direct Sync management UI |
| `Scanner.lua` | Reads Blizzard profession APIs, stores spec node data |
| `Comm.lua` | Cross-account sync protocol (HELLO/PUSH/CHUNK over GUILD/WHISPER) |
| `Tooltip.lua` | Injects alt data into profession spec tooltips via EventRegistry |

Load order matters: `Utils → Core → Data → Config → Scanner → Comm → Tooltip`.

## Key Data Structures

- `PST.db.characters[charKey]` – per-character profession data, keyed by `"Name-Realm"`.
- `PST.db.nodeIndex[nodeID][charKey]` – reverse index for O(1) tooltip lookups.
- `PST.db.config.directSyncTargets` – set of `"Name-Realm" = true` for whisper sync.
- `charData.syncedFrom` – `nil` for locally scanned, `"guild"` for synced. **Never push characters with `syncedFrom` set** (prevents sync loops).

## Important Blizzard API Gotchas

- `C_TradeSkillUI.GetAllProfessionTradeSkillLines()` returns **stale skill lines for dropped professions**. Always cross-reference with `GetProfessions()`.
- `C_Traits.GetNodeInfo().currentRank` includes the unlock entry cost. Subtract it via `GetDisplayRanks()` to match Blizzard's displayed values.
- Addon messages have a **255-byte limit**. Messages are chunked automatically in `Comm.lua`.
- `C_ChatInfo.RegisterAddonMessagePrefix()` must be called before any messages can be received.

## Sync Protocol Rules

- HELLO broadcasts are throttled to 30s (`SYNC_COOLDOWN`).
- Only locally-scanned characters (`syncedFrom == nil`) are pushed in response to HELLO.
- WHISPER-channel messages are always accepted (enables one-sided direct sync).
- PUSH responses go via WHISPER (not GUILD) to avoid flooding.

## When Modifying

- Bump `PST.DB_VERSION` in `Core.lua` if changing the SavedVariables schema. Add migration logic in `Data.Migrate()`.
- New events should be registered via `PST.RegisterEvent()` and dispatched to the appropriate module.
- New config keys need a default in `CONFIG_DEFAULTS` (in `Config.lua`) and will auto-initialize via `Config.InitDefaults()`.
- Respect scan throttle (2s) and sync cooldown (30s) when adding new trigger paths.
- The tooltip hook uses `EventRegistry` callbacks, **not** `hooksecurefunc`. Do not change this pattern (see `ARCHITECTURE.md` §6 for rationale).
