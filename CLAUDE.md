# Project: Zore's Scrolling Battle Text (ZSBT) - Retail
You are an expert World of Warcraft addon developer specializing in the modern Retail Lua API.

## Core Directives
- **Zero Legacy Globals**: Strictly use the modern `C_` namespaces (e.g., `C_Timer`, `C_ChatInfo`, `C_CombatLog`).
- **No third-party addon references**: Never name or cite other people's addons in code comments, docs, changelogs, UI strings, commit messages, or any other project text. Describe mechanics on their own terms ("the scored-race model", "trust/doubt corroboration") — never by provenance. (User directive, 2026-11.)
- **Garbage Collection (GC) Mitigation**: Prioritize table recycling pools (`Wipe` / object pooling) for high-frequency events (`COMBAT_LOG_EVENT_UNFILTERED`).
- **Secure Frames**: Ensure all UI frame rendering adheres to modern anchoring and secure frame templates. Do not trigger interface taints during combat lockdown.
- **Spellbook is the source of truth for spell DATA; research is required for MECHANICS**: `ZSBT.Spellbook`/`/zsbt sb` has live ids, names, school masks, tooltip durations/intervals — always prefer it over hardcoded values. But the book cannot express mechanics: buffs-with-duration parse as "dot" (it flagged Stormkeeper and Ascendance as dots — both wrong), and applicator chains (Voltaic Blaze/Ascendance *apply* Flame Shock), summons (Stormkeeper's elemental), and replace semantics are invisible to it. Verify those relationships against current sources (Wowhead/Icy Veins). Audit wounds are ground truth for what the client actually reports (e.g., composite school-12 ticks vs the tooltip's pure-nature school).

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

Status: **DONE — user confirmed working; the shell is now the ONLY config UI.**
`/zsbt` opens `ConfigShell` directly; `Addon:OpenConfig`/`OpenZCTUI` forward
to it (legacy-call-site safety); the `zctui` alias is removed; no Blizzard
options-panel registration exists. The classic AceConfig tree code remains
in the tree but is unreachable — do NOT re-add routes to it, and do not
edit the classic UI files (user standing order). User directive: rebuild
the config window to match standalone ZCT's *flow and structure* — left
sidebar page nav, one focused page at a time — while keeping ZSBT's
widgets, theme, and ZSBT-only features.

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
3. **Slash** — `/zsbt` → `ConfigShell:Toggle()`. The `zctui` alias and the
   old-UI route were removed at cutover (approved by user).
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
- **P3 — DONE** — cutover approved and shipped: `/zsbt` opens the shell;
  `zctui` alias removed; `OpenConfig`/`OpenZCTUI` forward to the shell;
  classic tree unreachable (kept in-tree for emergency revert only).
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

Status: **client gate + Era Warlock module live; cast→target binding, wand
family, drains/leech evidence, and name-keyed aura probing all shipped.**
`ClassDB.IsForever()` (project-18 check) and the client-scoped `ClassDB.Register`
gate are live — modules declare `mod.client = "era"` to load only on Forever;
everything else defaults to Retail and stays dormant there. `Classes/Era/` files
need TOC entries when created. Classes with no module still display all damage/
heals — modules upgrade naming/attribution only (see "Verified live" below).

### Attribution channels — verified on Camelot 1.60.1 (warlock sessions)

| Channel | Verdict |
|---|---|
| `UNIT_SPELLCAST_SENT` | **LIVE.** `(unit, target, castGUID, spellId)` — target arrives as a **readable name** (`tgt=Great Goretusk safe=true`); `castGUID` pairs SENT→SUCCEEDED. Feeds `_lastCastTargetName/Guid` → `seedDotApplication` anchors the real application mob. nil `target` happens (self/untargeted casts — `tgt=nil safe=false`, handled) |
| `COMBAT_LOG_MESSAGE` names | **DEAD**, 5 confirmations — `CLMSG_PROBE txt=\|Ky####\|k` (same KString render token as Retail). Names never readable; interval-family matching is the only split path |
| `C_UnitAuras.GetAuraDataBySpellName` | **Presence works, fields secret.** `present=1` once (nameplate2, at BoA application) — likely out-of-combat per Camelot secrecy rules. `a2.spellId` read is gated on `C_Secrets.ShouldAurasBeSecret() == false` (readable false only). In-combat calls may throw — the pcall absorbs it; presence edges (`AURA_SEED`) and `_nameDebuffAt` name sightings feed `debuffpass` for era entries |
| `UNIT_COMBAT` self-heals | **Amounts readable** (per community docs: UNIT_COMBAT amounts stay readable where UnitHealth is secret). `_playerHeals` ring feeds the leech check |
| `UNIT_AURA` (enemy) | Poll machinery live: `auraPollCandidates` = module dot `ids` + era dot `names[1]` (name-keyed) + `learnedProcDots` + gear dots. `AURA_PROBE` logs first-present-per-unit |
| `C_CombatText.GetCurrentEventInfo` | Live — already feeding `rawArg1-3`; `AUDCTI` probe logs heal-event args (no heal events observed yet — drains still untested) |
| Wand school | `readWandSchool()` (`C_TooltipInfo.GetInventoryItem("player",18)`) + `_wandVotes` learning; `_wandSchool` gates `pickWandShot` (off-school wounds never wear Shoot); `_swingAt.ranged` preferred anchor; `includeConsumed=true` on wand peeks |

