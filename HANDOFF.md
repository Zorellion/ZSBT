# Project Handoff / Technical Overview

## What this addon is
ZSBT (Zore's Scrolling Battle Text) is a World of Warcraft Retail 12.x addon that displays combat-related text in customizable scroll areas (incoming damage/healing, outgoing damage/healing, notifications/alerts) similar in spirit to MSBT.

It is designed to be safe under modern Retail restrictions ("secret values" / taint risks) and to remain functional in environments where classic combat log strategies are either unreliable or undesirable.

## Non-negotiable constraint: CLEU is forbidden
**This project intentionally does not use `COMBAT_LOG_EVENT_UNFILTERED` (CLEU).**

Requirements/assumptions for ongoing development:
- CLEU is treated as **forbidden** for this addon.
- Any contribution that proposes adding CLEU-based parsing should be rejected unless the project explicitly changes direction.

Rationale:
- The addon is built around a constrained set of safer/whitelisted signals available in Retail 12.x.
- Avoiding CLEU reduces the surface area for taint issues, secret-value propagation, and performance pitfalls.
- The existing architecture and heuristics assume that combat events are derived from alternate sources (below). Introducing CLEU would create parallel pipelines and inconsistent attribution behavior.

## How ZSBT works (high-level)
ZSBT is split into two major layers:

### 1) Parser layer (signal collection + normalization)
The parser layer listens to a curated set of events (not CLEU) and emits normalized internal events.

Primary kinds of signals used:
- **Blizzard combat text feeds** (e.g. `COMBAT_TEXT_UPDATE` + related CombatText routing).
- **`UNIT_COMBAT`** (including `unit == "target"` fallback strategies for some periodic/physical streams).
- **Spellcast lifecycle events** such as `UNIT_SPELLCAST_SUCCEEDED` for correlation/attribution.
- **Cooldown APIs** via `C_Spell.GetSpellCooldown` / `C_Spell.GetSpellCharges` + update events (`SPELL_UPDATE_COOLDOWN`, `SPELL_UPDATE_CHARGES`).
- **Aura APIs** via `UNIT_AURA` + `C_UnitAuras` data.
- **Chat/system messages** for non-combat notifications (loot/progress/tradeskills/etc., depending on feature).

The parser’s job is to:
- Collect signals.
- Apply heuristics to attribute them to the player where necessary.
- Produce a consistent internal event payload that the rest of the addon can consume.

### 2) Core/UI layer (routing + formatting + display)
Core modules take normalized events and decide:
- Whether to display them (filters/thresholds/enable toggles).
- Where to route them (scroll areas).
- How they should look/sound (fonts/colors/sticky behavior/icons).

The UI layer (AceConfig) exposes configuration for:
- Scroll areas (position/size/animations/fonts).
- Incoming/outgoing streams (thresholds, routing, spell names/icons).
- Notifications (templates/routing/sounds).
- Cooldowns + triggers.
- Diagnostics/debugging.

## Key subsystems

### Incoming / Outgoing combat text
Incoming and outgoing output is built from non-CLEU signals and may use fallback attribution strategies depending on content type (open world vs instance restrictions, PvP strictness, etc.).

Important implementation note:
- Some “fallback” detection relies on Blizzard combat messages being generated. If users disable too many combat log/chat filters, certain detection paths may degrade.

### Scroll Areas / Display
Text is emitted into named scroll areas. A scroll area defines:
- Position + size
- Animation style
- Font settings
- Sticky/crit treatment

### Notifications
Notifications are non-damage informational lines (combat state, loot, cooldown ready, auras, etc.) typically routed to a Notifications scroll area.

### Cooldowns
Cooldown ready alerts are implemented by:
- Tracking watched spells (from the Cooldowns UI tracked list and/or COOLDOWN_READY triggers).
- Detecting when a spell enters cooldown and scheduling a timer for readiness.
- Resyncing via cooldown APIs on lifecycle events (login/zone/combat transitions) so readiness can still fire even if the original cast wasn’t observed.

### Triggers
Custom triggers allow users to create notifications for events like:
- Aura gained/faded
- Cooldown ready
- Resource thresholds

Triggers can optionally attach spell icons to their emitted notifications.

### Blizzard Combat Text suppression (FCT)
ZSBT can manage Blizzard Floating Combat Text CVars to reduce duplicate spam.

As of 2.0.10 this is modular:
- `None (no-touch)`
- `Suppress All`
- `Suppress Incoming Only`
- `Suppress Outgoing Only`

**Important**: CVars persist outside the addon. ZSBT snapshots/restores previous values when suppression is used.

## SavedVariables
Primary SavedVariable: `ZSBTDB` (AceDB). High-level structure:
- `profile`: user profile settings (general, incoming/outgoing, notifications, UI, etc.)
- `char`: per-character settings (notably some rule/trigger storage)
- `global`: persistent global bookkeeping (e.g. Blizzard FCT backup state)

## Debugging and support
ZSBT includes diagnostic toggles and debug levels. When debugging:
- Prefer enabling addon debug output rather than adding spammy prints.
- Be cautious of printing or concatenating values that might be secret/tainted.

## Development rules of thumb (handoff)
- Do not introduce CLEU.
- Treat any `UnitName()` / GUID / combat payload fields as potentially unsafe/secret; sanitize before formatting.
- Prefer “no-touch” behaviors for Blizzard CVars when a feature is disabled.
- When adding new detection, integrate it into the existing parser->core pipeline rather than creating parallel output paths.

## Maintainer map (where things live)

### Entry points / initialization
- `ZSBT.toc`
  - Defines load order.
- `Core/Init.lua`
  - Creates the AceAddon instance (`ZSBT.Addon`).
  - Registers slash commands.
  - Initializes the AceDB database.
  - Coordinates parser enable/disable with combat lockdown deferral.
- `Core/Core.lua`
  - Central runtime coordinator (`ZSBT.Core`).
  - Enables subsystems.
  - Applies lifecycle policies (including Blizzard combat text CVar management).

### Parser pipeline (non-CLEU event collection)
- `Parser/Event_Collector.lua`
  - Central event collector / coordinator.
  - Handles key non-CLEU signals (notably `UNIT_COMBAT`-derived streams).
- `Parser/Pulse_Engine.lua`
  - Internal event pump/dispatcher (collector -> processors -> core display decisions).
- `Parser/Cooldowns_Detect.lua`
  - Cooldown detection, ready timers, and resync.

### Output decision + rendering
- `Core/Display_Decide.lua`
  - Final decision point for routing/styling.
  - Interprets metadata like spell icons and font overrides.
- `Core/ScrollAreas.lua` (and related UI)
  - Scroll area definitions, animations, unlock/lock, geometry persistence.

### Features / subsystems (Core)
- `Core/Triggers.lua`
  - Custom triggers.
  - Trigger event evaluation and action emission.
- `Core/Cooldowns_Decide.lua`
  - Cooldown-ready notifications and trigger firing.
- `Core/Incoming_*.lua` / `Core/Outgoing_*.lua` (and/or similarly named modules)
  - Stream-specific rules and formatting decisions.

### Configuration UI
- `UI/Config.lua`
  - Assembles the master options table.
  - Contains some embedded Help/Troubleshooting text.
- `UI/ConfigTabs.lua`
  - The actual per-tab AceConfig option definitions.
- `Core/Defaults.lua`
  - All default settings (AceDB profile schema).

### Documentation
- `Docs/`
  - Markdown docs intended for users but useful for developers to understand expected behavior.

## Data flow (mental model)

### Combat-ish events
In general:
1) A Blizzard/game signal arrives (non-CLEU).
2) Parser collects it and normalizes an internal event payload.
3) Core modules decide whether to emit.
4) Display layer routes/stylizes and shows it in a scroll area.

