# Changelog

## Useful Palico Horn 1.1.8 — 2026-11-20

User report: triggers still fired while the "next buff" countdown was running.

- **One authoritative gate**: `fire()` refuses while `cooldown_left() > 0`,
  whatever the trigger is. The first hit / quest start exemption is gone. Those
  two still get their chance because the cooldown is reset at quest start; they
  simply no longer override a running timer.
- Panel says it plainly: "applies to every trigger below, without exception".


## Useful Palico Horn 1.1.7 — 2026-11-20

Still `buff objects: 0` after 1.1.6. Three differences from the old counter's
walker, all fixed:

- **Seed the walk with objects resolved directly** (master otomo control, master
  character, `_StockDamage._Condition`) instead of relying on traversal alone.
- **Walk parent types** for fields. `get_fields()` only returns declared fields,
  and the control's fields live on a base class - so the walk found nothing.
- **Accept `isEnableAttackUpIcon` as well as `isActiveAttackUp`**. The old
  counter's chosen signal was `isEnableAttackUpIcon`; both are now read on every
  candidate and either may report the buff.

Trace now logs `buff objects: N (roots M)` and a per-object
`active=.. icon=..` diagnostic.


## Useful Palico Horn 1.1.6 — 2026-11-20

`buff objects: 0` in the trace: the graph walk never left its roots.
`array_len()` returns **0** for an object that is not a collection (the monster
code relies on that), and `children_of` treated any non-nil result as "this is
an array", so every node looked like an empty array and no fields were visited.

- `children_of` now only takes the array path when the length is **> 0**.
- Same guard for the player list lookup.

This is the same class of bug as the other big ones in this mod: a sentinel
value that means two different things (0 = empty vs 0 = not a collection).


## Useful Palico Horn 1.1.5 — 2026-11-20

The buff state never left `down`, even while the horn played. The diagnostic
showed why: every flag on the condition object the mod was reading stayed
false for the whole session - it is not the object that tracks the buff. Earlier
object-graph probing had found **six** candidate objects; the mod had been
narrowed to a single, dead one.

- The buff reader now **walks the object graph** from `app.OtomoManager`, the
  master otomo control and the local hunter (depth 5, 400 nodes), collects every
  object exposing `isActiveAttackUp`, and reports UP if any of them says so.
- The resolved set is refreshed every 10 s and at quest start, and the count is
  logged (`buff objects: N`) plus a `buff diag:` line when the values change.


## Useful Palico Horn 1.1.3 — 2026-11-20

Follow-up to 1.1.2, from the first live test of the quest-start trigger: the horn
fired at the transition, produced no buff, and still consumed the 8 minute
cooldown (panel: `buff: down`, `next buff in 460 s`).

- **Quest-start shot now waits ~4 s** after the quest begins. A request issued
  while the Palico is still spawning is accepted and silently ignored.
- **The buff object is re-resolved** on quest start and every 10 s. It is
  recreated with the quest, and a cached one keeps answering `false`, so
  `buff: down` could be a stale read rather than a real state.
- **No-op fires are refunded.** If no buff is up ~4 s after a fire, the cooldown
  is restored to what it was before, so a silently ignored action cannot lock
  the horn out for 8 minutes.


## Useful Palico Horn 1.1.2 — 2026-11-20

Reported by a user: with the cooldown on, the triggers never fired in a new hunt.

- **The cooldown is now reset at quest start.** It was stored as a wall-clock
  timestamp that survived quest changes, while the game recreates the Palico's
  tool (and its own cooldown) every quest. Firing late in one hunt therefore
  burned minutes of the next one, so "fire when the monster is paralyzed" never
  got a chance. A `quest start (cooldown reset)` line is written to the trace.
- **Per-trigger debounce (3 s).** With the cooldown off, a condition flag that
  flickers true/false could fire the horn several times for one event. Each
  trigger now has its own short latch.


## Useful Palico Horn 1.1.0 — 2026-11-19

- **Renamed** from "Otomo Horn" to **Useful Palico Horn**. "Otomo" is the
  internal term; the public name now says what it does.
- File is now `reframework/autorun/useful_palico_horn.lua`; archives are
  `UsefulPalicoHorn-1.1.0.zip` (Fluffy/Nexus) and
  `useful-palico-horn-1.1.0.zip` (flat/manual).
- Config and trace renamed to `useful_palico_horn.json` /
  `useful_palico_horn_trace.json`. The old `otomo_horn.json` is read once for
  migration, so existing settings survive the rename.


## Otomo Horn 1.0.3 — verified + packaging — 2026-11-19

**All three conditional triggers now verified in game:**

