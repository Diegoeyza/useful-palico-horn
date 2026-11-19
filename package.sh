#!/usr/bin/env bash
# Build shareable bundles into dist/. Two sibling mods, one repo:
#
#   otomo_tools.lua  Otomo Tools  - cooldown tuning + horn counter (data only)
#   otomo_horn.lua   Otomo Horn   - fires the horn action on command (hotkey)
#
# For each: a flat zip (just the lua + notes) and a Nexus/Vortex zip laid out
# for the game folder. The probes in tools/ and the tests are never packaged.
set -euo pipefail
cd "$(dirname "$0")"

command -v zip >/dev/null || { echo "error: 'zip' is required" >&2; exit 1; }

DIST="dist"
rm -rf "$DIST"
mkdir -p "$DIST"

version_of() {
    local file="$1"
    local v
    v="$(sed -n 's/^local VERSION = "\([^"]*\)".*/\1/p' "$file" | head -1)"
    [ -n "$v" ] || { echo "error: VERSION not found in $file" >&2; exit 1; }
    printf '%s' "$v"
}

# package <lua file> <flat zip base> <nexus zip base> <nexus readme>
package() {
    local lua="$1" flat="$2" nexus="$3" readme="$4"
    [ -f "$lua" ] || { echo "error: $lua not found" >&2; exit 1; }
    local v name
    v="$(version_of "$lua")"
    name="$(basename "$lua")"

    mkdir -p "$DIST/flat"
    cp "$lua" "$DIST/flat/$name"
    cp reframework/INSTALL.txt "$DIST/flat/INSTALL.txt"
    ( cd "$DIST/flat" && zip -q "../${flat}-${v}.zip" "$name" INSTALL.txt )
    rm -rf "$DIST/flat"

    mkdir -p "$DIST/nexus/reframework/autorun"
    cp "$lua" "$DIST/nexus/reframework/autorun/$name"
    cp "$readme" "$DIST/nexus/README.txt"
    ( cd "$DIST/nexus" && zip -q -r "../${nexus}-${v}.zip" . )
    rm -rf "$DIST/nexus"
}

package "reframework/otomo_tools.lua" "otomo-tools" "OtomoTools" "packaging/nexus/README.txt"
package "reframework/otomo_horn.lua" "otomo-horn" "OtomoHorn" "packaging/nexus/README-horn.txt"

echo "Built into $DIST/:"
ls -1 "$DIST"
