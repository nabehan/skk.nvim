-- lua/skk/encoding.lua
--
-- vim.fn.iconv() の薄いラッパー。辞書ファイルの文字コード変換に使う
-- （SKK-JISYO.L 等の伝統的な辞書は EUC-JP エンコーディングが主流）。
--
-- lua/skk/dict/jisyo_parser.lua は常に UTF-8 のテキストを受け取る前提の
-- ため、辞書ファイルを読み込む側（lua/skk/dict/file_source.lua、後続
-- フェーズで実装）がここを経由して事前に変換する。

local M = {}

--- 文字列を from エンコーディングから to エンコーディングへ変換する。
--- 変換に失敗した場合（vim.fn.iconv が空文字列を返す、または対応する
--- エンコーディングが無い等）は nil を返す。
---@param str string
---@param from string 例: "euc-jp"
---@param to string 例: "utf-8"
---@return string|nil
function M.convert(str, from, to)
  if from == to then
    return str
  end

  local ok, result = pcall(vim.fn.iconv, str, from, to)
  if not ok then
    return nil
  end

  -- vim.fn.iconv は変換に失敗すると空文字列を返す仕様
  -- （元の文字列が空でないのに結果が空になった場合は失敗とみなす）。
  if result == "" and str ~= "" then
    return nil
  end

  return result
end

--- UTF-8 への変換のショートカット。
---@param str string
---@param from string
---@return string|nil
function M.to_utf8(str, from)
  return M.convert(str, from, "utf-8")
end

return M
