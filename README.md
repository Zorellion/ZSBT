# Zore's Scrolling Battle Text (ZSBT)

Scrolling battle text for World of Warcraft Retail 12.x.

## Features
- Scrolling combat text with multiple animation styles
- Parabola, Fireworks, Waterfall, Straight, and Static animations
- Outgoing spell icons via clean spellId lookup
- Generic incoming damage/heal icons (sword/heart fallbacks)
- Buff/debuff gain and fade notifications
- Cooldown tracking with Blizzard CooldownFrame widget
- Loot and money alerts
- Power gain notifications (Rage Full!, etc.)
- Low health/mana warnings with configurable thresholds
- AoE hit condensing (merge buffer)
- Spam control with per-category thresholds
- Crit "POW" animations with random positioning
- Midnight 12.0 Secret Value safe — works in dungeons and raids
- Full suppress of Blizzard FCT including _v2 CVars

## Commands
- `/zsbt` — Open configuration
- `/zsbt debug 0-3` — Set debug level
- `/zsbt reset` — Reset to defaults
- `/zsbt minimap` — Toggle minimap button
- `/zsbt version` — Show version

## Documentation
- [Getting Started](Docs/01-Getting-Started.md)
- [General](Docs/00-General.md)
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