**Era Warlock module** (`Classes/Era/Warlock.lua`): name-primary `mod.dots`
(names+school+interval, `drains` on Siphon Life), `mod.channels` (Drain
Life/Soul drains, Drain Mana, Rain of Fire, Hellfire), `mod.ranged`/`rangedIds`
for Shoot (auto-shoot sustained family — anchor stamped at cast and every
ranged emit), `mod.exclude` denylist, pet school gates, `mod.schoolsAny`.

**Leech/drains evidence:** a self-heal in `_playerHeals`
with `amount == wound.amount` within ±0.06s is proof-positive a drain fired
(`leech=true`) — drains candidates score -0.40, non-drains +1.0 (proven leech
veto). Weaker co-timed heal LINE (`PeekHealLine` or self-sourced CT_UPDATE
heal → `_drainHealAt`) is bonus-only — full-overheal suppression makes absence
untrustworthy. `AUDD heal=` logs `leech`/`ctheal`/kind.

**Picker model** (`pickDotByCadenceDisambig`): per-wound scored race — school
gate, per-target scoping (`_dotAppliedTarget[sid][mobName]`/`_dotAppliedGuid`),
`dotCadencePredict` phase-lock + learned periods, amount-fit vs learned/persisted
tick amounts, entry-level dedup (`_disambigEntIdx` — two sids on one entry can't
manufacture a false tie), `drains` leech bonus/penalty, wand veto (live wand +
ranged line + no tick line ⇒ not a dot), tick-line rescue at +0.4, direct-line
veto on weak picks. >1 survivor within 0.15 score ⇒ generic (never wrong).

**Forever combat-text reference model** — mechanics verified against the
client's live behavior: a scored-race attribution engine (trust/doubt
corroboration, tick-beat veto, per-hand swing-lag learning, wand-school votes,
seal/poison recency naming, player-heals leech evidence) fed by UNIT_COMBAT
records (leech amount-match, aura-secret gating, SENT→SUCCEEDED cast-target
pairing with `CAST_TARGET_KEEP` + `uncertain`).

**Ground truth: `/combatlog` disk log + `Tools/correlate.py`** — the file
logs carry real names/sids/schools even where the live feed is secret.
Run: `python Tools/correlate.py --log "_forever_/Logs/WoWCombatLog-*.txt"
--sv "_forever_/WTF/Account/ZARGON2006/SavedVariables/ZSBT.lua"`. It
auto-aligns GetTime→wallclock by same-sid emit matching — **never trust a
run whose `peak anchors` is small**; a multi-fight log holds rival offset
peaks (an earlier fight won once with peak=9 vs the true 28, manufacturing
phantom misattributions). Real verdict for the 896326-896344 window:
20 exact / 2 wrong_sid / 5 generic-own; every own spell 100% coverage
except pet melee (0/10 — pet swings never reach the pet stream).

**Verified from that window (warlock, Goretusk fight):**
- Wound `school` is ACCURATE on this class: shadow DoTs→32, Immolate→4,
  arcane wand→64, pet melee→1 — every wound synced its log line at −0.01s.
  The paladin `school=32` report above may be class-specific or an artifact.
- Shoot's *spell* school header is `0x1` (RANGE_DAMAGE field 10) while the
  real damage school lives in the advanced suffix (`-1,64,0,0,0` — wand
  was arcane). Wound school = damage school. `castSchoolOk` now gates wand
  sids on `_wandSchool` before the Forever player-sid exemption.
- Two real misattributions, both claim-ordering: (a) Shoot's pending cast
  stole a school-4 Immolate tick (the old blanket school exemption);
  (b) a Drain Life pending/recency claim at dt=0.70s stole Corruption's
  on-schedule tick — `channelTickFloorOk` now requires `dt >= interval*0.8`
  for channel sids in `consumeBestPendingCast` AND `miwClaim`.
- `AUDCAD` logs failed-cadence anchors (applied/next/last/period) so
  picker rejections are diagnosable from the ring alone.
- **Learner trust:** a claim must carry
  evidence independent of learned state before it may teach —
  `self._dotPickTeach` is set by `pickDotByCadenceDisambig` only for
  debuff-tiebreak / live-channel / tickline-rescued picks, and
  `noteDotTickAmount(..., canLearn)` returns early without it (callers
  pass `chanPick/debuffOk/cast-seeded` themselves). Sole-survivor and
  score-margin guesses emit but never write `rec.period`,
  `_dotTickAmounts`, `confirmedAt`/`nextAt`, or the persisted
  `learnedDotPeriods`/`learnedTickAmounts` — a wrong guess's learning
  defends itself (SV had `learnedDotPeriods[6222]=1.994` vs real 3.0 and
  `[707]=1.694`; both ratios fall outside `boundedDotPeriod`'s
  0.7-1.4x-declared band, so the bound rejects them at read AND write;
  untrusted sids with no declared interval stay unbounded — learning is
  all they have). Wand-element votes (`_wandVotes` -> `_wandSchool`) only
  count `payload.wandProven` claims (ranged-line family claims) — pending-
  cast wand claims can't vote because a consumed wrong-school wound would
  teach the wrong element during bootstrap. AUDD `teach=` field shows it.
