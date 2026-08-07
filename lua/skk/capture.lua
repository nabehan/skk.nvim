-- lua/skk/capture.lua
--
-- vim.on_key() を使って挿入モードのキー入力を横取りし、モードに応じて
-- ローマ字→かな/カタカナ変換・全角変換を行うキャプチャ層。
--
-- 【モードとキー遷移】
--   半角英数 --<C-j>--> ひらがな
--   全角英数 --<C-j>--> ひらがな
--   ひらがな --l-->     半角英数
--   ひらがな --q-->     カタカナ
--   ひらがな --L-->     全角英数
--   カタカナ --l-->     半角英数
--   カタカナ --q-->     ひらがな
--   カタカナ --L-->     全角英数
--
-- `l`/`q`/`L` は印字可能文字なので vim.on_key() のコールバック内で
-- 特別扱いする。`<C-j>` は制御キーなので lua/skk/init.lua が
-- 通常の vim.keymap.set 経由で M.transition() を呼び出す。
--
-- 【設計上の制約】
-- - `l`/`q`/`L` によるモード切替は、未確定のローマ字バッファが空の
--   ときだけ有効にする（ローマ字入力の途中に紛れ込んだ場合は通常の
--   ローマ字入力として処理する）。
-- - 全角英数モードでは `l`/`q`/`L` を含む全ての印字可能ASCII文字を
--   そのまま全角に変換する（モード切替キーとしては扱わない。
--   「全角英数モードで q を打ったら ｑ にならないといけない」という
--   指摘のとおり）。
-- - 半角カナモードは検討したが、ターミナルエミュレーターの動作が
--   不安定になる事例が確認されたため実装しない方針とした。
--
-- 【henkan（▽/▼、漢字変換）との連携】
-- ひらがな/カタカナモードで、未確定バッファが空の状態で大文字キーが
-- 来ると lua/skk/henkan/state.lua の ▽ を開始する。henkan がアクティブな
-- 間は、直接入力の処理には一切進まず handle_henkan_key() へ全キーを
-- 委譲する（<CR>=確定 / <BS>=読み取り消し / <C-g>=キャンセル / space=
-- 検索・次候補 / ▼状態のみ x=前候補 / ▽状態のみ q=かな変換確定 /
-- ▽状態での大文字キー=送り開始点トリガー）。
-- ▼状態で space/x 以外のキーが来た場合は、選択中の候補を自動確定した
-- うえで、そのキー自体を新しい入力として直接入力へ引き継ぐ
-- （"Kanji<SPC>t" -> "漢字"確定+"t"から継続入力、
--  "Kanji<SPC>T" -> "漢字"確定+"T"で新しい▽開始）。
-- Sticky-shift（`;`）は、▽開始・送り開始点トリガーの両方で大文字キーと
-- 同様に扱う（`;` 自体は文字を持たないマーカーとしてのみ働く）。
-- 候補選択ウィンドウ（ホームポジション a s d f j k l で選択・即確定、
-- <SPC>/x でページ送り）は lua/skk/henkan/candidate_window.lua が担当する。
-- abbrev モード（"/" 開始、ASCII文字列そのものを見出しにする変換。
-- 例: "/Emacs" -> "いーまっくす" のような辞書エントリを引く）にも対応する。

local Context = require("skk.context")
local Input = require("skk.input")
local kana_util = require("skk.kana_util")
local mode_util = require("skk.mode")
local henkan_state = require("skk.henkan.state")

local M = {}

local context = Context.new()
local ns_id = nil

--- lua/skk/init.lua の M.setup() から差し込まれるオプション。
--- モジュールのトップレベルでは vim.* に触れないプレーンな値のみ
--- 保持する（この設計方針は他のモジュールと同様）。
---@type { sticky_shift_enabled: boolean, sticky_shift_key: string, egg_like_newline: boolean }
local config = {
  sticky_shift_enabled = true,
  sticky_shift_key = ";",
  egg_like_newline = true,
}

