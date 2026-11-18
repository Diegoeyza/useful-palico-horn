--
-- otomo_runtime_probe.lua — find the LIVE tool objects (one session, in quest)
--
-- Why: writing app.user_data.OtomoToolParam._CoolTime changes the data but not
-- the behaviour (uses stayed ~502 s apart with the param reading 90). The value
-- the game counts is on app.cOtomoToolManagedBase, which is only reachable
-- through app.mcOtomoToolManager — a mini-component the earlier probe could not
-- find from the otomo character.
--
-- This probe tries every route the type list suggests and reports which one
-- works, plus the live _CoolTime it finds. Read-only: it calls getters only.
--
-- Buttons:
--   1. Dump types   pure reflection, safe anywhere.
--   2. Find manager IN A QUEST (the otomo context is null in the hub).
--
-- Output: reframework/data/otomo_runtime_probe.json
--

local re = re
local sdk = sdk
local json = json
local log = log
local imgui = imgui

local VERSION = "0.1.4"
local TAG = "[OtomoRuntimeProbe]"
local OUT = "otomo_runtime_probe.json"
local OUT_TYPES = "otomo_runtime_probe_types.json"

local ALREADY_LOADED = _G.OTOMO_RUNTIME_PROBE_LOADED == true
_G.OTOMO_RUNTIME_PROBE_LOADED = true

local MAX_STR = 200
local MAX_NODES = 2500
local MAX_DEPTH = 6

local lastStatus = "(idle)"

-- ---------------------------------------------------------------------------
-- helpers (same shapes the other probes on this build use)
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


