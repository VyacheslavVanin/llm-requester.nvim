#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

exec nvim --headless -u NONE \
    -c "set rtp+=." \
    -c "luafile tests/run.lua"
