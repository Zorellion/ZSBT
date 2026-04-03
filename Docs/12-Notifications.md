# Notifications

Notifications controls what kinds of alerts are allowed to appear in your Notifications scroll area.

## Where to configure
- `/zsbt` -> `Alerts` -> `Notifications`

## Combat State
Combat state alerts are split into two categories:
- Enter Combat
- Leave Combat

Each category has its own:
- Enable toggle
- Route
- Template
- Style + sound options

### Enter Combat: stop sound when leaving combat
If you use a long Enter Combat sound, you can enable:
- `Stop sound when leaving combat`

This will stop the Enter Combat sound on combat end so the Leave Combat sound can play cleanly.

## Loot Alerts
Loot is split into three categories:
- Loot Items
- Loot Money (gold/silver/copper)
- Loot Currency (tokens/currencies)

You can configure loot message templates and loot filters under:
- `/zsbt` -> `Alerts` -> `Notifications` -> `Loot Alerts`

## Trade Skill Alerts
Trade skills are split into two categories:
- Trade Skills: Skill Ups
- Trade Skills: Learned Recipes/Spells

You can configure trade skill message templates under:
- `/zsbt` -> `Alerts` -> `Notifications` -> `Trade Skill Alerts`

## Interrupt Alerts
Interrupt Alerts covers:
- Successful interrupts
- Cast-stopping stuns/CC (optional)

You can configure these under:
- `/zsbt` -> `Alerts` -> `Notifications` -> `Interrupt Alerts`

Template codes:
- `%t` Target name
- `%s` Your stopping ability name (Kick/Pummel/Storm Bolt/etc.)

Shared options (apply to both Interrupts and Cast Stops):
- Routing (single `Route To` for both)
- Color
- Font override (face/outline/size)
- Optional sound
- Optional local chat output for successful interrupts

### How to use Loot Alerts

#### 1) Turn on the category (and choose where it goes)
- Go to `/zsbt` -> `Alerts` -> `Notifications`.
- Enable any of:
  - `Loot Items`
  - `Loot Money`
  - `Loot Currency`
- Use the `Route To` dropdown next to each category to choose which scroll area receives that alert.

#### 2) Customize the message template
- Go to `/zsbt` -> `Alerts` -> `Notifications` -> `Loot Alerts`.
- Each loot type has its own template.

Template codes:
- `%e` The thing you gained (item link / money string / currency link)
- `%a` Amount gained
- `%t` Total owned (your new total)

For Trade Skills:
- `%e` Skill name (Skill Ups) or learned recipe/spell link/name (Learned)
- `%a` Amount gained (Skill Ups)
- `%t` New level (Skill Ups)

Examples:
- `+%a %e (%t)` (MSBT-style)
- `+%e x%a` (simple)
- `+%e` (minimal)

#### 3) Configure loot filtering (items only)
Loot filters apply to Loot Items.

- `Show Created/Pushed Items`
  - Off: hides items produced by crafting/creation messages.
  - On: shows them.
- `Always Show Quest Items`
  - If enabled, quest items are shown even if they would normally be hidden by quality or exclusion filters.
- `Quality Exclusions`
  - Hide loot of selected qualities.
- `Items Excluded (one per line)`
  - Hide items by name (one per line).
- `Items Allowed (one per line)`
  - Allow-list always wins: if an item is listed here, it will be shown even if excluded by quality or name.

## What belongs in Notifications
Notifications is intended for short, high-signal messages like:
- Combat state (enter/leave)
- Loot / money / reputation / honor progress
- Trade skill skill-ups / learned recipes
- Power messages
- Warnings (low health, low mana)
- UT announcer events

## Step-by-step setup
- **Ensure you have a Notifications scroll area**
  - Go to `Scroll Areas`.
  - Enable the `Notifications` area.
  - Place it somewhere central or near your UI alerts.
- **Enable the categories you care about**
  - Go to `Alerts` -> `Notifications`.
  - Turn on the categories you want to see.
- **Route to the right scroll area**
  - Use the `Route To` selector per category in the Notifications tree.

## Tips
- If notifications are too noisy:
  - Disable the categories you don’t care about.
  - Use `Spam Control` to merge/throttle if you’re seeing too many repeated alerts.
- If notifications are hard to read:
  - Increase the `Notifications` area font size.
  - Increase its `Height` and reduce `Max Messages`.

## Related docs
- [Scroll Areas](02-Scroll-Areas.md)
- [Cooldowns](08-Cooldowns.md)
- [Triggers](07-Triggers.md)
- [UT Announcer](10-UT-Announcer.md)
- [Spam Control](06-Spam-Control.md)
