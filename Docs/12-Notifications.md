# Notifications

Notifications controls what kinds of alerts are allowed to appear in your Notifications scroll area.

## Where to configure
- `/zsbt` -> `Notifications`

## Loot Alerts
Loot is split into three categories:
- Loot Items
- Loot Money (gold/silver/copper)
- Loot Currency (tokens/currencies)

You can configure loot message templates and loot filters under:
- `/zsbt` -> `Notifications` -> `Loot Alerts`

### How to use Loot Alerts

#### 1) Turn on the category (and choose where it goes)
- Go to `/zsbt` -> `Notifications`.
- Enable any of:
  - `Loot Items`
  - `Loot Money`
  - `Loot Currency`
- Use the `Route To` dropdown next to each category to choose which scroll area receives that alert.

#### 2) Customize the message template
- Go to `/zsbt` -> `Notifications` -> `Loot Alerts`.
- Each loot type has its own template.

Template codes:
- `%e` The thing you gained (item link / money string / currency link)
- `%a` Amount gained
- `%t` Total owned (your new total)

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
- Cooldowns ready
- Procs / reactive abilities
- Buff/debuff gain or fade messages
- Loot / money / reputation / honor progress
- Warnings (low health, low mana)
- UT announcer events
- Custom Triggers

## Step-by-step setup
- **Ensure you have a Notifications scroll area**
  - Go to `Scroll Areas`.
  - Enable the `Notifications` area.
  - Place it somewhere central or near your UI alerts.
- **Enable the categories you care about**
  - Go to `Notifications`.
  - Turn on the categories you want to see.
- **Route to the right scroll area**
  - For most notification categories (combat state, progress, loot items/money/currency, auras, power full), use the `Route To` selector in the `Notifications` tab.
  - Cooldown ready routing is configured in the `Cooldowns` tab.
  - Custom trigger routing is configured per-trigger in the `Triggers` tab.

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
