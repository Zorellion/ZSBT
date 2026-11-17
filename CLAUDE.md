# Project: Zore's Scrolling Battle Text (ZSBT) - Retail
You are an expert World of Warcraft addon developer specializing in the modern Retail Lua API.

## Core Directives
- **Zero Legacy Globals**: Strictly use the modern `C_` namespaces (e.g., `C_Timer`, `C_ChatInfo`, `C_CombatLog`).
- **Garbage Collection (GC) Mitigation**: Prioritize table recycling pools (`Wipe` / object pooling) for high-frequency events (`COMBAT_LOG_EVENT_UNFILTERED`).
- **Secure Frames**: Ensure all UI frame rendering adheres to modern anchoring and secure frame templates. Do not trigger interface taints during combat lockdown.

## ZCT combat core transplant (in progress, unreleased)

The combat attribution/display-detection core is being replaced by a transplant of **Zore's Combat Text (ZCT)**, namespaced under `ZSBT.ZCT` (`ZCT/Core/*.lua`, TOC lines ~61-77). ZCT's own `Display/`, `UI/`, `FCT`, `Notify`, `Interrupts`, `Loot`, `Auras`, `Minimap`, `ResourceCounter` modules were deliberately NOT ported — ZSBT keeps its own display/rules/fonts/animations.

Pipeline: `ZCT.Collector` (whitelisted events) → `ZCT.LogLines` (COMBAT_LOG_MESSAGE RGB classify) + `ZCT.Incoming`/`ZCT.Outgoing` (pairing + attribution) → `ZCT.Normalize` (pooled CombatEvents, sink bus) → sinks: `ZCT.Decide` (no-op without Display) and **`ZCT.Bridge`** (`ZCT/Core/Bridge.lua`).

`ZCT.Bridge` translates CombatEvents into the legacy `info` contract and calls `ZSBT.Parser.Outgoing:ProcessEvent` / `Incoming:ProcessEvent` directly; pet events go to `PulseEngine:collect("PET_*")`. Secret amounts ride `EventCollector._rawPipe` (rawPipeId). The bridge also notes `_noteOutgoingSignal`/`_noteIncomingSignal` (damage-meter fallback suppression) and maintains `ec._lastOutgoingCombatAt/_lastOutgoingCombatTargetName` (kill inference).

Retired: `Parser.CombatLog:Enable` no longer wires `EventCollector -> PulseEngine` and never calls `collector:Enable()` — the collector's frame never registers events. `PulseEngine` stays enabled ONLY for pet-merge + damage-meter fallback sinks. `Event_Collector.lua` remains in the TOC solely to own the `_rawPipe` registry and legacy state fields.

Persistence: ZCT settings live at `ZSBTDB.ZCT` (bound in `ZCT/Core/Init.lua` OnLogin — SavedVariables are nil at file load). Filter name is `"ZSBT"` (`ZCT.FILTER_NAME`); written at PLAYER_LOGOUT, verified at PEW. The v3.7.0 `combatLogFilterCleanup_v1` migration only removes the OLD-palette filter and is one-time — it cannot delete the new filter (it runs before the new filter is ever written, and the flag is already set for 3.7.0 users).

Legacy attribution toggles REMOVED (ZCT Context/groupPolicy/contention handles strictness automatically): the Dungeon/Raid, PvP, and Open-World tuning sections were cut from `UI/ConfigTabs.lua`, the Instance/Open World/PvP dropdowns were cut from `UI/QuickControlBar.lua` (bar is now label+Unlock only), the `IsPvPStrictActive` auto-suppression was removed from `Parser/Outgoing_Detect.lua`, and the damage-meter combat-text fallback polls were disabled in `Parser/Pulse_Engine.lua` (`shouldPollDamageMeter*` return false — they emitted unattributed numbers). Saved db keys remain but have no UI and no live consumers outside dead code paths.

NOT yet verified in-game. Stage 3 (optional): delete dead combat paths inside `Event_Collector.lua`/`Pulse_Engine.lua` and the now-dead Core gating helpers once the bridge proves out.

## Development & Release Workflow

