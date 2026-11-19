# Changelog

## 1.0.2 — 2026-11-18

- Panel shows the live buff state (`buff now: UP / down`) next to the counter.
  `uptime` only closes when the buff ends, so there was no way to tell from the
  UI whether it was currently active.

## Unreleased — dev tools: the crash claim is false, and the action is inert

`tools/otomo_trigger.lua` calls `useOtomoTool()` once on demand. **Result on
this build: no crash** — returned `Void`, survived 300 frames.

But it also did nothing: 0 uses, 0 uptime, no buff. The call is the tail of a
state machine, and `update()` only enters that state when the tool's predicates
agree. Driving the action is therefore *safe and useless*, not dangerous.

The dump that came back is the real find — `app.cOtomoToolManaged_Horn_AtkUp`
exposes:

```
checkEnable()               Boolean   allowed at all
isDesireActivate()          Boolean   the AI's desire  <- the gate
useOtomoToolRequirement()   Boolean   cooldown / range / busy
useOtomoTool()              Void      performs the use
update()                    Void      per-frame driver
```

So the desire gate was never "not exposed"; it is a readable method. `v0.6.0`
missed it because `canUseOtomoTool` is on the base class and this type does not
override it — that is why 16 hits changed nothing.

`tools/otomo_watch.lua` reads the three predicates at 10 Hz and records every
transition. Measured over 190 s in a quest (~18 Hz, 3460 polls):

| Predicate | True | Share |
|---|---|---|
| `checkEnable()` | 3460 / 3460 | 100.0 % |
| `useOtomoToolRequirement()` | 3460 / 3460 | 100.0 % |
| `isDesireActivate()` | 76 / 3460 | 2.2 % |

One 7 s desire window, and the horn fired inside it. **The only gate that ever
closes is desire**, which is also why the 90 s cooldown changed so little: the
cooldown was almost never the blocker.

Two things broke the first three attempts at overriding it:

- `sdk.hook()` returns `nil` on this build **even when it installs**. Calls are the
  only reliable success signal (5949 in 58 s).
- `getOtomoToolManagedClass(HORN_ATKUP)` returns a **different object** than the
  one whose `isDesireActivate()` the AI updates:

  ```
  hook `this`:  userdata: 0000000CB046EA40   <- the runtime object
  manager:      userdata: 0000000D80C257B0   <- not this one
  ```

  Every earlier version filtered on the manager's address, so nothing matched.
  `distinct_this` is 1, so "force on every call" is unambiguous and the manager
  lookup is not needed at all.

`tools/otomo_desire.lua` hooks `isDesireActivate()` and returns true while armed.
Measured with on-demand 6 s pulses (12 presses, one 317 s hunt, outcome
attributed automatically from the counter): **2 presses, 2 uses** - and both
were the presses made while the horn was available. Every blocked press fell
inside a ~210-226 s refractory period after the previous use, much longer than
the 30 s `_CoolTime` configured for that run (consistent with a ~3 min buff plus
the cooldown).

**The horn fires on demand, once per ~3.5-4 minutes.** Which means the
speedrun case is solvable by *suppression*, not by forcing: return false from
`isDesireActivate()` so the AI cannot spend the horn at a random moment, then
release it when the monster is paralyzed or trapped.
The game's own `update()` then performs the use, so the animation and effect go
through the normal path - unlike the crash test, which called the action itself
and produced nothing.

Protocol and results: `docs/CRASH-TEST.md`.

The shipped mod is unchanged: v1.0.1, zero hooks.

## 1.0.1 — 2026-11-18

- Added panel controls for `_GlobalCoolTime` (`-30` / `+30` / **leave as-is**).
  It was already supported in the config (`global_cooltime_sec`, default 0) but
  had no UI. "Leave as-is" also restores the shipping value immediately.
- Worth knowing: the horns set `_IsUseOnlyUniqueCoolTime = true`, so they ignore
  the global cooldown entirely — this knob only affects the other tools (traps,
  slinger, bombs, heals).

## 1.0.0 — 2026-11-18

Final. What ships is the part that measurably works, with **no hooks at all**.

### What works

- The Palico's tool cooldowns are `app.user_data.OtomoToolParam_*` values, and
  writing them **does** reach the runtime (verified: live
  `cOtomoToolManagedBase._CoolTime` for `HORN_ATKUP` read 90 while the untouched
  `HORN_DEFUP` read 10).
- Measured effect on the Attack-Up horn: **~1.6–2.0 uses per 10 minutes** with a
  90 s cooldown, against a hard ceiling of ~1 at the shipping 600 s.
- The read-only counter reports uses / uptime / uses-per-10-min and is reliable
  once it resolves the `<StatusManager>` condition manager.

### What was tried and removed

| Lever | Result |
|---|---|
| `requestForceUseOtomoTool()` | accepted (`returns true`) but the AI ignores it — 10 requests, 0 uses |
| Override `cOtomoToolManagedBase.canUseOtomoTool` via hook | matched 16 times in 5 min, still ~1 use: the AI consults that gate only when it already wants the tool |
| Quiet the other tools (raise their cooldowns) | no change; the cooldown was not the limiter |

