# General

The General tab controls core behavior that applies across the whole addon.

## Where to configure
- `/zsbt` -> `General`

## Dungeon/Raid Aware Outgoing
When enabled, ZSBT will apply extra restrictions to outgoing detection while you are in dungeons and raids.

### Why this exists
In group content, some combat text feeds can become ambiguous or can look like “your” damage when it was actually done by a follower/party member.

This setting prioritizes **correct attribution** over **completeness**.

### What you may notice
- Outgoing numbers can become quieter in instances.
- Auto-attacks may be suppressed in some situations.

### When to enable
- If you see outgoing damage/heals that clearly aren’t yours in dungeons/raids.

### When to disable
- If you are solo and you want the maximum amount of outgoing detail.

## Experimental fallbacks (instances)
These options are only shown when `Dungeon/Raid Aware Outgoing` is enabled.

### Use Damage Meter Outgoing Fallback (Experimental)
Uses Blizzard’s damage meter totals as a last-resort outgoing source when normal outgoing detection is too quiet in instances.

- Pros: restores outgoing visibility in follower dungeons.
- Cons: may be less detailed and can increase duplicates if other sources are also active.

### Use Damage Meter Incoming Damage Fallback (Experimental)
Uses Blizzard’s damage-taken totals as a last-resort incoming damage source when incoming combat text becomes ambiguous/secret in instances.

- Pros: restores incoming damage visibility when combat text is hidden/secret.
- Cons: may be less detailed and can increase noise.

### Show Auto Attacks in Instances (Experimental)
Enables a conservative fallback for auto-attacks in restricted instance mode.

- Pros: restores missing swing numbers.
- Cons: in rare cases may misattribute follower/other melee swings.

## Recommended test checklist
1. Enable `Dungeon/Raid Aware Outgoing`.
2. Do a small follower dungeon pull.
3. If outgoing is too quiet, enable `Use Damage Meter Outgoing Fallback (Experimental)` and retest.
4. If incoming damage is missing/secret, enable `Use Damage Meter Incoming Damage Fallback (Experimental)` and retest.
5. Only if swings are missing, try `Show Auto Attacks in Instances (Experimental)`.
