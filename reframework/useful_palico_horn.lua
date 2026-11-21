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

local VERSION = "1.8.1"
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
    action_hook = "not tried",
    type_forced = false,
    type_before = false,
    type_after = false,
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
    scan = nil,              -- { started = frame } while binding a hotkey
    was_playing = nil,
    playing = nil,
    errors = 0,
    draw_errors = 0,
    quest_start_pending = false,
    quest_start_at = nil,
    blocked = 0,
    last_req_reason = nil,
    last_req_frame = nil,
    reason_last = {},        -- per-trigger debounce
    monster_state = nil,     -- true = damaged, false = full hp, nil = unknown
    monster_hp = nil,
    monster_max = nil,
    monster_note = "-",
    first_hit_done = false,
    chain_logged = false,

    fires = 0,
    confirmed = 0,
    want_horn = false,
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

-- Writes are deferred to the frame loop: json.dump_file on every trace line
-- was a disk write several times a second and a real source of stutter.
local function trace(line)
    state.trace[#state.trace + 1] = clock() .. " " .. line
    while #state.trace > 120 do table.remove(state.trace, 1) end
    state.trace_dirty = true
end

local function flush_trace()
    if not state.trace_dirty then return end
    state.trace_dirty = false
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

-- Reflection is expensive: type:get_methods() alone is ~600 entries on the
-- hunter. Cache every method/field descriptor by type name so the per-frame
-- readers do a table lookup instead of a scan.
local method_cache = {}
local field_cache = {}

local function type_key(td)
    return safe(function() return td:get_full_name() end) or tostring(td)
end

local function method0(obj, name)
    if obj == nil then return nil end
    local td = safe(function() return obj:get_type_definition() end)
    if td == nil then return nil end
    local per = method_cache[type_key(td)]
    if per == nil then per = {} method_cache[type_key(td)] = per end
    if per[name] ~= nil then return per[name] or nil end

    local walk, depth = td, 0
    while walk ~= nil and depth < 8 do
        for _, m in ipairs(safe(function() return walk:get_methods() end) or {}) do
            if safe(function() return m:get_name() end) == name
                and safe(function() return m:get_num_params() end) == 0 then
                per[name] = m
                return m
            end
        end
        walk = safe(function() return walk:get_parent_type() end)
        depth = depth + 1
    end
    per[name] = false
    return nil
end

local function getter(obj, name)
    local m = method0(obj, name)
    if m == nil then return nil end
    return safe(function() return m:call(obj) end)
end

local function field_descriptor(obj, name)
    local td = safe(function() return obj:get_type_definition() end)
    if td == nil then return nil end
    local per = field_cache[type_key(td)]
    if per == nil then per = {} field_cache[type_key(td)] = per end
    if per[name] ~= nil then return per[name] or nil end

    local walk, depth = td, 0
    while walk ~= nil and depth < 8 do
        for _, f in ipairs(safe(function() return walk:get_fields() end) or {}) do
            if safe(function() return f:get_name() end) == name then
                per[name] = f
                return f
            end
        end
        walk = safe(function() return walk:get_parent_type() end)
        depth = depth + 1
    end
    per[name] = false
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
-- with a boolean/number is used.
-- app.EnemyDef.CONDITION, read from the live type in game.
local COND_IDS = {
    paralyzed = { 5, 6 },          -- PARALYSE, PARALYSE_EM
    stunned   = { 15, 16 },        -- STUN, STUN_EM
    trapped   = { 31, 39, 40, 41, 42, 43 },  -- FIELD_PITFALL, TRAP_FALL,
                                             -- TRAP_PARALYSE, TRAP_IVY, ...
}

-- cEmModuleConditions:isActive(CONDITION) -> Boolean. nil means the method was
-- not found, which is different from "not active".
local cond_method_cache = {}
local function condition_method_bool(cond, methodName, value)
    if cond == nil then return nil end
    local td = safe(function() return cond:get_type_definition() end)
    if td == nil then return nil end
    local key = type_key(td) .. "|" .. methodName
    local m = cond_method_cache[key]
    if m == nil then
        for _, cand in ipairs(safe(function() return td:get_methods() end) or {}) do
            if safe(function() return cand:get_name() end) == methodName
                and safe(function() return cand:get_num_params() end) == 1 then
                m = cand
                break
            end
        end
        cond_method_cache[key] = m or false
    end
    if m == false then return nil end
    local ok, v = pcall(function() return m:call(cond, value) end)
    if ok and type(v) == "boolean" then return v end
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

-- cHunterAttackPower carries the Attack-Up timer for the hunter. This is the
-- field the horn's buff actually sets (the HUD icon does not exist for it).
local function attack_up_state()
    local hunter = local_hunter_character()
    local status = hunter and getter(hunter, "get_HunterStatus")
    local ap = status and access(status, "AttackPower")
    if ap == nil then return nil end
    return as_number(getter(ap, "get_AttackUpTimer")),
        as_number(getter(ap, "get_CurrentAttackPower"))
end

local function read_buff()
    local song = hunter_music_state()
    local timer = attack_up_state()
    local timer_up = (timer ~= nil) and (timer > 0) or nil
    local sig = tostring(song) .. "/" .. tostring(timer_up)
    if sig ~= state.buff_sig then
        state.buff_sig = sig
        trace("buff: song=" .. tostring(song)
            .. " attack_up_timer=" .. tostring(timer))
    end

    if song == true or timer_up == true then
        state.buff = true
    elseif song == false or timer_up == false then
        state.buff = false
    else
        state.buff = nil
    end
    return state.buff
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
                            if id == HORN_ACTION and not state.firing then
                                state.append_horn = state.append
                                if not state.append_horn_logged then
                                    state.append_horn_logged = true
                                    trace("AI horn append=" .. tostring(state.append_horn))
                                end
                            end
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

local function nullable_state(obj, name)
    local f = field_descriptor(obj, name)
    if f == nil then return nil end
    local v = safe(function() return f:get_data(obj) end)
    if v == nil then return nil end
    local hv = safe(function() return v:read_byte(0) end)
    local val = safe(function() return v:read_dword(4) end)
    if hv == nil and val == nil then return nil end
    return hv, val
end

local function install_action_hook()
    if state.action_hook ~= "not tried" then return end
    local td = safe(sdk.find_type_definition, "app.OtomoCommonAction.cUseHorn")
    if td == nil then
        state.action_hook = "type not found"
        trace("action hook: " .. state.action_hook)
        return
    end

    -- PalicoMod looks this up as "doEnter()" on the action type (its error
    -- message calls it useHornActionDoEnter). Collect doEnter/useHornAction*
    -- variants across the hierarchy and hook every match.
    local names = {}
    local list = {}
    local walk2, depth2 = td, 0
    while walk2 ~= nil and depth2 < 6 do
        for _, m in ipairs(safe(function() return walk2:get_methods() end) or {}) do
            local n = safe(function() return m:get_name() end)
            if type(n) == "string" then
                local low = n:lower()
                if low:find("doenter", 1, true)
                    or low:find("usehorn", 1, true) then
                    names[#names + 1] = n .. "/" .. tostring(safe(function() return m:get_num_params() end))
                    list[#list + 1] = m
                end
            end
        end
        walk2 = safe(function() return walk2:get_parent_type() end)
        depth2 = depth2 + 1
    end
    trace("cUseHorn enter methods: " .. table.concat(names, " "))

    local direct = safe(function() return td:get_method("doEnter()") end)
    if direct ~= nil then list[#list + 1] = direct end
    if #list == 0 then
        state.action_hook = "method not found"
        trace("action hook: " .. state.action_hook)
        return
    end

    local ok = false
    for _, m in ipairs(list) do
        local hooked = pcall(function()
            local last_action = nil
            sdk.hook(m, function(args)
                if args == nil or args[2] == nil then return end
                last_action = args[2]
                if state.want_horn or state.verify ~= nil then
                    local obj = safe(sdk.to_managed_object, args[2])
                    local f = obj and field_descriptor(obj, "_Type")
                    if f ~= nil then
                        local hv0, v0 = nullable_state(obj, "_Type")
                        if not state.type_before then
                            state.type_before = true
                            trace("_Type before: " .. tostring(hv0) .. "/" .. tostring(v0))
                        end
                        -- REFramework's ValueType supports raw writes, and
                        -- Nullable<T> is { bool hasValue; T value } in memory;
                        -- PalicoMod writes byte 1 at 0 and int 1 at 4.
                        local function raw_nullable(target)
                            local dt = safe(function() return f:get_type() end)
                            if dt == nil then return nil end
                            local vt = safe(function() return f:get_data(obj) end)
                            if vt == nil then
                                vt = safe(function() return ValueType.new(dt) end)
                            end
                            if vt == nil then return nil end
                            local a = pcall(function() vt:write_byte(0, 1) end)
                            local b = pcall(function() vt:write_dword(4, target) end)
                            if not (a and b) then return nil end
                            return vt
                        end

                        local function stuck()
                            local hv, v = nullable_state(obj, "_Type")
                            if hv == true and v == 1 then return true end
                            -- fall back to raw read-back through the ValueType
                            local vt = safe(function() return f:get_data(obj) end)
                            if vt == nil then return false end
                            local b = safe(function() return vt:read_byte(0) end)
                            local d = safe(function() return vt:read_dword(4) end)
                            return (b ~= nil and b ~= 0) and d == 1
                        end
                        local how = nil
                        -- 0) raw nullable bytes, then hand the ValueType back
                        local vt = raw_nullable(1)
                        if vt ~= nil then
                            pcall(function() f:set_data(obj, vt) end)
                            if stuck() then how = "raw_set_data" end
                            if how == nil then
                                safe(function() obj:set_field("_Type", vt) end)
                                if stuck() then how = "raw_set_field" end
                            end
                            if how == nil then
                                pcall(function()
                                    sdk.set_native_field(obj, obj:get_type_definition(),
                                        "_Type", vt)
                                end)
                                if stuck() then how = "raw_native" end
                            end
                        end
                        -- every attempt is verified by reading the field back;
                        -- set_field returns true without writing here
                        if how == nil then
                            safe(function() obj:set_field("_Type", 1) end)
                            if stuck() then how = "set_field" end
                        end
                        if how == nil then
                            pcall(function() f:set_data(obj, 1) end)
                            if stuck() then how = "set_data" end
                        end
                        local dt = safe(function() return f:get_type() end)
                        local field_value_obj = dt and safe(function() return f:get_data(obj) end) or nil
                        if how == nil and field_value_obj ~= nil then
                            pcall(function() sdk.set_native_field(field_value_obj, dt, "value", 1) end)
                            pcall(function() sdk.set_native_field(field_value_obj, dt, "hasValue", true) end)
                            if stuck() then how = "field_value" end
                        end
                        local vt = dt and safe(function() return ValueType.new(dt) end) or nil
                        if how == nil and vt ~= nil then
                            pcall(function() sdk.set_native_field(vt, dt, "value", 1) end)
                            pcall(function() sdk.set_native_field(vt, dt, "hasValue", true) end)
                            if how == nil then
                                safe(function() obj:set_field("_Type", vt) end)
                                if stuck() then how = "set_field_vt" end
                            end
                            if how == nil then
                                pcall(function() f:set_data(obj, vt) end)
                                if stuck() then how = "set_data_vt" end
                            end
                            if how == nil then
                                pcall(function()
                                    sdk.set_native_field(obj, obj:get_type_definition(), "_Type", vt)
                                end)
                                if stuck() then how = "native_field_vt" end
                            end
                        end
                        state.want_horn = false
                        if not state.type_forced then
                            state.type_forced = true
                            local hv1, v1 = nullable_state(obj, "_Type")
                            trace("forced horn _Type=1: " .. tostring(how or "failed")
                                .. " -> " .. tostring(hv1) .. "/" .. tostring(v1))
                        end
                    end
                end
            end, function(retval)
                if state.verify ~= nil and not state.type_after then
                    state.type_after = true
                    local obj = safe(sdk.to_managed_object, last_action)
                    local hv, v = nil, nil
                    if obj ~= nil then hv, v = nullable_state(obj, "_Type") end
                    trace("_Type after doEnter: " .. tostring(hv) .. "/" .. tostring(v))
                end
                return retval
            end)
        end)
        if hooked then ok = true end
    end
    state.action_hook = ok and ("installed " .. #list) or "hook failed"
    trace("action hook: " .. state.action_hook)
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
    local append = state.append_horn or state.append
    state.firing = true
    state.want_horn = true
    local ok, ret = pcall(function()
        return state.method:call(self, HORN_ACTION, append)
    end)
    state.firing = false
    if not ok then state.want_horn = false end

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
    trace("fire #" .. state.fires .. " " .. tostring(reason)
        .. " append=" .. tostring(append) .. " -> " .. tostring(state.last_result))
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
            state.want_horn = false
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
    state.want_horn = false
    state.reason_last[v.reason] = nil
    state.last_result = string.format(
        "fire did not land (%s), cooldown not used", v.reason)
    trace("fire not confirmed: " .. tostring(v.reason) .. " - cooldown not used")

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
-- ----------------------------------------------------------------- frame ----

-- REFramework pins managed objects that Lua still references. Holding the
-- Palico's condition manager or the monster chain across a quest end keeps the
-- old scene alive, which is what leaves the loading screen hanging; probing
-- those objects while the scene tears down is what fills the console with
-- errors. Drop every world reference the moment the quest is over.
local function release_world(why)
    state.self = nil
    state.append = nil
    state.buff = nil
    state.buff_sig = nil
    state.hunter_type = nil
    state.skill_missing = false
    state.boss_ctx, state.boss_em = nil, nil
    state.boss_chara, state.boss_basic, state.boss_status = nil, nil, nil
    state.boss_modules = {}
    state.status_type = nil
    state.cond = { trapped = nil, stunned = nil, paralyzed = nil }
    state.cond_prev = {}
    state.monster_state, state.monster_hp, state.monster_max = nil, nil, nil
    state.monster_note = "-"
    state.chain_logged = false
    state.verify = nil
    state.pending_fire = nil
    state.pending_kind = nil
    state.type_forced = false
    state.type_before = false
    state.type_after = false
    pcall(function() collectgarbage("collect") end)
    trace("world released (" .. tostring(why) .. ")")
end

re.on_frame(function()
    local ok, err = pcall(function()
        install()
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
                    state.verify = nil
                    state.retry_at = 0
                    state.quest_start_pending = state.cfg.fire_on_quest_start
                    state.quest_start_at = state.frames + 240   -- ~4 s settle
                end
                if playing == false then
                    state.quest_start_pending = false
                end
                state.playing = playing
                state.was_playing = playing
            end
        end

        if state.playing == true then
            if state.frames % 30 == 0 then read_buff() end
            if state.frames % 60 == 0 then monster_scan() end
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
            elseif state.cfg.enabled then
                handle_request(reason)
            end
        end

        if state.frames % 60 == 0 then flush_trace() end
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
