# Project: Zore's Scrolling Battle Text (ZSBT) - Retail
You are an expert World of Warcraft addon developer specializing in the modern Retail Lua API.

## Core Directives
- **Zero Legacy Globals**: Strictly use the modern `C_` namespaces (e.g., `C_Timer`, `C_ChatInfo`, `C_CombatLog`).
- **Garbage Collection (GC) Mitigation**: Prioritize table recycling pools (`Wipe` / object pooling) for high-frequency events (`COMBAT_LOG_EVENT_UNFILTERED`).
- **Secure Frames**: Ensure all UI frame rendering adheres to modern anchoring and secure frame templates. Do not trigger interface taints during combat lockdown.

## Development & Release Workflow

- **Authoritative source**: All code work happens ONLY in this folder (`_retail_\Interface\AddOns\ZSBT`). Never edit `_classic_beta_`, `_forever_`, or `_ptr_` copies directly; they are synced from here only when the user explicitly asks (e.g. for testing on that client).
- **"increment version" / "bump to vX.Y"**: Update `ZSBT.toc` (`## Version`), `Core/Constants.lua` (`ZSBT.VERSION`), and `CHANGELOG.md` (new top section). Also update any in-game help text, docs, or troubleshooting references affected by the change. Do not touch other client folders.
- **"release version" / "release vX.Y"**: Verify version metadata is consistent, then sync this folder to `F:\REPOS\ZSBT` (preserve the repo's `.git` and `.github`; dev files `.devin`, `.pkgmeta`, `CLAUDE.md` stay in the repo but are excluded from packages via `.pkgmeta`). Then `git add -A`, commit (`Release vX.Y`), tag `vX.Y`, and push `main` + tag to `origin` (`https://github.com/Zorellion/ZSBT.git`). Git is at `C:\Program Files\Git\cmd\git.exe` and the repo needs `-c safe.directory=F:/REPOS/ZSBT` per command.
- **Tag format**: `vX.Y` (e.g., `v3.2`). Pushing the tag triggers `.github/workflows/release.yml`, which runs the BigWigs packager and attaches the zip to a GitHub Release; CurseForge pulls that release automatically.
- **`.pkgmeta`**: `package-as: ZSBT` is the archive folder name — never use it for versioning. Its `ignore:` list must keep excluding `.git`, `.github`, `.devin`, `.pkgmeta`, and `CLAUDE.md`.

---

# Masterplan: Periodic Damage Tracker extraction (`Parser/Periodic_Tracker.lua`)

Status: **planned — not started.** Current inline implementation works (verified on shaman/Flame Shock against a training dummy). Do not start until the current state has soaked for a few real sessions.

## Why

Periodic-hit attribution is currently duplicated across three divergent paths inside `Parser/Event_Collector.lua`:

- target path (~line 3430) — has all latest fixes (signal-live bypass, `applyAt` seeding, pending-cast peek, nameplate dedup)
- pet-fallback path (~line 2655) — older gates, missing the signal-live fixes
- combat-text path (~line 2495) — third variant

They have already drifted once; they will drift again. Consolidating is required for all-class correctness, and per-DoT state needs a real home to support multiple simultaneous DoTs.

## Hard limits (unchanged by refactor)

- `COMBAT_LOG_EVENT_UNFILTERED` is permanently off the table (protected → `ADDON_ACTION_FORBIDDEN`).
- No combat-log *text* parsing — `COMBAT_LOG_MESSAGE` RGB values only.
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
