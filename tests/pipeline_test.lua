--
-- pipeline_test.lua — the tick loop against a fake REFramework world
--
-- logic_test.lua covers the pure functions. This one runs the real tick():
-- quest gating, manager resolution caching, the guarded 1-arg calls, the reset
-- plan and the write. It is the only place the "we never call into a freed
-- object" rule can be checked without the game.
--
-- The fakes implement just enough of REFramework's shapes:
--   RETypeDefinition: get_full_name, get_methods, get_method, get_parent_type,
--                     get_fields
--   REMethodDefinition: get_name, get_num_params, get_param_types,
--                       get_return_type, is_static, call
--
--   lua5.1 tests/pipeline_test.lua
--

_G.OTOMO_TOOLS_TEST = true

-- ---------------------------------------------------------------------------
-- a very small reflection fake
-- ---------------------------------------------------------------------------

local TYPES = {}

local function param(n) return { get_name = function() return n end } end

local function new_type(full_name, method_specs, field_specs, parent)
    local t = {
        full_name = full_name,
        methods = {},
        fields = {},
        parent = parent,
    }

    for _, spec in ipairs(method_specs or {}) do
        local params = spec.params or {}
        t.methods[#t.methods + 1] = {
            get_name = function() return spec.name end,
            get_full_name = function() return full_name .. "." .. spec.name .. "()" end,
            get_num_params = function() return #params end,
            get_param_types = function()
                local arr = {}
                for i, p in ipairs(params) do arr[i] = param(p) end
                return arr
            end,
            get_return_type = function() return { get_name = function() return "Boolean" end } end,
            is_static = function() return spec.static == true end,
            call = function(_, obj, ...) return spec.fn(obj, ...) end,
        }
    end

    for _, spec in ipairs(field_specs or {}) do
        t.fields[#t.fields + 1] = {
            get_name = function() return spec.name end,
            get_type = function() return { get_name = function() return spec.type end } end,
            is_static = function() return spec.static == true end,
            get_data = function(_, obj) return spec.get(obj) end,
        }
    end

    t.get_full_name = function() return full_name end
    t.get_parent_type = function() return parent end
    t.get_size = function() return 8 end
    t.get_fields = function() return t.fields end
    t.get_methods = function() return t.methods end
    t.get_method = function(_, mname)
        local want = mname:gsub("%(%)$", "")
        for _, m in ipairs(t.methods) do
            if m.get_name() == want then return m end
        end
        return nil
    end

    TYPES[full_name] = t
    return t
end

local function instance(ft)
    return { get_type_definition = function() return ft end }
end

-- ---------------------------------------------------------------------------
-- the fake game
-- ---------------------------------------------------------------------------

local world = {
    playing = true,
    result = false,
    ending = false,
    loading = false,
    tool_on_cooldown = true,      -- isCoolTimeOut(false) => clear it
    tool_can = true,
    using = false,
    using_type = 0,
    resets = {},                  -- names of cleared tools
    gcd_resets = 0,
    cool_arg = nil,
}

