-- lua/skk/mode_indicator.lua
--
-- 入力モードが切り替わった瞬間、カーソル位置にフローティングウィンドウで
-- 現在のモードを示すグリフ（あ/ア/A/Ａ）を一瞬だけ表示する。
--
-- 表示するのは capture.lua がモードを切り替えたタイミング（l/q/L や
-- <C-j>）だけで、実際に次のキー入力があった時点で消す
-- （capture.lua の on_key() が毎回呼び出す M.hide() が担当する）。
--
-- 【設計方針】lua/skk/henkan/candidate_window.lua と同様、モジュール
-- 読み込み時（トップレベル）に vim.api を呼ばない。ウィンドウ/バッファは
-- 初回表示時に遅延生成する。

local M = {}

--- モード名 -> 表示するグリフ。
---@type table<SkkMode, string>
M.GLYPHS = {
  hira = "ひら",
  kata = "カタ",
  ascii = "abcd",
  zenei = "ＡＢ",
}

---@type integer|nil
local win = nil
---@type integer|nil
local buf = nil

---@return integer
local function get_buf()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
  end
  return buf
end

--- 現在のカーソル位置にモードインジケーターを表示する。
--- 対応するグリフが無いモードが渡されたら何もしない。
---@param mode SkkMode
function M.show(mode)
  local glyph = M.GLYPHS[mode]
  if not glyph then
    return
  end

  local b = get_buf()
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { glyph })

  local win_config = {
    relative = "cursor",
    row = 1,
    col = 0,
    width = 4, -- 全角グリフ2文字ぶん
    height = 1,
    style = "minimal",
    border = "none",
    focusable = false,
  }

  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_config(win, win_config)
  else
    win_config.noautocmd = true
    win = vim.api.nvim_open_win(b, false, win_config)
  end
end

--- インジケーターを消す。実際の入力があった時点（capture.lua の
--- on_key() の先頭）で毎回呼ばれる。表示していなければ何もしない。
function M.hide()
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  win = nil
end

return M
