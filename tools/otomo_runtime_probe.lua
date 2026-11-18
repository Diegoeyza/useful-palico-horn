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

local VERSION = "0.1.0"
local TAG = "[OtomoRuntimeProbe]"
local OUT = "otomo_runtime_probe.json"

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
    json.dump_file(OUT, out)
    lastStatus = "types -> " .. OUT
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
-- UI
-- ---------------------------------------------------------------------------

local function draw_ui()
    if not imgui.tree_node("Otomo Runtime Probe v" .. VERSION) then return end
    imgui.text("1. Dump types (safe anywhere)")
    if imgui.button("Dump types") then
        local ok, err = pcall(dump_types)
        lastStatus = ok and lastStatus or ("dump failed: " .. tostring(err))
    end
    imgui.separator()
    imgui.text("2. Find the live tool manager (IN A QUEST)")
    if imgui.button("Find manager") then
        local ok, err = pcall(find_manager)
        lastStatus = ok and lastStatus or ("find failed: " .. tostring(err))
    end
    imgui.separator()
    imgui.text_wrapped("Last: " .. lastStatus)
    imgui.text("Output: " .. OUT)
    imgui.tree_pop()
end

if not ALREADY_LOADED then
    re.on_draw_ui(function()
        local ok, err = pcall(draw_ui)
        if not ok then log.info(TAG .. " draw error: " .. tostring(err)) end
    end)
    log.info(TAG .. " loaded v" .. VERSION)
end
