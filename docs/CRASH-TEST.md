# Crash test — driving the Palico's tool action

## Why this exists

Otomo Tools ships with **zero hooks** and never drives the Palico's actions.
That decision rests on a claim everyone repeats — "calling `useOtomoTool`
directly crashes the game" — which, on this build, has never actually been
tested. This document is the record of testing it.

The speedrunning question that prompted it: *can the horn be moved to an
optimal moment (monster paralyzed or trapped) instead of a random one?*
Answering that honestly requires knowing whether the action can be driven at
all, because gating availability is only half the problem.

## What is called

```
app.mcOtomoToolManager:getOtomoToolManagedClass(HORN_ATKUP)   -- 2
  -> cOtomoToolManagedBase instance for the Attack-Up horn
     -> useOtomoTool()                                        -- 0 params
```

Read first, no side effects:

- every method on the tool's type → `otomo_trigger_methods.json`
- `canUseOtomoTool()` → recorded in the breadcrumb as `can_use`

Then, once:

- `useOtomoTool()` with `pcall`

## Safeguards in the script

| Guard | Why |
|---|---|
| Separate autorun file (`tools/otomo_trigger.lua`) | the shipped mod is untouched; if the game dies, the cause is unambiguous |
| Fires at most **once per script load** | no runaway loop into a crash |
| Checkbox acknowledgement before the button appears | no accidental firing |
| Call executed from `on_frame`, not the draw callback | game thread, and the same pattern the mod's writes use |
| Breadcrumb written **before** the call | a hard crash cannot lose it — the file still says `calling` |
| Survival notes at +1 / +60 / +300 frames | distinguishes "crashed in the call", "crashed during the animation", "fine" |
| The tool object is resolved **outside** the risky call | calling game methods from inside a hook is the known crash surface |

## Procedure

1. Enter a quest with the Palico present, a few seconds in (so the manager
   exists and the tool object is resolvable).
2. **Scripts → Otomo Trigger** → *Dump methods (safe)*. This writes the method
   list and touches nothing else.
3. Tick *I accept that this may crash the game*.
4. Press **FIRE useOtomoTool once**.
5. Watch. If the game survives, keep playing for a few seconds and confirm the
   horn animation/effect actually happened (or did not).
6. If it crashes: relaunch, read
   `reframework/data/otomo_trigger_state.json`.
7. **Delete `reframework/autorun/otomo_trigger.lua` when done.** It hooks
   `mcOtomoToolManager:updateMain` for the session.

## Reading the result

| `stage` in the state file | Meaning |
|---|---|
| `calling` | the game died in or immediately after `useOtomoTool()` → the crash claim is true |
| `returned` | the call came back cleanly; the crash, if any, came later |
| `survived` 1 / 60 / 300 frames | it ran; the claim is false for this build |
| `lua error` | `pcall` caught a Lua-level error (not a native crash) — still informative |
| `no useOtomoTool(0 params)` | the method has a different signature; see the methods dump |

The methods dump is the other half of the result: it settles the exact
signature and shows what else the object exposes (`setUseOtomoTool`,
`resetCoolTimeSingle`, requirement checks).

## Results

| Date | Build | Outcome | Notes |
|---|---|---|---|
| 2026-11-18 | Otomo Tools v1.0.1, trigger 0.1.0 | **no crash** — `returned`, then `survived` 1 / 60 / 300 frames | `useOtomoTool()` returned `Void` and the game ran on. **The buff never applied**: the counter read 0 uses / 0 uptime for the quest. Safe, but inert. |

### What the call actually did

```
calling   canUseOtomoTool=n/a tool=userdata: 0000000D80C257B0
returned  sol.api::sdk::ValueType: ...          <- System.Void
survived  1 frames / 60 frames / 300 frames
```

No crash, and no effect. `useOtomoTool()` is the tail of a sequence, not the
trigger: the tool's own `update()` drives it, and the game only enters that
state after its predicates agree. Calling it directly is a no-op.

