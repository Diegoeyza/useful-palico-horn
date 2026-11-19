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

local VERSION = "0.10.1"
local TAG = "[OtomoHorn] "

local CONFIG_FILE = "otomo_horn.json"
local TRACE_FILE = "otomo_horn_trace.json"
local HORN_ACTION = 0x85
local ACTION_TYPE = "app.OtomoCharacter"
local METHOD_NAME = "setActionRequest"

local state = {
    cfg = {
        enabled = true,
        hotkey = "F9",
        min_interval_sec = 0.5,
        auto_when_down = false,
        use_base_cooldown = true,
        global_cooldown_sec = 480,
        fire_on_first_hit = false,
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
    logkeys = nil,          -- diagnostic: just record what is down/pressed
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
end

-- The Attack-Up horn's own cooldown, straight from the tool params. This is the
-- "base game cooldown": 600 s in vanilla, or whatever Otomo Tools has written.
local function read_base_cooldown()
    local om = safe(sdk.get_managed_singleton, "app.OtomoManager")
    if om == nil then return nil end
    local catalog = getter(om, "get_Catalog")
    if catalog == nil then catalog = field_value(om, "_Catalog") end
    local gp = catalog and getter(catalog, "get_GlobalParam")
    if gp == nil and catalog ~= nil then gp = field_value(catalog, "_GlobalParam") end
    local root = gp and getter(gp, "get_OtomoToolParam")
    if root == nil and gp ~= nil then root = field_value(gp, "_OtomoToolParam") end
    if root == nil then return nil end
    local horn = field_value(root, "_Horn_AtkUp")
    if horn == nil then return nil end
    local v = field_value(horn, "_CoolTime")
    if type(v) == "number" and v >= 0 then return v end
    return nil
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

local function resolve_key()
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
    state.key_note = state.key == nil and ("unknown key '" .. spec .. "'")
        or (spec .. " (" .. tostring(state.key) .. ")")
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
            imgui.same_line()
            if imgui.button("Log keys (hold a key 2 s)") then
                state.logkeys = { started = state.frames or 0 }
                trace("logkeys started")
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

    changed, state.cfg.auto_when_down =
        imgui.checkbox("Fire when the buff is down", state.cfg.auto_when_down)
    if changed then save_config() end

    changed, state.cfg.use_base_cooldown =
        imgui.checkbox("Use the base game cooldown", state.cfg.use_base_cooldown)
    if changed then save_config() end
    if state.cfg.use_base_cooldown then
        imgui.text(string.format("  game cooldown: %s s",
            state.base_cooldown ~= nil and tostring(state.base_cooldown) or "unknown (600)"))
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

-- Diagnostic: record every value that reports down or pressed, without binding.
-- This tells us where this build's key values actually are.
local function try_logkeys()
    if state.logkeys == nil then return end
    if (state.frames or 0) - state.logkeys.started > 900 then
        state.logkeys = nil
        trace("logkeys finished")
        return
    end
    if (state.frames or 0) % 30 ~= 0 then return end

    local downs, presses = {}, {}
    for v = 0, 700 do
        local ok1, d = pcall(imgui.is_key_down, v)
        if ok1 and d == true then downs[#downs + 1] = v end
        if imgui.is_key_pressed ~= nil then
            local ok2, pr = pcall(imgui.is_key_pressed, v)
            if ok2 and pr == true then presses[#presses + 1] = v end
        end
    end
    if #downs > 0 or #presses > 0 then
        trace("logkeys down=[" .. table.concat(downs, ",") .. "] pressed=["
            .. table.concat(presses, ",") .. "]")
    end
end

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
    try_logkeys()
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
