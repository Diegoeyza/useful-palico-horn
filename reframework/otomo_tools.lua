--
-- otomo_tools.lua v0.2.0 — make the Palico use a chosen support move more often
--
-- How it works (data tuning, no action calls):
--   The Palico tools are plain data: app.user_data.OtomoToolParam_Horn_AtkUp
--   carries _CoolTime (600 s in the shipping build), _CoolTime_PowerUp, etc.
--   This mod writes those numbers for the tools you pick, so the game's own AI
--   can use them far more often. Nothing is triggered, animated or hooked.
--
-- Why data and not the tool manager:
--   The live per-tool object (app.cOtomoToolManagedBase) does have
--   resetCoolTimeSingle(), but it is only reachable through the otomo's mini
--   component holder, which the probe could not resolve. The param objects the
--   game copies those values from are reachable in one hop from
--   OtomoManager.Catalog.GlobalParam.OtomoToolParam, so that is the lever.
--
-- Verified on this build (otomo_probe_instance.json, 2026-11-18):
--   _OtomoToolParam._GlobalCoolTime = 90
--   _Horn_AtkUp._CoolTime = 600   _CoolTime_PowerUp = 480
--   _Horn_DefUp._CoolTime = 10
--   _Slinger._CoolTime = 360      _SetFlashTrap = 360
--   _StealBoomerang._CoolTime = 210
--
-- Load: reframework\autorun\  (Script Generated UI -> "Otomo Tools v…")
-- Config: reframework\data\otomo_tools.json
-- Trace:  reframework\data\otomo_tools_trace.json  (ring buffer, crash-survivable)
--
-- Every SDK call is pcall-guarded, and every write is read back before it is
-- reported: set_field/set_data lie (MODDING-NOTES 4.3).
--

local re = re
local sdk = sdk
local json = json
local log = log
local imgui = imgui

local VERSION = "0.2.1"
local TAG = "[OtomoTools]"

local ALREADY_LOADED = _G.OTOMO_TOOLS_LOADED == true
_G.OTOMO_TOOLS_LOADED = true

local CONFIG_FILE = "otomo_tools.json"
local TRACE_FILE = "otomo_tools_trace.json"

local MAX_STR = 160

local M = { version = VERSION, _test = nil }

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