-- 制御キーの raw keycode。vim.api.nvim_replace_termcodes は使わない
-- （preedit.lua の namespace 生成で踏んだのと同じ「モジュールのトップ
-- レベルで vim.api を呼んでしまい、vim グローバルの無い環境で require
-- するだけでクラッシュする」ミスを避けるため。これらは全て固定の
-- ASCII 制御バイトなので string.char で十分）。
local BS = string.char(8) -- <C-h> はこの生バイトで届く
-- 物理的な Backspace キーは、ターミナルによって 0x08 (BS) ではなく
-- 0x7F (DEL) を送ってくることがある（よくある終端エミュレータの差異）。
-- 直接入力モード側は is_target_key に該当しないキーを汎用的に
-- リセットする設計なのでこの差異を意識せずに済むが、henkan 側は
-- <BS> を明示的に検知する必要があるため、両方のバイト値を受け付ける。
local BS_ALT = string.char(127) -- 一部の環境で Backspace が送る DEL
-- 実機で確認したところ、物理 Backspace キーは上記どちらの生バイトでもなく
-- termcap 由来の内部キーコード K_SPECIAL(0x80) + "kb" (0x80,0x6b,0x62)
-- として vim.on_key() に届くケースがあった（<C-h> は素の 0x08 で届くのに
-- 対し、物理 <BS> は Neovim 側で termcap の t_kb を経由して特別な内部表現に
-- 正規化される）。決め打ちのバイト値ではなく Neovim 自身に問い合わせて
-- 取得する。モジュールのトップレベルで vim.api を呼ぶと vim グローバルの
-- 無い環境で require するだけでクラッシュするため、M.setup() 内で遅延評価する。
local BS_TERMCODE = nil
local CR = string.char(13) -- <CR> (Enter)
local CTRL_G = string.char(7) -- <C-g>

-- ひらがな/カタカナモードで、確定したかなをどう表示するか。
---@type table<SkkMode, fun(s: string): string>
local RENDERERS = {
  hira = function(s)
    return s
  end,
  kata = kana_util.to_katakana,
}

--- 変換対象にする1文字かどうか（半角小文字アルファベット + 一部記号）
--- ひらがな/カタカナモードでの romaji 入力用。
---@type table<string, boolean>
local EXTRA_TARGET_CHARS = {
  ["-"] = true,
  ["."] = true,
  [","] = true,
  ["["] = true,
  ["]"] = true,
  ["("] = true,
  [")"] = true,
  [" "] = true,
}

--- ▽ 開始・送り開始点トリガーとして扱うキーかどうか。
--- 大文字キー（Shift+文字、トリガーと1文字目を1打鍵で兼ねる）と
--- Sticky-shift のキー（デフォルト `;`。トリガー専用で、文字は次の
--- 打鍵から別に入力する。config.sticky_shift_enabled=false なら
--- Sticky-shift 自体を無効化する）の両方を受け付ける。
---@param key string
---@return boolean
local function is_midashi_trigger_key(key)
  if key:match("%u") ~= nil then
    return true
  end
  return config.sticky_shift_enabled and key == config.sticky_shift_key
end

--- 大文字キーは「小文字化した1文字」がそのまま最初の読みになるが、
--- Sticky-shift のキーはトリガー専用で文字を持たないので "" を返す。
---@param key string
---@return string
local function midashi_trigger_first_char(key)
  if config.sticky_shift_enabled and key == config.sticky_shift_key then
    return ""
  end
  return key:lower()
end

---@param key string
---@return boolean
local function is_target_key(key)
  if #key ~= 1 then
    return false
  end
  if key:match("%l") then
    return true
  end
  return EXTRA_TARGET_CHARS[key] == true
end

--- 半角の印字可能ASCII文字か（全角英数モード用。制御キー・特殊キーは除外する）
---@param key string
---@return boolean
local function is_printable_ascii(key)
  if #key ~= 1 then
    return false
  end
  local b = key:byte(1)
  return b >= 0x20 and b <= 0x7E
end