```
PARALYSE   cond change: 5=true/true   -> fire #1 monster paralyzed
STUN (KO)  cond change: 15=true/true  -> fire #1 monster stunned
FIELD_PITFALL  ... trap=true          -> fired
```

- Packaging: the Nexus-layout zips now include `modinfo.ini` (name, version,
  description) so Fluffy Manager / Vortex list them properly.
- Fluffy installs these by extracting into the game folder; the archive root
  already contains `reframework/autorun/`, which is what it needs.


## Otomo Horn 1.0.1 — 2026-11-18

Debugging why paralysis and stun never register while `FIELD_PITFALL` does.

- **Stale-object bug**: the boss objects (`ctx`, `em`, `chara`, `basic`) were
  captured only on the first sighting and never refreshed, so after a quest or
  monster change every condition read was against a dead object. They are now
  updated on every scan.
- `isActive` may only cover "bad conditions" (traps); `isActualActive` is now
  consulted as well, and either returning true counts.
- **Automatic condition dump**: the `_Conditions` array is written to
  `otomo_conditions.json` at baseline and every time the condition signature
  changes (element types plus their numeric/boolean fields), so the encoding of
  paralysis/stun can be read from a single hunt. No UI button, no user action.


## Otomo Horn 1.0.0 — 2026-11-18

Release UI. The panel now contains only what a player needs:

```
Fires the Attack-Up horn on command.
[x] Enabled        [Fire horn now]   hotkey: . (599)
buff: UP

Cooldown           [x] Use the base game cooldown
                     game cooldown: 480 s (8 min)
                     next buff in 431 s
                     applies to every trigger below,
                     except first hit and quest start

Triggers           [ ] On the first hit to the monster
                   [ ] At quest start
                   [ ] When the monster is trapped
                   [ ] When the monster is stunned
                   [ ] When the monster is paralyzed
                   [ ] When the buff runs out

last: fired (first hit)
```

Removed from the UI: hook state, capture counters, monster HP, condition flags,
the condition module name, the config path, and the monster-structure dump
button. All of it still goes to `otomo_horn_trace.json`, so debugging does not
depend on the panel.

Also removed the in-game key rebinding code (`imgui.ImGuiKey` is an empty table
on this build, which is why it never worked). The hotkey lives in
`otomo_horn.json`; the default is `.` = 599.


## Otomo Horn 0.16.2 — 2026-11-18

- Panel order now states the rule before the options: **Cooldown** sits above
  **Triggers**, with the line "when on, EVERY trigger below uses this cooldown"
  and its two exceptions (first hit, quest start) directly underneath.
- The buff-down keep-alive and Dump button moved under the trigger list.


## Otomo Horn 0.16.0 — 2026-11-18

- **Fire at quest start** option: arms on a false->true transition of
  `MissionManager:get_IsPlayingQuest()` and fires as soon as the Palico has been
  captured, so it does not depend on anything else happening.
- **The cooldown now applies to everything except two triggers**: first hit and
  quest start. Hotkey/button, buff-down and trap/stun/paralysis are all held by
  it. A press during the cooldown reports `held by cooldown: N s left` instead
  of silently doing nothing.
- The panel states the rule explicitly:
  `applies to: hotkey, button, buff down, trap/stun/paralysis` and
  `never applies to: first hit, quest start`.
- The countdown is labelled `next buff in N s` rather than "automatic fire",
  since it now gates manual fires too.


## Otomo Horn 0.15.1 — 2026-11-18

- `status: not found` was a real bug: the status lookup still asked for
  `StatusManager`/`Condition` while the actual module is `em.Conditions`
  (`app.cEmModuleConditions`). The plural is tried first now.
- Shock traps are not a `FIELD_PITFALL` condition, so `getTrapCondition()` is
  also consulted as a trap signal (boolean or condition id >= 0).
- Diagnostics: the trace now carries a one-time `conditions:` line (module type,
  whether `isActive` was found, and all three flag values) and the periodic
  `status:` line includes `trap= stun= para=`.


## Otomo Horn 0.15.0 — 2026-11-18

The real API, from a dump taken during a pitfall trap:

```
app.EnemyDef.CONDITION:
  PARALYSE=5  PARALYSE_EM=6  STUN=15  STUN_EM=16  CAPTURE=17
  FIELD_PITFALL=31  TRAP_FALL=39  TRAP_PARALYSE=40  TRAP_IVY=41 ...

app.cEmModuleConditions: isActive(CONDITION), isActualActive, getTrapCondition
```

So the flags are **condition ids**, not named properties. Now:

- paralyzed -> `isActive(5)` or `isActive(6)`
- stunned   -> `isActive(15)` or `isActive(16)`
- trapped   -> `isActive(31/39/40/41/42/43)`

