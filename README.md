# Otomo Tools

A REFramework mod for Monster Hunter Wilds that makes the Palico use a chosen
support move more often — first target, the Attack-Up horn ("the trumpet"), but
every Palico tool is configurable.

## Status

**v0.3.0 — data tuning + a read-only horn counter.** The Palico's tool cooldowns
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
| Rewrites `_CoolTime` / `_CoolTime_PowerUp` for the tools you pick | Call any game action or animation |
| Optionally rewrites the 90 s `_GlobalCoolTime` | Write anything it could not read first |
| Restores the shipping values on demand | Touch the game's files or pak |
| Works in the hub (where the game copies these values into the otomo) | Overflow past the enum (sentinels are filtered) |

## Presets

| Preset | Targets |
|---|---|
| `horn_attack` (default) | `HORN_ATKUP` → 90 s |
| `horn_both` | both horns → 90 s |
| `healing` | every `*HEAL*` tool → 60 s |
| `custom` | whatever you set in the panel |

Every tool also has `-30` / `+30` / `tune`|`off` controls in the panel.

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
