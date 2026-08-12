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

local target = require("skk.target")

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

--- 【コマンドラインモード用】コマンドラインには extmark が存在しないため、
--- ▽/▼ の表示は「コマンドライン文字列そのものへの直接書き込み」で
--- 実現する（ddskk/skkeleton と同様の方式）。anchor 時点の getcmdpos()
--- （1-indexed）を cmdline_anchor_pos に記録し、以降その位置に表示中の
--- マーカーテキストのバイト長を cmdline_shown_len で追跡する。更新の
--- たびに「今表示している分だけ消して、新しいテキストを差し込む」を
--- 繰り返す。
---@type integer|nil
local cmdline_anchor_pos = nil
---@type integer|nil
local cmdline_shown_len = nil

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

--- 表示の基準位置を記録する。▽/abbrev 開始時に呼ぶ。
--- バッファモードなら現在のカーソル位置、コマンドラインモードなら
--- 現在の getcmdpos() を基準にする。
function M.anchor()
  if target.kind() == "cmdline" then
    cmdline_anchor_pos = vim.fn.getcmdpos()
    cmdline_shown_len = 0
    anchor_bufnr = nil
    anchor_win = nil
    anchor_row = nil
    anchor_col = nil
    return
  end

  local win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(win)
  anchor_bufnr = vim.api.nvim_win_get_buf(win)
  anchor_win = win
  anchor_row = cursor[1] - 1
  anchor_col = cursor[2]
  cmdline_anchor_pos = nil
  cmdline_shown_len = nil
end

---@return boolean
function M.is_anchored()
  return anchor_row ~= nil or cmdline_anchor_pos ~= nil
end

---@param text string
---@param hl_group string
local function set_virtual_text(text, hl_group)
  if cmdline_anchor_pos ~= nil then
    -- コマンドラインには extmark も highlight group による装飾も無いので
    -- （プレーンなテキストとして扱う）、hl_group は使わない。
    local line = vim.fn.getcmdline()
    local shown_len = cmdline_shown_len or 0
    local new_line = line:sub(1, cmdline_anchor_pos - 1) .. text .. line:sub(cmdline_anchor_pos + shown_len)
    vim.fn.setcmdline(new_line, cmdline_anchor_pos + #text)
    cmdline_shown_len = #text
    return
  end

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
--- コマンドラインモードでは、表示していたマーカーテキストをコマンドライン
--- 文字列から実際に削除して元に戻す（extmarkと違い、コマンドラインの
--- テキストは仮想ではなく実体そのものなので、消すには削除する必要がある）。
function M.hide()
  if cmdline_anchor_pos ~= nil then
    local shown_len = cmdline_shown_len or 0
    if shown_len > 0 then
      local line = vim.fn.getcmdline()
      local new_line = line:sub(1, cmdline_anchor_pos - 1) .. line:sub(cmdline_anchor_pos + shown_len)
      vim.fn.setcmdline(new_line, cmdline_anchor_pos)
    end
    cmdline_anchor_pos = nil
    cmdline_shown_len = nil
    return
  end

  if mark_id and anchor_bufnr then
    pcall(vim.api.nvim_buf_del_extmark, anchor_bufnr, get_ns(), mark_id)
  end
  mark_id = nil
  anchor_bufnr = nil
  anchor_win = nil
  anchor_row = nil
  anchor_col = nil
end

--- 【コマンドラインモード専用】現在コマンドラインに表示中のマーカー
--- テキストのバイト長。バッファモード、または何も表示していない場合は 0。
--- state.lua の confirm_text() が、確定テキストで置き換えるべき範囲
--- （= target.replace_before_cursor() に渡す byte_len）を知るために使う。
---@return integer
function M.pending_cmdline_byte_len()
  return cmdline_shown_len or 0
end

--- 【コマンドラインモード専用】内部の追跡状態だけをクリアする。
--- M.hide() と違い、表示中のマーカーテキストには一切触れない
--- （呼び出し側がこの直後に target.replace_before_cursor() で実際の
--- 置き換えを行う前提。state.lua の confirm_text() 参照）。
function M.clear_cmdline_tracking()
  cmdline_anchor_pos = nil
  cmdline_shown_len = nil
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
