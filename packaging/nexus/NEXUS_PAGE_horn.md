# Nexus page — Useful Palico Horn v1.4.5

Upload `dist/UsefulPalicoHorn-1.4.5.zip` as the main file (Vortex/Fluffy-ready
layout).

The Nexus description field uses **BBCode** (not Markdown). Paste the blocks
below straight into the matching fields (BBCode/source view). Markdown `#` and
`**` will NOT render on Nexus.

**Companion mod:** Otomo Tools (cooldown tuning + horn counter). Independent —
they can be installed together or separately.

---

**Title:**

```
Useful Palico Horn — Fire the Attack-Up Horn on Command (REFramework)
```

**Short description:**

```
Fires the Palico's Attack-Up horn when you want it: first hit, quest start, trap, stun, paralysis, or the moment the buff runs out. Stops the trumpet being spent on the walk over.
```

**Full description (BBCode — paste as-is):**

```
[size=6][b]Useful Palico Horn[/b][/size]

In vanilla, the Palico decides when to play the Attack-Up horn. With its 8 minute cooldown that means roughly one buff per hunt, at a random moment — often while you are walking to the monster, and on cooldown by the time it is trapped or paralysed.

This mod gives you the timing. The horn is the Palico's own horn: the game still plays the animation and applies the buff, through its normal action pipeline.

[line]

[size=5][b]Triggers[/b][/size]

[list]
[*][b]On the first hit to the monster[/b] — the buff goes up as soon as the fight starts.
[*][b]At quest start[/b] — once the world has loaded and the Palico can act.
[*][b]When the monster is trapped[/b] — pitfall, shock and ivy traps.
[*][b]When the monster is stunned[/b] — the KO with stars.
[*][b]When the monster is paralyzed[/b] — the paralysis ailment.
[*][b]When the buff runs out[/b] — keeps it up permanently.
[*][b]Any time[/b] — press [b].[/b] (period) or the [b]Fire horn now[/b] button.
[/list]

Each event trigger fires once per event, not continuously.

A fire only costs the cooldown once the buff is actually up. If a monster roar cancels the animation, or the quest-start request lands before the world has loaded, the fire is refunded and the trigger tries again a few seconds later - no wasted 8 minute window.

While enabled, the mod also blocks the Palico's own horn use, so the cooldown is
absolute: the AI cannot play it on the game's schedule behind your back. Untick
[b]Block the Palico's own horn use[/b] to let the game use it normally.

[line]

[size=5][b]Cooldown[/b][/size]

The horn's own cooldown is [b]8 minutes (480 s)[/b].

[list]
[*][b]Use the base game cooldown[/b] (default) applies it to every trigger.
[*]The cooldown [b]resets at the start of every quest[/b], like the game's own.
[*]Untick it to type any value you like, including 0.
[*][b]The cooldown applies to every trigger, without exception.[/b] First hit and quest start still get their chance because the cooldown resets at the start of each quest; they just do not override a running timer.
[*]When a trigger is held, the panel says so ([i]held by cooldown: 431 s left[/i]) instead of silently doing nothing.
[/list]

[line]

[size=5][b]How to use[/b][/size]

[list=1]
[*]Install REFramework, then extract this archive into your game folder (Fluffy / Vortex: install normally). You should end up with:
[code]<game>\reframework\autorun\useful_palico_horn.lua[/code]
[*]In game, let the Palico act once in a quest (a few seconds is enough — that is how the mod captures its action object).
[*]Press [b]Insert[/b] → [b]Script Generated UI[/b] → [b]Useful Palico Horn[/b].
[*]Tick the triggers you want. The panel shows [b]buff: UP / down[/b] and the last action taken.
[*]Press [b].[/b] or [b]Fire horn now[/b] to fire manually.
[/list]

Default Steam path:
[code]...\steamapps\common\MonsterHunterWilds\[/code]

[line]

[size=5][b]Hotkey[/b][/size]

The default hotkey is [b].[/b] (period), which the game does not use. Every function key already does something in game, so F-keys are a bad choice.

To change it: click [b]Change hotkey[/b] in the panel, then hold the key you want for about a second. It binds on hold, and the panel shows the new key.

Advanced: the value is stored raw in [code]reframework\data\useful_palico_horn.json[/code], not as a name - [b].[/b] is 599, letters are 546 (A) to 571 (Z).

[line]

[size=5][b]Status and limits[/b][/size]

[list]
[*][b]Your Palico only.[/b] Only your own (master) Palico is used.
[*][b]No data changes.[/b] It does not touch cooldowns, stats, items or save data. It performs the Palico's action and nothing else.
[*][b]One hook[/b] on the Palico's action request, used to capture the object and (when the block option is on) to refuse the AI's own horn request. The action itself is issued through the game's own call path, so the animation and the effect stay consistent.
[*][b]Game-version dependent.[/b] The trap, stun and paralysis checks read condition ids from the game (PARALYSE 5, STUN 15, FIELD_PITFALL 31 and the other trap ids). They are verified on the current build; a title update could move them, in which case those three checkboxes would stop matching until the mod is updated.
[*]Reload any time: REFramework → [b]Reset scripts[/b], or restart the game.
[/list]

[line]

[size=5][b]Safety[/b][/size]

[list]
[*]Every game call is guarded. As with any mod that drives a game action, a game-side access violation is still possible; use at your own risk.
[*]Back up your save before using mods that change gameplay, as always.
[/list]

[line]

[size=5][b]Requirements[/b][/size]

[list]
[*]Monster Hunter Wilds
[*][url=https://www.nexusmods.com/monsterhunterwilds]REFramework for MH Wilds[/url] (install [b]dinput8.dll[/b] first)
[/list]

[line]

[size=5][b]Changelog[/b][/size]

[b]1.4.5[/b] - first public release
[list]
[*]Releases all game objects when a quest ends and does not read the world outside a quest, fixing the endless loading screen and the console errors reported on 1.1.8.
[*]If the buff does not register, the trigger retries once (2 fires total), then gives up without spending the cooldown.
[*]The buff is read from the hunter's horn-song skill (isOtomoMusicAttackUp), so the panel no longer shows "down" while the buff is up.
[/list]

[b]1.4.2[/b]
[list]
[*]Fires the Palico's Attack-Up horn on command: hotkey, button, first hit, quest start, trapped, stunned, paralyzed, or when the buff runs out.
[*]Base-game 8 minute cooldown, or any value you choose. One gate for every trigger: nothing fires while the countdown runs.
[*]The cooldown resets at the start of each quest, and only starts once the buff is confirmed. A roar-cancelled horn or a request sent before the quest loaded is refunded, and the trigger retries.
[*]Blocks the Palico's own horn use while enabled, so the AI cannot spend it behind your back.
[*]Change hotkey button in the panel (default .).
[*]Live buff state (buff: UP / down).
[/list]

[line]

[size=5][b]Credits[/b][/size]

[list]
[*][url=https://github.com/praydog/REFramework]REFramework[/url] by praydog
[/list]

Source and issues: [url=https://github.com/Diegoeyza/useful-palico-horn]github.com/Diegoeyza/useful-palico-horn[/url]
```

**Changelog field:**

```
1.4.5 - first public release
- Releases all game objects when a quest ends and does not read the world outside a quest, fixing the endless loading screen and the console errors reported on 1.1.8.
- If the buff does not register, the trigger retries once (2 fires total), then gives up without spending the cooldown.
- The buff is read from the hunter's horn-song skill (isOtomoMusicAttackUp), so the panel no longer shows "down" while the buff is up.
- Fires the Palico's Attack-Up horn on command: hotkey, button, first hit, quest start, trapped, stunned, paralyzed, or when the buff runs out.
- Base-game 8 minute cooldown, or any value you choose. One gate for every trigger: nothing fires while the countdown runs.
- The cooldown resets at the start of each quest, and only starts once the buff is confirmed. A roar-cancelled horn or a request sent before the quest loaded is refunded, and the trigger retries.
- Blocks the Palico's own horn use while enabled.
- Change hotkey button in the panel (default .).
- Live buff state (buff: UP / down).
```

**File to upload:** `dist/UsefulPalicoHorn-1.4.5.zip`

**Suggested Nexus metadata:**
- Category: Gameplay
- Version: 1.4.5
- Requirements: REFramework for MH Wilds
- Companion: Otomo Tools (optional)
