Otomo Horn
==========

Fires the Palico's Attack-Up horn on command, for timing it to a paralysis, a
trap or a down instead of leaving it to the AI.

Requirements
------------
REFramework (with Lua support). Nothing else.

Install
-------
Extract into your game folder so that you end up with:

    MonsterHunterWilds\reframework\autorun\otomo_horn.lua

or install with Vortex / Fluffy.

Use
---
1. Enter a quest and let the Palico act once (a few seconds is enough).
2. Press F6 to fire the horn, or use the "Fire horn now" button in the
   REFramework script list (Otomo Horn v0.1.0).
3. The horn plays and the Attack-Up buff applies, even if the Palico's own
   cooldown would not have allowed it.

The hotkey is stored in reframework/data/otomo_horn.json:

    { "enabled": true, "hotkey": "F6", "min_interval_sec": 0.5 }

Notes
-----
* This mod plays the Palico's action directly. It does not tune any values and
  does not touch the horn's cooldown. It is a different product from Otomo
  Tools, which is a data-only cooldown/counter mod; the two do not conflict.
* The Palico must have acted at least once in the quest before the hotkey can
  work - the mod needs to capture its action object.
* If REFramework reports an unknown key name, edit "hotkey" to one of the
  ImGui key names (F1..F12, etc.).
