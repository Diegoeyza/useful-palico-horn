--
-- otomo_tools.lua v0.1.0 — make the Palico use a chosen support move more often
--
-- What it does (Tier A, state-only):
--   Keeps a chosen "Otomo Tool" off cooldown for the master Palico, so the
--   game's own AI can pick it as often as its desire gate and animation allow.
--   Default preset: the Attack-Up horn (the trumpet).
--
-- What it does NOT do:
--   It never calls an action (no useOtomoTool / doUseOtomoTool / animation
--   driving). Those are the calls that get this kind of mod a crash reputation.
--   See MODDING-NOTES.md 7.2/7.4 — mutate state, never drive the action.
--
-- Why the names are not hardcoded:
--   The tool enum is read from app.OtomoDef.USE_OTOMO_TOOL_TYPE at runtime and
--   matched by pattern, because a patch already rebalanced horn frequency once
--   and can rename enum members. Weight/matching never assumes numeric values.
--
-- Load: reframework\autorun\  (Script Generated UI -> "Otomo Tools v…")
-- Config: reframework\data\otomo_tools.json
-- Trace:  reframework\data\otomo_tools_trace.json  (ring buffer, crash-survivable)
--
-- Every SDK call is pcall-guarded. The few game methods called are arity- and
-- parameter-type-checked first: a wrong call is an uncatchable native crash.
--

local re = re
local sdk = sdk
local json = json
local log = log
local imgui = imgui

local VERSION = "0.1.1"
local TAG = "[OtomoTools]"

local ALREADY_LOADED = _G.OTOMO_TOOLS_LOADED == true
_G.OTOMO_TOOLS_LOADED = true

local CONFIG_FILE = "otomo_tools.json"
local TRACE_FILE = "otomo_tools_trace.json"

local MAX_STR = 160
local MAX_NODES = 700

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

local function type_name(obj)
    if obj == nil then return nil end
    local td = safe(function() return obj:get_type_definition() end)
    return td and safe(function() return td:get_full_name() end) or nil
end

local function is_obj(v)
    if v == nil or type(v) ~= "userdata" then return false end
    if type(sdk.is_managed_object) == "function" then
        local ok = safe(sdk.is_managed_object, v)
        if ok ~= nil then return ok == true end
    end
    return true
end

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

-- Enum sentinels are not real tools; passing one to a native per-tool method is
-- an out-of-range index, which is an uncatchable crash. Keep them out.
local function is_sentinel_name(name)
    local n = tostring(name):lower()
    return n:find("none", 1, true) ~= nil
        or n:find("invalid", 1, true) ~= nil
        or n:find("dummy", 1, true) ~= nil
        or n:find("max", 1, true) ~= nil
end

-- ---------------------------------------------------------------------------
-- bounded graph walk (finds the live tool manager)
-- ---------------------------------------------------------------------------

