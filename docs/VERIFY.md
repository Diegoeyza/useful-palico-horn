# Otomo Tools — verification plan

The pure logic is covered offline by `tests/` (45 assertions under Lua 5.1).
What cannot be faked is the game, so this is the order that finds real problems
fastest. Run it after a game patch and before every release.

## 0. Probe first (once per patch)

The probe answers the questions the mod is built on. Without it, v0.1.0 is an
educated guess.

1. Copy `tools/otomo_probe.lua` to `<game>\reframework\autorun\`.
2. REFramework → Script → **Reset scripts**.
3. **Dump types** (safe anywhere). Read `otomo_probe_types.json`:
   - does `app.mcOtomoToolManager` exist, and does it declare
     `canUseOtomoTool` / `resetCoolTimeSingle` / `resetGCDTimer`?
   - which of `USE_OTOMO_TOOL_TYPE` / `_Fixed` / `OTOMO_TOOL_TYPE` has values,
     and what are the numeric values of the horn members?
   - does `app.OtomoDef` resolve as a nested type, or are the enums `app.X`?
4. In a quest, press **Resolve instance**. Read `otomo_probe_instance.json`:
   - `resolved_manager: true` and which `tools_hits[].path` produced it —
     compare it with the routes in `otomo_tools.lua`'s `resolve_manager()`.
   - `character_hits` — the master otomo was reachable at all.
   - `buff_owners` — which type owns `isActiveAttackUp`.
5. Leave **Watch** on for a full hunt. Read `otomo_probe_watch.json`:
   - `tools[]` with `can=false` and `ok=false` most of the time → cooldown is
     the blocker → **Tier A is the right lever**.
   - `can=true` but the tool is never `using` → desire/lottery is the blocker →
     Tier C (`restrict` / desire bias) is required.
   - `can=true, ok=true` but rare → proximity/animation gating; check the
     Palico's distance (`MoveToPLUseOtomoToolDist`).
6. Remove the probe from `autorun/` when the JSON is read (do not ship it).

## 1. Load and version

1. Copy `reframework/otomo_tools.lua` to `<game>\reframework\autorun\`.
2. REFramework → Script → Reset scripts.
3. Insert → Script Generated UI → **Otomo Tools**. The title must read
   `v0.1.0`; if it does not, the file did not reach the game.
4. `re2_framework_log.txt` must contain `[OtomoTools] loaded v0.1.0 (…)`.

## 2. Baseline vs mod (the actual claim)

1. Without the mod (or with **Enabled** off), record a 10-minute hunt: how many
   times did the Palico use the Attack-Up horn? Watch the buff icon, or read the
   probe's `using` transitions.
2. Enable the mod with `horn_attack`. Same quest, same Palico gear, 10 minutes.
3. The horn count must rise; there must be no Lua error and no crash.
4. The panel's `last reset:` line names `Horn_AtkUp` right after a cast, and
   `otomo_tools_trace.json` shows `reset Horn_AtkUp (<n>)` lines.

## 3. Gates

| Check | Expected |
|---|---|
| Results screen / end screen | no reset lines in the trace |
| Loading screen | no reset lines |
| Hub (not playing) | no reset lines |
| Second player's Palico | never touched (only `getMasterOtomoManagedControl`) |
| Reset scripts mid-quest | reloads cleanly, no duplicate callbacks |

## 4. Failure modes to look for

- **No manager**: panel says `manager: not found (retrying)`. The route in
  `resolve_manager()` is wrong for this patch — fix against the probe dump.
- **Enum empty**: panel lists no tools. `USE_OTOMO_TOOL_TYPE` was renamed;
  check the probe's `enums[]`.
- **Buff never appears** but resets are happening: the cooldown was never the
  blocker → go to Tier C.
- **Crash**: check `otomo_tools_trace.json` for the last line. That is the
  breadcrumb the game log cannot give you (`MODDING-NOTES.md` §1, §9).

## 5. Release gate

1. `LUA=/tmp/opencode/lua51/lua ./tests/run.sh` → all pass, no unexpected
   globals.
2. `./package.sh` → `dist/OtomoTools-<ver>.zip`.
3. `cmp -s` the deployed file against the repo copy.
4. Only the newest zip in `C:\Users\diego\Downloads\`.
