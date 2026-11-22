# Project: Zore's Scrolling Battle Text (ZSBT) - Retail
You are an expert World of Warcraft addon developer specializing in the modern Retail Lua API.

## Core Directives
- **Zero Legacy Globals**: Strictly use the modern `C_` namespaces (e.g., `C_Timer`, `C_ChatInfo`, `C_CombatLog`).
- **Garbage Collection (GC) Mitigation**: Prioritize table recycling pools (`Wipe` / object pooling) for high-frequency events (`COMBAT_LOG_EVENT_UNFILTERED`).
- **Secure Frames**: Ensure all UI frame rendering adheres to modern anchoring and secure frame templates. Do not trigger interface taints during combat lockdown.

## Combat core restructure (verified in-game; transplant framing superseded — the pipeline was rebuilt inside ZSBT directly, ZCT was not kept as a separate transplant)

The combat attribution/display-detection core was rebuilt inside ZSBT on a ZCT-inspired, correctness-first model. There is no separate `ZCT/` tree or `ZSBT.ZCT` namespace — the pipeline lives in the `Parser/` and `Core/` files below.

Pipeline: `Parser/Event_Collector.lua` (whitelisted events — `UNIT_COMBAT`, `UNIT_SPELLCAST_SUCCEEDED`, `UNIT_HEALTH`, `COMBAT_TEXT_UPDATE`, `PLAYER_SWING` where supported, `CHAT_MSG_*` self-damage) → pairing/attribution (pending-cast records, `_castToken` merge bucket, pet claims, DoT/HoT records) → `emit()` → **`Parser/ZBattleText.lua` ownership veto** → `PulseEngine` sink queue → `Parser.Outgoing`/`Incoming` → `Core/Outgoing_Probe.lua`/`Incoming_Probe.lua` → ZSBT display.

`ZBattleText` is the line-pairing core: it installs a source-restricted (MINE + MY_PET) combat-log filter named `"ZSBT"` (written at `PLAYER_LOGOUT`, verified at `PLAYER_ENTERING_WORLD`), classifies `COMBAT_LOG_MESSAGE` lines by RGB palette into damage kinds (melee/ranged/direct/tick/shield) plus a separate heal/hot ring, and `OfferOutgoing` requires each ambiguous wound to claim a buffered line. Candidates are tiered — tier 1 (spellId/petSpellId/`_swingProven`) claims before unattributed generics; `candidateKinds`/`kindPreference` keep non-auto wounds from taking melee lines. On Forever (`ClassDB.IsForever`), proven candidates emit line-free after one retry (`kind=noline`) because the feed is structurally incomplete; generics stay line-gated. A `heal`/`hot` line is ownership proof for outgoing heals — `matchOutgoingHotTick` + `queuePendingHotHeal` pair them either-order with the UC event.

Secret amounts ride `EventCollector._rawPipe` (`rawPipeId`) untouched; `ZSBT.RoundDisplayValue`/`ResolveDisplayAmount`/`FormatDisplayAmount` in `Core/Constants.lua` are the only display-safe paths — never arithmetic, compare, or tostring a possibly-secret value.

Strictness is context-tiered (`Core:OutgoingStrictnessTier` + `IsAutoRestrictActive`), relaxed by profile toggles `requireProof`, `showUnprovenInGroups`, `pvpRelaxed`; the old Dungeon/Raid/PvP/Open-World tuning UI was removed (saved keys dormant).

Verified in-game on Retail and Forever (era) solo combat via `/zsbt arep` + `/zsbt auditreport`. Remaining untested surface: instanced group content (raid) — contention/strictness paths only exercise there.

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

---
# Masterplan: Outgoing strictness — context-tiered ownership

Status: **AGREED 2026-11-20, not started.** Replaces the four legacy
context toggles that pre-date the combat-log veto.

## Why

