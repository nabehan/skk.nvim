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
  ascii = "latn",
  zenei = "ＬＡ",
}

---@type integer|nil
local win = nil
---@type integer|nil
local buf = nil

--- ハイライトグループ（SkkModeIndicator）は winhighlight で当てる
--- （'winhighlight' は特定のグループを別名にリンクするだけなので、他の
--- フロートウィンドウ（候補一覧ウィンドウ等）には影響しない。
--- lua/skk/henkan/candidate_window.lua と同じ方式）。
local WINHIGHLIGHT = "NormalFloat:SkkModeIndicator"

--- インジケーター用のハイライトグループのデフォルトを定義する。
--- fg/bg のいずれかが指定されていれば、そのグループはリンクではなく
--- 直接その色で定義する（明示的に指定した色を優先する）。指定が無ければ
--- 標準のフロートウィンドウ用グループ（NormalFloat）にリンクしたままに
--- する（＝カラースキーム任せ、現状と同じ見た目）。
---@param opts { fg: string?, bg: string? }
local function setup_highlights(opts)
  if opts.fg or opts.bg then
    vim.api.nvim_set_hl(0, "SkkModeIndicator", { fg = opts.fg, bg = opts.bg })
  else
    vim.api.nvim_set_hl(0, "SkkModeIndicator", { default = true, link = "NormalFloat" })
  end
end

--- 見た目のオプションを設定する。lua/skk/init.lua から setup() 時に呼ばれる。
---@param opts { fg: string?, bg: string? }|nil
function M.setup(opts)
  setup_highlights(opts or {})
end

---@return integer
local function get_buf()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
  end
  return buf
end

--- ウィンドウに 'winhighlight' を適用する。候補一覧ウィンドウと同様、
--- 失敗しても pcall で握りつぶす（単に配色が当たらないだけにする）。
---@param w integer
local function apply_winhighlight(w)
  pcall(vim.api.nvim_set_option_value, "winhighlight", WINHIGHLIGHT, { win = w })
end

--- 現在のカーソル位置（挿入モード）またはコマンドライン付近
--- （コマンドラインモード）にモードインジケーターを表示する。
--- 対応するグリフが無いモードが渡されたら何もしない。
---
--- 【コマンドラインモードでの位置について】
--- nvim_open_win() の relative="cursor" は「現在のウィンドウのカーソル
--- 位置」を基準にする（:help nvim_open_win() の relative フィールド参照）。
--- コマンドラインモード中、この「現在のウィンドウ」はコマンドラインの
--- ウィンドウではなく、コマンドラインに入る直前の通常ウィンドウのままで
--- あり、そのカーソルはコマンドライン編集中ずっと固定されている。その
--- ため relative="cursor" のままだと、カーソルが画面下端付近にある場合に
--- コマンドライン行と重なり、コマンドラインの毎キー入力ごとの再描画で
--- 即座に上書きされてしまい、実質的に「表示されない」状態になる
--- （実機で報告された不具合）。コマンドラインモードでは代わりに
--- relative="editor" でコマンドライン行の右端付近に固定表示する。
---@param mode SkkMode
function M.show(mode)
  local glyph = M.GLYPHS[mode]
  if not glyph then
    return
  end

  local b = get_buf()
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { glyph })

  local win_config
  if vim.api.nvim_get_mode().mode == "c" then
    win_config = {
      relative = "editor",
      row = math.max(vim.o.lines - vim.o.cmdheight, 0),
      col = math.max(vim.o.columns - 4, 0),
      width = 4,
      height = 1,
      style = "minimal",
      border = "none",
      focusable = false,
      zindex = 250, -- コマンドライン自体の描画より手前に出す
    }
  else
    win_config = {
      relative = "cursor",
      row = 1,
      col = 0,
      width = 4, -- 全角グリフ2文字ぶん（"latn"のような半角4文字表記もこの幅に収まる）
      height = 1,
      style = "minimal",
      border = "none",
      focusable = false,
    }
  end

  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_config(win, win_config)
  else
    win_config.noautocmd = true
    win = vim.api.nvim_open_win(b, false, win_config)
    apply_winhighlight(win)
  end

  -- 【なぜ redraw が必要か】コマンドライン編集中（Enterを押す前）に新規
  -- 作成・再配置したフローティングウィンドウは、Neovimの通常の画面再描画
  -- サイクルには乗らず、次にコマンドラインを抜けるまで実際には描画され
  -- ない（実機で確認済みの既知の挙動）。挿入モードでは次のキー入力ごとに
  -- 通常の再描画が走るため問題にならないが、コマンドラインでは明示的に
  -- 'redraw' を挟まない限り画面に反映されない。
  if vim.api.nvim_get_mode().mode == "c" then
    vim.cmd("redraw")
  end
end

--- インジケーターを消す。実際の入力があった時点（capture.lua の
--- on_key() の先頭）で毎回呼ばれる。表示していなければ何もしない。
function M.hide()
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
    -- show() 同様、コマンドライン編集中は明示的な redraw が無いと
    -- ウィンドウを閉じたことが画面に反映されない（表示が残り続ける）。
    if vim.api.nvim_get_mode().mode == "c" then
      vim.cmd("redraw")
    end
  end
  win = nil
end

--- 現在表示中のグリフ（テスト用）。表示していなければ nil。
---@return string|nil
function M._current_glyph()
  if not win or not vim.api.nvim_win_is_valid(win) or not buf or not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  return lines[1]
end

return M
