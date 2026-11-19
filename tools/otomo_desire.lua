--[[
  otomo_desire.lua - force the desire gate. NOT part of Otomo Tools.

  Established:

    checkEnable()             true 100.0%
    useOtomoToolRequirement() true 100.0%
    isDesireActivate()        true   2.2%   <- the only gate that closes

  The override works: 9052 forced calls, and the method now returns true
  wherever it is read, including direct calls. One hunt with it armed at a 30 s
  cooldown produced 1 use in 213 s, which is consistent with the ~136 s buff
  blocking a replay - not with the override failing.

  So the open question is no longer "can we force it" but "can we TIME it".
  That is what the speedrun case actually needs, and it is also a much stronger
  proof than a frequency count.

  v0.5.0 adds a pulse: force desire for 6 seconds on demand.

      [Trigger now (6 s)]  ->  desire forced true for 360 frames

  Press it when the horn is off cooldown (and the buff is down) and the Palico
  should fire within a few seconds. Every pulse is timestamped into
  otomo_desire.json, so it can be compared with the counter's last_use.

  Nothing calls useOtomoTool(): the game's own update() performs the use.

  Output: reframework/data/otomo_desire.json
]]

local VERSION = "0.5.0"
local TAG = "[OtomoDesire] "
local FILE = "otomo_desire.json"
local TOOL_TYPE = "app.cOtomoToolManaged_Horn_AtkUp"
local METHOD = "isDesireActivate"
local PULSE_FRAMES = 360     -- 6 s at 60 fps

local st = {
    armed = false,
    pulse_until = 0,
    frames = 0,
    pulses = {},
    check_at = nil,
    check_rec = nil,

    hook_state = "not tried",
    calls = 0,
    hits = 0,
    first_this = nil,
    seen_count = 0,
    seen = {},
    pulses_fired = 0,
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
        type = TOOL_TYPE,
        hook = st.hook_state,
        calls = st.calls,
        hits = st.hits,
        first_this = st.first_this,
        distinct_this = st.seen_count,
        pulses_fired = st.pulses_fired,
        pulses = st.pulses,
    })
end

local function forced_now()
    if st.armed then return true end
    return st.frames < st.pulse_until
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
                local addr = args ~= nil and args[2] ~= nil and tostring(args[2]) or nil
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
                if forced_now() then st.hits = st.hits + 1 end
            end,
            function(retval)
                if not forced_now() then return retval end
                return sdk.to_ptr(true)
            end)
    end)

    st.hook_state = ok and ("installed" .. (hook == nil and " (returned nil)" or "")) or "error"
    log.info(TAG .. " hook: " .. tostring(st.hook_state))
    flush()
end

local function pulse()
    st.pulse_until = st.frames + PULSE_FRAMES
    st.pulses_fired = st.pulses_fired + 1

    -- read the counter so the outcome is attributed automatically
    local uses_before = nil
    local ok, counter = pcall(json.load_file, "otomo_counter.json")
    if ok and type(counter) == "table" then uses_before = counter.uses end

    local rec = {
        at = os.time(),
        clock = os.date("%H:%M:%S"),
        index = st.pulses_fired,
        uses_before = uses_before,
        calls_at_pulse = st.calls,
        hits_at_pulse = st.hits,
        followed = nil,
    }
    st.pulses[#st.pulses + 1] = rec
    st.check_rec = rec
    st.check_at = st.frames + PULSE_FRAMES + 300   -- 5 s after the pulse ends

    log.info(TAG .. " pulse #" .. st.pulses_fired .. " for " .. PULSE_FRAMES
        .. " frames, uses_before=" .. tostring(uses_before))
    flush()
end

local function check_pulse()
    local rec = st.check_rec
    st.check_rec = nil
    st.check_at = nil
    if rec == nil then return end
    local ok, counter = pcall(json.load_file, "otomo_counter.json")
    if not ok or type(counter) ~= "table" then
        rec.followed = "unknown (counter unreadable)"
        return
    end
    rec.uses_after = counter.uses
    if type(rec.uses_before) == "number" and type(counter.uses) == "number" then
        rec.followed = counter.uses > rec.uses_before
    end
    log.info(TAG .. " pulse #" .. tostring(rec.index) .. " followed=" .. tostring(rec.followed))
    flush()
end

re.on_frame(function()
    local ok, err = pcall(function()
        ensure_hook()
        st.frames = st.frames + 1
        if st.check_at ~= nil and st.frames >= st.check_at then
            check_pulse()
        end
        if st.frames % 120 == 0 then flush() end
    end)
    if not ok then log.info(TAG .. " frame error: " .. tostring(err)) end
end)

local function draw_body()
    local changed
    imgui.text("Forces isDesireActivate() on the Attack-Up horn.")
    imgui.text("Scoped to the horn type; no other tool is affected.")
    imgui.separator()
    imgui.text("hook:    " .. tostring(st.hook_state))
    imgui.text(string.format("calls:   %d      forced: %d", st.calls, st.hits))
    local left = st.pulse_until - st.frames
    if left > 0 then
        imgui.text(string.format("PULSE ACTIVE  %d frames left", left))
    end
    imgui.text(string.format("pulses:  %d", st.pulses_fired))
    local first = math.max(1, #st.pulses - 2)
    for i = first, #st.pulses do
        local p = st.pulses[i]
        imgui.text(string.format("  #%d %s  uses %s -> %s  %s",
            p.index, tostring(p.clock), tostring(p.uses_before),
            tostring(p.uses_after), tostring(p.followed)))
    end
    imgui.separator()
    if imgui.button("Trigger now (6 s)") then
        pulse()
    end
    imgui.text("press when the horn is off cooldown and the buff is down")
    imgui.separator()
    changed, st.armed = imgui.checkbox("Or hold desire on permanently", st.armed)
    if changed then
        log.info(TAG .. " armed -> " .. tostring(st.armed))
        flush()
    end
    imgui.text("file: " .. FILE)
end

re.on_draw_ui(function()
    if not imgui.tree_node("Otomo Desire v" .. VERSION) then return end
    local ok, err = pcall(draw_body)
    safe(function() imgui.tree_pop() end)
    if not ok then log.info(TAG .. " draw error: " .. tostring(err)) end
end)

log.info(TAG .. " loaded v" .. VERSION)
