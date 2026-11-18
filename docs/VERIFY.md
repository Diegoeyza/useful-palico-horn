# Otomo Tools — verification plan

The pure logic and the apply path are covered offline by `tests/` (90
assertions under Lua 5.1). What cannot be faked is the game, so this is the
order that finds real problems fastest.

## 0. What the probe already established (2026-11-18)

`otomo_probe_types.json` / `otomo_probe_instance.json` answered the open
questions; these are facts now, not assumptions:

- `app.OtomoDef.USE_OTOMO_TOOL_TYPE` exists with numeric values
  (`HORN_ATKUP = 2`, `HORN_DEFUP = 3`, `MAX = 14`, `NONE = -1`).
- `app.mcOtomoToolManager` exists, but its live instance is **not** reachable
  from `OtomoManager` by the routes tried (the character's `_Components` is a
  `COMPONENT_HOLDER`, not an array). Not used by the mod.
- The tool params are reachable in one hop:
  `OtomoManager._Catalog._GlobalParam._OtomoToolParam`.
- Shipping values: `_Horn_AtkUp._CoolTime = 600`, `_CoolTime_PowerUp = 480`,
  `_GlobalCoolTime = 90`, `_Horn_DefUp._CoolTime = 10`.

## 1. Load and version

1. Copy `reframework/otomo_tools.lua` to `<game>\reframework\autorun\`.
2. REFramework → Script → Reset scripts.
3. Insert → Script Generated UI → **Otomo Tools**. The title must read
   `v0.2.1`; if it does not, the file did not reach the game.
4. `re2_framework_log.txt` must contain `[OtomoTools] loaded v0.2.1 (…)`.
5. `otomo_tools_trace.json` shows `loaded v0.2.1 … tools=14` and, once in the
   hub or a quest, `param root resolved (N fields)`.

## 2. The write lands

1. In the **hub**, open the panel. `tool params: resolved` must appear.
2. `HORN_ATKUP tune now=600 want=90` before the first apply, then
   `now=90` after the next interval (~5 s).
3. The trace gains `HORN_ATKUP _CoolTime 600 -> 90 via <strategy>`.
4. **Restore original cooltimes** puts `now=600` back (and the trace says so).

If the trace says `600 -> 600`, the write did not land. v0.2.1 tries
`set_field`, then `set_data`, then the runtime object, and writes
`reframework\data\otomo_write_test.json` with what happened:

| Key | Meaning |
|---|---|
| `strategy` | `set_field`, `set_data`, `failed` |
| `field_type` / `field_size` / `value_type` | the field's real shape |
| `after_set_field`, `after_set_data` | the read-back after each attempt |
| `managed_found` | was the runtime `cOtomoToolManagedBase` reachable |
| `tool_manager_path` | how the manager was found, if it was |

A `strategy: "failed"` with `managed_found: false` means the catalog is
read-only on this build and the runtime path still has to be cracked — send that
JSON back.

If `now=` stays `nil`, the field mapping did not resolve — check that the panel
lists `HORN_ATKUP` and that `param root resolved` appeared.

## 3. Does the game honour it (the real test)

This is the part that cannot be automated: the params are copied into the
per-tool runtime object when the otomo is set up, so the change takes effect
from the **next quest**.

1. Baseline: with the mod **disabled**, hunt 10 minutes and count horn uses
   (a use is visible as the buff icon appearing).
2. Enable `horn_attack` in the hub, start the same quest, count again.
3. Expected: at least one use per ~2 minutes instead of one per 10, i.e. 4–5
   uses in 10 minutes.

If the count does not move, the cooldown was not the limiter. Then check, in
this order:

| Symptom | Meaning | Next step |
|---|---|---|
| `now=90` but uses unchanged | the managed copy was made before the write, or desire gates it | re-apply at quest start, then investigate `cOtomoToolManagedBase` |
| uses rise but cap at ~2/min | some other timer (animation, `_CheckAreaMoveTime`, GCD) | lower `global_cooltime_sec` too, then re-measure |
| the Palico stands near you and never plays | `MoveToPLUseOtomoToolDist` / `_ActiveRange` | not a cooldown problem |

## 4. Gates

| Check | Expected |
|---|---|
| Loading screen | no writes in the trace |
| Results / end screen | no writes |
| Quest with the mod off | no writes |
| Second player's Palico | untouched (only the global param data is edited) |
| Reset scripts | reloads cleanly, config kept |

## 5. Failure modes

- **`tool params: not resolved yet`** — the catalog is not loaded (title screen)
  or the field path changed in a patch. The trace's `param root resolved` is the
  marker; if the type moved, fix `resolve_param_root()` against a fresh probe.
- **`now=nil` for a tool** — `param_field_for()` returned nil or the object is
  missing. It is deliberately conservative: it will not write a guessed field.
- **Values revert between quests** — the game reloads the param data per stage.
  The mod re-applies every interval; if the revert is after the otomo setup, the
  change will not take effect that quest. Note it in the trace.

## 6. Release gate

1. `LUA=/tmp/opencode/lua51/lua ./tests/run.sh` → all pass, no unexpected
   globals.
2. `./package.sh` → `dist/OtomoTools-<ver>.zip`.
3. `cmp -s` the deployed file against the repo copy.
4. Remove `otomo_probe.lua` from `autorun/` (the probe is not shipped).
5. Only the newest zip in `C:\Users\diego\Downloads\`.
