# Getting Started

## Open the configuration
- Type `/zsbt` in chat.
- Use the tabs on the left to configure features.

## Recommended first run
- **Optional: choose a preset profile**
  - Go to `DB Profiles`.
  - Select one of the shipped preset profiles (Melee / Ranged / Tank / Healer / Pet Class).
  - If you ever want to restore a preset back to its shipped layout, use the reset buttons at the bottom of `DB Profiles`.
- **Enable the addon**
  - Go to `General`.
  - Make sure `Enabled` is on.
- **Confirm scroll areas are enabled**
  - Go to `Scroll Areas`.
  - Ensure the `Incoming`, `Outgoing`, and `Notifications` areas are enabled.
- **Unlock and place scroll areas**
  - Go to `Scroll Areas`.
  - Use the unlock/move controls (if present) to position each area where you want it.
  - Adjust `Width` / `Height` so text doesn’t clip.
- **Pick your number formatting**
  - Go to `General` -> `Numbers`.
  - Choose the Number Format you prefer (full numbers, abbreviated, etc.).
- **Pick fonts**
  - Go to `General` for the master font.
  - Optionally override fonts per scroll area in `Scroll Areas`.
- **Test**
  - Hit a target dummy or fight a mob.
  - You should see:
    - Incoming damage/heals in `Incoming`
    - Your damage/heals in `Outgoing`
    - Alerts (if enabled) in `Notifications`

## Quick setup checklist
- **Optional: pick a preset profile**
  - Go to `DB Profiles`.
  - Select a shipped preset profile.
- **Enable ZSBT**
  - Go to `General`.
  - Make sure `Enabled` is on.
- **Pick your font**
  - Go to `General`.
  - Adjust the master font (face/size/outline).
- **Place your scroll areas**
  - Go to `Scroll Areas`.
  - Move/size the `Incoming`, `Outgoing`, and `Notifications` areas.
- **Confirm you see messages**
  - Hit a target dummy or fight a mob.
  - You should see numbers in `Incoming` / `Outgoing` and alerts in `Notifications`.

## Common first tweaks
- **Too much spam**
  - Go to `Spam Control`.
  - Enable merging and set reasonable minimum thresholds.
- **Don’t want auto-attack clutter**
  - Go to `Outgoing`.
  - Adjust `Auto Attack` display and/or raise the outgoing damage min threshold.
- **Want cooldown / proc / warning style alerts**
  - Go to `Notifications`.
  - Enable the categories you care about and route them to the `Notifications` scroll area.

## Common commands
- `/zsbt` Open configuration
- `/zsbt minimap` Toggle minimap button
- `/zsbt reset` Reset settings to defaults
- `/zsbt version` Show addon version

## Troubleshooting
- **Nothing shows up**
  - Ensure ZSBT is enabled in `General`.
  - Ensure the scroll area you’re using is enabled in `Scroll Areas`.
  - If `Combat Only` is enabled, you won’t see most messages out of combat.
- **Too much spam**
  - Go to `Spam Control` and enable merging/throttling and thresholds.
- **Blizzard floating combat text still shows**
  - Go to `General` and enable Blizzard FCT suppression, then `/reload`.

## Next reading
- [General](00-General.md)
- [Scroll Areas](02-Scroll-Areas.md)
- [Incoming](03-Incoming.md)
- [Outgoing](04-Outgoing.md)
- [Spam Control](06-Spam-Control.md)
- [Diagnostics](11-Diagnostics.md)
