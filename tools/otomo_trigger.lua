--[[
  otomo_trigger.lua - isolated crash test. NOT part of Otomo Tools.

  One question, asked once: does calling cOtomoToolManagedBase.useOtomoTool()
  directly crash the game?

  Everything shipped in Otomo Tools deliberately avoids driving the Palico's
  actions, so the "it will crash" claim behind that decision has never actually
  been tested on this build. This script tests it, on purpose, and leaves a
  breadcrumb on disk that survives a hard crash:

      stage = "calling"   -> written BEFORE the call (the call frame)
      stage = "returned"  -> the call came back
      stage = "survived"  -> +1 / +60 / +300 frames after the call

  If the game dies and the file still says "calling", the call is the cause.
  If it says "survived 300 frames", the claim is wrong for this build.

  Not for normal use. Delete it from reframework/autorun when the test is done.
]]

local VERSION = "0.1.0"
local TAG = "[OtomoTrigger] "
local TARGET = "HORN_ATKUP"

local STATE_FILE = "otomo_trigger_state.json"
local METHODS_FILE = "otomo_trigger_methods.json"

local st = {
    hooked = false,
    mgr_raw = nil,
    mgr_type = nil,
    tool_type = nil,
    accepted = false,
    pending = nil,
    fired = false,
    phase = "idle",
    frames = 0,
    last = "idle",
    history = {},
}

local function safe(fn, ...)
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil
end

local function flush()
    pcall(json.dump_file, STATE_FILE, {
        version = VERSION,
        at = os.time(),
        phase = st.phase,
        last = st.last,
        fired = st.fired,
        manager = st.mgr_type,
        tool_type = st.tool_type,
        history = st.history,
    })
end