local manager_type = new_type("app.mcOtomoToolManager", {
    { name = "get_IsUseingTool", fn = function() return world.using end },
    { name = "get_UseOtomoToolType", fn = function() return world.using_type end },
    { name = "get_IsForceUseOtomoTool", fn = function() return false end },
    { name = "canUseOtomoTool", params = { "USE_OTOMO_TOOL_TYPE" },
      fn = function(_, v) return world.tool_can and v == world.cool_arg end },
    { name = "isCoolTimeOut", params = { "USE_OTOMO_TOOL_TYPE" },
      fn = function(_, v)
          if v ~= world.cool_arg then return nil end
          return not world.tool_on_cooldown
      end },
    { name = "resetCoolTimeSingle", params = { "USE_OTOMO_TOOL_TYPE" },
      fn = function(_, v) world.resets[#world.resets + 1] = v end },
    { name = "resetGCDTimer", fn = function() world.gcd_resets = world.gcd_resets + 1 end },
})

local manager = instance(manager_type)

local mission_type = new_type("app.MissionManager", {
    { name = "get_IsPlayingQuest", fn = function() return world.playing end },
    { name = "get_IsQuestResult", fn = function() return world.result end },
    { name = "get_IsQuestEndShowing", fn = function() return world.ending end },
})
local flow_type = new_type("app.GameFlowManager", {
    { name = "get_Loading", fn = function() return world.loading end },
})

local mission = instance(mission_type)
local flow = instance(flow_type)

-- a driver type that owns the manager, so resolve_manager() has a real route
local driver_type = new_type("app.cOtomoManageControl", {
    { name = "get_Dummy", fn = function() return nil end },
}, {
    { name = "_ManageControl", type = "app.mcOtomoToolManager",
      get = function() return manager end },
})

-- the walker needs `type(v) == "userdata"` to recurse and list_length() to
-- decide "is this a list?"; the fakes are tables, so drive the route with a
-- one-element list and a get_Count that returns 1.
local driver = instance(driver_type)
driver.get_Count = function() return 1 end
driver[0] = manager

local otomo_manager = {
    get_type_definition = function()
        return new_type("app.OtomoManager", {
            { name = "getMasterOtomoManagedControl", fn = function() return driver end },
        })
    end,
    call = function(_, name)
        if name == "getMasterOtomoManagedControl" then return driver end
        return nil
    end,
}

-- ---------------------------------------------------------------------------
-- stubs consumed at load time
-- ---------------------------------------------------------------------------

local function noop() end
local is_managed = {}
is_managed[driver] = true
is_managed[manager] = true

re = { on_frame = noop, on_draw_ui = noop }
sdk = {
    find_type_definition = function(name) return TYPES[name] end,
    get_managed_singleton = function(name)
        if name == "app.OtomoManager" then return otomo_manager end
        if name == "app.MissionManager" then return mission end
        if name == "app.GameFlowManager" then return flow end
        return nil
    end,
    is_managed_object = function(v) return is_managed[v] == true or v == driver end,
}
json = { dump_file = function() return true end, load_file = function() return nil end }
log = { info = noop, warn = noop, debug = noop }
imgui = {}

local here = arg and arg[0] or "tests/pipeline_test.lua"
local dir = string.match(here, "^(.*)[/\\]") or "."
local OT = dofile(dir .. "/../reframework/otomo_tools.lua")
local T = OT._test
local rt = T._rt
assert(rt and rt.tick, "mod did not export its runtime hooks")

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
    check(a == b, string.format("%s (got %s, want %s)", tostring(a), tostring(b), what))
end

local function reset_world()
    world.playing = true
    world.result = false
    world.ending = false
    world.loading = false
    world.tool_on_cooldown = true
    world.tool_can = true
    world.using = false
    world.using_type = 0
    world.resets = {}
    world.gcd_resets = 0
    world.cool_arg = 3
end

local function arm()
    -- what the script does at load, but with the fake world's enum
    local st = rt.state
    st.cfg = T.normalize_config({
        enabled = true,
        preset = "horn_attack",
        tick_interval_frames = 1,
        tools = { Horn_AtkUp = { mode = "cooldown" } },
    }, { "Horn_AtkUp" })
    st.tool_values = { { name = "Horn_AtkUp", value = 3 } }
    st.manager = manager
    st.manager_type = "app.mcOtomoToolManager"
    st.frame = 0
    st.last_plan = ""
end

local function frame() rt.tick() end
local function frames(n) for _ = 1, n do rt.tick() end end

-- ---------------------------------------------------------------------------
group("resets when the game says the tool is on cooldown")
-- ---------------------------------------------------------------------------

reset_world(); arm(); frame()
eq(#world.resets, 1, "one reset")
eq(world.resets[1], 3, "the horn's enum value")
eq(world.gcd_resets, 1, "global cooldown reset once")

-- ---------------------------------------------------------------------------
group("does nothing when the tool is already ready")
-- ---------------------------------------------------------------------------

reset_world(); arm()
world.tool_on_cooldown = false
frames(3)
eq(#world.resets, 0, "no reset while ready")
eq(world.gcd_resets, 0, "no gcd reset while ready")

-- ---------------------------------------------------------------------------
group("never touches the tool that is being used")
-- ---------------------------------------------------------------------------

reset_world(); arm()
world.using = true
world.using_type = 3
frames(3)
eq(#world.resets, 0, "no reset during a cast")

-- ---------------------------------------------------------------------------
group("unknown live state means no write")
-- ---------------------------------------------------------------------------

reset_world(); arm()
world.cool_arg = 99          -- isCoolTimeOut returns nil for our tool
frames(3)
eq(#world.resets, 0, "nil state is not treated as 'on cooldown'")

-- ---------------------------------------------------------------------------
group("quest gates")
-- ---------------------------------------------------------------------------

reset_world(); arm()
world.result = true
frame()
eq(#world.resets, 0, "results screen blocks")

reset_world(); arm()
world.ending = true
frame()
eq(#world.resets, 0, "end screen blocks")

reset_world(); arm()
world.loading = true
frame()
eq(#world.resets, 0, "loading blocks")

reset_world(); arm()
world.playing = false
frame()
eq(#world.resets, 0, "hub blocks")
eq(rt.state.manager, nil, "the manager pointer is dropped outside a quest")

-- ---------------------------------------------------------------------------
group("disabled mod")
-- ---------------------------------------------------------------------------

reset_world(); arm()
rt.state.cfg.enabled = false
frames(3)
eq(#world.resets, 0, "disabled means zero writes")

-- ---------------------------------------------------------------------------
group("mode off")
-- ---------------------------------------------------------------------------

reset_world(); arm()
rt.state.cfg.tools.Horn_AtkUp.mode = "off"
frames(3)
eq(#world.resets, 0, "an off tool is never reset")

-- ---------------------------------------------------------------------------
group("global cooldown toggle")
-- ---------------------------------------------------------------------------

reset_world(); arm()
rt.state.cfg.reset_global_cooldown = false
frame()
eq(#world.resets, 1, "tool still reset")
eq(world.gcd_resets, 0, "gcd left alone when the toggle is off")

-- ---------------------------------------------------------------------------
group("tick schedule")
-- ---------------------------------------------------------------------------

reset_world(); arm()
rt.state.cfg.tick_interval_frames = 30
frames(29)
eq(#world.resets, 0, "nothing before the interval")
frame()
eq(#world.resets, 1, "one write on the interval frame")

-- ---------------------------------------------------------------------------
-- summary
-- ---------------------------------------------------------------------------

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
