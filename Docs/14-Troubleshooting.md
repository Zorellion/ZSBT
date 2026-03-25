# Troubleshooting

If something feels “off”, start here.

## Quick checklist (30 seconds)
- Confirm the addon is enabled: `/zsbt` -> `General` -> `Enabled`
- Confirm you have at least one visible scroll area enabled: `/zsbt` -> `Scroll Areas`
- If `Combat Only` is enabled, you will see very little out of combat
- Lower thresholds temporarily to confirm output is working
- Type `/reload`

## Nothing shows
- **Enable ZSBT**
  - `/zsbt` -> `General` -> `Enabled`
- **Enable a scroll area**
  - `/zsbt` -> `Scroll Areas`
  - Ensure `Incoming`, `Outgoing`, and/or `Notifications` are enabled
- **Combat-only settings**
  - If `Combat Only` is enabled, test by hitting a target dummy or mob
- **Thresholds**
  - If minimum thresholds are high, smaller events will be hidden
  - Temporarily set thresholds low to confirm messages appear
- **Reload**
  - `/reload`

## Icons/names missing (or wrong)
ZSBT tries to show spell icons/names only when it can do so reliably.

- **Check options**
  - Ensure `Show Spell Icons` and/or `Show Spell Names` are enabled
- **Instance/group content note**
  - In dungeons/raids, some combat signals are more ambiguous
  - You may see fewer icons/names because ZSBT prefers correctness over guessing
- **If something is consistently wrong**
  - If you can reproduce it on the same spell every time, report it (see Bug Report)

## Too much spam
- **Spam Control**
  - `/zsbt` -> `Spam Control`
  - Enable merging to condense rapid hits
  - Raise thresholds gradually until only meaningful events show
- **Scroll Area tuning**
  - Reduce `Max Messages` (if present)
  - Increase scroll area height so lines have room

## Triggers/cooldowns not firing
If a trigger or cooldown alert doesn’t fire, the issue is usually one of these:

- **Feature disabled**
  - Ensure the Triggers/Cooldowns system is enabled
  - Ensure the specific trigger/cooldown entry is enabled
- **Routed to the wrong place**
  - Route to a visible scroll area (usually `Notifications`)
- **Wrong SpellID**
  - Verify the spell ID and test with a known ability
- **Event expectations**
  - Some trigger types fire only on a state change (example: “became usable”)

## Custom media not showing
If custom fonts or sounds don’t appear in dropdowns:

- **Reload is required**
  - `/reload`
- **Fonts**
  - Format: `.ttf`
  - Path: `Media/Fonts/`
  - When registering, use the filename without extension
- **Sounds**
  - Format: `.ogg`
  - Path: `Media/Sounds/`
  - When registering, use the filename without extension

## Limits (what’s expected)
These are common reports that can be expected behavior depending on settings and what signals WoW provides:

- **Fewer icons/names in group content**
  - Some signals do not include a reliable spell ID
  - ZSBT will omit icons/names rather than display the wrong spell
- **Outgoing can be “quieter” in instances**
  - If `Dungeon/Raid Aware Outgoing` is enabled, ZSBT may suppress uncertain attribution
  - This reduces false positives in group content

## PvP feels too quiet (or missing swings)
- **Check PvP Strict Mode**
  - `/zsbt` -> `General` -> `PvP Tuning`
  - PvP Strict Mode tightens attribution in battlegrounds/arenas.
- **Check auto-attacks in PvP**
  - If you are missing swings while PvP Strict Mode is enabled, try disabling `Disable Auto-Attack Fallback (PvP)`.

## I updated and my PvP settings changed
- ZSBT only applies new defaults to existing profiles when a setting is missing (unset/nil).
- If you previously had explicit PvP settings, ZSBT will not overwrite them.

## Config window size looks different after an update
- ZSBT uses a default window size only when no saved window size exists.
- If you previously resized the config window, that size should still be preserved.

## Blizzard combat text leaking (incoming heals/damage)
If you see Blizzard combat text (for example, incoming heals) while ZSBT is enabled:

- Go to `/zsbt` -> `General` and enable `Suppress All Blizzard Combat Text`.
- If you are using Blizzard outgoing numbers, enable `/zsbt` -> `Outgoing` -> `Turn off ZSBT outgoing and use Blizzard FCT`.
- Use `/zsbt dumpcvars` to verify the Blizzard combat text CVars are set as expected.

## Blizzard XP / world text size is too small
If you previously changed CVars to reduce Blizzard XP/progress spam and your world text now looks too small:

- Run `/zsbt dumpcvars` and check the "World / XP text scale CVars" section.
- Restore the relevant CVar to its default value (shown in the dump output).

## Bug report
If you think you found a real bug:

- Include:
  - What you expected vs what happened
  - Open world vs dungeon/raid
  - The specific spell/ability (and SpellID if possible)
  - Repro steps
- If diagnostics are available:
  - Raise debug level
  - Reproduce once
  - Copy/paste the relevant `ZSBT:` lines
  - Set debug level back to `0`
