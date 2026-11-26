# Changelog

## 4.0.8

### Added
- **UT kill announcer: real kill-credit and death-witness events** — the announcer now listens for `PARTY_KILL` (attacker/victim GUIDs), `UNIT_DIED` (dead unit's GUID), and `PLAYER_PVP_KILLS_CHANGED` (honorable-kill credit — PvP kills covered). Multi-signal dedup keys each kill by GUID and name so PARTY_KILL + UNIT_DIED + chat witnesses announce once.
- **Kill witnesses for clients that clear the target instantly on death:** a gated target-clear (GUID identity + recent hit) arms a short candidate confirmed by a witness — `UNIT_DIED` on the same GUID, or a "X dies" chat line naming it — and untargeted kills (dot/pet finishes) announce when the dead unit's GUID or name matches your last victim. `/zsbt utprobe` and `/zsbt uttrace` diagnostics added.

### Fixed
- **UT announcer no longer fires on target switching:** the old "recent damage + lost target" inference announced every tab-cycle in combat — including switching away from a living victim with the same name as a dead pack-mate. The cleared unit now must be corroborated as actually dead (witness, dead tick, or GUID death event); identity is decided by GUID with names as fallback, and a stale name/GUID pair can no longer mislabel a kill (names resolve through an atomic guid-to-name map).
- Possibly-secret boolean returns in the announcer (`UnitExists`, `UnitIsDeadOrGhost`, `UnitAffectingCombat`) are normalized safely — comparisons moved inside pcall so restricted values degrade to false/nil instead of raising errors.

## 4.0.7

### Added
- **In-game User Guide** — a new "User Guide" page in the `/zsbt` sidebar (between Class and Help and Support) with the full guide as navigable topics: Getting Started, Quick Setup, General, Scroll Areas, Combat Text, Crits, Spam Control, Alerts, Resources & Class Page, Profiles, and Midnight Limits & Troubleshooting. Sub-sections appear as child topics, and every topic can be opened in a separate window with Open In Window.

### Fixed
- **Blizzard FCT partial suppression no longer stomps user settings:** with any suppress mode besides "all", unhidden categories were rewritten to `1` on every login/reload/zone/regen — re-enabling floating combat text the user had turned off in game options. Hidden categories are still forced off; shown categories now restore only the CVar's pre-suppression backup value, and only when ZSBT was the one that zeroed it (tracked per-CVar in the FCT state). Categories ZSBT never touched are left alone. Same rule applies to the `enableCombatText`/`enableFloatingCombatText` master toggles.

## 4.0.6

### Added
- **Buff Tracking / Debuff Tracking leaves under Alerts → Notifications** — each gets its own Enabled, Route To, per-category Style (Color, Font Override), Show-Gains/Fades-Without-Rules toggles, and a button to its rules manager. Aura notifications now flow through real `buffs`/`debuffs` categories with independent routing, colors, and fonts.
- **Debuff Rules Manager** — a fully separate window from Buff Rules Manager, with its own Recently Seen Debuffs list, its own `debuffRules` table, and harm-aware matching (buff rules can't suppress debuffs and vice versa). Opens from the Debuff Tracking leaf.
- **Icons on aura notifications** — buff/debuff gains and fades render the spell icon again, resolved from the emit's spellID (secret spellIDs still resolve via the existing cast-match/recast paths).

### Changed
- **Aura rules simplified to Enabled / Hide Gain / Hide Fade** — per-rule scroll-area and throttle options removed; they could never apply to secret-named auras in combat anyway, so the rule surface now shows only what can actually execute. Per-rule sounds are likewise impossible (Blizzard blocks every secret→Lua channel — verified live), so sound controls were removed from the tracking leaves rather than left as dead UI.
- **Split the `auras` notification category** into `buffs` and `debuffs` (migration `auraCategories_v1` copies existing settings to both).

### Fixed
- **Disabled aura rules now revert to default behavior** — unchecking Enabled on a rule treats it as nonexistent (was: it suppressed the aura outright — inverted semantics on both the readable and secret paths).
- **Self-buffs flagged `Aura is Debuff`** (Fel Armor, Necrotic Wave, Stagger-style damage-delay/heal-absorb trackers) correctly classify as debuffs — Blizzard's polarity flag reflects the mechanical effect, so they live in Debuff Tracking / Debuff Rules where they can be hidden by rule.
- **Aura-category settings migrate correctly** — `notificationsPerType` deep-copied so buffs and debuffs don't share the same style/sound tables.

## 4.0.5

### Fixed
- **Allocation churn in group combat:** several hot paths built throwaway objects every event — closures inside the per-frame text updater and the per-wound `UNIT_COMBAT` handler, `pcall(function() ... end)` wrappers around secret-value compares, `("..."):format(...)` strings built before gated loggers that discard them, and `"sid@at"` string keys rebuilt and re-parsed on the off-target cleave scan. All are now hoisted, lazy, or restructured; unit-aura polling also coalesces to 50ms per unit. Large pulls no longer pile up Lua garbage for the garbage collector to sweep mid-fight — the periodic pause that read as a freeze on slower machines.

### Added
- **ZSBT User Guide** ships with the addon — a plain-language walkthrough of the settings window and how attribution works.

## 4.0.4

### Fixed
- **Combat-log filter nag loop:** when the `ZBattleText` filter check failed, the warning dialog re-showed every 30s and its "Later" button did nothing — on clients where the applied filter only refreshes at process start, the popup could never be satisfied without a full restart. The verifier now tries to heal the filter silently first (re-select, or rebuild-and-reapply on corruption); only repeated failures earn a single once-per-session dialog offering "Reload UI", which also self-closes if a heal later succeeds.
- **Respect manual filter choice:** switching the combat log to a different filter via the quick buttons is read as deliberate intent — no re-select, no dialog, one quiet chat reminder. Clicking back to `ZBattleText` (or `/reload`) restores normal protection.
- **`Verify` no longer fires during addon load** before saved filters are restored, and its v2 corruption check now covers source-part changes so those rebuild instead of escalating.

### Added
- **`/zsbt filter` test surface:** status now reports the session flags (`away`, heal attempts/rebuilds, popup state); `clear`, `away`, and `attempts <n>` subcommands exercise the heal paths without needing `/run` access to addon internals.

## 4.0.3

### Fixed
- **Shapeshift freeze:** `SPELLS_CHANGED` (fired by form swaps, stealth, possess) triggered a full ~40ms spellbook rescan inside the same frame. Rescans now defer while in combat (regen re-triggers) and run chunked across frames at ~4ms per slice. The book is a knowledge layer, not fight-critical state — a transient swap no longer costs a visible hitch.

### Added
- **`/zsbt perf`:** opt-in performance tracing — times every event dispatcher, ticker, OnUpdate, and named hot span; `/zsbt perf report` dumps top consumers plus a >=8ms spike log. Also enables the existing perf debug channel so the `UI.*`/`PE.*` render spans light up under one flag.

## 4.0.2

### Fixed
- **Client stutter from the CT probe:** the combat-text diagnostic probe installed ~140 permanent hooks at addon load for every user, including on per-frame functions. Now lazily installed on first `/zsbt ctprobe` use only; normal users carry zero hook overhead. (Users on 4.0.1 must update — the hooks cannot be removed once installed.)

## 4.0.1

### Added
- **Warrior class module (Forever/Camelot):** the era kit — Rend and Deep Wound bleeds, Thunder Clap (physical on this client), Cleave budgets, ranged Shoot/Throw, and exclusions for shouts, stances, and utility casts.
- **Hunter class module (Forever/Camelot):** Serpent Sting, Black Arrow, Lacerate, Immolation Trap, and Volley dots; Multi-Shot budget; aspect/track/pet-utility exclusions.
- **Next-swing strike handling:** Heroic Strike and Raptor Strike (all ranks) no longer scroll a phantom "0" at the press — the client's empty report is dropped once per cast and the real hit claims the record on the swing.
- **Class page knowledge rows:** next-swing strikes, ranged kit, excluded casts, and pinned spell facts now render, book-scoped to what you've learned.

### Fixed
- **Heroic Strike showing "0" (Forever):** queuing a next-swing strike emits an empty damage report at the press instant; it claimed the cast record and scrolled as zero. Now dropped, and the real hit displays.
- **"0" returning after level-up (Forever):** the drop depended on finding a pending cast record — a level-up rescan could starve the pool. The last-cast stamp now proves the press independently.

## 4.0-Release

### Added
- **Hunter class module:** full spec coverage including Dark Ranger hero talents — Bleak Arrows, Black Arrow, Wailing Arrow — plus Beast Mastery pet mechanics (Kill Command strikes, Bloodshed bleeds, Wild Thrash, Stomp).
- **Demon Hunter class module:** Vengeance and Devourer coverage — Sigils, Fel Devastation channels, Voidfall meteor kit, Catastrophe, Spirit Bomb → Dark Matter procs, and per-cast claim budgets for the multi-hit AoE abilities.
- **Per-spell flight learning:** each damage cast learns its own cast-to-hit delay (a bounded EMA that arms after three proven claims) and only claims wounds inside that span — a wound can no longer steal a fresher record belonging to a different spell. This retires the "freshest record wins" theft class entirely.
- **Sustained ranged-family treatment:** auto-attack replacement shots (Bleak Arrows, Wailing Arrow) claim through a live family anchor plus a learned shot-flight window instead of colliding with same-school DoTs.
- **Pet-evidence veto:** a wound proven to be a pet hit — a pet-class combat line plus a pending pet cast record for a *different* spell — can never claim a player cast record. Player-cast/pet-execute abilities (Kill Command, Bloodshed) stay claimable via a new `petExecuted` declaration.
- **`mod.spellFacts`:** per-module fact table that pins school and role for spells the spellbook can't see — replaced, hidden, or triggered-only ids (Wailing Arrow, Catastrophe damage ticks, Meteor Shower).
- **Correlation audit tool** (`Tools/correlate.py`): pairs emits to combat-log wounds, reports right-name/misnamed/recall coverage per spell, and prints per-wound decision traces for debugging claim paths.

### Changed
- **Excluded casts no longer become "the last cast":** hidden applicator spells (e.g. Vengeance's Frailty — a ~1s invisible self-cast that never deals damage) can't hold the recency anchor, so recency, pin, and fallback claims can't borrow their name.
- **Pet-routed wounds claim pet lines only:** a pet route backed by a real pending pet record can no longer eat player-colored lines or lose its name to a coincident own hit.
- **Veto fall-through is consume-consistent:** a wound vetoed off a DoT anchor consumes the rival record it was vetoed for instead of wandering into a different claim path.
- **`/zsbt clearlearned` completeness:** now also wipes the proc-dot library, per-spell flight learns, and wand element votes — every learned store resets.
- **Learning-safety standard documented:** ten anti-poison invariants plus a new-module validation checklist (spellbook output must be diffed against live references; "log-verified" means checking event type *and* aura target).

### Fixed
- **Dark Ranger name swap:** Bleak Arrows' shadow wounds were feeding the Black Arrow DoT anchor (same school, debuff always up, matching cadence) and vice-versa — roughly forty misnames per fight down to single digits via a rival-cast veto and the shot/tick flight discriminator.
- **Physical wounds stealing ranged records:** the school check short-circuited for ranged-family ids, so Cobra Shot and melee hits emitted "Bleak Arrows" — physical is now unconditionally rejected for ranged families.
- **Instant record theft:** wounds landing the same frame as a cast could claim its record before the spell's real hit arrived (Kill Command records eaten at +0.0s) — a minimum claim-age floor now applies.
- **"Frailty" on every fire spell (Demon Hunter):** the id was registered as a DoT, but the spell only ever heals — its invisible applicator cast also flooded the claim pool once per second. Removed as a DoT and excluded as a cast; ~25 misnames per session eliminated.
- **"Set Fire to the Pain" mis-registered:** it is a self-stagger defensive (a fire DoT on the player), not an enemy DoT — removed from the dot table.
- **Spellbook school contamination:** tooltip verbs like "Fire a shot" (Barbed Shot) and possessives ("Nature's Ally") no longer pollute derived damage schools — a real bug that was rejecting legitimate physical wounds.
- **Correlate alignment:** pairing now prefers tight matches (fixes wrong clock offsets), and name-level matching separates "right spell, different id" from true misnames.

## 3.3.9.7-beta

### Added
- **Source-classed combat-log feed:** the attribution filter now tells apart *who* caused each event — your hits, your pet's hits, and five classes of foreign hits (friendly NPCs, hostile units, hostile players, neutral units, unknown). Follower-dungeon companions and co-attackers on your target are now positively identifiable instead of background noise, so the addon can prove a hit is **not** yours — something no battle-text addon could do on this client before.
- **Foreign-hit veto:** wounds that line up with a foreign-classed line are dropped as provably someone else's, so group and instance traffic from other attackers no longer leaks into your scroll.
- **Incoming Merging section (Spam Control):** incoming damage/heal bursts now have their own controls, separate from outgoing spell merging — an on/off toggle, a merge-window slider (0.05–2s), and a "Merged Hidden Amounts" style: **Last value xN** (default — shows the newest real amount, e.g. "1234 x3") or **Count only** (the old "Heals x3" style).
- **Attribution Delay slider:** the wound-to-line pairing window is now profile-tunable (0.05–0.50s) instead of a fixed 0.2s — lower feels snappier, higher catches lagging evidence.
- **Shaman class module:** Elemental and Enhancement coverage — strikes, the Totemic kit, Flame Shock spread and applicators (Ascendance, Voltaic Blaze, Stormkeeper's fire-elemental window), composite-school DoTs, and guardian handling for elementals and Feral Spirit wolves.
- **Druid class module:** all-spec coverage, including named physical bleed ticks (feral) and strict AoE application anchors for multi-mob DoTs.
- **Warlock guardian roster verified** against the client's own combat log: Mother of Chaos, Overlord, Imp Lord, and Gloomhound are mapped; the Antoran Jailer summon is correctly excluded.
- **On-attack proc naming:** procs that are guaranteed to ride a hit but have no cast record now get named from a proven physical-hit anchor instead of showing as generic hits.
- **Audit tooling:** `/zsbt auditmax <n>` tunes the audit ring size (default 8000), pet emits carry provenance markers, and physical-DoT decisions are traced for debugging.

### Changed
- **Instance/group gates now defer to line proof:** the old rule "in an instance another attacker is guaranteed, so unattributed hits are unprovable" no longer kills wounds when the source-classed feed is live — they queue for arbitration (your/pet lines prove them, foreign lines veto them). When the feed can't be trusted, the old strict dropping stays in place.
- **All pet and guardian damage goes through ownership arbitration:** non-physical pet hits (imp firebolts, dreadbites, guardian attacks) now pair against pet-colored lines instead of displaying unproven or dying upstream — previously only physical pet hits took that path.
- **Contested-target discipline:** when evidence shows a second attacker on your target, unattributed white hits and generics are refused rather than guessed — the detector is anchored to your own melee lines and auto-attack rhythm, and your own proven hits no longer accidentally arm it.
- **Merged outgoing lines prefer spell names:** merged hits with hidden amounts show the spell name when Outgoing → Show Spell Names is enabled, "Hits (xN)" otherwise.
- **Custom damage/heal color swatches are authoritative:** the split swatches now win over the legacy single custom color; partial saves fall back per channel.
- **Trace flags are session-scoped:** `/zsbt audit` and `/zsbt ucdrop` no longer persist across reloads.

### Fixed
- **Follower-dungeon damage loss (the big one):** three hard-kill gates dropped unattributed wounds before the line machinery could prove them — which is exactly the hit profile pets, guardians, and AoE produce. Displayed damage roughly doubled in follower-dungeon testing with no foreign leakage.
- **Zero, "0", and "-0" spam:** the client's absorb-style zero-amount entries are now dropped — plain zeros directly, hidden-value zeros by C-side evaluation, and unevaluable hidden values via the school-0 signature those pseudo-entries carry. Real non-zero hits are unaffected.
- **Pet incoming shows real numbers:** damage taken by your pet renders actual values instead of zeros — damage shows as `-N`, heals as `+N`.
- **Heals stopped double-rendering:** outgoing heals no longer emit twice on self-resolving unit tokens, twin reports dedup by combat-log timestamp, and a first-hit duplication gap is closed.
- **Phantom "second tick" heals:** outgoing heal candidacy now requires a readable HEAL action — periodic damage-class events that used to queue as fake heals are rejected.
- **Off-target DoT identity leak and bleed pick gate:** ticks on other mobs attribute to their own application records, and a gate bug that misnamed bleeds is fixed.
- **Pet-melee guesses can't claim spell lines:** unattributed pet melee can no longer borrow direct/tick line evidence.
- **Protected-call crash under combat lockdown:** spell pickups that could fire during lockdown are now guarded.
- **Forever dedup:** the wound-twin signature now includes the amount, so two different same-instant hits on Era clients no longer collapse into one number.

## 3.3.9.6-beta

### Fixed
- **Enable/disable now hands combat text back to Blizzard live:** disabling ZSBT stopped our text but left Blizzard's floating combat text suppressed — CVars at 0, CombatText frames unregistered, `CombatText_AddMessage*` nulled — so a `/reload` was required to get Blizzard numbers back. `Core:Disable` now restores the suppressed FCT state (only when ZSBT actually suppressed it), and `Core:Enable` re-suppresses per your config — the master toggle works in both directions without a reload.
- **Master toggle dead call:** one of the "Enable ZSBT" toggles called `Core:SetEnabled`, which didn't exist — the flag flipped but nothing ran. `Core:SetEnabled` now exists and both toggles share one enable/disable path (minimap middle-click included).

## 3.3.9.5-beta

### Fixed
- **Outgoing HoT/direct-heal ticks now emit (Retail):** periodic heals (Rejuvenation, Regrowth, etc.) on friendly units were silently dropped — they arrive with tainted action strings and no aura API can verify ownership on Retail (auras are secret). Ownership now comes from the source-restricted filtered combat log: `SPELL_HEAL`/`SPELL_PERIODIC_HEAL` lines buffer in a separate ring and prove the heal is ours, with either-order UC/CLM pairing, per-line consumption dedup, cast-seeded naming, and a persisted learned-period EMA for cadence.
- **"Really long number" on heals:** secret heal/damage amounts passed through the raw pipe rendered at full float precision. Amounts now round before display — safe numbers via `math.floor`, secrets via the `:round()`/`:floor()` methods Retail secret userdata exposes (falling back to the raw passthrough if unavailable).
- **Forever: two same-time hits collapsing into one number.** The merge bucket exists for duplicate reports of a *single* cast, but every wound after the last cast shared one key — so Judgement + strike (different spells) and seal + weapon proc (different schools) merged to max and ate one hit. Wounds carrying a different spell identity, or a different school against an unnamed bucket, now emit separately.
- **Forever: swing-proven auto-attacks no longer starve.** A spell wound consuming the melee combat-log line left the real auto attack queued until drop (`AUDROP src=auto`). A `PLAYER_SWING`-proven hit is provenance equal to a consumed cast record — on Forever's incomplete feed it now emits line-free after the retry, same as spell-attributed hits already did.

## 3.3.9.4-beta

### Changed
- **Custom media now survives addon updates:** custom fonts/sounds registered via `Display → Media` default to `Interface\CustomMedia\Fonts\` and `Interface\CustomMedia\Sounds\` — a folder inside `Interface` next to `AddOns` that no addon manager manages, so files dropped there are never wiped by clean installs. Bare filenames resolve there automatically; any full `Interface\...` path is also accepted, so files can live anywhere. Bundled media in `ZSBT\Media` is unchanged.

## 3.3.9.3-beta

### Fixed
- **Blizzard combat-text restore rewritten (ownership-safe):** explicit restores — the "Restore Blizzard Combat Text Now" panic button, `/zsbt restorefct`, and the restore prompt — now revert *everything* ZSBT touches when no snapshot exists: every FCT CVar plus `WorldTextScale`/`WorldTextScreenY` (and `_v2` variants), CombatText frame registrations, `CombatText_AddMessage*` overrides, and the XP chat filter, each reset to the client-reported default via `GetCVarDefault`. Previously the no-backup path wrote a handful of hardcoded `"1"`s and never touched WorldText — leaving floating text permanently invisible after a reinstall or cleared SavedVariables.
- **Suppression no longer stomps user CVars:** the zone/regen re-apply path is now gated on `suppressedByZSBT`/backup state — if ZSBT never suppressed, your own Blizzard FCT settings are left untouched instead of being rewritten to `"1"` on every zone change and combat end.
- **Panic button actually works:** it now clears the master suppression toggle (previously the next zone change re-zeroed everything seconds later) and is always enabled — the no-backup defaults revert was previously unreachable in exactly the state you'd need it. `/zsbt restorefct` also clears suppression for the same reason.
- **Master CVar ordering:** `enableFloatingCombatText` removed from the outgoing/incoming category groups — a "show outgoing, hide incoming" config no longer leaves the master switch at `0` with nothing visible.
- **Orphan CVars managed:** `floatingCombatTextCombatState`, `floatingCombatTextFloatMode`, and `floatingCombatTextFriendlyHealers` now zero on hide-all and restore from backup on partial configs, instead of sticking wherever a previous suppress left them.
- **Restore prompt checks the live key** (`hideBlizzardFCT`), not the dead legacy `suppressBlizzardFCT` — it no longer fires while suppression is intentionally on.

### Added
- **Era pet spellbook discovery (Forever/Camelot):** the pet scan now accepts `PetAction` spellbook items (the client's actual shape) and unmasks action IDs to real spell IDs, with legacy `HasPetSpells`/`GetSpellBookItemInfo(i, "pet")` and `GetPetActionInfo` action-bar probes as pcall-guarded fallbacks. Pet verification lanes and pet spell icons now work on era clients.

### Changed
- **Era mutual veto for stolen DoT ticks:** when a recent cast blocks a surviving disambiguation pick on era clients, that cast can no longer claim the wound line-free either — the wound renders as a bare number instead of wearing a wrong spell name (e.g. a wand's "Shoot" on an Immolate tick). Retail travel-time nuke claims are unaffected.

## 3.3.9.2-beta

### Added
- **Signature matcher + persisted proc bindings:** hits that land unnamed inside a trigger window now claim the linked spell, and every claim feeds a persisted per-binding ledger (`n` claims, `w` windows, `rel` drift) written to the profile in instances and on demand. The learner accumulates real trigger-to-proc correlation instead of one-off guesses. `/zsbt clearlearned` wipes bindings and evidence for a cold start.
- **Learner evidence reporting (`/zsbt arep`):** end-of-fight report pairing each emitted line back to its wound — sid match / lost / changed / unverifiable counts, per-binding claim fidelity across cast/dot/channel/pet/generic lanes, and a pressure ledger of gate refusals. Evidence records migrate forward from older saves.
- **`/zsbt auditreport`:** end-to-end confidence metrics from the audit ring, persisted to `diagnostics.auditReport` so the numbers survive `/reload`.
- **Monotonic trace IDs:** every wound carries a unique `traceId` through the PulseEngine event rebuilds (replaces recycled pipe IDs), so `AUDRNDR` render lines correlate exactly to their claim — the backbone of `/arep`.
- **Talent-tree spellbook import:** selected talent nodes join the derived knowledge layer — `GetTreeNodes` enumeration, cast-to-talent sid pairs, trigger-to-proc links, and hero-tree provenance — feeding learner/spec context without claiming display. `/zsbt sb` dump got a copyable window, plus `/zsbt sb all`.
- **Channel ownership lane:** channels get their own evidence path — registry-seeded `_channel` records and a cadence pool — so channel ticks (Drain Life-style channels) claim and verify like dots.
- **Burst/merge engine rework:** unattributed same-signature bursts fan out from line-backed evidence keyed by hit signature so distinct hits can't collapse; pets whitelist companion schools; suppressed twin wounds park on the signature bucket for line-backed recovery; extra claims tighten to a per-event window.
- **Demon Hunter module (real, replacing the stub):** Vengeance spellbook verification pass, Frailty (`227255`) joins dots, Void Metamorphosis is transform-only (excluded rather than budgeted) with proper cast budgets, and Devourer module section. Stub modules for Monk/Paladin/Evoker now correctly fall back to no-module handling instead of pretending coverage.
- **Pet aggregation modes fixed:** "Spell Name" uses resolved pet-spell names, "None (Numbers Only)" shows bare numbers, and the dead summons-bucket path that forced a bare prefix is repaired — the dropdown actually does something now.
- **Composed crit animations:** crit animations (Stomp, Slam, Shockwave, Ignite, Chromatic, ScreenPunch, Shatter, Afterimage, Rumble) now play on top of the scroll area's motion instead of replacing it — a crit in a Parabola area travels the curve while the effect plays, and crits spread across normal lanes instead of stacking in the center. Pow keeps its classic centered-sticky behavior. New toggle: General > Crit Animations Ride Scroll Motion (default on; off restores centered crits).
- **Outgoing Pet Crits section (Crits page):** pet crits get the same per-stream crit options as incoming/outgoing — scroll-area routing, sticky + jiggle, and a full crit font override (face, size/scale, outline, all crit animations with intensity sliders). Pet crit color moved here from the pet damage settings; existing colors carry over.
- **Pet spell icons (opt-in):** Pets > Show Pet Spell Icons puts the pet's own spell icon next to pet damage (e.g. the imp's Firebolt). Merged pet lines only show an icon when every contributor shares the same spell.
- **Dual empower/proc icons (experimental):** Outgoing > Show Empowering Proc Icon renders the triggering cast's icon alongside the proc that empowered it, when the client can prove the proc's state. Degrades cleanly to a single icon on secret-value builds.
- **Warlock guardian naming:** Blighted Maw (`1276960`, school 40) joins named guardians.

### Changed
- **Pairing preference order:** wounds now claim their own line kind first — pet-route and swing-proven wounds reclaim melee lines, non-autos can claim ranged lines (wand Shoot was unpairable), impossible kinds are removed from the fallback rather than deprioritized.
- **Off-target DoT attribution:** nameplate wounds on other mobs attribute to that mob's own application record; AoE dots additionally fall back to spell-level anchoring, fixing multi-mob dot leakage.
- **DoT learning:** tick intervals only learn between hits on the same mob — cross-target gaps no longer corrupt cadence.
- **Merged outgoing lines honor Show Spell Names:** secret-amount merges no longer display a spell name unless Outgoing > Show Spell Names is enabled — they now read "Hits (xN)".
- **Module-declared exclusion lists:** `mod.exclude` denylists (e.g. Health Funnel) can never name enemy wounds.

### Fixed
- **Attribution honesty layer:** talent-node spell IDs can no longer claim wounds (they're modifiers, not damage events); proc claims require tooltip damage proof or a clean learned binding with no school drift; learned-binding score boosts stop self-reinforcing after drift is detected.
- **School-gate vetoes, four fixes:** line evidence is now exempt from the foreign-school veto; module-declared and spellbook-derived masks gate cast claims; a quiet feed is no longer treated as a dead feed so combat openers stop dying at intake.
- **Zero-damage casts:** casts that provably deal no damage can neither name wounds nor block DoT picks.
- **Secret-value crashes:** secret-string comparison crash in the dot per-target map and the attribution audit sink (Retail 12.x); audit ring now guards writes and skips tainted entries in `/arep`.
- **Pet render accounting:** pet lines with no verifiable identity count as `unverifiable` instead of falsely `lost`; `/arep` no longer crashes on learner records saved before that counter existed.
- **Spellbook parse accuracy:** talent enumeration via `GetTreeNodes` (the old `treeInfo.nodes` walk silently died), all tree grants counted, tooltip-header channel detection, clause-scoped dot gating, damage-taken rider vetoes scoped to their clause, resource-generation clauses no longer read as dots, and string-typed spell IDs coerced at the cast boundary.

## 3.3.9.1-Beta

### Added
- **Context-tiered outgoing strictness (auto-detected):** outgoing attribution now picks a strictness tier automatically — combat-log line pairing proves ownership whenever the feed is live, and conservative correlation only engages as a degraded-mode fallback when the feed goes quiet (permissive solo, restricted grouped/PvP). The old per-context toggle lattice is gone.
- **Outgoing Accuracy section:** General now has a dedicated tree group holding the three surviving policy toggles (Require Combat-Log Proof, Show Unproven in Groups, Relaxed in PvP) and the damage-meter fallbacks, with one "Outgoing" entry on the Quick Control Bar. Legacy keys migrate forward.
- **Styled page intros:** General, DB Profiles, Combat Text, Crits, and Alerts landing pages have sectioned, palette-colored descriptions of what each category controls — all locales carry the same structure.
- **Class page no-module notice:** classes without a module (most Era classes on Forever) show a static gold-bordered panel explaining that all damage still displays — visibility is never module-gated.
- **Forever feed-gap fallback:** on Camelot, spell/pet-proven hits that retry and still find no combat-log line display anyway — the feed omits whole spell classes (e.g. Judgement under Seal of the Crusader). Retail keeps strict pairing.
- **Module-less dot disambiguation on Forever:** spellbook-derived periodic spells run the cadence/amount disambiguation engine without a class module.

### Fixed
- **Fontstring clipping on the Class page:** shellFont pinned every label to one line, silently truncating multi-line status and notice text — now auto-sizes.
- **Forever school-field lies:** bogus UNIT_COMBAT school masks no longer kill proven player hits (era-exempt school checks; pet matching stays strict).
- **Audit tier stamping:** every target wound logs `AUDT tier=live|dead_*` so policy decisions are visible in the audit ring.

## 3.3.9-beta

### Added
- **Death Knight class module (all three specs, log-verified):** channels (Breath of Sindragosa), per-cast hit budgets, permanent ghoul handling for Unholy, guardian spellbook and summon windows (Dancing Rune Weapon, Rider of the Apocalypse horsemen, Summon Gargoyle, Army/Apocalypse), and disease/proc DoT coverage including Remorseless Winter's damage id.
- **Warrior class module:** Fury multi-strike budgets (Raging Blow family and empowered variants, dual-wield Execute MH+OH, Rampage), Whirlwind `190411`, Odyn's Fury four-cast pattern; Protection Thunder Blast and Whirlwind dual-cast handling; Ravager tick window via a debuff-gated classifier seeded from its cast.
- **Live spellbook-derived knowledge layer:** the addon now enumerates the player and pet spellbooks, resolves current spell IDs by name (self-healing across Midnight's re-ids), and parses descriptions for role (DoT/channel/cast), tick cadence, and damage-school masks — school names resolve through localized client strings. Module tables stay authoritative; derived knowledge only fills gaps. `/zsbt sb` dumps the derived view.
- **Teach-a-spell on the Class page:** drag a spell from your action bar or the new spellbook flyout (class + current-spec icon grid) onto the drop slot. Auto role inference guesses dot/channel/cast; entries the module already knows are flagged redundant; taught spells take precedence over derived knowledge.
- **School-colored module knowledge:** the Class page's knowledge list renders spell names in their damage-school color — the same palette as the scroll (honors `media.schoolColors`) — so masks like "school 36" read as shadowflame purple.

### Fixed
- **Foreign-school veto:** unattributed hits carrying a school the active class module cannot produce are provably foreign (follower/party damage on shared targets) and are dropped instead of displaying.
- **Succubus pet-routing:** the pet fallback no longer claims player shadow-school hits, and fire-bit pet claims now require an actual imp — Destruction's fire/chaos kit no longer lands in the pet scroll.
- **Pet-route integrity, three layers:** hits whose school no class minion can produce strip the pet route (the damage still shows as honest outgoing); a real player spell ID on a pet-routed payload strips it on both the immediate and deferred delivery paths; and player-spellbook IDs can no longer enter the pet-cast pool at all.
- **Channel school verification:** channel tick claims (Rain of Fire, Drain Life, Bladestorm, Rapid Fire, Breath of Sindragosa) now verify the wound's school — foreign ticks inside a channel window no longer wear the channel's name.
- **Per-pet-cast claim budgets:** single-target pet casts stop pulling same-school strays into the pet scroll.
- **Derived-knowledge guards:** summon/self-drain descriptions (Summon Infernal, Burning Rush) no longer seed DoT windows.
- **Warlock Affliction + Destruction coverage** from verified logs: Wither (`445468`), Rain of Fire's Midnight cast (`1214467`), Chaos Bolt's chromatic mask (`124`), Malevolence, Curse of the Satyr.
- Secret-string compare crash in the attribution audit sink.
- Teach-a-spell capture stores the true spell ID and restores the dragged action-bar slot.
- QCB class button now appears for any class with an active module.

## 3.3.8-beta

### Changed
- **ZCT combat core transplant:** the combat attribution pipeline is rebuilt on Zore's Combat Text internals (`ZSBT.ZCT`): collector -> combat-log line classification -> incoming/outgoing pairing -> normalized combat events -> bridge into ZSBT's existing display. Animations, fonts, scroll behavior, and formatting are unchanged.
- **The config shell is now the only UI:** `/zsbt` opens it directly. The classic AceConfig window and the `/zsbt zctui` alias are retired; `OpenConfig` forwards to the shell for stale callers.
- **Class-driven attribution modules:** per-class modules now declare hooks (pet schools, cast budgets, guardian windows, auto-attack vetoes, DoTs, channels). Warlock is the reference implementation; Hunter is fully implemented (pet melee vs auto-shot split, Kill Command, Dark Ranger guardian naming incl. Shadow Thrash); other classes fall back to safe generic attribution.

### Added
- **Icon Position option** (Incoming/Outgoing Damage): place the spell icon left or right of the text, shown when Show Spell Icons is enabled.
- **Class page toggles are capability-driven:** modules declare which toggles apply (e.g. Name Guardian Spells, Show Pet Melee Hits); classes without toggles get no class button.

### Fixed
- School colors: pet damage now honors Use School Colors, composite school masks (shadowflame, cosmic) resolve instead of falling back to white, and the custom `media.schoolColors` palette applies.
- Per-cast attribution budgets stop foreign misses/ticks inheriting the last cast's icon (Shadow Bolt miss spam fix).
- Travel-time casts (Hand of Gul'dan, Implosion, Demonbolt) claim their delayed hits instead of displaying generic numbers.
- Nil-call in the outgoing emit path that silently killed outgoing display.


### Fixed
- **Doubled dodge/parry/miss text:** `UNIT_COMBAT` fires once per unit token, so a miss on your target arrived as both `nameplateN` (remapped to target) and `target`, and each event emitted its own miss line. Non-damage actions now collapse same-action twins within 50ms before reaching the emit branches, matching the dedup damage already had.
- **Green outgoing numbers from mob self-heals:** `UNIT_COMBAT("target")` heals were emitted as outgoing regardless of who healed — mob HoTs (e.g. Owlbeast Regrowth) displayed as green outgoing text, doubled by the same token duplication. Heals on attackable (hostile) units are now suppressed since players cannot heal them; heals on friendly targets are unaffected.

## 3.3.6

### Fixed
- **Outgoing damage/pet damage stopped scrolling while idle:** a silent group-instance gate dropped `UNIT_COMBAT("target")` hits unless the player had cast within ~0.9s, so opener follow-up, DoT ticks and pet/minion damage vanished until the next attack (and only in group content — which is why a group member pulling "fixed" it). The gate is now bypassed while the trusted RGB combat-log veto is live; ownership is still proven by the palette line before anything displays.
- **Quiet/strict outgoing modes no longer starve unattributed hits:** `quietOutgoingWhenIdle`, `strictOutgoingCombatLogOnly` and related correlation windows required a recent player cast (~1.25s), which pet and DoT damage can never satisfy. All five drop sites now bypass when the combat-log veto is active.
- **Off-target fallback for targets that never report `UNIT_COMBAT`:** hostile `nameplateN`/`softenemy` WOUNDS now emit as unattributed candidates, but only while the resolved target has produced no WOUND for ~1.5s — sessions where Retail simply doesn't fire target-token events still show pet/cleave damage, while normal fights produce no extra candidates and foreign hits can't pair.
- **Incoming damage invisible while heals/misses worked:** secret (tainted) damage amounts were dropped twice — once in `Incoming_Probe` and again when building display text (heals were explicitly exempted both times, which is why only they rendered). Secret damage now flows through the raw pipe to `SetText` exactly like heals.
- **Whirlwind missing/unattributed:** Retail fires Whirlwind casts as a `199658`+`1680` pair; `199658` is now recognized everywhere (cast attribution, spell-rule lookups, aggregation checks, `Outgoing_Probe`). Spell rules keyed to any Whirlwind ID now match regardless of which ID the client reports.
- **Whirlwind aggregation swallowed every hit on secret-value clients:** the aggregator required a summable numeric amount, but Retail amounts are secret — the push no-oped while the caller still dropped the hit. Aggregation now only engages for readable amounts; secret hits display individually (per-hit numbers, rule formatting still applied).
- **Player casts recorded as pet casts:** `targettarget` resolves to the player when the mob is attacking you, so your own casts were logged into pet-cast tracking and could misroute damage styling. Player-alias tokens are now excluded via `UnitIsUnit(unit, "player")`.

## 3.3.5

### Changed
- **Warlock pet-attribution rules reverted:** the 3.3 additions that kept shadow-school (32) hits attributed to the player unless the last cast was a hardcoded warlock nuke/DoT ID list, plus the warlock physical-hit auto-attack exception, are removed. `UNIT_COMBAT` has no source attribution on Midnight, and the ID-list approach broke on clients reporting classic rank spell IDs (e.g. Forever's Shadow Bolt = 705) — nukes were claimed by the pet fallback and hidden. Warlock pet signatures are back to Imp-fire (4) only; the generic pet-eligibility gate, `petMayOwnHit` auto-attack fix, and all dedup/hardening from 3.3 remain.

### Fixed
- Missing locale strings: 57 `L[]` keys used by the config shell, miss-subtype toggles, and resource tracker had no definition in any locale (enUS included) and displayed as raw English keys. Added enUS entries plus translations for deDE, esES, frFR, itIT, koKR, ptBR, and ruRU; zhCN falls back to English pending translation. Also filled the 15 DK rune-tracker keys that only existed in enUS.

## 3.3.4

### Added
- **Resource Tracker** (from 3.5.3, with the 3.5.6 rework): Alerts > Notifications > Resource Tracker adds freely-positionable resource counters (diamond pips or fraction/number text) with drag-to-move and corner-resize while unlocked, looping Ignite/Chromatic/Shatter/Afterimage effects and a rising-edge sound while a resource sits at max, per-counter font overrides, and a gold border in unlock mode.
- One independently-configured counter per resource, a DK rune tracker with selectable rune shapes, seconds-remaining text and hide-when-ready, and filtering of resources Retail marks secret (`C_Secrets.ShouldUnitPowerBeSecret`).
- Resource Full notification: per-resource opt-in with a customizable template (`%e` = resource name). Replaces the single global Power Full notification.
- The config options table is rebuilt each time the window opens so class-dependent options (such as the Runes button) are present without a reload; the DB Profiles tab is preserved across the rebuild.
- Aura notifications no longer go silent in combat on secret-value clients: `SPELL_AURA_*` combat-text notices now act as a fallback when `UNIT_AURA` payloads are unreadable, deduplicated against readable aura updates.
- Buff refresh re-notification: recasting a buff that keeps the same aura instance now re-shows its gain when `expirationTime` jumps forward.
- Recast pairing: a cast of a known self-buff within 0.5s of an unreadable aura update re-shows the buff's cached name/icon.
- `C_Secrets` per-index/per-instance predicates refine secret-aura gating (skips individual secret auras instead of all-or-nothing where the client supports it).
- Name-keyed aura rules (`"name:X"` in `auraRules`) match every rank of an aura by name when no spellID rule exists.
- Aura notifications can carry spell icons via `meta.spellIcon`.

- **WoW Forever XP notifications:** the progress tracker now parses Forever's `"<creature> dies, you gain N experience."` chat format, so the `+N XP` notification fires correctly on Forever alongside Retail's existing formats.
- **XP CVar coverage:** `floatingCombatTextXPChanges`/`_v2` added to the Blizzard FCT suppression lists so Retail's XP-change text follows the XP suppression toggle.
- **XP chat filter:** a `CHAT_MSG_COMBAT_XP_GAIN` chat filter hides the XP line (and, on clients where the popup is spawned by that display path, the popup) while XP suppression is on. ZSBT's own XP notification still fires.

### Changed
- **New navigation shell is now the default UI (from 4.1):** bare `/zsbt` and the minimap button open a left-sidebar shell. The classic AceConfig UI is unchanged and still available via `/zsbt classic`.
- **Settings reorganization in the shell:** General is split into System, Master Font, Numbers and Media; crit settings moved onto a dedicated Crits page; Resources and Scroll Areas get their own pages; Combat Text and Alerts pages have introductions. The Dungeon/Raid, PvP and Open-World tuning options remain on the General page.
- **DB Profiles in the shell and on rebuild:** the AceDB profile manager is re-attached whenever the options tree is rebuilt, so it renders in the shell and after reopening the classic window.
- **Misses are configurable per subtype:** dodge, parry, block, evade, miss, immune, resist (plus absorb, reflect, deflect) can be hidden individually, with their own scroll area and color under Incoming/Outgoing Misses.
- **Merge Critical Hits:** new toggle under Spam Control (`spamControl.merging.mergeCrits`, default off). When enabled, crits merge under a separate key so they never combine with non-crit hits and keep crit styling on the rollup.
- **World-text suppression:** when all Blizzard text categories are hidden, ZSBT now inflates `WorldTextScale`/`_v2` to `1000` (flinging world text off-screen) instead of shrinking it. Values still snapshot/restore with the FCT backup.

### Fixed
- Outgoing misses, immunes, dodges, parries, blocks, absorbs, deflects, reflects and evades now display when "Show Misses" is enabled. The `UNIT_COMBAT(target)` path returned for every non-hit action; it now emits the dedicated `OUTGOING_MISS_COMBAT` event (from 3.4.4/3.5.5), which routes to the miss kind and the configured Outgoing scroll area. In restricted mode a miss still needs a recent cast of yours to show.
- Duplicate aura gain notifications: recast pairing, watched-presence rules, and refresh re-notifies now stamp the aura-read timestamp so the combat-text fallback can't double-emit (e.g. two `+Buff` for one cast).
- Crash (`attempted to index a table that cannot be indexed with secret keys`) when auras report secret `auraInstanceID` (e.g. toys like Essence of Yu'lon). Such auras are now skipped in `ScanPlayerAuras`.

- **Resource counters after login/logout:** delayed refreshes now run at 0.5s, 2s, and 5s after initialization instead of a single early read, so counters recover on their own when power/max-power data isn't ready at first pass.

### Removed
- **RESOURCE_THRESHOLD trigger:** removed from the Event Type dropdown and in-addon help. The event path was never wired up and every offered resource is secret on Retail 12.x, so it could never fire. Existing saved triggers of this type remain but are inert.

## 3.3.3

### Fixed
- Cleans up combat-log filters left behind by newer builds. ZSBT 3.4-3.6 and 4.x installed a "ZSBT" filter, and the embedded ZCT a "ZCT" filter, into `Blizzard_CombatLog_Filters` and made it active, which restricted the combat log to self and pet lines. On login this version removes both and resets the active filter if it pointed at one of them. The "ZCT" filter is left alone while the standalone ZCT addon is loaded.

## 3.3.2

### Added
- Full UI localization restored on the 3.3 codebase (from 3.5.0): menus, tabs, options, tooltips, dialogs and slash-command output route through AceLocale. Eight locale files: `deDE`, `esES`, `frFR`, `itIT`, `ptBR`, `ruRU`, `zhCN`, `koKR`; missing keys fall back to English.
- Active locale shown in the login message and at the top of the Help tab.
- `Locales/ForceLocale.lua` test hook (disabled by default via a commented .toc entry).

## 3.3.1

### Changed
- Rolled back to the 3.3 codebase. The embedded ZCT combat framework introduced after 3.3 (releases 4.0.0 through 4.1.3) has been removed from the main line pending further testing. No other changes from 3.3.

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
- Added Loot Alerts: separate notifications for Loot Items, Loot Money, and Loot Currency.
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
