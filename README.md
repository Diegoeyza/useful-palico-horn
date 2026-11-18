# Otomo Tools

A REFramework mod for Monster Hunter Wilds that makes the Palico use a chosen
support move more often — first target, the Attack-Up horn ("the trumpet"), but
every Palico tool is configurable.

## Status

**v0.1.1 — Tier A only (state-level cooldown control).** Built, offline-tested,
not yet verified against a live build. See `docs/VERIFY.md`.

## What it does / does not do

| Does | Does not |
|---|---|
| Clears the per-tool cooldown (and optionally the global cooldown) for tools you pick | Call `useOtomoTool` / drive the animation |
| Reads the live tool state and only writes when the game says "on cooldown" | Write every tick regardless of state |
| Runs only during a quest, only on the master Palico | Touch networked Palico replicas |

The design rule comes from this workspace's notes (`MODDING-NOTES.md` §7.2/§7.4):
mutate state, never drive the action. The Nexus mod that did the quest-start
version of this by forcing the tool has a long crash thread; this takes the
boring path on purpose.

## Layout

```
reframework/otomo_tools.lua   the mod
tools/otomo_probe.lua         read-only discovery probe (not shipped)
tests/logic_test.lua          offline tests (Lua 5.1)
docs/VERIFY.md                live verification checklist
package.sh                    builds dist/ bundles
```

## Test

```sh
LUA=/tmp/opencode/lua51/lua ./tests/run.sh
```

Covers config normalisation (including hostile/partial configs), presets as
patterns, the tick schedule, the quest gate, the reset planner's "never write
without live state" rule, and a save→load→normalise round trip.

## Probe first

`tools/otomo_probe.lua` must be run once on a live build before the mod is
trusted: it resolves which object actually owns `mcOtomoToolManager`, dumps the
real `USE_OTOMO_TOOL_TYPE` members with their numeric values, and records a
per-2s timeline of `canUseOtomoTool` / cooldown / horn-buff through a hunt.

That timeline is what says whether the cooldown lever (this mod) is sufficient
or whether the desire/lottery side has to be biased too.

## Install

Copy `reframework/otomo_tools.lua` to `<game>\reframework\autorun\`, then
REFramework → Script → Reset scripts.
