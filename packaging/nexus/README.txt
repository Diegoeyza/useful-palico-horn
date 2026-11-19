Otomo Tools
===========

Makes your Palico use a chosen support move more often.

The first target is the Attack-Up horn — the trumpet — but the same setting
works for every Palico support move the game exposes (bombs, traps, slinger,
healing bugs, and so on).

How it works
------------
MH Wilds gates each Palico support move on four things: the AI's desire to use
it, a global cooldown, a per-tool cooldown, and stock. This mod clears the
cooldown side for the tools you pick, so the game's own AI can choose them as
often as it wants to.

It never forces an animation or calls the "use tool" action, which is the part
of this kind of mod that tends to crash.

Usage
-----
1. Install REFramework, then copy otomo_tools.lua into
   reframework\autorun\ and reset scripts.
2. Open Insert -> Script Generated UI -> Otomo Tools.
3. Pick a preset (Horn Attack Up by default) or toggle individual tools.
4. Optional: lower the global cooldown (90 s by default) so the other tools
   come off cooldown sooner. The horns ignore it - they use their own cooldown.
5. The panel shows the live buff state (buff now: UP / down) and a horn use
   counter, so you can see it working.

Notes
-----
- Only your own (master) Palico is touched.
- The mod only acts during a quest, never on the results or loading screens.
- If the Palico is far from you it will not use a tool regardless of cooldown;
  the game requires proximity for most support moves.
