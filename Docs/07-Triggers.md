# Triggers

Triggers let you create your own notifications when specific events happen.

## Where to configure
- `/zsbt` -> `Triggers`

## Enable triggers
- Turn on `Enable Triggers`.

## How triggers work (mental model)
- A trigger has:
  - **Event Type**: what kind of thing you’re watching for.
  - **Optional Spell ID filter**: for event types that represent a specific spell/aura/cooldown.
  - **Throttle**: minimum time between firings for that trigger.
  - **Action**: what to show/play when it fires (text, scroll area, sound, color, sticky).

## Event Types (what each one means)

### Aura-based
- **AURA_GAIN**
  - Fires when you gain the configured aura (buff or debuff) on yourself.
  - Requires `Spell ID`.
- **AURA_FADE**
  - Fires when the configured aura fades from you.
  - Requires `Spell ID`.
- **AURA_STACKS**
  - Fires when the configured aura stack count changes.
  - Requires `Spell ID`.

### Cooldown/spell-based
- **COOLDOWN_READY**
  - Fires when a tracked cooldown becomes ready.
  - Requires `Spell ID`.
- **SPELL_USABLE**
  - Fires when a spell becomes usable.
  - Typically requires `Spell ID`.
- **SPELLCAST_SUCCEEDED**
  - Fires when the player (or pet) successfully casts a spell.
  - Requires `Spell ID`.

### Combat state / general
- **ENTER_COMBAT**
  - Fires when you enter combat.
- **LEAVE_COMBAT**
  - Fires when you leave combat.
- **TARGET_CHANGED**
  - Fires when your target changes.
- **EQUIPMENT_CHANGED**
  - Fires when an equipment slot changes.
- **SPEC_CHANGED**
  - Fires when your spec changes.

### Warnings / thresholds
- **LOW_HEALTH**
  - Fires when low-health warning logic triggers.
- **RESOURCE_THRESHOLD**
  - Fires when a configured resource threshold is crossed.

### Kill / UT-style
- **KILLING_BLOW**
  - Fires when you get a killing blow.
- **UT_KILL_1** through **UT_KILL_7**
  - UT announcer tier events.
  - Install the preset UT triggers via the `Setup UT Announcer Triggers` button.

## Add a trigger
- Click `Add Trigger`.
- Configure:
  - **Event Type** (what kind of event fires the trigger)
  - **Spell ID** (if the event is tied to a specific spell)
  - **Throttle** (minimum time between repeated firings)

## Action (what happens when it fires)
- **Text**: what to display.
- **Scroll Area**: usually `Notifications`.
- **Sound**: choose from the sound dropdown.
- **Color**: set the message color.
- **Sticky**: make it pop like a crit.
- **Sticky Jiggle (shake)**: optional shake animation for Sticky.
- **Font Override**: choose a specific font/outline for this trigger.

## Aura gain/fade notes
- Aura gain/fade triggers are detected via player aura tracking and periodic sync/rescan.
- ZSBT tries to avoid false repeats caused by transient aura enumeration issues during loading screens.

## Text placeholders
The trigger text supports simple placeholders you can include in the Action text.

- **`{spell}`**: resolved spell/aura name (when available)
- **`{id}`**: spell ID
- **`{event}`**: event label (GAIN/FADE/READY/etc.)
- **`{pct}`**: percent value (used by low health)
- **`{threshold}`**: threshold value (used by low health / resource threshold / equipment)
- **`{unit}`**: unit name/id (when available)
- **`{power}`**: power type (for resource threshold)
- **`{value}`**: value payload (slot id, killed unit name, etc.)
- **`{stacks}`**: aura stacks
- **`{count}`**: generic count field (if provided)
- **`{label}`**: generic label field (if provided)

If a placeholder isn’t relevant for a given event type, it will usually be blank.

## Throttle (anti-spam)
- Throttle is per-trigger.
- If a trigger could fire rapidly (procs, stacks changing, repeated usable checks), set a throttle like `0.5` to `2.0` seconds.
- If you want something to always fire, set throttle to `0`.

## Examples (copy/paste ideas)

### Example: Buff gained
- **Event Type**: `AURA_GAIN`
- **Spell ID**: (your buff)
- **Text**: `+{spell}`
- **Throttle**: `1.0`

### Example: Buff faded
- **Event Type**: `AURA_FADE`
- **Spell ID**: (your buff)
- **Text**: `-{spell}`
- **Throttle**: `1.0`

### Example: Cooldown ready
- **Event Type**: `COOLDOWN_READY`
- **Spell ID**: (your cooldown)
- **Text**: `{spell} Ready!`
- **Sound**: pick a distinct sound

### Example: Low health warning
- **Event Type**: `LOW_HEALTH`
- **Text**: `LOW HP ({pct}%)`
- **Sticky**: enabled
- **Throttle**: `3.0`

### Example: Enter/leave combat
- **Event Type**: `ENTER_COMBAT`
- **Text**: `Combat!`
- **Throttle**: `0`

### Example: UT kill announcement styling
- Edit `UT_KILL_1` and change only:
  - **Text**: `First Blood!`
  - **Sound**: your preferred sound

## Testing
- Use the `Play Sound` button (when available) to preview a sound.
- For spell-based triggers, cast the spell or cause the event in combat.

## Tips
- Use `Throttle` for events that can spam (auras ticking, repeated procs).
- Keep the text short for the cleanest look.
