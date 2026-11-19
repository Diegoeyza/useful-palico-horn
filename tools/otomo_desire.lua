--[[
  otomo_desire.lua - force the desire gate. NOT part of Otomo Tools.

  Measured with tools/otomo_watch.lua over a whole hunt:

      checkEnable()             true 100.0%
      useOtomoToolRequirement() true 100.0%
      isDesireActivate()        true   2.2%

  Desire is the only gate that ever closes. v0.1.0 tried to override it with
  sdk.hook() and got zero calls - not even from the watcher's own direct calls,
  so the hook was never entered at all. isDesireActivate() is declared on
  app.cOtomoToolManaged_Horn_AtkUp, i.e. it is an override, i.e. it is virtual,
  and sdk.hook() does not reliably intercept virtual dispatch.

  v0.2.0 installs BOTH and counts calls separately, so one hunt answers which
  mechanism actually reaches the function:

      calls_global  sdk.hook(method_definition)
      calls_vtable  sdk.hook_vtable(horn_object, "isDesireActivate")

  Both paths force the return to true while armed; both only do so when
  `this` is the horn. That is still not calling useOtomoTool(): the game's own
  update() performs the use, so animation and effect use the normal path.

  Off by default. Output: reframework/data/otomo_desire.json
]]

local VERSION = "0.2.0"
local TAG = "[OtomoDesire] "
local FILE = "otomo_desire.json"
local TOOL_TYPE = "app.cOtomoToolManaged_Horn_AtkUp"
local TARGET = "HORN_ATKUP"
local METHOD = "isDesireActivate"

local st = {
    armed = false,
    mgr_raw = nil,
    mgr_type = nil,
    horn_addr = nil,
    horn = nil,
    tool = nil,

    global_state = "not tried",
    global_calls = 0,
    global_hits = 0,
    vtable_state = "not tried",
    vtable_calls = 0,
    vtable_hits = 0,

    first_this = nil,
    frames_armed = 0,
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
        armed = st.armed,
        manager = st.mgr_type,
        horn_addr = st.horn_addr,
        horn_type = st.horn_type,
        first_this = st.first_this,
        global_state = st.global_state,
        global_calls = st.global_calls,
        global_hits = st.global_hits,
        vtable_state = st.vtable_state,
        vtable_calls = st.vtable_calls,
        vtable_hits = st.vtable_hits,
        frames_armed = st.frames_armed,
    })
end

-- ---------------------------------------------------------------- manager ----

local function ensure_manager_hook()
    if st.mgr_raw ~= nil then return true end
    local td = safe(sdk.find_type_definition, "app.mcOtomoToolManager")
    if td == nil then return false end
    local m = safe(function() return td:get_method("updateMain") end)
    if m == nil then return false end
    pcall(function()
        sdk.hook(m, function(args)
            if st.mgr_raw == nil and args ~= nil then st.mgr_raw = args[2] end
        end, function() end)
    end)
    return st.mgr_raw ~= nil
end

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

-- Resolved OUTSIDE every hook. Hooks only compare strings.
local function resolve_horn()
    if st.horn ~= nil then return true end
    if not ensure_manager_hook() then return false end
    if st.mgr_raw == nil then return false end
    local mgr = safe(sdk.to_managed_object, st.mgr_raw)
    if mgr == nil then return false end
    local td = safe(function() return mgr:get_type_definition() end)
    if td == nil then return false end
    st.mgr_type = safe(function() return td:get_full_name() end)
    local value = enum_value(TARGET)
    if value == nil then return false end
    for _, m in ipairs(safe(function() return td:get_methods() end) or {}) do
        if safe(function() return m:get_name() end) == "getOtomoToolManagedClass"
            and safe(function() return m:get_num_params() end) == 1 then
            local tool = safe(function() return m:call(mgr, value) end)
            if tool ~= nil then
                st.tool = tool
                st.horn = tool
                st.horn_addr = tostring(safe(sdk.to_ptr, tool) or tool)
                st.horn_type = safe(function() return tool:get_type_definition():get_full_name() end)
                log.info(TAG .. " horn resolved at " .. st.horn_addr)
                flush()
                return true
            end
        end
    end
    return false
