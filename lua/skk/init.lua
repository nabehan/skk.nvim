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
---@field sticky_shift_enabled boolean? Sticky-shift（大文字キーを使わずに ▽開始・送り開始点を
---  指示する操作）の有効/無効。デフォルト true。
---@field sticky_shift_key string? Sticky-shift のトリガーキー。デフォルト ";"。
---  sticky_shift_enabled=false のときは無視される。
---@field egg_like_newline boolean? true: ▼状態での <CR> は確定のみ行い、改行は挿入しない
---  （skk.nvimのデフォルト）。false: 確定に加えて改行も挿入する（SKK本来の動作）。デフォルト true。
---@field candidate_window { border: string|string[], annotation: boolean }? 候補一覧ウィンドウの見た目。
---  border は nvim_open_win() の "border" と同じ形式（"rounded"/"single"/"double"/
---  "none"/自前の文字配列 等）。デフォルト "rounded"。
---  annotation: 辞書の注釈（";注釈"）を候補一覧に表示するか。デフォルト true。

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
  capture.setup({
    sticky_shift_enabled = opts.sticky_shift_enabled,
    sticky_shift_key = opts.sticky_shift_key,
    egg_like_newline = opts.egg_like_newline,
  })
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
