-- lua/skk/init.lua
--
-- プラグインのエントリーポイント。
-- require("skk").setup() を呼ぶと vim.on_key() のリスナーが登録され、
-- <C-j>（挿入モード）でひらがなモードに入れるようになる。
-- l/q/L によるモード切替は lua/skk/capture.lua の vim.on_key() 側で処理する。

local capture = require("skk.capture")

local M = {}

---@class SkkSetupOpts
---@field enter_key string? 半角英数/全角英数 -> ひらがな。デフォルト "<C-j>"

---@param opts SkkSetupOpts|nil
function M.setup(opts)
  opts = opts or {}
  local enter_key = opts.enter_key or "<C-j>"

  capture.setup()

  local function notify_mode()
    vim.notify("skk.nvim: " .. capture.mode_label())
  end

  vim.keymap.set("i", enter_key, function()
    if capture.transition(enter_key) then
      notify_mode()
    end
  end, { desc = "skk.nvim: enter hiragana mode" })

  vim.api.nvim_create_user_command("SkkMode", function()
    notify_mode()
  end, {})
end

return M
