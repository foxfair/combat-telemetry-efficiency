# CombatTelemetryEfficiency

Passive post-combat rotation and resource efficiency analyzer built for **World of Warcraft: Forever** (`1.60.1` / `Interface: 16001`).

Instead of flashing prescriptive rotation prompts mid-combat, **CombatTelemetryEfficiency** acts as a zero-clutter flight-data recorder during fights and generates an interactive, zoomable timeline review once combat ends.

---

## Features

- **Zero Mid-Combat Interference:** Renders nothing while in combat (`PLAYER_REGEN_DISABLED`); opens a subtle dismissible review pill or `/cte` window after combat ends (`PLAYER_REGEN_ENABLED`).
- **15ms Macro Burst & Level-Locked Spell Filtering:**
  - Discards level-locked or untalented spells inside leveling macros before resource checks run.
  - Clusters multi-line `/cast` macro bursts within `15ms` into vertical `[M]` icon stacks and suppresses false errors when a fallback line succeeds.
- **Objective Resource Verdicts:**
  - **`EFFICIENT` (Green):** Clean spend or generator cast.
  - **`EARLY_STARVED` (Red):** Keypress attempted without enough resource (collapses rapid GCD spam within `400ms` into an `xN` badge).
  - **`LATE_HOARD` (Amber):** Resource held at or above `2.0x` primary spender cost past the configured grace period while spenders were usable.
  - **`OVERCAP_WASTE` (Purple):** Wasted `SPELL_ENERGIZE` ticks at `100%`, `5/5 Combo Point` builder overcaps, or early Shaman totem clipping.
- **Dual-Resource & Multi-Form Support Across All 9 WoW Forever Classes:**
  - **Druid:** Tracks `Bear Form` (Rage + backup Mana), `Cat Form` (Energy + Combo Points + `[PS]` powershift tagging), `Moonkin Form`, and `Caster Form` with a color-coded Stance Ribbon.
  - **Hunter:** Evaluates player Mana shots/traps alongside Pet Focus (`UnitPower("pet", 2)`), pet casts, and pet uptime %.
  - **Rogue:** Tracks Energy pooling (`90` threshold) alongside a `1–5` Combo Point strip and `5/5 CP` builder overcap detection.
  - **Shaman:** Tracks Mana alongside 4 elemental totem lanes (`Fire`, `Earth`, `Water`, `Air`) via `PLAYER_TOTEM_UPDATE`.
  - **Warrior, Paladin, Priest, Mage, Warlock:** Tailored Rage and Mana overcap/starvation analysis without penalizing intentional Mana conservation.

---

## Installation (WoW Forever `1.60.1`)

1. Download the latest `CombatTelemetryEfficiency-vX.Y.Z.zip` from [GitHub Releases](https://github.com/foxfair/combat-telemetry-efficiency/releases) or clone this repository.
2. Extract the `CombatTelemetryEfficiency` folder into:
   ```text
   <WoW Forever Directory>/Interface/AddOns/CombatTelemetryEfficiency
   ```
3. Verify `CombatTelemetryEfficiency.toc` sits directly inside `Interface/AddOns/CombatTelemetryEfficiency/`.
4. Enable **CombatTelemetryEfficiency** on the character select AddOns screen (`Interface: 16001`).

---

## Slash Commands & In-Game Settings

| Command | Description |
| :--- | :--- |
| `/cte` | Toggle the post-combat timeline review window. |
| `/cte mult <1.0-5.0 \| default>` | Set the `hoardMultiplier` threshold (`2.0x` default) and re-score stored fights. |
| `/cte hold <0.0-10.0 \| default>` | Set the `hoardHoldSeconds` grace window (`1.0s` default) and re-score stored fights. |
| `/cte boss` | Toggle Boss-Only recording mode (ignores non-boss trash pulls). |
| `/cte rescore` | Re-run analysis across all stored encounters using current thresholds. |
| `/cte status` | Display combat state, saved fight count, and active threshold settings. |
| `/cte clear` | Clear all saved encounter history from `CombatTelemetryEfficiencyDB`. |

You can also click **`Settings`** in the top-right header of the `/cte` window to adjust sliders and toggles live.
