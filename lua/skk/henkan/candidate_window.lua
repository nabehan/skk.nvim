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

local target = require("skk.target")

--- ホームポジションキーを上から順に並べたもの。
--- page_candidates() の配列インデックス（1〜7）と対応する。
--- 【注意】`;` は Sticky-shift のトリガーキーと衝突するため含めない。
M.HOME_ROW_KEYS = { "a", "s", "d", "f", "j", "k", "l" }

---@type integer|nil
local win = nil
---@type integer|nil
local buf = nil
---@type integer|nil
local ns = nil
--- 現在の変換セッション中に一度決めた配置（"NW"=下, "SW"=上）を覚えて
--- おき、ウィンドウが開いている間は使い回す（sticky）。<SPC> でページを
--- 送って候補数が減り、本来なら下にも収まるようになった場合でも、一度
--- 上に出したなら上に出し続ける。視線移動を減らすための仕様
--- （ユーザーからのフィードバックで判明した挙動）。
--- ウィンドウを閉じたとき（M.hide()）にリセットし、次の変換セッションでは
--- 改めて計算し直す。
---@type "NW"|"SW"|nil
local sticky_corner = nil
---@type integer|nil
local sticky_row_offset = nil

--- 見た目の設定。lua/skk/init.lua の M.setup({ candidate_window = {...} }) から
--- 差し込む。border は nvim_open_win() の "border" と同じ形式を受け付ける
--- （"rounded"/"single"/"double"/"none"/自前の文字配列 等）。
--- annotation は候補一覧ウィンドウにアノテーション（辞書の ";注釈"）を
--- 表示するかどうか。page_indicator は最下行の "現在ページ/全ページ数"
--- （例: "2/3"）を表示するかどうか。
---@type { border: string|string[], annotation: boolean, page_indicator: boolean }
local config = { border = "rounded", annotation = true, page_indicator = true }

--- 候補ウィンドウ用のハイライトグループのデフォルトを定義する。
--- fg/bg/border_fg/border_bg/alt_fg/alt_bg のいずれかが指定されていれば、
--- そのグループはリンクではなく直接その色で定義する。指定が無いグループは
--- 標準のフロートウィンドウ用グループ（NormalFloat/FloatBorder）に
--- リンクしたままにする（＝カラースキーム任せ、現状と同じ見た目）。
--- SkkCandidateWindowNormalAlt（1行おきの縞模様用）は、alt_fg/alt_bg が
--- 無指定なら SkkCandidateWindowNormal 自体にリンクする（＝縞なし）。
---@param opts { fg: string?, bg: string?, border_fg: string?, border_bg: string?, alt_fg: string?, alt_bg: string? }
local function setup_highlights(opts)
  if opts.fg or opts.bg then
    vim.api.nvim_set_hl(0, "SkkCandidateWindowNormal", { fg = opts.fg, bg = opts.bg })
  else
    vim.api.nvim_set_hl(0, "SkkCandidateWindowNormal", { default = true, link = "NormalFloat" })
  end
  if opts.border_fg or opts.border_bg then
    vim.api.nvim_set_hl(0, "SkkCandidateWindowBorder", { fg = opts.border_fg, bg = opts.border_bg })
  else
    vim.api.nvim_set_hl(0, "SkkCandidateWindowBorder", { default = true, link = "FloatBorder" })
  end
  if opts.alt_fg or opts.alt_bg then
    vim.api.nvim_set_hl(0, "SkkCandidateWindowNormalAlt", { fg = opts.alt_fg, bg = opts.alt_bg })
  else
    vim.api.nvim_set_hl(0, "SkkCandidateWindowNormalAlt", { default = true, link = "SkkCandidateWindowNormal" })
  end
end

