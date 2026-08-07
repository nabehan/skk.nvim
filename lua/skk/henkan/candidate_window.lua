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
--- page_candidates() の配列インデックス（1〜7）と対応する。
--- 【注意】`;` は Sticky-shift のトリガーキーと衝突するため含めない。
M.HOME_ROW_KEYS = { "a", "s", "d", "f", "j", "k", "l" }

---@type integer|nil
local win = nil
---@type integer|nil
local buf = nil

--- 見た目の設定。lua/skk/init.lua の M.setup({ candidate_window = {...} }) から
--- 差し込む。border は nvim_open_win() の "border" と同じ形式を受け付ける
--- （"rounded"/"single"/"double"/"none"/自前の文字配列 等）。
---@type { border: string|string[] }
local config = { border = "rounded" }

--- 見た目のオプションを設定する。lua/skk/init.lua から setup() 時に呼ばれる。
--- 未指定のキーはデフォルト値のまま維持する。
---@param opts { border: string|string[] }|nil
function M.setup(opts)
  opts = opts or {}
  if opts.border ~= nil then
    config.border = opts.border
  end
end

-- ===================================================================
-- テキスト整形（vim.* 非依存、単体テスト可能）
-- ===================================================================

--- 候補一覧を "a: 候補" 形式の行配列に整形する。アノテーションがあれば
--- "a: 候補 ;注釈" のように末尾に付与する（SKK辞書の生の記法 "候補;注釈"
--- に揃えている）。
---@param candidates SkkDictCandidate[] 最大7件（Session:page_candidates() の返り値）
---@return string[] lines
local function format_lines(candidates)
  local lines = {}
  for i, candidate in ipairs(candidates) do
    local key = M.HOME_ROW_KEYS[i]
    if key then
      local line = key .. ": " .. candidate.word
      if candidate.annotation then
        line = line .. " ;" .. candidate.annotation
      end
      table.insert(lines, line)
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

--- border 設定によって、フローティングウィンドウが実際に食う「枠線の
--- 行数」（上下合計）を返す。"none"（または border 無し）なら 0、
--- それ以外（"rounded"/"single"/"double"/"solid"/自前の文字配列 等）は
--- 上下1行ずつ、計2行を消費する。
---@return integer
local function border_row_overhead()
  if config.border == nil or config.border == "none" then
    return 0
  end
  return 2
end

--- アンカー行の画面上の位置を見て、候補ウィンドウをアンカー行の下に
--- 出すか上に出すかを決める。
--- 下に十分な行数（枠線込みのウィンドウ全体の高さ）が無ければ、上に出す
--- （プレエディットと重なって表示されてしまうのを避けるため）。
---
--- 【行数の考え方（実測で確認済み）】vim.o.lines はコマンドライン分を
--- 含んだ画面全体の行数（例: 20行端末なら 20）。screenpos() が返す行番号も
--- 同じ基準（1-indexed、端末そのまま）なので、コマンドラインの直前の行までが
--- 使える範囲 = (vim.o.lines - cmdheight)。ステータスライン分はあえて
--- 引かない（フローティングウィンドウはステータスラインの上に重ねて
--- 描画できるため、コマンドラインさえ避ければ良い）。
---@param anchor_win integer
---@param anchor_row integer 0-indexed
---@param content_height integer 候補一覧の行数（枠線を含まない）
---@return "NW"|"SW" anchor_corner
---@return integer row_offset bufpos からの行オフセット
local function compute_placement(anchor_win, anchor_row, content_height)
  local ok, screen = pcall(vim.fn.screenpos, anchor_win, anchor_row + 1, 1)
  if not ok or not screen or screen.row == 0 then
    -- 取得に失敗した場合は、従来通り下に出す（フォールバック）。
    return "NW", 1
  end

  local total_height = content_height + border_row_overhead()

  -- アンカー行より下に残っている画面行数（コマンドライン分は使えないので除く）。
  local available_below = (vim.o.lines - vim.o.cmdheight) - screen.row
  if available_below >= total_height then
    return "NW", 1 -- アンカー行のすぐ下
  end

  -- 上に出す場合も、画面上端をはみ出さないか一応確認する
  -- （はみ出す場合でも、無限ループを避けるため下に出すフォールバックのまま）。
  local available_above = screen.row - 1
  if available_above >= total_height then
    return "SW", 0 -- 下に入りきらないので、アンカー行のすぐ上（下端を接する）
  end

  return "NW", 1 -- 上下どちらにも入りきらない極端なケース。下に出す。
end

M._compute_placement = compute_placement
-- 【注意】_compute_placement は screenpos() に依存するため、`nvim --headless`
-- （UIが接続されていない）環境では正しい値を返さない（screenpos が常に
-- row=0 を返す）。実機の Neovim（TUI/GUIが接続された状態）でのみ
-- 意味のある検証ができる。

--- 候補一覧を、アンカー位置（変換プレエディットのカーソル位置）の
--- すぐ下（入りきらなければ上）にフローティングウィンドウで表示する。
--- 既に表示中なら、内容とサイズだけ更新する（ウィンドウを開き直さない）。
---@param anchor_win integer 基準となるウィンドウID
---@param anchor_row integer 0-indexed の行
---@param anchor_col integer 0-indexed の列
---@param candidates SkkDictCandidate[] 現在ページの候補一覧（最大7件）
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
  local height = #lines

  local anchor_corner, row_offset = compute_placement(anchor_win, anchor_row, height)

  local win_config = {
    relative = "win",
    win = anchor_win,
    bufpos = { anchor_row, anchor_col },
    anchor = anchor_corner,
    row = row_offset,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = config.border,
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
