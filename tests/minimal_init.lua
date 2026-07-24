-- tests/minimal_init.lua
--
-- plenary.nvim のテストランナーを headless で動かすための最小 init。
-- 使い方（推奨）:
--   make test
--   （Makefile が .tests/site/pack/deps/start/plenary.nvim に plenary.nvim を
--    自動で clone してから、このファイル経由でテストを実行する）
--
-- 手動で使う場合:
--   nvim --headless --noplugin -u tests/minimal_init.lua \
--     -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"

local function first_existing(paths)
  for _, path in ipairs(paths) do
    if path ~= nil and vim.fn.isdirectory(path) == 1 then
      return path
    end
  end
  return nil
end

local plenary_dir = first_existing({
  os.getenv("PLENARY_DIR"),
  vim.fn.getcwd() .. "/.tests/site/pack/deps/start/plenary.nvim", -- Makefile の deps 先
  os.getenv("HOME") .. "/.local/share/nvim/lazy/plenary.nvim", -- lazy.nvim を個人環境で使っている場合
})

if not plenary_dir then
  error(
    "plenary.nvim が見つかりません。`make test` を実行するか、"
      .. "PLENARY_DIR 環境変数で plenary.nvim のパスを指定してください。"
  )
end

vim.opt.runtimepath:append(".")
vim.opt.runtimepath:append(plenary_dir)

vim.cmd("runtime plugin/plenary.vim")