--- 見た目のオプションを設定する。lua/skk/init.lua から setup() 時に呼ばれる。
--- 未指定のキーはデフォルト値のまま維持する。
---@param opts { border: string|string[], annotation: boolean, page_indicator: boolean, fg: string?, bg: string?, border_fg: string?, border_bg: string?, alt_fg: string?, alt_bg: string? }|nil
function M.setup(opts)
  opts = opts or {}
  if opts.border ~= nil then
    config.border = opts.border
  end
  if opts.annotation ~= nil then
    config.annotation = opts.annotation
  end
  if opts.page_indicator ~= nil then
    config.page_indicator = opts.page_indicator
  end
  setup_highlights(opts)
end

-- ===================================================================
-- テキスト整形（vim.* 非依存、単体テスト可能）
-- ===================================================================

--- 候補一覧を "a: 候補" 形式の行配列に整形する。アノテーションがあれば
--- （config.annotation が true の場合のみ）"a: 候補 ;注釈" のように
--- 末尾に付与する（SKK辞書の生の記法 "候補;注釈" に揃えている）。
---@param candidates SkkDictCandidate[] 最大7件（Session:page_candidates() の返り値）
---@return string[] lines
local function format_lines(candidates)
  local lines = {}
  for i, candidate in ipairs(candidates) do
    local key = M.HOME_ROW_KEYS[i]
    if key then
      local line = key .. ": " .. candidate.word
      if config.annotation and candidate.annotation then
        line = line .. " ;" .. candidate.annotation
      end
      table.insert(lines, line)
    end
  end
  return lines
end

M._format_lines = format_lines -- テストから直接検証できるように公開しておく

--- 最下行に表示する "現在ページ/全ページ数" のインジケーター行。
--- 例: 3ページ中2ページ目を表示中なら "2/3"。
---@param page integer 現在のページ（1-indexed）
---@param page_count integer 全ページ数
---@return string
local function page_indicator_line(page, page_count)
  return string.format("%d/%d", page, page_count)
end

M._page_indicator_line = page_indicator_line -- テストから直接検証できるように公開しておく

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

---@return integer
local function get_ns()
  if not ns then
    ns = vim.api.nvim_create_namespace("skk_candidate_window")
  end
  return ns
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

--- 候補一覧の内容（バッファへの書き込み・ハイライト・幅/高さの算出）を
--- 組み立てる。M.show()（バッファ用、relative="win"）と
--- M.show_cmdline()（コマンドライン用、relative="editor"）の共通部分。
---@param candidates SkkDictCandidate[]
---@param page integer
---@param page_count integer
---@param selected_offset integer|nil
---@return integer buf
---@return integer width
---@return integer height
local function build_content(candidates, page, page_count, selected_offset)
  local lines = format_lines(candidates)
  if config.page_indicator then
    table.insert(lines, page_indicator_line(page, page_count))
  end
  local b = get_buf()
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)

  vim.api.nvim_buf_clear_namespace(b, get_ns(), 0, -1)
  for i = 1, #candidates do
    if not (selected_offset and i == selected_offset) then
      -- 選択行以外は、1行おきに SkkCandidateWindowNormal /
      -- SkkCandidateWindowNormalAlt を交互に当てる（縞模様。
      -- alt_fg/alt_bg 未指定時は同じ色にリンクしているため見た目は
      -- 変わらない。設定した場合だけ可読性向上の縞が現れる）。
      local hl_group = (i % 2 == 1) and "SkkCandidateWindowNormal" or "SkkCandidateWindowNormalAlt"
      vim.api.nvim_buf_set_extmark(b, get_ns(), i - 1, 0, {
        line_hl_group = hl_group,
      })
    end
  end
  if selected_offset and selected_offset >= 1 and selected_offset <= #candidates then
    vim.api.nvim_buf_set_extmark(b, get_ns(), selected_offset - 1, 0, {
      line_hl_group = "SkkHenkanCandidate",
    })
  end

  local width = 1
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  local height = #lines
  return b, width, height
end

