# Combat Log Settings (Required for Fallback Detection)

ZSBT primarily uses secure combat text signals (Combat Log events and Blizzard combat text feeds).

However, some of ZSBT’s **fallback detection** relies on **combat messages being generated** so the addon can listen to them via chat combat events.

If your Combat Log filters are too restrictive, you may see issues like:
- Missing outgoing spell hits / ticks in some situations
- Missing periodic damage (DoTs) in edge cases
- Missing kill-credit / death messages used by fallback logic

## What you need to enable (high level)
You must make sure these are enabled in Combat Log filtering:
- **My Actions**
- **What happened to me**

And within those, ensure these categories are enabled:
- **Damage**
- **Healing**
- **Misses** (optional, but recommended)
- **Deaths** / **Killing blows** (recommended)

## Step-by-step (click-by-click)
1. **Open your Combat Log window**
   - Open chat.
   - If you don’t have a Combat Log tab, create a new chat tab and set it to Combat Log.

2. **Open Combat Log settings**
   - Right-click your chat tab name.
   - Click `Settings` (or `Chat Settings`).
   - Go to the `Combat Log` section.

3. **Open the Combat Log "Filters" / "What to Log" panel**
   - Look for a button like `Filters`, `What to Log`, or `Configure`.

4. **Enable the two required filter presets**
   - Enable:
     - `My Actions`
     - `What happened to me`

5. **Inside each preset, enable the categories ZSBT needs**
   In BOTH `My Actions` and `What happened to me`, make sure these are enabled:
   - `Damage`
   - `Spell damage`
   - `Periodic damage`
   - `Melee / swings`
   - `Healing` (including periodic heals)

6. **Recommended extras (more reliable fallbacks)**
   In BOTH presets, also enable:
   - `Misses` (dodge/parry/block/resist/immune)
   - `Deaths` / `Killing blows`

7. **Reload UI**
   - Type `/reload`

## Notes
- ZSBT can still run with restrictive logs, but you may lose some fallback coverage.
- If you use other combat log addons, avoid disabling these categories globally.

## Quick verification
- Attack a target dummy for 10 seconds.
- You should see:
  - Outgoing hits
  - DoT ticks (if you apply one)
  - Crits (if you crit)

If you still see missing outgoing events after enabling these, check:
- `General` -> master enable
- `Outgoing` -> enable outgoing damage
- `Spam Control` -> thresholds (min threshold not too high)
