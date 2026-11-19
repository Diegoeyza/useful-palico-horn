--[[
  otomo_horn.lua - fire the Palico's Attack-Up horn on command.

  Sibling of otomo_tools.lua (cooldown tuning + counter). This one is the
  timing tool: it makes the Palico play the horn when YOU decide, which is what
  a speedrun needs when it wants the buff on a paralysis or a trap instead of
  whenever the AI feels like it.

  Mechanism (reverse-engineered from Nexus mod 627, PalicoMod.dll, and verified
  in game): rather than going through the tool system - desire gate, cooldown,
  ~4 min refractory - it replays the Palico's own action request with the horn's
  action id.

      setActionRequest(this, actionId, appendKind)
      captured: this = app.OtomoCharacter, appendKind from the game's own call
      fired:    setActionRequest(this, 0x85, appendKind)   -- 0x85 = cUseHorn

  Verified: the horn plays and the buff applies, including a second time after
  the buff has expired. The tool's cooldown is not consulted, because this is
  the action layer.

  Lua cannot rewrite a hook argument, so the hook is read-only (it only stores
  the pointers) and the call happens in on_frame.

  Trigger: hotkey (default F6) or the panel button. The Palico must have acted
  at least once in the current quest so the object can be captured.
]]

local VERSION = "0.1.0"
local TAG = "[OtomoHorn] "

local CONFIG_FILE = "otomo_horn.json"
local TRACE_FILE = "otomo_horn_trace.json"
local HORN_ACTION = 0x85          -- app.OtomoCommonAction.cUseHorn
local ACTION_TYPE = "app.OtomoCharacter"
local METHOD_NAME = "setActionRequest"

local state = {
    cfg = { enabled = true, hotkey = "F6", min_interval_sec = 0.5 },

    frames = 0,
    hook_note = "not tried",
    method = nil,
    method_desc = nil,

    self = nil,
    append = nil,
    captured_at = nil,
    captures = 0,

    fires = 0,
    last_result = "-",
    last_fire_frame = 0,
    pending_fire = nil,     -- reason for the next on_frame
    key = nil,
    key_note = "-",
    trace = {},
}

local function safe(fn, ...)
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil
end

local function trace(line)
    state.trace[#state.trace + 1] = os.date("%H:%M:%S") .. " " .. line
    while #state.trace > 200 do table.remove(state.trace, 1) end
    pcall(json.dump_file, TRACE_FILE, { version = VERSION, lines = state.trace })
end

local function load_config()
    local raw = safe(json.load_file, CONFIG_FILE)
    if type(raw) ~= "table" then return end
    if raw.enabled ~= nil then state.cfg.enabled = raw.enabled == true end
    if type(raw.hotkey) == "string" then state.cfg.hotkey = raw.hotkey end
    if type(raw.min_interval_sec) == "number" then
        local n = raw.min_interval_sec
        if n < 0 then n = 0 elseif n > 10 then n = 10 end
        state.cfg.min_interval_sec = n
    end
end

local function save_config()
    pcall(json.dump_file, CONFIG_FILE, state.cfg)
end

-- ---------------------------------------------------------------- hooks ----

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

-- ---------------------------------------------------------------- input ----

local function resolve_key()
    if imgui.ImGuiKey == nil then
        state.key_note = "no imgui.ImGuiKey"
        return
    end
    local k = imgui.ImGuiKey[state.cfg.hotkey]
    if k == nil then
        state.key_note = "unknown key " .. tostring(state.cfg.hotkey)
        return
    end
    state.key = k
    state.key_note = tostring(state.cfg.hotkey)
end

local function key_pressed()
    if state.key == nil or imgui.is_key_pressed == nil then return false end
    local ok, v = pcall(imgui.is_key_pressed, state.key)
    return ok and v == true
end

-- ---------------------------------------------------------------- fire ----

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
        return
    end

    local min_frames = (state.cfg.min_interval_sec or 0.5) * 60
    if state.fires > 0 and (state.frames - state.last_fire_frame) < min_frames then
        state.last_result = "debounced"
        return
    end

    local self = safe(sdk.to_managed_object, state.self)
    local ok, ret = pcall(function()
        return state.method:call(self, HORN_ACTION, state.append)
    end)

    state.fires = state.fires + 1
    state.last_fire_frame = state.frames
    if ok then
        state.last_result = "fired (" .. tostring(reason) .. ")"
    else
        state.last_result = "error: " .. tostring(ret)
    end
    trace("fire #" .. state.fires .. " " .. tostring(reason) .. " -> " .. tostring(state.last_result))
end

-- ---------------------------------------------------------------- frame ----

re.on_frame(function()
    local ok, err = pcall(function()
        install()
        state.frames = state.frames + 1
        if state.pending_fire ~= nil then
            local reason = state.pending_fire
            state.pending_fire = nil
            fire(reason)
        end
    end)
    if not ok then log.info(TAG .. " frame error: " .. tostring(err)) end
end)

-- ---------------------------------------------------------------- ui ----

local function draw_body()
    local changed

    imgui.text("Plays the Attack-Up horn on command (action layer).")
    imgui.text("Independent of the Palico's tool cooldown and AI desire.")
    imgui.separator()

    imgui.text("hook:    " .. tostring(state.hook_note))
    imgui.text("hotkey:  " .. tostring(state.key_note))
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
    imgui.text("Press " .. tostring(state.cfg.hotkey) .. " during a hunt.")
    imgui.text("config: " .. CONFIG_FILE)
end

re.on_draw_ui(function()
    -- Key polling has to happen in the draw callback (imgui input API).
    local okk, pressed = pcall(key_pressed)
    if okk and pressed and state.pending_fire == nil then
        state.pending_fire = "hotkey"
    end

    if not imgui.tree_node("Otomo Horn v" .. VERSION) then return end
    local ok, err = pcall(draw_body)
    safe(function() imgui.tree_pop() end)
    if not ok then log.info(TAG .. " draw error: " .. tostring(err)) end
end)

load_config()
resolve_key()
trace("loaded v" .. VERSION .. " key=" .. tostring(state.key_note))
log.info(TAG .. " loaded v" .. VERSION .. " (" .. tostring(state.key_note) .. ")")
