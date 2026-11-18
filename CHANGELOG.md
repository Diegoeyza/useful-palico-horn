# Changelog

## 0.3.0 — 2026-11-18

- **Read-only horn counter.** Watches the Attack-Up buff go off → on and reports
  uses, uptime and the last use, so the effect of the cooldown change can be
  measured instead of eyeballed.
- Resolves the signal by method name (`isActiveAttackUp`, falling back to
  `isEnableAttackUpIcon`) starting from the master control and the otomo
  character; the chosen object and every other candidate are dumped to
  `otomo_counter_diag.json` so a wrong target is visible rather than silent.
- Writes `otomo_counter.json` on every transition (and about once a minute for
  `observed_sec`). It never writes to the game.
- Panel: `horn uses / uptime% / last` plus **Reset counter**.
- Tests: 86 logic + 23 pipeline = 109, including the transition state machine
  (off→on counts, on→on does not, on→off adds duration, an unknown signal
  changes nothing, a missing clock still counts).

## 0.2.1 — 2026-11-18

**The catalog write was a no-op and the trace proved it:**

```
16:35:00 HORN_ATKUP _CoolTime 600 -> 600 (want 90)
```

`REField:set_data()` returns without error on these `app.user_data` fields but
changes nothing — exactly the failure mode `MODDING-NOTES.md` §4.3 warns about.

- New write path, verified by read-back after every attempt:
  1. `obj:set_field(name, value)` (RSZ-aware; the one that works on
     `via.user_data` elsewhere in this install),
  2. `REField:set_data(obj, value)`,
  3. runtime fallback: `mcOtomoToolManager:getOtomoToolManagedClass(type)` →
     `setCoolTime(seconds)` on the live `cOtomoToolManagedBase`.
- The strategy that actually worked is now named in the trace
  (`600 -> 90 via set_field`), so a regression is visible immediately.
- One-shot diagnostic `otomo_write_test.json`: field type/size/value-type, the
  value after each strategy, whether the runtime tool manager was found and by
  which path.
- Tests: 71 logic + 23 pipeline = 94, now including "set_field wins" and "a
  refusing field is reported as failed, not as success".

## 0.2.0 — 2026-11-18

**The probe changed the design.** The Palico's tool cooldowns are plain data, and
the Attack-Up horn's was **600 seconds** in the shipping build.

Measured from `otomo_probe_instance.json` (`OtomoManager.Catalog.GlobalParam`):

| Param | `_CoolTime` | `_CoolTime_PowerUp` |
|---|---|---|
| `_Horn_AtkUp` | 600 | 480 |
| `_Horn_DefUp` | 10 | 10 |
| `_Slinger` | 360 | 360 |
| `_SetFlashTrap` | 360 | 270 |
| `_StealBoomerang` | 210 | 150 |
| `_GlobalCoolTime` | 90 | — |

- **Replaced the v0.1 design.** `resetCoolTimeSingle` does exist, but on the
  per-tool `app.cOtomoToolManagedBase`, reachable only through the otomo's
  mini-component holder, which the probe could not resolve. v0.1 called it on
  the manager with the wrong arity, so it silently did nothing.
- **New lever: data tuning.** Writes `_CoolTime` (and `_CoolTime_PowerUp`) on the
  `app.user_data.OtomoToolParam_*` objects, which are reachable in one hop from
  `OtomoManager._Catalog._GlobalParam._OtomoToolParam`.
- Every write is read back before it is reported (`set_data` return values are
  not trustworthy).
- Optional `global_cooltime_sec` rewrites `_GlobalCoolTime` (default: untouched).
- **Restore original cooltimes** button puts the shipping values back.
- Presets now match the real, uppercase enum members (`HORN_ATKUP`), and the
  enum→param-field mapping has an explicit table plus a normalized fallback that
  returns nil rather than guessing.
- Tests: 71 logic + 19 pipeline = 90.

## 0.1.1 — 2026-11-18

- Fix: `imgui.text_wrapped` does not exist on this REFramework build
  (`dinput8.dll` registers `text` and `text_colored` only). Calling it threw
  inside the tree node, which is what produced ImGui's **"Missing TreePop()"**.
  Replaced with a local word-wrap + `imgui.text`, and the UI is now told to use
  `text_wrapped` only if the binding exists.
- Fix: `imgui.tree_pop()` now runs outside the body's `pcall`, so a future
  exception can never leave a tree node open again.
- Tests: 59 logic + 18 pipeline (77 total), including the wrap behaviour.

## 0.1.0 — 2026-11-18

- First build. Tier A only: clears the per-tool cooldown (and optionally the
  global cooldown) for the selected Otomo tools so the game's own AI can choose
  them more often.
- Default preset `horn_attack` targets the Attack-Up horn.
- Presets are Lua patterns over the live enum names, so a patch that renames
  an enum member does not silently disable the mod.
- Optional tools: `horn_both`, `healing`; per-tool `cooldown` / `off` toggle.
- Safety: master otomo only, quest-only gate, never writes when the live state
  is unknown, never resets the tool currently in use, arity- and type-checked
  method calls, crash-survivable trace ring (`otomo_tools_trace.json`).
- Offline tests: 45 assertions under Lua 5.1.
