# Changelog

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