(`canUseOtomoTool=n/a` because that method lives on the base class;
`app.cOtomoToolManaged_Horn_AtkUp` does not override it. That is also why the
v0.6.0 override matched 16 times and changed nothing — it was overriding a
method this path does not consult.)

### The method surface (the useful part)

`app.cOtomoToolManaged_Horn_AtkUp`, 10 methods:

| Method | Returns | Read as |
|---|---|---|
| `checkEnable()` | Boolean | is the tool allowed at all |
| `isDesireActivate()` | Boolean | **does the AI want it right now** — the gate |
| `useOtomoToolRequirement()` | Boolean | conditions met (cooldown, range, busy) |
| `useOtomoTool()` | Void | performs the use |
| `useOtomoToolEnd()` | Void | tears it down |
| `update()` | Void | the per-frame driver |
| `setupParam()` | Void | applies the catalog values |
| `get_ToolType()` | enum | which tool this object is |
| `onCreate(int,int,int)` | Void | constructor |
| `.ctor()` | Void | constructor |

So the "desire gate" that was dismissed as *not exposed* **is** exposed as
`isDesireActivate()`. The question is now measurable: is it ever true, and what
does it need? That is what `tools/otomo_watch.lua` reads.

### Gate breakdown (watcher, 190 s in a quest, ~18 Hz)

| Predicate | True | Share |
|---|---|---|
| `checkEnable()` | 3460 / 3460 | **100.0 %** |
| `useOtomoToolRequirement()` | 3460 / 3460 | **100.0 %** |
| `isDesireActivate()` | 76 / 3460 | **2.2 %** |
| all three | 76 / 3460 | 2.2 % |

One desire window, 7 seconds long, and the horn fired inside it (counter: 1
use). So on this build, in a normal hunt, **the only gate that ever closes is
desire**. Cooldown, range and state checks were satisfied for the whole fight —
which also explains why lowering `_CoolTime` to 90 s bought so little: the
cooldown was almost never what stopped the Palico.

Consequence: the lever is not the data, it is `isDesireActivate()`. Forcing that
one Boolean to true is the whole problem — and unlike `useOtomoTool()`, it does
not perform anything, so the game's own `update()` still drives the animation
and the effect through its normal path.

`tools/otomo_desire.lua` tests exactly that.

### On-demand test (12 pulses, one hunt, 317 s)

`isDesireActivate()` forced true for 6 s on each button press, with the counter
read before and 5 s after to attribute the outcome:

| Press | Since last use | Followed by a use |
|---|---|---|
| 22:21:57 | — (no active buff) | **yes** |
| 22:22:33 | +31 s | no |
| 22:22:49 | +47 s | no |
| 22:23:37 | +95 s | no |
| 22:24:07 | +125 s | no |
| 22:24:20 | +138 s | no |
| 22:24:58 | +176 s | no |
| 22:25:03 | +181 s | no (check slot overwritten) |
| 22:25:30 | +208 s | no |
| **22:25:48** | **+226 s** | **yes** |

Two presses, two uses - and they are exactly the two presses made while the
horn was available. Every blocked press falls inside a ~210-226 s refractory
period after the previous use, which is far longer than the 30 s `_CoolTime`
configured for that run (consistent with a ~3 min buff plus the cooldown).

**Conclusion: the horn can be fired on demand, but only once per ~3.5-4
minutes.** For the speedrun case that is enough: a 5-minute hunt has one usable
window, and the problem is stopping the AI from spending it early.


## If it survives

Surviving does **not** make action-driving a good design for this mod:

- a call that works once from the panel is not proof it is safe from a per-frame
  loop or from a hook, where the timing and thread differ;
- the animation runs from game state the AI normally sets up; forcing it can
  leave the state machine inconsistent in ways that surface later (stuck tool,
  no effect, broken follow-up behaviour);
- the honest use is still **gating availability**, not driving the action.

If it crashes, the claim is confirmed on this build and the design decision
stands with evidence behind it instead of folklore.
