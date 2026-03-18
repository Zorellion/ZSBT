# Changelog

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
- Added MSBT-style Loot Alerts parity: separate notifications for Loot Items, Loot Money, and Loot Currency.
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
