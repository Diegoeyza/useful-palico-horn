# Otomo Tools

A REFramework mod for Monster Hunter Wilds that makes the Palico use a chosen
support move more often — first target, the Attack-Up horn ("the trumpet"), but
every Palico tool is configurable.

## Status

**v0.5.0 — data tuning, a horn counter, and an opt-in force-use.** The Palico's tool cooldowns
are plain data, and the Attack-Up horn ships with a **600 s** cooldown. This mod
writes that number down to whatever you pick (default 90 s), per tool, and
counts how often the buff actually goes up so the result can be measured.

Verified in game: the value writes and sticks (`600 -> 90 via set_field`), and
the game does not re-assert it. Not yet verified: how much the AI's desire gate
then limits actual use — the counter answers that.

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