- **Pet melee recall fix (0/14 -> rescue):** Forever's feed carries **no
  `cls=pet` lines at all** — the filter's MY_PET part is configured but
  pet-classed lines never arrive (only `cls=mine` appears; foreign
  `cls=neutral/friendly/hostileU` come from the mob's and co-attackers'
  traffic). A pet-routed wound could never satisfy the line requirement
  and died `src=pet` (retry exhausted) or `src=fline` (a mob hit on our
  pet paints a foreign line inside the old 0.35s window at mob-swing
  cadence). Fix (pet-out/pet-attacking model): pet-route wounds get
  the narrowed 0.12s same-frame foreign check, then a `petNolineProven`
  rescue emits after one retry — hard evidence (`petEvidence` cast/melee/
  mline) always; guess-evidence needs `UnitExists("pet")`, a readable-
  false `UnitIsUnit("pettarget","target")` vetoing, and no armed
  `_autoContestUntil`. `UnitIsUnit` is secret-gated in combat — read via
  double-pcall (`pcall(fn)` then `pcall(res == true)`), unreadable =
  unknown not false.
- **Companion bug — `_swingProven` stamp ignored pet route + VetoAuto:**
  `emit()` stamped `schoolMask==1, spellId==nil` payloads with
  `_swingProven` whenever `anySwingRecent` fired — and a `ranged` hand
  report covers ALL schools for 0.05-2.0s with no school check (must
  school-fit the learned wand school). A wand report promoted pet wounds
  to tier-1 where they died `fnear` (or could claim own lines as player
  damage). Stamp now skips `_petRoute` payloads and `VetoAuto()` classes;
  same guard added to the flush-time late-swing upgrade.
- **Wound `amount` is a SECRET value on Forever** (`amt=<secret>` in
  AUDTWIN — `IsSafeNumber` fails): amount-based discrimination can never
  arm here — BoA-vs-Corruption same-school same-grid collisions are
  irreducible, honest generics. Amount-mismatch veto and leech
  amount-match are no-ops on this client, not bugs.
- **Next-swing EMPTY REPORT (Camelot mechanic, verified):** the
  queued next-swing frame carries an Empty Report before the real Hit
  (prefer the queued strike's hit; `mod.nextSwing` sid table,
  `ClassDB.NextSwing`). The phantom rides the cast's own instant
  (`cast.at == first.at` — tape: wound ht == cast ht), which is the only
  legible marker: wound amounts are SECRET values (type() reports
  "number" but IsSafeNumber fails — `amount == 0` can never be
  evaluated). A phys wound claiming a pending nextSwing record at
  dt<0.30 = the phantom → dropped, record left unconsumed so the
  same-frame real hit (the sid=nil second wound) claims it — a
  record-bound wound is proven → emits `noline` on Forever, skipping
  the fline/fnear foreign vetoes that otherwise kill it. `onSwingBeat`
  wounds exempt. `consumeBestPendingCast` also stretches a nextSwing
  record's cap to 3.2s (pool expiry 3.25 bounds it) for late swings.
