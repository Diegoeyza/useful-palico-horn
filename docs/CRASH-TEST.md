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
| — | — | not yet run | |

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
