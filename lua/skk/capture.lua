-- lua/skk/capture.lua
--
-- vim.on_key() を使って挿入モードのキー入力を横取りし、ローマ字を
-- かなに変換してバッファへ反映するキャプチャ層。
--
-- 【設計】
-- 未確定のローマ字断片（例: "k" だけ打った直後）は、消費こそするが
-- そのまま「普通の文字」としてバッファに literal 表示しておく。
-- 変換が確定したタイミングで、その文字数ぶんを消して確定したかなに
-- 置き換える。skkeleton の ▽ のような専用の pre-edit 表示ではないが、
-- 実装がシンプルで、何も表示されない不安がない。
--
-- 【既知の制限（MVP・phase 1）】
-- - 未確定バッファがある状態でカーソルを動かす/<BS> を押すと、
--   画面上のテキストと内部状態 (context.buffer) がずれる可能性がある。
--   （<BS> を明示的にハンドリングしていないため）
-- - 大文字入力（SKK の ▽ 開始トリガー）や辞書変換（▼）はまだ未実装。
--   このモジュールは「ローマ字かな変換」だけを担当する。
-- - コマンドラインモードや検索は未対応（挿入モードのみ）。

local Context = require("skk.context")
local Input = require("skk.input")

local M = {}

local enabled = false
local context = Context.new()
local ns_id = nil

-- 半角小文字アルファベット以外で変換対象にする記号
-- （kana_table.lua で M["-"] / M["."] / M[","] を定義しているのに合わせる）
local EXTRA_TARGET_CHARS = {
  ["-"] = true,
  ["."] = true,
  [","] = true,
  ["["] = true,
  ["]"] = true,
}

--- 変換対象にする1文字かどうか（半角小文字アルファベット + 上記の記号）
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

---@param key string 実際に処理されるキー（マッピング適用後）
---@param _typed string マッピング適用前に打鍵されたキー（未使用）
---@return string|nil
local function on_key(key, _typed)
  if not enabled then
    return
  end
  if vim.api.nvim_get_mode().mode ~= "i" then
    return
  end
  if not is_target_key(key) then
    return
  end

  -- これまで画面に literal 表示していた未確定ローマ字のバイト数
  -- （半角英字のみなので文字数 == バイト数）
  local old_pending_len = #context.buffer

  Input.kanaInput(context, key)
  local confirmed = context:flush()
  local pending = context.buffer

  vim.schedule(function()
    -- blink.cmp のキーマップ実行時に踏んだ textlock (E565) と同じ問題を
    -- 避けるため、実際のバッファ書き換えは1ティック遅らせる。
    replace_before_cursor(old_pending_len, confirmed .. pending)
  end)

  return "" -- 元のキー（生のローマ字）はここで破棄する
end

--- SKK を有効化する。
function M.enable()
  enabled = true
  context = Context.new()
end

--- SKK を無効化する。未確定のローマ字断片は破棄する
--- （画面上の literal 表示はそのまま残るので、消したい場合は別途 <BS>）。
function M.disable()
  enabled = false
  context = Context.new()
end

--- 有効/無効をトグルする。
---@return boolean 切り替え後の状態
function M.toggle()
  if enabled then
    M.disable()
  else
    M.enable()
  end
  return enabled
end

---@return boolean
function M.is_enabled()
  return enabled
end

--- vim.on_key() のリスナーを登録する。init 時に一度だけ呼ぶ。
function M.setup()
  ns_id = vim.on_key(on_key, ns_id)
end

return M
