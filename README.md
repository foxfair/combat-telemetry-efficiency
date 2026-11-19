# CombatTelemetryEfficiency

Passive post-combat rotation and resource efficiency analyzer built for **World of Warcraft: Forever** (`1.60.1` / `Interface: 16001`).

- **GitHub Repository:** https://github.com/foxfair/combat-telemetry-efficiency
- **CurseForge Project ID:** `1815218` (https://www.curseforge.com/wow/addons/combattelemetryefficiency)

---

## Features

- **Zero Mid-Combat Interference:** Renders nothing while in combat (`PLAYER_REGEN_DISABLED`); opens a dismissible review pill, minimap button, or `/cte` window after combat ends (`PLAYER_REGEN_ENABLED`).
- **Fast Post-Fight Triage:** Band 3 verdict filter chips (`All`, `Issues`, `Early`, `Late`, `Overcap`) isolate mistakes on both the timeline graph and step log in one click; **`Pin`** protects key boss parses from ring-buffer eviction and **`Delete`** removes individual pulls.
- **Post-Fight Chat Report Export:** Click **`Report`** in the header (or run `/cte report [self|party|raid|guild|say]`) to post a concise efficiency summary and the top 3 recurring resource improvements to chat.
- **Draggable Minimap Button:** Left-click to toggle the timeline review window, right-click to open threshold settings, or drag around the minimap edge (angle persisted in `CombatTelemetryEfficiencyDB.minimap.angle`).
- **15ms Macro Burst & Level-Locked Spell Filtering:** Discards unlearned/level-locked macro lines and clusters simultaneous macro casts within `15ms` into vertical `[M]` stacks.
- **Objective Resource Verdicts:** Classifies casts into `EFFICIENT`, `EARLY_STARVED` (with `xN` spam collapse), `LATE_HOARD`, and `OVERCAP_WASTE`.
- **Dual-Resource & Multi-Form Support Across All 9 WoW Forever Classes:** Druid (Bear/Cat/Moonkin/Caster stance ribbon + powershift detection), Hunter (Mana + Pet Focus & uptime), Rogue (Energy + Combo Points), Shaman (Mana + 4 elemental totem tracks), and Warrior/Paladin/Priest/Mage/Warlock.

---

## Slash Commands & In-Game Settings

| Command | Description |
| :--- | :--- |
| `/cte` | Toggle the post-combat timeline review window. |
| `/cte report [self\|party\|raid\|guild\|say]` | Share the latest encounter score and top 3 resource improvements to chat. |
| `/cte minimap` | Show or hide the draggable minimap button. |
| `/cte mult <1.0-5.0 \| default>` | Set the `hoardMultiplier` threshold (`2.0x` default) and re-score stored fights. |
| `/cte hold <0.0-10.0 \| default>` | Set the `hoardHoldSeconds` grace window (`1.0s` default) and re-score stored fights. |
| `/cte boss` | Toggle Boss-Only recording mode (ignores non-boss trash pulls). |
| `/cte rescore` | Re-run analysis across all stored encounters using current thresholds. |
| `/cte dump [count\|all]` | Open a scrollable, copyable (`Ctrl+C`) popup window with raw timestamps, spell IDs, resource deltas, and verdicts. Use `/cte dump chat [count]` to print to chat instead. |
| `/cte status` | Display combat state, saved fight count, and active threshold settings. |
| `/cte pin [idx]` | Pin or unpin a recorded fight (defaults to latest) to protect it from ring-buffer eviction. |
| `/cte del [idx]` | Delete an individual recorded fight from history (defaults to latest). |
| `/cte clear [all]` | Clear unpinned encounter history (add `all` to also wipe pinned fights). |