-- this build has no imgui.text_wrapped (only text / text_colored)
local function wrap_text(text, width)
    local out = {}
    text = tostring(text or "")
    width = math.max(1, tonumber(width) or 76)
    local line = ""
    for word in text:gmatch("%S+") do
        if #line == 0 then line = word
        elseif #line + 1 + #word <= width then line = line .. " " .. word
        else out[#out + 1] = line line = word end
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
    for _, line in ipairs(wrap_text(text, width)) do imgui.text(line) end
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
        for i = 0, math.min(n - 1, 64) do
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

-- walk and collect objects matching a predicate
local function walk(root, rootPath, visit)
    if root == nil then return 0 end
    local queue = { [1] = { obj = root, path = rootPath, depth = 0 } }
    local seen = { [root] = true }
    local nodes, head, tail = 0, 1, 1
    while head <= tail and nodes < MAX_NODES do
        local item = queue[head]
        queue[head] = nil
        head = head + 1
        nodes = nodes + 1
        local tn = type_name(item.obj)
        if visit(item.obj, tn, item.path, item.depth) then return nodes end
        if item.depth < MAX_DEPTH then
            for _, k in ipairs(children_of(item.obj)) do
                local v = k.value
                if is_obj(v) and not seen[v] then
                    seen[v] = true
                    tail = tail + 1
                    queue[tail] = {
                        obj = v,
                        path = item.path .. "." .. k.key,
                        depth = item.depth + 1,
                    }
                end
            end
        end
    end
    return nodes
end

local function describe(typeName, maxFields, maxMethods)
    local td = safe(sdk.find_type_definition, typeName)
    local e = { name = typeName, exists = td ~= nil }
    if not td then return e end
    e.full = safe_str(safe(function() return td:get_full_name() end))
    e.parent = safe_str(safe(function()
        local p = td:get_parent_type()
        return p and p:get_full_name()
    end))
    e.fields = {}
    for i, f in ipairs(safe(function() return td:get_fields() end) or {}) do
        if i > (maxFields or 120) then break end
        e.fields[#e.fields + 1] = {
            name = safe_str(safe(function() return f:get_name() end)),
            type = safe_str(safe(function() return f:get_type():get_name() end)),
        }
    end
    e.methods = {}
    for i, m in ipairs(safe(function() return td:get_methods() end) or {}) do
        if i > (maxMethods or 200) then break end
        e.methods[#e.methods + 1] = {
            name = safe_str(safe(function() return m:get_name() end)),
            params = safe(function() return m:get_num_params() end),
            ret = safe_str(safe(function() return m:get_return_type():get_name() end)),
        }
    end
    return e
end

-- ---------------------------------------------------------------------------
-- 1. types
-- ---------------------------------------------------------------------------

local TYPES = {
    "app.OtomoManager", "app.OtomoCharacter", "app.OtomoAccessor",
    "app.OtomoController", "app.cOtomoContextHolder",
    "app.cEntityBase", "app.cOtomoControllerEntityBase",
    "app.cMasterOtomoControllerEntity", "app.cEntityHolder",
    "app.mcOtomoToolManager", "app.cOtomoToolManagedBase",
    "app.cGlobalOtomoToolManagedData", "app.cRestrictOtomoToolManager",
    "app.CharacterBase", "app.CharacterParamHolder",
}

local function dump_types()
    local out = { probe_version = VERSION, kinds = {} }
    for _, n in ipairs(TYPES) do
        out.kinds[#out.kinds + 1] = describe(n)
    end

    -- the container type is game-specific; resolve it from the live field
    local om = safe(sdk.get_managed_singleton, "app.OtomoManager")
    local ctl = om and getter(om, "getMasterOtomoManagedControl")
    local info = ctl and field_value(ctl, "_OtomoManagedInfo")
    local char = info and field_value(info, "<Character>k__BackingField")
    if char ~= nil then
        local f = field_descriptor(char, "_Components")
        local holder = f and safe(function() return f:get_type():get_name() end)
        if holder then
            out.components_type = holder
            for _, prefix in ipairs({ "app.", "via.", "" }) do
                if safe(sdk.find_type_definition, prefix .. holder) then
                    out.components_type_resolved = prefix .. holder
                    out.components = describe(prefix .. holder)
                    break
                end
            end
        end
    end
    json.dump_file(OUT_TYPES, out)
    lastStatus = "types -> " .. OUT_TYPES
    log.info(TAG .. " " .. lastStatus)
end

-- ---------------------------------------------------------------------------
-- 2. find the runtime manager (in a quest)
-- ---------------------------------------------------------------------------

local function character()
    local om = safe(sdk.get_managed_singleton, "app.OtomoManager")
    if not om then return nil end
    local ctl = getter(om, "getMasterOtomoManagedControl")
    if ctl == nil then return nil end
    local info = field_value(ctl, "_OtomoManagedInfo")
    local char = info and field_value(info, "<Character>k__BackingField")
    if char ~= nil then return char end
    return nil
end

local function find_manager()
    local out = {
        probe_version = VERSION,
        found = false,
        roots = {},
        hits = {},
    }

    local char = character()
    out.character = type_name(char)
    if char == nil then
        out.reason = "no master otomo character (are you in a quest?)"
        json.dump_file(OUT, out)
        lastStatus = "no character -> " .. OUT
        return
    end

    -- candidate roots, including the paths the counter proved are live in-quest
    local roots = {}
    local function add_root(name, obj)
        if obj ~= nil then roots[#roots + 1] = { name = name, obj = obj } end
    end
    add_root("character", char)
    add_root("_ContextHolder", field_value(char, "_ContextHolder"))
    local ctx = field_value(char, "_ContextHolder")
    if ctx ~= nil then
        add_root("ctx.<Otomo>", field_value(ctx, "<Otomo>k__BackingField"))
        add_root("ctx.<StatusManager>",
            field_value(field_value(ctx, "<Otomo>k__BackingField"), "<StatusManager>k__BackingField"))
    end
    add_root("_Components", field_value(char, "_Components"))
    for _, fname in ipairs({
        "_MiniCompUpdater_LateUpdate", "_MiniCompUpdater_AfterMotion",
        "_MiniCompUpdater_AfterAction", "_MiniCompUpdater_LateUpdateEnd",
        "_MiniCompUpdator_BeforeAction",
    }) do
        add_root(fname, field_value(char, fname))
    end
    local access = getter(char, "get_Access")
    add_root("get_Access()", access)
    add_root("access.get_MasterEntity()", access and getter(access, "get_MasterEntity"))

    for _, r in ipairs(roots) do
        out.roots[#out.roots + 1] = { name = r.name, type = type_name(r.obj) }
        walk(r.obj, r.name, function(obj, tn, path, depth)
            if tn == nil then return false end
            if tn:find("mcOtomoToolManager")
                or tn:find("cOtomoToolManagedBase")
                or type_has_method(tn, "getOtomoToolManagedClass") then
                local rec = {
                    path = path, type = tn, depth = depth,
                    fields = {},
                    methods = {},
                }
                for _, f in ipairs(field_names(obj)) do
                    rec.fields[#rec.fields + 1] = { name = f, value = safe_str(field_value(obj, f)) }
                    if #rec.fields > 40 then break end
                end
                local td = safe(sdk.find_type_definition, tn)
                for _, m in ipairs(safe(function() return td and td:get_methods() end) or {}) do
                    local mn = safe(function() return m:get_name() end)
                    if mn then
                        rec.methods[#rec.methods + 1] = mn
                        if #rec.methods > 80 then break end
                    end
                end
                out.hits[#out.hits + 1] = rec
            end
            return false
        end)
    end

    -- if we found a manager, ask it for the live horn object
    local HORN_ATKUP = 2      -- app.OtomoDef.USE_OTOMO_TOOL_TYPE.HORN_ATKUP
    for _, h in ipairs(out.hits) do
        if type_has_method(h.type, "getOtomoToolManagedClass") then
            for _, r in ipairs(roots) do
                walk(r.obj, r.name, function(obj, tn, path)
                    if tn ~= h.type then return false end
                    local live = nil
                    local td = safe(sdk.find_type_definition, tn)
                    for _, m in ipairs(safe(function() return td and td:get_methods() end) or {}) do
                        if safe(function() return m:get_name() end) == "getOtomoToolManagedClass"
                            and safe(function() return m:get_num_params() end) == 1 then
                            live = safe(function() return m:call(obj, HORN_ATKUP) end)
                            break
                        end
                    end
                    if live ~= nil then
                        out.found = true
                        out.manager_path = path
                        out.horn = {
                            type = type_name(live),
                            cool_time = safe_str(field_value(live, "_CoolTime")),
                            cool_timer = safe_str(field_value(live, "_CoolTimeTimer")),
                            stock = safe_str(field_value(live, "_StockCount")),
                            is_active = safe_str(field_value(live, "_IsActive")),
                            is_enable = safe_str(field_value(live, "_IsEnable")),
                        }
                        return true
                    end
                    return false
                end)
                if out.found then break end
            end
        end
        if out.found then break end
    end

    json.dump_file(OUT, out)
    lastStatus = string.format("hits=%d found=%s -> %s", #out.hits,
        tostring(out.found), OUT)
    log.info(TAG .. " " .. lastStatus)
end

-- ---------------------------------------------------------------------------
-- 3. capture the live instance from a hook
--
-- The manager is an ace mini-component: no owner exposes it as a field, so the
-- bounded walk cannot reach it. A pre-hook on one of its own methods receives
-- `this` as args[1] — the object we need. The hook only stores the pointer and
-- calls nothing (MODDING-NOTES 4.8: never dereference a hook argument).
-- ---------------------------------------------------------------------------

local captured = nil
local captured_alt = nil
local hook_args = nil
local hook_state = "not installed"

local function install_hook()
    if hook_state == "installed" then return true end
    local td = safe(sdk.find_type_definition, "app.mcOtomoToolManager")
    if not td then hook_state = "type not found" return false end
    local m = safe(function() return td:get_method("updateMain") end)
        or safe(function() return td:get_method("onCreate") end)
    if not m then hook_state = "method not found" return false end
    local ok = safe(function()
        sdk.hook(m, function(args)
            -- store only; do not touch the objects here.
            -- On this build args[2] is `this` and args[3..] are the parameters
            -- (same convention as artian_editor / kill_counter / highlights).
            if captured == nil and args ~= nil then
                captured = args[2]
                captured_alt = args[1]
                -- raw snapshot only; nothing is called on these here
                hook_args = { args[1], args[2], args[3], args[4], args[5] }
            end
        end, function() end)
        return true
    end)
    hook_state = ok and "installed" or "hook failed"
    log.info(TAG .. " hook " .. tostring(hook_state))
    return ok == true
end

local function get_managed_class(mgr, value)
    if mgr == nil then return nil end
    local td = safe(function() return mgr:get_type_definition() end)
    for _, m in ipairs(safe(function() return td and td:get_methods() end) or {}) do
        if safe(function() return m:get_name() end) == "getOtomoToolManagedClass"
            and safe(function() return m:get_num_params() end) == 1 then
            return safe(function() return m:call(mgr, value) end)
        end
    end
    return nil
end

local TOOLS = {
    { "INSECT_HEAL_DELIVERY", 0 }, { "SHIELD_PROVOKE", 1 },
    { "HORN_ATKUP", 2 }, { "HORN_DEFUP", 3 }, { "SLINGER", 4 },
    { "TRAP_PARALYZE", 5 }, { "INSECT_HEAL_REVIVE", 7 },
    { "TRAP_FLASH", 8 }, { "STEAL_BOOMERANG", 10 },
    { "BAD_CONDITIONS_HEAL_DELIVERY", 11 }, { "SET_BOMB", 12 },
    { "MULTI_HIT_BOOMERANG", 13 },
}

-- Hook args arrive as raw pointers on this build, so convert explicitly.
-- to_managed_object is only called on a non-nil value that the hook itself
-- produced, and the result is validated before anything calls a method on it.
local function try_convert(v, label)
    if v == nil then return nil end
    if is_obj(v) then return v, label .. ":direct" end
    if type(v) == "number" and type(sdk.to_ptr) == "function" then
        local p = safe(sdk.to_ptr, v)
        if p ~= nil and type(sdk.to_managed_object) == "function" then
            local obj = safe(sdk.to_managed_object, p)
            if obj ~= nil and is_obj(obj) then return obj, label .. ":to_ptr" end
        end
    end
    if type(sdk.to_managed_object) == "function" then
        local obj = safe(sdk.to_managed_object, v)
        if obj ~= nil and is_obj(obj) then return obj, label .. ":to_managed_object" end
    end
    return nil
end

local function resolve_captured()
    local function usable(obj)
        if obj == nil then return false end
        return safe(function() return obj:get_type_definition() end) ~= nil
    end
    local obj, how = try_convert(captured, "args[2]")
    if usable(obj) then return obj, how end
    obj, how = try_convert(captured_alt, "args[1]")
    if usable(obj) then return obj, how end
    for i, v in ipairs(hook_args or {}) do
        local o, h = try_convert(v, "args[" .. i .. "]")
        if usable(o) then return o, h end
    end
    return nil, "no captured argument has a type definition"
end



-- What is this value, really? No method calls beyond type reflection.
local function describe_value(v)
    if v == nil then return nil end
    local rec = { lua_type = type(v), tostring = tostring(v) }
    rec.is_object = is_obj(v)
    local td = safe(function() return v:get_type_definition() end)
    if td ~= nil then
        rec.has_type_def = true
        rec.type = safe(function() return td:get_full_name() end)
        local ms = safe(function() return td:get_methods() end)
        rec.method_count = ms and #ms or 0
        local fs = safe(function() return td:get_fields() end)
        rec.field_count = fs and #fs or 0
    else
        rec.has_type_def = false
        if rec.is_object and type(sdk.to_managed_object) == "function" then
            local obj = safe(sdk.to_managed_object, v)
            local td2 = obj and safe(function() return obj:get_type_definition() end)
            if td2 ~= nil then
                rec.retry_type = safe(function() return td2:get_full_name() end)
            end
        end
    end
    return rec
end

local function report_live()
    local out = { probe_version = VERSION, hook = hook_state }
    out.args = {}
    for i, v in ipairs(hook_args or {}) do
        out.args[i] = describe_value(v)
    end
    out.captured_lua_type = captured ~= nil and type(captured) or nil
    out.captured_tostring = captured ~= nil and tostring(captured) or nil
    if captured == nil then
        out.reason = "no instance captured yet (stay in a quest a few seconds)"
        json.dump_file(OUT, out)
        lastStatus = "not captured yet"
        return
    end

    local obj, how = resolve_captured()
    out.captured = obj ~= nil
    out.resolved_by = how
    if obj == nil then
        out.reason = "captured a value but could not convert it to a managed object"
        json.dump_file(OUT, out)
        lastStatus = "captured but not convertible (" .. tostring(how) .. ")"
        return
    end
    captured = obj
    out.type = type_name(captured)
    out.is_object = is_obj(captured)

    out.fields = {}
    for _, f in ipairs(field_names(captured)) do
        out.fields[#out.fields + 1] = { name = f, value = safe_str(field_value(captured, f)) }
        if #out.fields > 50 then break end
    end

    local td = safe(function() return captured:get_type_definition() end)
    out.methods = {}
    for _, m in ipairs(safe(function() return td and td:get_methods() end) or {}) do
        local n = safe(function() return m:get_name() end)
        if n then
            out.methods[#out.methods + 1] = {
                name = n,
                params = safe(function() return m:get_num_params() end),
            }
            if #out.methods > 90 then break end
        end
    end

    out.tools = {}
    for _, t in ipairs(TOOLS) do
        local obj = get_managed_class(captured, t[2])
        if obj ~= nil then
            local rec = {
                name = t[1], value = t[2],
                type = type_name(obj),
                cool_time = safe_str(field_value(obj, "_CoolTime")),
                cool_timer = safe_str(field_value(obj, "_CoolTimeTimer")),
                stock = safe_str(field_value(obj, "_StockCount")),
                is_active = safe_str(field_value(obj, "_IsActive")),
                is_enable = safe_str(field_value(obj, "_IsEnable")),
            }
            local otd = safe(function() return obj:get_type_definition() end)
            rec.methods = {}
            for _, m in ipairs(safe(function() return otd and otd:get_methods() end) or {}) do
                local n = safe(function() return m:get_name() end)
                if n and (n:find("CoolTime") or n:find("Stock") or n:find("canUse")) then
                    rec.methods[#rec.methods + 1] = {
                        name = n,
                        params = safe(function() return m:get_num_params() end),
                    }
                end
            end
            out.tools[#out.tools + 1] = rec
        end
    end

    json.dump_file(OUT, out)
    lastStatus = string.format("live: %d tools -> %s", #out.tools, OUT)
    log.info(TAG .. " " .. lastStatus)
end

-- UI
-- ---------------------------------------------------------------------------

local function draw_body()
    imgui.text("1. Dump types (safe anywhere)")
    if imgui.button("Dump types") then
        local ok, err = pcall(dump_types)
        lastStatus = ok and lastStatus or ("dump failed: " .. tostring(err))
    end

    imgui.separator()
    imgui.text("2. Find manager by walking (IN A QUEST)")
    if imgui.button("Find manager") then
        local ok, err = pcall(find_manager)
        lastStatus = ok and lastStatus or ("find failed: " .. tostring(err))
    end

    imgui.separator()
    imgui.text("3. Capture from the hook (IN A QUEST, ~2 s)")
    imgui.text("hook: " .. tostring(hook_state) ..
        (captured ~= nil and ("   captured: " .. tostring(type_name(captured))) or "   captured: -"))
    if imgui.button("Report live values") then
        local ok, err = pcall(report_live)
        lastStatus = ok and lastStatus or ("report failed: " .. tostring(err))
    end

    imgui.separator()
    text_wrapped("Last: " .. lastStatus)
    imgui.text("Outputs: " .. OUT_TYPES .. ", " .. OUT)
end

-- ImGui needs TreePop for every TreePush; an exception in the body is exactly
-- how "Missing TreePop()" happens, so the pop is outside the pcall.
local function draw_ui()
    if not imgui.tree_node("Otomo Runtime Probe v" .. VERSION) then return end
    local ok, err = pcall(draw_body)
    safe(function() imgui.tree_pop() end)
    if not ok then
        lastStatus = "draw error: " .. tostring(err)
        log.info(TAG .. " " .. lastStatus)
    end
end

if not ALREADY_LOADED then
    install_hook()
    re.on_draw_ui(function()
        local ok, err = pcall(draw_ui)
        if not ok then log.info(TAG .. " draw error: " .. tostring(err)) end
    end)
    log.info(TAG .. " loaded v" .. VERSION)
end