- **`castSchoolOk` phys boundary (post-rescue misattribution):** the
  Forever exemption still crosses phys/magic — a school-1 wound claimed
  Corruption's pending record (s1 wound named sid=6222). Exemption now
  keeps the phys veto: declared/learned non-phys school + s1 wound =
  reject; the paladin anomaly was magic-vs-magic so this direction is
  safe. **Melee-avoid misses:** PARRY/DODGE/BLOCK only come from melee —
  `VetoAuto()` classes skip the `_lastPlayerSpellId` bind entirely
  (Tangkresh's parried swing wore `bind=cast:980`).

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

---

# Class module authoring guide (`Classes/<Class>.lua`)

Distilled from the warrior debugging cycle (Nov 2026). Every rule below
exists because violating it produced a real, log-verified bug.

## Module lifecycle

1. File declares `local mod = {}`, fills data + hooks, ends with
   `ZSBT.ClassDB.Register("TAG", mod)`.
2. `Register` is client-scoped: `mod.client = "era"` → dormant on
   Retail; anything else → dormant on Forever.
3. `ClassDB.ActiveModule()` resolves via `UnitClass("player")`, cached.
4. Every `mod.<fn>` hook is invoked through a `safeHook` pcall in
   `Classes/Registry.lua` — a throwing hook logs `HOOKERR fn=<name>`
   (throttled 5s, `ucdropLog` ring) and is treated as absent.
   **Hooks must never kill the caller; never rely on the caller's
   behavior after your error.**

## The `self` argument is the EventCollector, NOT the module

`mod.onCast(self, ...)`, `mod.onPhysicalWound(self, ctx)` etc. receive
the collector instance as `self`. Module state (`self._dwTick`,
`self._rendLastCastAt`, `self._dwAppAt`) is stored ON THE COLLECTOR —
shared with EC's own `_last*` fields. Name module state with a distinct
prefix to avoid collisions.

## Declared data tables

| Table | Shape | Consumed by |
|---|---|---|
| `mod.dots` | `{names={...}, ids={...}, school=N}` | `DotEntry` resolves by NAME first (localized spell name → entry), then id. `ids` should include the TICK sid, not just the cast sid (Rend: cast 772, tick 388539). |
| `mod.hots` | same shape | `HotEntry` — module-only, no spellbook fallback |
| `mod.channels` | `{names, ids, duration, tickMin, school}` | `ChannelMatch` — `ids` must be the CAST sid(s); talent-swapped variants change the cast id (Bladestorm 227847 → 446035 under Unrelenting Onslaught) |
| `mod.castBudget` | `{[sid]=N}` | How many wounds one cast may name; missing = 1. AoE needs N ≥ max targets or hits go anonymous |
| `mod.schools` | `{[mask]=true}` | `SchoolAllowed` — foreign wounds on impossible schools get vetoed |
| `mod.dotApplicators` | `{[castSid]={dotSid,...}}` | AoE applicator casts (Primal Wrath→Rip) |
| `mod.toggles` | `{key=true}` | UI visibility only |

## Hook contract

- `mod.onCast(self, spellId, spellName, t)` — every player cast. Track
  applicator-cast state here; do NOT read `self._lastPlayerSpellId`
  inside wound handlers — periodic-trigger casts (Bladestorm ticks
  arrive as cast events with the tick sid) overwrite it between your
  cast and its wound.
- `mod.onPhysicalWound(self, ctx)` — every school-1 WOUND on the target
  unit. ctx fields: `t, amount, isCrit, actionStr, school, emit,
  safeUnitName, hasTargetDebuff, autoAttackActive, swingPredicted,
  dbgSafe, ecPrint, restrict, members, dl`.
- `mod.onMatchedPhysical(self, spellId, t, amount)` — wound already
  paired to a cast.
- `mod.onGuardianWound(self, ctx)` — guardian-style pet wounds (no pet).
- Pet hooks: `petSchoolHit`, `petSchoolAllowed`, `petSchoolHitRecent`,
  `petPhysicalHit`, `resolvePetSpellId`, `resolvePetMelee`,
  `swingEvidence`, `autoLineKinds`, `vetoAuto` — receive `ClassDB.Helpers()`.
- `mod.dotGuard(entry, school)` — return false to veto a dot attribution.

## Secret-value rules (the #1 bug family)

Every rendered amount on the current client is a **secret value**
(`sv=true`). Consequences:

- `ZSBT.IsSafeNumber(amount)` is FALSE for real wounds. Any gate like
  `if IsSafeNumber(amount) and amount <= N then ... end` is DEAD CODE —
  it returns false on every wound (killed the DK ghoul gate and both
  warrior classifiers before rewrite).
- Never compare, threshold, or crit-adjust amounts. Classifiers must be
  **timing-only**: applicator seed + cadence beats + streak evidence.
- `amountText = (IsSafeNumber(amount) and tostring(amount)) or nil` is
  the correct safe-write pattern for emitted payloads.
- `hasTargetDebuff` usually returns nothing readable either — treat it
  as an evidence UPGRADE, never a hard gate (same degrade as DW/Rend).

## Classifier architecture (proven: DW + Rend)

```
seed (mod.onCast stamps applicator time on self)
  → beat grid: nextAt = lastAt + interval (rolling; interval learned
    from observed dt, nominal from log-verified ticks)
  → wound within ±SLACK of nextAt = on-beat
  → first on-beat wound = observation only (no emit)
  → second consecutive = claim → emit named tick
  → debuffOk == true upgrades first beat to a claim
  → ctx.swingPredicted(t) vetoes melee-shaped wounds BEFORE everything
```

- Audit every stage to `ucdropLog` via a FileLog-backed helper
  (`ravAudit` pattern): `seed`, `observe`, `claim` with dt — without
  these you cannot tell "never fires" from "fires and fails".
- Order matters in the wrapper: strongest-evidence classifier first
  (Ravager window → Rend → DW last; shared `_lastDotEmitAt` dedup).

## Lua scoping rules (bit twice)

- A `local function`/`local table` is only visible AFTER its
  declaration. Module hooks defined early in the file that reference
  later locals resolve to **globals → nil → runtime error**. Declare
  constants and helpers above their first caller, or forward-declare.
  (Killed onCast 48×: `DW_APPLICATOR_SIDS` used before declared.)
- `local function ravAudit` moved before its first caller for the same
  reason.

## Spell id discipline

- Never guess ids. Sources, in order of trust: the addon's own
  combat log (`/combatlog` + correlate.py) > `/zsbt sb` spellbook dump
  (real per-build ids + talent pairing like `227847 -> 446035`) >
  wowhead/simc. Comment every id with its source and date.
- Same spell, different sids: cast id vs damage/tick id vs talent-swap
  id vs empowered variant (Execute 5308 Fury vs 281000 Arms). Record
  ALL of them where they matter.
- `DotEntry` name-resolution is the safety net — keep `names`
  localized-accurate.

## Verification ritual (per module/classifier)

1. `luaparser` the file.
2. Mirror to `_forever_` if shared.
3. In-game: `/reload`, real combat (dummy for ticks, dungeon for
   contention), logout.
4. Correlate: `python Tools/correlate.py` — newest session cluster.
5. Check `seed`/`observe`/`claim`/`HOOKERR` records AND named-sid shows.
   Named shows via generic paths prove data tables work; only
   `claim` records prove the classifier runs.

# Ring record & state glossary (diagnostic vocabulary)

Records live in `prof.ucdropLog` (SV) via `ZB:FileLog` — gated on
`ZSBT._ucDropTrace` (persisted). `ZB:Audit` → `prof.auditLog` is the OTHER
sink (`/zsbt audit` toggle, usually OFF — absence of AUD* records proves
nothing). `ucdropLog` is a bounded ring; correlate sessions by timestamp.

## Pipeline stages (a wound's journey)

1. `UNIT_COMBAT` fires → `UC_RAW` (intake, per unit token). One hit can
   re-report on `target` + `nameplateN` + `softenemy` — the twin dedup
   collapses same-frame re-reports (20ms, same school+crit, different
   reporting token).
2. EC eval (`unit=="target"` path) → `CAND` logged → claim attempts:
   `pickDotForWound`/physDotCand (dot eval FIRST — grid+line is stronger
   evidence than cast proximity) → `consumeBestPendingCast` (pin → pool
   fallback) → recency/miw → contested/inst gates → auto fallback →
   restrict drops.
3. Off-target nameplates → OFFT block (below).
4. `emit()` → `ZBattleText.OfferOutgoing`: tier-1 (sid-bearing) needs a
   buffered palette line near tHit (`ALLOW_FAST` = line already buffered);
   unattributed generics queue as `CAND` in ZBT's `_pending` for the
   deferred flush → `ALLOW` (shown, `via=def` = generic) or `DROP`.
5. `SHOW` = emitted to display. `ht=` = hit time, `dly=` = queue delay.

## Record tags

| Tag | Meaning |
|---|---|
| `UC_RAW unit=X action=WOUND amtNil= amtT= school=` | wound intake per unit token |
| `UC_UNIT unit=X hostile= istarget= name=` | unit resolution (friend/hostile/target) |
| `UC_CAST unit=X sid=` | SPELLCAST_SUCCEEDED on non-player/target/pet token (throttled 0.5s/unit) — player casts don't log here |
| `CAND school= crit=` | EC intake survived dedup, entering eval (target path) |
| `UC_DROP reason=R` | EC gave up naming/dropped — see reasons below |
| `OFFT unit=X sid=S school=` | off-target nameplate wound assigned cast sid |
| `ALLOW kind=direct sid=` / `ALLOW_FAST kind=K sid=` | ZBT approved show; FAST = line pre-buffered |
| `SHOW TYPE sid= ht= dly= via=` | displayed event; `via=def` = generic/deferred path |
| `FLUSH sid= school= cnt= crit=` | ZBT deferred batch resolved |
| `LINv2 cls=mine/pet/hostileU heal= rgb=` | palette line classified (mine = our source) |
| `FLIN cls=` | foreign line (veto evidence) |
| `MISS_EMIT type=` / `SHOW COMBAT_TEXT_MISS` | miss/dodge/parry displays |
| `INC_EMIT` / `INC_DROP reason=HEAL_DEDUP` | incoming path |
| `CT_HEAL sid= per=` / `HEAL_TGT sid= restrict=` | heal naming path |
| `RND src=` | round/format sampling (noise) |
| `HB` / `REQUEUE n=` | heartbeat / deferred requeue |
| `PET_CAST unit=X sid=` / `FRIEND_CAST` / `PET_CAST_REJECT` | non-player cast pool records |
| `PET_ROUTE_DIRECT` | MINE line disproved a pet guess → relabeled own |
| `SHOW SPELLCAST_SUCCEEDED sid=` | player-branch cast (proves enqueue ran) |
| `PHYS_MISS want= school= pool=sid@dt,... [swing=1]` | restrict-phys pending claim failed; pool = queued casts+ages at eval (EMPTY = enqueue refused); `swing=1` = intentionally skipped (predicted white hit) |
| `PEND_REF sid= why=helpful/nodmg` | cast refused entry into `_pendingCasts` |
| `HOOKERR fn=` | module hook threw (safeHook swallowed it) |
| `DW seed/observe/claim/hook`, `REND seed/observe/claim` | warrior classifier records |
| `AUD*` (`AUDPASS`, `AUDROP`, `AUDCLAIM`, `AUDD`, `AUDT`, ...) | audit-sink records — need `/zsbt audit` ON |

## UC_DROP reasons

| Reason | Meaning |
|---|---|
| `BYPASS_RESTRICT_PHYS` | phys wound, restrict on, no cast claim → passed unnamed (veto live) |
| `RESTRICT_PHYS` | same but veto dead → hard drop |
| `BYPASS_RESTRICT_AGE` / `RESTRICT_AGE` | non-phys wound, miw recency failed (age>window or school-mismatch vs last cast) |
| `BYPASS_RESTRICT_NOCAST` | no recent cast at all |
| `CONTESTED` / `CONTESTED_OFFT` | co-attacker detector: unattributed phys dropped |
| `INST_GATE` | in-instance+group: no cast within 0.9s and no recent dot → wound skipped |
| `INST_UNATTR` / `BYPASS_INST_UNATTR` | in-instance unattributed phys |
| `WHT_DEDUP` | twin wound re-report dedup |
| `OFFT_NOCOMBAT` | off-target wound while player not recently active |
| `BYPASS_OFFT_INST` | off-target unattributed in instance (still emits generic) |
| `PHYS_PET` / `BYPASS_PHYS_PET` | phys wound with pet out |
| `GROUP_GATE` / `BYPASS_GROUP_GATE` | timestamp-only claim refused in group |
| `SUPPRESS_UNATTR` | non-phys unattributed suppressed |
| `ZERO_DROP` | proven-zero amount filtered |

## Core state (collector `self`)

- `_pendingCasts` — FIFO of `{token,spellId,spellName,at,helpful,harmful,eligibleIcon}`; enqueued only on `unit=="player"` casts; refused if `IsHelpfulSpell` or `SpellFacts.damages==false` (logs `PEND_REF`); expire at 3.25s. `consumeBestPendingCast` needs `c.spellId==wantSpellId` (when pinned), `castSchoolOk`, `dt<=window`. **Single-consume**: a claim removes the record — cleave hits #2..N must use the `_castClaims` budget paths.
- `_lastPlayerSpellId/At/Name` — LAST player-branch cast (any kind). Used by heal naming + miw tail.
- `_lastPlayerDamageCastId/At` — last cast that actually ENQUEUED (damage casts only). Wound-path pins use this: refused casts (DRW, Gorefiend's) used to move the raw pin, stranding the real damage cast's pool record ("stale pin" bug).
- **Pin → pool fallback**: in restrict, `wantSpellId` is a *preference* not a requirement — on pin miss the wound retries `wantSpellId=nil` (any school-fitting pool cast). Needed because the newest cast can be a different school than the wound (cross-school pin staleness — phys wound pinned to a shadow cast could never match). Foreign ownership is still proven downstream by palette lines, so relaxing the pin weakens only sid-selection, not theft protection.
- `_castClaims["sid@castAt"]` — per-cast claim count; budget via `ClassDB.CastBudget` (default 1). `miwClaim` consumes the pending record AND burns budget — used by non-phys miw, heal (target HEAL), miss paths, phys recency, and OFFT proven-cast fan-out.
- Swing predictor: `_swingAt[hand]`, `_swingSpeed[hand]`, `_swingLags`, `swingExplainsHit`, `swingPredictedNear(self,t,slackMul)` — PLAYER_SWING reports only own swings. `slackMul` scales the beat window: claim gates use 0.35 (~±0.12s — precision, since a false "swing" eats a real hit's name); classifier vetoes use default (~±0.35s — recall-friendly).
- `onSwingBeat` — `swingPredictedNear(t,0.35)` at the phys wound: **unconditional exclusion** from cast claims (pending/pool/Whirlwind-shortcut/recency). A swing can never wear a cast's name or burn its budget; `autoAttackMode` is display-only policy. OFFT is NOT gated (swings only hit the target — a nameplate wound can't be a swing); physDotCand stays open (a real tick may coincide with a beat).
- `_castToken` — increments per player cast; merge/dedup bucket key.
- `_recentPeriodicSpellAt[sid]` — last tick emit per dot sid (liveness).
- `_dotAppliedTarget`/`_dotAppliedGuid`/`_dotAppliedAoe` — dot application anchors (per-name / per-GUID / multi-mob). Written by `seedDotApplication`/`seedDotApplicationOnUnit` on dot casts, by `mod.dotApplicators[cast]={sid,aoe=bool}` entries, and by `handleUnitAura`'s presence-poll edge when a declared/learned own debuff appears on target/nameplate (proc dots — trinkets/enchants with no cast) (Primal Wrath→Rip pattern; DK: Blood Boil→Blood Plague AoE spread, Death's Caress→BP target). `aoe=true` = cast puts the dot on EVERY enemy in range → off-target nameplate ticks phase-lock via `resolveOffTargetDot`/`dotCadencePredict`.
- `prof.learnedProcDots[sid] = {name,school,interval,src}` — persisted proc-dot library, consumed by `ClassDB.DotEntry`'s learned fallback. Writers: gear scan (below) or future combat-viable feeds. NOTE: aura `updateInfo` is fully secret in combat on 12.x (isFullUpdate/addedAuras spellId/name all secret) — `handleUnitAura` therefore presence-POLLS known sids (`AuraUtil.FindAuraBySpellId` + `HARMFUL|PLAYER` — engine-side sid compare + own-source proof) and seeds on the absence→presence edge. Unknown sid discovery is impossible via auras in combat; a tick-line name feed is the future channel.
- `prof.gearLibrary[itemID] = {sid,spellName}` — persisted item→effect-sid map from `Spellbook:Scan`'s gear pass (`C_Item.GetItemSpell` over slots 1-17; `PLAYER_EQUIPMENT_CHANGED` invalidates `_scanned`). Gear entries get `gear=true` + full ParseDesc fields → `DotEntry` spellbook fallback claims their periodic wounds with no module table.
- Spellbook school-mask vetoes (ParseDesc): "damage taken" (defensive text), **article-follow** ("Fire a shot" — Barbed Shot parsed sch=4 from its own verb, rejecting real school-1 wounds via `DeclaredSchoolFits`), **possessive** ("Nature's Ally" → nature mask). `DeclaredSchoolFits` fallback order: dot decl → channel decl → `mod.spellFacts` → spellbook masks. `mod.spellFacts` covers sids the book can't see (replaced/hidden spells — Wailing Arrow 392060/392058 replaces Bestial Wrath under Wailing Dead, "Not In Spellbook Until Learned"; Bleak Arrows' firing sid 467718 vs talent sid 467749).
- `_lastTargetWoundAt` — last WOUND on `target`; OFFT needs it stale >1.5s OR a found sid.
- `_rawPipe[n]` — secret amounts by rawPipeId; never read directly.
- `restrict` = autoRestrict ∨ legacyStrict ∨ (in-instance ∧ members>1); `zbtVetoActive()` = trusted palette feed live (bypass = emit unnamed instead of drop).
- Swing predictor: `_swingAt[hand]`, `_swingSpeed[hand]`, `_swingLags`, `swingExplainsHit`, `swingPredictedNear` — PLAYER_SWING reports only own swings (pet/follower swings never produce one).

