-- lua/skk/kana_util.lua
--
-- ひらがな/カタカナ/全角英数 の相互変換ユーティリティ。
--
-- 半角カタカナへの変換は検討したが、ターミナルエミュレーターの動作が
-- 不安定になる事例が確認されたため実装しない方針とした。
--
-- 【なぜ自前で UTF-8 デコード/エンコードを書いているか】
-- Lua 5.3+ の標準 `utf8` ライブラリは LuaJIT（Neovim の既定の Lua 実装）には
-- 含まれていない。`utf8.codes`/`utf8.char` に依存するコードを書くと、この
-- 開発環境（lua5.4）では動いても実際の Neovim (LuaJIT) では
-- "attempt to index a nil value (global 'utf8')" のように壊れる可能性がある。
-- そのため、バイト列から直接コードポイントを読み書きする最小限の
-- デコーダ/エンコーダをここに実装する。

local M = {}

--- UTF-8 バイト列を Unicode コードポイントの配列にデコードする。
---@param str string
---@return integer[]
local function utf8_decode(str)
  local codepoints = {}
  local i = 1
  local len = #str
  while i <= len do
    local b1 = str:byte(i)
    local cp, size

    if b1 < 0x80 then
      cp, size = b1, 1
    elseif b1 >= 0xF0 then
      local b2, b3, b4 = str:byte(i + 1, i + 3)
      cp = ((b1 - 0xF0) * 0x40000) + ((b2 - 0x80) * 0x1000) + ((b3 - 0x80) * 0x40) + (b4 - 0x80)
      size = 4
    elseif b1 >= 0xE0 then
      local b2, b3 = str:byte(i + 1, i + 2)
      cp = ((b1 - 0xE0) * 0x1000) + ((b2 - 0x80) * 0x40) + (b3 - 0x80)
      size = 3
    elseif b1 >= 0xC0 then
      local b2 = str:byte(i + 1)
      cp = ((b1 - 0xC0) * 0x40) + (b2 - 0x80)
      size = 2
    else
      -- 不正なバイト列。そのまま1バイトとして扱いスキップする
      cp, size = b1, 1
    end

    table.insert(codepoints, cp)
    i = i + size
  end
  return codepoints
end

--- Unicode コードポイント1つを UTF-8 バイト列にエンコードする。
---@param cp integer
---@return string
local function utf8_encode(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40))
  elseif cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + (math.floor(cp / 0x40) % 0x40), 0x80 + (cp % 0x40))
  else
    return string.char(
      0xF0 + math.floor(cp / 0x40000),
      0x80 + (math.floor(cp / 0x1000) % 0x40),
      0x80 + (math.floor(cp / 0x40) % 0x40),
      0x80 + (cp % 0x40)
    )
  end
end

M._utf8_decode = utf8_decode -- テストから直接検証できるように公開しておく
M._utf8_encode = utf8_encode

-- ひらがな(U+3041-U+3096)とカタカナ(U+30A1-U+30F6)は、小書き文字を含め
-- 例外なく +0x60 のオフセットで対応している。
local HIRA_START, HIRA_END, HIRA_TO_KATA_OFFSET = 0x3041, 0x3096, 0x60

--- ひらがな文字列をカタカナに変換する。
--- ひらがな範囲外の文字（ー・、・。・「・」等）はそのまま素通りする。
---@param str string
---@return string
function M.to_katakana(str)
  local out = {}
  for _, cp in ipairs(utf8_decode(str)) do
    if cp >= HIRA_START and cp <= HIRA_END then
      table.insert(out, utf8_encode(cp + HIRA_TO_KATA_OFFSET))
    else
      table.insert(out, utf8_encode(cp))
    end
  end
  return table.concat(out)
end

--- 半角ASCII1文字を全角に変換する。
--- 半角スペース(0x20)は全角スペース(U+3000)に、
--- 半角の印字可能文字(0x21-0x7E)は +0xFEE0 した全角形に変換する。
--- 対象外の文字（制御文字等）はそのまま返す。
---@param char string 半角ASCII1文字
---@return string
function M.to_zenkaku_char(char)
  local cp = char:byte(1)
  if cp == nil or #char ~= 1 then
    return char
  end
  if cp == 0x20 then
    return utf8_encode(0x3000)
  elseif cp >= 0x21 and cp <= 0x7E then
    return utf8_encode(cp + 0xFEE0)
  else
    return char
  end
end

return M
