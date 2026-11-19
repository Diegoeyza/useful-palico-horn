--[[
  otomo_watch.lua - read-only gate watcher. NOT part of Otomo Tools.

  The crash test (tools/otomo_trigger.lua) showed that calling
  useOtomoTool() does not crash, but also does nothing: the buff never went up.
  That means the action is gated by something that runs before it.

  This script reads the three predicates that the tool exposes, ten times a
  second, and records every transition:

      checkEnable()               -> Boolean   is the tool allowed at all
      isDesireActivate()          -> Boolean   does the AI WANT it right now
      useOtomoToolRequirement()   -> Boolean   are the conditions met (cooldown...)

  Nothing is written to the game. The only risky action is the opt-in
  one-shot below, which calls useOtomoTool() on the first frame where all
  three are true - that is the question "can we execute what the AI already
  decided", as opposed to "can we drive a tool it did not want".

  Output: reframework/data/otomo_watch.json
]]

local VERSION = "0.1.0"
local TAG = "[OtomoWatch] "
local TARGET = "HORN_ATKUP"
local FILE = "otomo_watch.json"
local POLL_EVERY = 6      -- ~10 Hz at 60 fps
local KEEP = 240          -- ring buffer of transitions

local st = {
    hooked = false,
    mgr_raw = nil,
    mgr_type = nil,
    tool = nil,
    tool_type = nil,
    frame = 0,
    polls = 0,
    prev = nil,
    events = {},
    counts = { enable = 0, desire = 0, requirement = 0, all = 0 },
    armed = false,
    fired = false,
    fire_note = nil,
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
        target = TARGET,
        type = st.tool_type,
        polls = st.polls,
        counts = st.counts,
        armed = st.armed,
        fired = st.fired,
        fire_note = st.fire_note,
        events = st.events,
    })
end

local function ensure_hook()
    if st.hooked then return true end
    local td = safe(sdk.find_type_definition, "app.mcOtomoToolManager")
    if td == nil then return false end
    local m = safe(function() return td:get_method("updateMain") end)
    if m == nil then return false end
    local ok = pcall(function()
        sdk.hook(m, function(args)
            if st.mgr_raw == nil and args ~= nil then st.mgr_raw = args[2] end
        end, function() end)
    end)
    st.hooked = ok
    return ok
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

local function resolve_tool()
    if st.mgr_raw == nil then return nil end
    local mgr = safe(sdk.to_managed_object, st.mgr_raw)
    if mgr == nil then return nil end
    local td = safe(function() return mgr:get_type_definition() end)
    if td == nil then return nil end
    st.mgr_type = safe(function() return td:get_full_name() end)
    local value = enum_value(TARGET)
    if value == nil then return nil end
    for _, m in ipairs(safe(function() return td:get_methods() end) or {}) do
        if safe(function() return m:get_name() end) == "getOtomoToolManagedClass"
            and safe(function() return m:get_num_params() end) == 1 then
            local tool = safe(function() return m:call(mgr, value) end)
            if tool ~= nil then
                local ttd = safe(function() return tool:get_type_definition() end)
                if ttd == nil then
                    tool = safe(sdk.to_managed_object, tool) or tool
                    ttd = safe(function() return tool:get_type_definition() end)
                end
                if ttd ~= nil then
                    st.tool_type = safe(function() return ttd:get_full_name() end)
                    return tool
                end
            end
        end
    end
    return nil
end

local function find_method(tool, name, nparams)
    local td = safe(function() return tool:get_type_definition() end)
    if td == nil then return nil end
    for _, m in ipairs(safe(function() return td:get_methods() end) or {}) do
        if safe(function() return m:get_name() end) == name
            and safe(function() return m:get_num_params() end) == nparams then
            return m
        end
    end
    return nil
end

-- nil means "the call failed", not "false".
local function call_bool(tool, name)
    local m = find_method(tool, name, 0)
    if m == nil then return nil end
    local ok, v = pcall(function() return m:call(tool) end)
    if not ok then return nil end
    if type(v) == "boolean" then return v end
    if type(v) == "number" then return v ~= 0 end
    return v == true
