<p align="center">
	<img src="media/logo500.png" alt="Profession Spec Tracker Logo" />
</p>

A World of Warcraft (Retail) addon that shows which of your alts have invested specialization points in profession spec nodes — right inside the tooltip.

## Features

- **Tooltip Enhancement** — Hover any profession specialization node or tab to see which of your characters have invested points there, and how many.
- **Automatic Scanning** — Profession spec data is recorded whenever you open a profession window or spend specialization points. No manual steps required.
- **Cross-Alt Tracking** — Data is stored per-character in SavedVariables and shared across all characters on the same account automatically.
- **Cross-Account Sync** — Share profession data between multiple WoW accounts via two independent methods:
  - **Guild Sync** — Broadcast to guild members running the addon (opt-in, off by default).
  - **Direct Sync** — Whisper data to specific characters you configure. Only one side needs to set it up.
- **Settings Panel** — Manage sync settings, view stored characters, and configure direct sync targets from Interface → Addons → Profession Spec Tracker.

## Installation

1. Download the latest release from [CurseForge](https://www.curseforge.com/wow/addons/professionspectracker), [Wago](https://addons.wago.io/addons/professionspectracker), or the [GitHub Releases](../../releases) page.
2. Extract into your `World of Warcraft/_retail_/Interface/AddOns/` folder.
3. Restart WoW or `/reload`.

## Usage

Once installed, just open any profession with specializations. The addon scans automatically and stores the data.

Hover a spec node or tab to see your other characters' invested points in the tooltip:

```
Account Characters:
  Mainname-Turalyon (25)
  Altname-Turalyon (10)
Synced Characters:
  Friendalt-Stormrage (15)
```

### Slash Commands

| Command | Description |
|---------|-------------|
| `/pst` | Show help |
| `/pst scan` | Force rescan current professions |
| `/pst status` | Show stored character summary |
| `/pst sync` | Force sync (guild + direct) |
| `/pst config` | Open settings panel |
| `/pst directsync` | Manage direct sync targets |
| `/pst debug` | Toggle debug logging |
| `/pst wipe` | Wipe all saved data |

### Cross-Account Sync Setup

1. Open settings: `/pst config` → **Direct Sync** tab.
2. Add the character name of your alt on the other account (e.g. `Myalt-Stormrage`).
3. Log into that alt — sync happens automatically. Only one side needs to configure the other.

Guild sync can be enabled in the same settings panel if you want to share data with your entire guild.

## Requirements

- World of Warcraft Retail (Midnight)
- A profession with specializations
