--[[
  otomo_horn.lua - fire the Palico's Attack-Up horn on command.

  Sibling of otomo_tools.lua (cooldowns + counter). This one is the timing
  tool: it plays the horn when you decide, so the buff lands where it matters
  instead of whenever the AI feels like it.

  Mechanism (from Nexus 627 PalicoMod.dll, verified in game): replay the
  Palico's own action request with the horn's action id.

      hook app.OtomoCharacter:setActionRequest   -- read-only, captures `this`
      fire: setActionRequest(this, 0x85, appendKind)   -- 0x85 = cUseHorn

  The tool's desire gate, cooldown and ~4 min refractory are not involved: this
  is the action layer. Verified repeating, and after the buff expires.

  Triggers
  --------
    - hotkey (default F6) or the panel button          -- always available
    - fire when the buff goes down                     -- keeps it up, gated by
                                                          the global cooldown
    - fire on the first hit to the monster             -- event trigger
    (later: trapped / stunned / paralyzed)

  Buff state comes from the Palico's condition manager (isActiveAttackUp).
  Monster state comes from app.EnemyManager -> _EnemyList -> array, with the
  HP chain Context -> Chara -> HealthManager. Every accessor is tried as a
  getter, a plain method and a field, and the trace records which one worked.
]]

local VERSION = "0.14.0"
local TAG = "[OtomoHorn] "

local CONFIG_FILE = "otomo_horn.json"
local TRACE_FILE = "otomo_horn_trace.json"
local HORN_ACTION = 0x85
local ACTION_TYPE = "app.OtomoCharacter"
local METHOD_NAME = "setActionRequest"

local state = {
    cfg = {
        enabled = true,
        hotkey = "599",          -- "." on this build: unused by the game
        min_interval_sec = 0.5,
        auto_when_down = false,
        use_base_cooldown = true,
        global_cooldown_sec = 480,
        fire_on_first_hit = false,
        cond_trapped = false,
        cond_stunned = false,
        cond_paralyzed = false,
    },

    frames = 0,
    hook_note = "not tried",
    method = nil,
    method_desc = nil,

    self = nil,
    append = nil,
    captured_at = nil,
    captures = 0,

    condition = nil,
    buff = nil,
    buff_checked = 0,

    base_cooldown = nil,
    base_checked = 0,
    boss_ctx = nil,
    boss_em = nil,
    boss_chara = nil,
    boss_basic = nil,
    boss_status = nil,
    boss_modules = {},
    status_type = nil,
    cond = { trapped = nil, stunned = nil, paralyzed = nil },
    cond_prev = {},
    dump_requested = false,
    monster_state = nil,     -- true = damaged, false = full hp, nil = unknown
    monster_hp = nil,
    monster_max = nil,
    monster_note = "-",
    first_hit_done = false,
    chain_logged = false,

    fires = 0,
    last_result = "-",
    last_fire_frame = 0,
    last_fire_time = nil,
    pending_fire = nil,
    pending_kind = nil,      -- "event" or "auto"

    key = nil,
    key_index = nil,
    key_note = "-",
    binding = false,
    key_list = nil,
    scan = nil,             -- { i = next value, max = limit }
    bind_block_until = nil,

    trace = {},
}

local function safe(fn, ...)
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil
end

local function clock()
    return os.date("%H:%M:%S")
end

