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
---
--- 【実機で発見】`start_pos` を渡した場合（buffer のみ対応。呼び出し側が
--- extmark 等で追跡した「削除範囲の開始位置」）は `byte_len` の逆算より
--- こちらを優先する。呼んだ側（lua/skk/capture.lua の process_romaji 等）と
--- ここでの処理タイミングの間に、nvim-autopairs 等の他プラグインが
--- カーソル付近へ追加の文字を挿入していても、extmark はバッファ編集に
--- 追従して自動補正されるため、`byte_len`（固定のバイト数逆算）方式より
--- 正確に「本来削除すべき範囲」を特定できる。
---
-- 【ヘッドレスNeovim（実機と同一のv0.12.4）でのRPC経由キー入力再現に
-- より判明・修正】以前は「削除範囲の開始位置」だけを start_pos（extmark）
-- から得て、「削除範囲の終了位置」は常にその時点の「現在のカーソル」を
-- 使っていた（`byte_len` そのものは終了位置の計算には使っていなかった）。
-- これは、nvim-autopairs 等の合成キー列に含まれる `<Left>`
-- （アンドゥ境界制御イディオムの一部。capture.lua 側では素通しされ、
-- Neovim ネイティブに処理される）が、対応する書き込みがまだ実行される前
-- （vim.schedule による1ティック遅延の間）に実カーソルを動かしてしまうと、
-- 「終了位置」が本来削除すべき範囲からずれてしまう（酷いときは開始位置
-- より手前になり、start > end の不正な範囲になってしまう）という欠陥が
-- あった。start_pos が分かっている場合は、終了位置も「現在のカーソル」
-- ではなく「start_pos から byte_len バイト進んだ位置」として計算する
-- ことで、開始位置・終了位置の両方を「現在のカーソル」から完全に
-- 切り離す。これにより、書き込みが実行されるまでの間に他プラグインが
-- カーソルをどこへ動かしていても（挿入・削除以外の、純粋なカーソル移動
-- である限り）影響を受けなくなる。
--
-- なお、同一ティック内で複数回この関数が呼ばれることそのもの（呼んだ側の
-- extmark が競合し合う問題）は、呼び出し側 capture.lua でのバッチ化
-- （同一ティック内の複数キーをまとめて1回の書き込みに集約する設計）で
-- 別途解消済み。バッチ化によりextmark自体の生成・破棄は「バッチ全体で
-- 1回」に限定されるため、ここでは単純にその1個のextmarkと、そのバッチが
-- 対象とすべき byte_len を信頼すればよい。
---@param byte_len integer
---@param text string
---@param start_pos { row: integer, col: integer }|nil
function M.replace_before_cursor(byte_len, text, start_pos)
  local kind = M.kind()

  if kind == "buffer" then
    local win = vim.api.nvim_get_current_win()
    local cursor = vim.api.nvim_win_get_cursor(win)
    local row0 = cursor[1] - 1
    local col = cursor[2]
    local start_row, start_col, end_row, end_col

    if start_pos ~= nil then
      start_row, start_col = start_pos.row, start_pos.col
      end_row, end_col = start_pos.row, start_pos.col + byte_len
    else
      start_row, start_col = row0, math.max(col - byte_len, 0)
      end_row, end_col = row0, col
    end

    if start_row ~= end_row or start_col < end_col then
      vim.api.nvim_buf_set_text(0, start_row, start_col, end_row, end_col, {})
    end
    if text ~= "" then
      vim.api.nvim_buf_set_text(0, start_row, start_col, start_row, start_col, { text })
    end
    vim.api.nvim_win_set_cursor(win, { start_row + 1, start_col + #text })
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
