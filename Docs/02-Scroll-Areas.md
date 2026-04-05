# Scroll Areas

Scroll areas control where text appears on your screen and how it animates.

## Where to configure
- `/zsbt` -> `Scroll Areas`

## The default areas
- **Notifications**
  - Used for alerts (combat state, progress, loot, trade skills, warnings, UT announcements).
- **Outgoing**
  - Your damage/healing.
- **Incoming**
  - Damage/healing you receive.

## How to position an area
- Select the scroll area by name.
- Adjust:
  - `Anchor`
  - `X Offset`
  - `Y Offset`
  - `Width` / `Height`

## Animation settings
Each scroll area has its own animation settings.

- **Animation Type**
  - Options include `Parabola`, `Fireworks`, `Waterfall`, `Straight`, `Static`.
- **Direction / Justify**
  - Controls movement direction and text alignment.
- **Duration / Fade / Scale / Arc**
  - Controls how long and how dramatic the animation is.

## Font per scroll area
Each area can use the global font or a per-area font.

- Set `Use Global` (if available) to use the font from `General`.
- Otherwise set a custom:
  - `Font Face`
  - `Font Size`
  - `Font Outline`

## Troubleshooting
- **Text appears but overlaps too much**
  - Reduce `Max Messages`.
  - Increase `Height`.
  - Increase animation duration slightly.
- **Text is clipped**
  - Increase `Width` and/or `Height`.
- **Notifications feel too small**
  - Increase the `Notifications` area font size.

## Testing
- Use `Test Selected` to fire regular test events into the selected scroll area.
- Use `Test Crit` to fire crit-style test events. This also fires incoming heal/damage crit tests using your `Incoming` crit routing overrides.
