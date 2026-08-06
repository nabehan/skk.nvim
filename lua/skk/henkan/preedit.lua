-- lua/skk/henkan/preedit.lua
--
-- ▽（読み入力中）/▼（候補選択中）の見た目を extmark の仮想テキストで表示する。
--
-- 【設計方針】変換セッション中は実バッファに一切書き込まない。
-- 確定するまでは全て extmark の virt_text（inline）で表示するだけにする。
-- こうすることで、<BS> による読みの取り消し等も「session.reading を
-- 1文字削って表示を更新するだけ」で済み、実バッファの操作が絡まない
-- ぶん安全になる（lua/skk/capture.lua で <BS>/<Delete> により実害のある
-- バグを踏んだ教訓を踏まえた設計）。
--
-- 表示位置は M.anchor() を呼んだ時点のカーソル位置に固定する
-- （変換中はその位置に仮想テキストを出し続け、カーソル自体は動かさない）。

local M = {}

---@type integer|nil
local ns = nil
---@type integer|nil
local mark_id = nil
---@type integer|nil
local anchor_bufnr = nil
---@type integer|nil
local anchor_win = nil
---@type integer|nil
local anchor_row = nil
---@type integer|nil
local anchor_col = nil

--- namespace は初回使用時に遅延生成する。モジュール読み込み時（トップ
--- レベル）に vim.api を呼んでしまうと、vim グローバルが存在しない
--- 環境（lua5.4/luajit だけのテストサンドボックス等）で require した
--- だけでクラッシュしてしまうため。
---@return integer
local function get_ns()
  if not ns then
    ns = vim.api.nvim_create_namespace("skk_henkan_preedit")
  end
  return ns
end

-- ===================================================================
-- テキスト整形（vim.* 非依存、単体テスト可能）
-- ===================================================================

--- ▽ 表示用のテキストを組み立てる。
--- 送り開始点が指定されていれば "▽よみ*子音" の形式にする。
---@param reading string
---@param okuri_consonant string|nil
---@return string
local function midashi_text(reading, okuri_consonant)
  local text = "▽" .. reading
  if okuri_consonant and okuri_consonant ~= "" then
    text = text .. "*" .. okuri_consonant
  end
  return text
end

--- ▼ 表示用のテキストを組み立てる。
--- okurigana は既に現在のモード（ひらがな/カタカナ）に応じて
--- 変換済みの文字列を渡す想定（変換自体はこのモジュールの責務ではない）。
---@param candidate string
---@param okurigana string|nil
---@return string
local function henkan_text(candidate, okurigana)
  return "▼" .. candidate .. (okurigana or "")
end

--- abbrev モード（"/" 開始）の見出し表示用テキスト。
---@param reading string
---@return string
local function abbrev_text(reading)
  return "▽" .. reading
end

M._midashi_text = midashi_text -- テストから直接検証できるように公開しておく
M._henkan_text = henkan_text
M._abbrev_text = abbrev_text

-- ===================================================================
-- extmark 表示（vim.* 依存）
-- ===================================================================

--- 表示の基準位置（現在のカーソル位置）を記録する。▽/abbrev 開始時に呼ぶ。
function M.anchor()
  local win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(win)
  anchor_bufnr = vim.api.nvim_win_get_buf(win)
  anchor_win = win
  anchor_row = cursor[1] - 1
  anchor_col = cursor[2]
end

---@return boolean
function M.is_anchored()
  return anchor_row ~= nil
end

---@param text string
---@param hl_group string
local function set_virtual_text(text, hl_group)
  if not anchor_row or not anchor_bufnr then
    return
  end
  if mark_id then
    pcall(vim.api.nvim_buf_del_extmark, anchor_bufnr, get_ns(), mark_id)
  end
  mark_id = vim.api.nvim_buf_set_extmark(anchor_bufnr, get_ns(), anchor_row, anchor_col, {
    virt_text = { { text, hl_group } },
    virt_text_pos = "inline",
    right_gravity = false,
  })
end

--- ▽ (読み入力中) を表示する。
---@param reading string
---@param okuri_consonant string|nil
function M.show_midashi(reading, okuri_consonant)
  set_virtual_text(midashi_text(reading, okuri_consonant), "SkkHenkanMidashi")
end

--- ▼ (候補選択中) を表示する。
---@param candidate string
---@param okurigana string|nil
function M.show_henkan(candidate, okurigana)
  set_virtual_text(henkan_text(candidate, okurigana), "SkkHenkanCandidate")
end

--- abbrev モード ("/" 開始) の読み入力中表示。
---@param reading string
function M.show_abbrev(reading)
  set_virtual_text(abbrev_text(reading), "SkkHenkanMidashi")
end

--- 表示を消す。確定・キャンセル時に呼ぶ。
function M.hide()
  if mark_id and anchor_bufnr then
    pcall(vim.api.nvim_buf_del_extmark, anchor_bufnr, get_ns(), mark_id)
  end
  mark_id = nil
  anchor_bufnr = nil
  anchor_win = nil
  anchor_row = nil
  anchor_col = nil
end

--- 確定時に実バッファへ挿入すべき位置（アンカー位置）を返す。
--- lua/skk/henkan/state.lua が確定処理で使う。
---@return integer|nil bufnr
---@return integer|nil row0
---@return integer|nil col
function M.anchor_position()
  return anchor_bufnr, anchor_row, anchor_col
end

--- アンカー位置を記録した時点のウィンドウID。候補選択ウィンドウ
--- （lua/skk/henkan/candidate_window.lua）を relative="win" で
--- 配置するために必要。
---@return integer|nil
function M.anchor_win()
  return anchor_win
end

return M
