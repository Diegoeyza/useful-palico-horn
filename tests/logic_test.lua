--
-- logic_test.lua — offline tests for the pure parts of Otomo Tools
--
-- Runs under a plain Lua 5.1 interpreter (the game's LuaJIT is 5.1), with the
-- REFramework globals stubbed out. Nothing here touches the game.
--
--   LUA=/tmp/opencode/lua51/lua ./tests/run.sh
--
-- The enum names, field names and cool times are the real ones from
-- otomo_probe_types.json / otomo_probe_instance.json (2026-11-18).
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
    check(a == b, string.format("%s (got %s, want %s)", tostring(what), tostring(a),
        tostring(b)))
end

-- The live enum, exactly as the probe dumped it (sentinels included: the
-- loader filters those, this list is what reaches the config).
local NAMES = {
    "INSECT_HEAL_DELIVERY", "SHIELD_PROVOKE", "HORN_ATKUP", "HORN_DEFUP",
    "SLINGER", "TRAP_PARALYZE", "DRAG_AIR_SHIP", "INSECT_HEAL_REVIVE",
    "TRAP_FLASH", "SET_INSECT_HEAL", "STEAL_BOOMERANG",
    "BAD_CONDITIONS_HEAL_DELIVERY", "SET_BOMB", "MULTI_HIT_BOOMERANG",
}

-- The live field names on app.user_data.OtomoToolParam.
local FIELDS = {
    "_GlobalCoolTime", "_CheckEnemyAreaMoveTime",
    "_InsectDelivery", "_BadConditionsHealDelivery", "_HealBugWarmSet",
    "_InsectRevive", "_ShieldProvoke", "_Slinger", "_Bomb", "_SetBomb",
    "_SetParalyzeTrap", "_SetFlashTrap", "_Horn_AtkUp", "_Horn_DefUp",
    "_StealBoomerang", "_DragAirShip",
}

-- ---------------------------------------------------------------------------
group("normalize: defaults")
-- ---------------------------------------------------------------------------

local cfg = T.normalize_config(nil, NAMES)
eq(cfg.enabled, true, "enabled default")
eq(cfg.preset, "horn_attack", "preset default")
eq(cfg.apply_interval_frames, 300, "interval default")
eq(cfg.global_cooltime_sec, 0, "global cooltime left alone by default")
eq(cfg.tools.HORN_ATKUP and cfg.tools.HORN_ATKUP.mode, "tune", "horn preset is tune")
eq(cfg.tools.HORN_ATKUP and cfg.tools.HORN_ATKUP.cooltime_sec, 90, "horn preset target")
eq(cfg.tools.HORN_DEFUP, nil, "horn_attack leaves the defence horn alone")

-- ---------------------------------------------------------------------------
group("presets match the live UPPERCASE enum members")
-- ---------------------------------------------------------------------------

local c2 = { preset = "horn_both", tools = {} }
T.apply_preset(c2, NAMES)
eq(c2.tools.HORN_ATKUP.mode, "tune", "atk horn matched")
eq(c2.tools.HORN_ATKUP.cooltime_sec, 90, "atk horn target")
eq(c2.tools.HORN_DEFUP.mode, "tune", "def horn matched")
eq(c2.tools.SLINGER, nil, "slinger untouched")

c2 = { preset = "healing", tools = {} }
T.apply_preset(c2, NAMES)
eq(c2.tools.INSECT_HEAL_DELIVERY.mode, "tune", "insect delivery matched")
eq(c2.tools.INSECT_HEAL_REVIVE.mode, "tune", "insect revive matched")
eq(c2.tools.BAD_CONDITIONS_HEAL_DELIVERY.mode, "tune", "bad-conditions heal matched")
eq(c2.tools.SET_INSECT_HEAL.mode, "tune", "insect heal set matched")
eq(c2.tools.HORN_ATKUP, nil, "healing leaves the horn alone")

c2 = { preset = "nonsense", tools = {} }
T.apply_preset(c2, NAMES)
eq(next(c2.tools), nil, "unknown preset applies nothing")

-- ---------------------------------------------------------------------------
group("normalize: hostile and legacy input")
-- ---------------------------------------------------------------------------

cfg = T.normalize_config({
    enabled = false,
    apply_interval_frames = 100000,
    tools = { Nope = { mode = "tune", cooltime_sec = 30 } },
}, NAMES)
eq(cfg.enabled, false, "enabled false survives")
eq(cfg.apply_interval_frames, 3600, "interval clamped high")
eq(cfg.tools.Nope, nil, "unknown tool dropped")
check(cfg.tools.HORN_ATKUP ~= nil, "empty result falls back to preset")

cfg = T.normalize_config({ apply_interval_frames = -5 }, NAMES)
eq(cfg.apply_interval_frames, 1, "interval clamped low")

cfg = T.normalize_config({ tools = { HORN_ATKUP = { mode = "banana" } } }, NAMES)
eq(cfg.tools.HORN_ATKUP.mode, "off", "unknown mode -> off")

-- v1 used mode="cooldown" for the same intent
cfg = T.normalize_config({ tools = { HORN_ATKUP = { mode = "cooldown", cooldown_sec = 120 } } }, NAMES)
eq(cfg.tools.HORN_ATKUP.mode, "tune", "legacy mode migrated")
eq(cfg.tools.HORN_ATKUP.cooltime_sec, 120, "legacy cooldown_sec migrated")

cfg = T.normalize_config({ tools = { HORN_ATKUP = { mode = "tune", cooltime_sec = 99999 } } }, NAMES)
eq(cfg.tools.HORN_ATKUP.cooltime_sec, 3600, "cooltime clamped high")

cfg = T.normalize_config({ global_cooltime_sec = -10 }, NAMES)
eq(cfg.global_cooltime_sec, 0, "global cooltime clamped to 0")

-- ---------------------------------------------------------------------------
group("param field mapping (the riskiest logic)")
-- ---------------------------------------------------------------------------

eq(T.param_field_for("HORN_ATKUP", FIELDS), "_Horn_AtkUp", "explicit horn atk")
eq(T.param_field_for("HORN_DEFUP", FIELDS), "_Horn_DefUp", "explicit horn def")
eq(T.param_field_for("SLINGER", FIELDS), "_Slinger", "normalized fallback (slinger)")
eq(T.param_field_for("SET_BOMB", FIELDS), "_SetBomb", "normalized fallback (set bomb)")
eq(T.param_field_for("TRAP_PARALYZE", FIELDS), "_SetParalyzeTrap", "explicit trap paralyze")
eq(T.param_field_for("TRAP_FLASH", FIELDS), "_SetFlashTrap", "explicit trap flash")
eq(T.param_field_for("MULTI_HIT_BOOMERANG", FIELDS), "_Bomb", "explicit boomerang")
eq(T.param_field_for("BAD_CONDITIONS_HEAL_DELIVERY", FIELDS),
    "_BadConditionsHealDelivery", "long name")
eq(T.param_field_for("SET_INSECT_HEAL", FIELDS), "_HealBugWarmSet", "explicit insect heal set")
eq(T.param_field_for("NOT_A_TOOL", FIELDS), nil, "unknown tool maps to nothing")
eq(T.param_field_for("HORN_ATKUP", { "_SomethingElse" }), nil,
    "an explicit name that does not exist is not guessed")

-- ---------------------------------------------------------------------------
group("schedule")
-- ---------------------------------------------------------------------------

check(T.should_tick(300, 300), "frame 300 ticks at 300")
check(not T.should_tick(299, 300), "frame 299 does not")
check(T.should_tick(7, 0), "interval 0 is coerced to 1")
check(T.should_tick(300, nil), "nil interval uses the default 300")

-- ---------------------------------------------------------------------------
group("write gate")
-- ---------------------------------------------------------------------------

check(T.write_gate_ok({}), "quiet state is writable")
check(T.write_gate_ok({ playing = true }), "mid-quest is writable (data only)")
check(not T.write_gate_ok({ loading = true }), "loading blocks")
check(not T.write_gate_ok({ result = true }), "results block")
check(not T.write_gate_ok({ ending = true }), "end screen blocks")
check(not T.write_gate_ok(nil), "nil flow blocks")

-- ---------------------------------------------------------------------------
group("plan: only what is readable and different")
-- ---------------------------------------------------------------------------

local pc = { enabled = true, tools = {
    HORN_ATKUP = { mode = "tune", cooltime_sec = 90 },
    HORN_DEFUP = { mode = "off", cooltime_sec = 90 },
    SLINGER = { mode = "tune", cooltime_sec = 120 },
} }

local plan = T.plan_tuning(pc, { HORN_ATKUP = 600, SLINGER = 120 })
eq(#plan, 1, "one write planned")
eq(plan[1].name, "HORN_ATKUP", "the differing tool")
eq(plan[1].target, 90, "target seconds")
eq(plan[1].current, 600, "current seconds")

plan = T.plan_tuning(pc, { HORN_ATKUP = 90, SLINGER = 120 })
eq(#plan, 0, "already matching means no write")

-- The safety property: unreadable state is never written.
plan = T.plan_tuning(pc, {})
eq(#plan, 0, "unknown current is never written")

plan = T.plan_tuning({ enabled = false, tools = pc.tools }, { HORN_ATKUP = 600 })
eq(#plan, 0, "disabled plans nothing")

plan = T.plan_tuning(pc, { HORN_DEFUP = 600, SLINGER = 5, HORN_ATKUP = 600 })
eq(#plan, 2, "off tools skipped even when they differ")
eq(plan[1].name, "HORN_ATKUP", "sorted first")
eq(plan[2].name, "SLINGER", "sorted second")

-- ---------------------------------------------------------------------------
group("quiet the other tools (Tier C)")
-- ---------------------------------------------------------------------------

eq(T.normalize_config(nil, NAMES).quiet_others, false, "quieting is off by default")
eq(T.normalize_config(nil, NAMES).quiet_cooltime_sec, 3600, "quiet target default")
eq(T.normalize_config({ quiet_cooltime_sec = 5 }, NAMES).quiet_cooltime_sec, 60,
    "quiet target clamped low")
eq(T.normalize_config({ quiet_cooltime_sec = 99999 }, NAMES).quiet_cooltime_sec, 3600,
    "quiet target clamped high")

local qc = { quiet_others = true, tools = {
    HORN_ATKUP = { mode = "tune", cooltime_sec = 90 },
    SLINGER = { mode = "off" },
} }
local qlist = T.quiet_targets(qc, { "HORN_ATKUP", "SLINGER", "TRAP_FLASH" })
local function has(list, name)
    for _, v in ipairs(list) do if v == name then return true end end
    return false
end
check(has(qlist, "SLINGER"), "an off tool is quieted")
check(has(qlist, "TRAP_FLASH"), "an unlisted live tool is quieted")
check(not has(qlist, "HORN_ATKUP"), "the tuned tool is never quieted")
eq(#T.quiet_targets({ quiet_others = false, tools = qc.tools }, { "SLINGER" }), 0,
    "nothing is quieted when the toggle is off")

-- ---------------------------------------------------------------------------
group("force use predicate")
-- ---------------------------------------------------------------------------

local fc = { force_use = true, force_interval_frames = 1200 }
check(T.force_due(fc, 5000, nil, true, false), "due when ready, buff down, never forced")
check(not T.force_due(fc, 5000, nil, false, false), "not due while the game says no")
check(not T.force_due(fc, 5000, nil, true, true), "not due while the buff is up")
check(not T.force_due(fc, 1000, 500, true, false), "not due inside the interval")
check(T.force_due(fc, 1700, 500, true, false), "due once the interval passed")
check(not T.force_due({ force_use = false }, 5000, nil, true, false), "off by default")
check(not T.force_due(fc, 5000, nil, nil, false), "unknown can-use is not a yes")

-- ---------------------------------------------------------------------------
group("horn counter (read-only, pure transitions)")
-- ---------------------------------------------------------------------------

local c = { uses = 0, uptime = 0, observed = 0, last_state = false }

check(T.step_counter(c, false, 100, "t0") == nil, "off -> off is not an event")
eq(c.uses, 0, "no use yet")

local ev = T.step_counter(c, true, 101, "t1")
eq(ev and ev.kind, "start", "off -> on is a start event")
eq(c.uses, 1, "use counted")
eq(c.active_since, 101, "start time kept")

check(T.step_counter(c, true, 105, "t5") == nil, "on -> on is not an event")
eq(c.uses, 1, "still one use")

ev = T.step_counter(c, false, 110, "t10")
eq(ev and ev.kind, "end", "on -> off is an end event")
eq(c.uptime, 9, "duration accumulated")
eq(c.uses, 1, "ending does not add a use")

-- Unknown signal must not fabricate transitions.
local c2 = { uses = 0, uptime = 0, observed = 0, last_state = true, active_since = 200 }
check(T.step_counter(c2, nil, 210, "tx") == nil, "nil signal is not an event")
eq(c2.uses, 0, "nil signal does not count")
eq(c2.last_state, true, "nil signal leaves the state alone")

-- A second use, with no clock available: still counted, no crash.
local c3 = { uses = 0, uptime = 0, observed = 0, last_state = false }
T.step_counter(c3, true, nil, "t1")
T.step_counter(c3, false, nil, "t2")
eq(c3.uses, 1, "counted without a clock")
eq(c3.uptime, 0, "no duration without a clock")

-- ---------------------------------------------------------------------------
group("word wrap (the text_wrapped binding is missing on this build)")
-- ---------------------------------------------------------------------------

local lines = T.wrap_text("a b c d e f", 5)
eq(#lines, 2, "two wrapped lines")
eq(lines[1], "a b c", "first line")
eq(lines[2], "d e f", "second line")

lines = T.wrap_text("abcdefghij", 4)
eq(#lines, 3, "an overlong token is split")
eq(lines[1], "abcd", "split 1")
eq(lines[3], "ij", "split remainder")

lines = T.wrap_text("", 10)
eq(#lines, 1, "empty text still yields one line")
eq(lines[1], "", "empty line")

-- ---------------------------------------------------------------------------
group("config round trip")
-- ---------------------------------------------------------------------------

local saved = T.normalize_config({
    enabled = true,
    preset = "custom",
    apply_interval_frames = 120,
    global_cooltime_sec = 30,
    tools = {
        HORN_ATKUP = { mode = "tune", cooltime_sec = 60 },
        TRAP_FLASH = { mode = "tune", cooltime_sec = 180 },
        SLINGER = { mode = "off" },
    },
}, NAMES)
local again = T.normalize_config(saved, NAMES)
eq(again.apply_interval_frames, 120, "interval survives")
eq(again.global_cooltime_sec, 30, "global cooltime survives")
eq(again.tools.HORN_ATKUP.cooltime_sec, 60, "mode survives")
eq(again.tools.TRAP_FLASH.cooltime_sec, 180, "second tool survives")
eq(again.tools.SLINGER.mode, "off", "off entry survives")

-- ---------------------------------------------------------------------------
-- summary
-- ---------------------------------------------------------------------------

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
