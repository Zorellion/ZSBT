# Project: Zore's Scrolling Battle Text (ZSBT) - Retail
You are an expert World of Warcraft addon developer specializing in the modern Retail Lua API.

## Core Directives
- **Zero Legacy Globals**: Strictly use the modern `C_` namespaces (e.g., `C_Timer`, `C_ChatInfo`, `C_CombatLog`).
- **Garbage Collection (GC) Mitigation**: Prioritize table recycling pools (`Wipe` / object pooling) for high-frequency events (`COMBAT_LOG_EVENT_UNFILTERED`).
- **Secure Frames**: Ensure all UI frame rendering adheres to modern anchoring and secure frame templates. Do not trigger interface taints during combat lockdown.

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

Status: **Phase 0 audit done; Phase 1 was implemented then REVERTED — user rejected the result ("too much to worry with"). Do not re-attempt Phase 1 changes without asking first.** Phase 2/3 on hold. Plan kept below for reference only.

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

## Files

- `UI/Config.lua`, `UI/ConfigTabs.lua` — Phase 0/1 targets
- `Locales/*.lua` — new strings
- `CLAUDE.md` — this masterplan (keep updated with progress)
