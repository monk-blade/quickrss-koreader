#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export QUICKRSS_ROOT="$ROOT/"

LUA=""
for candidate in lua5.1 lua luajit; do
    if command -v "$candidate" >/dev/null 2>&1; then
        LUA="$candidate"
        break
    fi
done

if [[ -z "$LUA" ]]; then
    echo "No Lua interpreter found. Install lua5.1 (sudo apt install lua5.1) or run ./scripts/install-deps.sh" >&2
    exit 1
fi

echo "Using $LUA"
"$LUA" tests/test_opml.lua
"$LUA" tests/test_parser.lua
"$LUA" tests/test_text_util.lua
"$LUA" tests/test_html_cleanup.lua

if command -v luacheck >/dev/null 2>&1; then
    echo "Running luacheck…"
    luacheck quickrss.koplugin/
else
    echo "luacheck not installed — skip (install with: sudo apt install lua-check)"
fi

echo "All tests passed."
