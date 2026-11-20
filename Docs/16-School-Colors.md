# School Colors

School colors tint each damage number by the magic school that caused it,
so you can read what kind of damage is flowing at a glance — not just how
much.

## What it looks like

| Damage school | Color |
|---|---|
| Physical | pale yellow |
| Holy | gold |
| Fire | orange |
| Nature | green |
| Frost | ice blue |
| Shadow | purple |
| Arcane | pink |

Mixed-school damage (Shadowflame, Chaos, Cosmic, and so on) picks the
color of its dominant school — Shadowflame shows as shadow purple, Chaos
as arcane pink. Physical hits keep your normal damage color so melee
doesn't light up like a spell.

## What uses it

- **Outgoing damage** — your hits are tinted by their school.
- **Incoming damage** — damage you take is tinted by the school that
  hit you.
- **Pet damage** — your pets' hits follow the same palette, so a
  Fel Firebolt looks like fire and a Lash of Pain looks like shadow.
- **Module knowledge list** — spell names on the Class page use the
  same colors, matching what their damage looks like on the scroll.

## Turning it on

- `/zsbt` -> `Combat Text` -> `Incoming` -> **Use Damage School Colors**
- `/zsbt` -> `Combat Text` -> `Outgoing` -> **Use Damage School Colors**

Each side is toggled separately. If school coloring is off (or a hit's
school isn't readable), numbers fall back to your normal damage color —
**Custom Damage Color** sets that fallback.

## Changing the palette

- `/zsbt` -> `Media` -> **Damage School Colors**

Every school has its own color picker. Any color you change is used
everywhere school colors appear — scroll text, pet damage, and the
Class page knowledge list alike.

## Why it's useful

- **Read your damage profile instantly.** A Destruction warlock sees a
  wall of orange with purple Wither ticks mixed in — you can spot which
  effects are actually landing.
- **Spot incoming threat types.** Frost hits you can't dodge look
  different from shadow DoTs ticking on you.
- **Catch attribution mistakes.** If a "shadow" spell ever shows in
  fire orange, something's mislabeled — and the Class page makes it easy
  to check what the module believes about that spell.

## A note on honesty

On modern WoW, not every combat event reports its damage school. Hits
that arrive without readable school information just show in your normal
damage color — ZSBT never invents a color it can't verify.
