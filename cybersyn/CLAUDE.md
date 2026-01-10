# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Project Cybersyn is a Factorio 2.0+ mod that creates automated train logistics networks using cybernetic combinators and circuit network signals. It's written in Lua (~11K lines across 27 script files) and uses the Factorio Modding API.

**No build system** - Lua is interpreted by Factorio at runtime. Test changes by loading the mod in-game.

## Architecture

### Entry Points

- **control.lua** - Main runtime entry. Loads all scripts, registers event handlers, initializes GUI system
- **data.lua** - Data stage entry. Defines prototypes (entities, items, recipes, technologies)
- **data-final-fixes.lua** - Final mod compatibility adjustments

### Core Runtime Modules (scripts/)

| Module | Purpose |
|--------|---------|
| `global.lua` | Type definitions, MapData structure, global storage initialization |
| `main.lua` | Entity lifecycle, event handling, tick loop coordination |
| `central-planning.lua` | Train dispatch logic, provider/requester matching, economy system |
| `train-events.lua` | Train state machine, delivery tracking, manifest synchronization |
| `layout.lua` | Train cargo/wagon configuration detection |
| `constants.lua` | Signal names, combinator modes, train statuses |

### Data Flow

```
Tick Loop (every N frames):
  tick_poll_stations() → Read station inventories/requests
  tick_dispatch()      → Match trains to deliveries
  update_trains()      → Update train positions/status
```

### Key Data Structures

**MapData** (stored in `storage`):
- `stations` - Provider/requester train stops with combinator config
- `depots` - Train parking locations
- `trains` - Active trains with manifests and status
- `economy` - Hash-based provider/requester matching cache
- `to_comb` - Combinator lookup by unit_number

**Train Status Flow**: `STATUS_D (depot) → STATUS_TO_P → STATUS_P (loading) → STATUS_TO_R → STATUS_R (unloading) → STATUS_TO_D`

### Combinator Modes

```lua
MODE_PRIMARY_IO = "/"    -- Provider/Requester station
MODE_SECONDARY_IO = "%"  -- Secondary combinator
MODE_DEPOT = "+"         -- Train depot
MODE_REFUELER = ">>"     -- Fuel station
MODE_WAGON = "-"         -- Wagon manifest config
```

## GUI System (scripts/gui/)

- **manager.lua** - Window management, tab coordination, update scheduling
- **trains.lua**, **stations.lua**, **depots.lua** - Tab implementations
- **inventory.lua** - Item display with quality support
- **util.lua** - Table rendering, filtering, common UI patterns

GUI updates run on a separate configurable tick rate from the main dispatch loop.

## Mod Compatibility

- `scripts/mod-compatibility/` contains integrations for Space Exploration elevators and Picker Dollies
- Check `data-final-fixes.lua` for prototype adjustments based on active mods

## Remote Interface

`scripts/remote-interface.lua` exposes events for other mods:
- `on_station_created`, `on_station_removed`
- `on_train_created`, `on_train_removed`, `on_train_status_changed`
- `on_depot_created`, `on_depot_removed`

## Settings

Runtime settings defined in `settings.lua`:
- `cybersyn-ticks-per-second` - Planning update rate (0-60)
- `cybersyn-request-threshold` - Minimum request size
- `cybersyn-priority` - Default station priority

## Localization

9 languages in `locale/`: en, de, es, fr, ko, pl, ru, sv-SE, zh-CN. Each has `base.cfg` (core strings) and `manager.cfg` (GUI strings).

## Key Patterns

1. **Combinators as config interfaces** - Circuit combinators hold station/depot settings via signals
2. **Tick-based planning** - Configurable update rate for performance tuning
3. **Manifest system** - Trains carry cargo manifests with item names, counts, and quality levels
4. **Network masking** - Binary flags for multi-network station/train assignment
5. **Lazy deletion** - Invalid entities cleaned up on access rather than constant validation

## Making Changes

- **New train statuses**: `scripts/constants.lua` + update tick logic in `main.lua`
- **New GUI tabs**: Add file in `scripts/gui/`, register in `gui/manager.lua`
- **New settings**: Add to `settings.lua`, update locale files
- **Schema changes**: Update `scripts/migrations.lua` for existing saves
