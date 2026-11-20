# Nexus page — Otomo Tools v1.0.3

Upload `dist/OtomoTools-1.0.3.zip` as the main file (Vortex/Fluffy-ready
layout).

The Nexus description field uses **BBCode** (not Markdown). Paste the blocks
below straight into the matching fields (BBCode/source view). Markdown `#` and
`**` will NOT render on Nexus.

**Companion mod:** Useful Palico Horn (fire the horn on command). Independent —
they can be installed together or separately.

---

**Title:**

```
Otomo Tools — Palico Tool Cooldowns & Attack-Up Horn Counter (REFramework)
```

**Short description:**

```
Lowers the cooldowns of the Palico's support tools — the Attack-Up horn ships at 600 s — plus an optional global cooldown and a read-only counter showing horn uses, uptime and the live buff state. Data-only, no hooks, nothing forced.
```

**Full description (BBCode — paste as-is):**

```
[size=6][b]Otomo Tools[/b][/size]

Every Palico support move has a cooldown of its own, and the Attack-Up horn's is [b]600 seconds[/b]. That is why the trumpet is a once-per-10-minutes novelty instead of something you can plan around.

This mod edits those cooldowns — the tools you choose, by the amount you choose — and shows you what actually happened, with a counter and a live buff readout.

[line]

[size=5][b]What it does[/b][/size]

[list]
[*][b]Per-tool cooldowns[/b] — every Palico support tool, read live from the game's own data. Set a target and press tune, or use a preset.
[*][b]Presets[/b] — [b]Horn Attack Up[/b] (the trumpet on its own), [b]Horn Both[/b] (attack + defence), [b]Healing[/b].
[*][b]Global cooldown[/b] — the shared 90 s cooldown between tools can be lowered too. The horns ignore it (they run on their own cooldown); it affects traps, slinger, bombs, heals and the rest.
[*][b]Horn counter[/b] — uses, total uptime, uses per 10 minutes, and the live state ([b]buff now: UP / down[/b]) at the top of the panel.
[*][b]Restore originals[/b] — one button puts every shipping value back.
[/list]

[line]

[size=5][b]What it does not do[/b][/size]

[b]It does not make the Palico use anything.[/b] It changes availability, not intent. The game still decides when to act, so lowering a cooldown means the tool can fire more often — not that it will fire on command.

Two honest limits, measured in game:

[list]
[*][b]The AI's desire is the real limiter.[/b] Across full hunts, the horn's cooldown check was satisfied [i]100%[/i] of the time; what gated it was the Palico's own desire flag, which is internal to the game.
[*][b]The horn's buff lasts about 2 minutes.[/b] After a use there is a refractory period before it can be played again, so a very short cooldown does not produce a very short cycle.
[/list]

Measured effect on the trumpet: roughly [b]1.6 to 2 uses per 10 minutes[/b] with a 90 s cooldown, against a hard ceiling of about 1 at the shipping 600 s.

If you need the horn to fire at a specific moment, that is what the companion mod [b]Useful Palico Horn[/b] is for.

[line]

[size=5][b]How to use[/b][/size]

[list=1]
[*]Install REFramework, then extract this archive into your game folder (Fluffy / Vortex: install normally). You should end up with:
[code]<game>\reframework\autorun\otomo_tools.lua[/code]
[*]In game, press [b]Insert[/b] → [b]Script Generated UI[/b] → [b]Otomo Tools[/b].
[*]Pick a preset, or set a target per tool and press [b]tune[/b].
[*]Leave the hub and start a quest; the values are applied when the game sets the Palico up.
[*][b]Restore original cooltimes[/b] puts everything back.
[/list]

Default Steam path:
[code]...\steamapps\common\MonsterHunterWilds\[/code]

[line]

[size=5][b]Status and limits[/b][/size]

[list]
[*][b]Your Palico only.[/b] Only your own (master) Palico is modified.
[*][b]Quest only.[/b] Values are applied during a quest, never on results or loading screens.
[*][b]Data-only, no hooks.[/b] The mod writes the tool parameter values and reads them back to confirm. It never calls an action or plays an animation.
[*][b]No save editing.[/b] It does not write save data and does not modify game files.
[*][b]The counter is read-only.[/b] It reads the game's own condition flags; nothing is written by it.
[*]Reload any time: REFramework → [b]Reset scripts[/b], or restart the game.
[/list]

[line]

[size=5][b]Safety[/b][/size]

[list]
[*][b]No hooks[/b] and no action calls, which is what tends to crash this class of mod.
[*]Every SDK call is guarded, and every write is verified by reading the value back.
[*]As with any mod that changes live game state, a game-side access violation is still possible; use at your own risk.
[/list]

[line]

[size=5][b]Requirements[/b][/size]

[list]
[*]Monster Hunter Wilds
[*][url=https://www.nexusmods.com/monsterhunterwilds]REFramework for MH Wilds[/url] (install [b]dinput8.dll[/b] first)
[/list]

[line]

[size=5][b]Changelog[/b][/size]

[b]1.0.3[/b]
[list]
[*]Live buff state at the top of the panel (buff now: UP / down) next to the use count.
[/list]

[b]1.0.2[/b]
[list]
[*]Live buff state added to the counter.
[/list]

[b]1.0.1[/b]
[list]
[*]Global cooldown controls (-30 / +30 / leave as-is). The horns ignore the global cooldown and keep using their own.
[/list]

[b]1.0.0[/b]
[list]
[*]Release: per-tool cooldown tuning, presets, restore originals, horn counter.
[*]No hooks; all writes verified by read-back.
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
1.0.3
- Live buff state at the top of the panel (buff now: UP / down) next to the use count.

1.0.2
- Live buff state added to the counter.

1.0.1
- Global cooldown controls (-30 / +30 / leave as-is). The horns ignore the global cooldown.

1.0.0
- Release: per-tool cooldown tuning, presets, restore originals, horn counter.
- No hooks; all writes verified by read-back.
```

**File to upload:** `dist/OtomoTools-1.0.3.zip`

**Suggested Nexus metadata:**
- Category: Gameplay
- Version: 1.0.3
- Requirements: REFramework for MH Wilds
- Companion: Useful Palico Horn (optional)
