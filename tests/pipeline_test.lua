--
-- pipeline_test.lua — apply_tuning against a fake REFramework world
--
-- logic_test.lua covers the pure functions. This runs the real code path:
-- resolve OtomoManager -> Catalog -> GlobalParam -> OtomoToolParam, read the
-- live _CoolTime values, plan, write, read back, and restore.
--
-- The fakes implement just enough of REFramework's shapes:
--   RETypeDefinition: get_full_name, get_fields, get_methods, get_method,
--                     get_parent_type
--   REField:          get_name, get_type, is_static, get_data, set_data
--
--   lua5.1 tests/pipeline_test.lua
--

_G.OTOMO_TOOLS_TEST = true

-- ---------------------------------------------------------------------------
-- fake data objects (a table of numeric fields, plus child objects)
-- ---------------------------------------------------------------------------

local function make_object(typeName, entries)
    local obj = {}
    local ft = { name = typeName, fields = {} }

    for fname, e in pairs(entries) do
        -- Lua 5.1 reuses the loop variable, so closures must capture locals
        -- or every field ends up reading the last entry.
        local key, ent = fname, e
        local desc = {
            get_name = function() return key end,
            get_type = function() return { get_name = function() return ent.type or "Int32" end } end,
            is_static = function() return false end,
        }
        if ent.object ~= nil then
            desc.get_data = function() return ent.object end
            obj[key] = ent.object
        else
            desc.get_data = function() return ent.value end
            desc.set_data = function(_, _, v) ent.value = v end
            obj[key] = ent
        end
        ft.fields[#ft.fields + 1] = desc
    end

    ft.get_full_name = function() return typeName end
    ft.get_parent_type = function() return nil end
    ft.get_fields = function() return ft.fields end
    ft.get_methods = function() return {} end
    ft.get_method = function() return nil end

    obj.get_type_definition = function() return ft end
    return obj
end

local function entry(value, t)
    return { value = value, type = t or "Int32" }
end

-- ---------------------------------------------------------------------------
-- the fake game
-- ---------------------------------------------------------------------------

local world = {
    loading = false,
    result = false,
    ending = false,
    writing = true,      -- global switch to simulate "value not readable"
}

local horn = make_object("app.user_data.OtomoToolParam_Horn_AtkUp", {
    _CoolTime = entry(600),
    _CoolTime_PowerUp = entry(480),
})

local slinger = make_object("app.user_data.OtomoToolParam_Slinger", {
    _CoolTime = entry(360),
    _CoolTime_PowerUp = entry(360),
})

local root = make_object("app.user_data.OtomoToolParam", {
    _GlobalCoolTime = entry(90),
    _CheckEnemyAreaMoveTime = entry(10.0, "Single"),
    _Horn_AtkUp = { object = horn, type = "app.user_data.OtomoToolParam_Horn_AtkUp" },
    _Slinger = { object = slinger, type = "app.user_data.OtomoToolParam_Slinger" },
})

local globalParam = make_object("app.cOtomoGlobalParam", {
    _OtomoToolParam = { object = root, type = "app.user_data.OtomoToolParam" },
})

local catalog = make_object("app.cOtomoCatalogHolder", {
    _GlobalParam = { object = globalParam, type = "app.cOtomoGlobalParam" },
})

local otomoManager = make_object("app.OtomoManager", {
    _Catalog = { object = catalog, type = "app.cOtomoCatalogHolder" },
})

local mission = make_object("app.MissionManager", {
    _playing = entry(1),
})
local flow = make_object("app.GameFlowManager", {})

local function noop() end
re = { on_frame = noop, on_draw_ui = noop }
sdk = {
    find_type_definition = function() return nil end,
    get_managed_singleton = function(name)
        if name == "app.OtomoManager" then return otomoManager end
        if name == "app.MissionManager" then return mission end
        if name == "app.GameFlowManager" then return flow end
        return nil
    end,
}
json = { dump_file = function() return true end, load_file = function() return nil end }
log = { info = noop, warn = noop, debug = noop }
imgui = {}

local here = arg and arg[0] or "tests/pipeline_test.lua"
local dir = string.match(here, "^(.*)[/\\]") or "."
local OT = dofile(dir .. "/../reframework/otomo_tools.lua")
local T = OT._test
local rt = T._rt
assert(rt and rt.apply_tuning, "mod did not export its runtime hooks")

-- MissionManager/GameFlowManager getters are resolved through get_method,
-- so give those two types the shape the mod asks for.
local function add_getter(obj, methodName, fn)
    local ft = obj.get_type_definition()
    local old = ft.get_methods
    ft.get_methods = function() return old() end
    local m = {
        get_name = function() return methodName end,
        get_num_params = function() return 0 end,
        get_param_types = function() return {} end,
        get_return_type = function() return { get_name = function() return "Boolean" end } end,
        call = function() return fn() end,
    }
    local base = ft.get_method
    ft.get_method = function(self, name)
        local want = name:gsub("%(%)$", "")
        if want == methodName then return m end
        return base(self, name)
    end
end

add_getter(mission, "get_IsPlayingQuest", function() return true end)
add_getter(mission, "get_IsQuestResult", function() return world.result end)
add_getter(mission, "get_IsQuestEndShowing", function() return world.ending end)
add_getter(flow, "get_Loading", function() return world.loading end)

-- ---------------------------------------------------------------------------
-- harness
-- ---------------------------------------------------------------------------

local passed, failed = 0, 0
local current = "?"
local function group(n) current = n end
local function check(cond, what)
    if cond then passed = passed + 1
    else
        failed = failed + 1
        io.write(string.format("FAIL [%s] %s\n", current, tostring(what)))
    end
end
local function eq(a, b, what)
    check(a == b, string.format("%s (got %s, want %s)", tostring(what), tostring(a), tostring(b)))
end

local function reset_world()
    world.loading = false
    world.result = false
    world.ending = false
    horn._CoolTime.value = 600
    horn._CoolTime_PowerUp.value = 480
    slinger._CoolTime.value = 360
    root._GlobalCoolTime.value = 90
end

local function arm(extra)
    local st = rt.state
    st.cfg = T.normalize_config(extra or {
        enabled = true,
        preset = "horn_attack",
        apply_interval_frames = 1,
        tools = { HORN_ATKUP = { mode = "tune", cooltime_sec = 90 } },
    }, { "HORN_ATKUP", "SLINGER" })
    st.param_root = nil
    st.param_fields = {}
    st.params = {}
    st.original = {}
    st.original_global = nil
    st.param_root = nil
    st.frame = 0
    st.last_writes = ""
end

local function run() rt.apply_tuning() end

-- ---------------------------------------------------------------------------
group("the horn's 600 s cooldown is written down to the configured value")
-- ---------------------------------------------------------------------------

reset_world(); arm(); run()
eq(horn._CoolTime.value, 90, "_CoolTime written")
eq(horn._CoolTime_PowerUp.value, 90, "_CoolTime_PowerUp kept in step")
eq(root._GlobalCoolTime.value, 90, "global cooltime untouched by default")
eq(slinger._CoolTime.value, 360, "unconfigured tool untouched")
eq(rt.state.original.HORN_ATKUP, 600, "original remembered for restore")

-- ---------------------------------------------------------------------------
group("already correct means no write")
-- ---------------------------------------------------------------------------

reset_world(); arm(); run()
local before = horn._CoolTime.value
run()
eq(horn._CoolTime.value, before, "second run changes nothing")
eq(rt.state.last_writes, "", "no write reported on the second run")

-- ---------------------------------------------------------------------------
group("write gate")
-- ---------------------------------------------------------------------------

reset_world(); arm(); world.loading = true; run()
eq(horn._CoolTime.value, 600, "loading blocks the write")

reset_world(); arm(); world.result = true; run()
eq(horn._CoolTime.value, 600, "results block the write")

reset_world(); arm(); world.ending = true; run()
eq(horn._CoolTime.value, 600, "end screen blocks the write")

-- ---------------------------------------------------------------------------
group("disabled / off tool")
-- ---------------------------------------------------------------------------

reset_world(); arm({ enabled = false, tools = { HORN_ATKUP = { mode = "tune", cooltime_sec = 90 } } })
run()
eq(horn._CoolTime.value, 600, "disabled mod writes nothing")

reset_world(); arm({ enabled = true, tools = { HORN_ATKUP = { mode = "off", cooltime_sec = 90 } } })
run()
eq(horn._CoolTime.value, 600, "off tool is not written")

-- ---------------------------------------------------------------------------
group("global cooldown is opt-in")
-- ---------------------------------------------------------------------------

reset_world(); arm({
    enabled = true,
    global_cooltime_sec = 30,
    tools = { HORN_ATKUP = { mode = "tune", cooltime_sec = 90 } },
})
run()
eq(root._GlobalCoolTime.value, 30, "global cooltime written when configured")
eq(rt.state.original_global, 90, "original global remembered")

-- ---------------------------------------------------------------------------
group("write strategies (set_field first, then set_data)")
-- ---------------------------------------------------------------------------

local probe_obj = make_object("app.user_data.Probe", { _CoolTime = entry(600) })
probe_obj.set_field = function(self, name, value)
    local e = rawget(self, name)
    if e ~= nil and type(e) == "table" then e.value = value end
end
local rec = rt.write_number(probe_obj, "_CoolTime", 45)
eq(rec.strategy, "set_field", "set_field is preferred when available")
eq(probe_obj._CoolTime.value, 45, "value written through set_field")

-- An object with no working setter must report failure, not pretend.
local dead = make_object("app.user_data.Dead", { _CoolTime = entry(600) })
dead.get_type_definition = function()
    local ft = { fields = {} }
    ft.get_full_name = function() return "app.user_data.Dead" end
    ft.get_parent_type = function() return nil end
    ft.get_methods = function() return {} end
    ft.get_method = function() return nil end
    ft.get_fields = function()
        return { {
            get_name = function() return "_CoolTime" end,
            get_type = function() return { get_name = function() return "Int32" end } end,
            is_static = function() return false end,
            get_data = function() return 600 end,
            set_data = function() end,      -- silently does nothing
        } }
    end
    return ft
end
rec = rt.write_number(dead, "_CoolTime", 30)
eq(rec.strategy, "failed", "a refusing field is reported as failed")
eq(rec.after, 600, "the read-back shows the truth")

-- ---------------------------------------------------------------------------
group("restore puts the shipping values back")
-- ---------------------------------------------------------------------------

reset_world()
arm({ enabled = true, global_cooltime_sec = 30,
      tools = { HORN_ATKUP = { mode = "tune", cooltime_sec = 90 } } })
run()
rt.restore_originals()
eq(horn._CoolTime.value, 600, "horn restored")
eq(horn._CoolTime_PowerUp.value, 600, "power-up variant restored")
eq(root._GlobalCoolTime.value, 90, "global restored")

-- ---------------------------------------------------------------------------
group("tick schedule")
-- ---------------------------------------------------------------------------

reset_world()
arm({ enabled = true, apply_interval_frames = 30,
      tools = { HORN_ATKUP = { mode = "tune", cooltime_sec = 90 } } })
for _ = 1, 29 do rt.tick() end
eq(horn._CoolTime.value, 600, "nothing before the interval")
rt.tick()
eq(horn._CoolTime.value, 90, "written on the interval frame")

-- ---------------------------------------------------------------------------
-- summary
-- ---------------------------------------------------------------------------

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
