-- lua/skk/target.lua
--
-- 入力先（挿入モードのバッファ / コマンドラインモードのコマンドライン文字列）を
-- 抽象化する層。capture.lua はこのモジュール経由でのみ実際のテキスト読み書きを
-- 行い、バッファとコマンドラインの違いを意識しなくて済むようにする。
--
-- 【なぜ必要か】
-- 挿入モードのテキスト操作は nvim_buf_set_text() + nvim_win_get_cursor() だが、
-- コマンドラインはバッファではないため、これらのAPIが使えない。代わりに
-- vim.fn.getcmdline()/setcmdline()/getcmdpos() を使う（setcmdline()/getcmdpos()
-- は Neovim 0.10 で追加。:help setcmdline() 参照。plugin側で要求している
-- Neovim 0.10+ という前提と矛盾しない）。
--
-- 【対象外】henkan（▽/▼）の preedit 表示（lua/skk/henkan/preedit.lua）は
-- extmark を使っており、コマンドラインには extmark が存在しないため、
-- このモジュールの対象外（コマンドラインでの henkan 対応は別途行う）。
-- ここではローマ字→かな変換・モード切替（l/q/L, <C-j>）で使う、単純な
-- 「カーソル直前の N バイトを削除して置き換える」操作のみを対象にする。

local M = {}

--- 現在のモードが対応対象かどうかを返す。
--- @return "buffer"|"cmdline"|nil 挿入モードなら "buffer"、コマンドライン
---   モードなら "cmdline"、それ以外（対応していないモード）なら nil。
function M.kind()
  local mode = vim.api.nvim_get_mode().mode
  if mode == "i" then
    return "buffer"
  end
  if mode == "c" then
    return "cmdline"
  end
  return nil
end

-- ===================================================================
-- コマンドライン: 純粋なテキスト操作ロジック（vim.* 非依存、単体テスト可能）
-- ===================================================================

--- コマンドライン文字列 `line` の、カーソル位置 `cmdpos`（getcmdpos() が返す
--- 1-indexed の値。「次に入力される文字の位置」を指す）の直前から
--- `byte_len` バイトを削除し、`text` を挿入した結果を返す。
---@param line string
---@param cmdpos integer 1-indexed（getcmdpos() と同じ意味）
---@param byte_len integer
---@param text string
---@return string new_line
---@return integer new_cmdpos 1-indexed（setcmdline() の第2引数にそのまま渡せる）
local function compute_cmdline_replace(line, cmdpos, byte_len, text)
  local cursor_byte = cmdpos - 1 -- 0-indexed バイトオフセットに変換
  local start_byte = math.max(cursor_byte - byte_len, 0)
  local new_line = line:sub(1, start_byte) .. text .. line:sub(cursor_byte + 1)
  return new_line, start_byte + #text + 1
end

M._compute_cmdline_replace = compute_cmdline_replace -- テストから直接検証できるように公開しておく

-- ===================================================================
-- 実際の読み書き（vim.* 依存。plenary/実機の Neovim でしか検証できない）
-- ===================================================================

--- 現在のカーソル位置の直前から `byte_len` バイトを削除し、続けて `text` を
--- 挿入する。カーソルは挿入後のテキストの末尾に置く。
--- M.kind() が "buffer" か "cmdline" かに応じて処理を振り分ける。
--- どちらでもない場合（呼び出し側が事前に M.kind() で確認している想定）は
--- 何もしない。
---@param byte_len integer
---@param text string
function M.replace_before_cursor(byte_len, text)
  local kind = M.kind()

  if kind == "buffer" then
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
    return
  end

  if kind == "cmdline" then
    local line = vim.fn.getcmdline()
    local pos = vim.fn.getcmdpos()
    local new_line, new_pos = compute_cmdline_replace(line, pos, byte_len, text)
    vim.fn.setcmdline(new_line, new_pos)
    return
  end
end

return M
