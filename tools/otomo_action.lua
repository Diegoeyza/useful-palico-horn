--[[
  otomo_action.lua - fire the horn ACTION on demand. NOT part of Otomo Tools.

  PalicoMod (Nexus 627) proved the action layer works: it hooks
  setActionRequest(), replaces the requested action id with 0x85 (cUseHorn),
  and the Palico plays the horn - independent of the tool's desire gate and of
  its cooldown. That is why it can fire at quest start.

  Lua cannot write a hook argument back into the call frame, so this probe does
  the equivalent differently:

    1. hook setActionRequest() read-only, capture `this` and the append kind
       from the game's own call
    2. on a button press, call the same method with action id 0x85

  Both are done outside the risky path: the hook only stores pointers, and the
  call happens in on_frame, not inside a hook.

  What this answers:
    - does the horn play on demand?         (PalicoMod says yes)
    - does the buff actually apply?         (counter)
    - does it work while the tool is in its ~215 s refractory?  <- the point

  Off by default; one fire per press. Output: reframework/data/otomo_action.json
]]

local VERSION = "0.1.0"
local TAG = "[OtomoAction] "
local FILE = "otomo_action.json"
local HORN_ACTION = 0x85          -- cUseHorn, from PalicoMod's disassembly
local MAX_CAPTURE_AGE = 300       -- frames (~5 s)

local st = {
    frames = 0,
    hooked = 0,
    hook_note = nil,
    method = nil,          -- the 2-param setActionRequest we will call
    method_desc = nil,
    self = nil,
    append = nil,
    capture_frame = nil,
    captures = 0,
    last_captured_id = nil,
    fires = {},
    pending_fire = false,
    last_result = nil,
    fire_count = 0,
}

local function safe(fn, ...)
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil
end

local function flush()
    pcall(json.dump_file, FILE, {
        version = VERSION,
        at = os.time(),
        hooks = st.hooked,
        hook_note = st.hook_note,
        method = st.method_desc,
        captures = st.captures,
        last_captured_id = st.last_captured_id,
        last_result = st.last_result,
        fires = st.fires,
    })
end