local function trace(line)
    state.trace[#state.trace + 1] = clock() .. " " .. line
    while #state.trace > 240 do table.remove(state.trace, 1) end
    pcall(json.dump_file, TRACE_FILE, { version = VERSION, lines = state.trace })
end

-- ---------------------------------------------------------------- config ----

local function load_config()
    local raw = safe(json.load_file, CONFIG_FILE)
    if type(raw) ~= "table" then return end
    local c = state.cfg
    if raw.enabled ~= nil then c.enabled = raw.enabled == true end
    if type(raw.hotkey) == "string" then c.hotkey = raw.hotkey end
    if type(raw.min_interval_sec) == "number" then
        c.min_interval_sec = math.max(0, math.min(10, raw.min_interval_sec))
    end
    if raw.auto_when_down ~= nil then c.auto_when_down = raw.auto_when_down == true end
    if raw.use_base_cooldown ~= nil then
        c.use_base_cooldown = raw.use_base_cooldown == true
    end
    if type(raw.global_cooldown_sec) == "number" then
        c.global_cooldown_sec = math.max(0, math.min(3600, raw.global_cooldown_sec))
    end
    if raw.fire_on_first_hit ~= nil then
        c.fire_on_first_hit = raw.fire_on_first_hit == true
    end
    for _, key in ipairs({ "cond_trapped", "cond_stunned", "cond_paralyzed" }) do
        if raw[key] ~= nil then c[key] = raw[key] == true end
    end
end

local function save_config()
    pcall(json.dump_file, CONFIG_FILE, state.cfg)
end

-- ------------------------------------------------------------ reflection ----

local function method0(obj, name)
    if obj == nil then return nil end
    local td = safe(function() return obj:get_type_definition() end)
    local depth = 0
    while td and depth < 8 do
        for _, m in ipairs(safe(function() return td:get_methods() end) or {}) do
            if safe(function() return m:get_name() end) == name
                and safe(function() return m:get_num_params() end) == 0 then
                return m
            end
        end
        td = safe(function() return td:get_parent_type() end)
        depth = depth + 1
    end
    return nil
end

local function getter(obj, name)
    local m = method0(obj, name)
    if m == nil then return nil end
    return safe(function() return m:call(obj) end)
end

local function field_descriptor(obj, name)
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
    if f == nil then return nil end
    return safe(function() return f:get_data(obj) end)
end

-- Tries get_X(), X(), _X, X. Records which spelling worked, once.
local function access(obj, name)
    if obj == nil then return nil, nil end
    for _, get in ipairs({ "get_" .. name, name }) do
        local v = getter(obj, get)
        if v ~= nil then return v, get .. "()" end
    end
    for _, fname in ipairs({ "_" .. name, name }) do
        local v = field_value(obj, fname)
        if v ~= nil then return v, fname end
    end
    return nil, nil
end

local function as_number(v)
    if type(v) == "number" then return v end
    return nil
end

-- Status flags. The exact accessor names are not documented, so several are
-- tried on the status manager and the monster objects, and whichever answers
-- with a boolean/number is used. The "Dump monster" button records the real
-- method and field names so these lists can be corrected from data.
local COND_CANDIDATES = {
    paralyzed = { "Paralysis", "IsParalysis", "isParalysis", "Paralyzed",
                  "Paralyze", "IsParalyze", "isParalyze", "ParalysisNow" },
    stunned   = { "Stun", "IsStun", "isStun", "Stan", "IsStan", "Dizzy",
                  "IsDizzy", "isDizzy", "KO", "IsKO" },
    trapped   = { "Trap", "IsTrap", "isTrap", "Trapped", "IsTrapped",
                  "isTrapped", "Capture", "IsCapture", "isCapture",
                  "IsGimmickTrap", "IsTrapNow" },
}

local function read_flag(objs, names)
    for _, obj in ipairs(objs) do
        if obj ~= nil then
            for _, n in ipairs(names) do
                local v = access(obj, n)
                if type(v) == "boolean" then return v end
                if type(v) == "number" then return v > 0 end
            end
        end
    end
    return nil
end

local function status_manager(ctx, em, chara)
    return access(chara, "StatusManager") or access(em, "StatusManager")
        or access(ctx, "StatusManager") or access(chara, "Condition")
        or access(em, "Condition") or access(ctx, "Condition")
end

-- --------------------------------------------------------------- monster ----

local function enemy_array()
    local mgr = safe(sdk.get_managed_singleton, "app.EnemyManager")
    if mgr == nil then return nil end
    local list, how = access(mgr, "EnemyList")
    if list == nil then return nil end
    local arr = safe(function() return list:call("get_Array") end)
    return arr or list
end

local function array_len(arr)
    local n = safe(function() return arr:get_Count() end)
        or safe(function() return arr:get_Size() end)
    if type(n) == "number" then return math.floor(n) end
    return 0
end

local function monster_scan()
    local arr = enemy_array()
    if arr == nil then
        state.monster_state = nil
        state.monster_note = "no EnemyManager"
        return
    end

    local n = array_len(arr)
    if n == 0 then
        state.monster_state = nil
        state.monster_note = "empty list"
        return
    end

    local damaged, full, seen = false, false, false
    local best_hp, best_max, best_boss = nil, nil, false

    for i = 0, math.min(n - 1, 15) do
        local entry = safe(function() return arr[i] end)
        if entry ~= nil then
            local valid = access(entry, "CharacterValid")
            if valid ~= false then
                local ctx = access(entry, "Context")
                local em = ctx and access(ctx, "Em")
                local basic = em and access(em, "Basic")
                local boss = basic and access(basic, "IsBoss")

                local chara = ctx and access(ctx, "Chara")
                if boss == true and state.boss_chara == nil then
                    state.boss_ctx, state.boss_em = ctx, em
                    state.boss_chara, state.boss_basic = chara, basic
                end
                local health = chara and access(chara, "HealthManager")
                local hp = health and as_number(access(health, "Health"))
                local maxhp = health and as_number(access(health, "MaxHealth"))

                if hp ~= nil and maxhp ~= nil and maxhp > 0 then
                    seen = true
                    if boss == true then
                        best_hp, best_max, best_boss = hp, maxhp, true
                    elseif best_hp == nil then
                        best_hp, best_max = hp, maxhp
                    end
                    if hp < maxhp then damaged = true end
                    if hp >= maxhp then full = true end
                end
            end
        end
    end

    if not seen then
        state.monster_state = nil
        state.monster_note = "no health manager"
        return
    end

    state.monster_hp = best_hp
    state.monster_max = best_max
    state.monster_note = string.format("%s/%s%s",
        tostring(best_hp), tostring(best_max), best_boss and " boss" or "")

    if damaged then
        state.monster_state = true
    elseif full then
        state.monster_state = false
    else
        state.monster_state = nil
    end

    if not state.chain_logged then
        state.chain_logged = true
        trace("monster chain ok: " .. state.monster_note)
    end

    -- status flags, only meaningful while a boss is present
    if state.boss_chara ~= nil then
        local em = state.boss_em
        state.boss_modules = {
            { "conditions", em and access(em, "Conditions") },
            { "capture", em and access(em, "Capture") },
            { "catch", em and access(em, "Catch") },
            { "aistate", em and access(em, "AIStateManager") },
        }
        local sm = status_manager(state.boss_ctx, state.boss_em, state.boss_chara)
        state.boss_status = sm
        state.status_type = sm and safe(function()
            return sm:get_type_definition():get_full_name()
        end) or nil
        local objs = { sm }
        for _, m in ipairs(state.boss_modules) do
            if m[2] ~= nil then objs[#objs + 1] = m[2] end
        end
        objs[#objs + 1] = state.boss_chara
        objs[#objs + 1] = state.boss_em
        objs[#objs + 1] = state.boss_ctx
        state.cond.paralyzed = read_flag(objs, COND_CANDIDATES.paralyzed)
        state.cond.stunned = read_flag(objs, COND_CANDIDATES.stunned)
        state.cond.trapped = read_flag(objs, COND_CANDIDATES.trapped)
    else
        state.cond.paralyzed, state.cond.stunned, state.cond.trapped = nil, nil, nil
    end
end

-- Rising-edge detection: fire once when a monitored flag turns true.
local function cond_trigger()
    local c = state.cond
    local prev = state.cond_prev
    local what = nil
    if state.cfg.cond_trapped and c.trapped == true and prev.trapped ~= true then
        what = "monster trapped"
    elseif state.cfg.cond_stunned and c.stunned == true and prev.stunned ~= true then
        what = "monster stunned"
    elseif state.cfg.cond_paralyzed and c.paralyzed == true and prev.paralyzed ~= true then
        what = "monster paralyzed"
    end
    state.cond_prev = { trapped = c.trapped, stunned = c.stunned, paralyzed = c.paralyzed }
    return what
end

-- The horn's shipping cooldown is 8 minutes. Do NOT read _CoolTime from the
-- tool params: that is user data, so Otomo Tools rewrites it (to 30 s in our
-- tests) and this would report the edit back instead of the game default.
local BASE_GAME_COOLDOWN = 480

local function read_base_cooldown()
    return BASE_GAME_COOLDOWN
end

-- ------------------------------------------------------------------ buff ----

local function resolve_condition()
    local om = safe(sdk.get_managed_singleton, "app.OtomoManager")
    if om == nil then return nil end
    local ctl = getter(om, "getMasterOtomoManagedControl")
    if ctl == nil then return nil end
    local info = field_value(ctl, "_OtomoManagedInfo") or getter(ctl, "get_OtomoManagedInfo")
    if info == nil then return nil end
    local char = field_value(info, "<Character>k__BackingField")
    if char == nil then return nil end
    local stock = field_value(char, "_StockDamage")
    if stock == nil then return nil end
    local cond = field_value(stock, "_Condition")
    if cond == nil then return nil end
    if method0(cond, "isActiveAttackUp") == nil then return nil end
    return cond
end

local function read_buff()
    if state.condition == nil then state.condition = resolve_condition() end
    if state.condition == nil then state.buff = nil return nil end
    local m = method0(state.condition, "isActiveAttackUp")
    if m == nil then state.condition = nil state.buff = nil return nil end
    local v = safe(function() return m:call(state.condition) end)
    if type(v) ~= "boolean" then
        state.condition = nil
        state.buff = nil
        return nil
    end
    state.buff = v
    return v
end

-- ------------------------------------------------------------------ hook ----

-- Method:get_full_name() returns nil on this build, so the signature comes from
-- get_param_types(). Everything here must tolerate both.
local function param_type_names(m)
    local out = {}
    local types = safe(function() return m:get_param_types() end)
    if types ~= nil then
        for _, t in ipairs(types) do
            out[#out + 1] = tostring(safe(function() return t:get_full_name() end))
        end
    end
    return out
end

local function describe(m)
    local full = safe(function() return m:get_full_name() end)
    if full ~= nil then return tostring(full) end
    local names = param_type_names(m)
    return tostring(safe(function() return m:get_num_params() end))
        .. "(" .. table.concat(names, ", ") .. ")"
end

local function first_param_is_int(m)
    local names = param_type_names(m)
    if #names > 0 then return names[1] == "System.Int32" end
    local full = safe(function() return m:get_full_name() end)
    if type(full) == "string" then
        return full:find("System.Int32", 1, true) ~= nil
    end
    return false
end

local function collect(td, name, out, depth)
    for _, m in ipairs(safe(function() return td:get_methods() end) or {}) do
        if safe(function() return m:get_name() end) == name then
            out[#out + 1] = m
        end
    end
    local parent = safe(function() return td:get_parent_type() end)
    if parent ~= nil and depth < 4 then collect(parent, name, out, depth + 1) end
end

local function install()
    if state.hook_note ~= "not tried" then return end
    local td = safe(sdk.find_type_definition, ACTION_TYPE)
    if td == nil then
        state.hook_note = ACTION_TYPE .. " not found"
        return
    end

    local list = {}
    collect(td, METHOD_NAME, list, 0)

    local hooked = 0
    for _, m in ipairs(list) do
        if safe(function() return m:get_num_params() end) == 2 then
            local ok = pcall(function()
                sdk.hook(m,
                    function(args)
                        if args == nil or args[2] == nil then return end
                        state.self = args[2]
                        state.append = safe(function() return sdk.to_int64(args[4]) end)
                        state.captured_at = state.frames
                        state.captures = state.captures + 1
                    end,
                    function(retval) return retval end)
            end)
            if ok then
                hooked = hooked + 1
                if state.method == nil and first_param_is_int(m) then
                    state.method = m
                    state.method_desc = describe(m)
                end
            end
        end
    end

    if state.method == nil then
        state.hook_note = "no System.Int32 overload; refusing to fire"
    else
        state.hook_note = "hooked " .. hooked
    end
    trace("install: " .. tostring(state.hook_note) .. " call=" .. tostring(state.method_desc))
end

-- ----------------------------------------------------------------- input ----

local function build_key_list()
    local enum = imgui.ImGuiKey
    if type(enum) ~= "table" then
        state.key_list = nil
        return
    end
    local list = {}
    for k, v in pairs(enum) do
        if type(k) == "string" and type(v) == "number" then
            list[#list + 1] = { name = k, value = v }
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    state.key_list = list
end

-- ImGui does not expose a key enum on this build (the table is empty), so the
-- common values are labelled here for display only.
local KEY_LABELS = {
    -- Confirmed on this build: "." reports as 599 (not 587 as in stock ImGui),
    -- so only values actually seen in game are labelled here.
    [599] = ".",
}

local function key_label(v)
    if type(v) ~= "number" then return nil end
    if v >= 546 and v <= 571 then return string.char(65 + (v - 546)) end
    if v >= 536 and v <= 545 then return tostring(v - 536) end
    return KEY_LABELS[v]
end

local function resolve_key()
    -- must be cleared first: the old value is sticky otherwise, so a rebind
    -- changed the config string while the mod kept listening on the old key
    state.key = nil
    state.key_index = nil

    local spec = tostring(state.cfg.hotkey)
    local enum = imgui.ImGuiKey
    if enum ~= nil then
        for _, name in ipairs({ spec, "ImGuiKey_" .. spec, string.upper(spec) }) do
            local v = enum[name]
            if v ~= nil then state.key = v break end
        end
    end
    if state.key == nil then
        local n = tonumber(spec)
        if n ~= nil then state.key = n end
    end
    if state.key ~= nil and imgui.get_key_index ~= nil then
        state.key_index = safe(imgui.get_key_index, state.key)
    end
    if state.key == nil then
        state.key_note = "unknown key '" .. spec .. "'"
    else
        local label = key_label(state.key)
        state.key_note = (label ~= nil and (label .. " ") or "") .. "(" .. tostring(state.key) .. ")"
    end
    trace("key: " .. state.key_note)
end

local function pressed(v)
    if v == nil or imgui.is_key_pressed == nil then return false end
    local ok, r = pcall(imgui.is_key_pressed, v)
    return ok and r == true
end

local function key_pressed()
    return pressed(state.key) or pressed(state.key_index)
end

-- ------------------------------------------------------------------ fire ----

local function ready_reason()
    if not state.cfg.enabled then return "disabled" end
    if state.method == nil then return "no action method" end
    if state.self == nil then return "wait for the Palico to act once" end
    local self = safe(sdk.to_managed_object, state.self)
    if self == nil then return "stale object" end
    local tn = safe(function() return self:get_type_definition():get_full_name() end)
    if type(tn) ~= "string" or not tn:find("OtomoCharacter", 1, true) then
        return "object is " .. tostring(tn)
    end
    return nil
end

local function cooldown_seconds()
    if state.cfg.use_base_cooldown then
        return state.base_cooldown or 600
    end
    return state.cfg.global_cooldown_sec or 0
end

local function cooldown_left()
    if state.last_fire_time == nil then return 0 end
    local left = cooldown_seconds() - (os.time() - state.last_fire_time)
    if left < 0 then return 0 end
    return left
end

local function fire(reason)
    local why = ready_reason()
    if why ~= nil then
        state.last_result = "skipped: " .. why
        return false
    end

    local min_frames = (state.cfg.min_interval_sec or 0.5) * 60
    if state.fires > 0 and (state.frames - state.last_fire_frame) < min_frames then
        state.last_result = "debounced"
        return false
    end

    local self = safe(sdk.to_managed_object, state.self)
    local ok, ret = pcall(function()
        return state.method:call(self, HORN_ACTION, state.append)
    end)

    state.fires = state.fires + 1
    state.last_fire_frame = state.frames
    state.last_fire_time = os.time()
    state.last_result = ok and ("fired (" .. tostring(reason) .. ")")
        or ("error: " .. tostring(ret))
    trace("fire #" .. state.fires .. " " .. tostring(reason) .. " -> " .. tostring(state.last_result))
    return ok
end

-- ------------------------------------------------------------------ dump ----

local function dump_obj(label, obj)
    if obj == nil then return nil end
    local td = safe(function() return obj:get_type_definition() end)
    if td == nil then return nil end
    local rec = {
        label = label,
        type = safe(function() return td:get_full_name() end),
        methods = {},
        fields = {},
    }
    for _, m in ipairs(safe(function() return td:get_methods() end) or {}) do
        local n = safe(function() return m:get_name() end)
        if n ~= nil then rec.methods[#rec.methods + 1] = n end
    end
    for _, f in ipairs(safe(function() return td:get_fields() end) or {}) do
        local n = safe(function() return f:get_name() end)
        if n ~= nil then
            local ft = safe(function() return f:get_type() end)
            local tn = ft ~= nil and safe(function() return ft:get_full_name() end) or nil
            rec.fields[#rec.fields + 1] = n .. " : " .. tostring(tn)
        end
    end
    table.sort(rec.methods)
    table.sort(rec.fields)
    return rec
end

-- Enum member name -> value, for the AI/condition state enums.
local function enum_members(typeName)
    local td = safe(sdk.find_type_definition, typeName)
    if td == nil then return nil end
    local out = {}
    for _, f in ipairs(safe(function() return td:get_fields() end) or {}) do
        if safe(function() return f:is_static() end) then
            local n = safe(function() return f:get_name() end)
            local v = safe(function() return f:get_data(nil) end)
            if n ~= nil and type(v) == "number" then
                out[#out + 1] = { name = n, value = v }
            end
        end
    end
    table.sort(out, function(a, b) return a.value < b.value end)
    return out
end

-- Read-only: records the real type, method and field names so the status-flag
-- candidates can be corrected from data instead of guessed.
local function dump_monster()
    local out = { at = os.time(), status_type = state.status_type, objects = {} }
    for _, e in ipairs({
        { "ctx", state.boss_ctx }, { "em", state.boss_em },
        { "basic", state.boss_basic }, { "chara", state.boss_chara },
        { "status", state.boss_status },
    }) do
        local rec = dump_obj(e[1], e[2])
        if rec ~= nil then out.objects[#out.objects + 1] = rec end
    end
    for _, m in ipairs(state.boss_modules or {}) do
        local rec = dump_obj("module:" .. tostring(m[1]), m[2])
        if rec ~= nil then out.objects[#out.objects + 1] = rec end
    end

    if state.boss_chara ~= nil then
        local td = safe(function() return state.boss_chara:get_type_definition() end)
        local kids = {}
        for _, f in ipairs(safe(function() return td:get_fields() end) or {}) do
            local n = safe(function() return f:get_name() end)
            local v = safe(function() return f:get_data(state.boss_chara) end)
            if n ~= nil and v ~= nil
                and safe(function() return sdk.is_managed_object(v) end) == true then
                local kt = safe(function() return v:get_type_definition():get_full_name() end)
                kids[#kids + 1] = { name = n, type = tostring(kt) }
            end
        end
        out.chara_children = kids
    end

    -- condition objects: their own type and members tell us if they carry an
    -- "active" flag we can read
    local conditions = nil
    for _, m in ipairs(state.boss_modules or {}) do
        if m[1] == "conditions" then conditions = m[2] end
    end
    if conditions ~= nil then
        out.condition_objects = {}
        for _, name in ipairs({ "Capture", "FieldPitfall", "Flash", "Blast",
                                "Tired", "Koyasi", "SandDig" }) do
            local rec = dump_obj("condition:" .. name, access(conditions, name))
            if rec ~= nil then out.condition_objects[#out.condition_objects + 1] = rec end
        end
    end

    -- the AI state/interrupt enums are the likely home of paralysis and stun
    out.enums = {}
    for _, tn in ipairs({
        "app.EnemyDef.AI_STATE_ID",
        "app.EnemyDef.AI_INTERRUPT_ID",
        "app.EnemyDef.CONDITION",
        "app.EnemyDef.EXTRA_STATE",
        "app.CharacterDef.STAND_STATE",
    }) do
        local members = enum_members(tn)
        if members ~= nil then
            out.enums[#out.enums + 1] = { type = tn, members = members }
        end
    end

    -- live values at dump time
    local ai = nil
    for _, m in ipairs(state.boss_modules or {}) do
        if m[1] == "aistate" then ai = m[2] end
    end
    out.current = {
        extra_state = state.boss_em and tostring(access(state.boss_em, "ExtraState")) or nil,
        stand_state = state.boss_em and tostring(access(state.boss_em, "StandState")) or nil,
        down_direction = state.boss_em and tostring(access(state.boss_em, "DownDirection")) or nil,
        ai_state = ai and tostring(access(ai, "CurrentAIStateID")) or nil,
        ai_interrupt = ai and tostring(access(ai, "CurrentAIInterruptID")) or nil,
        is_capture = ai and tostring(access(ai, "IsCapture")) or nil,
        is_flash = ai and tostring(access(ai, "IsFlash")) or nil,
        is_damage = ai and tostring(access(ai, "IsDamage")) or nil,
    }

    pcall(json.dump_file, "monster_flags.json", out)
    trace("monster dump written")
end

-- ----------------------------------------------------------------- frame ----

re.on_frame(function()
    local ok, err = pcall(function()
        install()
        state.frames = state.frames + 1

        if state.frames % 15 == 0 then read_buff() end
        if state.frames % 30 == 0 then monster_scan() end
        if state.frames % 300 == 0 then state.base_cooldown = read_base_cooldown() end

        local bind_blocked = state.scan ~= nil
            or (state.bind_block_until ~= nil and state.frames <= state.bind_block_until)
        if state.pending_fire == nil and not bind_blocked and key_pressed() then
            state.pending_fire = "hotkey"
            state.pending_kind = "event"
        end

        -- event trigger: first damage to the monster
        if state.cfg.fire_on_first_hit and state.pending_fire == nil then
            if state.monster_state == false then
                state.first_hit_done = false     -- full hp again: new hunt/monster
            elseif state.monster_state == true and state.first_hit_done == false then
                state.pending_fire = "first hit"
                state.pending_kind = "event"
            end
        end

        -- conditional: trapped / stunned / paralyzed, rising edge only
        if state.pending_fire == nil then
            local what = cond_trigger()
            if what ~= nil then
                state.pending_fire = what
                state.pending_kind = "event"
            end
        end

        if state.dump_requested then
            state.dump_requested = false
            dump_monster()
        end

        -- keep-alive: buff down, gated by the global cooldown
        if state.cfg.auto_when_down and state.buff == false
            and state.pending_fire == nil and cooldown_left() == 0 then
            local since = state.last_fire_frame == 0 and 999999
                or (state.frames - state.last_fire_frame)
            if since > 600 then
                state.pending_fire = "buff down"
                state.pending_kind = "auto"
            end
        end

        if state.pending_fire ~= nil then
            local reason = state.pending_fire
            state.pending_fire = nil
            state.pending_kind = nil
            trace("request: " .. tostring(reason))
            -- only latch the first-hit trigger once a fire actually happened,
            -- otherwise "wait for the Palico to act once" consumes it forever
            if fire(reason) and reason == "first hit" then
                state.first_hit_done = true
            end
        end

        if state.frames % 300 == 0 then
            local buffv = state.buff == true and "UP"
                or (state.buff == false and "down" or "?")
            local monv = state.monster_state == true and "damaged"
                or (state.monster_state == false and "full" or "?")
            trace(string.format(
                "status: %s | captures=%d buff=%s monster=%s fires=%d last=%s",
                tostring(state.hook_note), state.captures, buffv, monv,
                state.fires, tostring(state.last_result)))
        end
    end)
    if not ok then log.info(TAG .. " frame error: " .. tostring(err)) end
end)

-- -------------------------------------------------------------------- ui ----

local function buff_text()
    if state.buff == true then return "UP" end
    if state.buff == false then return "down" end
    return "unknown"
end

local function monster_text()
    if state.monster_state == true then return "damaged" end
    if state.monster_state == false then return "full HP" end
    return "unknown"
end

local function draw_body()
    local changed

    imgui.text("Plays the Attack-Up horn on command (action layer).")
    imgui.text("The tool cooldown and the AI's desire are not involved.")
    imgui.separator()

    imgui.text("hook:    " .. tostring(state.hook_note))
    imgui.text("hotkey:  " .. tostring(state.key_note))
    if state.scan ~= nil then
        imgui.text("  scanning... press the key now")
    elseif state.binding then
        imgui.text("  press a key to bind it (Escape cancels)")
    else
        if not (state.key_list ~= nil and #state.key_list > 0) then
            if imgui.button("Find my key (press it after clicking)") then
                state.scan = { started = state.frames or 0 }
                trace("scan started")
            end

        else
            if imgui.button("Bind hotkey") then
                state.binding = true
            end
        end
    end
    imgui.text("buff:    " .. buff_text())
    imgui.text("monster: " .. monster_text() .. "   " .. tostring(state.monster_note))
    if state.captured_at ~= nil then
        imgui.text(string.format("captured: %d calls, last %d frames ago",
            state.captures, state.frames - state.captured_at))
    else
        imgui.text("captured: none yet (the Palico must act once)")
    end
    imgui.text("fires:   " .. tostring(state.fires) .. "   last: " .. tostring(state.last_result))

    imgui.separator()
    changed, state.cfg.enabled = imgui.checkbox("Enabled", state.cfg.enabled)
    if changed then save_config() end

    if imgui.button("Fire horn now") then
        state.pending_fire = "button"
        state.pending_kind = "event"
    end

    imgui.separator()
    imgui.text("Automation")
    changed, state.cfg.fire_on_first_hit =
        imgui.checkbox("Fire on the first hit to the monster", state.cfg.fire_on_first_hit)
    if changed then save_config() end

    changed, state.cfg.cond_trapped =
        imgui.checkbox("Fire when the monster is trapped", state.cfg.cond_trapped)
    if changed then save_config() end
    changed, state.cfg.cond_stunned =
        imgui.checkbox("Fire when the monster is stunned", state.cfg.cond_stunned)
    if changed then save_config() end
    changed, state.cfg.cond_paralyzed =
        imgui.checkbox("Fire when the monster is paralyzed", state.cfg.cond_paralyzed)
    if changed then save_config() end

    local function tri(v)
        if v == true then return "yes" end
        if v == false then return "no" end
        return "?"
    end
    imgui.text("  flags: trap=" .. tri(state.cond.trapped)
        .. " stun=" .. tri(state.cond.stunned)
        .. " para=" .. tri(state.cond.paralyzed))
    imgui.text("  status: " .. tostring(state.status_type or "not found"))
    if imgui.button("Dump monster structure") then
        state.dump_requested = true
    end

    changed, state.cfg.auto_when_down =
        imgui.checkbox("Fire when the buff is down", state.cfg.auto_when_down)
    if changed then save_config() end

    changed, state.cfg.use_base_cooldown =
        imgui.checkbox("Use the base game cooldown", state.cfg.use_base_cooldown)
    if changed then save_config() end
    if state.cfg.use_base_cooldown then
        imgui.text(string.format("  game cooldown: %d s (8 min)",
            state.base_cooldown or BASE_GAME_COOLDOWN))
    else
        local cd = state.cfg.global_cooldown_sec or 0
        changed, cd = imgui.drag_int("  cooldown (s)", cd, 10, 0, 1800)
        if changed then
            state.cfg.global_cooldown_sec = cd
            save_config()
        end
    end
    local left = cooldown_left()
    imgui.text(left > 0 and string.format("  next automatic fire in %d s", left)
        or "  automatic fire ready")

    imgui.separator()
    imgui.text("config: " .. CONFIG_FILE)
end

-- imgui.ImGuiKey is empty on this build, so names cannot be bound. Values are
-- scanned numerically, but only up to 600: ImGui's named-key table ends around
-- 616 and reading past it returns garbage (a scan up to 700 "found" 691, which
-- is not a key at all). A press must also be stable for two frames.
local SCAN_MIN = 512          -- below this are mouse buttons and legacy keys
local SCAN_MAX = 600

local function try_scan()
    if state.scan == nil then return false end

    if (state.frames or 0) - state.scan.started > 600 then
        state.scan = nil
        trace("scan cancelled (10 s timeout)")
        return false
    end

    local downs = {}
    for v = SCAN_MIN, SCAN_MAX do
        local ok, down = pcall(imgui.is_key_down, v)
        if ok and down == true then downs[#downs + 1] = v end
    end

    if #downs == 0 then
        state.scan.candidate = nil
        return false
    end

    -- highest value wins: modifiers sit lower than letters and function keys
    local v = downs[#downs]
    if state.scan.candidate == v then
        state.scan.stable = (state.scan.stable or 0) + 1
    else
        state.scan.candidate = v
        state.scan.stable = 1
    end

    if state.scan.stable >= 2 then
        state.cfg.hotkey = tostring(v)
        state.scan = nil
        state.bind_block_until = (state.frames or 0) + 30
        resolve_key()
        save_config()
        trace("scan bound raw key " .. tostring(v))
        return true
    end
    return false
end

-- While binding, any key press becomes the hotkey. This sidesteps both the
-- enum-naming problem and the fact that every function key is already bound
-- to something in the game.
local function try_bind()
    if not state.binding then return false end
    if state.key_list == nil then return false end
    for _, k in ipairs(state.key_list) do
        local hit = pressed(k.value)
        if not hit and imgui.get_key_index ~= nil then
            local idx = safe(imgui.get_key_index, k.value)
            hit = pressed(idx)
        end
        if hit then
            if k.name == "Escape" then
                state.binding = false
                trace("bind cancelled")
                return true
            end
            state.cfg.hotkey = k.name
            state.binding = false
            state.bind_block_until = (state.frames or 0) + 30
            resolve_key()
            save_config()
            trace("bound key " .. k.name)
            return true
        end
    end
    return false
end

re.on_draw_ui(function()
    local consumed = try_scan() or try_bind()
    local okk, pressed_now = false, false
    if not consumed then
        okk, pressed_now = pcall(key_pressed)
    end
    local blocked = state.scan ~= nil
        or (state.bind_block_until ~= nil and state.frames <= state.bind_block_until)
    if okk and pressed_now and not blocked
        and not state.binding and state.pending_fire == nil then
        state.pending_fire = "hotkey"
        state.pending_kind = "event"
    end

    if not imgui.tree_node("Otomo Horn v" .. VERSION) then return end
    local ok, err = pcall(draw_body)
    safe(function() imgui.tree_pop() end)
    if not ok then log.info(TAG .. " draw error: " .. tostring(err)) end
end)

load_config()
build_key_list()
resolve_key()
state.base_cooldown = read_base_cooldown()
trace("base cooldown: " .. tostring(state.base_cooldown))

do
    local enum = imgui.ImGuiKey
    if enum == nil then
        trace("ImGuiKey: absent")
    else
        local names = {}
        for k, v in pairs(enum) do
            if type(k) == "string" then names[#names + 1] = k .. "=" .. tostring(v) end
        end
        table.sort(names)
        trace("ImGuiKey: " .. table.concat(names, " "))
    end
end

trace("loaded v" .. VERSION)
log.info(TAG .. " loaded v" .. VERSION .. " (" .. tostring(state.key_note) .. ")")
