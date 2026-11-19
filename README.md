# Otomo mods

Two sibling REFramework mods for Monster Hunter Wilds, one repo, installed
independently:

| Mod | File | What it does |
|---|---|---|
| **Otomo Tools** | `reframework/otomo_tools.lua` | Data only, zero hooks: rewrites the Palico's tool cooldowns (the Attack-Up horn ships at 600 s), optionally the global cooldown, and counts horn uses / uptime. |
| **Useful Palico Horn** | `reframework/useful_palico_horn.lua` | Fires the horn's action on command (default **F6**), so the buff lands on a paralysis or a trap instead of whenever the AI decides. Bypasses the tool cooldown entirely. |

They do not conflict and can run together. Splitting them is deliberate: Otomo
Tools only writes user data and can never drive the game, while Otomo Horn
performs an action. Different risk, different product.

## Otomo Tools

Makes the Palico use a chosen support move more often — first target, the
Attack-Up horn ("the trumpet"), but every Palico tool is configurable.

### Status

**v1.0.3 — cooldown tuning + a read-only counter. No hooks.**

The Palico's tool cooldowns are plain data, and the Attack-Up horn ships with a
**600 s** cooldown. This mod writes that number down per tool and counts how
often the buff actually goes up, with a live `buff now: UP / down` line at the
top of the panel.

Measured in game: the write reaches the runtime (`_CoolTime` 600 → 90 on the
live tool object), and the effect is roughly **double** the frequency (~1.6-2
uses per 10 min against a ceiling of ~1 at 600 s). The real limiter turned out
to be the AI's desire gate, not the cooldown — see `CHANGELOG.md` and
`docs/CRASH-TEST.md` for the measurements that established it, and `Otomo Horn`
for the mod that solves the timing properly.

## How it works

The Palico tools live in `app.user_data.OtomoToolParam`, one child object per
tool, reachable in one hop from `OtomoManager.Catalog.GlobalParam.OtomoToolParam`:

```
_Horn_AtkUp._CoolTime        600   -> 90
_Horn_AtkUp._CoolTime_PowerUp 480  -> 90
```

Each write is read back before it is reported. Nothing is triggered, animated,
hooked, or called: this is a data edit, which is why it has no crash surface.

The per-tool runtime object (`app.cOtomoToolManagedBase`) does have
`resetCoolTimeSingle()` / `setCoolTime()`, but it is only reachable through the
otomo's mini-component holder, which the probe could not resolve — so this mod
does not use it.

## What it does / does not do

| Does | Does not |
|---|---|
| Rewrites `_CoolTime` / `_CoolTime_PowerUp` for the tools you pick | Call any action, animation, or game method (no hooks) |
| Optionally rewrites the 90 s `_GlobalCoolTime` | Write anything it could not read first |
| Counts horn uses / uptime / uses per 10 min | Change which tool the AI chooses |
| Restores the shipping values on demand | Touch the game's files or pak |

## Presets

| Preset | Targets |
|---|---|
| `horn_attack` (default) | `HORN_ATKUP` → 90 s |
| `horn_both` | both horns → 90 s |
| `healing` | every `*HEAL*` tool → 60 s |
| `custom` | whatever you set in the panel |

Every tool also has `-30` / `+30` / `tune`|`off` controls in the panel.

**Quiet the other tools** (off by default) is the second lever: it raises the
cooldown of every tool you did *not* pick, so the Palico has fewer alternatives
and picks yours more often. It is a data edit too — turning the toggle off puts
the previous values straight back. It does mean the Palico will use its healing
and traps far less while it is on.

## Measuring it

The panel counts every time the Attack-Up buff goes off → on:

```
horn uses: 4   uptime: 12.3%   last: 17:22:41
in quests: 4 uses over 610 s  (= 3.9 per 10 min)
```

`reframework/data/otomo_counter.json` has the same numbers per candidate signal
(sorted by uses), so if the counter ever targets the wrong object it is visible
rather than silent.

## Layout

```
reframework/otomo_tools.lua   the mod
tools/otomo_probe.lua         read-only discovery probe (not shipped)
tests/                        offline tests, Lua 5.1
docs/VERIFY.md                live verification checklist
package.sh                    builds dist/ bundles
```

## Test

```sh
LUA=/tmp/opencode/lua51/lua ./tests/run.sh
```

109 assertions: config normalisation and legacy migration, case-insensitive
presets, the enum→param-field mapping, the "never write what you could not read"
rule, the write gate, the full apply/restore path against fake param objects,
the write-strategy ladder (`set_field` first), the horn counter's transition
state machine, and the tick schedule.

## Install

Copy `reframework/otomo_tools.lua` to `<game>\reframework\autorun\`, then
REFramework → Script → Reset scripts.

Enabling it **in the hub** is better than mid-quest: the game copies these
values into the otomo when it is set up, so a hub change applies from the next
quest.
