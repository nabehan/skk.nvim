#!/usr/bin/sh

BLINK_DIR=~/.local/share/nvim/lazy/blink.cmp PLENARY_DIR=~/.local/share/nvim/lazy/plenary.nvim nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}" >./test.log

# PLENARY_DIR=~/.local/share/nvim/lazy/plenary.nvim nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}" >./test.log

cat ./test.log | rg Failed

cat ./test.log | rg Errors

echo "test.log が 更新されました"
