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
2. Press F9 to fire the horn, or use the "Fire horn now" button in the
   REFramework script list (Otomo Horn v0.2.0).
3. The horn plays and the Attack-Up buff applies, even if the Palico's own
   cooldown would not have allowed it.

Automation
----------
* **Fire when the buff is down** - fires automatically as soon as the
  Attack-Up buff expires, keeping it up permanently.
* **Fire on the first hit to the monster** - fires once as soon as the target
  monster first takes damage. Read from `app.EnemyManager` health data; the
  panel shows `monster: full HP / damaged` plus HP so you can confirm it sees
  the fight.
* **Use a global cooldown** - toggle, with a seconds value (default
  **480 s / 8 minutes**) for the keep-alive fires. Manual fires and the first-hit trigger are not blocked
  by it; a 10 s anti-spam gap always applies.

The panel shows the live buff state (UP / down / unknown) and a countdown to the
next automatic fire.

Settings live in reframework/data/otomo_horn.json:

    {
      "enabled": true,
      "hotkey": "F9",
      "min_interval_sec": 0.5,
      "auto_when_down": false,
      "global_cooldown_sec": 480,
      "fire_on_first_hit": false
    }

Notes
-----
* This mod plays the Palico's action directly. It does not tune any values and
  does not touch the horn's cooldown. It is a different product from Otomo
  Tools, which is a data-only cooldown/counter mod; the two do not conflict.
* The Palico must have acted at least once in the quest before the hotkey can
  work - the mod needs to capture its action object.
* If REFramework reports an unknown key name, edit "hotkey" to one of the
  ImGui key names (F1..F12, etc.).