Four UI toggles (`instanceAwareOutgoing`, `strictOutgoingCombatLogOnly`,
`pvpStrictEnabled`, `quietOutgoingWhenIdle`) collapse into the same two
runtime flags (`restrict` + `instanceAware`, Event_Collector ~L3165)
differing only in activation context. They were built before the
ZBattleText line-veto existed: restrict was the only anti-bleed defense.
Now pairing proves ownership whenever the feed is live, so the toggles
mostly duplicate each other — and they fail *closed* (silence own
damage) exactly in the veto-dead windows they were meant to handle.

## Key facts that shape the design

- `UNIT_COMBAT(target)` carries no source attribution — own hits and a
  party member's hits on the same target are indistinguishable without
  either a palette line (veto) or activity correlation (restrict).
- The user's "someone else's damage on my target while I idle" case is
  covered automatically by the veto whenever the feed is live; it only
  fails open when the feed is dead (uninstalled, untrusted, or
  sustained-rejection failsafe).
- Feed-dead is a rare degraded mode on both clients; the toggle stack
  becomes degraded-mode policy, not everyday behavior.
- Forever's feed is incomplete for some spells (Judgement etc.) — the
  era `noline` rescue covers sid-bearing hits only; unattributed
  generics on Forever still depend on lines, same as Retail.

## Target model — strictness is contextual, not manual

| Context | Veto live | Veto dead |
|---|---|---|
| Solo / solo instance | line pairing | permissive heuristics (no bleed source exists) |
| Group / instance / follower | line pairing | restrict auto-engages (cast/swing/DoT correlation) |
| PvP / arena | line pairing | restrict auto-engages + auto-attack fallback off |

Context detection is all existing code: `IsInInstance`,
`GetNumGroupMembers`, `IsInPvPInstanceType`, `Core._inGroupInstance`.

## Surviving toggles (3)

1. **"Require combat-log proof for outgoing"** (`requireProof`,
   default off) — suppress tier-2 even while veto live; the paranoid
   mode. Absorbs `strictOutgoingCombatLogOnly` +
   `classModule.hideUnattributed`.
2. **"Show unproven outgoing in groups"** (`showUnprovenInGroups`,
   default off) — relaxes veto-dead group restrict. Absorbs
   `autoAttackRestrictFallback`; unlike the old key it actually reaches
   the drop sites it promises to affect.
3. **"Relaxed outgoing in PvP"** (`pvpRelaxed`, default off) — opt-out
   of auto-strict in pvp/arena. Inverts `pvpStrictEnabled` (auto-strict
   is now the default until proven unnecessary).

## Retired keys (kept dormant in saved data; no UI, no consumers)

`quietOutgoingWhenIdle`, `quietOutgoingAutoAttacks`,
`strictOutgoingCombatLogOnly`, `strictOutgoingAlways`,
`instanceAwareOutgoing`, `autoAttackRestrictFallback`,
`pvpStrictDisableAutoAttackFallback`, `autoRelaxOutgoingWhenSolo`
(absorbed by the solo tier).

## Migration (one-time, additive)

- `strictOutgoingCombatLogOnly == true` → `requireProof = true`
- `classModule.hideUnattributed == true` → `requireProof = true`
- `autoAttackRestrictFallback == true` → `showUnprovenInGroups = true`
- `pvpStrictEnabled == false` → `pvpRelaxed = true`
- quiet keys: no migration (the behavior is now automatic).

## Implementation phases

- **P0** — `Core:OutgoingStrictnessTier()` returns
  `live|dead_solo|dead_group|dead_pvp` using existing context helpers.
- **P1** — collapse the ~L3165 restrict lattice onto the tier function;
  `quietMode`/`instanceAware` local refs go away; restrict gates read
  tier directly. Behavior identical for every current toggle combo.
- **P2** — new profile keys + ConfigTabs replacement section (one
  "Outgoing ownership" group, 3 toggles) + QuickControlBar dropdown
  cleanup; localization keys.
- **P3** — one-time migration + dormant key sweep.
- **P4** — audit-tag emits with the active tier (`AUDT live|dgroup`)
  so post-change logs prove which policy ran.

## Verification

- Veto-live grouped fight: foreign wounds still AUDROP via line
  pairing; own hits unaffected — restrict must not engage while live.
