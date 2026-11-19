--[[
  otomo_desire.lua - force the desire gate. NOT part of Otomo Tools.

  Findings so far:

    checkEnable()             true 100.0%   (watcher, whole hunt)
    useOtomoToolRequirement() true 100.0%
    isDesireActivate()        true   2.2%   <- the only gate that closes

  v0.1.0 hooked isDesireActivate() with sdk.hook and saw 0 calls, but only
  counted MATCHES. v0.2.0 counted calls: 5949 in 58 s, so the global hook works
  fine. The mismatch was the object:

      hook `this`: userdata: 0000000CB046EA40
      cached horn: userdata: 0000000D80C257B0

  The horn was resolved in the hub; the quest recreates the tool objects, so the
  cached address was stale. (sdk.hook also returns nil here even when it
  installs, so the return value is not a success signal on this build.)

  v0.3.0:
    - re-resolves the horn every ~2 s and updates the address
    - drops the vtable attempt (it throws; the global hook already reaches the
      function, so it is unnecessary)
    - records which `this` addresses call the method, to prove whether the
      resolved object is among them

  Forcing the return to true still does NOT call useOtomoTool(): the game's own
  update() performs the use, so the animation and effect take the normal path.

  Off by default. Output: reframework/data/otomo_desire.json
]]

local VERSION = "0.3.0"
local TAG = "[OtomoDesire] "
local FILE = "otomo_desire.json"
local TOOL_TYPE = "app.cOtomoToolManaged_Horn_AtkUp"
local TARGET = "HORN_ATKUP"
local METHOD = "isDesireActivate"
local RESOLVE_EVERY = 120     -- ~2 s

local st = {
    armed = false,
    mgr_raw = nil,
    mgr_type = nil,
    tool = nil,
    horn_addr = nil,
    horn_type = nil,

    hook_state = "not tried",
    calls = 0,
    hits = 0,

    first_this = nil,
    seen = {},
    seen_count = 0,
    frames = 0,
    frames_armed = 0,
    addr_changes = 0,
}

local function safe(fn, ...)
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil
end

local function flush()
    local seen_list = {}
    for addr, _ in pairs(st.seen) do seen_list[#seen_list + 1] = addr end
    table.sort(seen_list)
    pcall(json.dump_file, FILE, {
        version = VERSION,
        at = os.time(),
        armed = st.armed,
        manager = st.mgr_type,
        horn_addr = st.horn_addr,
        horn_type = st.horn_type,
        first_this = st.first_this,
        hook = st.hook_state,
        calls = st.calls,
        hits = st.hits,
        distinct_this = st.seen_count,
        seen_this = seen_list,
        addr_changes = st.addr_changes,
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

-- Called outside every hook. Refreshes the address because the quest recreates
-- the tool objects.
local function resolve_horn()
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
                local addr = tostring(safe(sdk.to_ptr, tool) or tool)
                if st.horn_addr ~= nil and st.horn_addr ~= addr then
                    st.addr_changes = st.addr_changes + 1
                    log.info(TAG .. " horn moved: " .. st.horn_addr .. " -> " .. addr)
                end
                if st.horn_addr ~= addr then
                    st.horn_addr = addr
                    st.horn_type = safe(function()
                        return tool:get_type_definition():get_full_name()
                    end)
                    log.info(TAG .. " horn resolved at " .. addr)
                    flush()
                end
                st.tool = tool
                return true
            end
        end
    end
    return false
end

-- ------------------------------------------------------------------ hook ----

local last_this = nil

local function ensure_hook()
    if st.hook_state ~= "not tried" then return end
    local td = safe(sdk.find_type_definition, TOOL_TYPE)
    if td == nil then st.hook_state = "type not found" return end
    local m = safe(function() return td:get_method(METHOD) end)
    if m == nil then st.hook_state = "method not found" return end

    local ok, hook = pcall(function()
        return sdk.hook(m,
            function(args)
                last_this = args ~= nil and args[2] or nil
                st.calls = st.calls + 1
                local addr = last_this ~= nil and tostring(last_this) or nil
                if addr ~= nil then
                    if st.first_this == nil then
                        st.first_this = addr
                        log.info(TAG .. " first this " .. addr)
                    end
                    if st.seen[addr] == nil then
                        st.seen[addr] = true
                        st.seen_count = st.seen_count + 1
                        if st.seen_count <= 32 then
                            log.info(TAG .. " new this " .. addr)
                        end
                    end
                end
            end,
            function(retval)
                if st.armed ~= true then return retval end
                if st.horn_addr == nil or last_this == nil then return retval end
                if tostring(last_this) ~= st.horn_addr then return retval end
                st.hits = st.hits + 1
                return sdk.to_ptr(true)
            end)
    end)

    -- the return value is not reliable on this build; calls are.
    st.hook_state = ok and ("installed" .. (hook == nil and " (returned nil)" or "")) or "error"
    log.info(TAG .. " hook: " .. tostring(st.hook_state))
    flush()
end

re.on_frame(function()
    local ok, err = pcall(function()
        ensure_hook()
        st.frames = st.frames + 1
        if st.frames % RESOLVE_EVERY == 1 then
            resolve_horn()
        end
        if not st.armed then return end
        st.frames_armed = st.frames_armed + 1
        if st.frames_armed % 120 == 0 then flush() end
    end)
    if not ok then log.info(TAG .. " frame error: " .. tostring(err)) end
end)

local function draw_body()
    local changed
    imgui.text("Forces isDesireActivate() on the Attack-Up horn.")
    imgui.text("The game performs the use; nothing is called directly.")
    imgui.separator()
    imgui.text("hook:    " .. tostring(st.hook_state))
    imgui.text("horn:    " .. tostring(st.horn_addr or "not resolved")
        .. (st.addr_changes > 0 and ("  (moved " .. st.addr_changes .. "x)") or ""))
    imgui.text(string.format("calls:   %d      distinct objects: %d", st.calls, st.seen_count))
    imgui.text(string.format("forced:  %d", st.hits))
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
