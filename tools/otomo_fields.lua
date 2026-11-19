--[[
  otomo_fields.lua - read-only field dump of the live horn object.
  NOT part of Otomo Tools.

  Why: the horn refuses to fire for ~210-226 s after a use, while the mod
  writes _CoolTime = 30. So the real timer is a different field, and guessing
  which one would waste hunts. This dumps every field of the object the AI
  actually updates, once a second, and records every change.

  The object matters: getOtomoToolManagedClass() returns a DIFFERENT instance
  than the one whose methods are called. The only reliable way to reach the real
  one is to take `this` from a hook. So we hook isDesireActivate() read-only
  (the post returns the original value untouched) purely to capture `this`.

  Nothing is written to the game. No method is called on the object.

  Output: reframework/data/otomo_fields.json
    fields[]  - name, type, initial value
    changes[] - every value change with a wall-clock stamp
]]

local VERSION = "0.1.0"
local TAG = "[OtomoFields] "
local FILE = "otomo_fields.json"
local TOOL_TYPE = "app.cOtomoToolManaged_Horn_AtkUp"
local METHOD = "isDesireActivate"
local SAMPLE_EVERY = 60      -- ~1 s at 60 fps
local MAX_CHANGES = 2000

local st = {
    hook_state = "not tried",
    this = nil,
    frames = 0,
    samples = 0,
    fields = nil,      -- {name, type, initial}
    prev = {},         -- key -> value
    changes = {},
    started_at = nil,
}

local function safe(fn, ...)
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil
end

local function clock()
    return os.date("%H:%M:%S")
end

local function flush()
    pcall(json.dump_file, FILE, {
        version = VERSION,
        type = TOOL_TYPE,
        at = os.time(),
        started = st.started_at,
        object = st.this,
        samples = st.samples,
        fields = st.fields or {},
        changes = st.changes,
    })
end

local function ensure_hook()
    if st.hook_state ~= "not tried" then return end
    local td = safe(sdk.find_type_definition, TOOL_TYPE)
    if td == nil then st.hook_state = "type not found" return end
    local m = safe(function() return td:get_method(METHOD) end)
    if m == nil then st.hook_state = "method not found" return end
    local ok = pcall(function()
        sdk.hook(m, function(args)
            -- capture only; nothing is called
            if args ~= nil and args[2] ~= nil then
                st.this = args[2]
            end
        end, function(retval)
            return retval
        end)
    end)
    st.hook_state = ok and "installed" or "error"
    log.info(TAG .. " hook: " .. tostring(st.hook_state))
end

-- Fields declared on the type and its bases.
local function collect_fields(td, out, depth)
    for _, f in ipairs(safe(function() return td:get_fields() end) or {}) do
        if safe(function() return f:is_static() end) ~= true then
            out[#out + 1] = f
        end
    end
    local parent = safe(function() return td:get_parent_type() end)
    if parent ~= nil and depth < 4 then
        collect_fields(parent, out, depth + 1)
    end
end

local function sample()
    if st.this == nil then return end
    local obj = safe(sdk.to_managed_object, st.this)
    if obj == nil then return end
    local td = safe(function() return obj:get_type_definition() end)
    if td == nil then return end

    local list = {}
    collect_fields(td, list, 0)

    st.samples = st.samples + 1

    if st.fields == nil then
        st.fields = {}
        st.started_at = clock()
        for _, f in ipairs(list) do
            local name = safe(function() return f:get_name() end)
            local ft = safe(function() return f:get_type() end)
            local ftn = ft ~= nil and safe(function() return ft:get_full_name() end) or nil
            local value = safe(function() return f:get_data(obj) end)
            st.fields[#st.fields + 1] = {
                name = name,
                type = ftn,
                initial = type(value) == "number" and value
                    or type(value) == "boolean" and value
                    or nil,
            }
        end
        log.info(TAG .. " captured " .. tostring(#st.fields) .. " fields of "
            .. tostring(st.this))
        flush()
    end

    for _, f in ipairs(list) do
        local name = safe(function() return f:get_name() end)
        if name ~= nil then
            local value = safe(function() return f:get_data(obj) end)
            local t = type(value)
            if t == "number" or t == "boolean" then
                local key = name
                local prev = st.prev[key]
                if prev == nil or prev ~= value then
                    st.prev[key] = value
                    if #st.changes < MAX_CHANGES then
                        st.changes[#st.changes + 1] = {
                            at = clock(),
                            key = key,
                            value = value,
                        }
                    end
                end
            end
        end
    end
end

re.on_frame(function()
    local ok, err = pcall(function()
        ensure_hook()
        st.frames = st.frames + 1
        if st.frames % SAMPLE_EVERY == 0 then
            sample()
            if st.frames % (SAMPLE_EVERY * 4) == 0 then flush() end
        end
    end)
    if not ok then log.info(TAG .. " frame error: " .. tostring(err)) end
end)

local function draw_body()
    imgui.text("Read-only dump of the live horn object's fields.")
    imgui.text("Captures the object the AI actually updates.")
    imgui.separator()
    imgui.text("hook:   " .. tostring(st.hook_state))
    imgui.text("object: " .. tostring(st.this and tostring(st.this) or "not captured"))
    imgui.text(string.format("samples: %d   fields: %s   changes: %d",
        st.samples, tostring(st.fields and #st.fields or 0), #st.changes))
    if imgui.button("Write now") then flush() end
    imgui.same_line()
    if imgui.button("Clear") then
        st.changes = {}
        st.prev = {}
        st.fields = nil
        st.samples = 0
        flush()
    end
    imgui.text("file: " .. FILE)
end

re.on_draw_ui(function()
    if not imgui.tree_node("Otomo Fields v" .. VERSION) then return end
    local ok, err = pcall(draw_body)
    safe(function() imgui.tree_pop() end)
    if not ok then log.info(TAG .. " draw error: " .. tostring(err)) end
end)

log.info(TAG .. " loaded v" .. VERSION)
