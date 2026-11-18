--
-- otomo_probe.lua — read-only discovery probe for Otomo Tools (MH Wilds)
--
-- Why: Otomo Tools needs three things that only the live build can answer:
--   (1) which object actually owns the Palico tool manager (mcOtomoToolManager),
--   (2) the real numeric values of the USE_OTOMO_TOOL_TYPE enum,
--   (3) whether "the Palico never uses the horn" is a cooldown problem or a
--       desire/lottery problem.
--
-- It never hooks anything, never writes to game state, and only writes JSON
-- under reframework/data/. Every SDK call is pcall-guarded; the few game
-- methods it calls are arity- and type-checked first, because a wrong call is
-- an uncatchable native crash (MODDING-NOTES 4.8 / 7.4).
--
-- Buttons, in order:
--   1. Dump types        pure reflection; calls nothing. Safe anywhere.
--   2. Resolve instance  finds the master otomo + tool manager; calls only
--                        0-arg property getters.
--   3. Watch (toggle)    ~1 sample per 2 s: tool gates + horn buff. This is the
--                        button that answers question (3) — leave it on for a
--                        full hunt.
--
-- Outputs (all in <game>\reframework\data\):
--   otomo_probe_types.json      every candidate type: fields, methods, enums+values
--   otomo_probe_instance.json   resolution routes, the tool-manager hit, signatures
--   otomo_probe_watch.json      the per-2s timeline (ring, capped)
--
-- Load: <game>\reframework\autorun\otomo_probe.lua
--   REFramework menu (Insert) -> Script Generated UI -> "Otomo Probe v…"
--

local re = re
local sdk = sdk
local json = json
local log = log
local imgui = imgui

local VERSION = "0.1.1"
local TAG = "[OtomoProbe]"

-- Re-running the script must not register a second set of callbacks.
local ALREADY_LOADED = _G.OTOMO_PROBE_LOADED == true
_G.OTOMO_PROBE_LOADED = true

local OUT_TYPES = "otomo_probe_types.json"
local OUT_INSTANCE = "otomo_probe_instance.json"
local OUT_WATCH = "otomo_probe_watch.json"

local MAX_STR = 160
local MAX_NODES = 700
local MAX_DEPTH = 5
local MAX_SAMPLES = 320
local SAMPLE_EVERY = 120      -- frames between samples (~2 s at 60 fps)
local WRITE_EVERY = 3         -- write the watch file every N samples

local lastStatus = "(idle)"

-- ---------------------------------------------------------------------------
-- helpers (same shapes the probes on this build already use)
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

local function type_name(obj)
    if obj == nil then return nil end
    local td = safe(function() return obj:get_type_definition() end)
    return td and safe(function() return td:get_full_name() end) or nil
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

local function is_obj(v)
    if v == nil or type(v) ~= "userdata" then return false end
    if type(sdk.is_managed_object) == "function" then
        local ok = safe(sdk.is_managed_object, v)
        if ok ~= nil then return ok == true end
    end
    return true
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
    local is_static = safe(function() return f:is_static() end)
    return safe(function() return f:get_data(is_static and nil or obj) end)
end

-- A zero-arg getter, by name, on this object's type or a base type.
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