## Naming mechanisms (who can name a wound)

| Path | Window | Needs |
|---|---|---|
| **dot eval (phys + non-phys)** — runs FIRST | tick grid | grid membership + corroboration: phys needs MINE `tick` line + cadence; non-phys needs DotGuard/school/debuff + cadence. "Match me to ONLY this": a corroborated tick claims its dot before any cast sees the wound — ticks can't steal cast icons (was the biggest wrong_sid source) |
| pending-cast claim (phys) | 0.55s restrict / 0.85 open | damage-pin (then pool fallback) + castSchoolOk + not onSwingBeat |
| pending-cast claim (non-phys) | 0.55s restrict / 0.85 open | same |
| nuke guard (non-phys dot eval) | — | `dotBlockedByRecentCast` requires a **direct-kind palette line** within 0.30s + non-dot cast ≤1.5s — evidence-based; cast recency alone blocked every pick (was time-based, ~always true in combat) |
| rival-cast veto (non-phys dot eval, retail) | cast ≤0.55/0.85, or `_wandAt` ≤3.5 + ranged line ≤0.35 | a fresh pending record for a **different** same-school sid — or a `ranged` line while a ranged family is live — outranks the DoT anchor unless the wound holds a `tick`-kind line (`AUDD reason=DOT_RIVAL_VETO`). Retail Bleak Arrows (467718 — Dark Ranger auto-shot replacement, RANGE_DAMAGE every ~2.4s) was absorbed by the Black Arrow dot anchor (s32, debuff always up, cadence window contains the shot cadence); the family/ranged-line prong catches flight-time wounds past the record window. Era excluded — Forever's feed emits no `tick` lines (proof can't fire) and its disambig picker owns typed-line evidence |
| sustained ranged family (`mod.ranged`/`mod.rangedIds`) | swing ≤2.0s / family ≤3.0s | `pickWandShot`: school≠1 + `_wandSid` stamped by ranged-declared cast/emit + `PreferRangedLine` + ranged line ≤0.35s (consumed incl.) — Hunter declares Bleak Arrows 467718 + Wailing Arrow 392060; era warlock Shoot 5019 |
| ranged-family flight gate | `consumeBestPendingCast` | `PreferRangedLine` records only claim wounds at shot-flight age (`wandFlightWindow`: learned `_wandFlight` EMA −0.35/+0.45, default 0.05–1.20, cap=fhi not castWindow) — record-age is the shot-vs-tick discriminator on feeds with no tick/ranged line kinds (retail hunter: direct+melee only). Veto consumes the in-window record directly so fall-through can't steal it |
| per-sid flight gate | `consumeBestPendingCast` → `_flightBySid[sid]={ema,n}` | every damage-cast record learns its cast→hit delay on consume (EMA α=0.3, clamp 0.05–2.0); gate arms at n≥3 (poisoned bootstrap would lock real hits out): window = ema−0.35/+0.45, cap = max(window, ema+0.45). Measured from log: Cobra 0.80s, Wailing Arrow 0.91s, Black Arrow 0.43s, Bleak ~0.63s. Kills freshest-record-wins theft (a Barbed hit at +0.24s can't wear the Cobra record) |
| instant-claim floor | `consumeBestPendingCast` → unlearned branch | retail-only: unlearned sids refuse wounds at dt<0.15 — a wound at cast-time is a coincident steal, not this spell's hit (KC record eaten at dt=0 left its real +0.4s pet strike vs pool=EMPTY; gate seen rejecting once learned). Era exempt — era instants (Fire Blast) genuinely hit same-frame |
| pet-route evidence gate | `takeCandidateLine` `_petRoute` race | hard-evidence routes (`pev=cast/melee/resolve/mline`) claim `melee` (cls=pet) lines only — a coincident `direct` mine line is never theirs (observed: 16 `PET_ROUTE_DIRECT` strips/session eating real pet hits' names AND player lines). Guess routes keep the nearest-arbiter race |
| pet-evidence veto | phys path, before record claim | `cls=pet` line within 0.12s (`{melee=true}` — pet-exclusive kind on this feed) + pending pet cast record naming a DIFFERENT spell (`auraSpellName` both) → IS NOT the player record's hit (`pv=1` in PHYS_MISS); `pSid==nil` line-only proof vetoes on retail only. Gates record consume + whirlwind rescue + `miwClaim` recency. `mod.petExecuted` exempts sids whose real hits are pet-lined by design (KC 34026, Bloodshed 321538 — strike/autos indistinguishable; flight gate owns them) |
| excluded-cast anchor block | cast stamp `unit=="player"` | `ExcludedSpellId` casts never write `_lastPlayerSpellId/Name/At` or `_lastCastTarget*` — records still enqueue (expiry-bound) but a ~1s hidden applicator (retail DH Frailty 227255, SPELLCAST-fed, zero log rows) can't hold the recency anchor. `miwClaim` call sites also check excl directly — both layers needed since recency reads the stamp AND consumes budgets |
| ranged-family school gate | `castSchoolOk` PreferRangedLine branch | `_wandSchool` is authoritative once learned; **school-1 always rejected** (no ranged-family sid is ever phys — observed: Cobra/Barbed/melee wounds consuming Bleak records during bootstrap, emitting "Bleak Arrows" on phys hits); nil `_wandSchool` falls back to `_learnedSpellSchool` before permissive |
| phys recency claim | 0.75s post-cast | `miwClaim` on damage pin + school-fit + **prior claim ≥1** (cast must already have produced a hit — strays can't steal unproven names) + not onSwingBeat + not dot candidate |
| miw recency (non-phys) | 1.25s | lastId school-fit + budget |
| OFFT pool search | cast ≤0.5s | school-fit + `castCleavesOffTarget` (budget>1) + `PeekDamageLine(direct)` + shared budget |
| OFFT proven-cast fan-out | cast ≤0.75s | `_castClaims` entry with n≥1 + same gates — recovers cleave hits #2..N after the pool record is consumed |
| OFFT damage-pin fallback | cast ≤0.5s | `_lastPlayerDamageCast*` + school-fit + cleave-capable |
| OFFT dot claim | application anchor ≤30s | `resolveOffTargetDot`: app record (`_dotApplied*`) + school-fit + `dotCadencePredict` + **direct/melee/ranged/shield line veto** (no tick line → direct evidence kills it — a direct hit can never wear a dot name) |

## Learning-safety standard (anti-poison invariants)

Every learned value is a hypothesis a thief can teach. When adding any
learning mechanism or authoring a new module, hold ALL of these:

1. **Unlearned = permissive-with-floor, never restrictive.** A gate that
   starts strict starves real hits before it learns (and can't learn
   what it rejects). Bootstrap claims stay open except against the
   impossible (phys on a ranged-family sid, dt<0.15 on retail).
2. **Gates arm on count, not first-learn.** `_flightBySid` needs n≥3 —
   a poisoned first window would lock the real flight out permanently.
3. **Learn only from proven claims.** `_wandSchool` votes need
   `wandProven` (line-verified); a consumed wrong-school wound teaching
   the element would gate the family against itself.
4. **EMA bounded and clamped** — α≤0.3, value clamped to the plausible
   range (flight 0.05–2.0s) so single outliers can't dominate.
5. **Unreadable evidence → conservative.** `auraSpellName` nil → no
   veto. Never act on a check that failed to resolve; degrade to the
   pre-check behavior, not to restriction.
6. **Authored data outranks learned.** `DeclaredSchoolFits` order:
   decl → `mod.spellFacts` → spellbook masks → learned. Module tables
   are ground truth; learned values only fill gaps the author can't see.
7. **Feed-shape exemptions are mandatory.** Any rule consuming a line
   kind must check that kind exists on the client (era emits no `tick`
   lines — a veto whose proof can't fire *becomes* the bug).
8. **Register every learned store in `/zsbt clearlearned`** — persisted
   AND in-memory. If it isn't wiped, it respawns after fixes.
9. **"Log-verified" means verifying the event TYPE.** Frailty 227255
   was a ~1s `SPELL_HEAL` misread as damage — seeded a permanent anchor
   that claimed 24 wounds/session. Set Fire to the Pain 452406 was a
   self-stagger defensive, never an enemy dot. Verify sid + event type
   + school + TARGET of the aura, not just cadence.
10. **Evidence counters are observability, not authority.**
    `learnerEvidence` informs debugging; it never gates a claim on its
    own.
11. **New-module validation pass is required.** Before calling a
    module done: diff `/zsbt sb win` against Wowhead — every `dot`
    entry confirmed periodic-DAMAGE on an ENEMY (Frailty/Set-Fire
    classes above), every replaced/hidden sid pinned in `mod.spellFacts`
    (schools go blind in combat otherwise), `castBudget` checked against
    known AoE counts, `mod.exclude` covering zero-damage applicator
    casts, `mod.schools` covering every mask the spec emits (chaos
    reports as 124/127/36/106 on DH). Devourer lesson: `mod.spellFacts`
    for Meteor Shower/Catastrophe damage sids — triggered damage lands
    under sids the book never lists.
| channel claim | live channel record | `isLiveChannelPick` |
| swing/melee | predictor beats | swingExplainsHit |
| ZBT arbitration (flush) | line within VETO_WINDOW | palette line pairing (ownership, not name) |

Evidence hierarchy ("match me to ONLY this" — user-directed):
strong-specific beats weak-generic. Tick-grid + tick-line membership is
stronger than cast-window proximity, so dots eval first. Off-target
wounds can ONLY be multi-target casts (`castCleavesOffTarget` — a
budget-1 cast's sole hit arrives on `target`, never a nameplate).
Negation is mostly DERIVED, not hand-authored: `mod.dots` membership
already means "never a direct hit" → enforce line-kind vetoes in core
(only per-module `not=` data where dual-nature spells need it).

## Timing facts (measured 12.x retail)

- UC wound arrival vs combat-log damage event: ~0.2-0.9s lag.
- Combat log stamp `M/D/Y H:M:S.mmm-tz`; `ep_corr = naive_utc(stamp)+43200`; `GetTime ≈ ep_corr - 1794666676.856` (offset drifts per session — recompute via anchors).
- DS (Blood, Deadly Reach): 2-3 SPELL_DAMAGE per cast — castBudget 3.
- `correlate.py` next to devin.exe dir; `python -m luaparser` for compile checks (exe path → permission denied).