-- Walk the type and its bases for a named method.
local function collect(td, name, out, depth)
    for _, m in ipairs(safe(function() return td:get_methods() end) or {}) do
        if safe(function() return m:get_name() end) == name then
            out[#out + 1] = m
        end
    end
    local parent = safe(function() return td:get_parent_type() end)
    if parent ~= nil and depth < 4 then collect(parent, name, out, depth + 1) end
end

local function describe(m)
    local n = safe(function() return m:get_num_params() end)
    local parts = {}
    local types = safe(function() return m:get_param_types() end)
    if types ~= nil then
        for _, t in ipairs(safe(function() return types end) or {}) do
            local tn = safe(function() return t:get_full_name() end)
            parts[#parts + 1] = tostring(tn)
        end
    end
    return tostring(n) .. "(" .. table.concat(parts, ", ") .. ")"
end

local function first_param_is_int(m)
    local types = safe(function() return m:get_param_types() end)
    if types == nil then return false end
    local first = nil
    for _, t in ipairs(types) do
        first = t
        break
    end
    if first == nil then return false end
    local name = safe(function() return first:get_full_name() end)
    return name == "System.Int32"
end

local function ensure_hooks()
    if st.hook_note ~= nil then return end
    local td = safe(sdk.find_type_definition, "app.OtomoCharacter")
    if td == nil then st.hook_note = "app.OtomoCharacter not found" return end

    local list = {}
    collect(td, "setActionRequest", list, 0)
    if #list == 0 then st.hook_note = "no setActionRequest" return end

    for _, m in ipairs(list) do
        if safe(function() return m:get_num_params() end) == 2 then
            local desc = describe(m)
            log.info(TAG .. " candidate setActionRequest " .. desc)
            pcall(function()
                sdk.hook(m,
                    function(args)
                        if args == nil then return end
                        st.captures = st.captures + 1
                        local id = safe(function() return sdk.to_int64(args[3]) end)
                        st.last_captured_id = id
                        if st.self == nil then
                            st.self = args[2]
                            st.append = safe(function() return sdk.to_int64(args[4]) end)
                            st.capture_frame = st.frames
                        else
                            st.self = args[2]
                            st.append = safe(function() return sdk.to_int64(args[4]) end)
                            st.capture_frame = st.frames
                        end
                    end,
                    function(retval) return retval end)
                st.hooked = st.hooked + 1
                if st.method == nil and first_param_is_int(m) then
                    st.method = m
                    st.method_desc = desc
                end
            end)
        end
    end

    if st.method == nil and #list > 0 then
        for _, m in ipairs(list) do
            if safe(function() return m:get_num_params() end) == 2 then
                st.method = m
                st.method_desc = describe(m) .. " (fallback)"
                break
            end
        end
    end

    st.hook_note = st.hooked > 0 and ("hooked " .. st.hooked) or "hook failed"
    log.info(TAG .. " " .. tostring(st.hook_note) .. " call=" .. tostring(st.method_desc))
    flush()
end

local function fire()
    if st.method == nil then
        st.last_result = "no method"
        return
    end
    if st.self == nil or st.capture_frame == nil then
        st.last_result = "no capture yet (the Palico must act first)"
        return
    end
    if st.frames - st.capture_frame > MAX_CAPTURE_AGE then
        st.last_result = "capture is stale (waited too long after the last action)"
        return
    end

    local self = safe(sdk.to_managed_object, st.self)
    if self == nil then
        st.last_result = "self is not a managed object"
        return
    end

    st.fire_count = st.fire_count + 1
    local rec = {
        at = os.time(),
        clock = os.date("%H:%M:%S"),
        index = st.fire_count,
        action = HORN_ACTION,
        append = st.append,
        captured_id = st.last_captured_id,
    }

    local ok, ret = pcall(function()
        return st.method:call(self, HORN_ACTION, st.append)
    end)

    if ok then
        rec.result = "called"
        st.last_result = "called ok -> " .. tostring(ret)
    else
        rec.result = "error: " .. tostring(ret)
        st.last_result = rec.result
    end
    st.fires[#st.fires + 1] = rec
    log.info(TAG .. " fire #" .. st.fire_count .. ": " .. tostring(st.last_result))
    flush()
end

re.on_frame(function()
    local ok, err = pcall(function()
        ensure_hooks()
        st.frames = st.frames + 1
        if st.pending_fire then
            st.pending_fire = false
            fire()
        end
        if st.frames % 240 == 0 then flush() end
    end)
    if not ok then log.info(TAG .. " frame error: " .. tostring(err)) end
end)

local function draw_body()
    imgui.text("Fires action 0x85 (cUseHorn) through setActionRequest.")
    imgui.text("Independent of the tool's desire gate and cooldown.")
    imgui.separator()
    imgui.text("hooks:   " .. tostring(st.hooks))
    imgui.text("call:    " .. tostring(st.method_desc or "-"))
    imgui.text(string.format("captures: %d   last id: %s   age: %s",
        st.captures, tostring(st.last_captured_id),
        st.capture_frame and tostring(st.frames - st.capture_frame) or "-"))
    imgui.text("result:  " .. tostring(st.last_result or "-"))
    imgui.separator()
    if imgui.button("Fire horn action (0x85)") then
        st.pending_fire = true
    end
    imgui.text("press while the Palico is active in a quest")
    imgui.text("file: " .. FILE)
end

re.on_draw_ui(function()
    if not imgui.tree_node("Otomo Action v" .. VERSION) then return end
    local ok, err = pcall(draw_body)
    safe(function() imgui.tree_pop() end)
    if not ok then log.info(TAG .. " draw error: " .. tostring(err)) end
end)

log.info(TAG .. " loaded v" .. VERSION)