local function list_length(obj)
    local n = safe(function() return obj:get_Count() end)
    if type(n) == "number" then return math.floor(n) end
    n = safe(function() return obj:get_Size() end)
    if type(n) == "number" then return math.floor(n) end
    n = safe(function() return #obj end)
    if type(n) == "number" then return math.floor(n) end
    return nil
end

local function children_of(obj)
    local kids = {}
    local n = list_length(obj)
    if n then
        for i = 0, math.min(n - 1, 48) do
            local v = safe(function() return obj[i] end)
            if v ~= nil then kids[#kids + 1] = { key = "[" .. i .. "]", value = v } end
        end
        return kids
    end
    local td = safe(function() return obj:get_type_definition() end)
    local depth = 0
    while td and depth < 6 do
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

local function walk(root, maxDepth, visit)
    if root == nil then return 0 end
    local queue = { [1] = { obj = root, depth = 0 } }
    local seen = { [root] = true }
    local nodes, head, tail = 0, 1, 1
    while head <= tail and nodes < MAX_NODES do
        local item = queue[head]
        queue[head] = nil
        head = head + 1
        nodes = nodes + 1
        local tn = type_name(item.obj)
        if visit(item.obj, tn, item.depth) then return nodes end
        if item.depth < maxDepth then
            for _, k in ipairs(children_of(item.obj)) do
                local v = k.value
                if is_obj(v) and not seen[v] then
                    seen[v] = true
                    tail = tail + 1
                    queue[tail] = { obj = v, depth = item.depth + 1 }
                end
            end
        end
    end
    return nodes
end

-- ---------------------------------------------------------------------------
-- guarded calls
-- ---------------------------------------------------------------------------

local method_cache = {}

local function find_overload(ownerType, methodName, arity)
    local key = methodName .. "@" .. tostring(ownerType) .. "#" .. tostring(arity)
    if method_cache[key] ~= nil then return method_cache[key] end
    local found = { m = nil, params = {}, reason = "type not found" }
    local td = safe(sdk.find_type_definition, ownerType)
    if td then
        found.reason = "no overload"
        for _, m in ipairs(safe(function() return td:get_methods() end) or {}) do
            local n = safe(function() return m:get_name() end)
            local np = safe(function() return m:get_num_params() end)
            if n == methodName and np == arity then
                local names = {}
                local pts = safe(function() return m:get_param_types() end)
                for i = 1, arity do
                    local pt = pts and pts[i]
                    names[i] = pt and safe(function() return pt:get_name() end) or nil
                end
                found = { m = m, params = names, reason = "ok" }
                break
            end
        end
    end
    method_cache[key] = found
    return found
end

-- An enum/Int32 parameter is what these setters take; anything else is not a
-- signature we are willing to call.
local function param_is_int(p)
    if p == nil then return true end
    local s = tostring(p)
    return s:find("Int") ~= nil or s:find("TOOL_TYPE") ~= nil or s:find("Enum") ~= nil
end

local function call_one(obj, methodName, value)
    local tn = type_name(obj)
    if not tn then return nil end
    local found = find_overload(tn, methodName, 1)
    if not found.m or not param_is_int(found.params[1]) then return nil end
    return safe(function() return found.m:call(obj, value) end)
end

local function call_zero(obj, methodName)
    local tn = type_name(obj)
    if not tn then return nil end
    local found = find_overload(tn, methodName, 0)
    if not found.m then return nil end
    return safe(function() return found.m:call(obj) end)
end

-- ---------------------------------------------------------------------------
-- pure logic (tested offline)
-- ---------------------------------------------------------------------------

local MODES = { off = true, cooldown = true }

-- Presets are patterns, not exact names: the enum member names are a patch
-- target and must not be baked into the config format.
local PRESETS = {
    horn_attack = {
        { pattern = "Horn.*Atk", mode = "cooldown" },
        { pattern = "Horn.*Def", mode = "off" },
    },
    horn_both = {
        { pattern = "Horn.*Atk", mode = "cooldown" },
        { pattern = "Horn.*Def", mode = "cooldown" },
    },
    healing = {
        { pattern = "Heal", mode = "cooldown" },
        { pattern = "BadCondition", mode = "cooldown" },
    },
}

local DEFAULT_CONFIG = {
    version = 1,
    enabled = true,
    preset = "horn_attack",
    tick_interval_frames = 30,
    reset_global_cooldown = true,
    verify_all_tools = false,   -- read live state for unselected tools too
    debug = false,
    tools = {},          -- [enum member name] = { mode = "cooldown"|"off" }
}

local function copy_shallow(t)
    local out = {}
    for k, v in pairs(t or {}) do out[k] = v end
    return out
end

-- Write the preset's modes into cfg.tools, only for names that exist live.
local function apply_preset(cfg, live_names)
    local preset = PRESETS[cfg.preset or ""] or {}
    live_names = live_names or {}
    for _, name in ipairs(live_names) do
        for _, rule in ipairs(preset) do
            if name:find(rule.pattern) then
                local entry = cfg.tools[name] or {}
                entry.mode = rule.mode
                cfg.tools[name] = entry
            end
        end
    end
    return cfg
end

-- Drop unknown tools, unknown modes, missing entries. Never throws.
local function normalize_config(raw, live_names)
    local cfg = copy_shallow(DEFAULT_CONFIG)
    cfg.tools = {}
    raw = type(raw) == "table" and raw or {}

    if raw.enabled ~= nil then cfg.enabled = raw.enabled == true end
    if type(raw.preset) == "string" then cfg.preset = raw.preset end
    if type(raw.tick_interval_frames) == "number" then
        local n = math.floor(raw.tick_interval_frames)
        if n < 1 then n = 1 elseif n > 600 then n = 600 end
        cfg.tick_interval_frames = n
    end
    if raw.reset_global_cooldown ~= nil then
        cfg.reset_global_cooldown = raw.reset_global_cooldown == true
    end
    if raw.verify_all_tools ~= nil then
        cfg.verify_all_tools = raw.verify_all_tools == true
    end
    if raw.debug ~= nil then cfg.debug = raw.debug == true end

    local known = {}
    for _, n in ipairs(live_names or {}) do known[n] = true end

    if type(raw.tools) == "table" then
        for name, entry in pairs(raw.tools) do
            if type(name) == "string" and (not next(known) or known[name])
                and type(entry) == "table" then
                local mode = entry.mode
                if type(mode) ~= "string" or not MODES[mode] then mode = "off" end
                cfg.tools[name] = { mode = mode }
            end
        end
    end

    -- A config with no usable tools falls back to the preset.
    if not next(cfg.tools) then apply_preset(cfg, live_names) end
    return cfg
end

local function should_tick(frame, interval)
    interval = tonumber(interval) or 30
    if interval < 1 then interval = 1 end
    return frame % interval == 0
end

-- Only run where a Palico exists and the game is not tearing a quest down.
local function quest_gate_ok(flow)
    if type(flow) ~= "table" then return false end
    if not flow.playing then return false end
    if flow.result or flow.ending or flow.loading then return false end
    return true
end

-- Which tools to clear this tick. `live[name] = { ok = bool, using = bool }`.
local function plan_resets(cfg, live)
    local out = {}
    if not cfg or cfg.enabled ~= true then return out end
    for name, entry in pairs(cfg.tools or {}) do
        if entry.mode == "cooldown" then
            local st = (live or {})[name]
            -- Reset when the game says it is on cooldown. Unknown state is left
            -- alone: a blind reset every tick is exactly the kind of write that
            -- looks fine and then misbehaves.
            if st and st.ok == false and st.using ~= true then
                out[#out + 1] = name
            end
        end
    end
    table.sort(out)
    return out
end

-- Tools the mod is allowed to ask the game about. Anything not listed here is
-- never passed to a per-tool native method: an out-of-range enum value in a
-- setter is an uncatchable crash, so the set stays small on purpose.
local function active_names(cfg)
    local out = {}
    if not cfg then return out end
    for name, entry in pairs(cfg.tools or {}) do
        if entry.mode == "cooldown" then out[name] = true end
    end
    return out
end

M._test = {
    normalize_config = normalize_config,
    apply_preset = apply_preset,
    should_tick = should_tick,
    quest_gate_ok = quest_gate_ok,
    plan_resets = plan_resets,
    active_names = active_names,
    wrap_text = wrap_text,
    presets = PRESETS,
    modes = MODES,
    _rt = nil,   -- filled in below, once the runtime exists
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
-- runtime state
-- ---------------------------------------------------------------------------

local state = {
    cfg = nil,
    live_names = {},
    manager = nil,
    manager_type = nil,
    manager_misses = 0,
    frame = 0,
    last_status = "(idle)",
    last_plan = "",
    last_apply_at = 0,
    enum_type = nil,
    tool_values = nil,
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

local function resolve_manager()
    local om = safe(sdk.get_managed_singleton, "app.OtomoManager")
    if not om then return nil end
    local roots = {
        getter(om, "getMasterOtomoManagedControl"),
        getter(om, "getMasterOtomoInfo"),
        field_value(om, "_OtomoManagedControlList"),
        field_value(om, "_AidOtomoManagedControlList"),
    }
    for _, root in ipairs(roots) do
        if root ~= nil then
            local hit = nil
            walk(root, 5, function(obj, tn)
                if tn and tn:lower():find("otomotool", 1, true)
                    and type_has_method(tn, "canUseOtomoTool") then
                    hit = obj
                    state.manager_type = tn
                    return true
                end
                return false
            end)
            if hit then
                state.manager = hit
                state.manager_misses = 0
                return hit
            end
        end
    end
    state.manager = nil
    state.manager_misses = state.manager_misses + 1
    return nil
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

local function snapshot_tools(filter)
    local live = {}
    local mgr = state.manager
    if not mgr or not state.tool_values then return live end
    local using = getter(mgr, "get_IsUseingTool") == true
    local current = getter(mgr, "get_UseOtomoToolType")
    for _, t in ipairs(state.tool_values) do
        if filter == nil or filter[t.name] then
            local ok = call_one(mgr, "isCoolTimeOut", t.value)
            local can = call_one(mgr, "canUseOtomoTool", t.value)
            live[t.name] = {
                -- tri-state on purpose: true = ready, false = on cooldown,
                -- nil = the call failed or the method is missing. Only a real
                -- `false` may lead to a write.
                ok = ok,
                can = can,
                using = using and current == t.value or false,
            }
        end
    end
    return live
end

local function tick()
    state.frame = state.frame + 1

    if not state.cfg then return end
    if not should_tick(state.frame, state.cfg.tick_interval_frames) then return end

    local flow = quest_flow()

    -- Never hold a tool-manager pointer across a quest boundary: the Palico is
    -- recreated per quest, and calling into a freed managed object is an
    -- uncatchable crash.
    if not flow.playing then
        state.manager = nil
        state.manager_type = nil
        state.last_plan = ""
        return
    end

    if not quest_gate_ok(flow) then
        state.last_plan = ""
        return
    end

    if not state.manager then
        if state.frame % 60 == 0 then resolve_manager() end   -- ~1/s while in a quest
        if not state.manager then return end
    end

    local live = snapshot_tools(active_names(state.cfg))
    local plan = plan_resets(state.cfg, live)
    state.last_plan = #plan > 0 and table.concat(plan, ", ") or ""

    for _, name in ipairs(plan) do
        local value = nil
        for _, t in ipairs(state.tool_values or {}) do
            if t.name == name then value = t.value break end
        end
        if value ~= nil then
            call_one(state.manager, "resetCoolTimeSingle", value)
            if state.cfg.reset_global_cooldown then
                call_zero(state.manager, "resetGCDTimer")
            end
            trace("reset " .. name .. " (" .. tostring(value) .. ")")
        end
    end
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------

local function mode_button(name, mode)
    if imgui.button((mode == "cooldown" and "[cooldown]" or "[off]") .. "##" .. name) then
        local entry = state.cfg.tools[name] or {}
        entry.mode = (entry.mode == "cooldown") and "off" or "cooldown"
        state.cfg.tools[name] = entry
        state.cfg.preset = "custom"
        save_config()
        trace("mode " .. name .. " -> " .. entry.mode)
    end
end

local ui = { frame = -999, flow = nil, live = {} }

-- The panel redraws at screen rate; native per-tool getters should not. One
-- refresh per 30 frames is plenty and keeps the call surface small.
local function ui_reads()
    if state.frame - ui.frame >= 30 then
        ui.frame = state.frame
        ui.flow = quest_flow()
        local filter = active_names(state.cfg)
        if state.cfg.verify_all_tools then filter = nil end
        ui.live = state.manager and snapshot_tools(filter) or {}
    end
    return ui
end

local function draw_body()
    if not state.cfg then
        imgui.text("config not loaded")
        return
    end

    local changed
    changed, state.cfg.enabled = imgui.checkbox("Enabled", state.cfg.enabled)
    if changed then save_config() end

    changed, state.cfg.verify_all_tools =
        imgui.checkbox("Read live state for every tool", state.cfg.verify_all_tools)
    if changed then save_config() end

    imgui.text("Preset: " .. tostring(state.cfg.preset))
    for _, pname in ipairs({ "horn_attack", "horn_both", "healing" }) do
        if imgui.button(pname) then
            state.cfg.preset = pname
            for _, n in ipairs(state.live_names) do
                local entry = state.cfg.tools[n] or {}
                entry.mode = "off"
                state.cfg.tools[n] = entry
            end
            apply_preset(state.cfg, state.live_names)
            save_config()
            trace("preset -> " .. pname)
        end
        imgui.same_line()
    end
    imgui.new_line()

    imgui.separator()
    if not state.manager then
        imgui.text("manager: not found (retrying)")
        if imgui.button("Resolve now") then
            resolve_manager()
        end
    else
        imgui.text("manager: " .. tostring(state.manager_type))
        local flow = ui_reads().flow or {}
        imgui.text(string.format("flow playing=%s result=%s loading=%s",
            tostring(flow.playing), tostring(flow.result), tostring(flow.loading)))
    end

    imgui.separator()
    local live = ui_reads().live or {}
    for _, t in ipairs(state.tool_values or {}) do
        local entry = state.cfg.tools[t.name] or { mode = "off" }
        local st = live[t.name] or {}
        imgui.text(string.format("%-22s %-8s ok=%s can=%s",
            t.name, entry.mode, tostring(st.ok), tostring(st.can)))
        imgui.same_line()
        mode_button(t.name, entry.mode)
    end

    imgui.separator()
    imgui.text("last reset: " .. (state.last_plan ~= "" and state.last_plan or "(none)"))
    text_wrapped("status: " .. state.last_status)
    imgui.text("config: " .. CONFIG_FILE .. "   trace: " .. TRACE_FILE)
end

-- ImGui requires TreePop for every TreePush. An exception inside the body is
-- exactly how you get the "Missing TreePop()" error the user sees, so the pop
-- happens outside the pcall.
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
    resolve_manager = resolve_manager,
    snapshot_tools = snapshot_tools,
    quest_flow = quest_flow,
    load_tool_enum = load_tool_enum,
    load_config = load_config,
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