--- 現在のカーソル位置の直前から `byte_len` バイトを削除し、
--- 続けて `text` を挿入する。カーソルは挿入後のテキストの末尾に置く。
---@param byte_len integer
---@param text string
local function replace_before_cursor(byte_len, text)
  local win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(win)
  local row0 = cursor[1] - 1
  local col = cursor[2]
  local start_col = math.max(col - byte_len, 0)

  if byte_len > 0 then
    vim.api.nvim_buf_set_text(0, row0, start_col, row0, col, {})
  end
  if text ~= "" then
    vim.api.nvim_buf_set_text(0, row0, start_col, row0, start_col, { text })
  end
  vim.api.nvim_win_set_cursor(win, { row0 + 1, start_col + #text })
end

--- ローマ字入力を処理し、確定したかな（モードに応じてカタカナに
--- 変換済み）と未確定バッファをバッファへ反映する。
---@param key string
local function process_romaji(key)
  local old_pending_len = #context.buffer

  Input.kanaInput(context, key)
  local confirmed = context:flush()
  local pending = context.buffer

  local render = RENDERERS[context.mode] or function(s)
    return s
  end
  local display = render(confirmed) .. pending

  vim.schedule(function()
    -- blink.cmp との統合作業で踏んだ textlock (E565) と同じ問題を避けるため、
    -- 実際のバッファ書き換えは1ティック遅らせる。
    replace_before_cursor(old_pending_len, display)
  end)
end

--- henkan（▽/▼）がアクティブな間のキー処理。
--- <CR>/<BS>/<C-g> はフェーズに関係なく共通、それ以外はフェーズごとに
--- 意味が変わる（▼状態の space/x は候補送り、▽状態の q はかな変換確定、等）。
---@param key string
---@return boolean reprocess true なら、このキーは確定処理のうえで
---  通常の直接入力として再処理してほしい、という意味（on_key 側が続けて処理する）
local function handle_henkan_key(key)
  if key == CR then
    henkan_state.confirm()
    if not config.egg_like_newline then
      -- SKK本来の動作: 確定に加えて改行も行う。henkan_state.confirm() の
      -- バッファ挿入は vim.schedule で1ティック遅延しているので、それより
      -- 後に <CR> を「本物のキー入力」として再度 feedkeys で送り込むことで、
      -- FIFO順序（確定 -> 改行）を保証しつつ、改行そのものはNeovim
      -- ネイティブの処理に委ねる（自前で行分割を実装しない）。
      -- この時点で henkan は既に非アクティブになっているので、再入力された
      -- <CR> は on_key の henkan 分岐を通らず、通常の直接入力パス
      -- （is_target_key に該当しない印字可能ASCII外のキー）としてそのまま
      -- Neovim に素通しされる。
      vim.schedule(function()
        vim.api.nvim_feedkeys(CR, "n", false)
      end)
    end
    return false
  end
  if key == BS or key == BS_ALT or (BS_TERMCODE and key == BS_TERMCODE) then
    henkan_state.backspace()
    return false
  end
  if key == CTRL_G then
    henkan_state.cancel()
    return false
  end
  if key == " " then
    henkan_state.space()
    return false
  end

  local phase = henkan_state.get_phase()

  if phase == "select" then
    if key == "x" then
      henkan_state.prev_page()
      return false
    end
    -- ホームポジションキー（a s d f j k l）は、現在ページの候補一覧
    -- ウィンドウに表示されている位置に対応する候補を選択・即確定する。
    -- そのキーの位置に候補が存在しない場合（候補が8件未満で、
    -- ウィンドウ上でそのキーに何も表示されていない場合）は、
    -- 下の「空以外のキー」共通処理にフォールバックする
    -- （選択中の候補を確定したうえで、このキー自体を新しい入力として
    -- 再処理する）。
    if henkan_state.select_by_key(key) then
      henkan_state.confirm()
      return false
    end
    -- space/x/ホームポジション選択 以外のキーが来たら、選択中の候補を
    -- 確定したうえで、このキー自体は「確定後の新しい入力」として通常の
    -- 直接入力に引き継ぐ（例: "Kanji<SPC>t" -> "漢字" 確定 + "t" から
    -- 入力継続、"Kanji<SPC>T" -> "漢字" 確定 + "T" で新しい ▽ 開始）。
    -- 矢印キー等の特殊キー（印字可能ASCIIでないもの）は再処理の対象外
    -- とし、確定だけ行う（literal 挿入すると壊れるため）。
    henkan_state.confirm()
    return is_printable_ascii(key)
  end

  -- ここから phase == "midashi" / "abbrev"

  if phase == "abbrev" then
    -- abbrev（"/" 開始）は ASCII 文字列そのものを見出しにするモードなので、
    -- ローマ字変換や大文字トリガー（送り開始点）の解釈をせず、印字可能
    -- ASCII文字はすべてそのまま見出しに追加する（大文字・記号・数字を含む。
    -- 例: "Bug", "Emacs" のような見出しをそのまま打てる）。
    if is_printable_ascii(key) then
      henkan_state.input_abbrev(key)
      return false
    end
    -- 矢印キー等、印字可能ASCIIでないキーが来たら、ここまでの見出しを
    -- 確定する（▽状態の「未対応のキー」と同じ考え方）。
    henkan_state.confirm()
    return false
  end

  -- ここから phase == "midashi"
  if key == "q" then
    henkan_state.convert_and_confirm_kana()
    return false
  end

  if key:match("%u") then
    -- 送り開始点トリガー: ▽ の中でもう一度大文字キーが来たら、そこから
    -- 送り仮名の入力が始まる（例: "Ugokasu" の2番目の "K"）。
    henkan_state.start_okuri()
    henkan_state.input(key:lower())
    return false
  end

  if config.sticky_shift_enabled and key == config.sticky_shift_key then
    -- Sticky-shift の送り開始点トリガー。大文字キーと違い、このキー自体は
    -- 文字を持たないのでマーカーとしてだけ扱う（次の打鍵から送り仮名の
    -- 子音入力が始まる。デフォルトのキー（;）なら例: ";oku;ri" の2番目の ";"）。
    henkan_state.start_okuri()
    return false
  end

  if is_target_key(key) then
    henkan_state.input(key)
    return false
  end

  -- 未対応のキー（数字・記号等）。以前はセッションを丸ごと中断していたが、
  -- それだと「▽かん」に続けて "1" や ";" を打っただけで読みが全部消えて
  -- しまい、使い勝手が悪かった（実際に報告された不具合）。▼状態の
  -- space/x 以外のキーと同じく、ここまでの読みを確定したうえで、
  -- このキー自体は新しい入力として直接入力に引き継ぐ。
  -- 矢印キー等の特殊キー（印字可能ASCIIでないもの）は再処理の対象外
  -- とし、確定だけ行う（literal 挿入すると壊れるため）。
  henkan_state.confirm()
  return is_printable_ascii(key)
end

--- henkan 確定直後に「このキーを新しい直接入力として再処理してほしい」
--- と言われた場合の処理。handle_henkan_key が reprocess=true を返すのは
--- is_printable_ascii(key) が真の場合に限定してあるので、ここではその
--- 前提で常に literal に処理しきる。
--- 【重要】この時点で元の物理キー入力は既に消費済み（on_key が "" を
--- 返している）なので、通常の直接入力パスと違って Neovim のネイティブ
--- 処理に頼ることはできない（"" 未対応キーは自分で literal 挿入する）。
---@param key string
local function reprocess_direct_key(key)
  if context.buffer == "" and is_midashi_trigger_key(key) then
    henkan_state.start_midashi(context.mode, midashi_trigger_first_char(key))
    return
  end

  if context.buffer == "" and key == "/" then
    -- abbrev モード開始（ASCII文字列そのものを見出しにする変換）。
    henkan_state.start_abbrev(context.mode)
    return
  end

  if context.buffer == "" then
    local target = mode_util.char_transition(key, context.mode)
    if target then
      context.mode = target
      return
    end
  end

  if is_target_key(key) then
    process_romaji(key)
    return
  end

  -- ローマ字にもモード切替にも該当しない印字可能文字（数字・記号等）を
  -- そのまま literal に挿入する。
  replace_before_cursor(0, key)
end

---@param key string 実際に処理されるキー（マッピング適用後）
---@param _typed string マッピング適用前に打鍵されたキー（未使用）
---@return string|nil
local function on_key(key, _typed)
  if context.mode == "ascii" then
    return -- 完全パススルー。<C-j> は init.lua 側のキーマップで処理する
  end

  if vim.api.nvim_get_mode().mode ~= "i" then
    return
  end

  if context.mode == "zenei" then
    if not is_printable_ascii(key) then
      return
    end
    local zenkaku = kana_util.to_zenkaku_char(key)
    vim.schedule(function()
      replace_before_cursor(0, zenkaku)
    end)
    return ""
  end

  -- ここから hira / kata 共通

  -- henkan (▽/▼) がアクティブなら、まずそちらにキーを渡す。
  -- 確定のうえで「このキーは新しい入力として続けて処理してほしい」
  -- (reprocess=true) と言われた場合は、直接入力の処理へフォールスルーする
  -- （▼状態で space/x 以外のキーが来たときの自動確定 + 継続入力）。
  --
  -- 【重要】henkan_state.confirm() 自体のバッファ挿入は vim.schedule で
  -- 1ティック遅延している（textlock 対策）。もしここで再処理を同期的に
  -- 実行してしまうと、確定テキストがまだ挿入される前のカーソル位置を
  -- 新しい ▽ の anchor() が記録してしまい、カーソル位置がずれる
  -- 不具合になる（実際に発生した）。再処理も同じく vim.schedule で
  -- 遅延させることで、Neovim の FIFO 実行順序により「確定の挿入 ->
  -- 再処理」の順序を保証する。
  if henkan_state.is_active() then
    local reprocess = handle_henkan_key(key)
    if not reprocess then
      return ""
    end
    vim.schedule(function()
      reprocess_direct_key(key)
    end)
    return ""
  end

  -- ▽ 開始トリガー: 未確定バッファが空の状態での大文字キー、または
  -- Sticky-shift の `;`（Shift を使わずに大文字キー相当の操作をする方法。
  -- `;` 自体は文字を持たないマーカーなので、最初の読みは "" になる）。
  -- （▽ の中での送り開始点トリガーは handle_henkan_key 側で処理する）。
  if context.buffer == "" and is_midashi_trigger_key(key) then
    henkan_state.start_midashi(context.mode, midashi_trigger_first_char(key))
    return ""
  end

  if context.buffer == "" and key == "/" then
    -- abbrev モード開始（ASCII文字列そのものを見出しにする変換）。
    henkan_state.start_abbrev(context.mode)
    return ""
  end

  if context.buffer == "" then
    local target = mode_util.char_transition(key, context.mode)
    if target then
      context.mode = target
      return "" -- 切り替えキー自体は破棄する（挿入しない）
    end
  end

  if not is_target_key(key) then
    -- 未確定のローマ字が画面に literal 表示されている状態で、ローマ字
    -- 入力の続きとして認識できないキー（<BS>/<Delete>/カーソル移動キー等）
    -- が来た場合は、内部の追跡を諦めてリセットする。以降その文字列は
    -- Neovim から見て「ただのプレーンテキスト」になり、ネイティブの
    -- 処理（削除・カーソル移動）にそのまま委ねられる。
    --
    -- 【これが無いとどうなるか（実際に踏んだバグ）】
    -- <BS> も <Delete> も is_target_key に該当しないため、素通しすると
    -- Neovim ネイティブの処理に委ねられる。画面上の未確定ローマ字
    -- （例: "t"）は正しく消えても、内部の context.buffer は "t" のまま
    -- 更新されずに残ってしまう。次のキー入力時、capture.lua は
    -- 「まだ1バイト分の未確定文字が画面に残っているはず」という
    -- 古い情報を元にカーソル直前のバイトを削除してしまい、実際にそこに
    -- ある確定済みのマルチバイト文字（かな）の末尾バイトだけを削って
    -- しまい、不正なバイト列（例: "か<e3><81>k"）に破壊してしまっていた。
    -- 個別のキーごとに対処するのではなく、この汎用的なリセットで
    -- <BS>/<Delete>、そして今後遭遇する未知のキーもまとめて防ぐ。
    context.buffer = ""
    return
  end

  process_romaji(key)
  return ""
end

--- <C-j> などの制御キーによるモード遷移を試みる。
--- 現在のモードから見て遷移先が定義されていなければ何もしない。
---@param ctrl_key string 例: "<C-j>"
---@return SkkMode|nil 遷移後のモード（遷移しなかった場合は nil）
function M.transition(ctrl_key)
  local target = mode_util.ctrl_transition(ctrl_key, context.mode)
  if not target then
    return nil
  end
  context.mode = target
  context.buffer = "" -- 未確定のローマ字断片が残っていたら破棄する
  return context.mode
end

---@return SkkMode
function M.get_mode()
  return context.mode
end

---@return string
function M.mode_label()
  return mode_util.label(context.mode)
end

--- vim.on_key() のリスナーを登録する。init 時に一度だけ呼ぶ。
---@param opts { sticky_shift_enabled: boolean?, sticky_shift_key: string?, egg_like_newline: boolean? }|nil
function M.setup(opts)
  opts = opts or {}
  if opts.sticky_shift_enabled ~= nil then
    config.sticky_shift_enabled = opts.sticky_shift_enabled
  end
  if opts.sticky_shift_key ~= nil then
    config.sticky_shift_key = opts.sticky_shift_key
  end
  if opts.egg_like_newline ~= nil then
    config.egg_like_newline = opts.egg_like_newline
  end

  -- 物理 <BS> キーが termcap 経由の特殊な内部キーコードとして届く環境が
  -- あるため、Neovim 自身に問い合わせて実際の表現を取得しておく。
  BS_TERMCODE = vim.api.nvim_replace_termcodes("<BS>", true, true, true)
  ns_id = vim.on_key(on_key, ns_id)
end

return M
