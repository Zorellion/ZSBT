# Zore's Scrolling Battle Text (ZSBT)

Scrolling battle text for World of Warcraft Retail 12.x.

ZSBT is built to behave safely under modern Retail restrictions ("secret values" / protected actions) so it stays stable in open world, dungeons, and raids.

## Why ZSBT
- Built for Retail 12.x restrictions (avoids taint/blocked-action patterns)
- Multiple independent scroll areas with an MSBT-style animation engine
- Strong spam control (merge/throttle/thresholds) so big pulls stay readable
- Custom alerts system (Notifications + Cooldowns + Triggers)

## Features
- Scroll areas & animations:
  - Unlimited scroll areas (move/size/anchor)
  - Parabola, Fireworks, Waterfall, Straight, Static
  - Per-area font override (or use master font)
- Core combat text:
  - Incoming damage/healing (thresholds, misses, overheal options)
  - Outgoing damage/healing (thresholds, misses, auto-attack options)
  - Optional: use Blizzard Floating Combat Text for outgoing only (keep ZSBT incoming + alerts)
  - Crit emphasis: separate crit configuration blocks + sticky crit styling
- Alerts & notifications:
  - Notifications system with per-category toggles
  - Loot alerts (items/money/currency) with templates + filters
  - Trade skill alerts (skill ups + learned recipes/spells)
- Interrupt Alerts:
  - Successful interrupts + cast-stopping stuns/CC (optional)
  - Templates: `%t`=target, `%s`=your stopping ability
  - One shared config block for routing/style/sound
  - Optional local chat output for successful interrupts (prints to your chat frame)
- Cooldowns:
  - Cooldown-ready alerts for tracked spells (text + sound)
- Custom Triggers:
  - Build alerts for auras, cooldown ready, spell usable, spellcast succeeded, low health warning,
    resource thresholds, combat state, target changes, spec changes, equipment changes, and killing blows
  - Per-trigger styling (color/sound/sticky/font override)
- UT Announcer:
  - Unreal Tournament–style multi-kill announcer implemented as triggers (UT_KILL_1 .. UT_KILL_7)
  - One-click install of shipped presets (merge-only)
- Spam Control (readability tools):
  - AoE hit condensing/merging
  - Global min thresholds for damage/healing
  - Per-spell outgoing rules (throttle/routing/style overrides)
  - Buff rules for notifications (whitelist mode + per-buff throttles)
- Pets:
  - Pet/guardian damage display (aggregation + merge window + thresholds)
  - Optional incoming pet damage + incoming pet healing streams
- Media:
  - LibSharedMedia font and sound support
  - Custom media registration for your own fonts/sounds
- Quality-of-life:
  - Optional Quick Control Bar (toggle tuning + unlock/lock scroll areas)
  - Preset profiles (Melee/Ranged/Tank/Healer/Pet Class)
  - Diagnostics / debug logging tools

## Quick start
- `/zsbt` -> `General`: enable addon + choose master font
- `/zsbt` -> `Scroll Areas`: place/size Incoming, Outgoing, Notifications
- `/zsbt` -> `Alerts` -> `Notifications`: enable categories you want

## Commands
- `/zsbt` — Open configuration
- `/zsbt debug show` — Show current default + per-channel debug levels
- `/zsbt debug <0-5>` — Set global default debug level
- `/zsbt debug <channel> <0-5>` — Set a per-channel debug level
- `/zsbt reset` — Reset to defaults
- `/zsbt minimap` — Toggle minimap button
- `/zsbt version` — Show version

## Quick Control Bar
An optional on-screen bar that can be enabled in:
- `/zsbt` -> `General` -> `Enable Quick Control Bar`

It provides:
- Instance tuning dropdown
- Open-world tuning dropdown
- Unlock/Lock button for scroll area positioning

## Documentation
- [Getting Started](Docs/01-Getting-Started.md)
- [General](Docs/00-General.md)
- [Combat Log Settings](Docs/13-Combat-Log-Settings.md)
- [Scroll Areas](Docs/02-Scroll-Areas.md)
- [Incoming](Docs/03-Incoming.md)
- [Outgoing](Docs/04-Outgoing.md)
- [Notifications](Docs/12-Notifications.md)
- [Pets](Docs/05-Pets.md)
- [Spam Control](Docs/06-Spam-Control.md)
- [Triggers](Docs/07-Triggers.md)
- [Cooldowns](Docs/08-Cooldowns.md)
- [Media](Docs/09-Media.md)
- [UT Announcer](Docs/10-UT-Announcer.md)
- [Diagnostics](Docs/11-Diagnostics.md)

## Author
Zorellion