The name-based guesses remain as a fallback. `isActive` returning a boolean is
the source of truth; `nil` means the method was not found (as opposed to "not
active"), and the two cases are kept distinct.

Also confirmed from the trap dump: the trap is **not** an AI state
(`ai_state=2` COMBAT, `is_capture=false`), which is why the AI-state approach
would not have worked.


## Otomo Horn 0.14.0 — 2026-11-18

From the module dump: `cEmModuleConditions` names Angry, Blast, Block, Capture,
FieldPitfall, Flash, Koyasi, SandDig, SmokeBall, Stamina, Tired - **no paralysis
or stun**. Those are therefore modelled as AI states/interrupts, so the dump now
also records:

- enum members for `EnemyDef.AI_STATE_ID`, `AI_INTERRUPT_ID`, `CONDITION`,
  `EXTRA_STATE`, `CharacterDef.STAND_STATE`
- the type/methods/fields of the individual condition objects (Capture,
  FieldPitfall, Flash, Blast, Tired, Koyasi, SandDig)
- live values: `ExtraState`, `StandState`, `DownDirection`,
  `CurrentAIStateID`, `CurrentAIInterruptID`, `IsCapture`, `IsFlash`

A dump taken during a paralysis/trap is the missing sample: the baseline state
is already captured, so the delta names the flag.


## Otomo Horn 0.13.0 — 2026-11-18

Structural dump from a hunt showed where the monster state actually lives:

```
em = app.cEnemyContext
   Conditions : app.cEmModuleConditions
   Capture    : app.cEmModuleCapture
   Catch      : app.cEmModuleCatch
   AIStateManager, DownDirection, ExtraState, StandState
chara = app.cCharacterContext   <- only HealthManager + FieldAreaInfo
```

So the flags are on the enemy *modules*, not under `chara` where 0.12.0 was
looking. The flag candidates are now tried on `Conditions`, `Capture`, `Catch`
and `AIStateManager` first, with `isX`-style spellings added, and the dump
includes those modules' methods and fields so the names can be read directly.


## Otomo Horn 0.12.0 — 2026-11-18

- **Conditional buffing**: `Fire when the monster is trapped / stunned /
  paralyzed`, each on a rising edge so it fires once per event, not every scan.
- Flags are read from the monster's status manager (`Chara`/`Em`/`Context` ->
  `StatusManager` or `Condition`) with several candidate accessor names, and the
  panel shows the live state: `flags: trap=? stun=? para=?`.
- **Dump monster structure** button: writes the real type, method and field
  names of `ctx`, `em`, `basic`, `chara` and `status` to
  `monster_flags.json` (read-only). The accessor names for these three flags are
  not documented anywhere, so this is how they get corrected from data instead
  of guessed again.


## Otomo Horn 0.11.2 — 2026-11-18

- Default hotkey corrected to **599**, which is what `.` reports on this build
  (stock ImGui uses 587, so the label table only keeps values confirmed in game).
- Removed the "Log keys" diagnostic button; the key value is known, and it had
  no use left.


## Otomo Horn 0.11.1 — 2026-11-18

- **Base game cooldown is 8 minutes (480 s)**, hardcoded. It was reading
  `_Horn_AtkUp._CoolTime` from the tool params, which is *user data* - so with
  Otomo Tools installed it reported the rewritten value (30 s) instead of the
  game default. The panel now shows `game cooldown: 480 s (8 min)`.


## Otomo Horn 0.11.0 — 2026-11-18

- **Default hotkey is now `.` (period, value 587).** It is the one key the game
  does not use; every function key is bound to something. The config keeps the
  raw ImGui value, so nothing depends on the (empty) key enum.
- Fixed the reason rebinding appeared broken: `resolve_key()` never cleared
  `state.key`, so it stayed on the first value it ever resolved — the panel
  showed `key: 546 (508)`, config 546 but the mod still listening on 508.
- The panel now shows a readable label (`hotkey: . (587)`) for the common keys.


## Otomo Horn 0.8.0 — 2026-11-18

- The key scan bound **691**, which is not a key: ImGui's named-key table ends
  around 616 and reading past it returns garbage because asserts are compiled
  out. The scan is now capped at **600** (letters and F1-F12 all live below 584),
  requires the same value down for **two consecutive frames**, and cancels after
  10 s. A modifier combo binds the highest value, i.e. the real key.
- Hotkey in the config reset to `0` so a stale garbage value cannot fire.


## Otomo Horn 0.7.0 — 2026-11-18

- **Key binding could never work as written.** `imgui.ImGuiKey` is an empty
  table on this build (so there were no names to bind), and the numeric fallback
  scanned 150 values per frame with `is_key_pressed`, which is edge-triggered -
  a press was only seen if the key's value happened to be in the chunk being
  scanned on that exact frame.
