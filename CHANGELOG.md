# Changelog

## 3.5.7

### Added
- **WoW Forever XP notifications:** the progress tracker now parses Forever's `"<creature> dies, you gain N experience."` chat format, so the `+N XP` notification fires correctly on Forever (build 1.60.x) alongside Retail's existing formats.
- **XP CVar coverage:** `floatingCombatTextXPChanges`/`_v2` added to the Blizzard FCT suppression lists so Retail's XP-change text follows the XP suppression toggle.
- **Diagnostic commands:** `/zsbt xpdiag`, `xpfind`, `textscan`, `findcvar`, `ctinspect`, `xpwrap`, `dumpcvars` for live client probing (used to isolate Forever's XP popup path).

### Changed
- **World-text suppression:** when all Blizzard text categories are hidden, ZSBT now inflates `WorldTextScale`/`_v2` to `1000` (flinging world text off-screen) instead of shrinking to `0.01`. Verified on WoW Forever where the XP popup is world-text-driven and ignores every other suppression path; values still snapshot/restore with the FCT backup.

## 3.5.6

### Added
- **Multiple resource counters:** the Resource Tracker now supports one independently-configured counter per resource (Combo Points, Soul Shards, Holy Power, Runes, etc.), each with its own config window, placement, colors, and full-resource alerts. Legacy `comboPoints` settings migrate automatically onto the effective power type.
- **Retail secret-value filtering:** resources Blizzard marks secret via `C_Secrets.ShouldUnitPowerBeSecret` (Mana, Rage, Energy, Fury, Pain, Runic Power on Retail 12.x) no longer appear as tracker options; capped secondary resources stay fully supported. Older clients without the API are unaffected.
- **DK rune tracker:** power type 5 renders six per-slot rune indicators driven by `GetRuneCooldown` — ready runes lit, recharging runes fill upward with optional seconds-remaining text. Updates via `RUNE_POWER_UPDATE` plus a light ticker for sweep animation. Rune shapes: Square, Diamond, Circle, Hexagon (new `Media/Textures` assets). Dedicated config page hides count-based options (format, hide-at-zero, alerts) that don't apply to runes; "Hide when All Runes Are Ready" supported.
- Config options table is rebuilt each time the config window opens, fixing class-dependent options (like the Runes button) being missing until reload.

### Fixed
- Resource counter buttons now evaluate power availability at config-open time instead of addon load, when `UnitPowerMax`/class data may not be ready.

## 3.5.5

### Fixed
- Outgoing misses/immunes/dodges/parries/blocks/absorbs/deflects/reflects/evades now display when "Show Misses" is enabled. The UNIT_COMBAT(target) path was emitting OUTGOING_DAMAGE_COMBAT with a source the Pulse Engine trust list rejects, so every miss event was suppressed before reaching the probe. It now emits the dedicated OUTGOING_MISS_COMBAT event that routes to kind="miss" and the configured Outgoing scroll area.

## 3.5.4

### Fixed
- **Raid/group outgoing leak (major):** in group instances with instance-aware outgoing enabled, other players' damage on shared targets could flood the Outgoing stream — unattributed `UNIT_COMBAT(target)` hits were claimed by stale periodic records and emitted as `Outgoing nil` / mislabeled spellIds, bypassing merge entirely. Restricted content now requires a tick-colored combat-log line for periodic emits, drops nil/weak attributions at the merge-bucket flush, and no longer lets foreign hits burn pending casts (learned delay check moved inside cast matching).
- Cast school/delay profiles no longer record samples in group content — raid collateral can't poison the profiles solo/open-world attribution relies on; stored profiles were version-bumped and relearn clean.
- Periodic tracker candidates can no longer self-perpetuate: false emits no longer refresh tick liveness, so dead DoT records stop matching on their own.
- Moonfire (and similar) opener hits: a pending cast for the same spell now takes precedence over periodic interception, so the initial direct blast displays instead of being vetoed into nothing when the aura scan wins the race.

## 3.5.3

### Added
- **Resource Tracker**: new config section under Alerts → Notifications → Resource Tracker with a standalone, freely-positionable resource counter widget.
- Resource counter displays diamond pips (texture-based, outlined) or fraction/number text for any readable `UnitPower` resource; pips auto-scale to the frame and the widget supports drag-to-move and corner-resize while unlocked.
- Looping "resource ready" effects while the tracked resource sits at max: **Ignite**, **Chromatic**, **Shatter**, and **Afterimage** — the chosen effect runs continuously and stops the instant the resource drops, the counter hides, or the effect is set to None.
- Rising-edge full-resource sound (fires once on reaching max, not per animation loop).
- Resource Full notification renamed from Power Full and moved into Resource Tracker; supports custom templates (`%e` = resource name, e.g. `"%e Full!"`), route selection, and per-category style/sound overrides.
- Counter font override (face, outline, size/scale) matching the standard font-override pattern; notification styling uses the shared per-type style controls.
- Dedicated "Unlock Resource Counter" button — unlocks only the counter frame (scroll areas unaffected); the shared Scroll Areas unlock also works.
- Gold border shown around the counter while in edit/unlock mode.
- Resource dropdown now lists only power types actually readable for the current class/spec — both current value and max must be safe-readable numbers and max > 0, so secret resources (e.g. Energy in combat) are excluded automatically.
- Shipped defaults tuned for rogues: combo-point pips enabled, chromatic full effect, Finish Him sound, Bungee font overrides.

### Fixed
- Slider/config lag in Resource Tracker: setters now throttle `NotifyChange` refreshes (~0.15s) instead of rebuilding the entire options tree per pixel.
- Position dropdown no longer returns empty (anchor value map + default normalization); unknown anchors fall back to Center.
- `C_Timer` ticker callback arg treated as userdata — animation updates now use `GetTime()` deltas.
- Full effects now stop correctly on every hide path (disabled, unsafe values, max 0, hide-at-zero, out of combat) and restore canonical pip layout.
- Hide-at-zero toggle/runtime mismatch: code now treats any value other than explicit `false` as enabled.
- Counter debug logging removed.

## 3.5.2

### Added
- Outgoing periodic heals (HoTs): delayed `UNIT_COMBAT(target)` HEAL ticks are now attributed to recent heal casts via a learned hot-spell matcher, so Lifebloom/Rejuvenation/Wild Growth/Riptide-style ticks keep scrolling after the direct heal instead of going silent under restricted outgoing modes.
- Buff rule sounds: aura rules now support separate **Gain Sound** and **Fade Sound** selections with per-event test buttons; unset keys fall back to the shared sound.
- Warlock spell school seeds for all specs (Shadow Bolt, Demonbolt, Hand of Gul'dan, Incinerate, Conflagrate, Chaos Bolt, Shadowburn, Agony, Corruption, Unstable Affliction, Seed of Corruption, Phantom Singularity, Immolate, Haunt, Rain of Fire, Channel Demonfire, Infernal, Shadowfury) — day-one-confident school rejection instead of learning from zero.
- Attribution diagnostics: `weak=` flags in `FLUSH_BEST`/probe debug output and the custom attribution panel (`/zsbt debug`) show exactly how each outgoing hit was attributed.

### Removed
- Spell Rules no longer have a Show Icon option; per-rule icons were removed because hit-level spell attribution on secret-value clients can't guarantee the configured spell. Global spell icons still apply.

### Fixed
- **Icon/attribution bleed (major):** `spellIdWeak` was computed correctly by the collector but dropped by Pulse_Engine when rebuilding events — every inferred/weak attribution reached the probe as authoritative, so rule icons/fonts/names bled onto unrelated hits. The flag now propagates end-to-end.
- `school=127` (all-schools) hits carry zero school information but were keeping full spell-rule styling; they are now forced weak.
- Seeded spells now require hits to cover the full school signature (e.g. Hand of Gul'dan needs `school=36`, not a pure-fire `4` subset) for strong attribution — subset hits display anonymously.
- Weak attributions can no longer teach cast school/delay profiles, and only fresh pending-cast matches landing promptly after the cast contribute samples — the learning loop no longer feeds on its own guesses.
- `suppressDummyDamage` no longer suppresses heals/misses on training dummies — it was killing every non-damage event kind.
- Cast attribution profiles reset (v4) to clear poisoned school data learned during the permissive phase.
- Pet-priority rerouting strengthened: rejected hits matching pet damage signatures go to the pet stream instead of wearing player spell styling.

## 3.5.1

### Added
- Aura notifications no longer go silent in combat on secret-value clients: `SPELL_AURA_*` combat-text notices now act as a fallback when `UNIT_AURA` payloads are unreadable, deduplicated against readable aura updates.
- Buff refresh re-notification: recasting a buff that keeps the same aura instance now re-shows its gain when `expirationTime` jumps forward.
- Recast pairing: a cast of a known self-buff within 0.5s of an unreadable aura update re-shows the buff's cached name/icon.
- `C_Secrets` per-index/per-instance predicates refine secret-aura gating (skips individual secret auras instead of all-or-nothing where the client supports it).
- Name-keyed aura rules (`"name:X"` in `auraRules`) match every rank of an aura by name when no spellID rule exists.
- Aura notifications can carry spell icons via `meta.spellIcon`.

### Fixed
- Duplicate aura gain notifications: recast pairing, watched-presence rules, and refresh re-notifies now stamp the aura-read timestamp so the combat-text fallback can't double-emit (e.g. two `+Buff` for one cast).

## 3.5.0

### Added
- Full localization: the entire addon UI (menus, tabs, options, buttons, tooltips, dialogs, notifications, slash-command output) now routes through AceLocale with English-text keys.
- Eight complete locale files: `deDE`, `esES`, `frFR`, `itIT`, `ptBR`, `ruRU`, `zhCN`, `koKR` — all at full key parity (1,077 keys each). Untranslated or missing keys fall back to English automatically.
- Active locale now shown in the login message and at the top of the Help tab.
- `Locales/ForceLocale.lua` test hook (disabled by default via commented .toc entry) for previewing any locale on an English client.

### Fixed
- Second localization sweep: ~50 user-facing strings that bypassed the first pass (color-coded tab/group names, dynamic button labels, probe/status messages, editor labels, help topic names, UT trigger defaults, static popup dialogs verified) are now localized.
- enUS `TEST 12345` locale entry was `true` instead of a string — would have thrown a concat error in the scroll-area test feature.

## 3.4.4

### Fixed
- Misses, dodges, parries, blocks, absorbs and immunes display again: `UNIT_COMBAT` carries them as their own actions, and the WOUND-only branch dropped them before any emit. Both incoming (player) and outgoing (target) now emit them as miss text; restrict mode still requires recent-cast correlation so foreign misses don't leak.
- Whirlwind invisible on secret-value clients: the aggregation buffer required a safe numeric amount to sum, so every hit was silently dropped before display. Hits with secret amounts now emit directly via the raw-value path (aggregation is only used when amounts are readable).
- Icon spam: each per-hit Whirlwind emit rendered a spell icon; per-hit Whirlwind emits now suppress the icon.
- Multi-hit physical bursts (Whirlwind, cleaves) in groups: the first hit consumed the pending cast and follow-ups were dropped; the last matched cast can now be re-used for 0.75s, school-checked.
- Incoming heals showed the outgoing spell's icon: the last player cast was stamped on any heal within 0.5s. Now only stamped when the last cast was a helpful spell.
- Healer-name heal text: formatted safe strings ("Name\\n+1234") now collapse to a single line.

## 3.4.3

### Fixed
- Incoming damage and self-inflicted absorbs no longer vanish on secret-value clients: `Pulse_Engine` dropped `COMBAT_TEXT_DAMAGE` events whose secret amount failed `tonumber`, and `Incoming_Probe` only exempted heals (not damage) from the secret no-threshold suppression and secret raw-pipe text assignment.
- Outgoing direct spells (Shadow Bolt, Hand of Gul'dan, Demonbolt, etc.) suppressed in group content: grouped gates returned before the pending-cast queue was consulted, and the non-physical correlation window was shorter than travel time. Grouped hits now consume a pending-cast match; non-physical hits use the full 2.5s window.
- Follower/foreign damage stealing casts: pending casts now record their spell's school and hits must overlap it (combined schools like Shadowflame share bits). Physical hits can only match casts with a known physical school — a follower Holy crit can no longer wear a Shadow Bolt.
- DoT icon fallback: DoT emits now carry `spellName`, and `ZSBT.CleanSpellIcon` accepts spell names, so ticks whose spellId is unresolvable (e.g. Shadow Word: Pain on WoW Forever) can still resolve an icon.

## 3.4.2

### Fixed
- Strict outgoing now blocks ALL unattributed emits: the auto-attack fallback, physical-swing `spellId=nil` path, and the bucket-path last-resort auto emit were all gated by mode flags that ignored user strict mode, so other players' damage leaked through on shared targets.
- Quiet + "allow auto attacks while quiet" no longer shows other players' melee: auto-attacks now require swing-cadence alignment (predicted from `UnitAttackSpeed`, ±0.45s window) plus melee range via `CheckInteractDistance`.
- Foreign ability damage reduced: cast-correlation windows tightened (0.90→0.60s timestamp path, 0.55→0.45s bucket path).
- Pet melee no longer appears as player auto-attacks when a pet is active.

## 3.4.1

### Fixed
- Crash (`attempted to index a table that cannot be indexed with secret keys`) when auras report secret `auraInstanceID` — e.g. toys like Essence of Yu'lon. Such auras are now skipped in `ScanPlayerAuras` since they can't be tracked without a usable key.

## 3.4

### Added
- Periodic damage tracking extracted into `Parser/Periodic_Tracker.lua` — unified per-DoT records (true application time, learned tick interval, learned school, predicted next tick) shared by the target, pet-fallback, and combat-text paths instead of three divergent inline copies.
- Combat-log line-color classification (`COMBAT_LOG_MESSAGE`, RGB only — no text reads): the saved `ZSBT` combat-log filter colors `SPELL_DAMAGE`/`LEECH`/`DRAIN`/`BUILDING_DAMAGE`, `SPELL_PERIODIC_DAMAGE`/`LEECH`, `SWING`/`RANGE`/`DAMAGE_SHIELD`/`DAMAGE_SPLIT`/`ENVIRONMENTAL_DAMAGE`, and `SPELL_HEAL`/`SPELL_PERIODIC_HEAL` so tick-vs-direct-vs-melee attribution is confirmed by the line color itself.
- Multi-DoT disambiguation: `MatchHit` scores candidates by aura freshness, learned school match, and predicted tick schedule; new debug tags `PT_SEED`/`PT_LEARN`/`PT_MATCH` report each stage.
- DoT coverage expanded: `Immolate`, `Living Bomb`, `Fire Breath`, `Purge the Wicked`, `Holy Fire` added to the name table; `KNOWN_PERIODIC_IDS` fallback grew to ~30 canonical spellIds across all DoT classes.

### Fixed
- First ticks of every fresh DoT dropped: `dotAge` was seeded from when the throttled aura scan first noticed the debuff (up to several seconds after application on secret-value clients). Application time is now computed from `expirationTime - duration`, and when the color signal is live the deferred line-color check vets hits instead of the age gate.
- `AuraUtil.ForEachAura` sees zero auras for seconds after application on Midnight — cast-seeded periodic candidates now carry that window for every class (previously warlock/druid only via `isKnownPeriodicSpellId`).
- Duplicate ticks: a hit on a nameplated current target arrives as both the nameplate unit token and `target`; the second copy is now dropped only when its signature matches the remapped event within 0.12s (multi-hits still count).
- Lightning Bolts/nukes swallowed during active DoTs: signal-live candidates are only intercepted when no pending cast could own the hit (non-consuming `consumeBestPendingCast` peek).
- Pet melee displayed as player auto-attacks: the auto-attack fallback now yields to the pet path when a pet is active and pet display is enabled.

### Known limitations
- `UNIT_COMBAT` still carries no source/spellId for periodic hits on secret-value clients; tick attribution is inference (cast memory + color confirmation + learned schedule), so icons can misattribute between same-school DoTs.

## 3.3

### Changed
- Secret-value detection now uses Blizzard's official APIs: `issecretvalue()` / `issecrettable()` are checked first, `HasSecretValues()` retained for nested-secret detection, and the pcall arithmetic probe is now only a fallback for older clients. Added `ZSBT.CanAccessValue()` wrapping `canaccessvalue()` for context-aware checks. All ~500 existing `IsSafeNumber`/`IsSafeString`/`IsSecret` call sites benefit without signature changes.

### Fixed
- Outgoing damage chat fallback (`Parser/Event_Collector.lua`): the secret-message path called `msg:find`/`msg:match`/`tonumber`/`msg:lower()` directly on combat chat payloads, which can hard-error when `SecretInChatMessagingLockdown` makes those strings secret in dungeons/raids/PvP. Probes and parses are now `pcall`-guarded and results must pass `IsSafeNumber`/`IsSafeString` before comparison. Debug receive paths are also gated on string safety.
- Pet damage duplicates: all pet outgoing emit sources (UNIT_COMBAT target fallback, "Your pet hits" chat, pet-name chat, DK guardian) now share a 0.35s dedup window, and the chat paths stamp the same state — previously the same swing could display twice via fallback+chat or double `UNIT_COMBAT` reports.
- Auto-attacks stolen by pet fallback: unattributed physical hits were claimed as pet damage whenever a pet was in combat. Pet fallback now requires the hit's school to match a known pet signature (`isLikelyPetSchoolHit`) for all schools, not just in restricted modes.
- Auto-attacks dropped with a pet summoned: a pre-existing `hasPet and not matchedCast` gate discarded all unattributed hits while any pet existed. It now only drops hits the pet could actually own (signature-school match), so player white swings reach the outgoing path again.
- Quiet outgoing + "allow auto attacks while quiet" no longer suppresses auto-attacks when a pet is out: the auto-attack fallback only yields to the pet when the hit matches a pet signature.
- Warlock pet attribution: `isLikelyPetSchoolHit` now recognizes shadow (32) for Warlock (felhunter/felhunter/voidwalker/succubus abilities, Lash of Pain, Torment) alongside fire (4) for Imp/Infernal. Pet-signature hits win over the recent-player-cast window unless the last cast was a known Warlock nuke/DoT (Shadow Bolt, Incinerate, Chaos Bolt, Shadowburn, Haunt, Darkglare, DoTs).
- Warlock pet melee: physical hits are attributed to the pet when the player's auto-attack (`IsAutoRepeatAction`) is definitively off — covers succubus/voidwalker/felhunter melee while the warlock casts at range. When the player is auto-attacking, physical hits stay in outgoing since pet melee and player swings are indistinguishable in `UNIT_COMBAT`.

### Known limitations
- `UNIT_COMBAT` on Midnight provides no source GUID or spell ID, so player auto-attacks, pet melee, and unattributed procs remain ambiguous in some windows (e.g. pet melee within ~1.25s of a player cast, same-school pet abilities vs. player spells). Attribution is heuristic; perfect separation is not possible without a source-bearing combat event.

## 3.2

### Fixed
- Duplicate auto-attack numbers in open world: unattributed white swings could be emitted by both the `UNIT_COMBAT_PHYSICAL` and `UNIT_COMBAT_AUTO_FALLBACK` paths for the same swing (school is unreliable on Midnight, so one swing can satisfy both branches), and neither path deduplicated against the other. Auto emits (`spellId == nil`) now share a 0.35s dedup window; spell-attributed hits (Cleave/Whirlwind) are exempt.

## 3.1

### Added
- Incoming → Healing: new **Show Healer Names** option (default on). Some clients (e.g. WoW Forever) deliver incoming heal combat text as a formatted string containing the healer's name, which is rendered verbatim. When disabled, clean strings are reduced to the numeric amount and secret strings are skipped so the nameless `UNIT_COMBAT` heal path supplies the display instead.

### Fixed
- Spell merging stopped working on secret-value clients: the tainted-text guard added in 3.0a also bypassed the merge buffer for every outgoing hit (amounts arrive as secret values on Retail 12.x), so nothing ever merged. Tainted text now enters the merge buffer as count-only `"Hits (xN)"` merges — `text:match` is skipped for values that can't be inspected.
- Version string: `ZSBT.VERSION` in `Core/Constants.lua` still read `2.5.3a`, so `/zsbt version`, the minimap tooltip, and the config header showed the old version even though the TOC was updated. Now reports `3.1`.

## 3.0a

### Fixed
- Incoming healing on WoW Forever (1.60.x / secret-value client): `UNIT_COMBAT` heal amounts arrive as secret values, and `INCOMING_HEAL_COMBAT` never routed the raw amount through the combat-text pipe — so the secret value was stripped before display and every incoming heal was dropped. The raw amount now flows through `_rawPipe` for `INCOMING_HEAL_COMBAT`, `INCOMING_DAMAGE`, and `FALL_DAMAGE`, and the incoming probe passes tainted heal values through to `SetText()` (same pattern as outgoing heals) instead of suppressing them.
- Pet damage crash on secret-value clients: `Pulse_Engine` pet damage/incoming-damage fallbacks ran `pcall(tostring, val)` on secret amounts and then compared (`s ~= ""`) and concatenated (`"-" .. s`, `prefix .. " " .. s`) the resulting secret string, throwing `attempt to compare local 's' (a secret string value)` on every pet hit. Secret amounts are now passed raw to `SetText()` (which renders them); safe strings keep the prefix/`-` formatting. Also hardened the `[XPDBG]` debug paths in `Core.lua` against concatenating secret `tostring` results.

## 2.5.3a

### Fixed
- Config UI: fixed a crash (`attempt to call a nil value`) in the bundled AceGUI-3.0 CheckBox widget that blanked out every config page and prevented changing any options. Blizzard removed the global `SetDesaturation()` function in 12.1; replaced all 6 calls with the modern `texture:SetDesaturated()` method. This was not an addon conflict — ZSBT's own bundled library was calling a deleted Blizzard API.

## 2.5.3

### Fixed
- WoW Retail 12.1 aura safety: hardened player aura tracking against Blizzard 12.1 "secret value" restrictions (secret booleans/tables in `UNIT_AURA` update payloads).
  - Combat: unconfigured buff/debuff gain/fade notifications are suppressed (rules-only) to avoid secret-payload churn.
  - Combat: configured Buff/Debuff Rules continue to work via watched spellID presence checks rather than delta parsing.
  - Prevented Lua errors from comparing/iterating secret `UNIT_AURA` fields and reduced false fade/gain bursts on combat transitions.

## 2.5.2

### Changed
- TOC: updated `## Interface` to `120100` for Retail 12.1.
- Outgoing / Pets (`Parser/Event_Collector.lua`): added a group-aware pet/guardian suppression gate when `restrict` modes are active (Quiet/Strict/PvP/Instance-Aware) so pet fallback attribution is only allowed when the damage school matches a known pet signature. This reduces misattribution of other players' damage on shared targets.
- Outgoing correlation (`Parser/Event_Collector.lua`): relaxed the `restrict` cast-to-WOUND correlation window from `0.70s` to `0.90s` to better accommodate travel-time / delayed-hit spells.
- Outgoing correlation (`Parser/Event_Collector.lua`): tightened timestamp-only attribution suppression so it refuses timestamp-only matching whenever you are grouped (previously only blocked in group instances with instance-aware outgoing enabled).

## 2.5.1

### Fixed
- Interrupts/Cast-stops: fixed a crash (`attempted to index a table that cannot be indexed with secret keys`) when an interrupt or cast-stop notification fired against a nameplate unit in a dungeon, raid, or Mythic+. Nameplate GUIDs returned by `UnitGUID` are tainted in instanced content; the code was using them as table keys without an `IsSafeString` guard. Notifications still fire — they are just not GUID-qualified for dedup when the target GUID is instance-restricted.
- Debuff cache: fixed a crash (`attempt to compare field 'guid' (a secret string value)`) in the DoT attribution debuff TTL cache when the target's GUID was tainted. The GUID is now validated with `IsSafeString` before storage; the cache is bypassed entirely in tainted contexts; and a `pcall` guard safely drains any pre-existing tainted entries without requiring a `/reload`.

Both bugs only reproduce in group instanced content where Blizzard's secret value restrictions apply to nameplate and target GUIDs.

## 2.5.0

### Performance
- Combat pipeline: extracted the Whirlwind aggregation flush callback into a named module-level function; previously an anonymous closure was heap-allocated on every Whirlwind hit.
- Combat pipeline: added a 1.5s TTL cache for target debuff lookups (`hasTargetDebuffSpellId`) with per-GUID invalidation, reducing redundant aura scans during rapid multi-hit sequences.
- Combat pipeline: replaced per-event pet color table construction with module-level constants for all four pet damage/healing color pairs.
- Combat pipeline: replaced string concatenation keys in the damage meter last-totals map with a two-level nested table, eliminating string allocations on every outgoing damage event.
- Animation engine: removed redundant `ClearAllPoints`/`SetPoint` calls for icon FontStrings and icon textures from the per-frame `AE_UpdateEvent` path (ran ~66 times/sec per active event); anchor is now set once at event creation time.
- Animation engine: added early-out at the top of the `OnUpdate` handler when no scroll areas have active events, skipping all processing overhead for that tick.
- UI: `FireTestText` scroll area parent frames no longer call `ClearAllPoints`/`SetPoint` on every combat event; geometry is cached and only re-applied when the configured position or size actually changes.

### Fixed
- Combat pipeline (Midnight): guarded four `tostring(amount)` call sites in UNIT_COMBAT DOT and pet fallback paths with `IsSafeNumber` checks to prevent Lua errors when `amount` is a WoW 12.x secret/tainted value.
- Object pool: `RecycleIconFS` now resets `SetRotation` to 0 (matching `RecycleFontString`) so a rotated icon FontString cannot carry stale rotation into its next consumer.
- Display: `TryMerge` now stores a shallow copy of the incoming `meta` table in the merge buffer rather than a direct reference, preventing stale crit annotations if the caller's table is mutated before the flush timer fires.

### Changed
- Quick Control Bar: dragging is now blocked during combat (`InCombatLockdown`). If a drag is released while in combat, the position save is deferred and applied when combat ends (`PLAYER_REGEN_ENABLED`).

## 2.4.7
- Documentation: updated configuration paths to match the current Display, Combat Text, Alerts, and Help and Support UI layout.
- Documentation: clarified Blizzard combat text suppression options and Retail 12.x outgoing attribution limitations.
- Documentation: expanded incoming spell icon notes to explain resolved vs fallback icon controls.
- Help UI: updated in-game Help and Troubleshooting text to match current UI navigation paths.

## 2.4.6
- Outgoing: improved Warlock DoT tracking (including Seed of Corruption) and Warrior Rend periodic tick detection under WoW 12.x.
- Outgoing: tightened instance-aware outgoing attribution to reduce non-player damage leakage in group instances.
- Notifications: improved interrupt and cast-stop tracking, including Warlock pet interrupts via Command Demon (Axe Toss) and improved cast-stop announcements (e.g. Mortal Coil) when cast-start events are missing.

## 2.4.5
- Pets: fixed pet damage text only displaying when outgoing debug was set to 4+ (secret-value display fallback was incorrectly debug-gated).

## 2.4.4
- Outgoing: fixed Quiet Outgoing When Idle suppressing your own casts in some cases (improved cast correlation window for longer travel-time spells).
- Outgoing: restored spell icons for modern outgoing fallback sources.
- Pets: improved pet/guardian damage attribution for WoW 12.x-safe signals, including Death Knight ghoul damage when no `pet` unit exists.

## 2.4.3
- Outgoing: added an option to auto-relax strict/quiet outgoing attribution while solo inside party/raid instances (legacy content) to prevent one-shot hits from being suppressed.

## 2.4.2
- Libraries: integrated LibCombatPulse-1.0 as a unified event bus and switched internal parsing to consume via LibCombatPulse (prevents double-processing).
- Combat: enriched emitted events with original `eventType` for easier filtering/diagnostics; miss events now include `missType`.
- Diagnostics: LibCombatPulse sampling output is now controlled via the `lcp` debug channel.

## 2.4.1
- Notifications: split Progress notifications into separate categories for Player XP, Honor, and Reputation (individually configurable).
- Migration: added a one-time profile migration to copy legacy Progress settings to the new categories and remove the legacy keys.
- UI: restored Notifications category layout so Enter/Leave Combat and Loot/Trade Skill alerts appear as their own categories.

## 2.4.0
- Notifications: added LibSink-2.0 output support so other addons can route notifications into ZSBT.
- Notifications: added a new per-type notification category "External Addons (LibSink)" with routing/template/style options.
- Compatibility: fixed LibSink registration when LibStub is implemented as a callable table (ensures ZSBT appears in LibSink output lists).
- Compatibility: improved live refresh of LibSink output options in AceConfig UIs so newly registered sinks appear without UI errors (including SilverDragon announce output).
- Loot: added an option to display looted money using coin icons (no zero placeholders), configurable per notification type.
- Media: added a new setting to choose which WoW audio channel ZSBT uses for playing sounds (Master/SFX/Music/Ambience/Dialog).

## 2.3.9b
- UI: fixed StrikeSilver config styling to restore shared AceConfigDialog backdrops (prevents ElvUI config background override) and fixed nil errors on open.

## 2.3.9
- UI: rebuilt minimap button to use embedded LibDataBroker + LibDBIcon for consistent icon rendering and tooltips.

## 2.3.8
- UI: simplified minimap button icon rendering and improved texture fallback/centering.

## 2.3.7
- Triggers: reduced Bloodlust lockout false positives and duplicate alerts by making lockout debuff notifications core-driven (sync no longer emits lockout gain/fade).

## 2.3.6
- Crits: fixed inline Chromatic crit FX not rendering correctly when "Force Crits Inline" is enabled.
- Triggers: further hardened Bloodlust lockout aura sync against zone/instance transition flapping to reduce false-positive notifications.

## 2.3.5
- Crits: added new centered/sticky crit animations (Shockwave, Ignite, Chromatic, Stomp, ScreenPunch, Shatter, Afterimage, Rumble), each with its own intensity slider (Global/Incoming/Outgoing).
- Crits: improved centered crit positioning to reduce overlap/clutter for successive crits.
- Numbers: added a new Number Format option to always display values in thousands (K).

## 2.3.4
- Crits: added a General toggle to force crits inline with the normal incoming/outgoing damage/healing flow (no crit scroll-area routing), matching the scroll area's animation and font.
- Crits: crit damage/heal color settings now apply even when crit routing is disabled (incoming + outgoing).

## 2.3.3
- Outgoing: fixed a rare WoW 12.x secret/tainted number crash when polling attack speed in restricted UNIT_COMBAT attribution paths.

## 2.3.2
- Triggers: reduced rare false-positive aura notifications caused by WoW 12.x aura enumeration flapping (sync-driven fades are suppressed shortly after Core reports the aura present).

## 2.3.1
- Diagnostics: added debug output routing to a selected chat window (configurable in the Debug UI and via /zsbt debug frame).
- Diagnostics: added a one-click button to create a "ZSBT Debug" chat tab/window for debugging.

## 2.3.0
- Spam Control: fixed a WoW 12.x secret/tainted SpellID edge case that could cause a Lua error in Spell Merging.
- Combat Text: fixed Blizzard floating combat text "outgoing-only" mode leaking incoming self damage/heals.
- Cooldowns: fixed rare early "Cooldown Ready" notifications caused by a stale timer not being cancelled when a cooldown restarts.

## 2.2.10
- Spam Control: fixed global Spell Merging timing so it can accumulate rapid multi-hits within the configured merge window.
- Spam Control: clarified Spell Merging behavior/limitations in WoW 12.x (some abilities emit multiple SpellIDs; Spell Rules are more accurate).

## 2.2.9
- Profiles: added an in-game tool under DB Profiles to copy character-scoped Spell Rules, Buff Rules, and Triggers from another character (merge or replace) without requiring a /reload.

## 2.2.8
- Auras: fixed a rare aura-scan crash in instanced content (Mythic+) caused by overlapping init/zone timers clearing init suppression state.
- Triggers: deduped Bloodlust lockout aura triggers when multiple spell IDs resolve to the same lockout name (ex: Fatigued/Exhaustion) so only one notification fires.
- Media: registered additional bundled fonts with LibSharedMedia.

## 2.2.7
- Libraries: fixed embedded Ace3 TOC load order so ZSBT works standalone (loads AceGUI before AceConfigDialog, includes AceGUI XML, and includes AceConfig wrapper).

## 2.2.6
- Spam Control: fixed unconfigured aura gain/fade notifications bypassing global toggles when spell ID cannot be resolved (common in combat).
- Migration: hardened profile->char migrations for Spam Control rules, Triggers, and tracked cooldowns to normalize numeric string keys and avoid destructive trigger cleanup.
- Troubleshooting: added a repair button to normalize Spam Control rule keys (string spell IDs -> numeric).
- Diagnostics: fixed nil Addon initialization during early load.

## 2.2.5
- Config UI: hardened AceConfig window behavior (prevents ZSBT config close/ESC handling from interfering with other addons).
- Combat Text: replaced Blizzard combat text suppression dropdown with granular hide toggles (outgoing/incoming/heals/reactives/xp+rep+honor/resource gains/pet) and kept a manual restore button as a panic option.

## 2.2.4
- Triggers: fixed watched aura sync so auras already present at login/reload do not emit a new `AURA_GAIN` (prevents false re-notifies for debuffs like Temporal Displacement).
- Spam Control: fixed harmful debuff gain notifications ("+Debuff") bypassing global unconfigured toggles when spell ID could not be resolved in incremental aura updates.

## 2.2.3
- Triggers: fixed `Sticky Jiggle (shake)` toggle in Trigger actions so it correctly persists and can be disabled.
- Triggers: hardened watched aura sync presence checks to reduce false `AURA_FADE`/`AURA_GAIN` transitions during loading screens.
- Media: registered additional bundled fonts/sounds via LibSharedMedia so they appear in dropdowns.

## 2.2.2
- Triggers: improved watched aura sync so it only emits `AURA_GAIN`/`AURA_FADE` on actual state transitions (reduces sync dedup spam).
- Triggers: reduced loading-screen aura flapping causing false re-triggers (example: Bloodlust lockout debuffs like Sated/Fatigued/Temporal Displacement).

## 2.2.1
- Sticky: added a separate `Sticky Jiggle (shake)` toggle (Triggers and Crit Sticky settings) so you can disable shaking while keeping sticky placement/scale/duration.
- Sticky: improved the Pow-style sticky animation to feel more like a slam on entry.

## 2.2.0

### Debug / Diagnostics overhaul
- Replaced legacy debug gating (`diagnostics.debugLevel`, `cooldownsDebugLevel`, and ad-hoc tagged `Addon:Print()` debug lines) with a unified **channel-based** debug system.
- New API:
  - `Addon:GetDebugLevel(channel)`
  - `Addon:Dbg(channel, level, ...)`
  - (internally supported helpers for one-time / rate-limited debug where needed)
- Debug levels are standardized across the addon:
  - `0` Off
  - `1` Error
  - `2` Warn
  - `3` Info
  - `4` Debug
  - `5` Trace
- Debug output is now routed through safe formatting to avoid crashes from WoW 12.x “secret value” restrictions.

### Debug UI (new)
- Added a dedicated Debug UI panel for controlling:
  - Default debug level
  - Per-channel debug level overrides

### Commands (how to use)
- Show current levels:
  - `/zsbt debug show`
- Set global default debug level:
  - `/zsbt debug <0-5>`
- Set a specific channel:
  - `/zsbt debug <channel> <0-5>`
- Common channels:
  - `core`, `cooldowns`, `incoming`, `outgoing`, `triggers`, `notifications`, `ui`, `diagnostics`, `safety`, `perf`

### Troubleshooting quality-of-life
- Added an `Open Debug UI` button under:
  - `/zsbt` -> `Help and Support` -> `Troubleshooting`

### Outgoing
- Fixed: custom crit damage color now applies even when crits are not routed to a separate scroll area (staying in the default Outgoing area).

## 2.1.0
- Cooldowns: fixed late READY notifications and false READY on cast/regen by implementing combat-only `isActive==false` detection with 1s suppression window after combat transitions.
- Cooldowns: removed `start=0/dur=0` as a readiness signal to prevent transient API glitches from firing READY early.
- Cooldowns: removed action-button Cooldown widget readiness path due to unstable/tainted values in combat.
- Cooldowns: added `StartUsablePoll` system with proper combat-state tracking and `C_Spell.GetSpellCooldown` polling for reliable early-ready detection.

## 2.0.12
- Cooldowns: fixed cooldown_ready trigger firing late in combat by preventing timer drift from SPELL_UPDATE_COOLDOWN jitter.
- Cooldowns: cooldown timer now refuses to reschedule to a later ready time once a timer is active.
- Auras: fixed secret-value debug crash in combat (AceConsole concat error) by using safe debug printing.
- Triggers: fixed COOLDOWN_READY trigger matching to work without spellId specified.
- Triggers: removed heavy SpellUsable/AuraSync debug output to reduce combat overhead.

## 2.0.11
- Auras: suppressed buff notification spam on login/reload/zone change by tracking auras seen during initialization.
- Auras: added grace period after aura removal to suppress gain notifications from instance ID refreshes.
- Auras: added fallback lookup for fade notifications when instance IDs are not in cache.
- Auras: suppressed fade notifications during init window (1.5s after reload) when instance IDs are unstable.

## 2.0.10
- Blizzard Combat Text: replaced the single "Suppress All" toggle with modular suppression modes (None/All/Incoming/Outgoing).
- Blizzard Combat Text: suppression OFF is now "no-touch" and no longer forces Blizzard combat text back on.

## 2.0.9
- Cooldowns: added "Show Spell Icon" toggles for Cooldown notifications and COOLDOWN_READY triggers.
- Cooldowns/Triggers: COOLDOWN_READY triggers now fire without requiring the spell to be tracked under Alerts > Cooldowns.
- Cooldowns: added resync on login/combat transitions to (when readable) schedule cooldown ready timers for watched spells.
- Auras: suppressed buff gain notification spam on login/zone/reload by seeding aura state silently.

## 2.0.8
- Cooldowns: improved cooldown-ready notifications to work more reliably in combat with additional debug tracing and safer cooldown API handling.
- Cooldowns: disabled cooldown-ready notifications for multi-charge spells in WoW 12.0 Midnight due to unreliable/secret charge + recharge data.

## 2.0.7
- Fixed reputation, honor, and XP progress notifications not displaying amounts.
- Updated parser to pass amounts directly in event payloads, avoiding timing issues with rawPipe lookups.

## 2.0.6

### Added
- Notifications: revamped the Notifications configuration UI into a tree layout with grouped sections (Combat State, Loot Alerts, Trade Skill Alerts).
- Notifications: added per-notification-type customization for supported categories:
  - Message templates (all notification types now support templates)
  - Per-type style overrides (color + optional font override)
  - Per-type sound options (enable + sound picker)
- Notifications: split Combat State into separate Enter Combat and Leave Combat categories for independent routing/templates/styles/sounds.
- Notifications: added Enter Combat option to stop the Enter Combat sound when leaving combat (so the Leave Combat sound can play cleanly).

### Changed
- Notifications: Interrupt Alerts configuration and behavior remains unchanged (still uses the Interrupt Alerts system), but is now embedded under the new Notifications tree.
- Notifications: Loot Alerts and Trade Skill Alerts now live under grouped sections in the Notifications tree.

### Fixed
- Notifications: added upgrade migrations to backfill missing notification templates and per-type style/sound defaults without overwriting existing user settings.
- Notifications: fixed sound playback helper to return a handle so long Enter Combat sounds can be stopped on Leave Combat when configured.

### Removed
- Notifications: removed unsupported categories from the Notifications tab UI (auras, procs/reactives, cooldown ready, custom triggers). These are handled elsewhere.

## 2.0.5

### Fixed
- Notifications: fixed stopper ability naming in Interrupt Alerts (prevents cast-stops like Shockwave displaying as a previous interrupt like Pummel).
- Notifications: stabilized Interrupt Alerts spell naming by hardcoding/caching known interrupt + cast-stop spell names to avoid mob-specific name resolution.
- Notifications: guarded cast timing validation against missing safe-number helpers during early load to prevent rare loading-screen errors.

## 2.0.4

### Fixed
- Notifications: improved Interrupt Alerts attribution so non-interruptible casts no longer trigger alerts at natural cast end.
- Notifications: restored cast-stop alerts for stuns/CC in restricted content by handling missing/secret cast timing safely.
- Notifications: added mouseover support for interrupt/cast-stop attribution.

## 2.0.3

### Fixed
- Notifications: fixed Delve taint errors caused by comparing secret/tainted `UnitName()` values during interrupt/cast-stop attribution.

## 2.0.2

### Added
- Notifications: added Interrupt Alerts (successful interrupts + cast-stopping CC) routed through Notifications with customizable templates.
- Notifications: new Interrupt Alerts sub-section under Alerts -> Notifications with shared style options (font override, color), routing, and optional sound.
- Notifications: added template code %s for your stopping ability name (Kick/Pummel/Storm Bolt/etc.).
- Notifications: added optional local chat output for successful interrupts (prints to your chat frame; does not use protected SendChatMessage).

### Fixed
- Notifications: hardened interrupt/cast-stop messaging against WoW 12.x secret-string restrictions (prevents taint/blocked actions when formatting or outputting text).

## 2.0.1

### Fixed
- Profiles: fixed newly created profiles not persisting between sessions (profiles created via the Profiles UI now save correctly and remain after relog).

## 2.0.0

### Added
- Incoming/Outgoing: added split critical hit configuration blocks per stream and kind:
  - Incoming Crit Damage
  - Incoming Crit Heals
  - Outgoing Crit Damage
  - Outgoing Crit Heals
- Incoming/Outgoing: added per-stream + per-kind crit font override controls embedded directly in each crit block.

### Changed
- Incoming UI: moved Incoming "Color Settings" to the top of Incoming Damage for a more streamlined layout.
- Crits UI: consolidated crit configuration into the new split blocks and removed standalone crit font override sections from view.
- Incoming UI: hid legacy per-category incoming "Crit Scroll Area (optional)" dropdowns to avoid duplicate routing controls (runtime fallback remains).
- Help/Support: renamed the config tab label from "Maintenance" to "Help and Support".

### Fixed
- Outgoing: improved outgoing crit detection from combat log chat messages (detects "crits" / "critically" / "critical").
- Display: fixed a nil indexing error in crit font resolution (`ResolveCritFont`) when resolving outgoing crit fonts.
- UI: fixed crit font override gating so dependent controls (face/size/etc.) are hidden unless the override toggle is enabled.
- UI (Spam Control / Rules Managers): fixed inconsistent window title coloring and prevented custom button skinning so buttons remain Blizzard-style.

## 1.2.22

### Fixed
- Profiles: fixed ZSBT preset profile actions appearing in other addons' AceDBOptions "Profiles" tabs by isolating (cloning/wrapping) the AceDBOptions profiles options table before customization.
- Cooldowns: prevented errors in cooldown tracking (e.g. Taunt) by avoiding passing secret/tainted values into `Cooldown:SetCooldown`.

## 1.2.21

### Added
- Outgoing (Spell Rules): generic per-spell aggregation now supports spell rules with aggregation enabled (not Whirlwind-specific).

### Changed
- Outgoing (Spell Rules): aggregation can now use open-world rawPipe numeric values as a fallback when evt.amount is unavailable, improving compatibility for some periodic/multi-hit spells.
- Outgoing (Spell Rules): when Similar Hits is enabled, aggregated groups now split crits and non-crits into separate lines so crit styling/routing remains accurate.

## 1.2.20

### Fixed
- Outgoing (Warlock): improved reliability of Shadow Bolt / non-physical outgoing damage display in WoW 12.x Midnight by reducing over-filtering in the UNIT_COMBAT(target) fallback path.
- Outgoing (Warlock): Drain Life periodic damage ticks now emit as outgoing damage events per tick for better visibility.
- Pets: when pet outgoing is disabled, pet tracking is fully disabled (no pet raw-pipe consumption or pet debug spam).

### Changed
- Combat Text (Midnight): COMBAT_TEXT_UPDATE payload parsing now treats the spellId hint as optional and only trusts numeric values, improving compatibility across clients where payload slots vary.

## 1.2.19

### Fixed
- Outgoing (Whirlwind): fixed missing/incorrect crit output when using Whirlwind aggregation by splitting aggregated normal hits and crits into separate lines.
- Outgoing (Whirlwind): reduced false "crit-like" inference in the UNIT_COMBAT fallback path (prevents inflated crit aggregates from small off-hand minima).

### Changed
- Outgoing (Whirlwind): when aggregation is enabled, crits and non-crits are aggregated separately so crit styling/routing remains accurate.

## 1.2.18

### Added
- Outgoing: added a toggle to turn off ZSBT outgoing output and use Blizzard Floating Combat Text for outgoing damage while keeping incoming suppressed.
- Slash commands: added `/zsbt dumpcvars` to print relevant Blizzard combat text CVars (including XP/world text scale probes).
- Similar hits in spell rules now you can show DMG(x1, 1crit) 

### Fixed
- Whirlwind spell ID changed because of course it did. Updated. 
- Blizzard Combat Text: fixed incoming heals leaking through when using Blizzard outgoing override by keeping CombatText routing suppressed while outgoing floating damage CVars are enabled.

### Changed
- Version metadata: updated addon version strings to stay consistent across `.toc` and UI surfaces.

## 1.2.17

### Added
- Spell Rules: added per-spell style overrides for outgoing text (font face, outline, size/scale, and color).
- Spell Rules: added per-spell aggregation controls (enable, window, show (xN)) for Whirlwind (1680).

### Changed
- Whirlwind: burst aggregation is now spell-rule-driven. If no Whirlwind spell rule exists (or aggregation is disabled), Whirlwind shows every hit (no aggregation).
- Spell Rules: outgoing spell rules (routing/throttle/style/aggregation) are stored per-character.

## 1.2.16

### Added
- General: added a Hide Minimap Button toggle to show/hide the minimap icon in real time.

### Fixed
- Minimap button: hide/show now also applies to third-party/LibDBIcon minimap button variants that wrap the ZSBT button.

## 1.2.15

### Changed
- PvP: tightened outgoing attribution when PvP Strict Mode is active to reduce battleground bleed-through.
- PvP: auto-attacks are now always suppressed while PvP Strict Mode is active.

### Fixed
- PvP: suppressed outgoing healing derived from UNIT_COMBAT("target") while PvP Strict Mode is active to prevent heal-colored outgoing noise from other players.

## 1.2.14

### Fixed
- Instances: fixed a crash in damage meter fallback polling where certain GUID sources could be returned as secret strings ("table index is secret"). Secret GUID sources are now skipped safely.

## 1.2.13

### Added
- Quick Control Bar: added a PvP dropdown menu with toggles for PvP Strict Mode and disabling the PvP auto-attack fallback.

### Changed
- PvP Strict Mode now defaults to enabled for new profiles.
- Existing profiles now receive the PvP Strict Mode defaults on upgrade, but only if the settings were previously unset (no overwrites).

### Fixed
- Quick Control Bar: Open World and PvP menus now clear dependent settings when the parent is disabled and keep the dropdown state in sync while open.
- Config UI: main configuration window now has a stable default size when no saved geometry exists.

## 1.2.12

### Added
- Added Trade Skill notifications (Skill Ups and Learned Recipes/Spells) routed through the Notifications system, with per-category scroll area routing and message templates.

## 1.2.11

### Added
- Added an optional outgoing crit sound trigger (damage + healing) integrated into Outgoing -> Outgoing Critical Hits.
- Added a minimum crit amount threshold for playing the crit sound.

### Changed
- Instances: crit sound now defaults to only triggering when the crit amount is safely known (to avoid secret-value issues).

## 1.2.9

### Fixed
- Fixed config UI tab content bleeding after committing text inputs (Enter) by preventing edit boxes from double-committing on subsequent focus loss/tab switches.

## 1.2.8

### Fixed
- Fixed cooldown tracking for newly-added tracked spells by initializing cooldown state/frames lazily when spells are observed.
- Fixed SPELL_USABLE triggers failing for cooldown-based edges by safely treating spells as unusable while on cooldown (without crashing on Blizzard "secret" number values).
- Fixed trigger debug output causing errors in AceConsole-based print paths by printing a single safe string.

## 1.2.7

### Fixed
- Fixed outgoing spell icons/names sticking to later unrelated outgoing ticks by tightening UNIT_COMBAT(target) correlation and periodic attribution.
- Fixed missing outgoing spell icons for UNIT_COMBAT-derived events by preserving `amountSource` through the pulse engine.

## 1.2.6

### Changed
- README: updated documentation links and added Quick Control Bar + tuning overview.

## 1.2.5

### Added
- Added Open-World tuning options to reduce incorrect outgoing attribution on shared targets, including a global "Quiet Outgoing When Idle" mode.
- Added an optional Quick Control Bar (General) with Instance/Open World dropdown menus and a scroll-area Unlock/Lock button for fast testing.

### Changed
- General tab: renamed "Experimental Tuning" section to "Open-World Tuning".
- Shipped defaults updated for dungeon/open-world tuning, with a selective migration that only fills unset keys for existing profiles.
- General tab: turning off parent toggles now clears dependent child toggles (both in the config UI and Quick Control Bar) to avoid hidden stale settings.

### Fixed
- Fixed outgoing damage leakage in follower dungeons/group instances while idle by tightening attribution gates on ambiguous outgoing sources.
- Quick Control Bar: fixed dropdown menu behavior and menu item enable/disable state.

## 1.2.4

### Fixed
- Packaging: CurseForge/packager now packages the addon folder as "ZSBT" (instead of versioned folder names) and excludes the .git directory.

## 1.2.3

### Changed
- Crit positioning: when crits are not routed to a dedicated crit scroll area, incoming crits now spawn offset to the left and outgoing crits offset to the right.
- Crit positioning: adjusted vertical placement for non-routed crits so they appear closer to the center of their corresponding scroll areas.

## 1.2.2

### Added
- Added Loot Alerts parity: separate notifications for Loot Items, Loot Money, and Loot Currency.
- Added Loot Alerts templates for loot items, money, and currency with template codes (%e/%a/%t).
- Added loot filtering options: quality exclusions, item allow/deny lists, always-show quest items, and optional show created/pushed items.

### Changed
- Notifications configuration: added a Loot Alerts subtree under Notifications for loot templates and filtering.

## 1.2.1

### Added
- Added optional experimental Damage Meter fallback for incoming damage in instances (General tab).
- Added optional Incoming crit routing overrides: Incoming Damage crits and Incoming Healing crits can be routed to a separate scroll area.
- Scroll Areas: Test Crit now also tests incoming heal crits and incoming damage crits.
- Added General documentation and in-game Help topic explaining Dungeon/Raid awareness and instance experimental toggles.

### Changed
- Incoming formatting: sanitized unsafe/tainted label fields so secret fragments never appear in incoming lines.
- Documentation and in-game Help updated to describe incoming crit routing, crit testing, and instance-aware outgoing options.

### Fixed
- Fixed crash when Damage Meter APIs return secret/tainted totals.
- Reduced incoming duplication by deduplicating across incoming detection pipelines.
- Suppressed/filtered secret combat text incoming damage/heal noise.
- Fixed crit (Pow) placement so large crits stay within scroll area bounds.

## 1.2.0

### Changed
- Parabola animation: added a fixed 0.8s fade-in and seeded initial on-curve position to prevent lateral pop-in.
- Parabola animation: down-scroll direction now renders inside the scroll area bounds.

### Fixed
- Fixed Parabola Down anchoring/placement so down-scrolling parabola does not spawn above the scroll area.

## 1.1.11

### Added
- Added configurable crit color under Outgoing -> Outgoing Critical Hits (applies when crit routing is enabled).
- Added configurable colors for outgoing pet damage, incoming pet healing, and incoming pet damage (including crit colors).
- Added Incoming Pet Damage stream with its own toggle, routing scroll area, and minimum threshold.

### Changed
- Pets tab labels now distinguish outgoing pet damage vs incoming pet healing/damage.

### Fixed
- Fixed incoming pet damage being misclassified and displayed using healing-style coloring.

## 1.1.10

### Added
- Added a Triggers tab button to restore shipped UT announcer preset triggers without resetting the full profile.

### Fixed
- Fixed shipped UT announcer preset triggers reappearing after deletion; deletions are now remembered.
- Fixed main /zsbt config window briefly snapping back to a default size during Triggers refresh (remove/restore).

## 1.1.9

### Added
- Added per-category routing for Notifications so you can send loot/progress/auras/etc. to a chosen scroll area.

### Changed
- Notifications tab now points you to the Cooldowns and Triggers tabs for routing those features (to avoid conflicting routing controls).
- Scroll areas can now be moved farther and resized narrower.

### Fixed
- Fixed scroll area deletion confirmation popup errors.
- Fixed aura/buff notifications routing so both gains and fades honor the configured Notifications routing.

## 1.1.8

### Added
- Added an in-game Help section with topic tree and optional popup window for reference while configuring.
- Added Combat Log Settings documentation and in-game Help topic for configuring required filters for fallback detection.

### Changed
- Main /zsbt configuration window now remembers its last size (per character).

### Fixed
- Fixed help popup resizing compatibility issues on clients missing certain resize APIs.
- Fixed a UI config syntax error.
- Improved reliability of the Combat Log / Chat Settings helper button.

## 1.1.7

### Added
- Shipped preset profiles: Pet Class, Melee, Tank, Healer, Ranged.
- Preset reset buttons in the DB Profiles tab to restore shipped preset layouts.

### Changed
- Presets now include a dedicated Crits scroll area (sticky crits) using Porky font at 1.5 scale and Pow crit animation.

### Fixed
- Fixed an error when removing a tracked cooldown due to a missing confirmation popup dialog.

## 1.1.6

### Added
- Expanded documentation with step-by-step setup and examples.
- Added Notifications documentation.

### Changed
- Updated Getting Started, Outgoing, Diagnostics, Triggers, Spam Control, and Media docs for current features and workflows.

## 1.1.5

### Fixed
- Outgoing DoT/periodic damage ticks (e.g. warlock Agony) now display in the Outgoing scroll area.

## 1.1.4

### Fixed
- Incoming healing now respects the configured Number Format consistently (including merged incoming heal ticks).

## 1.1.3

### Added
- Added a new Notifications tab for managing what types of messages can emit to the Notifications scroll area.
- Added per-category notification toggles (default all enabled): combat state, progress (XP/Honor/Reputation), loot/money, cooldown ready, auras, power full, procs/reactives, and custom triggers.

## 1.1.2

### Fixed
- Minimap button icon now reliably loads bundled addon textures by texture path (instead of depending on GetFileIDFromPath behavior).
- Disabled circular mask clipping for the minimap icon to avoid a solid-white icon on some clients.

## 1.1.1

### Fixed
- Pet damage display now works in environments where UNIT_COMBAT("pet") does not fire by attributing UNIT_COMBAT("target") WOUND events to your pet when appropriate.
- Added additional pet damage fallbacks for combat log chat variants.
- Hardened pet damage/healing routing to fall back safely if a configured scroll area is missing.

## 1.1.0

### Added
- Added pet healing display support (e.g. Mend Pet ticks) using UNIT_COMBAT("pet", action=HEAL) for 12.x compatibility.
- Added optional pet healing routing controls (Pets tab): when enabled, pet healing can be routed to a dedicated scroll area with its own threshold.
- Added support for pet spell cast triggers: SPELLCAST_SUCCEEDED can now fire for pet casts (e.g. Growl).
- Registered bundled Growl sound with LibSharedMedia (ZSBT: Growl).

## 1.0.9

### Fixed
- Outgoing scroll area routing now honors the Outgoing tab scroll area selection regardless of Spell Rules routing defaults.
- Adjusted the minimap icon and gave it a consistent border for Asur. Because he's special.

## 1.0.8

### Added
- Added "Dungeon/Raid Aware Outgoing" option (General tab). When enabled, ZSBT restricts outgoing detection in dungeons/raids to avoid showing group/raid target activity as your outgoing.

### Changed
- "Dungeon/Raid Aware Outgoing" now ships enabled by default for new profiles.
- In dungeons/raids with dungeon-aware outgoing enabled:
  - Outgoing derived from UNIT_HEALTH(target/mouseover) deltas is suppressed.
  - UNIT_COMBAT(target) outgoing is only shown when strongly attributable to a recent player cast (reduced mis-attribution).
- Minimap button updated to a Blizzard-style round button with gold border.

### Fixed
- Buff gain notifications (e.g. +Enrage, +Shield Wall) now still display when aura spellId is unavailable/secret in 12.x combat.

## 1.0.7

### Changed
- Low Health warning sound now triggers based on Blizzard's built-in low health warning border (LowHealthFrame) instead of a configurable health percentage threshold.
- Removed Low Health (%) and Low Mana (%) warning sliders from the General tab.
- Removed Low Mana warning system and LOW_MANA trigger type.

### Fixed
- Fixed default configuration table syntax regression in Defaults.lua.

## 1.0.6

### Added
- Added backup/restore for Blizzard Floating Combat Text CVars when using "Suppress All Blizzard Combat Text".
- Added one-time prompt to restore Blizzard combat text if ZSBT detects CVars are still suppressed.
- Added manual restore tools: General -> "Restore Blizzard Combat Text Now" button and `/zsbt restorefct`.

### Changed
- "Suppress All Blizzard Combat Text" now includes clear UI instructions/warnings about CVars persisting after disable/uninstall.

## 1.0.5

### Fixed
- Outgoing healing now uses `UNIT_COMBAT(target, action=HEAL)` as a 12.0-compatible amount feed.
- Prevented bogus `UNIT_COMBAT(target)` WOUND values from non-attackable targets (e.g. healing dummies) from being attributed as outgoing damage.
- Hardened outgoing amount display so non-numeric tokens (e.g. literal `"heal"`) do not render as amounts.

## 1.0.4

### Added
- Added option to turn disable Notification Scroll Area in General section
- Large-number formatting options for incoming/outgoing damage and healing (General -> Numbers -> Number Format).

### Changed
- UI theme updates:
  - Accent color adjusted to Blizzard yellow.
  - Navigation labels updated to match.
- General -> Numbers section now includes help text explaining what Number Format affects.
- General tab now shows the addon version only in the main window title (removed duplicate version strings).
- Scroll Areas unlock overlays now refresh automatically when switching AceDB profiles.
- Cooldowns tab now uses manual Spell ID / Name entry only (removed drag/drop overlay).
- Default for "Suppress Training Dummy Internal Damage" is now disabled.
- Main config window default open size increased.
- Minimap button resized and positioned to sit on the minimap outer edge.

## 1.0.1

### Added
- Tiered UT kill events `UT_KILL_1` through `UT_KILL_7` (capped at 7).
- Shipped UT preset trigger pack for `UT_KILL_1..UT_KILL_7` (text, sounds, styling).
- Player documentation pages under `Docs/` and linked from `README.md`.
- `CurseForge-Overview.txt` for easy copy/paste project description.

### Changed
- Trigger Editor Event Type dropdown updated to include `UT_KILL_1..UT_KILL_7`.
- UT preset seeding behavior updated:
  - Seeds once per character.
  - Does not overwrite existing triggers.
  - Does not re-add presets after you delete them.
- Addon metadata updated for current Retail interface version.

## 1.0.0

Initial release.

### Added
- Multiple configurable scroll areas for incoming, outgoing, and notification text.
- Animation styles including Parabola, Fireworks, Waterfall, Straight, and Static.
- Outgoing spell icons and safe fallbacks for incoming/outgoing display.
- Spam control features including AoE hit condensing (merge buffer) and thresholds.
- Low health and low mana warnings with configurable thresholds.
- Cooldown ready alerts with configurable message format and sound.
- Custom Triggers system:
  - Fire notifications from common events.
  - Configure text, colors, sounds, sticky styling, and per-trigger font overrides.
- Media controls:
  - Sound selection via shared media dropdowns.
  - Support for registering custom fonts and sounds.
- UT-style multi-kill announcer:
  - Tiered events UT_KILL_1 through UT_KILL_7.
  - Ships with preset trigger pack (text, sounds, styling) that can be customized.

### Notes
- Built to behave safely under modern "secret value" restrictions in group content.