local function safe(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end

local function safe_str(v)
    if v == nil then return nil end
    local t = type(v)
    if t == "string" then
        if #v > MAX_STR then return v:sub(1, MAX_STR) .. "..." end
        return v
    end
    if t == "number" or t == "boolean" then return v end
    return tostring(v)
end

-- Word wrap without imgui.text_wrapped: that binding does not exist on this
-- REFramework build (dinput8.dll registers `text` and `text_colored` only).
local function wrap_text(text, width)
    local out = {}
    text = tostring(text or "")
    width = math.max(1, tonumber(width) or 76)
    local line = ""
    for word in text:gmatch("%S+") do
        if #line == 0 then
            line = word
        elseif #line + 1 + #word <= width then
            line = line .. " " .. word
        else
            out[#out + 1] = line
            line = word
        end
        while #line > width do
            out[#out + 1] = line:sub(1, width)
            line = line:sub(width + 1)
        end
    end
    if #line > 0 then out[#out + 1] = line end
    if #out == 0 then out[1] = "" end
    return out
end

local function text_wrapped(text, width)
    if type(imgui.text_wrapped) == "function" then
        return safe(function() imgui.text_wrapped(text) end)
    end
    for _, line in ipairs(wrap_text(text, width)) do
        imgui.text(line)
    end
end

local function getter(obj, name)
    if obj == nil then return nil end
    local td = safe(function() return obj:get_type_definition() end)
    local depth = 0
    while td and depth < 8 do
        local m = safe(function() return td:get_method(name .. "()") end)
        if m then return safe(function() return m:call(obj) end) end
        td = safe(function() return td:get_parent_type() end)
        depth = depth + 1
    end
    return nil
end

-- Field by name, walking base classes (inherited fields are common here).
local function field_descriptor(obj, name)
    if obj == nil then return nil end
    local td = safe(function() return obj:get_type_definition() end)
    local depth = 0
    while td and depth < 8 do
        for _, f in ipairs(safe(function() return td:get_fields() end) or {}) do
            if safe(function() return f:get_name() end) == name then return f end
        end
        td = safe(function() return td:get_parent_type() end)
        depth = depth + 1
    end
    return nil
end

local function field_value(obj, name)
    local f = field_descriptor(obj, name)
    if not f then return nil end
    if safe(function() return f:is_static() end) then return nil end
    return safe(function() return f:get_data(obj) end)
end

local function field_names(obj)
    local out = {}
    if obj == nil then return out end
    local td = safe(function() return obj:get_type_definition() end)
    local depth = 0
    while td and depth < 8 do
        for _, f in ipairs(safe(function() return td:get_fields() end) or {}) do
            local n = safe(function() return f:get_name() end)
            if n then out[#out + 1] = n end
        end
        td = safe(function() return td:get_parent_type() end)
        depth = depth + 1
    end
    return out
end

-- ---------------------------------------------------------------------------
-- bounded object walk (used to find the runtime tool manager)
-- ---------------------------------------------------------------------------

local function is_obj(v)
    if v == nil or type(v) ~= "userdata" then return false end
    if type(sdk.is_managed_object) == "function" then
        local ok = safe(sdk.is_managed_object, v)
        if ok ~= nil then return ok == true end
    end
    return true
end

local function list_length(obj)
    local n = safe(function() return obj:get_Count() end)
    if type(n) == "number" then return math.floor(n) end
    n = safe(function() return obj:get_Size() end)
    if type(n) == "number" then return math.floor(n) end
    return nil
end

local function children_of(obj)
    local kids = {}
    local n = list_length(obj)
    if n then
        for i = 0, math.min(n - 1, 32) do
            local v = safe(function() return obj[i] end)
            if v ~= nil then kids[#kids + 1] = { key = "[" .. i .. "]", value = v } end
        end
        return kids
    end
    local td = safe(function() return obj:get_type_definition() end)
    local depth = 0
    while td and depth < 5 do
        for _, f in ipairs(safe(function() return td:get_fields() end) or {}) do
            if not safe(function() return f:is_static() end) then
                local name = safe(function() return f:get_name() end)
                if name then
                    local v = safe(function() return f:get_data(obj) end)
                    if v ~= nil then kids[#kids + 1] = { key = name, value = v } end
                end
            end
        end
        td = safe(function() return td:get_parent_type() end)
        depth = depth + 1
    end
    return kids
end

-- Collect every reachable object whose type name contains `pattern`.
local function walk_find(root, pattern, maxDepth, maxNodes)
    local out = {}
    if root == nil then return out end
    local queue = { [1] = { obj = root, path = "root", depth = 0 } }
    local seen = { [root] = true }
    local nodes, head, tail = 0, 1, 1
    maxDepth = maxDepth or 4
    maxNodes = maxNodes or 400
    while head <= tail and nodes < maxNodes do
        local item = queue[head]
        queue[head] = nil
        head = head + 1
        nodes = nodes + 1
        local td = safe(function() return item.obj:get_type_definition() end)
        local tn = td and safe(function() return td:get_full_name() end) or nil
        if tn and tn:lower():find(pattern:lower(), 1, true) then
            out[#out + 1] = { path = item.path, type = tn, obj = item.obj }
        end
        if item.depth < maxDepth then
            for _, k in ipairs(children_of(item.obj)) do
                local v = k.value
                if is_obj(v) and not seen[v] then
                    seen[v] = true
                    tail = tail + 1
                    queue[tail] = { obj = v, path = item.path .. "." .. k.key, depth = item.depth + 1 }
                end
            end
        end
    end
    return out
end

-- Enum member name -> numeric value for a type, or nil.
local function enum_values(typeName)
    local td = safe(sdk.find_type_definition, typeName)
    if not td then return nil end
    local out, any = {}, false
    for _, f in ipairs(safe(function() return td:get_fields() end) or {}) do
        if safe(function() return f:is_static() end) then
            local n = safe(function() return f:get_name() end)
            local v = safe(function() return f:get_data(nil) end)
            if n and type(v) == "number" then
                out[n] = v
                any = true
            end
        end
    end
    if not any then return nil end
    return out
end

local function resolve_enum_type(shortName)
    for _, c in ipairs({ "app.OtomoDef." .. shortName, "app." .. shortName, shortName }) do
        if safe(sdk.find_type_definition, c) then return c end
    end
    return nil
end

-- Enum sentinels are not real tools. Writing a param for one would be a
-- pointless write at best and a wrong one at worst.
local function is_sentinel_name(name)
    local n = tostring(name):lower()
    return n:find("none", 1, true) ~= nil
        or n:find("invalid", 1, true) ~= nil
        or n:find("dummy", 1, true) ~= nil
        or n:find("max", 1, true) ~= nil
end

-- ---------------------------------------------------------------------------
-- pure logic (tested offline)
-- ---------------------------------------------------------------------------

local function norm(s)
    return (tostring(s):gsub("[^%w]", ""):upper())
end

-- Enum member -> field on OtomoToolParam. The explicit table is the verified
-- mapping from the probe; the normalized fallback keeps the obvious ones
-- working if a patch renames a member.
local PARAM_FIELD = {
    INSECT_HEAL_DELIVERY = "_InsectDelivery",
    SHIELD_PROVOKE = "_ShieldProvoke",
    HORN_ATKUP = "_Horn_AtkUp",
    HORN_DEFUP = "_Horn_DefUp",
    SLINGER = "_Slinger",
    TRAP_PARALYZE = "_SetParalyzeTrap",
    DRAG_AIR_SHIP = "_DragAirShip",
    INSECT_HEAL_REVIVE = "_InsectRevive",
    TRAP_FLASH = "_SetFlashTrap",
    SET_INSECT_HEAL = "_HealBugWarmSet",
    STEAL_BOOMERANG = "_StealBoomerang",
    BAD_CONDITIONS_HEAL_DELIVERY = "_BadConditionsHealDelivery",
    SET_BOMB = "_SetBomb",
    MULTI_HIT_BOOMERANG = "_Bomb",
}

-- Resolve a tool to one of the fields that actually exist on the param object.
-- Returns nil rather than guessing: a wrong field write is worse than no write.
local function param_field_for(toolName, available)
    local explicit = PARAM_FIELD[toolName]
    if explicit then
        for _, f in ipairs(available or {}) do
            if f == explicit then return f end
        end
    end
    local want = norm(toolName)
    for _, f in ipairs(available or {}) do
        if norm(f) == want then return f end
    end
    return nil
end

local MODES = { off = true, tune = true }

-- Presets are patterns over live enum member names (case-insensitive: the
-- build uses HORN_ATKUP, not Horn_AtkUp).
local PRESETS = {
    horn_attack = {
        { pattern = "^HORN_ATK", cooltime_sec = 90 },
    },
    horn_both = {
        { pattern = "^HORN_ATK", cooltime_sec = 90 },
        { pattern = "^HORN_DEF", cooltime_sec = 90 },
    },
    healing = {
        { pattern = "HEAL", cooltime_sec = 60 },
    },
}

local DEFAULT_CONFIG = {
    version = 2,
    enabled = true,
    preset = "horn_attack",
    apply_interval_frames = 300,     -- how often to re-check/write (~5 s at 60 fps)
    global_cooltime_sec = 0,         -- 0 = leave _GlobalCoolTime alone
    debug = false,
    tools = {},                      -- [enum member] = { mode = "tune"|"off", cooltime_sec = n }
}

local function copy_shallow(t)
    local out = {}
    for k, v in pairs(t or {}) do out[k] = v end
    return out
end

-- Write the preset into cfg.tools, only for names that exist live.
local function apply_preset(cfg, live_names)
    local preset = PRESETS[cfg.preset or ""] or {}
    for _, name in ipairs(live_names or {}) do
        local uname = tostring(name):upper()
        for _, rule in ipairs(preset) do
            if uname:find(rule.pattern) then
                local entry = cfg.tools[name] or {}
                entry.mode = "tune"
                entry.cooltime_sec = rule.cooltime_sec
                cfg.tools[name] = entry
            end
        end
    end
    return cfg
end

local function clamp_sec(v, default)
    if type(v) ~= "number" then return default end
    local n = math.floor(v + 0.5)
    if n < 0 then n = 0 end
    if n > 3600 then n = 3600 end
    return n
end

-- Drop unknown tools, unknown modes, out-of-range numbers.
local function normalize_config(raw, live_names)
    local cfg = copy_shallow(DEFAULT_CONFIG)
    cfg.tools = {}
    raw = type(raw) == "table" and raw or {}

    if raw.enabled ~= nil then cfg.enabled = raw.enabled == true end
    if type(raw.preset) == "string" then cfg.preset = raw.preset end
    if type(raw.apply_interval_frames) == "number" then
        local n = math.floor(raw.apply_interval_frames)
        if n < 1 then n = 1 elseif n > 3600 then n = 3600 end
        cfg.apply_interval_frames = n
    end
    cfg.global_cooltime_sec = clamp_sec(raw.global_cooltime_sec, 0)
    if raw.debug ~= nil then cfg.debug = raw.debug == true end

    local known = {}
    for _, n in ipairs(live_names or {}) do known[n] = true end

    if type(raw.tools) == "table" then
        for name, entry in pairs(raw.tools) do
            if type(name) == "string" and (not next(known) or known[name])
                and type(entry) == "table" then
                local mode = entry.mode
                -- v1 configs said "cooldown"; the lever is the same idea.
                if mode == "cooldown" then mode = "tune" end
                if type(mode) ~= "string" or not MODES[mode] then mode = "off" end
                local sec = entry.cooltime_sec
                if type(sec) ~= "number" and type(entry.cooldown_sec) == "number" then
                    sec = entry.cooldown_sec
                end
                cfg.tools[name] = {
                    mode = mode,
                    cooltime_sec = sec ~= nil and clamp_sec(sec, nil) or nil,
                }
            end
        end
    end

    if not next(cfg.tools) then apply_preset(cfg, live_names) end
    return cfg
end

local function should_tick(frame, interval)
    interval = tonumber(interval) or 300
    if interval < 1 then interval = 1 end
    return frame % interval == 0
end

-- Writing config data is safe outside a quest (in fact it is *better* there:
-- the game copies these values when the otomo is set up), but never while the
-- client is tearing a quest down (MODDING-NOTES 6).
local function write_gate_ok(flow)
    if type(flow) ~= "table" then return false end
    if flow.loading or flow.result or flow.ending then return false end
    return true
end

-- Which tools need a write. `current` holds the value read from the live param
-- object; a missing entry means "could not read it", which is not a reason to
-- write (the same rule as v0.1's tri-state).
local function plan_tuning(cfg, current)
    local out = {}
    if not cfg or cfg.enabled ~= true then return out end
    for name, entry in pairs(cfg.tools or {}) do
        if entry.mode == "tune" and type(entry.cooltime_sec) == "number" then
            local cur = (current or {})[name]
            if type(cur) == "number" and cur ~= entry.cooltime_sec then
                out[#out + 1] = { name = name, target = entry.cooltime_sec, current = cur }
            end
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

M._test = {
    normalize_config = normalize_config,
    apply_preset = apply_preset,
    should_tick = should_tick,
    write_gate_ok = write_gate_ok,
    plan_tuning = plan_tuning,
    param_field_for = param_field_for,
    wrap_text = wrap_text,
    presets = PRESETS,
    modes = MODES,
    param_field = PARAM_FIELD,
    _rt = nil,
}

-- ---------------------------------------------------------------------------
-- trace ring (survives a crash; the game log does not)
-- ---------------------------------------------------------------------------

local trace_ring = {}

local function trace(text)
    trace_ring[#trace_ring + 1] = os.date("%H:%M:%S ") .. tostring(text)
    while #trace_ring > 200 do table.remove(trace_ring, 1) end
    safe(function()
        json.dump_file(TRACE_FILE, { lines = trace_ring })
    end)
end

-- ---------------------------------------------------------------------------
-- runtime
-- ---------------------------------------------------------------------------

local state = {
    cfg = nil,
    live_names = {},
    tool_values = nil,
    enum_type = nil,
    param_root = nil,
    param_fields = {},
    params = {},          -- enum member -> live param object
    managed = {},         -- enum member -> runtime cOtomoToolManagedBase
    tool_manager = nil,
    tool_manager_path = nil,
    original = {},        -- enum member -> _CoolTime at first sight
    original_global = nil,
    diag_done = false,
    misses = 0,
    frame = 0,
    last_status = "(idle)",
    last_writes = "",
}

local function note(text)
    state.last_status = tostring(text)
    if state.cfg and state.cfg.debug then log.info(TAG .. " " .. state.last_status) end
end

local function load_tool_enum()
    for _, short in ipairs({
        "USE_OTOMO_TOOL_TYPE", "USE_OTOMO_TOOL_TYPE_Fixed",
        "OTOMO_TOOL_TYPE", "OTOMO_TOOL_TYPE_Fixed",
    }) do
        local resolved = resolve_enum_type(short)
        if resolved then
            local values = enum_values(resolved)
            if values then
                local names = {}
                for name, value in pairs(values) do
                    if type(value) == "number" and value >= 0 and value < 128
                        and not is_sentinel_name(name) then
                        names[#names + 1] = { name = name, value = value }
                    end
                end
                if #names > 0 then
                    table.sort(names, function(a, b) return a.value < b.value end)
                    state.enum_type = resolved
                    state.tool_values = names
                    state.live_names = {}
                    for _, t in ipairs(names) do state.live_names[#state.live_names + 1] = t.name end
                    return true
                end
            end
        end
    end
    return false
end

local function load_config()
    local raw = safe(function() return json.load_file(CONFIG_FILE) end)
    state.cfg = normalize_config(raw, state.live_names)
    note("config loaded (preset=" .. tostring(state.cfg.preset) .. ")")
end

local function save_config()
    if not state.cfg then return end
    safe(function() json.dump_file(CONFIG_FILE, state.cfg) end)
end

-- OtomoManager._Catalog._GlobalParam._OtomoToolParam
local function resolve_param_root()
    local om = safe(sdk.get_managed_singleton, "app.OtomoManager")
    if not om then return nil end
    local catalog = getter(om, "get_Catalog") or field_value(om, "_Catalog")
    if catalog == nil then return nil end
    local gp = getter(catalog, "get_GlobalParam") or field_value(catalog, "_GlobalParam")
    if gp == nil then return nil end
    local root = getter(gp, "get_OtomoToolParam") or field_value(gp, "_OtomoToolParam")
    return root
end

-- Write a numeric field and report what actually happened. Two strategies,
-- because set_data silently does nothing on some via.user_data fields
-- (MODDING-NOTES 4.3 — the API lies; the read-back is the truth).
local function write_number(obj, name, value)
    local f = field_descriptor(obj, name)
    if not f then return nil end
    if safe(function() return f:is_static() end) then return nil end
    local before = safe(function() return f:get_data(obj) end)
    if type(before) ~= "number" then return nil end

    local tname = safe(function() return f:get_type():get_name() end) or ""
    local is_float = tname:lower():find("single") ~= nil or tname:lower():find("float") ~= nil
    local target = is_float and (value + 0.0) or math.floor(value)

    local rec = {
        field = name, type = tname, before = before, target = target,
        size = safe(function() return f:get_size() end),
        value_type = safe(function() return f:get_type():is_value_type() end),
    }

    -- 1. Object-level setter (RSZ aware; this is the one that works on
    --    via.user_data in other mods on this install).
    safe(function() obj:set_field(name, target) end)
    local a1 = safe(function() return f:get_data(obj) end)
    if a1 == target then
        rec.strategy, rec.after = "set_field", a1
        return rec
    end
    rec.after_set_field = a1

    -- 2. Field descriptor setter.
    safe(function() f:set_data(obj, target) end)
    local a2 = safe(function() return f:get_data(obj) end)
    if a2 == target then
        rec.strategy, rec.after = "set_data", a2
        return rec
    end
    rec.after_set_data = a2

    rec.strategy, rec.after = "failed", a2
    return rec
end

-- The master otomo's character (path proven by the probe).
local function master_character()
    local om = safe(sdk.get_managed_singleton, "app.OtomoManager")
    if not om then return nil end
    local ctl = getter(om, "getMasterOtomoManagedControl")
    if ctl == nil then return nil end
    local info = field_value(ctl, "_OtomoManagedInfo")
        or getter(ctl, "get_OtomoManagedInfo")
    local char = info and field_value(info, "<Character>k__BackingField")
    if char ~= nil then return char end
    local hits = walk_find(ctl, "OtomoCharacter", 2, 120)
    return hits[1] and hits[1].obj or nil
end

-- The runtime tool manager (mcOtomoToolManager). The probe could not reach it
-- from the character's _Components (a COMPONENT_HOLDER), so try the mini
-- component updater containers, which do expose their contents.
local function find_tool_manager()
    if state.tool_manager ~= nil then return state.tool_manager end
    local char = master_character()
    if char == nil then return nil end
    local roots = {}
    for _, fname in ipairs({
        "_MiniCompUpdater_LateUpdate", "_MiniCompUpdater_AfterMotion",
        "_MiniCompUpdater_AfterAction", "_MiniCompUpdater_LateUpdateEnd",
        "_MiniCompUpdator_BeforeAction", "_Components",
    }) do
        local v = field_value(char, fname)
        if v ~= nil then roots[#roots + 1] = { name = fname, obj = v } end
    end
    for _, r in ipairs(roots) do
        local hits = walk_find(r.obj, "otomoToolManager", 3, 300)
        for _, h in ipairs(hits) do
            if h.type:find("mcOtomoToolManager") then
                state.tool_manager = h.obj
                state.tool_manager_path = r.name .. " -> " .. h.path
                trace("tool manager found via " .. state.tool_manager_path)
                return h.obj
            end
        end
    end
    return nil
end

-- 1-arg enum call on the live manager, arity-checked.
local function call_enum_method(obj, methodName, value)
    if obj == nil then return nil end
    local td = safe(function() return obj:get_type_definition() end)
    if not td then return nil end
    for _, m in ipairs(safe(function() return td:get_methods() end) or {}) do
        local n = safe(function() return m:get_name() end)
        local np = safe(function() return m:get_num_params() end)
        if n == methodName and np == 1 then
            return safe(function() return m:call(obj, value) end)
        end
    end
    return nil
end

-- The runtime per-tool object that actually counts the cooldown.
local function managed_tool_for(name)
    if state.managed[name] ~= nil then return state.managed[name] end
    local mgr = find_tool_manager()
    if mgr == nil then return nil end
    local value = nil
    for _, t in ipairs(state.tool_values or {}) do
        if t.name == name then value = t.value break end
    end
    if value == nil then return nil end
    local obj = call_enum_method(mgr, "getOtomoToolManagedClass", value)
    if obj ~= nil then state.managed[name] = obj end
    return obj
end

-- Set the live cooldown on the runtime object (setCoolTime(1) -> Void).
local function set_managed_cooltime(obj, seconds)
    if obj == nil then return false end
    local td = safe(function() return obj:get_type_definition() end)
    if not td then return false end
    for _, m in ipairs(safe(function() return td:get_methods() end) or {}) do
        if safe(function() return m:get_name() end) == "setCoolTime"
            and safe(function() return m:get_num_params() end) == 1 then
            local before = field_value(obj, "_CoolTime")
            safe(function() return m:call(obj, seconds) end)
            local after = field_value(obj, "_CoolTime")
            return before, after
        end
    end
    return false
end

local function params_object_for(name)
    local obj = state.params[name]
    if obj ~= nil then return obj end
    local fname = param_field_for(name, state.param_fields)
    if not fname then return nil end
    obj = field_value(state.param_root, fname)
    if obj ~= nil then state.params[name] = obj end
    return obj
end

local function quest_flow()
    local mm = safe(sdk.get_managed_singleton, "app.MissionManager")
    local gf = safe(sdk.get_managed_singleton, "app.GameFlowManager")
    return {
        playing = mm and getter(mm, "get_IsPlayingQuest") == true or false,
        result = mm and getter(mm, "get_IsQuestResult") == true or false,
        ending = mm and getter(mm, "get_IsQuestEndShowing") == true or false,
        loading = gf and getter(gf, "get_Loading") == true or false,
    }
end

-- One-shot diagnostic: what the field is, why the write failed, and whether the
-- runtime tool manager is reachable at all. Written once per session.
local function dump_diagnostic(toolName, paramObj, rec, managedBefore, managedAfter)
    local diag = {
        version = VERSION,
        tool = toolName,
        param_type = paramObj and safe(function()
            return paramObj:get_type_definition():get_full_name()
        end) or nil,
        field = rec and rec.field,
        field_type = rec and rec.type,
        field_size = rec and rec.size,
        value_type = rec and rec.value_type,
        before = rec and rec.before,
        target = rec and rec.target,
        after_set_field = rec and rec.after_set_field,
        after_set_data = rec and rec.after_set_data,
        strategy = rec and rec.strategy,
        managed_found = state.managed[toolName] ~= nil,
        managed_before = managedBefore,
        managed_after = managedAfter,
        tool_manager_path = state.tool_manager_path,
        param_fields = state.param_fields,
        tool_param_fields = field_names(paramObj),
    }
    safe(function() json.dump_file("otomo_write_test.json", diag) end)
    trace("diagnostic -> otomo_write_test.json")
end

local function apply_tuning()
    local cfg = state.cfg
    if not cfg or not cfg.enabled then return end
    if not write_gate_ok(quest_flow()) then return end

    local root = state.param_root
    if root == nil then
        root = resolve_param_root()
        if root ~= nil then
            state.param_root = root
            state.param_fields = field_names(root)
            state.params = {}
            trace("param root resolved (" .. tostring(#state.param_fields) .. " fields)")
        end
    end
    if root == nil then
        state.misses = state.misses + 1
        note("tool params not reachable yet")
        return
    end
    state.misses = 0

    -- Global cooldown (90 s in the shipping build).
    if cfg.global_cooltime_sec and cfg.global_cooltime_sec > 0 then
        local cur = field_value(root, "_GlobalCoolTime")
        if type(cur) == "number" then
            if state.original_global == nil then state.original_global = cur end
            if cur ~= cfg.global_cooltime_sec then
                local rec = write_number(root, "_GlobalCoolTime", cfg.global_cooltime_sec)
                trace(string.format("global cooltime %s -> %s (%s)",
                    tostring(rec and rec.before), tostring(rec and rec.after),
                    tostring(rec and rec.strategy)))
            end
        end
    end

    -- Per tool: read first, then plan. A tool we cannot read is not written.
    local current, objects = {}, {}
    for name, entry in pairs(cfg.tools) do
        if entry.mode == "tune" and type(entry.cooltime_sec) == "number" then
            local obj = params_object_for(name)
            if obj ~= nil then
                objects[name] = obj
                local v = field_value(obj, "_CoolTime")
                if type(v) == "number" then
                    current[name] = v
                    if state.original[name] == nil then state.original[name] = v end
                end
            end
        end
    end

    local writes = {}
    for _, item in ipairs(plan_tuning(cfg, current)) do
        local obj = objects[item.name]
        if obj ~= nil then
            local rec = write_number(obj, "_CoolTime", item.target)
            local strategy = rec and rec.strategy or "nil"
            -- keep the powered-up variant in step, otherwise the first
            -- level-up would restore the old number
            if field_value(obj, "_CoolTime_PowerUp") ~= nil then
                write_number(obj, "_CoolTime_PowerUp", item.target)
            end

            if rec and rec.after == item.target then
                writes[#writes + 1] = string.format("%s %s->%s", item.name,
                    tostring(rec.before), tostring(rec.after))
                trace(string.format("%s _CoolTime %s -> %s via %s", item.name,
                    tostring(rec.before), tostring(rec.after), strategy))
            else
                -- The catalog copy refused the write. Try the runtime object
                -- that actually counts the cooldown.
                local managed = managed_tool_for(item.name)
                local before, after = set_managed_cooltime(managed, item.target)
                if before ~= nil and after ~= nil then
                    writes[#writes + 1] = string.format("%s live %s->%s", item.name,
                        tostring(before), tostring(after))
                    trace(string.format("%s managed setCoolTime %s -> %s", item.name,
                        tostring(before), tostring(after)))
                else
                    trace(string.format("%s _CoolTime refused (%s), no runtime object",
                        item.name, strategy))
                end
                if not state.diag_done then
                    state.diag_done = true
                    dump_diagnostic(item.name, obj, rec, before, after)
                end
            end
        end
    end
    state.last_writes = table.concat(writes, ", ")
end

local function tick()
    state.frame = state.frame + 1
    if not state.cfg then return end
    if not should_tick(state.frame, state.cfg.apply_interval_frames) then return end
    local ok, err = pcall(apply_tuning)
    if not ok then
        note("apply error: " .. tostring(err))
        log.info(TAG .. " " .. state.last_status)
    end
end

-- Restore the values seen before the mod touched anything.
local function restore_originals()
    if state.param_root == nil then return end
    for name, obj in pairs(state.params) do
        local orig = state.original[name]
        if type(orig) == "number" then
            write_number(obj, "_CoolTime", orig)
            write_number(obj, "_CoolTime_PowerUp", orig)
        end
    end
    if type(state.original_global) == "number" then
        write_number(state.param_root, "_GlobalCoolTime", state.original_global)
    end
    state.params = {}
    trace("restored original cooltimes")
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------

local ui = { frame = -999, flow = nil }

local function ui_reads()
    if state.frame - ui.frame >= 30 then
        ui.frame = state.frame
        ui.flow = quest_flow()
    end
    return ui
end

local function bump(config, name, delta)
    local entry = config.tools[name]
    if not entry then
        entry = { mode = "tune", cooltime_sec = 90 }
        config.tools[name] = entry
    end
    local cur = entry.cooltime_sec or 90
    entry.cooltime_sec = clamp_sec(cur + delta, 90)
    config.preset = "custom"
end

local function draw_body()
    if not state.cfg then
        imgui.text("config not loaded")
        return
    end

    local changed
    changed, state.cfg.enabled = imgui.checkbox("Enabled", state.cfg.enabled)
    if changed then save_config() end

    imgui.text("Preset: " .. tostring(state.cfg.preset))
    for _, pname in ipairs({ "horn_attack", "horn_both", "healing" }) do
        if imgui.button(pname) then
            state.cfg.preset = pname
            for _, n in ipairs(state.live_names) do
                state.cfg.tools[n] = { mode = "off" }
            end
            apply_preset(state.cfg, state.live_names)
            save_config()
            trace("preset -> " .. pname)
        end
        imgui.same_line()
    end
    imgui.new_line()

    imgui.separator()
    if state.param_root == nil then
        imgui.text("tool params: not resolved yet (hub or quest)")
        if imgui.button("Resolve now") then
            state.param_root = nil
            apply_tuning()
        end
    else
        imgui.text("tool params: resolved")
        local g = field_value(state.param_root, "_GlobalCoolTime")
        imgui.text("global cooldown: " .. tostring(g) .. " s"
            .. (state.original_global and (" (was " .. tostring(state.original_global) .. ")") or ""))
    end

    imgui.separator()
    for _, t in ipairs(state.tool_values or {}) do
        local entry = state.cfg.tools[t.name] or { mode = "off" }
        local obj = state.params[t.name]
        local cur = obj and field_value(obj, "_CoolTime") or nil
        imgui.text(string.format("%-26s %-5s now=%s want=%s",
            t.name, entry.mode, tostring(cur), tostring(entry.cooltime_sec)))
        imgui.same_line()
        if imgui.button("-30##" .. t.name) then bump(state.cfg, t.name, -30) save_config() end
        imgui.same_line()
        if imgui.button("+30##" .. t.name) then bump(state.cfg, t.name, 30) save_config() end
        imgui.same_line()
        if imgui.button((entry.mode == "tune" and "off" or "tune") .. "##" .. t.name) then
            local e = state.cfg.tools[t.name] or { cooltime_sec = 90 }
            e.mode = (e.mode == "tune") and "off" or "tune"
            e.cooltime_sec = e.cooltime_sec or 90
            state.cfg.tools[t.name] = e
            state.cfg.preset = "custom"
            save_config()
        end
    end

    imgui.separator()
    if imgui.button("Restore original cooltimes") then
        restore_originals()
    end
    imgui.text("last writes: " .. (state.last_writes ~= "" and state.last_writes or "(none)"))
    text_wrapped("status: " .. state.last_status)
    imgui.text("config: " .. CONFIG_FILE .. "   trace: " .. TRACE_FILE)
end

-- ImGui requires TreePop for every TreePush; an exception in the body is how
-- you get "Missing TreePop()". The pop lives outside the pcall.
local function draw_ui()
    if not imgui.tree_node("Otomo Tools v" .. VERSION) then return end
    local ok, err = pcall(draw_body)
    safe(function() imgui.tree_pop() end)
    if not ok then
        state.last_status = "draw error: " .. tostring(err)
        log.info(TAG .. " " .. state.last_status)
    end
end

-- ---------------------------------------------------------------------------
-- registration
-- ---------------------------------------------------------------------------

M._test._rt = {
    state = state,
    tick = tick,
    apply_tuning = apply_tuning,
    resolve_param_root = resolve_param_root,
    write_number = write_number,
    field_value = field_value,
    restore_originals = restore_originals,
    quest_flow = quest_flow,
}

if _G.OTOMO_TOOLS_TEST then
    return M
end

if not ALREADY_LOADED then
    load_tool_enum()
    load_config()

    re.on_draw_ui(function()
        local ok, err = pcall(draw_ui)
        if not ok then log.info(TAG .. " draw error: " .. tostring(err)) end
    end)

    re.on_frame(function()
        local ok, err = pcall(tick)
        if not ok then log.info(TAG .. " tick error: " .. tostring(err)) end
    end)

    trace("loaded v" .. VERSION .. " enum=" .. tostring(state.enum_type)
        .. " tools=" .. tostring(#state.live_names))
    log.info(TAG .. " loaded v" .. VERSION .. " (" .. tostring(state.enum_type) .. ")")
end

return M
