-- lua/skk/input.lua
--
-- ローマ字 → ひらがな 変換のステートマシン本体。
-- 1キー入力ごとに kanaInput(context, char) を呼び出す想定。
--
-- 処理の優先順位（バッファの中身に対して毎回この順で判定する）:
--   1. 変換表に完全一致するか？          -> 確定して終了
--   2. "nn" か？                          -> 「ん」を確定して終了
--   3. まだ何かの変換表エントリの prefix か？ -> 入力待ち（何もしない）
--   4. 子音の連続（促音）か？             -> 「っ」を確定し、2文字目から仕切り直し
--   5. "n" + (母音でも y でも n でもない文字) か？ -> 「ん」を確定し、2文字目から仕切り直し
--   6. どれにも当てはまらない             -> 先頭の1文字を捨てて仕切り直し（誤入力からの回復）

local kana_table = require("skk.kana_table")

local VOWELS = { a = true, i = true, u = true, e = true, o = true }

local M = {}

--- buf が変換表のいずれかのエントリの「真の prefix」（buf 自身と完全一致するエントリは除く）
--- になっているかどうかを調べる。
---@param buf string
---@return boolean
local function is_prefix(buf)
  if buf == "" then
    return false
  end
  for entry in pairs(kana_table) do
    if entry ~= buf and #entry > #buf and entry:sub(1, #buf) == buf then
      return true
    end
  end
  return false
end

--- context.buffer の中身を、確定できるところまで処理する。
--- 促音・「ん」の確定など、1回の呼び出しで複数文字分の処理が走ることもあるため
--- while ループで繰り返し評価する。
---@param context SkkContext
local function process(context)
  while context.buffer ~= "" do
    local buf = context.buffer

    -- 1. 完全一致
    local kana = kana_table[buf]
    if kana then
      context:doKakutei(kana)
      context.buffer = ""
      return
    end

    -- 2. "nn" -> ん
    if buf == "nn" then
      context:doKakutei("ん")
      context.buffer = ""
      return
    end

    -- 3. まだ他の変換の途中かもしれない -> 入力待ち
    if is_prefix(buf) then
      return
    end

    local first = buf:sub(1, 1)
    local second = buf:sub(2, 2)

    if #buf >= 2 and first == second and not VOWELS[first] and first ~= "n" then
      -- 4. 促音: 子音が連続している -> 「っ」を確定し、2文字目以降で仕切り直す
      context:doKakutei("っ")
      context.buffer = buf:sub(2)
    elseif first == "n" and #buf >= 2 and second ~= "y" then
      -- 5. "n" + (母音でも y でも n でもない文字) -> 「ん」を確定し、
      --    その文字から仕切り直す（"n" + 母音や "ny" は別途変換表でマッチ済みのはず）
      context:doKakutei("ん")
      context.buffer = buf:sub(2)
    elseif #buf > 1 then
      -- 6. どの規則にも合わない -> 先頭の1文字を捨てて仕切り直す（誤入力からの回復）
      context.buffer = buf:sub(2)
    else
      -- 1文字だけで変換表にもなく prefix にもならない -> 未対応の文字として破棄する
      context.buffer = ""
      return
    end
  end
end

--- 1文字分のローマ字入力を処理する。
---@param context SkkContext
---@param char string 半角英字1文字を想定
function M.kanaInput(context, char)
  context.buffer = context.buffer .. char
  process(context)
end

return M
