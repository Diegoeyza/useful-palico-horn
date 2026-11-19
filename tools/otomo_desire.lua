--[[
  otomo_desire.lua - force the desire gate. NOT part of Otomo Tools.

  Measured first (tools/otomo_watch.lua, 190 s in a quest):

      checkEnable()             true 100.0%
      useOtomoToolRequirement() true 100.0%
      isDesireActivate()        true   2.2%   (one 7 s window)

  So the horn has exactly one gate that ever closes: desire. Everything else -
  cooldown, range, state - was satisfied the whole fight.

  This hooks isDesireActivate() on app.cOtomoToolManaged_Horn_AtkUp and returns
  true while armed. The game's own update() then drives the tool: we are not
  calling useOtomoTool(), so the animation and the effect go through the normal
  path. That is the difference between this and the crash test, which called the
  action directly and produced nothing.

  Off by default. The toggle takes effect immediately (the hook body is gated,
  not just the install).

  Output: reframework/data/otomo_desire.json
]]

local VERSION = "0.1.0"
local TAG = "[OtomoDesire] "
local FILE = "otomo_desire.json"
local TOOL_TYPE = "app.cOtomoToolManaged_Horn_AtkUp"
local TARGET = "HORN_ATKUP"

local st = {
    armed = false,
    hooked = false,
    hook_note = nil,
    mgr_raw = nil,
    mgr_type = nil,
    horn_addr = nil,
    hits = 0,
    frames_armed = 0,
    first_hit = nil,
    tool = nil,
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
        hook = st.hook_note,
        manager = st.mgr_type,
        horn_addr = st.horn_addr,
        hits = st.hits,
        frames_armed = st.frames_armed,
        first_hit = st.first_hit,
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

-- Resolve the horn object's address OUTSIDE the desire hook. The hook body must
-- never call game methods; it only compares this string.
local function resolve_horn()
    if st.horn_addr ~= nil then return true end
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
                local ptr = safe(sdk.to_ptr, tool)
                st.horn_addr = tostring(ptr or tool)
                st.tool = tool
                log.info(TAG .. " horn resolved at " .. st.horn_addr)
                flush()
                return true
            end
        end
    end
    return false
end

-- ------------------------------------------------------------------ hook ----

local last_this = nil

local function ensure_desire_hook()
    if st.hooked then return true end
    local td = safe(sdk.find_type_definition, TOOL_TYPE)
    if td == nil then
        st.hook_note = "type not found"
        return false
    end
    local m = safe(function() return td:get_method("isDesireActivate") end)
    if m == nil then
        st.hook_note = "method not found"
        return false
    end

    local ok = pcall(function()
        sdk.hook(m,
            function(args)
                -- remember `this`; no conversions, no game calls
                last_this = args ~= nil and args[2] or nil
            end,
            function(retval)
                if st.armed ~= true then return retval end
                if st.horn_addr == nil or last_this == nil then return retval end
                if tostring(last_this) ~= st.horn_addr then return retval end
                st.hits = st.hits + 1
                if st.first_hit == nil then
                    st.first_hit = os.time()
                    log.info(TAG .. " forcing desire (first hit)")
                    flush()
                end
                return sdk.to_ptr(true)
            end)
    end)

    st.hooked = ok
    st.hook_note = ok and "installed" or "hook failed"
    log.info(TAG .. " desire hook: " .. tostring(st.hook_note))
    flush()
    return ok
end

re.on_frame(function()
    local ok, err = pcall(function()
        if not st.hooked then ensure_desire_hook() end
        if not st.armed then return end
        st.frames_armed = st.frames_armed + 1
        if st.horn_addr == nil then resolve_horn() end
        if st.frames_armed % 120 == 0 then flush() end
    end)
    if not ok then log.info(TAG .. " frame error: " .. tostring(err)) end
end)

local function draw_body()
    local changed
    imgui.text("Forces isDesireActivate() on the Attack-Up horn.")
    imgui.text("The game still performs the use - nothing is called directly.")
    imgui.separator()
    imgui.text("hook:    " .. tostring(st.hook_note or "not installed"))
    imgui.text("manager: " .. tostring(st.mgr_type or (st.mgr_raw ~= nil and "captured" or "not captured")))
    imgui.text("horn:    " .. tostring(st.horn_addr or "not resolved"))
    imgui.text(string.format("forced:  %d      armed for %d frames", st.hits, st.frames_armed))
    if st.first_hit ~= nil then
        imgui.text("first hit at: " .. os.date("%H:%M:%S", st.first_hit))
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