--- 候補一覧を、アンカー位置（変換プレエディットのカーソル位置）の
--- すぐ下（入りきらなければ上）にフローティングウィンドウで表示する。
--- 既に表示中なら、内容とサイズだけ更新する（ウィンドウを開き直さない）。
--- 最下行に "現在ページ/全ページ数"（例: "2/3"）のインジケーターを付ける。
---
--- selected_offset で指定した行（ホームポジションの位置、1〜7）を
--- ハイライトする。候補一覧ウィンドウを表示するタイミングを遅らせる
--- 設定（lua/skk/init.lua の candidate_window.threshold）を使うと、
--- ウィンドウを開いた時点で選択中の候補がページの先頭（"a:"）とは
--- 限らなくなる（1件ずつ送っている途中でウィンドウが現れるため）。
--- インライン表示（▼候補）と齟齬が出ないよう、実際に選ばれている行を
--- ここで明示する。
---@param anchor_win integer 基準となるウィンドウID
---@param anchor_row integer 0-indexed の行
---@param anchor_col integer 0-indexed の列
---@param candidates SkkDictCandidate[] 現在ページの候補一覧（最大7件）
---@param page integer 現在のページ（1-indexed）
---@param page_count integer 全ページ数
---@param selected_offset integer|nil 現在選択中の候補の、ページ内での位置（1〜7）。
---  nil ならハイライトしない。
--- 候補一覧ウィンドウの NormalFloat/FloatBorder を、skk.nvim 専用の
--- ハイライトグループ（SkkCandidateWindowNormal/SkkCandidateWindowBorder）
--- に差し替える。これらは Neovim 全体で共有されるグループ（LSPのhover等
--- 他のフロートウィンドウにも影響する）なので、'winhighlight' で
--- このウィンドウだけ専用グループに切り替える。
local WINHIGHLIGHT = "NormalFloat:SkkCandidateWindowNormal,FloatBorder:SkkCandidateWindowBorder"

---@param w integer
local function apply_winhighlight(w)
  vim.api.nvim_set_option_value("winhighlight", WINHIGHLIGHT, { win = w })
end

function M.show(anchor_win, anchor_row, anchor_col, candidates, page, page_count, selected_offset)
  if #candidates == 0 then
    M.hide()
    return
  end

  local b, width, height = build_content(candidates, page, page_count, selected_offset)

  -- ウィンドウが既に開いている（＝同じ変換セッション中にページ送り等で
  -- 再描画している）間は、最初に決めた配置を使い回す。閉じている状態
  -- （新しい変換セッションの最初の表示）でだけ、改めて計算し直す。
  local anchor_corner, row_offset
  if win and vim.api.nvim_win_is_valid(win) and sticky_corner then
    anchor_corner, row_offset = sticky_corner, sticky_row_offset
  else
    anchor_corner, row_offset = compute_placement(anchor_win, anchor_row, height)
    sticky_corner, sticky_row_offset = anchor_corner, row_offset
  end

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
  }

  if win and vim.api.nvim_win_is_valid(win) then
    -- 【注意】noautocmd は nvim_open_win() 専用のオプションで、
    -- nvim_win_set_config()（既存ウィンドウの更新）には渡せない
    -- （渡すと "Invalid key: 'noautocmd'" エラーになる）。
    vim.api.nvim_win_set_config(win, win_config)
  else
    win_config.noautocmd = true
    win = vim.api.nvim_open_win(b, false, win_config)
  end
  apply_winhighlight(win)
end

