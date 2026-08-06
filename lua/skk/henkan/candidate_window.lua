-- lua/skk/henkan/candidate_window.lua
--
-- ▼ 候補選択中に出す、複数候補一覧のフローティングウィンドウ。
--
-- 【操作仕様】
--   ・1ページ最大8候補。ホームポジション a s d f j k l ; を上から
--     順に割り当て、そのキーを押すと即座にその候補を選択・確定する。
--   ・<SPC> で次の8候補（次ページ）、x で前の8候補（前ページ）に切り替える。
--   ・実際のキー処理（どのキーが来たら何をするか）は lua/skk/capture.lua と
--     lua/skk/henkan/state.lua が担当する。このモジュールは「表示」だけに
--     専念する（session:page_candidates() が返す配列を描画するだけで、
--     ページ送りや選択のロジックは持たない）。
--
-- 【設計方針】lua/skk/henkan/preedit.lua と同様、モジュール読み込み時
-- （トップレベル）に vim.api を呼ばない。vim グローバルの無い環境
-- （lua5.4/luajit だけのテストサンドボックス等）で require しただけで
-- クラッシュするのを避けるため、ウィンドウ/バッファは初回表示時に
-- 遅延生成する。

local M = {}

--- ホームポジションキーを上から順に並べたもの。
--- page_candidates() の配列インデックス（1〜8）と対応する。
M.HOME_ROW_KEYS = { "a", "s", "d", "f", "j", "k", "l", ";" }

---@type integer|nil
local win = nil
---@type integer|nil
local buf = nil

-- ===================================================================
-- テキスト整形（vim.* 非依存、単体テスト可能）
-- ===================================================================

--- 候補一覧を "a: 候補" 形式の行配列に整形する。
--- 【注意】辞書のアノテーション（候補の注釈）は phase 3 時点の
--- jisyo_parser でまだ保持していない（parse 時に切り捨てている）ため、
--- ここではまだ表示できない。アノテーション対応は別タスクとする。
---@param candidates string[] 最大8件（Session:page_candidates() の返り値）
---@return string[] lines
local function format_lines(candidates)
  local lines = {}
  for i, candidate in ipairs(candidates) do
    local key = M.HOME_ROW_KEYS[i]
    if key then
      table.insert(lines, key .. ": " .. candidate)
    end
  end
  return lines
end

M._format_lines = format_lines -- テストから直接検証できるように公開しておく

-- ===================================================================
-- フローティングウィンドウ表示（vim.* 依存）
-- ===================================================================

---@return integer
local function get_buf()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
  end
  return buf
end

--- 候補一覧を、アンカー位置（変換プレエディットのカーソル位置）の
--- すぐ下にフローティングウィンドウで表示する。既に表示中なら、
--- 内容とサイズだけ更新する（ウィンドウを開き直さない）。
---@param anchor_win integer 基準となるウィンドウID
---@param anchor_row integer 0-indexed の行
---@param anchor_col integer 0-indexed の列
---@param candidates string[] 現在ページの候補一覧（最大8件）
function M.show(anchor_win, anchor_row, anchor_col, candidates)
  if #candidates == 0 then
    M.hide()
    return
  end

  local lines = format_lines(candidates)
  local b = get_buf()
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)

  local width = 1
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end

  local win_config = {
    relative = "win",
    win = anchor_win,
    bufpos = { anchor_row, anchor_col },
    row = 1,
    col = 0,
    width = width,
    height = #lines,
    style = "minimal",
    border = "rounded",
    focusable = false,
    noautocmd = true,
  }

  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_config(win, win_config)
  else
    win = vim.api.nvim_open_win(b, false, win_config)
  end
end

--- ウィンドウを閉じる。確定・キャンセル・ページ移動で候補が0件に
--- なった場合等に呼ぶ。
function M.hide()
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  win = nil
end

return M