- Simulated feed-dead (`ZB._trusted=false` via test hook): solo shows
  all; grouped drops unattributed; pvp additionally drops the auto
  fallback.
- Forever: `kind=noline` rescue unaffected; Touch of the Grave and
  Judgement-of-Righteousness behavior unchanged.
- Byte-identical mirror to `_forever_` after every phase.

# Masterplan: World of Warcraft: Forever class modules

Status: **client gate + Era Warlock module live; module-less fallback works.**
`ClassDB.IsForever()` (project-18 check) and the client-scoped `ClassDB.Register`
gate are live — modules declare `mod.client = "era"` to load only on Forever;
everything else defaults to Retail and stays dormant there. `Classes/Era/` files
need TOC entries when created. Classes with no module still display all damage/
heals — modules upgrade naming/attribution only (see "Verified live" below).

## Client facts (researched 2026-11, verify against live build)

- **"Forever" is NOT Classic Era.** Internal codename **Camelot**; it is
  a second game type inside the Mainline family shipping the modern
  client (`_forever_` folder, same engine as `_retail_`).
- `WOW_PROJECT_ID == WOW_PROJECT_CAMELOT` (**18**). The constant is nil
  on other clients — detect via
  `local isForever = WOW_PROJECT_ID == (WOW_PROJECT_CAMELOT or 18)`.
  **Verified live 2026-11-19:** the current build returns 18 — the
  client gate (`ClassDB.IsForever` in `Classes/Registry.lua`) correctly
  suppressed the Retail warlock module on Forever ("no class module
  loaded" on the Class page). Early beta builds returned 1 (Mainline),
  so never branch on `== WOW_PROJECT_CLASSIC` (that is Era, project 2)
  or assume `== 1` means "modern".
- TOC interface **16001**; game type `forever` (alias `camelot`),
  family `mainline`. Lua 5.1 — no `//`, no bitwise ops outside `bit.*`,
  same restrictions as our Retail code.
- Blizzard states Forever shares Mainline's UI architecture "including
  the vast majority of APIs available in 12.1.5" **and Midnight's addon
  disarmament is active — secret values apply**. Treat it as the Retail
  combat surface: no `COMBAT_LOG_EVENT_UNFILTERED`, `UNIT_COMBAT`
  secrecy, palette lines — the entire ZCT pipeline ports unchanged.
- Prefer **capability probing over flavor checks** for API differences
  (`if C_DamageMeter`, `if issecretvalue`, etc.); reserve the project-id
  check for content/class differences only.

## Scope

The ZCT pipeline, bridge, collector, and module hook contract port
unchanged — the secret-value constraints are the same. Only class-module
*data* differs: Forever content is Classic+ (original-game classes and
mechanics), so spell ids, talents, and guardian semantics must be
re-derived from Forever logs, not copied from either Retail modules or
Classic-Era databases.

## Roster

Vanilla-style classes are expected (Warrior, Paladin, Hunter, Rogue,
Priest, Shaman, Mage, Warlock, Druid) but Forever is Classic+ — verify
the actual roster and any new/changed mechanics on the live client.
Registry must tolerate absent modules and never register a hook for a
class the client doesn't have.

## Module layout

- **Sibling files:** `Classes/Era/<Class>.lua` loaded only on Forever,
  selected in `Classes/Registry.lua` via the Camelot check above.
  Keeps Retail module files untouched; the Forever variants are
  different modules, not configs of the Retail ones.
- The `_forever_` install is a CurseForge-synced release copy, so Era
  modules ship in the same package and stay dormant on Retail. TOC
  needs the Forever interface/game-type markers when we ship for it.

## Mechanical notes (verify, don't assume)

### Verified live (combatlog-verified 2026-11-20)

- **Paladin — Judgement produces NO damage under its own sid.** Cast is
  always `20271 "Judgement"` (SPELL_CAST_SUCCESS); the damage sid depends
  on the *active seal* and judging consumes the seal:
  - Seal of Righteousness (`21084`) → `SPELL_DAMAGE 20187
    "Judgement of Righteousness"` school `0x2`. Also melee procs
    `SPELL_DAMAGE 25741 "Seal of Righteousness"` per swing.
  - Seal of the Crusader (`21082`) → **zero damage**. Only
    `SPELL_AURA_REFRESH 21183 "Judgement of the Crusader"` (debuff).
    Nothing should scroll — absence of text is correct.
  - Module implication: map cast `20271` → damage sid by active seal
    (Righteousness `20187`); a judgement with no damage event is
    legitimate, not a pipeline failure.
- **`UNIT_COMBAT` school field is unreliable** — reports `32` for hits
  whose combat-log school is `0x2` (holy). `castSchoolOk` is relaxed for
  player sids and `FOREIGN_SCHOOL` is era-exempt (commit `e63ef45`).
  Pet records keep strict school matching.
- **`UNIT_SPELLCAST_SUCCEEDED` fires per-unit unfiltered** — the
  player's own casts arrive on `player` AND duplicated on
  `targettarget` when the mob targets the player (targettarget =
  player). `UC_CAST unit=targettarget` lines are expected noise.
- **`PLAYER_SWING` exists and fires** on Forever (`AUDSWING`) — autos
  have real provenance; `SWING_DAMAGE` lines classify as `melee`.
- **Feed latency**: `SWING_DAMAGE`/chat lines lag wounds ~0.4s —
  `DEFER_SEC` (0.20s) first flush misses them; the `_retried` requeue
  pass is what claims them. Never remove the retry on this client.
- **Feed completeness**: `SPELL_DAMAGE` observed only for Holy Strike
  (`679`), Judgement of Righteousness (`20187`), Seal of Righteousness
  (`25741`), Touch of the Grave (`1260198`, school `0x20` — Forsaken
  racial, real shadow, purple tint is correct). Any spell the feed
  omits gets the era-gated `kind=noline` rescue in `flushPending`
  (tier-1 sid-bearing only; Retail keeps strict line requirement).
- **Module-less fallback works**: no module still displays casts
  (cast-record sids), autos (`_swingProven`), procs (line pairing),
  incoming/outgoing heals — modules upgrade naming/attribution, never
  gate visibility. Book-derived periodic entries drive dot
  disambiguation without a module (`ClassDB.DotCadenceDisambig`).

- **Warlock:** permanent named minions (Imp/Firebolt, Voidwalker,
  Succubus, Felhunter) — likely easier to attribute than Retail's
  temporary guardians; guardian-window machinery probably unnecessary.
  Era spell ids (e.g. classic Shadow Bolt families), not Retail's.
- **Hunter:** permanent pet; no Kill Command, no hero talents — the
  Dark Ranger spellbook/windows do not port. Auto-shot vs pet melee
  ambiguity still applies pending palette verification.
- **Shaman:** totem pulse damage is summoned-entity damage — totem
  windows are the Forever analogue of guardian windows.
- **Physical-dot classes** (Warrior Rend/Deep Wounds, Rogue poisons):
  same physical-ambiguity problem as Retail hunter melee.
- **Channels/DoTs:** Mage (Ignite, Blizzard, Arcane Missiles), Priest
  (SW:Pain, Holy Fire, Devouring Plague, Mind Flay/Sear), Druid
  (Moonfire, Insect Swarm, Hurricane), Paladin (Consecration ticks).

## Data verification method (unchanged)

All spell ids come from real Forever combat logs (`/combatlog` +
fights) — cast ids vs damage ids vs summon ids. Third-party databases
are secondary; log-verified only, same as the Retail Dire Beast
correction (guessed 120679, real 204432).

## Phases

- **P0** — Camelot detection helper (`ZSBT.IsForever` or similar) +
  registry flavor plumbing; register empty Era tables so the registry
  shape is identical on both clients.
- **P1** — Era module scaffolds for the verified roster with
  conservative name-keyed DoT tables (name keys survive rank/id
  variance).
- **P2** — deep modules by value: Warlock (permanent-pet spell naming),
  Hunter, then channels/DoTs; Shaman totem-window tracking.
- **P3** — verification ritual: `/combatlog` + real fights on Forever,
  same audit-vs-log diffing used on Retail.
