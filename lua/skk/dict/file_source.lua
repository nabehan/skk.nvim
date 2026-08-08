-- lua/skk/dict/file_source.lua
--
-- 辞書ファイルを読み込み、必要ならエンコーディング変換してからパースする。
--
-- ファイルの読み込み・文字コード変換（io.open/io.read, vim.fn.iconv 経由）
-- 自体は同期的に行う（実測でも数MB〜十数MBのファイルで1秒未満）。
-- 一方でパース本体（jisyo_parser.parse()）は大きな辞書（SKK-JISYO.LL
-- 相当、数十万行）だと数秒単位でブロックすることが実際に問題になったため、
-- jisyo_parser.parse_async() によるチャンク分割パースと組み合わせて使う
-- M.read_and_decode() を用意している（lua/skk/dict/init.lua の
-- M.load_dictionary_async() 参照）。M.load() は小さい辞書やテスト用の
-- 同期版としてそのまま残している。

local encoding = require("skk.encoding")
local parser = require("skk.dict.jisyo_parser")

local M = {}

--- 辞書ファイルを読み込み、UTF-8のテキストに変換する（パースはしない）。
--- M.load()（同期・読み込み+パース）と、非同期パース
--- （jisyo_parser.parse_async）を組み合わせたい呼び出し側
--- （lua/skk/dict/init.lua の M.load_dictionary_async() 参照）から使う。
---@param path string ファイルパス
---@param file_encoding string|nil ファイルの文字コード（省略時は "euc-jp"）
---@return string|nil utf8_text 読み込み・変換に失敗したら nil
---@return string|nil err 失敗時のエラーメッセージ
function M.read_and_decode(path, file_encoding)
  file_encoding = file_encoding or "euc-jp"

  local f, open_err = io.open(path, "rb")
  if not f then
    return nil, "辞書ファイルを開けませんでした: " .. path .. " (" .. tostring(open_err) .. ")"
  end

  local raw = f:read("*a")
  f:close()

  if raw == nil then
    return nil, "辞書ファイルの読み込みに失敗しました: " .. path
  end

  local utf8_text = encoding.to_utf8(raw, file_encoding)
  if not utf8_text then
    return nil, "文字コード変換に失敗しました: " .. path .. " (" .. file_encoding .. " -> utf-8)"
  end

  return utf8_text, nil
end

--- 辞書ファイルを読み込んでパースする。
---@param path string ファイルパス
---@param file_encoding string|nil ファイルの文字コード（省略時は "euc-jp"。
---  伝統的な SKK-JISYO.L 等は euc-jp が主流）
---@return table|nil dict パース結果（jisyo_parser.parse() の戻り値）。
---  読み込み・変換に失敗したら nil
---@return string|nil err 失敗時のエラーメッセージ
function M.load(path, file_encoding)
  local utf8_text, err = M.read_and_decode(path, file_encoding)
  if not utf8_text then
    return nil, err
  end
  return parser.parse(utf8_text), nil
end

return M
