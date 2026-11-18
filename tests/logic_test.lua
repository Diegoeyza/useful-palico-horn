--
-- logic_test.lua — offline tests for the pure parts of Otomo Tools
--
-- Runs under a plain Lua 5.1 interpreter (the game's LuaJIT is 5.1), with the
-- REFramework globals stubbed out. Nothing here touches the game.
--
--   LUA=/tmp/opencode/lua51 ./tests/run.sh
--
-- The mod exports its pure functions on M._test when OTOMO_TOOLS_TEST is set,
-- so the same code that ships is what gets tested.
--

_G.OTOMO_TOOLS_TEST = true

local function noop() end
re = { on_frame = noop, on_draw_ui = noop }
sdk = { find_type_definition = function() return nil end }
json = { dump_file = function() return true end, load_file = function() return nil end }
log = { info = noop, warn = noop, debug = noop }
imgui = {}

local here = arg and arg[0] or "tests/logic_test.lua"
local dir = string.match(here, "^(.*)[/\\]") or "."
local mod_path = dir .. "/../reframework/otomo_tools.lua"

local OT = dofile(mod_path)
assert(type(OT) == "table" and OT._test, "mod did not export its test hooks")
local T = OT._test

-- ---------------------------------------------------------------------------
-- harness
-- ---------------------------------------------------------------------------

local passed, failed = 0, 0
local current = "?"

local function group(name) current = name end

local function check(cond, what)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        io.write(string.format("FAIL [%s] %s\n", current, tostring(what)))
    end
end

local function eq(a, b, what)
    check(a == b, string.format("%s (got %s, want %s)", tostring(what),
        tostring(a), tostring(b)))
end

-- The enum names are what the live build gave the probe. Keep them a fixture so
-- a rename shows up as a failed test rather than a silently empty table.
local NAMES = {
    "Horn", "Horn_AtkUp", "Horn_DefUp", "Bomb", "SetBomb",
    "SetParalyzeTrap", "SetFlashTrap", "Slinger", "ShieldProvoke",
    "StealBoomerang", "InsectHeal_Delivery", "InsectHeal_Revive",
    "HealBugWarmSet", "BadConditionsHeal_Delivery",
}

-- ---------------------------------------------------------------------------
group("normalize: defaults")
-- ---------------------------------------------------------------------------

local cfg = T.normalize_config(nil, NAMES)
eq(cfg.enabled, true, "enabled default")
eq(cfg.preset, "horn_attack", "preset default")
eq(cfg.tick_interval_frames, 30, "tick default")
eq(cfg.reset_global_cooldown, true, "gcd default")
eq(cfg.debug, false, "debug default")
eq(cfg.tools.Horn_AtkUp and cfg.tools.Horn_AtkUp.mode, "cooldown", "preset applied to horn atk")
eq(cfg.tools.Horn_DefUp and cfg.tools.Horn_DefUp.mode, "off", "preset turns horn def off")

-- ---------------------------------------------------------------------------
group("normalize: hostile input")
-- ---------------------------------------------------------------------------

cfg = T.normalize_config({
    enabled = false,
    tick_interval_frames = 100000,
    tools = { Nope = { mode = "cooldown" } },
}, NAMES)
eq(cfg.enabled, false, "enabled false survives")
eq(cfg.tick_interval_frames, 600, "interval clamped high")
eq(cfg.tools.Nope, nil, "unknown tool dropped")
check(cfg.tools.Horn_AtkUp ~= nil, "empty result falls back to preset")

cfg = T.normalize_config({ tick_interval_frames = -5 }, NAMES)
eq(cfg.tick_interval_frames, 1, "interval clamped low")

cfg = T.normalize_config({
    tools = { Horn_AtkUp = { mode = "banana" } },
}, NAMES)
eq(cfg.tools.Horn_AtkUp.mode, "off", "unknown mode -> off")

cfg = T.normalize_config({
    tools = { Horn_AtkUp = "cooldown" },
}, NAMES)
eq(cfg.tools.Horn_AtkUp and cfg.tools.Horn_AtkUp.mode, "cooldown",
    "non-table entry replaced by the preset")

-- ---------------------------------------------------------------------------
group("normalize: no live names yet")
-- ---------------------------------------------------------------------------

-- At load the enum can be missing (menu before a quest). An existing config
-- must survive that round trip, not be wiped.
cfg = T.normalize_config({
    tools = { SomeToolFromAPreviousPatch = { mode = "cooldown" } },
}, {})
eq(cfg.tools.SomeToolFromAPreviousPatch
    and cfg.tools.SomeToolFromAPreviousPatch.mode, "cooldown",
    "config kept when the enum is not loaded")

-- ---------------------------------------------------------------------------
group("presets")
-- ---------------------------------------------------------------------------

local c2 = { preset = "horn_both", tools = {} }
T.apply_preset(c2, NAMES)
eq(c2.tools.Horn_AtkUp.mode, "cooldown", "horn_both atk")
eq(c2.tools.Horn_DefUp.mode, "cooldown", "horn_both def")
eq(c2.tools.Bomb, nil, "horn_both leaves bomb alone")

c2 = { preset = "healing", tools = {} }
T.apply_preset(c2, NAMES)
eq(c2.tools.InsectHeal_Delivery.mode, "cooldown", "healing matches InsectHeal")
eq(c2.tools.BadConditionsHeal_Delivery.mode, "cooldown", "healing matches BadCondition")
eq(c2.tools.Horn_AtkUp, nil, "healing leaves the horn alone")

c2 = { preset = "nonsense", tools = {} }
T.apply_preset(c2, NAMES)
eq(next(c2.tools), nil, "unknown preset applies nothing")

-- ---------------------------------------------------------------------------
group("schedule")
-- ---------------------------------------------------------------------------

check(T.should_tick(30, 30), "frame 30 ticks at 30")
check(not T.should_tick(29, 30), "frame 29 does not")
check(T.should_tick(7, 0), "interval 0 is coerced to 1")
check(T.should_tick(30, nil), "nil interval uses the default 30")
check(not T.should_tick(7, nil), "nil interval still gates on the default")

-- ---------------------------------------------------------------------------
group("quest gate")
-- ---------------------------------------------------------------------------

check(T.quest_gate_ok({ playing = true }), "playing alone is enough")
check(not T.quest_gate_ok({ playing = false }), "not playing blocks")
check(not T.quest_gate_ok({ playing = true, result = true }), "results block")
check(not T.quest_gate_ok({ playing = true, ending = true }), "end screen blocks")
check(not T.quest_gate_ok({ playing = true, loading = true }), "loading blocks")
check(not T.quest_gate_ok(nil), "nil flow blocks")

-- ---------------------------------------------------------------------------
group("plan: only what the game says is on cooldown")
-- ---------------------------------------------------------------------------

local pc = { enabled = true, tools = {
    Horn_AtkUp = { mode = "cooldown" },
    Horn_DefUp = { mode = "off" },
    Bomb = { mode = "cooldown" },
} }

local plan = T.plan_resets(pc, {
    Horn_AtkUp = { ok = false },
    Bomb = { ok = true },
})
eq(#plan, 1, "one tool planned")
eq(plan[1], "Horn_AtkUp", "the on-cooldown tool")

-- The important safety property: no live state, no write.
plan = T.plan_resets(pc, {})
eq(#plan, 0, "unknown state is never reset blind")

plan = T.plan_resets(pc, {
    Horn_AtkUp = { ok = false, using = true },
})
eq(#plan, 0, "never reset the tool that is being used")

plan = T.plan_resets({ enabled = false, tools = pc.tools },
    { Horn_AtkUp = { ok = false } })
eq(#plan, 0, "disabled mod plans nothing")

plan = T.plan_resets(pc, {
    Horn_DefUp = { ok = false },
    Bomb = { ok = false },
    Horn_AtkUp = { ok = false },
})
eq(#plan, 2, "off tools are skipped even when on cooldown")
eq(plan[1], "Bomb", "plan is sorted (Bomb)")
eq(plan[2], "Horn_AtkUp", "plan is sorted (Horn_AtkUp)")

-- ---------------------------------------------------------------------------
group("active names (the only tools allowed near a native call)")
-- ---------------------------------------------------------------------------

local an = T.active_names(pc)
check(an.Horn_AtkUp, "active includes a cooldown tool")
check(an.Bomb, "active includes the second cooldown tool")
check(not an.Horn_DefUp, "off tools are never active")
eq(next(T.active_names(nil)), nil, "nil config has no active tools")

-- ---------------------------------------------------------------------------
group("config round trip")
-- ---------------------------------------------------------------------------

-- Whatever the UI writes must survive save -> load -> normalize unchanged.
local saved = T.normalize_config({
    enabled = true,
    preset = "custom",
    tick_interval_frames = 15,
    tools = {
        Horn_AtkUp = { mode = "cooldown" },
        Bomb = { mode = "cooldown" },
        Slinger = { mode = "off" },
    },
}, NAMES)
local again = T.normalize_config(saved, NAMES)
eq(again.tick_interval_frames, 15, "interval survives")
eq(again.tools.Horn_AtkUp.mode, "cooldown", "mode survives")
eq(again.tools.Bomb.mode, "cooldown", "second tool survives")
eq(again.tools.Slinger.mode, "off", "off entry survives")

-- ---------------------------------------------------------------------------
-- summary
-- ---------------------------------------------------------------------------

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
