# Spam Control

Spam Control helps reduce noise by merging rapid hits and applying thresholds.

## Where to configure
- `/zsbt` -> `Spam Control`

## Merging (AoE condensing)
- Enable merging to combine multiple rapid hits into one line.
- Adjust the merge `Window` to control how long hits are collected.
- Enable `Show Count` to display “(xN)” style counts.

## Throttling / thresholds
- Use minimum thresholds to hide small damage/heals.
- Use auto-attack suppression thresholds if available.

## Routing defaults
- Choose default scroll areas for new spell/aura rules.

## Spell Rules (Per-Spell)
Spell Rules let you add **per-spell throttles** for outgoing combat text.

- **What Spell Rules affect**
  - Outgoing damage/healing display (not Notifications).
- **What Spell Rules do**
  - Apply an additional, per-spell throttle window so that repeated events from the same spell don’t spam the scroll area.
  - Optionally override scroll area routing.
  - Optionally override font and color (Style Override).
  - Some spells may support additional per-spell behaviors (like aggregation) that only apply when a rule exists.
- **Where to configure**
  - `/zsbt` -> `Spam Control` -> `Open Spell Rules Manager`

### Character-specific
Spell Rules are stored **per character**.

### How to add a spell rule
- Enter a **SpellID** (or exact spell name) and click `Add`.
- Then click `Edit` on the rule to adjust settings (enabled, throttle).

### Recently Seen Spells
The Spell Rules Manager includes **Recently Seen Spells**:
- Attack a target for a few seconds.
- Click `Refresh Recent Spells`.
- Use this list to discover SpellIDs you may want to add rules for.

### Spell Rules examples
- **Example: Reduce spam from a frequent proc/hit**
  - Add a rule for the proc spell.
  - Set throttle to something like `0.20` to `0.60` seconds.
- **Example: Keep big cooldowns “instant”**
  - Do not add spell rules to major cooldown hits.
  - Or keep throttle very low.

## Buff Rules (Notifications)
Buff Rules let you control which **buff gain/fade notifications** you see.

- **What Buff Rules affect**
  - Notifications for your own auras/procs (gain/fade).
- **What Buff Rules do**
  - Allow you to:
    - enable/disable a buff’s notifications
    - suppress Gain and/or Fade independently
    - add a per-buff throttle (spam control)
- **Where to configure**
  - `/zsbt` -> `Spam Control` -> `Open Buff Rules Manager`

### “Whitelist mode” (only show configured buffs)
The Spam Control tab has toggles that control whether **unconfigured** buffs are allowed:
- If you disable showing gains/fades without rules, only buffs with a Buff Rule will display.

There are separate toggles for **harmful debuffs**:
- If you disable showing debuff gains/fades without rules, only debuffs with a Debuff Rule will display.

### Recently Seen Buffs
The Buff Rules Manager includes **Recently Seen Buffs**:
- Trigger a proc or gain buffs.
- Click `Refresh Recent Buffs`.
- Use this list to discover spellIDs to add rules for.

### Templates
The Buff Rules Manager includes merge-only class templates:
- `Apply Class Templates (Merge Only)` adds useful rules without overwriting your custom rules.
- `Include All Specs` is recommended if you play multiple specs.

### Buff Rules examples
- **Example: Hide a noisy proc’s fade**
  - Add the proc as a Buff Rule.
  - Enable it.
  - Set `Suppress Fade` on.
- **Example: Keep only important cooldown buffs**
  - Disable “Show Buff Gains Without Rules” and “Show Buff Fades Without Rules”.
  - Add rules only for the buffs you care about (major cooldowns, trinket procs, defensives).
- **Example: Show debuffs only when configured**
  - Disable “Show Debuff Gains Without Rules” and “Show Debuff Fades Without Rules”.
  - Add rules only for the debuffs you care about (example: Bloodlust lockout debuffs).
- **Example: Stop spam from stacking buffs**
  - Add a Buff Rule.
  - Set a small throttle like `1.0` to `3.0` seconds.

## Tips
- If big pulls create unreadable spam:
  - Enable merging
  - Increase merge window slightly
  - Raise min thresholds
