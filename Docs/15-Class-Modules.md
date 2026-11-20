# Class Modules

Class modules are ZSBT's class-specific knowledge. They tell the addon what
your spells, pets, and guardians actually do, so your scroll text names the
right spell instead of showing a plain number.

## What you get

- **Your spells are named.** Casts, DoTs, and channels you use show their
  real names next to the damage they cause.
- **Your pets are named correctly.** Pet spells like Lash of Pain or Fel
  Firebolt appear on the pet scroll; your own spells stay on the player
  scroll and never mix.
- **Your guardians are named.** Temporary pets that don't announce their
  own casts — Wild Imps, Dreadstalkers, Demonic Tyrant, Dancing Rune
  Weapon, the Riders of the Apocalypse — still get identified by the
  summon you cast and the damage they can produce.
- **Damage that isn't yours stays off your scroll.** In dungeons and
  groups, hits that can't be proven to come from you or your pets are
  filtered rather than shown with a guessed name.

## Which classes have a module

| Class | Status |
|---|---|
| Warlock | All three specs covered (Affliction, Demonology, Destruction) |
| Hunter | Fully implemented, including Dark Ranger guardians |
| Death Knight | Blood and Frost covered |
| Warrior | Fury and Protection covered |
| Other classes | Safe generic behavior — your casts still name, but no pet/guardian extras yet |

More class modules are added over time. If your class isn't listed, you
still get named casts, DoTs, and pet damage — just without the
class-specific extras.

## The Class page

Open `/zsbt` and pick the class page in the sidebar (the button shows your
class). It only appears when your class has a module.

### Module knowledge

The left pane lists everything the module knows: your DoTs, channels,
summons, guardian spells, and multi-hit casts. Spell names are colored by
their damage school — the same colors your scroll uses — so a fire spell
shows in fire orange and a shadow spell in shadow purple. If a name ever
shows a color that doesn't match the spell, that's worth reporting.

### Toggles

Below the header, only the options your class supports appear. For
example:

- **Name guardian spells** — guardian damage (imps, tyrant, etc.) is
  named from summon tracking. Turn it off to show plain pet damage
  instead.
- **Show pet melee hits** — names your pet's regular swings "Auto
  Attack". Off by default because a rare wrong call can name something
  that wasn't your pet.

### Teach a spell

On the right is a drop slot shaped like an empty action-bar button. Drag
a spell from your action bar or spellbook onto it to teach ZSBT about
spells it can't see on its own — trinket effects, procs, or effects from
other sources that deal damage in your name.

- **Auto (guess)** is the default role — ZSBT reads the spell's
  description and classifies it for you.
- **Damage over Time** — pick this when the hit keeps ticking after the
  cast.
- **Channeled** — pick this when the damage comes in waves while you
  channel.
- **Multi-hit cast** — pick this when one cast produces several hits;
  the number box next to it sets how many hits it can claim.

If you drop a spell the module already knows, ZSBT tells you instead of
storing a duplicate. Taught spells always win over anything the addon
guessed automatically.

### Spellbook flyout

The `Spellbook` button on the Class page opens a movable grid of your
current spellbook — same icons you'd see in the real spellbook. You can
drag an icon straight from the flyout to the drop slot, or click an icon
to teach it with the default guess.

## How ZSBT learns your spells

Behind the scenes, ZSBT reads your live spellbook — including your pet's
spellbook — whenever your spec, talents, or pet changes. From each
spell's description it learns the current spell ID, whether it's a DoT or
a channel, roughly how often it ticks, and what damage school it uses.

This is why the addon survives patches that renumber spells: it resolves
your spells by name against your book instead of trusting an old ID. The
hand-tuned module tables and your taught spells are always consulted
first — automatic knowledge only fills in the gaps.

You can peek at what it learned with `/zsbt sb` (prints a summary and
each spell's role and school to chat).

## "Show less, never wrong"

Modern WoW hides the source of many combat events, so there are hits the
addon honestly cannot assign to a spell. When that happens, ZSBT shows a
plain number instead of guessing — and in group content it would rather
hide a hit it can't prove is yours than risk displaying someone else's
damage with your name on it.

So if some numbers appear unnamed, or group fights look a little quieter
than a target dummy, that's the addon being honest, not broken.
