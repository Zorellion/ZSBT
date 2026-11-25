# ZSBT User Guide

Nov 22, 2026 · @Zorellion

This guide covers ZSBT (Zore's Scrolling Battle Text) **v4.0-Release** for WoW Retail 12.x (Midnight). Every menu path below matches the `/zsbt` settings window in this build.

## Getting started

**Install:** put the `ZSBT` folder in `World of Warcraft\_retail_\Interface\AddOns\`, or install it through CurseForge. The libraries it needs (Ace3, LibSharedMedia) are bundled.

**First login: reload once.** ZSBT writes its own combat-log filter, called **ZBattleText**, but WoW only lets it do that while you log out or reload. That filter is how ZSBT proves a hit on a shared target is yours and not a groupmate's. About three seconds after login a chat line tells you which state you're in:

- `'ZBattleText' combat log filter active` means everything is working.
- `filter not active yet … Written on logout` means type `/reload` once. Until you do, outgoing attribution relies on weaker guesses.

**Open the settings:** type `/zsbt`, or left-click the minimap button. The window has these pages in the left sidebar:

| Page | What it holds |
| --- | --- |
| General | On/off, combat-only mode, hiding Blizzard's combat text, fonts, number format, outgoing accuracy, sounds and custom media |
| DB Profiles | Profile switching, the five shipped presets, import/export |
| Combat Text | Incoming, outgoing and pet damage, healing and misses |
| Crits | Separate styling for each kind of critical hit |
| Alerts | Notifications, custom Triggers, cooldown-ready alerts |
| Resources | On-screen counters for combo points, holy power, runes and so on |
| Scroll Areas | Where text appears on screen and how it moves |
| Spam Control | Merging, minimum amounts, Spell Rules, Buff Rules |
| Class | Your class module, and a slot to teach ZSBT extra spells. Only shown for classes that have a module |
| Help and Support | Built-in help topics, troubleshooting, the Debug window |

The window can be resized by dragging its corner, and it remembers its size.

**Minimap button:** left-click opens the settings, right-click closes them, middle-click turns ZSBT on or off. You can hide the button in General → System, or toggle it with `/zsbt minimap`.

**Quick Control Bar** (optional, turn it on in General → System): a small bar you can drag anywhere on screen. It has three buttons:

- **Outgoing:** pick the If the Proof Feed Stops fallback (Strict, Relaxed or Damage Meter), and toggle Show Proven Hits Without Lines and pet melee as "Auto Attack".
- **Class:** Name Guardian Spells, plus Open Class Module.
- **Unlock / Lock:** shows the scroll areas so you can drag them.

**Slash commands for everyday use:**

| Command | Does |
| --- | --- |
| `/zsbt` | Open or close the settings window |
| `/zsbt minimap` | Show or hide the minimap button |
| `/zsbt version` | Print the version |
| `/zsbt reset` | Reset all settings to defaults (your tracked cooldowns are kept) |
| `/zsbt restorefct` | Panic button: give Blizzard's combat text back and stop hiding it |
| `/zsbt filter` | Show the ZBattleText filter's status; `/zsbt filter rebuild` rebuilds it and reloads your UI |
| `/zsbt sb` | Print what ZSBT read from your spellbook (`/zsbt sb all` for everything, `/zsbt sb win` opens a copyable window) |

The diagnostic commands are listed in the last section.

## Quick setup (10 minutes)

These steps take you from a fresh install to working combat text. Every step after the reload is optional, and the defaults already work.

1. **Reload once.** Type `/reload` after your first login so the ZBattleText filter gets written. Wait for the `filter active` line in chat.
2. **Optional: start from a preset.** Open `/zsbt` → **DB Profiles** and pick one of the shipped presets: **ZSBT - Preset: Melee**, **Ranged**, **Tank**, **Healer** or **Pet Class**.
3. **Hide Blizzard's numbers.** Go to **General → System** and turn on **Hide Blizzard Combat Text**, so the same hit doesn't show twice. The sub-toggles let you hide only some categories, for example keeping Blizzard's XP/Rep text.
4. **Place your scroll areas.** Open **Scroll Areas** and click **Unlock Scroll Areas**. Drag the **Incoming**, **Outgoing** and **Notifications** boxes where you want them, then click it again to lock. Out of the box, Incoming sits left of center, Outgoing right of center, and Notifications above.
5. **Pick a font.** Go to **General → Master Font** and set the face, size and outline. Every scroll area uses this font unless you override it.
6. **Shorten big numbers.** Go to **General → Numbers** and set the **Number Format**, for example *Short (K/M/B, 1 decimal)*, so 1,234,567 shows as 1.2M.
7. **Test.** Hit a target dummy for 20 seconds. You should see:
   - your damage scrolling in **Outgoing**
   - damage you take in **Incoming**
   - *Entering combat* / *Leaving combat* in **Notifications**
8. **Tidy up.** If big pulls get cluttered, turn on **Spam Control → Enable Spell Merging** and raise **Combat Text → Outgoing Damage → Minimum Damage Threshold**.

Nothing showing? Check that **General → System → Enable ZSBT** is on, and that **Combat Only Mode** is off while you test out of combat.

## General

The General page holds the settings everything else builds on. It has five sections.

### System

- **Enable ZSBT:** master on/off. It takes effect immediately, and turning ZSBT off gives Blizzard's combat text back without a reload.
- **Combat Only Mode:** show ZSBT text only while you're in combat.
- **Hide Blizzard Combat Text:** stops Blizzard's floating numbers. Seven sub-toggles control what gets hidden: Outgoing Damage, Incoming Damage, Incoming Healing, Reactives / Procs, XP / Rep / Honor, Resource Gains, and Pet Combat Text.
- **Restore Blizzard Combat Text Now:** panic button. It resets every Blizzard combat-text setting ZSBT touched and turns hiding off. Use it if Blizzard's numbers stay missing after you disable or uninstall ZSBT.
- **Critical Hits:**
  - **Force Crits Inline** keeps crits in the normal flow, with no separate crit routing.
  - **Crit Animations Ride Scroll Motion** (on by default) plays crit effects while the crit keeps travelling its scroll path.
  - The **Inline Crit Style** sliders (scale, duration, FX, font) only apply while Force Crits Inline is on.
- **UI:** Enable Quick Control Bar, Reset Quick Control Bar Position, Hide Minimap Button.
- **Quick Actions:** **Reset to Defaults** (keeps your tracked cooldowns) and **Reload UI**.

### Master Font

- **Font, size and opacity:** **Font Face** (default Friz Quadrata), **Font Size** (8–32, default 18), **Outline Style** and **Text Opacity**.
- **Critical Hit Font:** the crit look every crit inherits unless the Crits page overrides it. Set the face, a fixed size, or a scale multiplier, plus the outline.
- **Crit Animation:** pick **Pow (Sticky)**, Slam, Shockwave, Ignite, Chromatic, Stomp, ScreenPunch, Shatter, Afterimage or Rumble. *Use Scroll Area Animation* turns crit animation off. Each effect has its own intensity slider (0–3).

### Numbers

**Number Format** controls how damage and healing numbers are written:

- **None:** the full number.
- **Short (K/M/B):** with 0, 1 or 2 decimals.
- **Thousands (K):** with 1 decimal.
- **Significant digits (3).**

### Outgoing Accuracy

These options decide how strict ZSBT is about claiming a hit as yours. The defaults suit most players.

| Option | Default | When to change it |
| --- | --- | --- |
| If the Proof Feed Stops | Damage Meter | This only applies during a combat-log feed outage, which is rare and mostly happens in heavy raid moments. **Strict** shows only hits that can still be proven yours, but your numbers may go quiet. **Relaxed** lets unproven hits through, so a groupmate's hit may rarely show as yours. **Damage Meter** uses Blizzard's running damage totals, so you lose per-hit detail and crit flags but your numbers never go silent. **Reset to Default** sets it back to Damage Meter. |
| Show Proven Hits Without Lines (Experimental) | Off | Turn on if outgoing goes quiet in dense raids. Hits proven by your own cast or swing then show even when their combat-log line never arrives. Risk: a co-attacker's hit can occasionally show with your spell's name. |
| Show Pet Melee Hits as "Auto Attack" | Off | Pet classes only. Labels your pet's physical hits "Auto Attack" instead of a bare number, but only when the combat log proved the hit was your pet's. |
| Show DoT Ticks on Other Enemies | On | Shows your DoT ticks on enemies you aren't targeting. A tick only shows when it matches a DoT you applied to that mob. Needs enemy nameplates turned on. |

The first three options are also on the Quick Control Bar's **Outgoing** button. These options replaced the older *Require Combat-Log Proof*, *Show Unproven Outgoing in Groups*, *Relaxed Outgoing in PvP* and Damage Meter fallback toggles. Your old choice was carried over to the new setting when you updated.

### Media

- **Sound Events:**
  - **Sound Channel:** Master, SFX, Music, Ambience or Dialog.
  - **Low Health Warning** and **Cooldown Ready** sounds, each with a **Play Sound** preview button.
- **Custom Media:** add your own fonts (`.ttf`) and sounds (`.ogg`).
  1. Put the file in `World of Warcraft\_retail_\Interface\CustomMedia\Fonts\` or `…\CustomMedia\Sounds\`. That folder sits next to `AddOns`, so addon updates never wipe it.
  2. Enter a display name and the bare filename, for example `MyFont`, then click **Add Font** or **Add Sound**. A full `Interface\…` path also works.
  3. Type `/reload`. **Currently Registered Media** lists and manages what you've added.
- **Damage School Colors:** one color per school (Physical, Holy, Fire, Nature, Frost, Shadow, Arcane), plus a reset button. They apply wherever **Use School Colors** is on. Mixed schools use their dominant color: Shadowflame shows purple, Chaos shows pink.

## Scroll areas

A scroll area is a box on your screen where text appears and moves. ZSBT ships three, and you can add as many as you like.

| Area | Default position | Default motion | Used for |
| --- | --- | --- | --- |
| Incoming | 250 px left of center, 100×300 | Parabola, arcing left | Damage and healing you receive |
| Outgoing | 250 px right of center, 100×300 | Parabola, arcing right | Damage and healing you deal |
| Notifications | 200 px above center, 300×100 | Straight | Alerts, loot, combat state, triggers |

**Managing areas (Scroll Areas page):**

- **Select Scroll Area** picks the area to edit. **Delete Selected** removes it.
- **Rename Selected** + **Apply Rename** renames it.
- **Create New Area:** type a name and press Enter. The new area appears in every *Scroll Area* / *Route To* dropdown in the addon.

**Positioning:** click **Unlock Scroll Areas**, drag the boxes, then lock. The Quick Control Bar's Unlock button does the same. For exact placement, use the **Geometry** sliders:

- **X Offset / Y Offset:** ±3000 px from screen center.
- **Width:** 20–800 px. **Height:** 100–600 px.

**Font Override:** leave **Use Global Font** on to use the Master Font. Turn it off to give this area its own face, size, outline and opacity.

**Layout & Animation:**

- **Text Alignment:** Left, Center or Right. **Scroll Direction:** Up or Down.
- **Animation Style:**
  - **Scroll** / **Straight:** a straight line.
  - **Parabola:** an arc. Choose the **Parabola Side** and the **Parabola Intensity** (0.25–2.5).
  - **Fireworks:** bursts from a **Fireworks Origin** (Top, Bottom, Left or Right).
  - **Waterfall:** falls with a **Waterfall Style** (Smooth, Wavy, Ripple or Turbulent).
  - **Pow:** pops in place.
  - **Static:** no movement.
- **Animation Speed:** 0.5–3.0 seconds on screen. 1.0 is normal.

**Testing (areas must be unlocked):**

- **Test Selected:** fires 3 sample messages into the selected area.
- **Test Crit:** fires 3 crit samples.
- **Test All (Unlocked):** loops samples in every unlocked area every 3 seconds, which is handy while you arrange your layout.

Tips: if lines overlap, increase **Height** or slow the animation slightly. If text gets cut off, widen the area.

## Combat Text

The Combat Text page has one group per stream. Every stream has an on/off toggle, a **Scroll Area** (where it goes), a **Minimum … Threshold** (0 shows everything; you can type values above the slider, up to 15,000), and a color.

### Incoming Damage

- **Show Incoming Damage**, **Scroll Area** (default Incoming), **Minimum Damage Threshold**.
- **Show Damage Flags:** adds Crushing, Glancing, Absorb, Block and Resist tags.
- **Show Spell Icons**, with two refinements:
  - **Show Resolved Spell Icons** shows only icons ZSBT is sure of.
  - **Show Fallback Icons** shows a generic icon when it isn't sure.
  - **Icon Position:** Left or Right.
- **Use Damage School Colors**, or a **Custom Damage Color**.

### Incoming Healing

- **Show Incoming Healing**, **Scroll Area**, **Minimum Healing Threshold**, **Custom Healing Color**.
- **Show HoT Ticks Separately:** each heal-over-time tick gets its own number.
- **Show Healer Names:** adds the healer's name when the game provides it.

### Incoming / Outgoing Misses

- **Show Misses / Avoids**, plus its own **Scroll Area** and **Miss Color**.
- **Hidden Types:** tick any of Dodge, Miss, Parry, Block, Resist, Absorb, Evade, Immune, Reflect or Deflect to never show it.

### Outgoing Damage

- **Show Outgoing Damage**, **Scroll Area** (default Outgoing), **Minimum Damage Threshold**.
- **Attribution Delay** (0.05–0.50 s, default 0.20): how long a number waits for combat-log proof before it shows. Lower feels snappier; higher is more reliable in busy fights.
- **Show Spell Names:** writes the ability name after the number. Merged lines with hidden amounts show the spell name when this is on, and "Hits (xN)" when it's off.
- **Show Spell Icons** and **Icon Position**.
- **Show Empowering Proc Icon (experimental):** when a proc empowered the cast, for example Secrets of the Coven on Shadow Bolt, both icons show.
- **Show Target Names:** adds the target's name.
- **Auto-Attack Display:** Show All (default), Show Only Crits, or Hide.
- **Use School Colors**, or a **Custom Damage Color**.

### Outgoing Healing

**Show Outgoing Healing**, **Scroll Area**, **Minimum Healing Threshold** and **Custom Healing Color**. Periodic heals such as Rejuvenation show as ticks.

### Pet streams

- **Outgoing Pet Damage:** damage from your pets and guardians.
  - **Aggregation Style** sets the label: *Attempt Pet Name*, *Spell Name*, *Generic ("Pet Hit X")* or *None (Numbers Only)*.
  - **Show Pet Spell Icons** shows the pet's spell icon, for example the Imp's Firebolt.
  - **Merge Pet Hits Window** (0–1 s) merges hits into one line, with an optional **(xN)** count.
  - In dungeons and raids pets may show only as "Pet", because WoW hides their names there.
- **Incoming Pet Healing:** for example Mend Pet. Turn it off to treat pet heals as normal outgoing healing.
- **Incoming Pet Damage:** damage your pet takes.
- Each pet stream has its own scroll area, threshold, and normal and crit colors.

**Tip for a clean look:** spell names off, icons on, merging on in Spam Control.

## Crits

The Crits page has five groups, one per crit type. Each group can override the shared crit look from **General → Master Font**:

- Incoming Crit Damage
- Incoming Crit Heals
- Outgoing Crit Damage
- Outgoing Crit Heals
- Outgoing Pet Crits

Every group offers the same set of options:

| Option | What it does |
| --- | --- |
| Override Crit Font | Use this group's face, size or scale, outline and animation instead of the shared crit font |
| Crit Animation | Pow (Sticky), Slam, Shockwave, Ignite, Chromatic, Stomp, ScreenPunch, Shatter, Afterimage, Rumble, or Use Scroll Area Animation. Each effect has an intensity slider (0–3). |
| Route … to a Different Scroll Area | Send crits to another area, for example a dedicated "Crits" area you created |
| Crit Color | Color for this crit type |
| Sticky (slightly bigger + longer) | Crits stay on screen longer and a little larger. **Sticky Jiggle** adds a shake. |
| Play a Sound | Plays a sound on this crit type. Pick the sound, preview it with **Test**, and set **Minimum Crit Amount** to skip small crits. |
| Instances: When amount is unavailable | In dungeons and raids, crit amounts can be hidden. Choose **Any Crit** (play anyway) or **Only when amount is known** |

Incoming crit groups also have **Crit Scroll Area (optional)**, a simpler one-dropdown way to reroute crits.

To keep crits in the normal flow with no separate routing, use **General → System → Force Crits Inline**.

## Spam Control

Spam Control keeps big pulls readable. It has its own sidebar page.

**Spell Merging** (off by default):

- **Enable Spell Merging** combines rapid hits from the same spell into one line.
- **Merge Window:** 0.5–5 s, default 1.5.
- **Show Merge Count:** shows "x3" on the merged line.
- **Merge Critical Hits:** crits merge separately and keep their crit style.

**Incoming Merging** (needs Spell Merging on): **Merge Incoming Bursts** combines rapid incoming hits and heals into one line, on by default. Merging is grouped by scroll area, kind, crit and school, not by spell.

- **Incoming Merge Window:** 0.05–2 s, default 0.20. It's kept short because incoming spam arrives within a fraction of a second.
- **Merged Hidden Amounts:** when the game hides the amounts, **Last value xN** (default) shows the newest real number, for example "1234 x3". **Count only** shows "Heals x3".

**Throttling:** **Global Minimum Damage** and **Global Minimum Healing** apply to every stream (0–15,000). **Hide Auto-Attacks Below** (0–5,000) drops small white swings.

**Pulse Engine:**

- **Pulse Queue Size** (20–600) and **Max Work Per Pulse** (10–200) control how many events ZSBT queues and processes.
- Raise them only if you lose numbers in very large pulls. Higher values use more CPU.

**Special Cases:** **Suppress Training Dummy Internal Damage** hides the fake huge numbers dummies produce.

**Routing Defaults:**

- Default scroll areas for Spell Rules and for Buff Rules.
- Four whitelist switches: **Show Buff Gains / Buff Fades / Debuff Gains / Debuff Fades Without Rules**. Turn one off and only auras you've made a rule for will notify.

### Spell Rules (per-spell, outgoing only)

Click **Open Spell Rules Manager**.

1. **Add a spell:** type a SpellID or the exact spell name and click **Add**. To find IDs, fight for a few seconds, click **Refresh Recent Spells**, and pick from the list.
2. **Or use templates:** **Apply Class Templates (Merge Only)** adds rules for your class without overwriting yours. **Include All Specs** is recommended.
3. **Edit a rule.** Click **Edit** to open the Spell Rule Editor:
   - **Enabled**.
   - **Throttle** (0–2 s): the minimum gap between displays of this spell.
   - **Scroll Area Override**.
   - **Aggregation:** combine hits within 0.1–1.25 s into one line, with an optional (xN) count. **Similar Hits (xN, crits)** shows lines like "(x5, 1 crit)" for multi-hit spells such as Whirlwind.
   - **Style Override:** a font and color for this spell only.

Example: give a noisy proc a 0.2–0.6 s throttle, and leave your big cooldowns without rules so they always show.

### Buff Rules (notifications)

Click **Open Buff Rules Manager**. It works the same way, with **Refresh Recent Buffs** and class templates. Each rule has:

- **Enabled**
- **Hide Gain** / **Hide Fade**
- **Throttle** (0–10 s, tracked separately for gain and fade)
- **Scroll Area Override**

Example: to see only major cooldowns and trinket procs, turn off *Show Buff Gains Without Rules* and *Show Buff Fades Without Rules*, then add rules just for those buffs.

If rules seem to vanish after an update, use **Help and Support → Troubleshooting → Spam → Repair Spam Control Rules**.

## Alerts

The Alerts page has three groups: Notifications, Triggers and Cooldowns. All of them normally go to the **Notifications** scroll area.

### Notifications

**Enable Notifications Area** is the master switch for the whole group. Below it, each category has its own settings:

- **Enabled** and **Route To** (which scroll area).
- A **Template**.
- **Style:** color, plus optional font override (face, outline, size 8–72).
- **Sound:** **Play a Sound** with a **Play Sound** preview.

| Category | On by default | Template codes |
| --- | --- | --- |
| Enter Combat / Leave Combat | Yes | `%e` event text |
| Player XP, Honor, Reputation, Companion XP | Yes | `%e` event text |
| Loot Items | Yes | `%e` item, `%a` amount looted, `%t` total owned |
| Loot Money | Yes | `%e` money string (Coin Icons or Text format) |
| Loot Currency | Yes | `%e` currency, `%a` amount, `%t` total |
| Trade Skills: Skill Ups | Yes | `%e` skill, `%a` amount, `%t` new level |
| Trade Skills: Learned Recipes/Spells | Yes | `%e` recipe or spell |
| Interrupts (Successful) | Yes | `%t` target, `%s` your ability |
| Cast Stops (Stuns/CC) | No | `%t` target, `%s` your ability |
| External Addons (LibSink) | — | `%e` event text; lets other addons print into ZSBT |

- **Template examples:** `+%a %e (%t)`, `+%e x%a`, `+%e`.
- **Stop sound when leaving combat** (Enter Combat): cuts a long enter-combat sound off when combat ends.
- **Interrupt Alerts:** Interrupts and Cast Stops share one route, color, font and sound.
  - **Show Successful Interrupts in Chat** prints a line to *your own* chat frame. Template codes: `%p` you, `%s` ability, `%t` target.
  - It doesn't send anything to party chat, because WoW blocks addons from doing that. **Test Chat** previews it.

### Triggers

Triggers are custom alerts you build yourself.

1. Turn on **Enable Triggers**, then click **Add Trigger**. Each trigger opens in the **Trigger Editor**.
2. Pick an **Event Type**:
   - **Auras:** `AURA_GAIN`, `AURA_FADE`, `AURA_STACKS` (with Min/Max Stacks).
   - **Spells:** `COOLDOWN_READY`, `SPELL_USABLE` (with *Only In Combat* and a *Rearm after unusable* delay that stops flicker), `SPELLCAST_SUCCEEDED`.
   - **State:** `ENTER_COMBAT`, `LEAVE_COMBAT`, `TARGET_CHANGED`, `EQUIPMENT_CHANGED`, `SPEC_CHANGED`.
   - **Warnings:** `LOW_HEALTH`, and RESOURCE\_THRESHOLD (Power Type + ABOVE/BELOW + value).
   - **Kills:** `KILLING_BLOW`, `UT_KILL_1` … `UT_KILL_7`.
3. Enter a **SpellID** or exact spell name for aura, cooldown, usable and cast triggers.
4. Set the **Throttle** (0–30 s), the minimum time between firings.
5. Set the action:
   - **Text**, **Scroll Area**, **Show Spell Icon**, **Sound**, **Color**.
   - Optional **Font Override**.
   - **Sticky**, which pops like a crit, with scale and duration multipliers and an optional jiggle.
6. Click **Test Trigger** to fire it once.

**Text tokens:** `{spell}` `{id}` `{event}` `{pct}` `{threshold}` `{unit}` `{power}` `{value}` `{stacks}` `{count}` `{label}`.

**Hidden buffs:** some buffs are hidden ("secret") during combat and can't be detected by SpellID. For those, click **Convert to Spellcast Succeeded** to fire on the cast instead.

**UT Announcer:** **Setup UT Announcer Triggers** installs Unreal Tournament–style multi-kill announcements (UT\_KILL\_1–7, with sounds like *First Blood* and *Godlike*). It only adds triggers you don't already have, so your edits are never overwritten. Each kill inside the chain window raises the tier, up to 7.

### Cooldowns

1. Turn on **Show Cooldown Notifications** and pick the **Scroll Area**.
2. Set the **Notification Format** (`%s` = spell name, for example `%s Ready!`), **Show Spell Icon**, and **Notification Sound**.
3. Add spells under **Tracked Spells**: drag a spell onto the drop slot, or type a SpellID or name and click **Add**. Remove one with its **X** button.

**Reset to Defaults** keeps your tracked cooldowns.

## Resources and the Class page

### Resource counters

Resources → Resource Tracker shows one button for each secondary resource your class actually has: combo points, holy power, chi, soul shards, runes, essence and so on. A green dot means that counter is on. Click a button to open that resource's settings window:

- **Resource Full Text Notification:** scrolls a message such as *Combo Points Full!* when you hit max (`%e` = resource name). It has its own route, color and font.
- **Show Resource Tracker:** the on-screen counter itself.
- **Tracker Placement:** **Anchor To** a scroll area or a free position, a **Position** (9 points), and X/Y offsets.
- **Display:**
  - **Display Format:** Diamond Pips, Fraction (4/6) or Number Only.
  - Pip, empty and outline colors. Width 80–800 and height 20–200.
  - **Hide at 0**, **Hide Out of Combat**.
  - Death Knights also get **Rune Shape** (Circle, Diamond, Hexagon or Square), **Show Seconds Remaining** on recharging runes, and **Hide when All Runes Are Ready**.
- **Full Resource:** **Play Sound at Max**, and a **Full Effect** (Afterimage, Chromatic, Ignite or Shatter) that loops while you stay at max.
- **Counter Font:** an optional font override.

**Unlock Resource Counters** lets you drag and resize counters without unlocking your scroll areas.

### Class page

The Class page only appears when your class has a module, and its sidebar button shows your class name. A module tells ZSBT what your spells, pets and guardians do, so hits get the right spell name instead of a bare number.

| Class | Module coverage |
| --- | --- |
| Warlock | All three specs, including verified guardians: Mother of Chaos, Overlord, Imp Lord, Gloomhound, Blighted Maw |
| Hunter | All specs, including Dark Ranger (Bleak Arrows, Black Arrow, Wailing Arrow) and Beast Mastery pet abilities (Kill Command, Bloodshed) |
| Death Knight | All three specs |
| Warrior | Fury and Protection |
| Demon Hunter | Vengeance and Devourer |
| Shaman | Elemental and Enhancement, including totems, Flame Shock spread, elementals and Feral Spirit wolves |
| Druid | All specs, including named Feral bleed ticks |
| Other classes | Generic behavior: casts, DoTs and pets still get names, without class extras |

On the page:

- **Module knowledge:** lists the DoTs, channels, summons and multi-hit casts the module knows, colored by damage school.
- **Name guardian spells:** names Wild Imps, Dreadstalkers, Dancing Rune Weapon and similar guardians from summon tracking. Turn it off to show plain pet damage instead.
- **Show pet melee hits** (off by default): moved to General → Outgoing Accuracy as Show Pet Melee Hits as "Auto Attack".
- **Teach a spell:** drag a spell onto the slot to teach ZSBT something it can't see itself, such as a trinket effect or proc. Pick its role:
  - **Auto (guess)** reads the tooltip.
  - **Damage over Time**.
  - **Channeled**.
  - **Multi-hit cast**, with a hit count.

  Taught spells always override ZSBT's own guesses.
- **Spellbook:** opens a movable grid of your spellbook. Drag an icon to the slot, or click it to teach it with the default guess.

ZSBT re-reads your spellbook whenever your spec, talents or pet change, so it keeps up when patches renumber spells. `/zsbt sb` shows what it learned.

## Profiles

Your settings live in a profile. The DB Profiles page has two parts.

**DB Profiles:** the standard Ace profile controls.

- Choose which profile this character uses, create a new one, or copy from another.
- Delete or reset a profile.
- **Preset Profiles:** five shipped layouts. **ZSBT - Preset: Melee**, **Ranged**, **Tank**, **Healer** and **Pet Class**.
  - Pick one as a starting point and tweak it.
  - The **Reset Preset: …** buttons restore a preset to its shipped layout. They don't change which profile you're using.

**Import / Export:** share settings as a text string.

1. Click **Export Current Profile**. A share string fills the **Profile Data** box.
2. Copy it and send it to a friend or another account.
3. To load a string, paste it into the box and click **Import Profile**. **This overwrites your current profile**, so switch to a new, empty profile first if you want to keep yours.

**Clear** empties the box.

Some lists are saved per character rather than per profile: Spell Rules, Buff Rules, tracked cooldowns and triggers.

## Midnight limits and troubleshooting

**What to expect.** WoW 12.x hides the source of many combat events and turns some amounts into protected "secret" values. ZSBT follows one rule: **show less, never wrong.** In practice:

- Some hits appear as a plain number with no spell name or icon, because ZSBT won't guess.
- Group content can look quieter than a target dummy. ZSBT hides hits it can't prove are yours rather than show a groupmate's damage under your name. The ZBattleText filter also recognizes hits from other players, NPCs and follower-dungeon companions on your target, and drops them.
- Pet names can show as "Pet" in dungeons and raids.
- Crit sounds may not be able to compare amounts in instances. Use the *When amount is unavailable* setting.
- Overheal and school color are shown only when the game provides them.

**Fixes for common problems:**

| Problem | Fix |
| --- | --- |
| Nothing shows | 1. Turn on General → System → **Enable ZSBT**. 2. Turn off **Combat Only Mode** while testing. 3. Lower the thresholds. 4. Make sure the stream routes to an area that exists. 5. Type `/reload`. |
| Other players' damage on my scroll | Check that `/zsbt filter` reports `trusted=true`; if not, `/reload`. **If it still happens in raids, set General → Outgoing Accuracy → If the Proof Feed Stops to Strict**. |
| My outgoing is too quiet in groups | Turn on **Show** **Proven Hits Without Lines, raise the Attribution Delay a little, or set If the Proof Feed Stops to Damage Meter or Relaxed**. |
| Blizzard's numbers show alongside ZSBT | Turn on General → System → **Hide Blizzard Combat Text**. |
| Blizzard's numbers never come back | Type `/zsbt restorefct`, or click **Restore Blizzard Combat Text Now**. |
| Too much spam | Turn on **Spell Merging**, raise the minimum thresholds, add Spell Rules for noisy procs. |
| A trigger doesn't fire | Check **Enable Triggers** and the trigger's own **Enabled**, the SpellID, and its route. For hidden buffs, use **Convert to Spellcast Succeeded**. |
| Custom font or sound is missing | `.ttf`/`.ogg` in `Interface\CustomMedia\…`, registered with the bare filename, then `/reload`. |
| Spell or Buff Rules look missing after an update | Click Troubleshooting → Spam → **Repair Spam Control Rules**. |
| A spell is always named wrong | Teach it on the Class page. If it keeps happening, report it. |

**Built-in help.** **Help and Support** has a topic for every feature. **Open In Window** keeps a topic visible while you change settings. Some older topics still mention a "Display" tab, which is now the Scroll Areas page and the Media section under General.

**Diagnostics.** Open the **Debug UI** from Help and Support → Troubleshooting.

- Set a default debug level from 0 (off) to 5 (trace), or per channel: core, cooldowns, incoming, outgoing, triggers, notifications, ui, diagnostics, safety, perf.
- **Setup Debug Chat Tab** sends the output to its own chat tab.
- The Incoming and Outgoing probes capture real events, replay them, and print a capability report.

**Bug-report flow:**

1. Raise the debug level for the relevant channel.
2. Reproduce the problem once.
3. Copy the `ZSBT:` lines.
4. Set the level back to 0.
5. Include open world vs. instance, the spell and its SpellID, and repro steps.

**Diagnostic commands:**

| Command | Does |
| --- | --- |
| `/zsbt debug show` | Show the current debug levels |
| `/zsbt debug <0-5>` | Set the default level |
| `/zsbt debug <channel> <0-5>` | Set one channel's level |
| `/zsbt cddebug <0-5>` | Shortcut for the cooldowns channel |
| `/zsbt dumpcvars` | Print Blizzard combat-text settings and their defaults |
| `/zsbt audit` / `/zsbt arep` | Toggle the attribution audit trace (off again after a reload) / print the end-of-fight accuracy report |
| `/zsbt auditreport` | Print the saved confidence metrics; /zsbt auditmax \<n> sets the audit buffer size (default 8000) |
| `/zsbt ucdrop` | Toggle a trace of dropped unattributed hits (off again after a reload) |
| `/zsbt ctprobe` | Combat-text probe tools |
| `/zsbt clearlearned` | Wipe everything ZSBT has learned (spell schools, tick amounts, DoT timings, per-spell hit delays, proc bindings) for a fresh start |
| `/zsbt auratest` | Run the aura detection test |

**Sources:** the ZSBT source in your retail AddOns folder (v4.0-Release): the options tree, `Core/Init.lua` slash commands, `Core/Defaults.lua`, and `Docs/`.