end

local function poll()
    local tool = st.tool
    if tool == nil then
        tool = resolve_tool()
        if tool == nil then return end
        st.tool = tool
    end

    local enable = call_bool(tool, "checkEnable")
    local desire = call_bool(tool, "isDesireActivate")
    local requirement = call_bool(tool, "useOtomoToolRequirement")

    if enable == nil and desire == nil and requirement == nil then
        st.tool = nil   -- stale object (new quest); re-resolve next frame
        return
    end

    st.polls = st.polls + 1
    if enable then st.counts.enable = st.counts.enable + 1 end
    if desire then st.counts.desire = st.counts.desire + 1 end
    if requirement then st.counts.requirement = st.counts.requirement + 1 end

    local all = (enable == true and desire == true and requirement == true)
    if all then st.counts.all = st.counts.all + 1 end

    local signature = tostring(enable) .. "/" .. tostring(desire) .. "/" .. tostring(requirement)
    if signature ~= st.prev then
        st.prev = signature
        st.events[#st.events + 1] = {
            at = os.time(),
            enable = enable,
            desire = desire,
            requirement = requirement,
            all = all,
        }
        if #st.events > KEEP then table.remove(st.events, 1) end
        log.info(TAG .. "enable=" .. tostring(enable) .. " desire=" .. tostring(desire)
            .. " requirement=" .. tostring(requirement))

        -- opt-in: execute the moment the game itself says "yes" to everything
        if all and st.armed and not st.fired then
            st.fired = true
            local use = find_method(tool, "useOtomoTool", 0)
            if use ~= nil then
                st.fire_note = "firing with enable+desire+requirement all true"
                flush()
                local ok, ret = pcall(function() return use:call(tool) end)
                st.fire_note = (ok and "fired, returned " or "lua error: ") .. tostring(ret)
                flush()
                log.info(TAG .. " " .. st.fire_note)
            else
                st.fire_note = "no useOtomoTool(0)"
                flush()
            end
        end
    end
end

re.on_frame(function()
    local ok, err = pcall(function()
        if not st.hooked then ensure_hook() end
        st.frame = st.frame + 1
        if st.frame % POLL_EVERY == 0 then
            poll()
        end
        if st.frame % 120 == 0 then
            flush()
        end
    end)
    if not ok then log.info(TAG .. " frame error: " .. tostring(err)) end
end)

local function draw_body()
    imgui.text("Read-only watcher for the horn's three gates.")
    imgui.text("Nothing is written to the game unless you arm the one-shot.")
    imgui.separator()
    imgui.text("hook:    " .. (st.hooked and "installed" or "not installed"))
    imgui.text("manager: " .. tostring(st.mgr_type or (st.mgr_raw ~= nil and "captured" or "not captured")))
    imgui.text("tool:    " .. tostring(st.tool_type or "-"))
    imgui.separator()
    imgui.text(string.format("polls: %d", st.polls))
    imgui.text(string.format("  checkEnable true:            %d", st.counts.enable))
    imgui.text(string.format("  isDesireActivate true:       %d", st.counts.desire))
    imgui.text(string.format("  useOtomoToolRequirement:     %d", st.counts.requirement))
    imgui.text(string.format("  all three true:              %d", st.counts.all))
    imgui.separator()
    changed, st.armed = imgui.checkbox("One-shot: call useOtomoTool when all three are true", st.armed)
    if st.fired then
        imgui.text("fired: " .. tostring(st.fire_note))
    end
    if imgui.button("Write now") then
        flush()
    end
    imgui.text("file: " .. FILE)
end

re.on_draw_ui(function()
    if not imgui.tree_node("Otomo Watch v" .. VERSION) then return end
    local ok, err = pcall(draw_body)
    safe(function() imgui.tree_pop() end)
    if not ok then log.info(TAG .. " draw error: " .. tostring(err)) end
end)

log.info(TAG .. " loaded v" .. VERSION)