--- 【コマンドラインモード専用】候補一覧をコマンドライン行のすぐ上に
--- フローティングウィンドウで表示する。
---
--- コマンドラインには M.show() が使う「アンカーウィンドウのバッファ位置
--- （bufpos）」という概念が無い（コマンドライン編集中、実際のウィンドウの
--- カーソルはコマンドラインに入る前の位置に固定されたままで、コマンド
--- ライン自体のバッファ位置は存在しない）ため、relative="win" は使えない。
--- 代わりに mode_indicator.lua と同じ考え方で relative="editor" を使い、
--- 常にコマンドライン行のすぐ上（画面下端寄り）に固定表示する。上下の
--- sticky配置切り替えは行わない（コマンドラインは1行固定なので、画面上の
--- 位置が動くバッファ内カーソルほど配置に迷う余地が無いため）。
---
--- 【redraw が必要な理由】mode_indicator.lua で確認したのと同じく、
--- コマンドライン編集中に新規作成・再配置したフローティングウィンドウは
--- 明示的な 'redraw' が無いと画面に反映されない（実機で確認済みの
--- 既知の挙動）。
---@param candidates SkkDictCandidate[] 現在ページの候補一覧（最大7件）
---@param page integer 現在のページ（1-indexed）
---@param page_count integer 全ページ数
---@param selected_offset integer|nil 現在選択中の候補の、ページ内での位置（1〜7）。
---  nil ならハイライトしない。
function M.show_cmdline(candidates, page, page_count, selected_offset)
  if #candidates == 0 then
    M.hide()
    return
  end

  local b, width, height = build_content(candidates, page, page_count, selected_offset)
  local total_height = height + border_row_overhead()

  local win_config = {
    relative = "editor",
    row = math.max(vim.o.lines - vim.o.cmdheight - total_height, 0),
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = config.border,
    focusable = false,
    zindex = 240, -- mode_indicator（250）より少し低くし、万一重なってもモード表示を隠さない
  }

  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_config(win, win_config)
  else
    win_config.noautocmd = true
    win = vim.api.nvim_open_win(b, false, win_config)
  end
  apply_winhighlight(win)

  vim.cmd("redraw")
end

--- ウィンドウを閉じる。確定・キャンセル・ページ移動で候補が0件に
--- なった場合等に呼ぶ。次の変換セッションで配置を再計算できるよう、
--- sticky な配置の記憶もここでリセットする。
function M.hide()
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
    -- show_cmdline() 同様、コマンドライン編集中は明示的な redraw が無いと
    -- ウィンドウを閉じたことが画面に反映されない。
    if target.kind() == "cmdline" then
      vim.cmd("redraw")
    end
  end
  win = nil
  sticky_corner = nil
  sticky_row_offset = nil
end

--- 現在表示中のバッファの行を返す（テスト用）。表示していなければ nil。
---@return string[]|nil
function M._buf_lines()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

--- 現在ハイライトされている行番号（0-indexed）を返す（テスト用）。
--- ハイライトが無ければ nil。
---@return integer|nil
--- テスト用: 現在「選択中の行」としてハイライトされている行番号（0-indexed）を
--- 返す。build_content() は選択行以外にも縞模様用の extmark を打つため、
--- 単純に「最初の extmark」ではなく、hl_group が SkkHenkanCandidate
--- （選択行専用のグループ。上記 build_content() 参照）のものを探す。
function M._highlighted_line()
  if not buf or not vim.api.nvim_buf_is_valid(buf) or not ns then
    return nil
  end
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  for _, mark in ipairs(marks) do
    local details = mark[4]
    if details and details.line_hl_group == "SkkHenkanCandidate" then
      return mark[2] -- {id, row, col, details}
    end
  end
  return nil
end

--- テスト用: 現在、縞模様用のハイライト（SkkCandidateWindowNormal /
--- SkkCandidateWindowNormalAlt）が付いている行番号（0-indexed）を、
--- グループ名ごとに配列で返す。build_content() のロジック検証用。
---@return { normal: integer[], alt: integer[] }
function M._alt_highlighted_lines()
  local out = { normal = {}, alt = {} }
  if not buf or not vim.api.nvim_buf_is_valid(buf) or not ns then
    return out
  end
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  for _, mark in ipairs(marks) do
    local details = mark[4]
    if details and details.line_hl_group == "SkkCandidateWindowNormal" then
      table.insert(out.normal, mark[2])
    elseif details and details.line_hl_group == "SkkCandidateWindowNormalAlt" then
      table.insert(out.alt, mark[2])
    end
  end
  return out
end

return M
