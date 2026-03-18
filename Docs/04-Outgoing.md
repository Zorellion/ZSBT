# Outgoing

Outgoing controls what you see when you deal damage or healing.

## Where to configure
- `/zsbt` -> `Outgoing`

## Step-by-step setup
- **Pick a scroll area**
  - Set `Outgoing Damage` -> `Scroll Area` to your `Outgoing` scroll area.
  - Set `Outgoing Healing` -> `Scroll Area` to where you want heals (often also `Outgoing`).
- **Set thresholds**
  - Start with a low `Min Threshold` so you can confirm everything works.
  - Raise it later if you want to hide small hits/ticks.
- **Decide how to show crits**
  - If you like crit emphasis, enable crits and use sticky crit styling.
- **Decide how to handle auto attacks**
  - If white swings clutter your view, reduce or disable auto attack display (or raise thresholds).

## Outgoing damage
- **Enable/disable** outgoing damage.
- Choose the `Scroll Area` (usually `Outgoing`).
- Set `Min Threshold` to hide small hits.
- Configure `Auto Attack` display behavior.
- Toggle whether to show `Misses`.

## Outgoing healing
- **Enable/disable** outgoing healing.
- Choose the `Scroll Area`.
- Toggle whether to show `Overheal`.
- Set `Min Threshold`.

## Crits
- Crits can be enabled separately.
- If you want crits to stand out, use sticky crit styling.

## Spell names and icons
- `Show Spell Names` shows the ability name (when available).
- `Show Spell Icons` shows an icon (when safe).

## Periodic damage (DoTs)
- Periodic effects (DoTs) should appear as outgoing damage ticks.
- Depending on the available 12.x-safe signals, periodic ticks may be strongest/reliably detected for your current `target`.

## Tips
- For a cleaner look:
  - Disable spell names.
  - Keep icons on.
  - Enable merging in `Spam Control`.

## Group/instance note
- If you have a “dungeon/raid aware outgoing” restriction enabled, outgoing fallback signals can be limited in instanced content to avoid mis-attributing group activity to you.
