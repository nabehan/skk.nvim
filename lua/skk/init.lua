-- lua/skk/init.lua
--
-- プラグインのエントリーポイント。
-- require("skk").setup() を呼ぶと vim.on_key() のリスナーが登録され、
-- <C-j>（挿入モード）で有効/無効をトグルできるようになる。

local capture = require("skk.capture")

local M = {}

---@class SkkSetupOpts
---@field toggle_key string? デフォルト "<C-j>"

---@param opts SkkSetupOpts|nil
function M.setup(opts)
  opts = opts or {}
  local toggle_key = opts.toggle_key or "<C-j>"

  capture.setup()

  vim.keymap.set("i", toggle_key, function()
    local enabled = capture.toggle()
    vim.notify("skk.lua: " .. (enabled and "ON" or "OFF"))
  end, { desc = "Toggle skk.lua" })

  vim.api.nvim_create_user_command("SkkToggle", function()
    local enabled = capture.toggle()
    vim.notify("skk.lua: " .. (enabled and "ON" or "OFF"))
  end, {})
end

return M
