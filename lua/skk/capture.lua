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
-- 検索・次候補 / ▼状態のみ x=前候補 / ▽状態のみ q=かな変換確定）。
-- phase 3 時点では送りあり変換（okuri）はまだ未対応。

local Context = require("skk.context")
local Input = require("skk.input")
local kana_util = require("skk.kana_util")
local mode_util = require("skk.mode")
local henkan_state = require("skk.henkan.state")

local M = {}

local context = Context.new()
local ns_id = nil

-- 制御キーの raw keycode。vim.api.nvim_replace_termcodes は使わない
-- （preedit.lua の namespace 生成で踏んだのと同じ「モジュールのトップ
-- レベルで vim.api を呼んでしまい、vim グローバルの無い環境で require
-- するだけでクラッシュする」ミスを避けるため。これらは全て固定の
-- ASCII 制御バイトなので string.char で十分）。
local BS = string.char(8) -- <BS>
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
---@return string 常に "" を返し、henkan アクティブ中は元のキーを必ず消費する
local function handle_henkan_key(key)
  if key == CR then
    henkan_state.confirm()
    return ""
  end
  if key == BS then
    henkan_state.backspace()
    return ""
  end
  if key == CTRL_G then
    henkan_state.cancel()
    return ""
  end
  if key == " " then
    henkan_state.space()
    return ""
  end

  local phase = henkan_state.get_phase()

  if phase == "select" then
    if key == "x" then
      henkan_state.prev_candidate()
    end
    -- phase 3 時点では、▼状態でのその他のキーは未定義として無視する。
    -- 本家 SKK には「候補確定 + 続けて入力」という挙動もあるが、
    -- 今回はスコープ外として明示的に何もしない。
    return ""
  end

  -- ここから phase == "midashi"
  if key == "q" then
    henkan_state.convert_and_confirm_kana()
    return ""
  end

  if is_target_key(key) then
    henkan_state.input(key)
    return ""
  end

  -- 未対応のキー（送りあり変換の開始トリガーとなる大文字キー等は
  -- phase 4 で対応する）。安全のためセッションを中断する。
  henkan_state.cancel()
  return ""
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

  -- henkan (▽/▼) がアクティブなら、直接入力の処理には進まずそちらへ委ねる。
  if henkan_state.is_active() then
    return handle_henkan_key(key)
  end

  -- ▽ 開始トリガー: 未確定バッファが空の状態での大文字キー
  -- （送りあり変換の送り開始点トリガーは phase 4 で対応する）。
  if context.buffer == "" and key:match("%u") then
    henkan_state.start_midashi(context.mode, key:lower())
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
function M.setup()
  ns_id = vim.on_key(on_key, ns_id)
end

return M
