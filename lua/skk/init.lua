-- lua/skk/init.lua
--
-- プラグインのエントリーポイント。
-- require("skk").setup() を呼ぶと vim.on_key() のリスナーが登録され、
-- <C-j>（挿入モード）でひらがなモードに入れるようになる。
-- ▽/▼ (henkan) がアクティブな間は、<C-j> は <CR> と同じく確定として扱う。
-- l/q/L によるモード切替は lua/skk/capture.lua の vim.on_key() 側で処理する。

local capture = require("skk.capture")
local henkan_state = require("skk.henkan.state")
local candidate_window = require("skk.henkan.candidate_window")

local M = {}

---@class SkkSetupOpts
---@field enter_key string? 半角英数/全角英数 -> ひらがな。henkan 中は確定。デフォルト "<C-j>"
---@field candidate_window { border: string|string[] }? 候補一覧ウィンドウの見た目。
---  border は nvim_open_win() の "border" と同じ形式（"rounded"/"single"/"double"/
---  "none"/自前の文字配列 等）。デフォルト "rounded"。

--- ▽/▼ 表示用のハイライトグループのデフォルトを定義する。
--- 既にユーザーやカラースキームが定義済みなら上書きしない (default = true)。
local function setup_highlights()
  vim.api.nvim_set_hl(0, "SkkHenkanMidashi", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "SkkHenkanCandidate", { default = true, link = "IncSearch" })
end

---@param opts SkkSetupOpts|nil
function M.setup(opts)
  opts = opts or {}
  local enter_key = opts.enter_key or "<C-j>"

  setup_highlights()
  capture.setup()
  candidate_window.setup(opts.candidate_window or {})

  local function notify_mode()
    vim.notify("skk.nvim: " .. capture.mode_label())
  end

  vim.keymap.set("i", enter_key, function()
    -- henkan (▽/▼) がアクティブな間は、<C-j> も <CR> と同じ「確定」として扱う。
    if henkan_state.is_active() then
      henkan_state.confirm()
      return
    end
    if capture.transition(enter_key) then
      notify_mode()
    end
  end, { desc = "skk.nvim: enter hiragana mode / confirm henkan" })

  vim.api.nvim_create_user_command("SkkMode", function()
    notify_mode()
  end, {})
end

return M
