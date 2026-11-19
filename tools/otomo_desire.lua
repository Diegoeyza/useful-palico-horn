--[[
  otomo_desire.lua - force the desire gate. NOT part of Otomo Tools.

  What the measurements established:

    checkEnable()             true 100.0%
    useOtomoToolRequirement() true 100.0%
    isDesireActivate()        true   2.2%   <- the only gate that closes

  And what v0.1.0 - v0.3.0 got wrong:

    - sdk.hook() returns nil here even when it installs. Never trust the return.
    - the hook fires ~100x per second, so the method is hot: it *is* the gate.
    - getOtomoToolManagedClass(HORN_ATKUP) returns a DIFFERENT object than the
      one whose isDesireActivate() the AI updates:

          hook `this`:  userdata: 0000000CB046EA40   <- the real runtime object
          manager:      userdata: 0000000D80C257B0   <- not this one

      Every earlier attempt filtered on the manager's address, so nothing ever
      matched. distinct_this was 1, i.e. exactly one object calls the method.

  v0.4.0 therefore drops the manager lookup and forces on every call of
  isDesireActivate() on app.cOtomoToolManaged_Horn_AtkUp. The hook is scoped to
  that type, so "every call" is the attack horn and nothing else.

  This still does not call useOtomoTool(): the game's own update() performs the
  use, so the animation and the buff take the normal path.

  Off by default. Output: reframework/data/otomo_desire.json
]]

local VERSION = "0.4.0"
local TAG = "[OtomoDesire] "
local FILE = "otomo_desire.json"
local TOOL_TYPE = "app.cOtomoToolManaged_Horn_AtkUp"
local METHOD = "isDesireActivate"

local st = {
    armed = false,
    hook_state = "not tried",
    calls = 0,
    hits = 0,
    first_this = nil,
    seen = {},
    seen_count = 0,
    frames_armed = 0,
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
        type = TOOL_TYPE,
        hook = st.hook_state,
        calls = st.calls,
        hits = st.hits,
        first_this = st.first_this,
        distinct_this = st.seen_count,
        seen_this = seen_list,
        frames_armed = st.frames_armed,
    })
end

local function ensure_hook()
    if st.hook_state ~= "not tried" then return end
    local td = safe(sdk.find_type_definition, TOOL_TYPE)
    if td == nil then st.hook_state = "type not found" return end
    local m = safe(function() return td:get_method(METHOD) end)
    if m == nil then st.hook_state = "method not found" return end

    local ok, hook = pcall(function()
        return sdk.hook(m,
            function(args)
                st.calls = st.calls + 1
                local this = args ~= nil and args[2] or nil
                local addr = this ~= nil and tostring(this) or nil
                if addr ~= nil then
                    if st.first_this == nil then
                        st.first_this = addr
                        log.info(TAG .. " first this " .. addr)
                    end
                    if st.seen[addr] == nil then
                        st.seen[addr] = true
                        st.seen_count = st.seen_count + 1
                        log.info(TAG .. " distinct this " .. addr)
                    end
                end
                if st.armed then
                    st.hits = st.hits + 1
                end
            end,
            function(retval)
                if st.armed ~= true then return retval end
                return sdk.to_ptr(true)
            end)
    end)

    st.hook_state = ok and ("installed" .. (hook == nil and " (returned nil)" or "")) or "error"
    log.info(TAG .. " hook: " .. tostring(st.hook_state))
    flush()
end

re.on_frame(function()
    local ok, err = pcall(function()
        ensure_hook()
        if not st.armed then return end
        st.frames_armed = st.frames_armed + 1
        if st.frames_armed % 120 == 0 then flush() end
    end)
    if not ok then log.info(TAG .. " frame error: " .. tostring(err)) end
end)

local function draw_body()
    local changed
    imgui.text("Forces isDesireActivate() on the Attack-Up horn.")
    imgui.text("Scoped to the horn's type: no other tool is affected.")
    imgui.separator()
    imgui.text("hook:    " .. tostring(st.hook_state))
    imgui.text(string.format("calls:   %d      distinct objects: %d", st.calls, st.seen_count))
    imgui.text(string.format("forced:  %d", st.hits))
    if st.first_this ~= nil then
        imgui.text("object:  " .. tostring(st.first_this))
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