end

-- ----------------------------------------------------------------- hooks ----

local last_this = nil

local function force(retval, counter)
    if st.armed ~= true then return retval end
    if st.horn_addr == nil or last_this == nil then return retval end
    if tostring(last_this) ~= st.horn_addr then return retval end
    st[counter] = st[counter] + 1
    return sdk.to_ptr(true)
end

local function ensure_global_hook()
    if st.global_state ~= "not tried" then return end
    local td = safe(sdk.find_type_definition, TOOL_TYPE)
    if td == nil then st.global_state = "type not found" return end
    local m = safe(function() return td:get_method(METHOD) end)
    if m == nil then st.global_state = "method not found" return end

    local ok, hook = pcall(function()
        return sdk.hook(m,
            function(args)
                last_this = args ~= nil and args[2] or nil
                st.global_calls = st.global_calls + 1
                if st.first_this == nil and last_this ~= nil then
                    st.first_this = tostring(last_this)
                    log.info(TAG .. " first this=" .. st.first_this)
                    flush()
                end
            end,
            function(retval)
                return force(retval, "global_hits")
            end)
    end)

    if not ok then
        st.global_state = "error: " .. tostring(hook)
    elseif hook == nil then
        st.global_state = "returned nil (not hookable)"
    else
        st.global_state = "installed"
    end
    log.info(TAG .. " global hook: " .. tostring(st.global_state))
    flush()
end

local function ensure_vtable_hook()
    if st.vtable_state ~= "not tried" then return end
    if st.horn == nil then return end

    local ok, res = pcall(function()
        return sdk.hook_vtable(st.horn, METHOD,
            function(args)
                last_this = args ~= nil and args[2] or nil
                st.vtable_calls = st.vtable_calls + 1
            end,
            function(retval)
                return force(retval, "vtable_hits")
            end)
    end)

    if not ok then
        st.vtable_state = "error: " .. tostring(res)
    elseif res == nil then
        st.vtable_state = "returned nil"
    else
        st.vtable_state = "installed"
    end
    log.info(TAG .. " vtable hook: " .. tostring(st.vtable_state))
    flush()
end

re.on_frame(function()
    local ok, err = pcall(function()
        ensure_global_hook()
        resolve_horn()
        ensure_vtable_hook()
        if not st.armed then return end
        st.frames_armed = st.frames_armed + 1
        if st.frames_armed % 120 == 0 then flush() end
    end)
    if not ok then log.info(TAG .. " frame error: " .. tostring(err)) end
end)

local function draw_body()
    local changed
    imgui.text("Forces isDesireActivate() on the Attack-Up horn.")
    imgui.text("Global hook and vtable hook both installed; each counts its calls.")
    imgui.separator()
    imgui.text("horn:    " .. tostring(st.horn_addr or "not resolved"))
    imgui.text(string.format("global:  %s   calls %d   forced %d",
        tostring(st.global_state), st.global_calls, st.global_hits))
    imgui.text(string.format("vtable:  %s   calls %d   forced %d",
        tostring(st.vtable_state), st.vtable_calls, st.vtable_hits))
    if st.first_this ~= nil then
        imgui.text("first this: " .. tostring(st.first_this))
    end
    imgui.separator()
    changed, st.armed = imgui.checkbox("Force desire (horn always wants to fire)", st.armed)
    if changed then
        log.info(TAG .. " armed -> " .. tostring(st.armed))
        flush()
    end
    imgui.text("watch the horn counter for actual uses")
    imgui.text("file: " .. FILE)
end

re.on_draw_ui(function()
    if not imgui.tree_node("Otomo Desire v" .. VERSION) then return end
    local ok, err = pcall(draw_body)
    safe(function() imgui.tree_pop() end)
    if not ok then log.info(TAG .. " draw error: " .. tostring(err)) end
end)

log.info(TAG .. " loaded v" .. VERSION)