### Cooldown-ready events (example)
1) Cooldown tracking observes cooldown start via spellcast/update signals.
2) A readiness timer is scheduled.
3) When timer fires, `Core/Cooldowns_Decide.lua` emits a notification (optional icon) and fires any `COOLDOWN_READY` triggers.
4) Resync runs on lifecycle events so missed casts still produce timers when cooldown data is readable.

## Common maintainer tasks (where to change what)

### Add or adjust Blizzard Combat Text suppression behavior
- Primary logic: `Core/Core.lua`
  - Look for the Blizzard FCT CVar lists and the suppression mode handling in `Core:ApplyBlizzardFCTCVars()`.
- UI: `UI/ConfigTabs.lua`
  - Option name: `Blizzard Combat Text Suppression`.
- Defaults: `Core/Defaults.lua`

### Add a new trigger type or extend trigger payload metadata
- Core trigger logic: `Core/Triggers.lua`
- Trigger editor UI: `UI/Config.lua`
- Trigger list/config tab: `UI/ConfigTabs.lua`

### Add/modify cooldown-ready behavior
- Detection/timers/resync: `Parser/Cooldowns_Detect.lua`
- Emission + trigger firing + icon meta: `Core/Cooldowns_Decide.lua`
- Cooldown UI + tracked list: `UI/ConfigTabs.lua`

### Add new notification categories
- Category gating/routing/templates typically live in `Core/Core.lua` (notification system) and `UI/ConfigTabs.lua` (Notifications tree).

## Debugging / testing checklist (Retail 12.x safe)

### First checks
- Verify ZSBT version surfaces:
  - `ZSBT.toc` `## Version:`
  - `Core/Constants.lua` `ZSBT.VERSION`
- Confirm config UI loads without AceConfig errors.
- Test in open world first (simplest signal environment), then in instance content.

### Quick in-game checks
- **Outgoing**:
  - Confirm outgoing damage/healing appears when attacking a target dummy.
- **Incoming**:
  - Confirm incoming damage/healing appears (take fall damage or duel).
- **Cooldowns**:
  - Track a spell cooldown and confirm ready alert.
- **Triggers**:
  - Create a simple trigger (e.g., cooldown ready) routed to Notifications.
- **Blizzard Combat Text suppression**:
  - Toggle suppression modes and confirm ZSBT does not force Blizzard settings when set to `None (no-touch)`.

## Release workflow notes (project practice)
Development is done in the **live addon folder**:
- `e:/Blizzard/World of Warcraft/_retail_/Interface/AddOns/ZSBT`

Release steps (high-level):
1) Update version surfaces:
   - `ZSBT.toc`
   - `Core/Constants.lua`
   - `CHANGELOG.md`
2) Sync live folder -> repo (`e:/REPOS/ZSBT`)
   - Do not overwrite `.pkgmeta`
   - Do not copy `Media/` unless explicitly intended
3) Commit, tag (`vX.Y.Z`), and push commit + tag.
