#!/usr/bin/sh

PLENARY_DIR=~/.local/share/nvim/lazy/plenary.nvim nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"