local function describe_type(typeName, opts)
    opts = opts or {}
    local td = safe(sdk.find_type_definition, typeName)
    local e = { name = typeName, exists = td ~= nil }
    if not td then return e end
    e.full = safe_str(safe(function() return td:get_full_name() end))
    e.parent = safe_str(safe(function()
        local p = td:get_parent_type()
        return p and p:get_full_name()
    end))
    e.size = safe(function() return td:get_size() end)

    e.fields = {}
    local fields = safe(function() return td:get_fields() end) or {}
    for i, f in ipairs(fields) do
        if i > (opts.max_fields or 200) then break end
        local rec = {
            name = safe_str(safe(function() return f:get_name() end)),
            type = safe_str(safe(function() return f:get_type():get_name() end)),
            static = safe(function() return f:is_static() end),
        }
        if rec.static then
            rec.value = safe_str(safe(function() return f:get_data(nil) end))
        end
        e.fields[#e.fields + 1] = rec
    end

    e.methods = {}
    local methods = safe(function() return td:get_methods() end) or {}
    for i, m in ipairs(methods) do
        if i > (opts.max_methods or 400) then break end
        e.methods[#e.methods + 1] = {
            name = safe_str(safe(function() return m:get_name() end)),
            full = safe_str(safe(function() return m:get_full_name() end)),
            ret  = safe_str(safe(function() return m:get_return_type():get_name() end)),
            params = safe(function() return m:get_num_params() end),
            static = safe(function() return m:is_static() end),
        }
    end
    return e
end

-- ---------------------------------------------------------------------------
-- graph walking (bounded, object-identity dedup)
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

-- visit(item, typeName) with item = { obj, path, depth }
local function walk(root, rootPath, maxDepth, visit)
    if root == nil then return 0 end
    local queue = { [1] = { obj = root, path = rootPath or "root", depth = 0 } }
    local seen = { [root] = true }
    local nodes = 0
    local head, tail = 1, 1
    while head <= tail and nodes < MAX_NODES do
        local item = queue[head]
        queue[head] = nil
        head = head + 1
        nodes = nodes + 1
        local tn = type_name(item.obj)
        visit(item, tn)
        if item.depth < maxDepth then
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

local function type_has_method(tn, methodName)
    if not tn then return false end
    local td = safe(sdk.find_type_definition, tn)
    if not td then return false end
    local depth = 0
    while td and depth < 8 do
        if safe(function() return td:get_method(methodName) end)
            or safe(function() return td:get_method(methodName .. "()") end) then
            return true
        end
        td = safe(function() return td:get_parent_type() end)
        depth = depth + 1
    end
    return false
end

local function find_objects(root, rootPath, pattern, maxDepth)
    local hits = {}
    walk(root, rootPath, maxDepth or MAX_DEPTH, function(item, tn)
        if tn and tn:lower():find(pattern:lower(), 1, true) then
            hits[#hits + 1] = { path = item.path, type = tn, obj = item.obj, depth = item.depth }
        end
    end)
    return hits
end

local function find_owners(root, rootPath, methodName, maxDepth)
    local hits = {}
    walk(root, rootPath, maxDepth or MAX_DEPTH, function(item, tn)
        if type_has_method(tn, methodName) then
            hits[#hits + 1] = { path = item.path, type = tn, obj = item.obj, depth = item.depth }
        end
    end)
    return hits
end

-- ---------------------------------------------------------------------------
-- 1. type dump
-- ---------------------------------------------------------------------------

local CANDIDATE_TYPES = {
    -- otomo core
    "app.OtomoManager", "app.OtomoCharacter", "app.cOtomoManageControl",
    "app.OtomoAccessor", "app.OtomoController",
    "app.cOtomoControllerEntityBase", "app.cOtomoControllerEntityHolder",
    "app.OtomoParamHolder", "app.OtomoParamPack", "app.OtomoGlobalParam",
    "app.NpcOtomoDataParam", "app.cNpcPartnerData",
    -- tool system
    "app.mcOtomoToolManager", "app.OtomoToolManager",
    "app.cGlobalOtomoToolManagedData", "app.cOtomoToolManagedBase",
    "app.cRestrictOtomoToolManager", "app.cCollectOtomoToolData",
    "app.cCollectTargetData",
    "app.OtomoToolParam", "app.OtomoToolParamBase",
    "app.OtomoToolParam_Horn", "app.OtomoToolParam_Horn_AtkUp",
    "app.OtomoToolParam_Horn_DefUp",
    -- buff / music
    "app.cMusicSkillConditionChecker", "app.cOtomoMusicSkillConditions",
    "app.OtomoMusicSkillParam", "app.PlayerOtomoMusicSkillParam",
    -- desire / lottery
    "app.cSituationDesireData", "app.cDesireValue", "app.DesireGroupPackages",
}

local ENUM_CANDIDATES = {
    "USE_OTOMO_TOOL_TYPE", "USE_OTOMO_TOOL_TYPE_Fixed",
    "OTOMO_TOOL_TYPE", "OTOMO_TOOL_TYPE_Fixed",
    "OTOMO_TOOL_TYPEBit", "OTOMO_TOOL_HORN_TYPE",
    "RESTRICT_OTOMO_TOOL_TYPE", "MUSIC_SKILL_TYPE",
    "OTOMO_TYPE", "OTOMO_TYPE_Fixed", "PARTNER_OTOMO_TYPE",
}

-- Nested il2cpp types can resolve as app.X, app.OtomoDef.X or bare X.
local function resolve_enum_type(shortName)
    local candidates = { "app.OtomoDef." .. shortName, "app." .. shortName, shortName }
    for _, c in ipairs(candidates) do
        if safe(sdk.find_type_definition, c) then return c end
    end
    return nil
end

-- Enum sentinels are not real tools; passing one to a native per-tool method is
-- an out-of-range index. Keep them out of the watch loop.
local function is_sentinel_name(name)
    local n = tostring(name):lower()
    return n:find("none", 1, true) ~= nil
        or n:find("invalid", 1, true) ~= nil
        or n:find("dummy", 1, true) ~= nil
        or n:find("max", 1, true) ~= nil
end

local function dump_types()
    local out = { probe_version = VERSION, kinds = {}, enums = {} }
    for _, name in ipairs(CANDIDATE_TYPES) do
        out.kinds[#out.kinds + 1] = describe_type(name)
    end
    for _, short in ipairs(ENUM_CANDIDATES) do
        local resolved = resolve_enum_type(short)
        local rec = { name = short, resolved = resolved }
        if resolved then
            rec.values = enum_values(resolved)
        end
        out.enums[#out.enums + 1] = rec
    end
    json.dump_file(OUT_TYPES, out)
    lastStatus = "types -> " .. OUT_TYPES
    log.info(TAG .. " " .. lastStatus)
    return out
end

-- ---------------------------------------------------------------------------
-- 2. instance resolution
-- ---------------------------------------------------------------------------

local cached_mgr = nil
local cached_mgr_type = nil
local cached_mgr_at = 0
local cached_buff = nil

local function sample_fields(obj, limit)
    local rec = {}
    local seen = 0
    local td = safe(function() return obj:get_type_definition() end)
    local depth = 0
    while td and depth < 4 and seen < (limit or 40) do
        for _, f in ipairs(safe(function() return td:get_fields() end) or {}) do
            if not safe(function() return f:is_static() end) then
                local name = safe(function() return f:get_name() end)
                if name then
                    local v = safe(function() return f:get_data(obj) end)
                    rec[#rec + 1] = { name = name, value = safe_str(v) }
                    seen = seen + 1
                    if seen >= (limit or 40) then break end
                end
            end
        end
        td = safe(function() return td:get_parent_type() end)
        depth = depth + 1
    end
    return rec
end

local function resolve_instance()
    local out = {
        probe_version = VERSION,
        routes = {},
        tool_hits = {},
        character_hits = {},
        buff_owners = {},
    }

    local om = safe(sdk.get_managed_singleton, "app.OtomoManager")
    out.otomo_manager = om ~= nil
    out.otomo_manager_type = type_name(om)

    -- candidate roots, most specific first
    local roots = {}
    local function add_root(label, obj)
        if obj ~= nil then roots[#roots + 1] = { label = label, obj = obj } end
    end

    if om then
        add_root("OtomoManager.getMasterOtomoManagedControl",
            getter(om, "getMasterOtomoManagedControl"))
        add_root("OtomoManager.getMasterOtomoInfo", getter(om, "getMasterOtomoInfo"))
        add_root("OtomoManager.getMasterOtomoInfo_BindCheck",
            getter(om, "getMasterOtomoInfo_BindCheck"))
        add_root("OtomoManager._MasterOtomoIndex", field_value(om, "_MasterOtomoIndex"))
        add_root("OtomoManager.get_OtomoManagedControlList",
            getter(om, "get_OtomoManagedControlList")
                or field_value(om, "_OtomoManagedControlList"))
        add_root("OtomoManager._OtomoManagedControlList",
            field_value(om, "_OtomoManagedControlList"))
        add_root("OtomoManager.get_OtShellManager", getter(om, "get_OtShellManager"))
        add_root("OtomoManager._Catalog", field_value(om, "_Catalog"))
    end

    -- the tool manager might also be a singleton of its own
    local direct = safe(sdk.get_managed_singleton, "app.OtomoToolManager")
        or safe(sdk.get_managed_singleton, "app.mcOtomoToolManager")
    add_root("managed_singleton(OtomoToolManager)", direct)
    out.direct_singleton = direct ~= nil

    out.route_count = #roots

    for _, r in ipairs(roots) do
        local route = {
            label = r.label,
            type = type_name(r.obj),
            fields = sample_fields(r.obj, 12),
            tool_hits = 0,
            char_hits = 0,
        }

        -- characters reachable from this root
        local chars = find_objects(r.obj, r.label, "OtomoCharacter", 4)
        route.char_hits = #chars
        for _, c in ipairs(chars) do
            out.character_hits[#out.character_hits + 1] = { path = c.path, type = c.type }
        end

        -- anything whose type name mentions the tool manager
        local hits = find_objects(r.obj, r.label, "OtomoTool", 5)
        route.tool_hits = #hits
        for _, h in ipairs(hits) do
            local is_mgr = type_has_method(h.type, "canUseOtomoTool")
                or type_has_method(h.type, "useOtomoTool")
            out.tool_hits[#out.tool_hits + 1] = {
                path = h.path,
                type = h.type,
                depth = h.depth,
                looks_like_manager = is_mgr and true or false,
                fields = sample_fields(h.obj, 24),
                methods = (function()
                    local names, td = {}, safe(sdk.find_type_definition, h.type)
                    for _, m in ipairs(safe(function() return td and td:get_methods() end) or {}) do
                        names[#names + 1] = safe_str(safe(function() return m:get_name() end))
                        if #names > 90 then break end
                    end
                    return names
                end)(),
            }
            if is_mgr and not cached_mgr then
                cached_mgr = h.obj
                cached_mgr_type = h.type
                cached_mgr_at = os.clock()
            end
        end

        out.routes[#out.routes + 1] = route
    end

    -- buff / music-skill owner, searched from the master character
    local char_root = roots[1] and roots[1].obj or nil
    if char_root then
        local owners = find_owners(char_root, "search", "isActiveAttackUp", 5)
        for _, o in ipairs(owners) do
            out.buff_owners[#out.buff_owners + 1] = {
                path = o.path, type = o.type,
                fields = sample_fields(o.obj, 30),
            }
        end
        if #out.buff_owners == 0 then
            local owners2 = find_owners(char_root, "search", "resetOtomoHornSkill", 5)
            for _, o in ipairs(owners2) do
                out.buff_owners[#out.buff_owners + 1] = {
                    path = o.path, type = o.type, via = "resetOtomoHornSkill",
                    fields = sample_fields(o.obj, 30),
                }
            end
        end
    end

    out.resolved_manager = cached_mgr ~= nil
    out.resolved_manager_type = cached_mgr_type
    if cached_mgr then
        out.resolved_manager_methods = describe_type(cached_mgr_type, {
            max_fields = 0, max_methods = 200,
        }).methods
    end

    json.dump_file(OUT_INSTANCE, out)
    lastStatus = string.format("instance: manager=%s chars=%d tool-hits=%d -> %s",
        tostring(out.resolved_manager), #out.character_hits, #out.tool_hits, OUT_INSTANCE)
    log.info(TAG .. " " .. lastStatus)
    return out
end

-- ---------------------------------------------------------------------------
-- guarded one-enum-arg method call (arity + param type checked)
-- ---------------------------------------------------------------------------

local method_cache = {}

local function method_owner(obj, methodName)
    local td = safe(function() return obj:get_type_definition() end)
    local depth = 0
    while td and depth < 8 do
        local m = safe(function() return td:get_method(methodName) end)
        if m then return m, safe(function() return td:get_full_name() end) end
        td = safe(function() return td:get_parent_type() end)
        depth = depth + 1
    end
    return nil
end

local function find_one_arg_overload(methodName, ownerType)
    local key = methodName .. "@" .. tostring(ownerType)
    if method_cache[key] ~= nil then return method_cache[key] end
    local td = safe(sdk.find_type_definition, ownerType)
    local found = { m = nil, param = nil, reason = "type not found" }
    if td then
        for _, m in ipairs(safe(function() return td:get_methods() end) or {}) do
            local n = safe(function() return m:get_name() end)
            if n == methodName then
                local np = safe(function() return m:get_num_params() end)
                if np == 1 then
                    local pts = safe(function() return m:get_param_types() end)
                    local p1 = pts and pts[1]
                    found = {
                        m = m,
                        param = p1 and safe(function() return p1:get_name() end) or nil,
                        reason = "ok",
                    }
                    break
                end
            end
        end
        if not found.m then found.reason = "no 1-arg overload" end
    end
    method_cache[key] = found
    return found
end

local function param_ok(paramType)
    if paramType == nil then return true end
    local p = tostring(paramType)
    return p:find("Int") ~= nil or p:find("TOOL_TYPE") ~= nil
        or p:find("Enum") ~= nil or p:find("Boolean") ~= nil
end

local call_log = {}

local function call_one_arg(obj, methodName, value)
    local tn = type_name(obj)
    if not tn then return nil end
    local found = find_one_arg_overload(methodName, tn)
    if not found.m or not param_ok(found.param) then return nil end
    local sigKey = methodName .. "(" .. tostring(found.param) .. ")"
    if not call_log[sigKey] then
        call_log[sigKey] = true
        log.info(TAG .. " calling " .. tn .. ":" .. sigKey)
    end
    return safe(function() return found.m:call(obj, value) end)
end

-- ---------------------------------------------------------------------------
-- 3. watch (the timeline that decides the design)
-- ---------------------------------------------------------------------------

local watch = {
    on = false,
    samples = {},
    frame = 0,
    lost = 0,
    since_write = 0,
}

local tool_enum_cache = nil

local function tool_enum()
    if tool_enum_cache then return tool_enum_cache end
    for _, short in ipairs({
        "USE_OTOMO_TOOL_TYPE", "USE_OTOMO_TOOL_TYPE_Fixed",
        "OTOMO_TOOL_TYPE", "OTOMO_TOOL_TYPE_Fixed",
    }) do
        local resolved = resolve_enum_type(short)
        if resolved then
            local values = enum_values(resolved)
            if values then
                local list = {}
                for name, value in pairs(values) do
                    if type(value) == "number" and value >= 0 and value < 128
                        and not is_sentinel_name(name) then
                        list[#list + 1] = { name = name, value = value }
                    end
                end
                table.sort(list, function(a, b) return a.value < b.value end)
                if #list > 0 then
                    tool_enum_cache = { type_name = resolved, tools = list }
                    return tool_enum_cache
                end
            end
        end
    end
    return nil
end

local function quest_flags()
    local mm = safe(sdk.get_managed_singleton, "app.MissionManager")
    local gf = safe(sdk.get_managed_singleton, "app.GameFlowManager")
    return {
        playing = mm and getter(mm, "get_IsPlayingQuest") and true or false,
        active = mm and getter(mm, "get_IsActiveQuest") and true or false,
        result = mm and getter(mm, "get_IsQuestResult") and true or false,
        ending = mm and getter(mm, "get_IsQuestEndShowing") and true or false,
        loading = gf and getter(gf, "get_Loading") and true or false,
    }
end

local function manager()
    if cached_mgr ~= nil then return cached_mgr end
    -- re-resolve quietly: cheap because the walk is bounded
    local om = safe(sdk.get_managed_singleton, "app.OtomoManager")
    if not om then return nil end
    for _, root in ipairs({
        getter(om, "getMasterOtomoManagedControl"),
        getter(om, "getMasterOtomoInfo"),
        field_value(om, "_OtomoManagedControlList"),
    }) do
        if root ~= nil then
            local hits = find_objects(root, "resolve", "OtomoTool", 4)
            for _, h in ipairs(hits) do
                if type_has_method(h.type, "canUseOtomoTool") then
                    cached_mgr = h.obj
                    cached_mgr_type = h.type
                    cached_mgr_at = os.clock()
                    return cached_mgr
                end
            end
        end
    end
    watch.lost = watch.lost + 1
    return nil
end

local function snapshot()
    local snap = {
        at = os.date("%H:%M:%S"),
        q = quest_flags(),
    }

    local mgr = manager()
    snap.mgr = mgr ~= nil
    snap.mgr_type = cached_mgr_type

    if mgr then
        snap.using = safe(function() return getter(mgr, "get_IsUseingTool") end)
        snap.using_tool = safe(function() return getter(mgr, "get_UseOtomoToolType") end)
        snap.force = safe(function() return getter(mgr, "get_IsForceUseOtomoTool") end)

        local en = tool_enum()
        if en then
            snap.enum = en.type_name
            snap.tools = {}
            for _, t in ipairs(en.tools) do
                snap.tools[#snap.tools + 1] = {
                    n = t.name,
                    v = t.value,
                    en = call_one_arg(mgr, "isEnableOtomoTool", t.value) == true,
                    can = call_one_arg(mgr, "canUseOtomoTool", t.value) == true,
                    cd = call_one_arg(mgr, "getToolTimer", t.value),
                    ok = call_one_arg(mgr, "isCoolTimeOut", t.value) == true,
                }
            end
        end
    end

    -- buff owner (first hit wins; the instance dump tells us which one)
    local buff = cached_buff
    if buff == nil then
        local om = safe(sdk.get_managed_singleton, "app.OtomoManager")
        local root = om and getter(om, "getMasterOtomoManagedControl")
        if root ~= nil then
            local owners = find_owners(root, "resolve", "isActiveAttackUp", 4)
            if #owners > 0 then
                cached_buff = owners[1].obj
                buff = cached_buff
            end
        end
    end
    if buff ~= nil then
        snap.buff_up = safe(function() return getter(buff, "isActiveAttackUp") end) == true
        snap.buff_icon = safe(function() return getter(buff, "isEnableAttackUpIcon") end) == true
        snap.buff_type = type_name(buff)
    end

    return snap
end

local function push_sample()
    if not watch.on then return end
    local ok, snap = pcall(snapshot)
    if not ok or type(snap) ~= "table" then
        lastStatus = "watch: snapshot failed"
        return
    end
    watch.samples[#watch.samples + 1] = snap
    while #watch.samples > MAX_SAMPLES do table.remove(watch.samples, 1) end
    watch.since_write = watch.since_write + 1
    if watch.since_write >= WRITE_EVERY then
        watch.since_write = 0
        json.dump_file(OUT_WATCH, {
            probe_version = VERSION,
            samples = watch.samples,
        })
        lastStatus = string.format("watch: %d samples -> %s", #watch.samples, OUT_WATCH)
    end
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------

local function draw_body()
    imgui.text("1. Dump types (safe anywhere, calls nothing)")
    if imgui.button("Dump types") then
        local ok, err = pcall(dump_types)
        lastStatus = ok and lastStatus or ("dump failed: " .. tostring(err))
    end

    imgui.separator()
    imgui.text("2. Resolve instance (hub or quest; master otomo)")
    if imgui.button("Resolve instance") then
        local ok, err = pcall(resolve_instance)
        lastStatus = ok and lastStatus or ("resolve failed: " .. tostring(err))
    end

    imgui.separator()
    imgui.text("3. Watch (~2 s samples; leave on for a full hunt)")
    local label = watch.on and "Stop watch" or "Start watch"
    if imgui.button(label) then
        watch.on = not watch.on
        if watch.on then
            watch.samples = {}
            watch.lost = 0
            watch.since_write = WRITE_EVERY
        else
            json.dump_file(OUT_WATCH, { probe_version = VERSION, samples = watch.samples })
            lastStatus = "watch stopped, " .. #watch.samples .. " samples"
        end
    end

    if watch.on then
        imgui.text("samples: " .. #watch.samples .. "   lost resolves: " .. watch.lost)
        if cached_mgr_type then
            imgui.text("manager: " .. tostring(cached_mgr_type))
        else
            imgui.text("manager: not found")
        end
        local q = quest_flags()
        imgui.text(string.format("flow playing=%s active=%s loading=%s",
            tostring(q.playing), tostring(q.active), tostring(q.loading)))
    end

    imgui.separator()
    text_wrapped("Last: " .. lastStatus)
    imgui.text("Outputs: " .. OUT_TYPES .. ", " .. OUT_INSTANCE .. ", " .. OUT_WATCH)
end

-- ImGui requires TreePop for every TreePush; an exception in the body is how
-- you get the "Missing TreePop()" error. The pop lives outside the pcall.
local function draw_ui()
    if not imgui.tree_node("Otomo Probe v" .. VERSION) then return end
    local ok, err = pcall(draw_body)
    safe(function() imgui.tree_pop() end)
    if not ok then
        lastStatus = "draw error: " .. tostring(err)
        log.info(TAG .. " " .. lastStatus)
    end
end

-- ---------------------------------------------------------------------------
-- registration
-- ---------------------------------------------------------------------------

if not ALREADY_LOADED then
    re.on_draw_ui(function()
        local ok, err = pcall(draw_ui)
        if not ok then log.info(TAG .. " draw error: " .. tostring(err)) end
    end)

    re.on_frame(function()
        if not watch.on then return end
        watch.frame = (watch.frame or 0) + 1
        if watch.frame % SAMPLE_EVERY == 0 then
            local ok, err = pcall(push_sample)
            if not ok then log.info(TAG .. " sample error: " .. tostring(err)) end
        end
    end)

    log.info(TAG .. " loaded v" .. VERSION)
end
