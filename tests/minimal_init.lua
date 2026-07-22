-- tests/minimal_init.lua
--
-- plenary.nvim のテストランナーを headless で動かすための最小 init。
-- 使い方:
--   nvim --headless --noplugin -u tests/minimal_init.lua \
--     -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"

local plenary_dir = os.getenv("PLENARY_DIR") or (os.getenv("HOME") .. "/.local/share/nvim/lazy/plenary.nvim")

vim.opt.runtimepath:append(".")
vim.opt.runtimepath:append(plenary_dir)

vim.cmd("runtime plugin/plenary.vim")