- **Authoritative source**: All code work happens ONLY in this folder (`_retail_\Interface\AddOns\ZSBT`). Retail is the DEV copy. Never edit `_classic_beta_`, `_forever_`, or `_ptr_` copies directly; they are synced from here only when the user explicitly asks (e.g. for testing on that client).
- **`_forever_` divergence is expected**: the user updates `_forever_` via CurseForge, which installs the last *released* package and overwrites whatever was mirrored. After a CurseForge update the folder matches the release (minus `.pkgmeta`-excluded dev files: `.devin`, `.pkgmeta`, `CLAUDE.md`), NOT the retail dev tree. Do not treat `_forever_` drift as corruption — only mirror retail → `_forever_` (robocopy `/MIR`) when the user asks to test unreleased changes there.
- **"increment version" / "bump to vX.Y"**: Update `ZSBT.toc` (`## Version`), `Core/Constants.lua` (`ZSBT.VERSION`), and `CHANGELOG.md` (new top section). Also update any in-game help text, docs, or troubleshooting references affected by the change. Do not touch other client folders.
- **"release version" / "release vX.Y"**: Verify version metadata is consistent, then sync this folder to `F:\REPOS\ZSBT` (preserve the repo's `.git` and `.github`; dev files `.devin`, `.pkgmeta`, `CLAUDE.md` stay in the repo but are excluded from packages via `.pkgmeta`). Then `git add -A`, commit (`Release vX.Y`), tag `vX.Y`, and push `main` + tag to `origin` (`https://github.com/Zorellion/ZSBT.git`). Git is at `C:\Program Files\Git\cmd\git.exe` and the repo needs `-c safe.directory=F:/REPOS/ZSBT` per command.
- **Tag format**: `vX.Y` (e.g., `v3.2`). Pushing the tag triggers `.github/workflows/release.yml`, which runs the BigWigs packager and attaches the zip to a GitHub Release; CurseForge pulls that release automatically.
- **`.pkgmeta`**: `package-as: ZSBT` is the archive folder name — never use it for versioning. Its `ignore:` list must keep excluding `.git`, `.github`, `.devin`, `.pkgmeta`, and `CLAUDE.md`.

---

# Masterplan: Periodic Damage Tracker extraction (`Parser/Periodic_Tracker.lua`)

Status: **implemented, then partially reverted in v3.7.0.** The tracker module exists and is the single home for periodic attribution, but the learned-signal layer this plan designed (learned school map, tick-interval prediction, `nextTickAt`, combat-log RGB line corroboration) was **removed** — `UNIT_COMBAT` has no reliable source attribution on secret-value clients, so learned/inferred signals produced confident-looking wrong spell IDs. Current state: deterministic matching only (aura freshness + cast memory + canonical `KNOWN_DOT_SCHOOLS` + fixed-window liveness). The combat-log filter module (`CombatLog_Lines.lua`) and off-target AoE tracker (`AoE_Damage.lua`) were also deleted; there are **no combat-log reads at all** now. Do not reintroduce learned attribution or combat-log inference without a fundamentally reliable source signal.

## Why

Periodic-hit attribution is currently duplicated across three divergent paths inside `Parser/Event_Collector.lua`:

- target path (~line 3430) — has all latest fixes (signal-live bypass, `applyAt` seeding, pending-cast peek, nameplate dedup)
- pet-fallback path (~line 2655) — older gates, missing the signal-live fixes
- combat-text path (~line 2495) — third variant

They have already drifted once; they will drift again. Consolidating is required for all-class correctness, and per-DoT state needs a real home to support multiple simultaneous DoTs.

## Hard limits (unchanged by refactor)

- `COMBAT_LOG_EVENT_UNFILTERED` is permanently off the table (protected → `ADDON_ACTION_FORBIDDEN`).
- No combat-log reads of any kind — `COMBAT_LOG_MESSAGE` RGB pairing was removed in v3.7.0 as unreliable.
- `UNIT_COMBAT` carries no source unit on secret-value clients: cross-player DoT ambiguity on shared targets cannot be solved by any architecture. The restrict/group gates are the ceiling there.
- Secret amounts flow through `rawPipe` untouched — pipeId allocation stays in the collector emit functions, verbatim.

## Architecture

New module `ZSBT.PeriodicTracker` in `Parser/Periodic_Tracker.lua` (`local ADDON_NAME, ZSBT = ...` at top — bare global `ZSBT` aborts file load).

### API (called from Event_Collector)

| Function | Replaces | Purpose |
|---|---|---|
| `PT:NotePlayerCast(spellId, spellName, t)` | `isKnownPeriodicSpellId` + `_recentPeriodicSpellAt` seed (~line 1108) | Seed a DoT candidate from a player cast (name matched against `PERIODIC_AURA_NAMES`) |
| `PT:ScanTargetAuras(t)` | `scanTargetPeriodicAuras` | Throttled scan; updates records; seeds `applyAt` from `expirationTime - duration` |
| `PT:MatchHit(t, school, isCrit)` | `getMostRecentPeriodicSpellId` + confident/debuffOk gates | Unified decision: returns spellId or nil |
| `PT:NoteEmit(spellId, t)` | scattered `_recentPeriodicSpellAt[sid] = t` writes | Recency refresh |
| `PT:IsTracked(spellId)` | `isAuraTrackedPeriodic` | Aura-backed check for callers |

### Per-DoT record

```lua
_dots[spellId] = {
    applyAt,     -- true application time (exp - duration), corrected on refresh
    seenAt,      -- last scan sighting (staleness expiry)
    interval,    -- learned tick interval (nil until >=2 confirmed ticks)
    school,      -- learned from first confirmed tick (no hardcoded per-class tables)
    nextTickAt,  -- predicted next tick time (lastTick + interval)
    seedSource,  -- "cast" | "aura"
}
```

### Lifecycle

1. **SEEDED** — player cast matched `PERIODIC_AURA_NAMES` by name
2. **CONFIRMED** — a hit attributed to it was paired with a tick-colored combat-log line
3. **AURA** — live debuff seen by scan; `applyAt` corrected to true application time

### Match precedence (secret non-physical WOUND, unattributed)

1. Color signal dead → legacy aura/cast gates (keep as fallback — no behavior change for users without the filter)
2. Color signal live → defer `DOT_LINE_WAIT` (0.15s): `kind=="tick"` emits, `direct/melee/ranged` vetoes, `nil` emits (aura-backed only)
3. Pending-cast peek (`consumeBestPendingCast(..., false)`) still required — never intercept a hit a cast could own
4. Among tracked dots pick winner by: school match → nearest `nextTickAt` → most recent `applyAt`

### New matching signals (multi-DoT accuracy)

- **Learned school map** — record the hit's safe `school` on each confirmed tick per spellId; prefer candidates whose learned school matches the hit's school
- **Tick-schedule prediction** — median interval from ≥2 confirmed ticks; a hit within ±0.35s of `nextTickAt` is strong evidence for that DoT

## Migration steps

1. Create `Parser/Periodic_Tracker.lua`; add to `ZSBT.toc` immediately before `Event_Collector.lua`
2. Port the **target path** first — keep `DOT_MISS`/`DOT_EVAL`/`DOT_LINE_OK`/`DOT_LINE_VETO` debug tags byte-identical so logs diff cleanly
3. Port the pet-fallback path (it also gains the signal-live fixes it never got)
4. Port the CT path (~line 2495)
5. Migrate remaining readers of `_periodicAuraAt` / `_recentPeriodicSpellAt` (lines ~1897, ~2520) onto `PT:` API, then delete the old state
6. Multi-DoT hardening: learned school map + tick-interval prediction
7. Quiet the debug prints, changelog entry

## Verification checklist (same dummy ritual)

- First tick after application emits (not dropped)
- No duplicate ticks (nameplate→target dedup intact)
- Lightning Bolt / nukes unaffected during an active DoT
- Ticks stop when the DoT ends; no stragglers beyond one scroll duration
- Multi-DoT: correct icon per tick (step 6)
- Compare log diffs pre/post refactor — same tags, same cadence

## Rollback

Single-file revert of `Event_Collector.lua`; new module is additive until step 5. Optionally gate `PT:MatchHit` usage behind `profile.diagnostics.periodicTracker` during transition.

## Files

- New: `Parser/Periodic_Tracker.lua`
- Edited: `Parser/Event_Collector.lua` (three call sites → `PT:` API), `ZSBT.toc`, `CHANGELOG.md`
- Sync target after verification: `_forever_` copy

---

# Masterplan: Config UI unification

Status: **SUPERSEDED by "ZCT-style config shell" below (user-directed rebuild, side-by-side with old UI).** Phase 0 audit findings still valid reference.

---

# Masterplan: ZCT-style config shell ("zctui")

Status: **P0+P1 implemented — awaiting in-game verification.** User directive: rebuild the config window to
match standalone ZCT's *flow and structure* — left sidebar page nav, one
focused page at a time — while keeping ZSBT's widgets, theme, and
ZSBT-only features. Old AceConfig UI stays intact side-by-side; new UI opens
via `/zsbt zctui`. Do NOT remove the old UI without explicit approval.

## Verified technical facts (researched 2025-11)

- `AceConfigDialog:Open(appName, container, ...)` accepts an **AceGUI widget
  container**: it `ReleaseChildren()` + `FeedGroup()` renders the options
  into it; non-InlineGroup containers auto-wrap in a ScrollFrame
  (AceConfigDialog-3.0.lua ~L1639, ~L1853). This is the embedding mechanism.
- ZSBT already bundles AceGUI-3.0 and uses it directly (ZSBT_InstantEditBox
  widget ~UI/Config.lua:72, help popup ~3039).
- ZCT shell reference: `ZCT/UI/Config.lua` — `buildShell()` (~L108-161):
  900x640 frame, 150px sidebar, NAV buttons, content frame,
  `pageFrames`/`pageHolders`, `ShowPage(id)` with per-page refresh
  hooks (`Config._refresh`). Pages = titled InlineGroup + ScrollFrame, or
  list+editor (combat categories, scroll areas).
- ZSBT options pipeline: `UI/ConfigTabs.lua` builders →
  `BuildOptionsTable()` (UI/Config.lua ~L3520) → `Addon:OpenConfig()`
  rebuilds + `InjectDBProfilesOptions` + `ACR:RegisterOptionsTable("ZSBT")`
  + `ACD:Open("ZSBT")` (Core/Init.lua ~L2657).
- ~1000 lines of ACD integration in UI/Config.lua that assume ONE app:
  theme/hooks (~L3927-4400), SelectGroup visibility (~L4541-4706),
  cooldown + spellRules drag-drop overlays (~L4713, ~L5063), status
  persistence, widget-tree walking.

## Architecture

New files only — `UI/Config.lua`, `UI/ConfigTabs.lua`, satellites, and all
ACD hooks for "ZSBT" remain untouched:

- `UI/ConfigShell.lua` — ZCT-style frame + sidebar + page host, styled with
  ZSBT colors/fonts (NOT ZCT's palette — keep ZSBT look).
- `UI/ConfigPages.lua` — NAV registry + per-page options-table builders
  wrapping the existing `BuildTab_*` args.

### Page mapping (ZCT nav order)

| Nav page | Args source |
|---|---|
| General | `BuildTab_General().args` (now incl. Media) |
| Profiles | `BuildTab_ProfilesRoot().args` |
| Combat Text | `BuildTab_CombatText().args` (Incoming/Outgoing/Pets/Spam) |
| Crits | `BuildTab_Crits().args` |
| Alerts | `BuildTab_Alerts().args` (Notifications/Triggers/Cooldowns) |
| Resources | `BuildTab_Resources().args` |
| Scroll Areas | `BuildTab_ScrollAreas().args` |
| Help | maintenance group's args (Help + Troubleshooting) |

Each page registers its own options table
`ZSBT_pg_<id>` = `{type="group", name, childGroups, args=<subargs>}` and
opens via `ACD:Open("ZSBT_pg_<id>", containerWidget)` where the container
is an AceGUI "Frame" widget inside the shell's content frame (one container
per page, fed once, hidden/shown — NOT re-fed on nav).

Sub-group presentation: `childGroups="select"` gives an in-page tab bar
(preferred — closest to ZCT's focused pages); `"tree"` would need ACD's
tree pane inside the page, which we don't want.

## Required infrastructure

1. **NotifyChange fan-out** — every arg `set()` calls
   `ACR:NotifyChange("ZSBT")`. Wrap `ACR.NotifyChange` (or the ACD
   equivalent) so "ZSBT" also notifies all `ZSBT_pg_*` apps, or
   hidden/disabled/order-dependent widgets go stale. ~15 lines, one hook.
   Satellite apps keep their own names — unaffected.
2. **Rebuild-on-open** — `OpenConfig()` already rebuilds the "ZSBT" table
   per open; extend to rebuild + re-register page tables (builders are pure).
3. **Slash** — `/zsbt zctui` → `Addon:OpenZCTUI()`; bare `/zsbt` keeps
   opening the old UI until cutover is approved.
4. **TOC** — add `UI/ConfigShell.lua`, `UI/ConfigPages.lua`.

## Port/generalize checklist (audit during build)

- Theme/accent hooks (~L3927-4400): verify they fire for page-app widgets
  (same ACD machinery — likely automatic; confirm tab/heading colors).
- SelectGroup visibility hack (~L4541-4706): audit whether select-style
  pages need it.
- Drag-drop overlays (cooldowns ~L4713, spellRules ~L5063): anchor to main
  ACD contentFrame today — re-anchor to page containers or generalize host
  lookup.
- `InjectDBProfilesOptions`: AceDB auto-injects only into "ZSBT" — the
  Profiles page uses `BuildTab_ProfilesRoot` (custom); verify it is
  self-contained, do NOT inject into page apps.
- Scroll-area dropdown args rebuild on show — add `Config._refresh`-style
  hooks per page like ZCT's.
- Status/size: keep ZSBT 900x820 unless user prefers ZCT 900x640.

## Phases

- **P0** — shell frame + nav + General page only. Prove: open, widgets
  set/get, NotifyChange refresh, theme applies.
- **P1** — all 8 pages; nav switching; per-page scroll; refresh-on-show.
- **P2** — parity pass: overlays/drag-drop, dynamic args (resource buttons
  per class), Profiles page, satellite launch buttons from pages.
- **P3** — cutover decision (user approval required): keep `/zsbt` on old
  UI; optional `general.newUI` toggle; old UI removal only on approval.
- **P4** (optional ZCT fidelity) — list+editor layouts for Scroll Areas /
  Resources; promote Spam Control to its own nav page.

## Risks

- ACD container-embed edge cases (ReleaseChildren reuse, status tables,
  OnClose) — mitigated by one container per page fed once.
- NotifyChange fan-out completeness — every `ZSBT_pg_*` app must be
  covered or dependent widgets stale.
- Widget-tree-walking code (theme, overlays, status) assumes one app —
  each site needs audit.
- In-combat open constraints identical to today.

## Decisions (locked with user 2025-11)

- Window: default 900x820 (ZSBT size) but **resizable** like the existing
  ACD window — add a resize grip; persist size across sessions.
- Last page name: **Help and Support** (Help + Troubleshooting content).
- Spam Control: **own nav page** — 9 pages total:
  General, Profiles, Combat Text, Crits, Alerts, Resources,
  Scroll Areas, Spam Control, Help and Support.
- Cutover: TWO commands coexist — `/zsbt` stays old UI,
  `/zsbt zctui` opens new shell. Only after user confirms does `/zsbt`
  swap to the new UI.


## Phase 0 audit findings (2025-11)

True duplicates (same db key, multiple editors):
- `general.enabled`, `general.combatOnly`, `general.hideBlizzardFCT` + 7 sub-toggles + `hideBlizzardFCTPet` + `restoreBlizzardFCTNow`, `general.quickControlBarEnabled` + reset — all edited in BOTH QuickStart and General. QuickStart versions had better legacy-aware getters; General's `enabled` set was the only one doing real runtime toggling (QuickStart called nonexistent `Core:SetEnabled` — fixed in Phase 1).
- `media.sounds.cooldownReady` — edited in both Cooldowns tab and Media tab (benign; left as-is, same value two contexts).
- `general.critFont` — split editing: General had face/size/useScale/anim/outline/scale; CombatText had the 8 `*Intensity` sliders (found at bottom of Combat Text tab, order 23.57+). Consolidated in Phase 1.

Read-only cross-references (NOT duplicates, left alone): `general.font.*` in ScrollAreas (fallback reads), `notifications*` in ResourceCounter args (routing selectors), `outgoing.crits` in QuickStart (test button), `char.cooldowns.tracked` in General (reset-to-defaults preservation), `char.spamControl.*` shared by rule managers (same underlying tables by design).

## Hard constraints

- **Zero `db.profile`/`db.char` key renames, moves, or path changes** — saved settings must survive untouched.
- All existing `get`/`set`/`disabled` functions preserved verbatim; only `args` structure, headers, order, and descriptions change.
- New UI strings go through `L[]` with locale entries (Locales/*.lua for every shipped locale).
- Satellite option tables keep their `ACR:RegisterOptionsTable("ZSBT_*")` registrations and all `ACR:NotifyChange("ZSBT_*")` calls — nothing that calls `ACD:Open("ZSBT_X")` may break.
- Options are rebuilt on every `Addon:OpenConfig()` — presentation-layer reshuffling is safe.

## Architecture (current)

- Main window: `UI/Config.lua` builds the AceConfig tree (`ZSBT` options table) from `UI/ConfigTabs.lua` arg groups.
- 7 satellite dialogs: Spell Rules, Buff Rules, Spell Rule Editor, Buff Rule Editor, Trigger Editor, Resource Counter, Debug — separate `ACD:Open` windows launched via buttons.
- `UI/ConfigTabs.lua` (~10.7k lines) holds per-section arg definitions; `UI/Config.lua` (~5.1k lines) assembles order/tree/groups.

## Phases

### Phase 0 — Audit (no behavior change)
Script/grep pass over `ConfigTabs.lua` + `Config.lua` cataloging every option's effective db path. Distinguish true duplicates (same key written from two places) from presentation-only overlaps. Output decides what Phase 1 may safely dedupe.

### Phase 1 — Main-tree polish — REVERTED (user rejected; files restored from repo)
What was tried (all reverted): Combat Text moved before Display (order 0.65); Blizzard FCT toggles deduped to QuickStart-only with an "Open Quick Start" button in General; QuickStart `enabled` toggle fixed to do real runtime toggling (it previously called nonexistent `Core:SetEnabled` — **this was a genuine bug fix, lost in the revert**); 8 `general.critFont.*Intensity` sliders moved from CombatText bottom into General's Critical Hit Font section; tab descriptions added to Incoming/Outgoing.
If revisited, the only piece arguably worth re-applying alone is the QuickStart `enabled` set fix (Core:Enable/Disable + Parser toggles instead of the no-op `Core:SetEnabled` call) — **this fix WAS re-applied after the revert** (QuickStart enabled toggle now does real runtime toggling; unreleased).

### Phase 2 — Satellite consolidation (medium risk, NOT started)
- Option A (safer): keep dialogs, add "← Back to ZSBT" behavior, launch with relevant tree node pre-selected.
- Option B (bigger): embed rule *managers* as collapsible groups inside main tree (`childGroups="tree"`), keep standalone windows registered for deep links. Editors stay popups.
- Decision point: revisit after Phase 1 is tested in-game.

### Phase 3 — Nice-to-haves (not started)
QuickStart presets/wizard polish; test buttons colocated with tested settings; profile import/export surfacing.

## ZCT-flow restructure (2025-11, user-directed — DONE in dev tree)

User approved a flow overhaul matching standalone ZCT section order while
keeping ZSBT look/feel and nested groups. Implemented:

- Quick Start tab REMOVED from tree (`BuildTab_QuickStart` left defined but unhooked).
- New top-level tabs: `Crits` (order 4 — crit font block from General +
  forceCritsInline/inlineCrit args + critFont.*Intensity sliders from
  CombatText; intensity orders renumbered 23.x→33.x) and `Resources`
  (order 6 — `resourceTracker` group extracted from Notifications;
  `notifyRt` throttled-notify local moved with it).
- Media group moved Display→General (order 17); Display wrapper removed,
  `scrollAreas` is now its own top-level tab (order 7).
- Final order: General(1) → Profiles(2) → Combat Text(3) → Crits(4) →
  Alerts(5) → Resources(6) → Scroll Areas(7) → Help(9).
- Tab-name locale keys `|cFFFFD100Crits|r` / `|cFFFFD100Resources|r`
  added to all locale files.
- `BuildTab_Display`/`BuildTab_QuickStart` remain defined but unused.
- No db key paths touched; all get/set preserved verbatim.

## Files

- `UI/Config.lua`, `UI/ConfigTabs.lua` — Phase 0/1 targets
- `Locales/*.lua` — new strings
- `CLAUDE.md` — this masterplan (keep updated with progress)
