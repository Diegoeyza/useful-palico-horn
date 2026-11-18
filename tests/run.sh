#!/bin/sh
# Run the offline tests under Lua 5.1 (the game's LuaJIT is 5.1).
#
#   tests/logic_test.lua     pure logic: config normalisation, presets, tick
#                            schedule, quest gate, reset planning, round trip
#   tests/pipeline_test.lua  the real tick() against a fake REFramework world:
#                            gating, guarded calls, the tri-state "unknown means
#                            no write" rule, and the manager dropped at quest end
#
# LUA=/path/to/lua ./tests/run.sh
set -e
cd "$(dirname "$0")/.."

LUA_BIN="${LUA:-}"
if [ -z "$LUA_BIN" ]; then
    for candidate in /tmp/opencode/lua51/lua lua5.1 luajit lua; do
        if [ -x "$candidate" ] || command -v "$candidate" >/dev/null 2>&1; then
            LUA_BIN="$candidate"
            break
        fi
    done
fi
if [ -z "$LUA_BIN" ]; then
    echo "no Lua 5.1 interpreter found; set LUA=/path/to/lua5.1" >&2
    exit 2
fi

# A misplaced `local` turns a table into a nil global and every test still
# passes, because the fake world sets it. Catch that here.
LUAC_BIN="${LUAC:-}"
if [ -z "$LUAC_BIN" ] && [ -x "$(dirname "$LUA_BIN")/luac" ]; then
    LUAC_BIN="$(dirname "$LUA_BIN")/luac"
fi
if [ -n "$LUAC_BIN" ]; then
    "$LUAC_BIN" -p reframework/otomo_tools.lua || exit 1
    EXPECTED_GLOBALS="_G imgui ipairs json log math next os pairs pcall re sdk string table tonumber tostring type"
    seen=$("$LUAC_BIN" -l -p reframework/otomo_tools.lua \
        | sed -n 's/.*GETGLOBAL.*; //p; s/.*GETGLOBAL.*- *[0-9][0-9]* *; //p' \
        | sort -u | tr '\n' ' ')
    extra=""
    for g in $seen; do
        case " $EXPECTED_GLOBALS " in
            *" $g "*) ;;
            *) extra="$extra $g" ;;
        esac
    done
    if [ -n "$extra" ]; then
        echo "unexpected globals in the mod:$extra" >&2
        exit 1
    fi
else
    echo "note: no luac next to $LUA_BIN, skipping the globals check" >&2
fi

status=0
for test_file in tests/logic_test.lua tests/pipeline_test.lua; do
    echo "== $test_file"
    "$LUA_BIN" "$test_file" || status=1
done
exit "$status"
