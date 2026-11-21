--[[
  useful_palico_horn.lua - fire the Palico's Attack-Up horn on command.

  Sibling of otomo_tools.lua (cooldowns + counter). This one is the timing
  tool: it plays the horn when you decide, so the buff lands where it matters
  instead of whenever the AI feels like it.

  Mechanism (from Nexus 627 PalicoMod.dll, verified in game): replay the
  Palico's own action request with the horn's action id.

      hook app.OtomoCharacter:setActionRequest   -- read-only, captures `this`
      fire: setActionRequest(this, 0x85, appendKind)   -- 0x85 = cUseHorn

  The tool's desire gate, cooldown and ~4 min refractory are not involved: this
  is the action layer. Verified repeating, and after the buff expires.

  A fire only costs the cooldown once the buff is seen: the request can be
  cancelled by a roar or dropped before the quest has loaded, so a fire that
  never lands is refunded and its event trigger tries again a few seconds later.

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

local VERSION = "1.6.1"
local TAG = "[UsefulPalicoHorn] "

local CONFIG_FILE = "useful_palico_horn.json"
local TRACE_FILE = "useful_palico_horn_trace.json"
local HORN_ACTION = 0x85
local ACTION_TYPE = "app.OtomoCharacter"
local METHOD_NAME = "setActionRequest"

-- A request is not a buff. A roar cancels the horn animation, and a request
-- sent before the quest has loaded is dropped, so the cooldown is only spent
-- once the buff has been seen and stayed up for a moment.
local VERIFY_TIMEOUT = 480     -- ~8 s to see the buff at all
local VERIFY_HOLD = 120        -- ~2 s of it staying up
local RETRY_FRAMES = 300       -- ~5 s before a cancelled trigger tries again
local MAX_ATTEMPTS = 2         -- one fire plus one retry, then give up

local state = {
    cfg = {
        enabled = true,
        hotkey = "599",          -- "." on this build: unused by the game
        min_interval_sec = 0.5,
        auto_when_down = false,
        block_ai_use = true,
        use_base_cooldown = true,
        global_cooldown_sec = 480,
        fire_on_first_hit = false,
        fire_on_quest_start = false,
        cond_trapped = false,
        cond_stunned = false,
        cond_paralyzed = false,
    },

    frames = 0,
    hook_note = "not tried",
    tool_hook = "not tried",
    tool_manager = nil,
    tool_values = nil,
    tool_self = nil,
    desire_self = nil,
    tool_fields = nil,
    tool_dumped = false,
    tool_type = nil,
    action_hook = "not tried",
    action_self = nil,
    action_dumped = false,
    method = nil,
    method_desc = nil,

    self = nil,
    append = nil,
    captured_at = nil,
    captures = 0,

    buff = nil,
    buff_sig = nil,
    hunter_type = nil,
    skill_missing = false,
    buff_objs = nil,
    buff_checked = nil,
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
    cond_logged = false,
    cond_sig = nil,
    scan = nil,              -- { started = frame } while binding a hotkey
    was_playing = nil,
    playing = nil,
    errors = 0,
    draw_errors = 0,
    quest_start_pending = false,
    quest_start_at = nil,
    diag_sig = nil,
    blocked = 0,
    last_req_reason = nil,
    last_req_frame = nil,
    reason_last = {},        -- per-trigger debounce
    dump_requested = false,
    dump_buff_requested = false,
    dump_at = nil,
    dump_seq = 0,
    monster_state = nil,     -- true = damaged, false = full hp, nil = unknown
    monster_hp = nil,
    monster_max = nil,
    monster_note = "-",
    first_hit_done = false,
    chain_logged = false,

    fires = 0,
    confirmed = 0,
    verify = nil,            -- { reason, at, seen } while a fire is unproven
    retry_at = 0,
    tries = { first_hit = 0, quest_start = 0 },
    last_result = "-",
    last_fire_frame = 0,
    last_fire_time = nil,
    pending_fire = nil,
    pending_kind = nil,      -- "event" or "auto"

    key = nil,
    key_index = nil,
    key_note = "-",
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

local LEGACY_CONFIG = "otomo_horn.json"

local function load_config()
    local raw = safe(json.load_file, CONFIG_FILE)
    if type(raw) ~= "table" then raw = safe(json.load_file, LEGACY_CONFIG) end
    if type(raw) ~= "table" then return end
    local c = state.cfg
    if raw.enabled ~= nil then c.enabled = raw.enabled == true end
    if type(raw.hotkey) == "string" then c.hotkey = raw.hotkey end
    if type(raw.min_interval_sec) == "number" then
        c.min_interval_sec = math.max(0, math.min(10, raw.min_interval_sec))
    end
    if raw.auto_when_down ~= nil then c.auto_when_down = raw.auto_when_down == true end
    if raw.block_ai_use ~= nil then c.block_ai_use = raw.block_ai_use == true end
    if raw.use_base_cooldown ~= nil then
        c.use_base_cooldown = raw.use_base_cooldown == true
    end
    if type(raw.global_cooldown_sec) == "number" then
        c.global_cooldown_sec = math.max(0, math.min(3600, raw.global_cooldown_sec))
    end
    if raw.fire_on_first_hit ~= nil then
        c.fire_on_first_hit = raw.fire_on_first_hit == true
    end
    if raw.fire_on_quest_start ~= nil then
        c.fire_on_quest_start = raw.fire_on_quest_start == true
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
-- app.EnemyDef.CONDITION, read from the live type in game.
local COND_IDS = {
    paralyzed = { 5, 6 },          -- PARALYSE, PARALYSE_EM
    stunned   = { 15, 16 },        -- STUN, STUN_EM
    trapped   = { 31, 39, 40, 41, 42, 43 },  -- FIELD_PITFALL, TRAP_FALL,
                                             -- TRAP_PARALYSE, TRAP_IVY, ...
}

-- cEmModuleConditions:isActive(CONDITION) -> Boolean. nil means the method was
-- not found, which is different from "not active".
local function condition_method_bool(cond, methodName, value)
    if cond == nil then return nil end
    local td = safe(function() return cond:get_type_definition() end)
    if td == nil then return nil end
    for _, m in ipairs(safe(function() return td:get_methods() end) or {}) do
        if safe(function() return m:get_name() end) == methodName
            and safe(function() return m:get_num_params() end) == 1 then
            local ok, v = pcall(function() return m:call(cond, value) end)
            if ok and type(v) == "boolean" then return v end
            return nil
        end
    end
    return nil
end

local function condition_active(cond, value)
    local a = condition_method_bool(cond, "isActive", value)
    if a == true then return true end
    local b = condition_method_bool(cond, "isActualActive", value)
    if b == true then return true end
    if a ~= nil or b ~= nil then return false end
    return nil
end

-- getTrapCondition() covers traps that are not a single CONDITION id.
local function trap_condition(cond)
    if cond == nil then return nil end
    local m = method0(cond, "getTrapCondition")
    if m == nil then return nil end
    local v = safe(function() return m:call(cond) end)
    if type(v) == "boolean" then return v end
    if type(v) == "number" then return v >= 0 end
    return nil
end

local function any_condition(cond, ids)
    local known = false
    for _, id in ipairs(ids) do
        local v = condition_active(cond, id)
        if v ~= nil then known = true end
        if v == true then return true end
    end
    if not known then return nil end
    return false
end

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
    -- the real one is em.Conditions (app.cEmModuleConditions); the singular
    -- names are kept only as a fallback
    return access(em, "Conditions") or access(chara, "Conditions")
        or access(ctx, "Conditions")
        or access(chara, "StatusManager") or access(em, "StatusManager")
        or access(ctx, "StatusManager")
        or access(chara, "Condition") or access(em, "Condition")
        or access(ctx, "Condition")
end

-- ---------------------------------------------------------------- quest ----

local function quest_playing()
    local mm = safe(sdk.get_managed_singleton, "app.MissionManager")
    if mm == nil then return nil end
    local v = getter(mm, "get_IsPlayingQuest")
    if type(v) == "boolean" then return v end
    return nil
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

-- The condition array is the last unknown: is a condition a boolean, a timer,
-- an object? Record the elements' types and their numeric/boolean fields so the
-- encoding can be read instead of guessed.
local function dump_conditions(cond, reason)
    if cond == nil then return end
    local td = safe(function() return cond:get_type_definition() end)
    local out = {
        at = os.time(),
        reason = reason,
        module = td and safe(function() return td:get_full_name() end) or nil,
        elements = {},
    }

    local arr = field_value(cond, "_Conditions") or field_value(cond, "_ValidContions_BadCond")
    local n = arr and array_len(arr) or 0
    for i = 0, math.min(n - 1, 60) do
        local el = safe(function() return arr[i] end)
        if el ~= nil then
            local etd = safe(function() return el:get_type_definition() end)
            local rec = {
                index = i,
                type = etd and safe(function() return etd:get_full_name() end) or nil,
                values = {},
            }
            local walk, depth = etd, 0
            while walk ~= nil and depth < 4 do
                for _, f in ipairs(safe(function() return walk:get_fields() end) or {}) do
                    local fn = safe(function() return f:get_name() end)
                    local fv = safe(function() return f:get_data(el) end)
                    if fn ~= nil and (type(fv) == "number" or type(fv) == "boolean")
                        and rec.values[fn] == nil then
                        rec.values[fn] = fv
                    end
                end
                walk = safe(function() return walk:get_parent_type() end)
                depth = depth + 1
            end
            out.elements[#out.elements + 1] = rec
        end
    end

    pcall(json.dump_file, "useful_palico_horn_conditions.json", out)
    trace("conditions dump (" .. tostring(reason) .. ") " .. #out.elements .. " elements")
end

local function bad_condition_type(cond)
    if cond == nil then return nil end
    local m = method0(cond, "getBadCondition")
    if m == nil then return nil end
    local obj = safe(function() return m:call(cond) end)
    if obj == nil then return nil end
    local t = as_number(field_value(obj, "_ConditionType"))
    if t ~= nil then return t end
    local td = safe(function() return obj:get_type_definition() end)
    return td and safe(function() return td:get_full_name() end) or nil
end

local function cond_signature(cond)
    if cond == nil then return "nil" end
    local parts = {}
    for _, id in ipairs({ 5, 6, 15, 16, 31, 40 }) do
        local a = condition_method_bool(cond, "isActive", id)
        local b = condition_method_bool(cond, "isActualActive", id)
        parts[#parts + 1] = tostring(id) .. "=" .. tostring(a) .. "/" .. tostring(b)
    end
    parts[#parts + 1] = "bad=" .. tostring(bad_condition_type(cond))

    -- counters straight off the array elements: if isActive lies, these still
    -- change and force a dump
    local arr = field_value(cond, "_Conditions")
    if arr ~= nil then
        for _, id in ipairs({ 15, 16 }) do
            local el = safe(function() return arr[id] end)
            local count = el and as_number(field_value(el, "_Count"))
            local sec = el and as_number(field_value(el, "_ActiveSec"))
            local acc = el and as_number(field_value(el, "_Accumulation"))
            parts[#parts + 1] = string.format("stun%d=%s/%s/%s",
                id, tostring(count), tostring(sec), tostring(acc))
        end
    end

    return table.concat(parts, " ")
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
                if boss == true then
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
        local conditions = nil
        for _, m in ipairs(state.boss_modules) do
            if m[1] == "conditions" then conditions = m[2] end
        end

        -- preferred: ask the condition module directly
        local para = any_condition(conditions, COND_IDS.paralyzed)
        local stun = any_condition(conditions, COND_IDS.stunned)
        local trap = any_condition(conditions, COND_IDS.trapped)

        -- fallback: the old name-based guesses
        local objs = { sm }
        for _, m in ipairs(state.boss_modules) do
            if m[2] ~= nil then objs[#objs + 1] = m[2] end
        end
        objs[#objs + 1] = state.boss_chara
        objs[#objs + 1] = state.boss_em
        objs[#objs + 1] = state.boss_ctx

        if para ~= nil then state.cond.paralyzed = para
        else state.cond.paralyzed = read_flag(objs, COND_CANDIDATES.paralyzed) end
        if stun ~= nil then state.cond.stunned = stun
        else state.cond.stunned = read_flag(objs, COND_CANDIDATES.stunned) end
        if trap ~= nil then
            state.cond.trapped = trap
        else
            local by_trap_cond = trap_condition(conditions)
            if by_trap_cond ~= nil then state.cond.trapped = by_trap_cond
            else state.cond.trapped = read_flag(objs, COND_CANDIDATES.trapped) end
        end

        local sig = cond_signature(conditions)
        if state.cond_sig == nil then
            state.cond_sig = sig
            if not state.cond_logged then
                state.cond_logged = true
                dump_conditions(conditions, "baseline")
            end
        elseif state.cond_sig ~= sig then
            state.cond_sig = sig
            trace("cond change: " .. sig)
            dump_conditions(conditions, "change")
        end

        if not state.cond_logged then
            state.cond_logged = true
            trace("conditions: type=" .. tostring(state.status_type)
                .. " isActive=" .. tostring(any_condition(conditions, { 5 }) ~= nil)
                .. " para=" .. tostring(state.cond.paralyzed)
                .. " stun=" .. tostring(state.cond.stunned)
                .. " trap=" .. tostring(state.cond.trapped)
                .. " trapCond=" .. tostring(trap_condition(conditions)))
        end
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
local BASE_GAME_COOLDOWN = 600

local function read_base_cooldown()
    return BASE_GAME_COOLDOWN
end

-- ------------------------------------------------------------------ buff ----

-- The buff is not on the first condition manager found: walking the object graph
-- turned up six candidates in earlier testing, and `_StockDamage._Condition`
-- reports false forever (verified: all four flags stayed false through a horn
-- use). So collect every object that exposes isActiveAttackUp near the Palico
-- and the hunter, and treat the buff as up if any of them says so.

local function children_of(obj)
    local out = {}
    local n = array_len(obj)
    if n ~= nil and n > 0 then
        for i = 0, math.min(n - 1, 32) do
            local v = safe(function() return obj[i] end)
            if v ~= nil then out[#out + 1] = v end
        end
        return out
    end
    local td = safe(function() return obj:get_type_definition() end)
    local depth = 0
    while td ~= nil and depth < 5 do
        for _, f in ipairs(safe(function() return td:get_fields() end) or {}) do
            if safe(function() return f:is_static() end) ~= true then
                local v = safe(function() return f:get_data(obj) end)
                if v ~= nil then out[#out + 1] = v end
            end
        end
        td = safe(function() return td:get_parent_type() end)
        depth = depth + 1
    end
    return out
end

local function local_hunter()
    local pm = safe(sdk.get_managed_singleton, "app.PlayerManager")
    if pm == nil then return nil end
    local list = field_value(pm, "_InstancedPlayerList")
    if list ~= nil then
        local n = array_len(list)
        if n ~= nil and n > 0 then
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

-- The character found through getMasterPlayer() can be a wrapper whose real
-- character is elsewhere, and its get_HunterStatus returns nil. Other mods in
-- this folder resolve the local player through _InstancedPlayerList and check
-- IsUserControl on the status instead; that path is proven on this build.
local function character_from(inst)
    local pi = getter(inst, "get_PlayerInfo") or inst
    for _, name in ipairs({ "get_Character", "get_Hunter", "get_Player" }) do
        local v = getter(pi, name)
        if v ~= nil then return v end
    end
    return field_value(inst, "<Character>k__BackingField")
        or field_value(inst, "_Character")
end

local function user_character()
    local pm = safe(sdk.get_managed_singleton, "app.PlayerManager")
    if pm == nil then return nil end
    local list = field_value(pm, "_InstancedPlayerList")
    if list == nil then return nil end
    local arr = field_value(list, "_Array") or field_value(list, "_Items") or list
    for i = 0, 7 do
        local inst = safe(function() return arr[i] end)
        if inst == nil then break end
        local ch = character_from(inst)
        if ch ~= nil then
            local st = getter(ch, "get_HunterStatus")
            if st ~= nil
                and getter(st, "get_IsUserControl") == true
                and getter(st, "get_IsNpc") ~= true then
                return ch
            end
        end
    end
    return nil
end

local function local_hunter_character()
    local ch = user_character()
    if ch ~= nil then return ch end
    local info = local_hunter()
    if info == nil then return nil end
    if method0(info, "get_HunterSkill") ~= nil then return info end
    local character = getter(info, "get_Character")
    if character ~= nil then
        local wrapped = field_value(character, "<Character>k__BackingField")
            or field_value(character, "_Character")
        return wrapped or character
    end
    return info
end

-- Roots: the manager, the master otomo control, the master character and the
-- local hunter. The character and the condition object are resolved directly
-- because that path is known to work, and they seed the walk even if it stalls.
local function buff_roots()
    local roots = {}
    local om = safe(sdk.get_managed_singleton, "app.OtomoManager")
    if om ~= nil then
        roots[#roots + 1] = om
        local ctl = getter(om, "getMasterOtomoManagedControl")
        if ctl ~= nil then
            roots[#roots + 1] = ctl
            local info = field_value(ctl, "_OtomoManagedInfo")
                or getter(ctl, "get_OtomoManagedInfo")
            local char = info and field_value(info, "<Character>k__BackingField")
            if char ~= nil then
                roots[#roots + 1] = char
                local stock = field_value(char, "_StockDamage")
                local cond = stock and field_value(stock, "_Condition")
                if cond ~= nil then roots[#roots + 1] = cond end
            end
        end
    end
    local hunter = local_hunter_character()
    if hunter ~= nil then roots[#roots + 1] = hunter end
    return roots
end

local function collect_buff_objects()
    local out, seen = {}, {}
    local queue, head, tail = {}, 1, 0
    for _, r in ipairs(buff_roots()) do
        if r ~= nil then
            tail = tail + 1
            queue[tail] = { obj = r, depth = 0 }
            seen[r] = true
        end
    end
    local nodes = 0
    while head <= tail and nodes < 400 do
        local it = queue[head]
        queue[head] = nil
        head = head + 1
        nodes = nodes + 1
        if safe(function() return sdk.is_managed_object(it.obj) end) == true then
            if method0(it.obj, "isActiveAttackUp") ~= nil then
                out[#out + 1] = it.obj
            end
            if it.depth < 5 then
                for _, child in ipairs(children_of(it.obj)) do
                    if not seen[child]
                        and safe(function() return sdk.is_managed_object(child) end) == true then
                        seen[child] = true
                        tail = tail + 1
                        queue[tail] = { obj = child, depth = it.depth + 1 }
                    end
                end
            end
        end
    end
    return out
end

local BUFF_METHODS = { "isActiveAttackUp", "isEnableAttackUpIcon" }

local function obj_flag(obj, name)
    local m = method0(obj, name)
    if m == nil then return nil end
    local v = safe(function() return m:call(obj) end)
    if type(v) == "boolean" then return v end
    return nil
end

-- The buff the mod grants is on the hunter: app.HunterCharacter:get_HunterSkill()
-- returns app.cHunterSkill, which tracks the Palico's horn song directly
-- (isOtomoMusicAttackUp / getOtomoMusicSkillTimer). The Palico's own condition
-- manager only mirrors it when the Palico gets the buff too, so it is the
-- fallback, not the source.
local function hunter_music_state()
    local hunter = local_hunter_character()
    if hunter == nil then return nil end

    if state.hunter_type == nil then
        local td = safe(function() return hunter:get_type_definition() end)
        state.hunter_type = td and safe(function() return td:get_full_name() end) or "?"
        trace("hunter object: " .. tostring(state.hunter_type)
            .. " status=" .. tostring(getter(hunter, "get_HunterStatus") ~= nil))
    end

    local skill = getter(hunter, "get_HunterSkill")
    if skill == nil then
        local status = access(hunter, "Status")
        skill = status and access(status, "Skill") or nil
    end
    if skill == nil then
        if not state.skill_missing then
            state.skill_missing = true
            trace("hunter skill: not found on " .. tostring(state.hunter_type))
        end
        return nil
    end

    local up = obj_flag(skill, "isOtomoMusicAttackUp")
    if up == nil then return nil end
    local timer = as_number(getter(skill, "getOtomoMusicSkillTimer"))
    return up, timer
end

local function palico_buff()
    if state.buff_objs == nil
        or (state.frames - (state.buff_checked or 0)) > 600 then
        state.buff_objs = collect_buff_objects()
        state.buff_checked = state.frames
        trace("buff objects: " .. #state.buff_objs
            .. " (roots " .. tostring(#buff_roots()) .. ")")
    end

    local any = false
    for _, obj in ipairs(state.buff_objs or {}) do
        for _, name in ipairs(BUFF_METHODS) do
            local v = obj_flag(obj, name)
            if v == true then return true end
            if v == false then any = true end
        end
    end
    if any then return false end
    return nil
end

-- Two sources: the hunter's horn-song skill (authoritative for the buff the mod
-- grants) and the Palico's condition manager (fallback / cross-check). Any true
-- wins, so a fire is never refunded while the buff is actually up.
local function read_buff()
    local song = hunter_music_state()
    local palico = palico_buff()
    local sig = tostring(song) .. "/" .. tostring(palico)
    if sig ~= state.buff_sig then
        state.buff_sig = sig
        trace("buff sources: song=" .. tostring(song)
            .. " palico=" .. tostring(palico))
    end

    if song == true or palico == true then
        state.buff = true
    elseif song == false or palico == false then
        state.buff = false
    else
        state.buff = nil
    end
    return state.buff
end

local function buff_diagnostic()
    local up, sec = hunter_music_state()
    local head = "song=" .. tostring(up) .. "/" .. tostring(sec)
    if state.buff_objs == nil then return head end
    local parts = {}
    for i, obj in ipairs(state.buff_objs) do
        local td = safe(function() return obj:get_type_definition() end)
        local tn = td and safe(function() return td:get_full_name() end) or "?"
        parts[#parts + 1] = string.format("%d:%s active=%s icon=%s", i, tostring(tn),
            tostring(obj_flag(obj, "isActiveAttackUp")),
            tostring(obj_flag(obj, "isEnableAttackUpIcon")))
    end
    if #parts == 0 then return head end
    return head .. " | " .. table.concat(parts, " ")
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
            local is_int_overload = first_param_is_int(m)
            local ok = pcall(function()
                sdk.hook(m,
                    function(args)
                        if args == nil or args[2] == nil then return end
                        state.self = args[2]
                        state.append = safe(function() return sdk.to_int64(args[4]) end)
                        state.captured_at = state.frames
                        state.captures = state.captures + 1

                        local id = is_int_overload
                            and safe(function() return sdk.to_int64(args[3]) end) or nil
                        if type(id) == "number" then
                            if id == HORN_ACTION and not state.firing
                                and state.cfg.block_ai_use and state.cfg.enabled then
                                state.blocked = state.blocked + 1
                                state.last_result = "blocked the Palico's own horn request"
                                trace("blocked AI horn request #" .. state.blocked)
                                return sdk.PreHookResult.SKIP_ORIGINAL
                            end
                        end
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

-- The tool object carries the game's own cooldown for the horn. Capture it from
-- the AI's own evaluation (read-only) and watch its numeric fields, so the mod
-- can stop firing while the game would refuse the buff.
local USE_TYPE = "app.cOtomoToolManaged_Horn_AtkUp"

local function install_tool_hook()
    if state.tool_hook ~= "not tried" then return end
    local td = safe(sdk.find_type_definition, USE_TYPE)
    if td == nil then
        state.tool_hook = "type not found"
        trace("tool hook: " .. state.tool_hook)
        return
    end
    local installed = 0
    for _, name in ipairs({ "isDesireActivate", "useOtomoTool" }) do
        local m = safe(function() return td:get_method(name) end)
        if m ~= nil then
            local ok = pcall(function()
                sdk.hook(m, function(args)
                    if args ~= nil and args[2] ~= nil then
                        if name == "useOtomoTool" then
                            state.tool_self = args[2]
                        else
                            state.desire_self = args[2]
                        end
                    end
                end, function(retval) return retval end)
            end)
            if ok then installed = installed + 1 end
        end
    end
    state.tool_hook = "installed " .. installed
    trace("tool hook: " .. state.tool_hook)
end

-- Dump every field of an object once, with its declared type and value. This is
-- how the horn tool and the cUseHorn action reveal what the game actually has
-- equipped / is playing.
local function trace_object(label, obj)
    local td = safe(function() return obj:get_type_definition() end)
    if td == nil then
        trace(label .. ": no type")
        return
    end
    trace(label .. ": " .. tostring(safe(function() return td:get_full_name() end)))
    local walk, depth = td, 0
    local parts = {}
    while walk ~= nil and depth < 6 do
        for _, f in ipairs(safe(function() return walk:get_fields() end) or {}) do
            local n = safe(function() return f:get_name() end)
            local ft = safe(function() return f:get_type() end)
            local tn = ft and safe(function() return ft:get_full_name() end) or "?"
            local v = safe(function() return f:get_data(obj) end)
            local vs = ""
            if type(v) == "number" then vs = string.format("%.2f", v)
            elseif type(v) == "boolean" or type(v) == "string" then vs = tostring(v) end
            parts[#parts + 1] = tostring(n) .. "(" .. tostring(tn) .. ")=" .. vs
        end
        walk = safe(function() return walk:get_parent_type() end)
        depth = depth + 1
    end
    trace(label .. " fields: " .. table.concat(parts, " "))
end

local function install_action_hook()
    if state.action_hook ~= "not tried" then return end
    local td = safe(sdk.find_type_definition, "app.OtomoCommonAction.cUseHorn")
    if td == nil then
        state.action_hook = "type not found"
        trace("action hook: " .. state.action_hook)
        return
    end
    local m = nil
    for _, cand in ipairs(safe(function() return td:get_methods() end) or {}) do
        if safe(function() return cand:get_name() end) == "useHornActionDoEnter" then
            m = cand
            break
        end
    end
    if m == nil then
        state.action_hook = "method not found"
        trace("action hook: " .. state.action_hook)
        return
    end
    local ok = pcall(function()
        sdk.hook(m, function(args)
            if args ~= nil and args[2] ~= nil then
                state.action_self = args[2]
            end
        end, function(retval) return retval end)
    end)
    state.action_hook = ok and "installed" or "hook failed"
    trace("action hook: " .. state.action_hook)
end

-- The runtime horn tool (the object that owns the game's cooldown) is not
-- reachable from the character directly. Otomo Tools found it through the
-- character's mini-component updaters -> mcOtomoToolManager -> the tool class
-- for the HORN_ATKUP enum value; the same path is used here.
local function field_children(obj)
    local out = {}
    local td = safe(function() return obj:get_type_definition() end)
    local depth = 0
    while td ~= nil and depth < 5 do
        for _, f in ipairs(safe(function() return td:get_fields() end) or {}) do
            if safe(function() return f:is_static() end) ~= true then
                local name = safe(function() return f:get_name() end)
                local v = safe(function() return f:get_data(obj) end)
                if name ~= nil and v ~= nil then
                    out[#out + 1] = { key = name, value = v }
                end
            end
        end
        td = safe(function() return td:get_parent_type() end)
        depth = depth + 1
    end
    return out
end

local function walk_find(root, pattern, maxDepth, maxNodes)
    if root == nil then return nil end
    local queue = { { obj = root, depth = 0 } }
    local seen = { [root] = true }
    local nodes, head, tail = 0, 1, 1
    maxDepth = maxDepth or 3
    maxNodes = maxNodes or 300
    while head <= tail and nodes < maxNodes do
        local it = queue[head]
        queue[head] = nil
        head = head + 1
        nodes = nodes + 1
        local td = safe(function() return it.obj:get_type_definition() end)
        local tn = td and safe(function() return td:get_full_name() end) or nil
        if type(tn) == "string" and tn:lower():find(pattern:lower(), 1, true) then
            return it.obj
        end
        if it.depth < maxDepth then
            for _, k in ipairs(field_children(it.obj)) do
                if safe(function() return sdk.is_managed_object(k.value) end) == true
                    and not seen[k.value] then
                    seen[k.value] = true
                    tail = tail + 1
                    queue[tail] = { obj = k.value, depth = it.depth + 1 }
                end
            end
        end
    end
    return nil
end

local function tool_manager()
    if state.tool_manager ~= nil then return state.tool_manager end
    local om = safe(sdk.get_managed_singleton, "app.OtomoManager")
    if om == nil then return nil end
    local ctl = getter(om, "getMasterOtomoManagedControl")
    if ctl == nil then return nil end
    local info = field_value(ctl, "_OtomoManagedInfo")
        or getter(ctl, "get_OtomoManagedInfo")
    local char = info and field_value(info, "<Character>k__BackingField")
    if char == nil then
        char = walk_find(ctl, "OtomoCharacter", 2, 120)
    end
    if char == nil then return nil end
    for _, name in ipairs({
        "_MiniCompUpdater_LateUpdate", "_MiniCompUpdater_AfterMotion",
        "_MiniCompUpdater_AfterAction", "_MiniCompUpdater_LateUpdateEnd",
        "_MiniCompUpdator_BeforeAction", "_Components",
    }) do
        local root = field_value(char, name)
        if root ~= nil then
            local m = walk_find(root, "otomoToolManager", 3, 300)
            if m ~= nil then
                state.tool_manager = m
                trace("tool manager found via " .. name)
                return m
            end
        end
    end
    return nil
end

local function tool_enum()
    if state.tool_values ~= nil then return state.tool_values end
    for _, short in ipairs({ "USE_OTOMO_TOOL_TYPE", "OTOMO_TOOL_TYPE" }) do
        local tn = nil
        for _, c in ipairs({ "app.OtomoDef." .. short, "app." .. short, short }) do
            if safe(sdk.find_type_definition, c) ~= nil then tn = c break end
        end
        if tn ~= nil then
            local td = safe(sdk.find_type_definition, tn)
            local vals = {}
            for _, f in ipairs(safe(function() return td:get_fields() end) or {}) do
                if safe(function() return f:is_static() end) == true then
                    local n = safe(function() return f:get_name() end)
                    local v = safe(function() return f:get_data(nil) end)
                    if n ~= nil and type(v) == "number" then vals[n] = v end
                end
            end
            if next(vals) ~= nil then
                state.tool_values = vals
                return vals
            end
        end
    end
    return nil
end

local function horn_tool()
    local vals = tool_enum()
    if vals == nil then return nil end
    local value = nil
    for name, v in pairs(vals) do
        if name:find("HORN_ATKUP", 1, true) then value = v break end
    end
    if value == nil then return nil end
    local mgr = tool_manager()
    if mgr == nil then return nil end
    local td = safe(function() return mgr:get_type_definition() end)
    if td == nil then return nil end
    for _, m in ipairs(safe(function() return td:get_methods() end) or {}) do
        if safe(function() return m:get_name() end) == "getOtomoToolManagedClass"
            and safe(function() return m:get_num_params() end) == 1 then
            return safe(function() return m:call(mgr, value) end)
        end
    end
    return nil
end

local function tool_state()
    if state.tool_self == nil then return nil end
    return safe(sdk.to_managed_object, state.tool_self)
end

local function tool_fields_of(obj)
    local out = {}
    local td = safe(function() return obj:get_type_definition() end)
    local walk, depth = td, 0
    while walk ~= nil and depth < 6 do
        for _, f in ipairs(safe(function() return walk:get_fields() end) or {}) do
            local n = safe(function() return f:get_name() end)
            if n ~= nil and out[n] == nil then
                local v = safe(function() return f:get_data(obj) end)
                if type(v) == "number" or type(v) == "boolean" or type(v) == "string" then
                    out[n] = v
                end
            end
        end
        walk = safe(function() return walk:get_parent_type() end)
        depth = depth + 1
    end
    return out
end

local function tool_scan()
    local obj = horn_tool() or tool_state()
    if obj == nil then
        if not state.tool_missing then
            state.tool_missing = true
            trace("horn tool: not resolved (manager="
                .. tostring(state.tool_manager ~= nil)
                .. " use_capture=" .. tostring(state.tool_self ~= nil) .. ")")
        end
        return
    end
    if not state.tool_dumped then
        state.tool_dumped = true
        trace_object("tool object", obj)
    end
    local fields = tool_fields_of(obj)
    local prev = state.tool_fields
    state.tool_fields = fields
    if prev == nil then
        local parts = {}
        for k, v in pairs(fields) do
            if type(v) == "number" then
                parts[#parts + 1] = k .. "=" .. string.format("%.2f", v)
            end
        end
        table.sort(parts)
        trace("tool fields: " .. table.concat(parts, " "))
        return
    end
    local changes = {}
    for k, v in pairs(fields) do
        local before = prev[k]
        if type(v) == "number" and type(before) == "number" and before ~= v then
            changes[#changes + 1] = k .. " " .. string.format("%.2f->%.2f", before, v)
        end
    end
    if #changes > 0 then
        table.sort(changes)
        trace("tool: " .. table.concat(changes, " "))
    end
end

-- ----------------------------------------------------------------- input ----

-- ImGui exposes no key enum on this build, so common values are labelled here
-- for display only. "." reports as 599 (stock ImGui uses 587).
local KEY_LABELS = {
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

-- Hotkey binding. imgui.ImGuiKey is empty on this build, so the key is found by
-- scanning numeric values. 512..600 covers Tab through F12 plus the punctuation
-- block (period is 599 here); lower values are mouse buttons and out-of-range
-- garbage. A key must be held for two frames so a stray read cannot bind.
local SCAN_MIN = 512
local SCAN_MAX = 600

local function try_scan()
    if state.scan == nil then return false end

    if (state.frames or 0) - state.scan.started > 600 then
        state.scan = nil
        state.last_result = "hotkey unchanged (no key detected)"
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
        state.last_result = "hotkey bound: " .. tostring(state.key_note)
        trace("bound hotkey " .. tostring(v))
        return true
    end
    return false
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

-- Forward declaration: a failed fire dumps the live buff state, and the dump
-- section is defined below the fire section.
local dump_buff_state

local function attempt_key(reason)
    if reason == "first hit" then return "first_hit" end
    if reason == "quest start" then return "quest_start" end
    return nil
end

local function fire(reason)
    local why = ready_reason()
    if why ~= nil then
        state.last_result = "skipped: " .. why
        return false
    end

    -- an unconfirmed fire holds the next one: its cooldown has not started, so
    -- the gate below would be wide open
    if state.verify ~= nil then
        state.last_result = "waiting for the last fire to land"
        return false
    end

    -- single authoritative gate: nothing fires while the next-buff countdown
    -- is running, whatever the trigger or its reason
    local left = cooldown_left()
    if left > 0 then
        state.last_result = string.format("held by cooldown: %d s left", left)
        return false
    end

    local min_frames = (state.cfg.min_interval_sec or 0.5) * 60
    if state.fires > 0 and (state.frames - state.last_fire_frame) < min_frames then
        state.last_result = "debounced"
        return false
    end

    local self = safe(sdk.to_managed_object, state.self)
    state.firing = true
    local ok, ret = pcall(function()
        return state.method:call(self, HORN_ACTION, state.append)
    end)
    state.firing = false

    state.fires = state.fires + 1
    state.last_fire_frame = state.frames
    if ok then
        local k = attempt_key(reason)
        if k ~= nil then state.tries[k] = (state.tries[k] or 0) + 1 end
        state.verify = { reason = reason, at = state.frames }
        state.last_result = "fired (" .. tostring(reason) .. "), waiting for the buff"
    else
        state.last_result = "error: " .. tostring(ret)
    end
    trace("fire #" .. state.fires .. " " .. tostring(reason) .. " -> " .. tostring(state.last_result))
    return ok
end

-- The request can be refused before the horn plays: a roar interrupts the
-- animation, and before the quest has loaded the action is dropped. Neither
-- produced a buff, so neither may spend the cooldown. Wait for the buff, make
-- sure it holds, and only then start the timer.
local function confirm_fire()
    local v = state.verify
    if v == nil then return end

    if state.buff == true then
        if v.seen == nil then v.seen = state.frames end
        if state.frames - v.seen >= VERIFY_HOLD then
            state.verify = nil
            state.confirmed = state.confirmed + 1
            state.last_fire_time = os.time()
            state.last_result = string.format("fired (%s), buff up", v.reason)
            trace(string.format("fire confirmed: %s, buff up after %.1f s",
                tostring(v.reason), (state.frames - v.at) / 60))
            -- latch the event triggers only now; a cancelled fire must be able
            -- to try again
            local k = attempt_key(v.reason)
            if k ~= nil then state.tries[k] = 0 end
            if v.reason == "first hit" then state.first_hit_done = true end
            if v.reason == "quest start" then state.quest_start_pending = false end
        end
        return
    end

    -- the buff was seen and dropped again (the animation was interrupted), so
    -- keep waiting inside the timeout
    if v.seen ~= nil then v.seen = nil end
    if state.frames - v.at < VERIFY_TIMEOUT then return end

    state.verify = nil
    state.reason_last[v.reason] = nil
    state.last_result = string.format(
        "fire did not land (%s), cooldown not used", v.reason)
    trace("fire not confirmed: " .. tostring(v.reason) .. " - cooldown not used")
    dump_buff_state("fire not confirmed: " .. tostring(v.reason))

    local k = attempt_key(v.reason)
    local tries = k ~= nil and (state.tries[k] or 0) or 0
    if k == nil then return end
    if tries >= MAX_ATTEMPTS then
        trace("giving up on " .. tostring(v.reason) .. " after "
            .. tostring(tries) .. " attempts")
        if v.reason == "first hit" then
            state.first_hit_done = true
        else
            state.quest_start_pending = false
        end
        return
    end

    if v.reason == "first hit" then
        state.first_hit_done = false
        state.retry_at = state.frames + RETRY_FRAMES
    else
        -- the object captured before the quest loaded is the likely cause, so
        -- make the retry wait for a fresh capture
        state.self = nil
        state.quest_start_pending = true
        state.quest_start_at = state.frames + RETRY_FRAMES
    end
end

-- One place for the debounce/cooldown/fire chain, so the pending-fire block in
-- the frame loop stays readable.
local function handle_request(reason)
    if state.last_req_reason ~= reason
        or (state.frames - (state.last_req_frame or 0)) > 60 then
        state.last_req_reason = reason
        state.last_req_frame = state.frames
        trace("request: " .. tostring(reason))
    end

    local left = cooldown_left()
    local last = state.reason_last[reason]
    local since = last ~= nil and (state.frames - last) or 999999
    if since < 180 then
        state.last_result = string.format("%s debounced (%d s)", reason,
            math.floor(since / 60))
        trace("debounced: " .. tostring(reason))
    elseif left > 0 then
        state.last_result = string.format("held by cooldown: %d s left", left)
        trace("held by cooldown: " .. tostring(reason))
    else
        -- latching happens in confirm_fire, never on the request alone
        if fire(reason) then
            state.reason_last[reason] = state.frames
        end
    end
end

-- ------------------------------------------------------------------ dump ----

-- Live snapshot of everything that could carry the horn buff, written while the
-- buff is visibly up. One read tells us which field actually moves.
local function describe_value(v)
    local t = type(v)
    if v == nil then return nil end
    if t == "number" or t == "boolean" or t == "string" then return v end
    if safe(function() return sdk.is_managed_object(v) end) == true then
        local td = safe(function() return v:get_type_definition() end)
        return "obj:" .. tostring(td and safe(function() return td:get_full_name() end) or "?")
    end
    return "<" .. t .. ">"
end

local function array_values(obj, maxn)
    if obj == nil then return nil end
    local n = safe(function() return obj:get_Length() end)
        or safe(function() return obj:get_Count() end)
        or safe(function() return obj:get_Size() end)
    if type(n) ~= "number" then return nil end
    local out = {}
    for i = 0, math.min(n - 1, maxn or 16) do
        out[#out + 1] = describe_value(safe(function() return obj[i] end))
    end
    return out
end

local function dump_fields_into(into, label, obj)
    if obj == nil then return end
    local td = safe(function() return obj:get_type_definition() end)
    if td == nil then return end
    local rec = {
        type = safe(function() return td:get_full_name() end),
        fields = {},
        methods = {},
        arrays = {},
    }
    local walk, depth = td, 0
    while walk ~= nil and depth < 6 do
        for _, f in ipairs(safe(function() return walk:get_fields() end) or {}) do
            local n = safe(function() return f:get_name() end)
            if n ~= nil and rec.fields[n] == nil then
                local v = safe(function() return f:get_data(obj) end)
                rec.fields[n] = describe_value(v)
                if safe(function() return sdk.is_managed_object(v) end) == true then
                    local vals = array_values(v, 16)
                    if vals ~= nil then rec.arrays[n] = vals end
                end
            end
        end
        walk = safe(function() return walk:get_parent_type() end)
        depth = depth + 1
    end
    for _, m in ipairs(safe(function() return td:get_methods() end) or {}) do
        local n = safe(function() return m:get_name() end)
        if n ~= nil and #n < 80 then
            rec.methods[n] = safe(function() return m:get_num_params() end)
        end
    end
    into[label] = rec
end

-- Every object near the hunter/otomo that exposes an AttackUp/Music method,
-- with its live flags. Finds the field even if it sits deeper than the normal
-- buff walk reaches.
local function dump_candidates(out)
    local seen, queue, head, tail = {}, {}, 1, 0
    for _, r in ipairs(buff_roots()) do
        if r ~= nil then
            tail = tail + 1
            queue[tail] = { obj = r, depth = 0 }
            seen[r] = true
        end
    end
    local nodes = 0
    out.candidates = {}
    while head <= tail and nodes < 1200 do
        local it = queue[head]
        queue[head] = nil
        head = head + 1
        nodes = nodes + 1
        if safe(function() return sdk.is_managed_object(it.obj) end) == true then
            local td = safe(function() return it.obj:get_type_definition() end)
            local hits = {}
            for _, m in ipairs(safe(function() return td:get_methods() end) or {}) do
                local n = safe(function() return m:get_name() end)
                if type(n) == "string" and (n:find("AttackUp", 1, true)
                    or n:find("OtomoMusic", 1, true)) then
                    hits[#hits + 1] = n
                end
            end
            if #hits > 0 then
                out.candidates[#out.candidates + 1] = {
                    depth = it.depth,
                    type = td and safe(function() return td:get_full_name() end) or "?",
                    methods = hits,
                    active_attack_up = obj_flag(it.obj, "isActiveAttackUp"),
                    active_attack_up_icon = obj_flag(it.obj, "isEnableAttackUpIcon"),
                    otomo_music_attack_up = obj_flag(it.obj, "isOtomoMusicAttackUp"),
                    otomo_music_timer = describe_value(
                        safe(function() return it.obj:getOtomoMusicSkillTimer() end)),
                }
            end
            if it.depth < 8 then
                for _, child in ipairs(children_of(it.obj)) do
                    if not seen[child]
                        and safe(function() return sdk.is_managed_object(child) end) == true then
                        seen[child] = true
                        tail = tail + 1
                        queue[tail] = { obj = child, depth = it.depth + 1 }
                    end
                end
            end
        end
    end
end

function dump_buff_state(reason)
    local out = { at = os.time(), version = VERSION, reason = reason,
        buff = state.buff, objects = {}, calls = {} }
    local hunter = local_hunter_character()

    dump_fields_into(out.objects, "hunter", hunter)
    local status = hunter and getter(hunter, "get_HunterStatus") or nil
    dump_fields_into(out.objects, "status", status)
    local skill = hunter and getter(hunter, "get_HunterSkill") or nil
    dump_fields_into(out.objects, "skill", skill)

    if status ~= nil then
        dump_fields_into(out.objects, "attack_power", access(status, "AttackPower"))
        dump_fields_into(out.objects, "defence_power", access(status, "DefencePower"))
        dump_fields_into(out.objects, "item_buff", access(status, "ItemBuff"))
        dump_fields_into(out.objects, "meal_effect", access(status, "MealEffect"))
        dump_fields_into(out.objects, "bad_conditions", access(status, "BadConditions"))
    end
    if hunter ~= nil then
        dump_fields_into(out.objects, "hunter_effect", access(hunter, "HunterEffect"))
        dump_fields_into(out.objects, "status_watcher",
            getter(hunter, "get_StatusWatcher"))
    end

    if skill ~= nil then
        out.otomo_music_timers = array_values(
            field_value(skill, "_OtomoMusicSkillTimer"), 16)
        for _, name in ipairs({ "isOtomoMusicAttackUp", "isOtomoMusicDefenceUp",
                                "getOtomoMusicSkillTimer", "getMusicSkillRate",
                                "getSkillOtomoPowerUpAttackRate" }) do
            local m = method0(skill, name)
            if m ~= nil then
                out.calls[name .. "()"] =
                    describe_value(safe(function() return m:call(skill) end))
            end
        end
        local td = safe(function() return skill:get_type_definition() end)
        for _, m in ipairs(safe(function() return td:get_methods() end) or {}) do
            if safe(function() return m:get_name() end) == "getOtomoMusicSkillTimer"
                and safe(function() return m:get_num_params() end) == 1 then
                for i = 0, 7 do
                    out.calls["getOtomoMusicSkillTimer(" .. i .. ")"] =
                        describe_value(safe(function() return m:call(skill, i) end))
                end
            end
        end
    end

    for _, obj in ipairs({ hunter, status }) do
        for _, name in ipairs({ "ItemBuff", "Buff", "Condition", "Conditions" }) do
            local v = obj and access(obj, name) or nil
            if v ~= nil then
                dump_fields_into(out.objects, "hunter." .. name, v)
            end
        end
    end

    out.tool_hook = state.tool_hook
    out.tool_fields = state.tool_fields
    dump_candidates(out)

    out.palico = { buff = palico_buff(), objects = {} }
    for i, o in ipairs(state.buff_objs or {}) do
        if not o then break end
        local td = safe(function() return o:get_type_definition() end)
        out.palico.objects[#out.palico.objects + 1] = {
            index = i,
            type = td and safe(function() return td:get_full_name() end) or "?",
            active = obj_flag(o, "isActiveAttackUp"),
            icon = obj_flag(o, "isEnableAttackUpIcon"),
        }
    end

    state.dump_seq = (state.dump_seq or 0) + 1
    local file = "useful_palico_horn_buff_" .. state.dump_seq .. ".json"
    pcall(json.dump_file, file, out)
    trace("buff state dumped (" .. tostring(reason) .. ") -> " .. file)
end

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

-- REFramework pins managed objects that Lua still references. Holding the
-- Palico's condition manager or the monster chain across a quest end keeps the
-- old scene alive, which is what leaves the loading screen hanging; probing
-- those objects while the scene tears down is what fills the console with
-- errors. Drop every world reference the moment the quest is over.
local function release_world(why)
    state.self = nil
    state.append = nil
    state.buff_objs = nil
    state.buff = nil
    state.buff_sig = nil
    state.hunter_type = nil
    state.skill_missing = false
    state.buff_checked = 0
    state.boss_ctx, state.boss_em = nil, nil
    state.boss_chara, state.boss_basic, state.boss_status = nil, nil, nil
    state.boss_modules = {}
    state.status_type = nil
    state.cond = { trapped = nil, stunned = nil, paralyzed = nil }
    state.cond_prev = {}
    state.cond_sig = nil
    state.cond_logged = false
    state.monster_state, state.monster_hp, state.monster_max = nil, nil, nil
    state.monster_note = "-"
    state.chain_logged = false
    state.verify = nil
    state.pending_fire = nil
    state.pending_kind = nil
    state.dump_at = nil
    state.tool_self = nil
    state.desire_self = nil
    state.tool_manager = nil
    state.tool_fields = nil
    state.tool_dumped = false
    state.tool_missing = nil
    state.action_self = nil
    state.action_dumped = false
    state.diag_sig = nil
    pcall(function() collectgarbage("collect") end)
    trace("world released (" .. tostring(why) .. ")")
end

re.on_frame(function()
    local ok, err = pcall(function()
        install()
        install_tool_hook()
        install_action_hook()
        state.frames = state.frames + 1

        -- quest state first: the world objects are released the moment the
        -- quest ends, and nothing below may probe them while it is not running
        if state.frames % 30 == 0 then
            local playing = quest_playing()
            if playing ~= nil then
                if playing == false and state.playing == true then
                    release_world("quest end")
                end
                if state.was_playing == false and playing == true then
                    trace("quest start (cooldown reset)")
                    state.last_fire_time = nil
                    state.first_hit_done = false
                    state.reason_last = {}
                    state.tries = { first_hit = 0, quest_start = 0 }
                    state.buff_objs = nil
                    state.verify = nil
                    state.retry_at = 0
                    state.quest_start_pending = state.cfg.fire_on_quest_start
                    state.quest_start_at = state.frames + 240   -- ~4 s settle
                    state.dump_at = state.frames + 360          -- baseline ~6 s
                end
                if playing == false then
                    state.quest_start_pending = false
                end
                state.playing = playing
                state.was_playing = playing
            end
        end

        if state.playing == true then
            if state.frames % 600 == 0 then state.buff_objs = nil end
            if state.frames % 15 == 0 then read_buff() end
            if state.frames % 150 == 0 then
                local diag = buff_diagnostic()
                if diag ~= state.diag_sig then
                    state.diag_sig = diag
                    trace("buff diag: " .. diag)
                end
            end
            if state.frames % 30 == 0 then monster_scan() end
        end

        if state.frames % 60 == 0 then
            tool_scan()
            if not state.action_dumped and state.action_self ~= nil then
                local act = safe(sdk.to_managed_object, state.action_self)
                if act ~= nil then
                    state.action_dumped = true
                    trace_object("horn action", act)
                end
            end
        end
        confirm_fire()
        if state.frames % 300 == 0 then state.base_cooldown = read_base_cooldown() end

        local bind_blocked = state.bind_block_until ~= nil
            and state.frames <= state.bind_block_until
        if state.pending_fire == nil and not bind_blocked and key_pressed() then
            state.pending_fire = "hotkey"
            state.pending_kind = "event"
        end

        -- event trigger: first damage to the monster
        if state.cfg.fire_on_first_hit and state.pending_fire == nil
            and state.frames >= (state.retry_at or 0) then
            if state.monster_state == false then
                state.first_hit_done = false     -- full hp again: new hunt/monster
                state.tries.first_hit = 0
            elseif state.monster_state == true and state.first_hit_done == false
                and state.self ~= nil then
                state.pending_fire = "first hit"
                state.pending_kind = "event"
            end
        end

        -- quest start: armed until a fire is actually confirmed; the monster has
        -- to exist first, which means the quest world is loaded
        if state.cfg.fire_on_quest_start and state.quest_start_pending
            and state.pending_fire == nil and state.self ~= nil
            and state.monster_state ~= nil
            and state.frames >= (state.quest_start_at or 0) then
            state.pending_fire = "quest start"
            state.pending_kind = "event"
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
        if state.dump_at ~= nil and state.frames >= state.dump_at then
            state.dump_at = nil
            dump_buff_state("quest start baseline")
        end
        if state.dump_buff_requested then
            state.dump_buff_requested = false
            dump_buff_state("manual")
        end

        -- keep-alive: buff down, gated by the global cooldown
        if state.cfg.auto_when_down and state.buff == false
            and state.pending_fire == nil and state.verify == nil
            and cooldown_left() == 0 then
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
            if state.verify ~= nil then
                -- the last fire has not landed yet; the trigger stays armed and
                -- asks again on the next frame
                state.last_result = "waiting for the last fire to land"
            else
                handle_request(reason)
            end
        end

        if state.frames % 300 == 0 then
            local buffv = state.buff == true and "UP"
                or (state.buff == false and "down" or "?")
            local monv = state.monster_state == true and "damaged"
                or (state.monster_state == false and "full" or "?")
            trace(string.format(
                "status: %s | captures=%d buff=%s monster=%s fires=%d ok=%d last=%s | blocked=%d | trap=%s stun=%s para=%s",
                tostring(state.hook_note), state.captures, buffv, monv,
                state.fires, state.confirmed, tostring(state.last_result),
                state.blocked,
                tostring(state.cond.trapped), tostring(state.cond.stunned),
                tostring(state.cond.paralyzed)))
        end
    end)
    if not ok then
        state.errors = (state.errors or 0) + 1
        if state.errors <= 3 or state.errors % 600 == 0 then
            log.info(TAG .. " frame error #" .. state.errors .. ": " .. tostring(err))
        end
    end
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

    imgui.text("Fires the Attack-Up horn on command.")

    changed, state.cfg.enabled = imgui.checkbox("Enabled", state.cfg.enabled)
    if changed then save_config() end

    if imgui.button("Fire horn now") then
        state.pending_fire = "button"
        state.pending_kind = "event"
    end
    imgui.same_line()
    imgui.text("hotkey: " .. tostring(state.key_note))
    if state.scan ~= nil then
        imgui.text("  press the new hotkey now (it binds on hold)")
    elseif imgui.button("Change hotkey") then
        state.scan = { started = state.frames or 0 }
    end
    imgui.text("buff: " .. buff_text())

    imgui.separator()
    imgui.text("Cooldown")
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
    if state.verify ~= nil then
        imgui.text("  waiting for the buff to confirm the last fire")
    else
        imgui.text(left > 0 and string.format("  next buff in %d s", left)
            or "  buff ready")
    end
    imgui.text("  applies to every trigger below, without exception")

    imgui.separator()
    imgui.text("Triggers")
    changed, state.cfg.fire_on_first_hit =
        imgui.checkbox("On the first hit to the monster", state.cfg.fire_on_first_hit)
    if changed then save_config() end

    changed, state.cfg.fire_on_quest_start =
        imgui.checkbox("At quest start", state.cfg.fire_on_quest_start)
    if changed then save_config() end

    changed, state.cfg.cond_trapped =
        imgui.checkbox("When the monster is trapped", state.cfg.cond_trapped)
    if changed then save_config() end
    changed, state.cfg.cond_stunned =
        imgui.checkbox("When the monster is stunned", state.cfg.cond_stunned)
    if changed then save_config() end
    changed, state.cfg.cond_paralyzed =
        imgui.checkbox("When the monster is paralyzed", state.cfg.cond_paralyzed)
    if changed then save_config() end

    changed, state.cfg.auto_when_down =
        imgui.checkbox("When the buff runs out", state.cfg.auto_when_down)
    if changed then save_config() end
    changed, state.cfg.block_ai_use =
        imgui.checkbox("Block the Palico's own horn use", state.cfg.block_ai_use)
    if changed then save_config() end

    if imgui.button("Dump buff state (click while the buff is up)") then
        state.dump_buff_requested = true
    end

    imgui.separator()
    imgui.text("last: " .. tostring(state.last_result))
end

re.on_draw_ui(function()
    local consumed = try_scan()
    local okk, pressed_now = false, false
    if not consumed then
        okk, pressed_now = pcall(key_pressed)
    end
    local blocked = state.bind_block_until ~= nil
        and state.frames <= state.bind_block_until
    if okk and pressed_now and not blocked and state.pending_fire == nil then
        state.pending_fire = "hotkey"
        state.pending_kind = "event"
    end

    if not imgui.tree_node("Useful Palico Horn v" .. VERSION) then return end
    local ok, err = pcall(draw_body)
    safe(function() imgui.tree_pop() end)
    if not ok then
        state.draw_errors = (state.draw_errors or 0) + 1
        if state.draw_errors <= 3 or state.draw_errors % 600 == 0 then
            log.info(TAG .. " draw error #" .. state.draw_errors .. ": " .. tostring(err))
        end
    end
end)

load_config()
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
