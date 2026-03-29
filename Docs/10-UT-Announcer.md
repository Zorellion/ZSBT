# UT Announcer (Multi-Kill)

ZSBT includes an Unreal Tournament–style multi-kill announcer.

## What it does
- Tracks your kill streak timing.
- Fires trigger events `UT_KILL_1` through `UT_KILL_7`.
- UT Announcer presets are optional and can be installed with one click.

## Enable / install the presets
- `/zsbt` -> `Alerts` -> `Triggers`
- Click `Setup UT Announcer Triggers`
- This is merge-only (it adds missing UT_KILL triggers but does not overwrite your edits).

## What the presets do
- Display styled text in `Notifications`
- Play matching sounds

## How the tiers work
- Tier 1 = first kill in a chain.
- Each additional kill within the chain window increases the tier.
- Tier 7 is the max (everything above stays at tier 7).

## Timing
ZSBT uses a rolling window + a chain cap (configured in the addon logic).

## Customize the announcements
- `/zsbt` -> `Alerts` -> `Triggers`
- Find the triggers for:
  - `UT_KILL_1` … `UT_KILL_7`
- Change:
  - Text
  - Sound
  - Color
  - Sticky / font override

## Tips
- If you want a different sound ladder, just change the sound on each `UT_KILL_X` trigger.
- If you don’t want UT at all, disable or delete the `UT_KILL_X` triggers.
