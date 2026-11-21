Useful Palico Horn
==================

Fires the Palico's Attack-Up horn on command, so the buff lands when you want
it: on the first hit, at quest start, on a trap, a stun or a paralysis, or the
moment the buff runs out.

Requirements
------------
- REFramework (with Lua support).
- Nothing else. Works alongside Otomo Tools; the two are independent.

Install
-------
Install with Fluffy Manager or Vortex, or extract the archive straight into your
game folder (the archive root contains reframework\autorun\, so it lands
correctly):

    MonsterHunterWilds\reframework\autorun\useful_palico_horn.lua

Use
---
1. Enter a quest and let the Palico act once (a few seconds is enough).
2. Press . (period), or use the "Fire horn now" button in
   Insert -> Script Generated UI -> Useful Palico Horn.

Cooldown
--------
The horn's own cooldown is 8 minutes, and it **resets at the start of every
quest**, so each hunt starts ready. "Use the base game cooldown" (on by default)
applies it to every trigger, or untick it to type any value you like.

It applies to every trigger without exception: hotkey, button, first hit,
quest start, buff runs out, trapped / stunned / paralyzed. Nothing fires while
the countdown is running.

First hit and quest start still get their chance because the cooldown resets at
the start of each quest. If you want more than one buff per quest, set a custom
cooldown shorter than the base 8 minutes.

Triggers
--------
- On the first hit to the monster
- At quest start
- When the monster is trapped
- When the monster is stunned (KO)
- When the monster is paralyzed
- When the buff runs out (keeps it up permanently)

Each fires once per event, not continuously.

The cooldown only starts once the buff is confirmed. If a roar cancels the horn,
or the quest-start request lands before the world has loaded, the fire is
refunded and the trigger tries again a few seconds later.

While enabled, the mod also **blocks the Palico's own horn use**, so the
cooldown is absolute: the AI cannot spend it behind your back. Untick "Block the
Palico's own horn use" to let the game use the horn on its own schedule again.

Hotkey
------
The default is . (period), which the game does not use.

To change it: click **Change hotkey** in the panel, then hold the key you want
for about a second. It binds on hold, and the panel shows the new key.

Advanced: the value is stored raw in reframework/data/useful_palico_horn.json,
not as a name - . is 599, letters are 546 (A) to 571 (Z).

Notes
-----
- The Palico must have acted at least once in the quest before the horn can be
  fired; that is how the mod captures its action object. The panel shows
  "wait for the Palico to act once" until then.
- This mod plays the Palico's own action. It does not change game data, and it
  does not touch Otomo Tools' cooldown values.
- A log and a trace are written to reframework/data/ if you need to report a
  problem: useful_palico_horn.json and useful_palico_horn_trace.json.