-- Every stage is appended and the whole file rewritten, so a crash mid-way
-- loses nothing that was already recorded.
local function note(stage, detail)
    local rec = { stage = stage, at = os.time() }
    if detail ~= nil then rec.detail = tostring(detail) end
    st.history[#st.history + 1] = rec
    st.last = stage
    flush()
    log.info(TAG .. stage .. (detail ~= nil and (" | " .. tostring(detail)) or ""))
end

local function ensure_hook()
    if st.hooked then return true end
    local td = safe(sdk.find_type_definition, "app.mcOtomoToolManager")
    if td == nil then return false end
    local m = safe(function() return td:get_method("updateMain") end)
    if m == nil then return false end
    local ok = pcall(function()
        sdk.hook(m, function(args)
            -- raw pointer only; nothing is called on it here
            if st.mgr_raw == nil and args ~= nil then st.mgr_raw = args[2] end
        end, function() end)
    end)
    st.hooked = ok
    if ok then note("hook installed") end
    return ok
end

-- Enum members read as static fields, same path Otomo Tools uses.
local function enum_value(name)
    local td = safe(sdk.find_type_definition, "app.OtomoDef.USE_OTOMO_TOOL_TYPE")
    if td == nil then return nil end
    for _, f in ipairs(safe(function() return td:get_fields() end) or {}) do
        if safe(function() return f:get_name() end) == name
            and safe(function() return f:is_static() end) == true then
            local v = safe(function() return f:get_data(nil) end)
            if type(v) == "number" then return v end
        end
    end
    return nil
end

local function resolve_tool()
    if st.mgr_raw == nil then return nil, "manager not captured yet (enter a quest)" end
    local mgr = safe(sdk.to_managed_object, st.mgr_raw)
    if mgr == nil then return nil, "to_managed_object failed" end
    local td = safe(function() return mgr:get_type_definition() end)
    if td == nil then return nil, "manager has no type definition" end
    st.mgr_type = safe(function() return td:get_full_name() end)

    local value = enum_value(TARGET)
    if value == nil then return nil, "enum " .. TARGET .. " not found" end
    note("target resolved", TARGET .. " = " .. tostring(value))

    for _, m in ipairs(safe(function() return td:get_methods() end) or {}) do
        if safe(function() return m:get_name() end) == "getOtomoToolManagedClass"
            and safe(function() return m:get_num_params() end) == 1 then
            local tool = safe(function() return m:call(mgr, value) end)
            if tool == nil then return nil, "getOtomoToolManagedClass returned nil" end
            local ttd = safe(function() return tool:get_type_definition() end)
            if ttd == nil then
                tool = safe(sdk.to_managed_object, tool) or tool
                ttd = safe(function() return tool:get_type_definition() end)
            end
            if ttd == nil then return nil, "tool has no type definition" end
            st.tool_type = safe(function() return ttd:get_full_name() end)
            return tool
        end
    end
    return nil, "manager has no getOtomoToolManagedClass(1)"
end

local function method_list(tool)
    local td = safe(function() return tool:get_type_definition() end)
    if td == nil then return nil end
    return safe(function() return td:get_methods() end) or {}
end

-- Safe when called from on_frame, never from the draw callback.
local function dump_methods(tool)
    local out = { version = VERSION, type = st.tool_type, methods = {} }
    for _, m in ipairs(method_list(tool)) do
        local rec = {
            name = safe(function() return m:get_name() end),
            params = safe(function() return m:get_num_params() end),
        }
        local rt = safe(function() return m:get_return_type() end)
        if rt ~= nil then
            rec.returns = safe(function() return rt:get_full_name() end)
        end
        out.methods[#out.methods + 1] = rec
    end
    table.sort(out.methods, function(a, b)
        return tostring(a.name) < tostring(b.name)
    end)
    out.count = #out.methods
    pcall(json.dump_file, METHODS_FILE, out)
    note("methods dumped", out.count .. " methods -> " .. METHODS_FILE)
    return out
end

local function find_method(tool, name, nparams)
    for _, m in ipairs(method_list(tool)) do
        if safe(function() return m:get_name() end) == name
            and safe(function() return m:get_num_params() end) == nparams then
            return m
        end
    end
    return nil
end

local function fire_once()
    if st.fired then
        note("refused: already fired this session (reset scripts to re-arm)")
        return
    end

    local tool, why = resolve_tool()
    if tool == nil then
        note("resolve failed", why)
        return
    end
    dump_methods(tool)

    local use = find_method(tool, "useOtomoTool", 0)
    if use == nil then
        note("no useOtomoTool(0 params) on " .. tostring(st.tool_type))
        return
    end

    local can = find_method(tool, "canUseOtomoTool", 0)
    local can_value = "n/a"
    if can ~= nil then
        can_value = tostring(safe(function() return can:call(tool) end))
    end

    st.fired = true
    st.phase = "calling"

    -- This is the line that survives a hard crash.
    note("calling", string.format("canUseOtomoTool=%s tool=%s",
        can_value, tostring(safe(sdk.to_ptr, tool))))

    local ok, ret = pcall(function() return use:call(tool) end)

    if ok then
        st.phase = "returned"
        st.frames = 0
        note("returned", tostring(ret))
    else
        st.phase = "idle"
        note("lua error", ret)
    end
end

re.on_frame(function()
    local ok, err = pcall(function()
        if not st.hooked then ensure_hook() end

        -- survival window from the previous fire
        if st.phase == "returned" then
            st.frames = st.frames + 1
            if st.frames == 1 or st.frames == 60 or st.frames == 300 then
                note("survived", st.frames .. " frames")
            end
            if st.frames >= 300 then st.phase = "done" end
        end

        if st.pending == "dump" then
            st.pending = nil
            local tool, why = resolve_tool()
            if tool == nil then note("resolve failed", why) else dump_methods(tool) end
        elseif st.pending == "fire" then
            st.pending = nil
            fire_once()
        end
    end)
    if not ok then log.info(TAG .. " frame error: " .. tostring(err)) end
end)

local function draw_body()
    imgui.text("Isolated crash test: drive the Palico action once.")
    imgui.text("Not part of Otomo Tools. Remove from autorun when done.")
    imgui.separator()

    imgui.text("hook:    " .. (st.hooked and "installed" or "not installed"))
    imgui.text("manager: " .. tostring(st.mgr_type or (st.mgr_raw ~= nil and "captured" or "not captured")))
    imgui.text("tool:    " .. tostring(st.tool_type or "-"))
    imgui.text("phase:   " .. tostring(st.phase) .. "   last: " .. tostring(st.last))
    imgui.separator()

    if imgui.button("Dump methods (safe)") then
        st.pending = "dump"
    end

    changed, st.accepted =
        imgui.checkbox("I accept that this may crash the game", st.accepted)
    if st.accepted then
        if st.fired then
            imgui.text("fired this session: reset scripts to re-arm")
        elseif imgui.button("FIRE useOtomoTool once") then
            st.pending = "fire"
        end
    else
        imgui.text("tick the box to enable the trigger")
    end

    imgui.separator()
    imgui.text("state:   " .. STATE_FILE)
    imgui.text("methods: " .. METHODS_FILE)
end

re.on_draw_ui(function()
    if not imgui.tree_node("Otomo Trigger v" .. VERSION) then return end
    local ok, err = pcall(draw_body)
    safe(function() imgui.tree_pop() end)
    if not ok then log.info(TAG .. " draw error: " .. tostring(err)) end
end)

note("loaded v" .. VERSION)
