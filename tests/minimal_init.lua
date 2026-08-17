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

-- blink.cmp は tests/blink_source_spec.lua が「rtp にあれば実行、無ければ
-- pending」で自己判定する外部プラグイン依存（このリポジトリはblink.cmp
-- を同梱しない）。BLINK_DIR 環境変数（PLENARY_DIR と同じ考え方）でパスを
-- 指定すると、その分のテストも実際に実行されるようになる。
local blink_dir = first_existing({
  os.getenv("BLINK_DIR"),
  os.getenv("HOME") .. "/.local/share/nvim/lazy/blink.cmp", -- lazy.nvim を個人環境で使っている場合
})
if blink_dir then
  vim.opt.runtimepath:append(blink_dir)
end

vim.cmd("runtime plugin/plenary.vim")
