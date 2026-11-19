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

local VERSION = "0.6.1"
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

local function type_has_method(tn, methodName)
    if not tn then return false end
    local td = safe(sdk.find_type_definition, tn)
    if not td then return false end
    local depth = 0
    while td and depth < 8 do
        if safe(function() return td:get_method(methodName) end) then return true end
        td = safe(function() return td:get_parent_type() end)
        depth = depth + 1
    end
    return false
end

local function walk_find_method(root, methodName, maxDepth, maxNodes)
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
        if tn and type_has_method(tn, methodName) then
            out[#out + 1] = { path = item.path, type = tn, obj = item.obj, method = methodName }
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
    quiet_others = false,            -- push the tools you did NOT pick out of the way
    quiet_cooltime_sec = 3600,       -- how far out (seconds)
    override_can_use = false,        -- experimental: hook canUseOtomoTool for one tool
    override_tool = "HORN_ATKUP",
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
    if raw.quiet_others ~= nil then cfg.quiet_others = raw.quiet_others == true end
    cfg.quiet_cooltime_sec = clamp_sec(raw.quiet_cooltime_sec, 3600)
    if cfg.quiet_cooltime_sec < 60 then cfg.quiet_cooltime_sec = 60 end
    if raw.override_can_use ~= nil then cfg.override_can_use = raw.override_can_use == true end
    if type(raw.override_tool) == "string" then cfg.override_tool = raw.override_tool end
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

-- Tools that are NOT the ones you picked. "Quieting" them raises their
-- cooldown, so the Palico's own choice has fewer alternatives — the picked
-- tool's share rises without touching the AI's desire tables.
local function quiet_targets(cfg, live_names)
    local out = {}
    if not cfg or cfg.quiet_others ~= true then return out end
    for _, name in ipairs(live_names or {}) do
        local entry = (cfg.tools or {})[name]
        if not entry or entry.mode ~= "tune" then
            out[#out + 1] = name
        end
    end
    return out
end

-- Count uses from a boolean signal. Pure: no game calls, so it is testable
-- offline. An unknown signal (nil) never changes the state.
local function step_counter(c, active, now, label)
    if c == nil or active == nil then return nil end
    if type(now) == "number" and type(c.last_now) == "number" then
        local d = now - c.last_now
        if d > 0 then c.observed = (c.observed or 0) + d end
    end
    if type(now) == "number" then c.last_now = now end

    local event = nil
    if active and not c.last_state then
        c.uses = (c.uses or 0) + 1
        c.active_since = now
        c.last_at = label
        event = { kind = "start", uses = c.uses, at = label }
    elseif not active and c.last_state then
        if type(now) == "number" and type(c.active_since) == "number" then
            local d = now - c.active_since
            if d > 0 then c.uptime = (c.uptime or 0) + d end
        end
        c.active_since = nil
        event = { kind = "end", at = label }
    end
    c.last_state = active
    return event
end

M._test = {
    normalize_config = normalize_config,
    apply_preset = apply_preset,
    should_tick = should_tick,
    write_gate_ok = write_gate_ok,
    plan_tuning = plan_tuning,
    quiet_targets = quiet_targets,
    param_field_for = param_field_for,
    step_counter = step_counter,
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
    buff = nil,
    buff_signal = nil,
    buff_type = nil,
    buff_path = nil,
    counter_off = false,
    mgr_raw = nil,
    mgr = nil,
    mgr_type = nil,
    hook_state = nil,
    horn_addr = nil,
    override_state = nil,
    buff_now = nil,
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

-- ---------------------------------------------------------------------------
-- read-only horn counter
--
-- Counts transitions of the Attack-Up buff from off to on. It never writes to
-- the game; the only output is otomo_counter.json + a trace line per use.
-- ---------------------------------------------------------------------------

-- Channels: one independent counter per (object, method) candidate. Which
-- object actually carries the horn buff is not obvious from the class names
-- (cOtomoConditionManager turned out to be the Palico's own status, not the
-- buff it grants the hunter), so count them all and let the data decide.
local channels = {}
local observation = { quest_sec = 0, last_now = nil }

local function channel_count()
    local n = 0
    for _ in pairs(channels) do n = n + 1 end
    return n
end

local function best_channel()
    local best = nil
    for _, ch in pairs(channels) do
        if best == nil or (ch.c.uses or 0) > (best.c.uses or 0) then best = ch end
    end
    return best
end

local function reset_channels()
    for _, ch in pairs(channels) do
        ch.c = { uses = 0, uptime = 0, observed = 0, last_state = false, events = {} }
    end
end

local function counter_snapshot()
    local list = {}
    for _, ch in pairs(channels) do
        list[#list + 1] = {
            type = ch.type, method = ch.method, path = ch.path,
            uses = ch.c.uses,
            uses_playing = ch.c.uses_playing or 0,
            uptime_sec = ch.c.uptime,
            observed_sec = ch.c.observed,
            last_use = ch.c.last_at,
            signal_kind = ch.kind,
        }
    end
    table.sort(list, function(a, b) return (a.uses or 0) > (b.uses or 0) end)
    local best = best_channel()
    local uses_playing = best and (best.c.uses_playing or 0) or 0
    return {
        version = VERSION,
        uses = best and best.c.uses or 0,
        uses_playing = uses_playing,
        uptime_sec = best and best.c.uptime or 0,
        observed_sec = best and best.c.observed or 0,
        quest_observed_sec = observation.quest_sec,
        uses_per_10min = observation.quest_sec > 0
            and (math.floor(uses_playing / observation.quest_sec * 6000 + 0.5) / 10) or nil,
        uptime_pct = (best and best.c.observed or 0) > 0
            and (math.floor((best.c.uptime / best.c.observed) * 1000 + 0.5) / 10) or nil,
        last_use = best and best.c.last_at or nil,
        signal = best and (best.type .. ":" .. best.method) or nil,
        override_hits = state.override_hits or 0,
        horn_addr = state.horn_addr,
        channel_count = #list,
        playing = state.last_playing,
        horn_cooltime = state.params.HORN_ATKUP
            and field_value(state.params.HORN_ATKUP, "_CoolTime") or nil,
        quiet_others = state.cfg and state.cfg.quiet_others or false,
        channels = list,
    }
end

local function save_counter()
    safe(function() json.dump_file("otomo_counter.json", counter_snapshot()) end)
end

local CHANNEL_METHODS = {
    { name = "isActiveAttackUp", kind = "bool" },
    { name = "isEnableAttackUpIcon", kind = "bool" },
    { name = "get_OtomoHorn_Attack", kind = "number" },
}

local function read_channel(ch)
    local v = getter(ch.obj, ch.method)
    if v == nil then return nil end
    if ch.kind == "number" then
        if type(v) ~= "number" then return nil end
        return v > 0
    end
    return v == true
end

local function local_hunter()
    local pm = safe(sdk.get_managed_singleton, "app.PlayerManager")
    if not pm then return nil end
    local list = field_value(pm, "_InstancedPlayerList")
    if list ~= nil then
        local n = list_length(list)
        if n then
            for i = 0, math.min(n - 1, 8) do
                local p = safe(function() return list[i] end)
                if p ~= nil then
                    local user = getter(p, "get_IsUserControl")
                    local npc = getter(p, "get_IsNpc")
                    if user == true and npc ~= true then return p end
                end
            end
        end
    end
    return getter(pm, "getMasterPlayer")
end

local function add_channels(root, rootName, found)
    for _, m in ipairs(CHANNEL_METHODS) do
        for _, h in ipairs(walk_find_method(root, m.name, 4, 500)) do
            local key = h.type .. "|" .. m.name .. "|" .. h.path
            if not channels[key] then
                channels[key] = {
                    type = h.type, method = m.name, path = rootName .. ":" .. h.path,
                    obj = h.obj, kind = m.kind,
                    c = { uses = 0, uptime = 0, observed = 0, last_state = false, events = {} },
                }
                found[#found + 1] = { type = h.type, method = m.name, path = rootName .. ":" .. h.path }
            end
        end
    end
end

local function discover_channels()
    local found = {}
    local om = safe(sdk.get_managed_singleton, "app.OtomoManager")
    if om then
        local ctl = getter(om, "getMasterOtomoManagedControl")
        if ctl ~= nil then add_channels(ctl, "otomo", found) end
        local char = master_character()
        if char ~= nil then add_channels(char, "otomo_char", found) end
    end
    local hunter = local_hunter()
    if hunter ~= nil then add_channels(hunter, "hunter", found) end

    if #found > 0 then
        trace(string.format("counter channels: %d", channel_count()))
    end
    safe(function()
        json.dump_file("otomo_counter_diag.json", {
            version = VERSION,
            channel_count = channel_count(),
            added = found,
            all = (function()
                local out = {}
                for _, ch in pairs(channels) do
                    out[#out + 1] = { type = ch.type, method = ch.method, path = ch.path }
                end
                return out
            end)(),
        })
    end)
    return channel_count() > 0
end

local counter_ticks = 0

-- The otomo (and the right condition manager) only exist once the quest is
-- running. Discovery in the hub finds a look-alike that never fires, so
-- re-resolve on the quest transition and drop channels that stop answering.
local function rediscover(reason)
    local saved = {}
    for k, ch in pairs(channels) do saved[k] = ch.c end
    channels = {}
    discover_channels()
    for k, ch in pairs(channels) do
        if saved[k] ~= nil then ch.c = saved[k] end
    end
    trace("counter re-discover (" .. reason .. ") -> " .. channel_count() .. " channels")
end

local function update_counter()
    if state.counter_off then return end
    if channel_count() == 0 then
        if state.frame < (state.buff_next or 0) then return end
        state.buff_next = state.frame + 300
        if not discover_channels() then return end
    end

    counter_ticks = counter_ticks + 1
    local now = safe(function() return os.time() end)
    local label = os.date("%H:%M:%S")
    local flow = quest_flow()

    if flow.playing and not state.prev_playing then
        rediscover("quest start")
    end
    state.prev_playing = flow.playing
    state.last_playing = flow.playing

    if type(now) == "number" and type(observation.last_now) == "number" then
        local d = now - observation.last_now
        if d > 0 and flow.playing then
            observation.quest_sec = observation.quest_sec + d
        end
    end
    if type(now) == "number" then observation.last_now = now end

    local wrote = false
    local alive = 0
    for key, ch in pairs(channels) do
        local active = read_channel(ch)
        if active == nil then
            ch.nil_polls = (ch.nil_polls or 0) + 1
            if ch.nil_polls >= 40 then
                channels[key] = nil
                trace("counter dropped stale channel " .. tostring(ch.type))
            end
        else
            ch.nil_polls = 0
            alive = alive + 1
            local ev = step_counter(ch.c, active, now, label)
            if ev ~= nil then
                ch.c.events[#ch.c.events + 1] = { kind = ev.kind, at = ev.at }
                while #ch.c.events > 50 do table.remove(ch.c.events, 1) end
                wrote = true
                if ev.kind == "start" then
                    if flow.playing then
                        ch.c.uses_playing = (ch.c.uses_playing or 0) + 1
                    end
                    local ct = state.params.HORN_ATKUP
                        and field_value(state.params.HORN_ATKUP, "_CoolTime") or nil
                    trace(string.format("%s:%s #%d (cooltime=%s)",
                        ch.type, ch.method, ch.c.uses, tostring(ct)))
                end
            end
        end
    end

    -- Everything answered nil: the objects are stale, look again (at most
    -- every ~30 s so the walk cannot become a per-frame cost).
    if alive == 0 and channel_count() > 0 then
        if state.frame >= (state.redisc_next or 0) then
            state.redisc_next = state.frame + 1800
            rediscover("all channels stale")
        end
    end

    local lead = best_channel()
    state.buff_now = lead ~= nil and lead.c.last_state or nil

    if wrote or counter_ticks % 240 == 0 then save_counter() end
end

-- ---------------------------------------------------------------------------
-- always-available override (v0.6.0, experimental)
--
-- requestForceUseOtomoTool() is accepted by the game but the AI ignores it
-- (verified: 10 requests, 0 uses). What the AI does read is
-- cOtomoToolManagedBase.canUseOtomoTool(), so we hook that method and return
-- true for the chosen tool.
--
-- Per REFramework's docs: args[1] = thread context, args[2] = `this`, and the
-- post function's return value replaces the original when it is a valid
-- pointer (sdk.to_ptr(true) for a boolean).
--
-- The hook is installed lazily and only while the user turns it on. The horn's
-- address is resolved OUTSIDE the hook (calling game methods inside a hook is
-- how crashes happen), and the hook body only compares two strings.
-- ---------------------------------------------------------------------------

local function install_manager_hook()
    if state.hook_state ~= nil then return state.hook_state == "installed" end
    local td = safe(sdk.find_type_definition, "app.mcOtomoToolManager")
    if not td then state.hook_state = "type not found" return false end
    local m = safe(function() return td:get_method("updateMain") end)
        or safe(function() return td:get_method("onCreate") end)
    if not m then state.hook_state = "method not found" return false end
    local ok = safe(function()
        sdk.hook(m, function(args)
            if state.mgr_raw == nil and args ~= nil then state.mgr_raw = args[2] end
        end, function() end)
        return true
    end)
    state.hook_state = ok and "installed" or "hook failed"
    trace("manager hook: " .. tostring(state.hook_state))
    return ok == true
end

local function manager()
    if state.mgr ~= nil then return state.mgr end
    local raw = state.mgr_raw
    if raw == nil then return nil end
    local obj = nil
    if type(sdk.to_managed_object) == "function" then
        obj = safe(sdk.to_managed_object, raw)
    end
    if obj == nil then obj = raw end
    local td = safe(function() return obj:get_type_definition() end)
    if td == nil then return nil end
    state.mgr = obj
    state.mgr_type = safe(function() return td:get_full_name() end)
    trace("manager captured: " .. tostring(state.mgr_type))
    return obj
end

-- Call a method declared with exactly one parameter.
local function call_int(obj, methodName, value)
    if obj == nil then return nil, false end
    local td = safe(function() return obj:get_type_definition() end)
    if td == nil then return nil, false end
    for _, m in ipairs(safe(function() return td:get_methods() end) or {}) do
        if safe(function() return m:get_name() end) == methodName
            and safe(function() return m:get_num_params() end) == 1 then
            return safe(function() return m:call(obj, value) end), true
        end
    end
    return nil, false
end

local function install_override_hook()
    if state.override_state ~= nil then return state.override_state == "installed" end
    local td = safe(sdk.find_type_definition, "app.cOtomoToolManagedBase")
    if not td then state.override_state = "type not found" return false end
    local m = safe(function() return td:get_method("canUseOtomoTool") end)
    if not m then state.override_state = "method not found" return false end

    local last_this = nil
    local ok = safe(function()
        sdk.hook(m,
            function(args)
                -- string compare only: no conversions, no game calls here
                last_this = args ~= nil and args[2] or nil
                if state.cfg ~= nil and state.cfg.override_can_use == true
                    and state.horn_addr ~= nil and last_this ~= nil
                    and tostring(last_this) == state.horn_addr then
                    state.override_hits = (state.override_hits or 0) + 1
                    return sdk.PreHookResult.SKIP_ORIGINAL
                end
            end,
            function(retval)
                if state.cfg ~= nil and state.cfg.override_can_use == true
                    and state.horn_addr ~= nil and last_this ~= nil
                    and tostring(last_this) == state.horn_addr then
                    return sdk.to_ptr(true)
                end
                return retval
            end)
        return true
    end)
    state.override_state = ok and "installed" or "hook failed"
    trace("override hook: " .. tostring(state.override_state))
    return ok == true
end

local function tool_value(name)
    for _, t in ipairs(state.tool_values or {}) do
        if t.name == name then return t.value end
    end
    return nil
end

-- Resolve everything OUTSIDE the hook, then install it once.
local function override_tick()
    local cfg = state.cfg
    if not cfg or not cfg.override_can_use then return end

    local flow = quest_flow()
    if not flow.playing then return end

    if not install_manager_hook() then return end
    local mgr = manager()
    if mgr == nil then return end

    if state.horn_addr == nil then
        local value = tool_value(cfg.override_tool)
        if value == nil then return end
        local horn = call_int(mgr, "getOtomoToolManagedClass", value)
        if horn == nil then return end
        local ptr = safe(sdk.to_ptr, horn)
        state.horn_addr = tostring(ptr or horn)
        trace("override target " .. tostring(cfg.override_tool) .. " @ " .. state.horn_addr)
    end

    install_override_hook()

    -- outside the hook: report whether it is actually matching
    if state.override_hits ~= nil and state.override_reported ~= true then
        state.override_reported = true
        trace("override matched " .. tostring(state.override_hits) .. " time(s)")
    end
end

-- ---------------------------------------------------------------------------

local function install_manager_hook()
    if state.hook_state ~= nil then return state.hook_state == "installed" end
    local td = safe(sdk.find_type_definition, "app.mcOtomoToolManager")
    if not td then state.hook_state = "type not found" return false end
    local m = safe(function() return td:get_method("updateMain") end)
        or safe(function() return td:get_method("onCreate") end)
    if not m then state.hook_state = "method not found" return false end
    local ok = safe(function()
        sdk.hook(m, function(args)
            -- store the raw pointer only; nothing is called on it here
            if state.mgr_raw == nil and args ~= nil then state.mgr_raw = args[2] end
        end, function() end)
        return true
    end)
    state.hook_state = ok and "installed" or "hook failed"
    trace("manager hook: " .. tostring(state.hook_state))
    return ok == true
end

local function manager()
    if state.mgr ~= nil then return state.mgr end
    local raw = state.mgr_raw
    if raw == nil then return nil end
    local obj = nil
    if type(sdk.to_managed_object) == "function" then
        obj = safe(sdk.to_managed_object, raw)
    end
    if obj == nil then obj = raw end
    local td = safe(function() return obj:get_type_definition() end)
    if td == nil then return nil end
    state.mgr = obj
    state.mgr_type = safe(function() return td:get_full_name() end)
    trace("manager captured: " .. tostring(state.mgr_type))
    return obj
end

-- Call a method declared with exactly one parameter.
local function call_int(obj, methodName, value)
    if obj == nil then return nil, false end
    local td = safe(function() return obj:get_type_definition() end)
    if td == nil then return nil, false end
    for _, m in ipairs(safe(function() return td:get_methods() end) or {}) do
        if safe(function() return m:get_name() end) == methodName
            and safe(function() return m:get_num_params() end) == 1 then
            return safe(function() return m:call(obj, value) end), true
        end
    end
    return nil, false
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

    -- Tier C: quiet the tools that were not picked. Same mechanism, opposite
    -- direction — fewer alternatives is what makes "more likely" true when the
    -- cooldown is no longer the limiter.
    local quieted = {}
    for _, name in ipairs(quiet_targets(cfg, state.live_names)) do
        local obj = params_object_for(name)
        if obj ~= nil then
            local cur = field_value(obj, "_CoolTime")
            if type(cur) == "number" then
                if state.original[name] == nil then state.original[name] = cur end
                if cur ~= cfg.quiet_cooltime_sec then
                    write_number(obj, "_CoolTime", cfg.quiet_cooltime_sec)
                    write_number(obj, "_CoolTime_PowerUp", cfg.quiet_cooltime_sec)
                    quieted[#quieted + 1] = name
                end
            end
        end
    end
    if #quieted > 0 then
        trace("quieted " .. #quieted .. " other tool(s) to " .. cfg.quiet_cooltime_sec .. "s")
        state.last_writes = state.last_writes .. (#writes > 0 and "; " or "")
            .. "quieted " .. #quieted
    end
end

-- Put back the tools that were quieted but are no longer meant to be (toggle
-- turned off), without touching the ones the user is actively tuning.
local function revert_quiet()
    local cfg = state.cfg
    if not cfg then return end
    local restored = 0
    for name, obj in pairs(state.params) do
        local entry = cfg.tools[name]
        if (not entry or entry.mode ~= "tune") and state.original[name] ~= nil then
            local cur = field_value(obj, "_CoolTime")
            if type(cur) == "number" and cur ~= state.original[name] then
                write_number(obj, "_CoolTime", state.original[name])
                write_number(obj, "_CoolTime_PowerUp", state.original[name])
                restored = restored + 1
            end
        end
    end
    if restored > 0 then
        trace("reverted " .. restored .. " quieted tool(s)")
    end
end

local function tick()
    state.frame = state.frame + 1

    -- the counter is read-only and independent of the tuning config
    if state.frame % 15 == 0 then
        local ok, err = pcall(update_counter)
        if not ok then log.info(TAG .. " counter error: " .. tostring(err)) end
    end

    if not state.cfg then return end

    if state.frame % 30 == 0 then
        local ok2, err2 = pcall(override_tick)
        if not ok2 then log.info(TAG .. " override error: " .. tostring(err2)) end
    end

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

    local was_quiet = state.cfg.quiet_others
    changed, state.cfg.quiet_others =
        imgui.checkbox("Quiet the other tools (raises their cooldown)", state.cfg.quiet_others)
    if changed then
        save_config()
        if was_quiet and not state.cfg.quiet_others then revert_quiet() end
        trace("quiet_others -> " .. tostring(state.cfg.quiet_others))
    end
    if state.cfg.quiet_others then
        imgui.text("  other tools -> " .. tostring(state.cfg.quiet_cooltime_sec) .. " s")
    end

    changed, state.cfg.override_can_use =
        imgui.checkbox("Always available (experimental, hooks the game)", state.cfg.override_can_use)
    if changed then
        save_config()
        trace("override_can_use -> " .. tostring(state.cfg.override_can_use))
    end
    if state.cfg.override_can_use then
        imgui.text(string.format("  %s   manager: %s   override: %s   hits: %d",
            tostring(state.cfg.override_tool),
            tostring(state.mgr_type or "not captured"),
            tostring(state.override_state or "-"),
            state.override_hits or 0))
    end

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
    -- read-only counter
    if channel_count() == 0 then
        imgui.text("horn counter: no signal found yet")
    else
        local best = best_channel()
        local uses = best and best.c.uses or 0
        local pct = 0
        if best and best.c.observed > 0 then
            pct = math.floor((best.c.uptime / best.c.observed) * 1000 + 0.5) / 10
        end
        imgui.text(string.format("horn uses: %d   uptime: %s%%   last: %s",
            uses, tostring(pct), tostring(best and best.c.last_at or "-")))
        imgui.text(string.format("in quests: %d uses over %d s%s",
            best and (best.c.uses_playing or 0) or 0,
            math.floor(observation.quest_sec),
            observation.quest_sec > 0
                and string.format("  (= %s per 10 min)",
                    tostring(math.floor(((best and best.c.uses_playing or 0)
                        / observation.quest_sec * 6000 + 0.5) / 10)))
                or ""))
        imgui.text("best signal: " .. tostring(best and (best.type .. ":" .. best.method) or "-")
            .. "   (" .. channel_count() .. " channels)")
    end
    if imgui.button("Reset counter") then
        reset_channels()
        observation.quest_sec = 0
        observation.last_now = nil
        save_counter()
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
    channels = channels,
    observation = observation,
    update_counter = update_counter,
    reset_channels = reset_channels,
    discover_channels = discover_channels,
    quiet_targets = quiet_targets,
    revert_quiet = revert_quiet,
    manager = manager,
    install_manager_hook = install_manager_hook,
    install_override_hook = install_override_hook,
    override_tick = override_tick,
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