The remaining gate is the AI's own selection (desire/lottery), which is not
exposed. Overriding it would mean driving the action — the crash class this mod
deliberately avoids.

### Removed in this version

- The manager hook, `requestForceUseOtomoTool` path, and the
  `canUseOtomoTool` override, plus their config and UI.
- The mod is back to **zero hooks**; the only runtime fallback (writing the live
  tool object) is attempted at most once per session and never on this build.

## 0.6.1 — 2026-11-18

## 0.6.0 — 2026-11-18

`requestForceUseOtomoTool` was measured as **accepted but ignored**: 10 requests
over 4 minutes, every one returned true, the AI never acted, 0 uses. The one use
in the previous run happened only because that build asked while
`canUseOtomoTool` (desire included) was already true — i.e. the Palico had
decided to play it anyway.

- Removed the force-use path (dead lever, dead code).
- Added **Always available (experimental)**: hooks
  `app.cOtomoToolManagedBase.canUseOtomoTool` and returns `true` for the chosen
  tool. Per REFramework's docs, `args[2]` is `this` and the post function's
  return value replaces the original (`sdk.to_ptr(true)` for a boolean), with
  `SKIP_ORIGINAL` in the pre.
- The horn's address is resolved **outside** the hook (calling game methods
  inside a hook is a crash surface); the hook body only compares two strings.
- Off by default, lazy install, and the panel shows `override: installed` plus a
  live `hits` counter so it is obvious whether the hook is matching at all.

## 0.5.0 — 2026-11-18

**The probe settled both questions.**

1. The data lever **works**: the live `app.cOtomoToolManagedBase._CoolTime` for
   `HORN_ATKUP` read **90.0** while the untouched `HORN_DEFUP` read 10.0. So the
   writes do reach the runtime — the 502 s gap between uses was the AI choosing
   not to play it, not a stale cooldown.
2. The manager (`app.mcOtomoToolManager`) is an `ace` mini-component with no
   reachable owner, but a pre-hook on `updateMain` hands us `this` in `args[2]`.
   That argument is a **raw pointer**: `is_managed_object()` says true while
   `get_type_definition()` returns nothing, so it must be unwrapped with
   `sdk.to_managed_object` first.

- Adds **Force use when ready** (experimental, **off by default**): once the
  captured manager says `canUseOtomoTool(tool)` and the buff is not up, calls
  the game's own `requestForceUseOtomoTool(tool)` at most once per interval
  (default 20 s), then `resetForceUseOtomoTool` ~5 s later.
- The hook is installed **lazily**, only while the toggle is on — the default
  path stays hook-free.
- Tests: 101 logic + 28 pipeline = 129.

## 0.4.1 — 2026-11-18

The counter was reading the wrong object again, for a new reason: discovery ran
in the hub, where the correct `<StatusManager>._OtomoConditionManager` does not
exist yet, so it latched onto the look-alike `_StockDamage._Condition` (same
type, permanently false). All six channels were that instance.

- Re-discover channels on the **quest start** transition, keeping counters for
  keys that survive.
- Drop a channel after 40 consecutive `nil` reads (a destroyed object), and
  re-discover when every channel has gone stale, rate-limited to ~30 s so the
  walk can never become a per-frame cost.
- `otomo_counter.json` records the per-channel `path`, which is how this was
  spotted at all.
- Quiet-others was measured at 0 uses in 308 s of quest time — but with the
  wrong object, so it is **inconclusive**; the default stays off.

## 0.4.0 — 2026-11-18

The counter found the right signal (`app.cOtomoConditionManager` under the
otomo's `<StatusManager>`) and measured **1 use in 7.6 min** with a 90 s
cooldown — the ceiling was ~6. So the cooldown is no longer the limiter: the
AI's desire is.

- **Tier C: `Quiet the other tools`** (off by default). Raises `_CoolTime` on
  every tool you did *not* pick to `quiet_cooltime_sec` (default 3600), so the
  Palico's choice has fewer alternatives. Same safe data mechanism, opposite
  direction. Turning the toggle off restores the previous values immediately
  (`revert_quiet`), and the tuned tools are never touched.
- **Quest-scoped metrics**: `uses_playing`, `quest_observed_sec` and
  `uses_per_10min`, so hub time no longer dilutes the number. The panel shows
  uses per 10 minutes of actual quest time.
- `Restore original cooltimes` now also covers quieted tools.
- Tests: 94 logic + 28 pipeline = 122.

## 0.3.1 — 2026-11-18

The first counter resolved `app.cOtomoConditionManager:isActiveAttackUp` and read
`0` for a whole hunt — because that object is the **Palico's own** condition
state, not the buff the horn grants the hunter.

- The counter now walks three roots (otomo control, otomo character, the local
  hunter from `PlayerManager._InstancedPlayerList`) and counts **every** signal
  it finds as an independent channel:
  `isActiveAttackUp`, `isEnableAttackUpIcon`, `get_OtomoHorn_Attack` (`> 0`).
- `otomo_counter.json` lists all channels sorted by uses, so one hunt tells us
  which object actually tracks the buff instead of guessing twice.
- The panel shows the leading channel and how many are being watched.
- Also records `playing` with each snapshot, so a hub-only run is obvious.
- Tests unchanged (86 + 23 = 109).

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
