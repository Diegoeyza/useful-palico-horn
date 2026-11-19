--[[
  otomo_horn.lua - fire the Palico's Attack-Up horn on command.

  Sibling of otomo_tools.lua (cooldowns + counter). This one is the timing
  tool: it plays the horn when you decide, so the buff lands on a paralysis or
  a trap instead of whenever the AI feels like it.

  Mechanism (from Nexus 627 PalicoMod.dll, verified in game): replay the
  Palico's own action request with the horn's action id.

      hook app.OtomoCharacter:setActionRequest   -- read-only, captures `this`
      fire: setActionRequest(this, 0x85, appendKind)   -- 0x85 = cUseHorn

  The tool's desire gate, cooldown and ~4 min refractory are not involved: this
  is the action layer. Verified repeating and after the buff expires.

  Triggers
  --------
    - hotkey (default F6) or the panel button
    - "fire when the buff is down": keeps the buff up automatically
    - global cooldown (default 480 s) that gates automatic fires

  The buff state is read from the Palico's own condition manager
  (isActiveAttackUp), the same object the Otomo Tools counter uses.
]]

local VERSION = "0.2.0"
local TAG = "[OtomoHorn] "

local CONFIG_FILE = "otomo_horn.json"
local TRACE_FILE = "otomo_horn_trace.json"
local HORN_ACTION = 0x85
local ACTION_TYPE = "app.OtomoCharacter"
local METHOD_NAME = "setActionRequest"

local state = {
    cfg = {
        enabled = true,
        hotkey = "F6",
        min_interval_sec = 0.5,
        auto_when_down = false,
        global_cooldown_sec = 480,
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
    buff = nil,             -- true / false / nil (unknown)
    buff_checked = 0,

    fires = 0,
    last_result = "-",
    last_fire_frame = 0,
    last_fire_time = nil,   -- os.time of the last fire
    pending_fire = nil,

    key = nil,
    key_index = nil,
    key_note = "-",

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
    while #state.trace > 200 do table.remove(state.trace, 1) end
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
    if type(raw.global_cooldown_sec) == "number" then
        c.global_cooldown_sec = math.max(0, math.min(3600, raw.global_cooldown_sec))
    end
end

local function save_config()
    pcall(json.dump_file, CONFIG_FILE, state.cfg)
end

-- ------------------------------------------------------------ reflection ----

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

local function method0(obj, name)
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

-- ------------------------------------------------------------------ buff ----

-- Same object the Otomo Tools counter reads.
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
    if state.condition == nil then
        state.condition = resolve_condition()
    end
    if state.condition == nil then
        state.buff = nil
        return nil
    end
    local m = method0(state.condition, "isActiveAttackUp")
    if m == nil then
        state.condition = nil
        state.buff = nil
        return nil
    end
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

local function describe(m)
    local full = safe(function() return m:get_full_name() end)
    if full ~= nil then return tostring(full) end
    return tostring(safe(function() return m:get_num_params() end))
end

-- Refuse to guess: an integer argument for a struct parameter is a crash shape.
local function first_param_is_int(m)
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

local function resolve_key()
    local spec = tostring(state.cfg.hotkey)
    local enum = imgui.ImGuiKey

    if enum ~= nil then
        for _, name in ipairs({ spec, "ImGuiKey_" .. spec, string.upper(spec) }) do
            local v = enum[name]
            if v ~= nil then
                state.key = v
                break
            end
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
        state.key_note = spec .. " (" .. tostring(state.key)
            .. (state.key_index ~= nil and (", idx " .. tostring(state.key_index)) or "") .. ")"
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
    if state.captured_at ~= nil
        and (state.frames - state.captured_at) > 60 * 60 * 10 then
        return "capture is 10+ minutes old"
    end
    local self = safe(sdk.to_managed_object, state.self)
    if self == nil then return "stale object" end
    local tn = safe(function() return self:get_type_definition():get_full_name() end)
    if type(tn) ~= "string" or not tn:find("OtomoCharacter", 1, true) then
        return "object is " .. tostring(tn)
    end
    return nil
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
    if ok then
        state.last_result = "fired (" .. tostring(reason) .. ")"
    else
        state.last_result = "error: " .. tostring(ret)
    end
    trace("fire #" .. state.fires .. " " .. tostring(reason) .. " -> " .. tostring(state.last_result))
    return ok
end

local function cooldown_left()
    if state.last_fire_time == nil then return 0 end
    local left = (state.cfg.global_cooldown_sec or 0) - (os.time() - state.last_fire_time)
    if left < 0 then return 0 end
    return left
end

-- ----------------------------------------------------------------- frame ----

re.on_frame(function()
    local ok, err = pcall(function()
        install()
        state.frames = state.frames + 1

        -- buff every ~0.25 s
        if state.frames % 15 == 0 then read_buff() end

        -- hotkey also polled here in case the draw callback is not running
        if state.pending_fire == nil and key_pressed() then
            state.pending_fire = "hotkey"
        end

        -- automatic: buff down, past the global cooldown
        if state.cfg.auto_when_down and state.buff == false
            and state.pending_fire == nil then
            local since_fire = state.last_fire_frame == 0 and 999999
                or (state.frames - state.last_fire_frame)
            if cooldown_left() == 0 and since_fire > 600 then
                state.pending_fire = "auto (buff down)"
            end
        end

        if state.pending_fire ~= nil then
            local reason = state.pending_fire
            state.pending_fire = nil
            fire(reason)
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

local function draw_body()
    local changed

    imgui.text("Plays the Attack-Up horn on command (action layer).")
    imgui.text("The tool cooldown and the AI's desire are not involved.")
    imgui.separator()

    imgui.text("hook:    " .. tostring(state.hook_note))
    imgui.text("hotkey:  " .. tostring(state.key_note))
    imgui.text("buff:    " .. buff_text())
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
    end

    imgui.separator()
    imgui.text("Automation")
    changed, state.cfg.auto_when_down =
        imgui.checkbox("Fire when the buff is down", state.cfg.auto_when_down)
    if changed then save_config() end

    local cd = state.cfg.global_cooldown_sec or 0
    changed, cd = imgui.drag_int("Global cooldown (s)", cd, 10, 0, 1800)
    if changed then
        state.cfg.global_cooldown_sec = cd
        save_config()
    end
    local left = cooldown_left()
    if left > 0 then
        imgui.text(string.format("  next automatic fire in %d s", left))
    else
        imgui.text("  automatic fire ready")
    end

    imgui.separator()
    imgui.text("config: " .. CONFIG_FILE)
end

re.on_draw_ui(function()
    local okk, pressed_now = pcall(key_pressed)
    if okk and pressed_now and state.pending_fire == nil then
        state.pending_fire = "hotkey"
    end

    if not imgui.tree_node("Otomo Horn v" .. VERSION) then return end
    local ok, err = pcall(draw_body)
    safe(function() imgui.tree_pop() end)
    if not ok then log.info(TAG .. " draw error: " .. tostring(err)) end
end)

load_config()
resolve_key()

-- Key diagnostics: if the hotkey still does not fire, this line in
-- otomo_horn_trace.json tells us the exact enum names this build exposes.
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