- The scan now runs the **whole range (0..700) every frame** using
  `is_key_down` (level-triggered) and binds the highest value found, so a
  modifier combo binds the actual key rather than Ctrl/Shift. The trace records
  the bound value and every value that was down.
- Confirmed from REFramework's source that `imgui.is_key_pressed(int)` takes the
  raw `ImGuiKey` value, so a numeric hotkey in the config is valid.


## Otomo Horn 0.5.0 — 2026-11-18

- **Bind the hotkey in the panel.** Every function key already does something
  in game, so guessing a name was the wrong approach: click *Bind hotkey*, press
  the key you want, and it is stored by its enum name in the config (Escape
  cancels). The key list is enumerated from `imgui.ImGuiKey` at load.
- The key that is bound cannot fire the mod on the same press (30-frame block),
  and Escape never becomes a hotkey.
- Default remains F9, but binding makes the default irrelevant.


## Otomo Horn 0.4.0 — 2026-11-18

**Critical fix: nothing fired at all.** `REMETHODDefinition:get_full_name()`
returns `nil` on this build, so the `System.Int32` overload check in 0.3.0 never
matched, `state.method` stayed nil, and every trigger was skipped with
"no action method". The signature is now read from `get_param_types()`, which
does work. (The 0.1.0 probe worked only because it fell back to any 2-param
overload.)

- **Global cooldown is now a toggle** (`global_cooldown_enabled`), with the
  seconds value shown only when it is on.
- Default hotkey moved from **F6 to F9**; F6 opens the game's radial menu.
- Diagnostics: a `status:` line every ~5 s in the trace (hook, captures, buff,
  monster, fires, last result), plus a `request:` line for every trigger and a
  `key pressed` log, so a silent failure is visible without guessing.


## Otomo Horn 0.3.0 — 2026-11-18

- **Fire on the first hit to the monster**: reads the target's health from
  `app.EnemyManager` (`_EnemyList` -> array -> `Context` -> `Chara` ->
  `HealthManager` -> `Health`/`MaxHealth`, boss-filtered via `Em.Basic.IsBoss`)
  and fires once when HP first drops below max. The latch re-arms when the
  monster is back at full HP, so the next hunt/monster triggers again.
- Every accessor is attempted as `get_X()`, `X()`, `_X` and `X`, and the trace
  records which spelling worked, because the exact names could not be verified
  offline.
- The panel shows `monster: full HP / damaged` with the HP values, so a wrong
  chain is visible immediately instead of silently doing nothing.
- Event triggers (first hit, manual) are not gated by the global cooldown; only
  the keep-alive ("fire when the buff is down") is.


## Otomo Horn 0.2.0 — 2026-11-18

- **Fire when the buff is down**: automatic re-fire as soon as the Attack-Up
  buff expires. The buff state is read from the Palico's condition manager
  (`isActiveAttackUp`), the same object the Otomo Tools counter uses.
- **Global cooldown** (default 480 s / 8 min) gating automatic fires, with a
  countdown in the panel. Manual fires are not gated by it; a 10 s anti-spam
  gap applies even at 0.
- Live `buff: UP / down / unknown` in the panel.
- Hotkey resolution now tries the enum name, the `ImGuiKey_` prefix and a raw
  number, and dumps the build's `imgui.ImGuiKey` names to
  `otomo_horn_trace.json` on load so a non-firing hotkey can be diagnosed
  instead of guessed at.
- Hotkey is also polled in `on_frame` in case the draw callback is not running.


## Sibling mod: Otomo Horn 0.1.0 — 2026-11-18

New file, `reframework/otomo_horn.lua`, packaged separately
(`OtomoHorn-0.1.0.zip`, `otomo-horn-0.1.0.zip`).

It fires the Attack-Up horn on command (hotkey, default F6, plus a panel
button). It does not touch the tool system at all: the hook on
`app.OtomoCharacter:setActionRequest` is read-only and only captures the
Palico's action object, then the mod calls the same method with action id
**0x85** (`cUseHorn`) from `on_frame`. This is the mechanism used by Nexus mod
627 (PalicoMod.dll), reproduced from Lua without modifying hook arguments.

Verified in game: the horn plays and the buff applies, including after the buff
has expired - so the ~4 min tool refractory does not apply to this path.

Splitting the mods is deliberate: Otomo Tools stays data-only and hook-free;
Otomo Horn performs an action.


## 1.0.3 — 2026-11-18

- The live buff state now sits at the top of the panel (`buff now: UP / down`,
  with the use count) instead of below the 14-row tool list, where it was easy
  to miss.

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
